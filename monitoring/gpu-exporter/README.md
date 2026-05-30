# amdgpu-exporter

Minimal Go exporter for the R9700 (card0). Reads amdgpu sysfs on every scrape
and serves Prometheus text on `:9101/metrics`. Targets the R9700 by PCI device
id `0x7551`, never the Phoenix2 iGPU (card1, immich's GPU).

## Metrics (USE)

- **Utilization** — `amdgpu_gpu_busy_percent`
- **Saturation** — `amdgpu_vram_used_bytes` / `_total`, `amdgpu_temp_celsius{sensor=edge|junction|mem}`,
  `amdgpu_power_watts` / `_cap_watts`, `amdgpu_fan_rpm`, `amdgpu_fan_pwm_percent`,
  `amdgpu_sclk_mhz`, `amdgpu_mclk_mhz`
- **Errors** — `amdgpu_up` (device/scrape health). The R9700 exposes no RAS or
  reset counter in sysfs; GPU resets surface in `journalctl -k`.

## LLM metrics (model-labelled)

llama-server's native `/metrics` has no model label and no ctx-size gauge.
So the exporter polls llama-swap to add them:

- From llama-swap `/running` → active model + upstream port.
- From upstream `/metrics` → `llm_tokens_per_second` (tg/s),
  `llm_prompt_tokens_per_second` (pp/s), `llm_requests_processing`,
  `llm_requests_deferred`.
- From upstream `/slots` → `llm_ctx_size`.
- `llm_model_loaded{model,state}` — 1 when ready.

All carry `{model="..."}`. Empty when no model is loaded (truthful No Data).
Disable with `-swap ""`.

**KV-cache occupancy is deliberately absent.** This llama.cpp build exposes
it nowhere: `/metrics` has no KV gauge, and recent builds stripped the
token-count fields from `/slots` (only `n_ctx` remains). Rather than emit a
permanently-zero `llm_kv_cache_usage_ratio`, we omit it. If a future build
restores `/slots` token counts (or we want last-request `cache_tokens` from
llama-swap `/api/metrics`), add it back in `collectSlots`.

## Build & run

```sh
go build -o amdgpu-exporter .     # binary is gitignored
./amdgpu-exporter                 # serve on :9101
./amdgpu-exporter -once           # one-shot human sensor dump (status.sh style)
./amdgpu-exporter -card card1     # force a card
```

Scraped by the host vmagent via `localhost:9101` (see
`../vmagent/prometheus.yml`). Runs as `amdgpu-exporter.service`.

## Deploy

Runs as a **user** service (linger on, like llama-swap) — no root, no docker.
amdgpu sysfs is world-readable so no privileges are needed.

```sh
go build -o amdgpu-exporter .
cp amdgpu-exporter.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now amdgpu-exporter
```

The dashboard is pushed via the Grafana API (the provisioning dir is
root-owned): `GRAFANA_PASSWORD=… python3 import_dashboard.py`.

Note: after editing `../vmagent/prometheus.yml`, vmagent's `/-/reload`
returns 200 but does **not** re-read the file — run `docker restart vmagent`.
