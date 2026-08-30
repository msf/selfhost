// shelly2vm polls Shelly Gen2+ devices over their local HTTP RPC and pushes the
// readings to VictoriaMetrics in Prometheus exposition format.
//
// Two classes of device are scraped concurrently and independently, each on its
// own goroutine, so a slow or absent device never stalls the others:
//
//	Mains-powered switches are polled on a slow tick. A failure there is a real
//	outage, and is reported as shelly_up 0.
//
//	Battery sensors (Shelly H&T Gen3) deep-sleep between wakes, surfacing for a
//	few seconds every wakeup_period. They are polled optimistically on a fast
//	tick, and a failure means "asleep", not "down" — nothing is emitted at all,
//	so the absence never pollutes the series.
//
// Component keys in Shelly.GetStatus are dynamic ("switch:0", "temperature:0"),
// so the status is decoded as a key/value map and dispatched by prefix. One
// code path therefore covers switches and sensors alike.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Device struct {
	Addr     string
	Label    string
	ID       string
	Interval time.Duration
	Sleepy   bool
	client   *http.Client
}

func (d *Device) identity() string {
	return firstNonEmpty(d.Label, d.ID, d.Addr)
}

type deviceInfo struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Model string `json:"model"`
}

// Pointer fields distinguish "absent" from zero: a Shelly Plus 1 has no power
// metering at all, and reporting it as 0 W would be a lie, not a measurement.
type switchStatus struct {
	ID      int      `json:"id"`
	Output  *bool    `json:"output"`
	APower  *float64 `json:"apower"`
	Voltage *float64 `json:"voltage"`
	Current *float64 `json:"current"`
	Freq    *float64 `json:"freq"`
	PF      *float64 `json:"pf"`
	AEnergy *struct {
		Total float64 `json:"total"`
	} `json:"aenergy"`
	Temperature *struct {
		C *float64 `json:"tC"`
	} `json:"temperature"`
}

type sensorStatus struct {
	ID int      `json:"id"`
	C  *float64 `json:"tC"`
	RH *float64 `json:"rh"`
}

type powerStatus struct {
	Battery struct {
		Volts   *float64 `json:"V"`
		Percent *float64 `json:"percent"`
	} `json:"battery"`
	External struct {
		Present *bool `json:"present"`
	} `json:"external"`
}

type sysStatus struct {
	MAC          string `json:"mac"`
	Uptime       *int64 `json:"uptime"`
	WakeupPeriod *int64 `json:"wakeup_period"`
}

type wifiStatus struct {
	RSSI *float64 `json:"rssi"`
	SSID string   `json:"ssid"`
}

type sample struct {
	name   string
	labels map[string]string
	value  float64
}

