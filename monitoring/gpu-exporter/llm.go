package main

// LLM metrics: llama-server's native Prometheus metrics carry no model label,
// but llama-swap's /running knows which model is loaded and on which port.
// We read /running for (model, proxyURL), scrape that upstream's /metrics, and
// re-emit the rates as llm_*{model="..."} so the dashboard can label them.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 2s: llama-server serves /metrics and /slots synchronously on its inference
// loop, so during a prefill batch they block for seconds. We no longer scrape
// them from the /metrics handler (see llmCache); a background poller absorbs
// the latency, so a timed-out poll just keeps the last-good values instead of
// punching a gap. 2s is enough to ride out a yield between decode batches.
var httpClient = &http.Client{Timeout: 2 * time.Second}

// llmCache decouples serving from scraping. The /metrics handler must never
// call collectLLM directly: llama-server's synchronous endpoints would block
// it during prefill, blow past vmagent's scrape timeout, and drop the whole
// sample (GPU metrics included). Instead a single background poller refreshes
// this cache and the handler serves the last snapshot instantly.
type llmCache struct {
	mu       sync.RWMutex
	metrics  []metric
	lastPoll time.Time
}

func (c *llmCache) get() ([]metric, time.Time) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.metrics, c.lastPoll
}

func (c *llmCache) set(m []metric) {
	c.mu.Lock()
	c.metrics, c.lastPoll = m, time.Now()
	c.mu.Unlock()
}

// poll refreshes the cache forever. collectLLM is bounded by httpClient's
// timeout, so the effective cadence is interval + up to a couple seconds of
// upstream latency — well within the staleness window the handler checks.
func (c *llmCache) poll(swapBase string, interval time.Duration) {
	for {
		c.set(collectLLM(swapBase))
		time.Sleep(interval)
	}
}

type runningResp struct {
	Running []struct {
		Model string `json:"model"`
		Proxy string `json:"proxy"` // e.g. http://localhost:9005
		State string `json:"state"`
	} `json:"running"`
}

// llamaSwapMetrics maps the upstream llamacpp: rate metrics we want onto our
// model-labelled names.
var llamaSwapMetrics = []struct {
	upstream string // llama-server metric name (no "llamacpp:" prefix matched literally below)
	name     string
	help     string
}{
	{"llamacpp:prompt_tokens_seconds", "llm_prompt_tokens_per_second", "Prompt processing speed (pp/s)"},
	{"llamacpp:predicted_tokens_seconds", "llm_tokens_per_second", "Token generation speed (tg/s)"},
	{"llamacpp:requests_processing", "llm_requests_processing", "Requests currently processing"},
	{"llamacpp:requests_deferred", "llm_requests_deferred", "Requests deferred (queued)"},
	// Note: llama-server's /metrics has no KV-cache or ctx-size gauge. We
	// derive those from /slots instead (see collectSlots).
}

// slot mirrors the fields we use from llama-server /slots. n_ctx is the
// per-slot context window; n_tokens is the current KV-cache occupancy.
type slot struct {
	NCtx         int  `json:"n_ctx"`
	NTokens      int  `json:"n_tokens"`
	IsProcessing bool `json:"is_processing"`
}

// parsePromValue returns the float value of a bare `name <value>` line.
func parsePromValue(body, name string) (float64, bool) {
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == name {
			if v, err := strconv.ParseFloat(fields[1], 64); err == nil {
				return v, true
			}
		}
	}
	return 0, false
}

func fetch(url string) (string, bool) {
	resp, err := httpClient.Get(url)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", false
	}
	return string(b), true
}

// collectLLM queries llama-swap and the active model's upstream, returning
// model-labelled metrics. Empty (not an error) when no model is loaded — the
// dashboard just shows No Data, which is the truth.
func collectLLM(swapBase string) []metric {
	body, ok := fetch(swapBase + "/running")
	if !ok {
		return nil
	}
	var rr runningResp
	if err := json.Unmarshal([]byte(body), &rr); err != nil {
		return nil
	}

	var out []metric
	for _, r := range rr.Running {
		if r.Model == "" || r.Proxy == "" {
			continue
		}
		label := fmt.Sprintf(`{model=%q,state=%q}`, r.Model, r.State)
		loaded := 0.0
		if r.State == "ready" {
			loaded = 1
		}
		out = append(out, metric{"llm_model_loaded",
			"1 if the model is loaded and ready", "gauge", label, loaded})

		mlabel := fmt.Sprintf(`{model=%q}`, r.Model)

		if ups, ok := fetch(r.Proxy + "/metrics"); ok {
			for _, m := range llamaSwapMetrics {
				if v, ok := parsePromValue(ups, m.upstream); ok {
					out = append(out, metric{m.name, m.help, "gauge", mlabel, v})
				}
			}
		}
		out = append(out, collectSlots(r.Proxy, mlabel)...)
	}
	return out
}

// collectSlots reads the context window from /slots. KV occupancy is not
// available in this build (see the note on llamaSwapMetrics), so we only
// emit ctx size. Single slot here (--parallel 1); take the max if more.
func collectSlots(proxy, mlabel string) []metric {
	body, ok := fetch(proxy + "/slots")
	if !ok {
		return nil // /slots may be disabled; not an error
	}
	var slots []slot
	if err := json.Unmarshal([]byte(body), &slots); err != nil || len(slots) == 0 {
		return nil
	}
	ctx := 0
	for _, s := range slots {
		if s.NCtx > ctx {
			ctx = s.NCtx
		}
	}
	if ctx == 0 {
		return nil
	}
	return []metric{{"llm_ctx_size", "Configured context window (tokens)",
		"gauge", mlabel, float64(ctx)}}
}
