// amdgpu exporter for hopper's R9700.
//
// Reads amdgpu sysfs on every scrape (cheap, always fresh) and serves
// Prometheus text on :9101/metrics. With -once it prints a human-readable
// sensor dump instead (status.sh-style). Stdlib only.
//
// Metric design follows USE:
//
//	Utilization : amdgpu_gpu_busy_percent
//	Saturation  : amdgpu_vram_used_bytes/total, temps, power vs cap, fan, clocks
//	Errors      : amdgpu_up (scrape/device health). The card exposes no RAS or
//	              reset counter in sysfs; GPU resets surface in `journalctl -k`.
//
// Card selection: defaults to the R9700 (PCI device 0x7551) so it never
// accidentally reports the Phoenix2 iGPU. Override with -card cardN.
package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const r9700DeviceID = "0x7551"

type metric struct {
	name   string
	help   string
	mtype  string
	labels string
	value  float64
}

// card resolves sysfs paths for one DRM card. hwmon index is not stable
// across reboots, so it is resolved on every read.
type card struct {
	dev string // /sys/class/drm/cardN/device
}

func readStr(path string) (string, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(b)), true
}

func readInt(path string) (int64, bool) {
	s, ok := readStr(path)
	if !ok {
		return 0, false
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

// hwmon returns the card's amdgpu hwmon directory, or "" if absent.
func (c card) hwmon() string {
	matches, _ := filepath.Glob(filepath.Join(c.dev, "hwmon", "hwmon*"))
	sort.Strings(matches)
	for _, h := range matches {
		if name, ok := readStr(filepath.Join(h, "name")); ok && name == "amdgpu" {
			return h
		}
	}
	if len(matches) > 0 {
		return matches[0]
	}
	return ""
}

// activeClockMHz parses pp_dpm_{sclk,mclk}; the active level ends with '*'.
func (c card) activeClockMHz(file string) (float64, bool) {
	s, ok := readStr(filepath.Join(c.dev, file))
	if !ok {
		return 0, false
	}
	for _, line := range strings.Split(s, "\n") {
		if !strings.HasSuffix(strings.TrimSpace(line), "*") {
			continue
		}
		// "1: 1200Mhz *"
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		num := strings.TrimSpace(parts[1])
		num = strings.TrimSuffix(num, "*")
		num = strings.TrimSpace(num)
		num = strings.TrimSuffix(strings.ToLower(num), "mhz")
		if v, err := strconv.ParseFloat(strings.TrimSpace(num), 64); err == nil {
			return v, true
		}
	}
	return 0, false
}

func (c card) collect() []metric {
	var out []metric
	add := func(name, help, mtype, labels string, v float64, ok bool) {
		if ok {
			out = append(out, metric{name, help, mtype, labels, v})
		}
	}

	up := 0.0
	if _, err := os.Stat(c.dev); err == nil {
		up = 1
	}

	// Utilization
	if v, ok := readInt(filepath.Join(c.dev, "gpu_busy_percent")); ok {
		add("amdgpu_gpu_busy_percent", "GPU compute utilization (percent)", "gauge", "", float64(v), true)
	}

	// Saturation: VRAM
	if v, ok := readInt(filepath.Join(c.dev, "mem_info_vram_used")); ok {
		add("amdgpu_vram_used_bytes", "VRAM used (bytes)", "gauge", "", float64(v), true)
	}
	if v, ok := readInt(filepath.Join(c.dev, "mem_info_vram_total")); ok {
		add("amdgpu_vram_total_bytes", "VRAM total (bytes)", "gauge", "", float64(v), true)
	}

	// Saturation: clocks
	if v, ok := c.activeClockMHz("pp_dpm_sclk"); ok {
		add("amdgpu_sclk_mhz", "Active shader (core) clock (MHz)", "gauge", "", v, true)
	}
	if v, ok := c.activeClockMHz("pp_dpm_mclk"); ok {
		add("amdgpu_mclk_mhz", "Active memory clock (MHz)", "gauge", "", v, true)
	}

	if hw := c.hwmon(); hw != "" {
		// Saturation: thermal — map by label so temp1/2/3 ordering is irrelevant.
		for i := 1; i <= 6; i++ {
			lbl, ok := readStr(filepath.Join(hw, fmt.Sprintf("temp%d_label", i)))
			if !ok {
				continue
			}
			if mc, ok := readInt(filepath.Join(hw, fmt.Sprintf("temp%d_input", i))); ok {
				add("amdgpu_temp_celsius", "GPU temperature (celsius)", "gauge",
					fmt.Sprintf(`{sensor="%s"}`, strings.ToLower(lbl)), float64(mc)/1000, true)
			}
		}
		// Saturation: power (microwatts -> watts)
		if v, ok := readInt(filepath.Join(hw, "power1_average")); ok {
			add("amdgpu_power_watts", "Average GPU package power (watts)", "gauge", "", float64(v)/1e6, true)
		}
		if v, ok := readInt(filepath.Join(hw, "power1_cap")); ok {
			add("amdgpu_power_cap_watts", "GPU power cap / TBP (watts)", "gauge", "", float64(v)/1e6, true)
		}
		// Saturation: voltage (millivolts). The R9700 reports 0 here (no
		// hwmon voltage sensor — same as rocm-smi); only emit if real.
		if v, ok := readInt(filepath.Join(hw, "in0_input")); ok && v > 0 {
			add("amdgpu_voltage_mv", "Core voltage (millivolts)", "gauge", "", float64(v), true)
		}
		// Saturation: fan
		if v, ok := readInt(filepath.Join(hw, "fan1_input")); ok {
			add("amdgpu_fan_rpm", "Fan speed (RPM)", "gauge", "", float64(v), true)
		}
		if pwm, ok := readInt(filepath.Join(hw, "pwm1")); ok {
			max, okm := readInt(filepath.Join(hw, "pwm1_max"))
			if !okm || max == 0 {
				max = 255
			}
			add("amdgpu_fan_pwm_percent", "Fan PWM duty cycle (percent)", "gauge", "",
				float64(pwm)/float64(max)*100, true)
		}
	}

	add("amdgpu_up", "1 if the amdgpu device is readable", "gauge", "", up, true)
	return out
}

func render(metrics []metric) string {
	var b strings.Builder
	seen := map[string]bool{}
	for _, m := range metrics {
		if !seen[m.name] {
			fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s %s\n", m.name, m.help, m.name, m.mtype)
			seen[m.name] = true
		}
		fmt.Fprintf(&b, "%s%s %g\n", m.name, m.labels, m.value)
	}
	return b.String()
}

// findCard returns the DRM card matching the wanted PCI device id, or the
// first card exposing gpu_busy_percent.
func findCard(deviceID string) (card, error) {
	cards, _ := filepath.Glob("/sys/class/drm/card[0-9]*")
	sort.Strings(cards)
	var fallback string
	for _, c := range cards {
		dev := filepath.Join(c, "device")
		id, _ := readStr(filepath.Join(dev, "device"))
		if id == deviceID {
			return card{dev: dev}, nil
		}
		if fallback == "" {
			if _, ok := readInt(filepath.Join(dev, "gpu_busy_percent")); ok {
				fallback = dev
			}
		}
	}
	if fallback != "" {
		return card{dev: fallback}, nil
	}
	return card{}, fmt.Errorf("no amdgpu card found (wanted device %s)", deviceID)
}

func printOnce(c card) {
	m := map[string]metric{}
	for _, x := range c.collect() {
		m[x.name+x.labels] = x
	}
	get := func(k string) float64 { return m[k].value }
	fmt.Printf("R9700 (%s)\n", c.dev)
	fmt.Printf("  busy        %.0f %%\n", get("amdgpu_gpu_busy_percent"))
	fmt.Printf("  vram        %.1f / %.1f GiB\n",
		get("amdgpu_vram_used_bytes")/1073741824, get("amdgpu_vram_total_bytes")/1073741824)
	fmt.Printf("  sclk/mclk   %.0f / %.0f MHz\n", get("amdgpu_sclk_mhz"), get("amdgpu_mclk_mhz"))
	fmt.Printf("  temp edge   %.0f C   junction %.0f C   mem %.0f C\n",
		get(`amdgpu_temp_celsius{sensor="edge"}`),
		get(`amdgpu_temp_celsius{sensor="junction"}`),
		get(`amdgpu_temp_celsius{sensor="mem"}`))
	fmt.Printf("  power       %.0f / %.0f W\n", get("amdgpu_power_watts"), get("amdgpu_power_cap_watts"))
	if v, ok := m[`amdgpu_voltage_mv`]; ok {
		fmt.Printf("  voltage     %.0f mV\n", v.value)
	}
	fmt.Printf("  fan         %.0f RPM (%.0f%%)\n", get("amdgpu_fan_rpm"), get("amdgpu_fan_pwm_percent"))
}

func main() {
	listen := flag.String("listen", ":9101", "HTTP listen address for /metrics")
	cardName := flag.String("card", "", "force a DRM card (e.g. card0); default auto-detects the R9700")
	swapBase := flag.String("swap", "http://127.0.0.1:8090", "llama-swap base URL for model-labelled LLM metrics; empty to disable")
	once := flag.Bool("once", false, "print a human-readable sensor dump and exit")
	flag.Parse()

	var c card
	if *cardName != "" {
		c = card{dev: filepath.Join("/sys/class/drm", *cardName, "device")}
	} else {
		var err error
		if c, err = findCard(r9700DeviceID); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}

	if *once {
		printOnce(c)
		return
	}

	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		m := c.collect()
		if *swapBase != "" {
			m = append(m, collectLLM(*swapBase)...)
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		fmt.Fprint(w, render(m))
	})
	fmt.Fprintf(os.Stderr, "amdgpu-exporter: card=%s listen=%s\n", c.dev, *listen)
	if err := http.ListenAndServe(*listen, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