func main() {
	var (
		mains         string
		sleepy        string
		vmHost        string
		vmPort        string
		interval      time.Duration
		sleepyEvery   time.Duration
		timeout       time.Duration
		sleepyTimeout time.Duration
		dryRun        bool
		once          bool
	)
	flag.StringVar(&mains, "devices", "", "comma-separated mains-powered Shellys (label=host)")
	flag.StringVar(&sleepy, "sleepy", "", "comma-separated battery Shellys (label=host)")
	flag.StringVar(&vmHost, "vm-host", "hopper", "VictoriaMetrics host")
	flag.StringVar(&vmPort, "vm-port", "8428", "VictoriaMetrics port")
	flag.DurationVar(&interval, "interval", 30*time.Second, "poll interval for mains-powered devices")
	flag.DurationVar(&sleepyEvery, "sleepy-interval", time.Second, "poll interval for battery devices")
	flag.DurationVar(&timeout, "timeout", 4*time.Second, "request timeout for mains-powered devices")
	flag.DurationVar(&sleepyTimeout, "sleepy-timeout", time.Second, "request timeout for battery devices")
	flag.BoolVar(&dryRun, "dry-run", false, "print exposition to stdout instead of pushing")
	flag.BoolVar(&once, "once", false, "poll every device a single time and exit")
	flag.Parse()

	if env := os.Getenv("VM_HOST"); env != "" {
		vmHost = env
	}
	if env := os.Getenv("SHELLY_DEVICES"); env != "" && mains == "" {
		mains = env
	}
	if env := os.Getenv("SHELLY_SLEEPY"); env != "" && sleepy == "" {
		sleepy = env
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	devices := append(
		parseDevices(mains, interval, timeout, false),
		parseDevices(sleepy, sleepyEvery, sleepyTimeout, true)...,
	)
	if len(devices) == 0 {
		log.Error("no devices configured; pass -devices and/or -sleepy")
		os.Exit(2)
	}

	c := &collector{
		vmClient: &http.Client{Timeout: 10 * time.Second},
		vmURL:    fmt.Sprintf("http://%s:%s/api/v1/import/prometheus", vmHost, vmPort),
		log:      log,
		dryRun:   dryRun,
	}

	log.Info("starting", "devices", len(devices), "vm", c.vmURL, "dry_run", dryRun)

	if once {
		var wg sync.WaitGroup
		for _, d := range devices {
			wg.Add(1)
			go func(d *Device) {
				defer wg.Done()
				c.poll(d)
			}(d)
		}
		wg.Wait()
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var wg sync.WaitGroup
	for _, d := range devices {
		wg.Add(1)
		go func(d *Device) {
			defer wg.Done()
			c.run(ctx, d)
		}(d)
	}
	wg.Wait()
	log.Info("shutting down")
}

// parseDevices accepts "192.168.0.3" or "label=192.168.0.3".
func parseDevices(s string, interval, timeout time.Duration, sleepy bool) []*Device {
	var out []*Device
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		d := &Device{
			Addr:     part,
			Interval: interval,
			Sleepy:   sleepy,
			client:   &http.Client{Timeout: timeout},
		}
		if label, addr, ok := strings.Cut(part, "="); ok {
			d.Label, d.Addr = label, addr
		}
		out = append(out, d)
	}
	return out
}

type collector struct {
	vmClient *http.Client
	vmURL    string
	log      *slog.Logger
	dryRun   bool
}

// run polls one device forever. Sleeping between polls rather than ticking
// keeps a slow request from stacking up overlapping polls.
func (c *collector) run(ctx context.Context, d *Device) {
	for {
		c.poll(d)
		select {
		case <-ctx.Done():
			return
		case <-time.After(d.Interval):
		}
	}
}

func (c *collector) poll(d *Device) {
	ts := time.Now()

	samples, err := c.scrape(d, ts)
	if err != nil {
		// A sleeping sensor is not a failure; stay silent so the gap in the
		// series honestly reflects "no reading" rather than "device down".
		if d.Sleepy {
			return
		}
		c.log.Warn("scrape failed", "addr", d.Addr, "err", err)
		c.emit([]sample{{
			name:   "shelly_up",
			labels: map[string]string{"device": d.identity(), "addr": d.Addr},
			value:  0,
		}}, ts)
		return
	}

	if d.Sleepy {
		c.log.Info("sensor awake", "addr", d.Addr, "device", d.identity(), "samples", len(samples))
	}
	c.emit(samples, ts)
}

func (c *collector) emit(samples []sample, ts time.Time) {
	var buf bytes.Buffer
	writeSamples(&buf, samples, ts)
	if buf.Len() == 0 {
		return
	}
	if c.dryRun {
		fmt.Print(buf.String())
		return
	}
	if err := c.push(buf.Bytes()); err != nil {
		c.log.Error("victoriametrics push failed", "err", err)
	}
}

func (c *collector) rpc(d *Device, method string, out any) error {
	url := fmt.Sprintf("http://%s/rpc/%s", d.Addr, method)
	resp, err := d.client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s returned %d", method, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}

func (c *collector) scrape(d *Device, ts time.Time) ([]sample, error) {
	var status map[string]json.RawMessage
	if err := c.rpc(d, "Shelly.GetStatus", &status); err != nil {
		return nil, err
	}

	// Readings first, metadata second: a sleepy device may vanish mid-scrape,
	// and losing its identity is far cheaper than losing the measurement.
	if d.ID == "" {
		var info deviceInfo
		if err := c.rpc(d, "Shelly.GetDeviceInfo", &info); err == nil {
			d.ID = info.ID
			if d.Label == "" {
				d.Label = firstNonEmpty(info.Name, info.ID)
			}
		}
	}

	dev := d.identity()
	out := []sample{{name: "shelly_up", labels: map[string]string{"device": dev, "addr": d.Addr}, value: 1}}
	if d.Sleepy {
		out = append(out, sample{"shelly_last_seen_timestamp_seconds", map[string]string{"device": dev}, float64(ts.Unix())})
	}

	keys := make([]string, 0, len(status))
	for k := range status {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, key := range keys {
		raw := status[key]
		component, _, _ := strings.Cut(key, ":")

		switch component {
		case "switch":
			var s switchStatus
			if json.Unmarshal(raw, &s) != nil {
				continue
			}
			l := map[string]string{"device": dev, "switch": fmt.Sprint(s.ID)}
			out = appendIf(out, "shelly_switch_power_watts", l, s.APower)
			out = appendIf(out, "shelly_switch_voltage_volts", l, s.Voltage)
			out = appendIf(out, "shelly_switch_current_amperes", l, s.Current)
			out = appendIf(out, "shelly_switch_frequency_hertz", l, s.Freq)
			out = appendIf(out, "shelly_switch_power_factor", l, s.PF)
			if s.Output != nil {
				out = append(out, sample{"shelly_switch_output", l, boolValue(*s.Output)})
			}
			if s.AEnergy != nil {
				out = append(out, sample{"shelly_switch_energy_watthours_total", l, s.AEnergy.Total})
			}
			if s.Temperature != nil {
				out = appendIf(out, "shelly_switch_temperature_celsius", l, s.Temperature.C)
			}

		case "temperature", "humidity":
			var s sensorStatus
			if json.Unmarshal(raw, &s) != nil {
				continue
			}
			l := map[string]string{"device": dev, "sensor": fmt.Sprint(s.ID)}
			out = appendIf(out, "shelly_temperature_celsius", l, s.C)
			out = appendIf(out, "shelly_humidity_percent", l, s.RH)

		case "devicepower":
			var s powerStatus
			if json.Unmarshal(raw, &s) != nil {
				continue
			}
			l := map[string]string{"device": dev}
			out = appendIf(out, "shelly_battery_volts", l, s.Battery.Volts)
			out = appendIf(out, "shelly_battery_percent", l, s.Battery.Percent)
			if s.External.Present != nil {
				out = append(out, sample{"shelly_external_power", l, boolValue(*s.External.Present)})
			}

		case "sys":
			var s sysStatus
			if json.Unmarshal(raw, &s) != nil {
				continue
			}
			l := map[string]string{"device": dev}
			if s.Uptime != nil {
				out = append(out, sample{"shelly_uptime_seconds", l, float64(*s.Uptime)})
			}
			if s.WakeupPeriod != nil {
				out = append(out, sample{"shelly_wakeup_period_seconds", l, float64(*s.WakeupPeriod)})
			}

		case "wifi":
			var s wifiStatus
			if json.Unmarshal(raw, &s) != nil {
				continue
			}
			out = appendIf(out, "shelly_wifi_rssi_dbm", map[string]string{"device": dev, "ssid": s.SSID}, s.RSSI)
		}
	}
	return out, nil
}

func appendIf(out []sample, name string, labels map[string]string, v *float64) []sample {
	if v == nil {
		return out
	}
	return append(out, sample{name, labels, *v})
}

func boolValue(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func writeSamples(buf *bytes.Buffer, samples []sample, ts time.Time) {
	ms := ts.UnixMilli()
	for _, s := range samples {
		keys := make([]string, 0, len(s.labels))
		for k := range s.labels {
			keys = append(keys, k)
		}
		sort.Strings(keys)

		pairs := make([]string, 0, len(keys))
		for _, k := range keys {
			pairs = append(pairs, fmt.Sprintf("%s=%q", k, s.labels[k]))
		}
		fmt.Fprintf(buf, "%s{%s} %g %d\n", s.name, strings.Join(pairs, ","), s.value, ms)
	}
}

func (c *collector) push(body []byte) error {
	req, err := http.NewRequest(http.MethodPost, c.vmURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "text/plain")

	resp, err := c.vmClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("vm returned %d: %s", resp.StatusCode, msg)
	}
	return nil
}
