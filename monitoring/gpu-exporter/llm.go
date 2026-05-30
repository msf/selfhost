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
	"time"
)

// 4s: llama-server serves /metrics synchronously, so under heavy inference
// (hermes mid-request) a 2s timeout intermittently dropped the rate metrics,
// punching gaps in the graph. 4s rides out a busy slot while staying under
// vmagent's scrape window.
var httpClient = &http.Client{Timeout: 4 * time.Second}

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
