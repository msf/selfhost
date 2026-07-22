package main

// The R9700's SMU reads GDDR temperature over I²C and publishes it into every
// source we have (hwmon "mem", gpu_metrics.temp_mem) — there is no second,
// independent memory sensor to fall back to. That read can hang: the SMU then
// re-publishes the last value forever while edge/junction/vrmem stay live, so
// mem freezes hot (seen: 88 °C pinned for an hour at 5 W idle) and the firmware
// fan curve chases the phantom heat. A real memory workload re-arms the read,
// and every sysfs knob is root-owned, so a 1-token decode through the loaded
// model is the only lever this userspace exporter has to unstick it.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

var memStallKicks atomic.Int64

// kickClient tolerates a decode under prefill contention; httpClient's 2 s is
// too short for a forward pass over the full weights.
var kickClient = &http.Client{Timeout: 10 * time.Second}

// watchMemTempStall re-arms the GDDR temp sensor when the SMU read hangs. Idle
// mem legitimately sits stable in the 30s (room + case), so flatness alone is
// not the signal. We act only when a value is BOTH stuck (unchanged for
// stallWindow) AND impossible: board idle yet mem sits far above the average of
// the other die sensors — its thermal baseline. The tests are complementary —
// the idle+delta test is ambient-invariant (every sensor tracks the room
// together) so it rejects real memory-bound heat and warm idle; the no-change
// test rejects a value merely cooling *through* high readings after a load,
// which is transient, not stuck.
func (c card) watchMemTempStall(swapBase string) {
	const (
		pollEvery   = 30 * time.Second
		stallWindow = 5 * time.Minute
		cooldown    = 3 * time.Minute
		idleWatts   = 30
		minDelta    = 25 // mem this far above the board baseline while idle == impossible
	)
	lastMem := -1.0
	var stuckSince, lastKick time.Time
	for {
		time.Sleep(pollEvery)
		mem, ok1 := c.temp("mem")
		base, ok2 := c.tempBaselineExcluding("mem")
		pw, ok3 := c.powerWatts()
		if !ok1 || !ok2 || !ok3 {
			continue
		}
		if mem != lastMem {
			lastMem, stuckSince = mem, time.Now()
			continue
		}
		frozen := !stuckSince.IsZero() && time.Since(stuckSince) >= stallWindow
		impossible := pw < idleWatts && mem-base >= minDelta
		if frozen && impossible && time.Since(lastKick) >= cooldown && kickGPU(swapBase) {
			memStallKicks.Add(1)
			lastKick = time.Now()
		}
	}
}

// temp returns the hwmon temperature (°C) for a lowercase sensor label.
func (c card) temp(label string) (float64, bool) {
	hw := c.hwmon()
	if hw == "" {
		return 0, false
	}
	for i := 1; i <= 6; i++ {
		if l, ok := readStr(filepath.Join(hw, fmt.Sprintf("temp%d_label", i))); ok && strings.ToLower(l) == label {
			if mc, ok := readInt(filepath.Join(hw, fmt.Sprintf("temp%d_input", i))); ok {
				return float64(mc) / 1000, true
			}
		}
	}
	return 0, false
}

// tempBaselineExcluding averages every hwmon temperature except the named one —
// the board's thermal baseline. Averaging the whole family (not one sibling)
// keeps the outlier test robust to any single sensor; today hwmon exposes only
// edge+junction, but VR sensors join automatically if firmware ever adds them.
func (c card) tempBaselineExcluding(exclude string) (float64, bool) {
	hw := c.hwmon()
	if hw == "" {
		return 0, false
	}
	var sum float64
	var n int
	for i := 1; i <= 6; i++ {
		l, ok := readStr(filepath.Join(hw, fmt.Sprintf("temp%d_label", i)))
		if !ok || strings.ToLower(l) == exclude {
			continue
		}
		if mc, ok := readInt(filepath.Join(hw, fmt.Sprintf("temp%d_input", i))); ok {
			sum += float64(mc) / 1000
			n++
		}
	}
	if n == 0 {
		return 0, false
	}
	return sum / float64(n), true
}

// powerWatts returns average package power in watts.
func (c card) powerWatts() (float64, bool) {
	hw := c.hwmon()
	if hw == "" {
		return 0, false
	}
	if v, ok := readInt(filepath.Join(hw, "power1_average")); ok {
		return float64(v) / 1e6, true
	}
	return 0, false
}

// kickGPU forces a one-token decode through whatever model llama-swap has
// loaded; the forward pass over VRAM makes the SMU re-read the sensor. Returns
// false (no-op) when nothing is loaded — there is nothing to kick.
func kickGPU(swapBase string) bool {
	body, ok := fetch(swapBase + "/running")
	if !ok {
		return false
	}
	var rr runningResp
	if json.Unmarshal([]byte(body), &rr) != nil {
		return false
	}
	for _, r := range rr.Running {
		if r.State != "ready" || r.Proxy == "" {
			continue
		}
		req := strings.NewReader(`{"prompt":" ","n_predict":1,"cache_prompt":false}`)
		resp, err := kickClient.Post(r.Proxy+"/completion", "application/json", req)
		if err != nil {
			return false
		}
		resp.Body.Close()
		return resp.StatusCode == http.StatusOK
	}
	return false
}
