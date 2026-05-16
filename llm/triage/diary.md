# LLM stack diary

Reverse-chronological incidents, experiments, decisions.
Config ground truth: `llama-swap.yaml`, `llama-swap.service`.

---

## PENDING — `amdgpu.gttsize=3072` (root + reboot)

The only remaining structural fix for VRAM→GTT eviction under host pressure.
TTM evicts buffers to GTT when the host shrinker fires; capping GTT below model
weight size leaves TTM nowhere to migrate → buffers stay in VRAM.

```bash
sudo tee /etc/modprobe.d/amdgpu.conf <<'EOF'
# Cap GTT pool to 3 GiB (in MiB). Default is ~½ system RAM = 16 GiB on hopper.
# With --no-host, happy-state GTT is ~390 MiB so 3 GiB is comfortable.
# Below model weight size (16–22 GiB) → TTM has no eviction target.
options amdgpu gttsize=3072
EOF
sudo reboot
# verify: cat /sys/module/amdgpu/parameters/gttsize → 3072
```

After reboot: run `stress-vram-pinning.sh` to confirm eviction no longer happens.

---

## 2026-05-13 — metrics gap; perf-monitor is a stopgap

`llama-server --metrics` exposes Prometheus at `$PORT/metrics` (slot utilization,
kv-cache hit rate, token throughput histograms). llama-swap proxies all endpoints
to the active model, so `http://127.0.0.1:8090/metrics` is the single scrape target.
This replaces `perf-monitor.sh` entirely and unlocks Grafana dashboards.

TODO: add `--metrics` to the macro in `llama-swap.yaml`, then add a VictoriaMetrics
scrape job and Grafana dashboard.

---

## 2026-05-11 — ongoing memory pressure; zswap enabled

Machine still memory-stressed (VRAM 0.5G, 4G swap active as of today).
Enabled `zswap` on hopper and updated systemd-boot config for kernel 6.19.
Ref: https://wiki.archlinux.org/title/Zswap

Context: `GGML_VK_ALLOW_SYSMEM_FALLBACK=0` prevents initial GTT allocation.
`--no-host` keeps happy-state GTT at ~0.39G. But TTM can still migrate VRAM→GTT
under kernel shrinker pressure (amdgpu.gttsize fix is the cure — still pending).

---

## 2026-05-08 — SWA prompt-cache checkpoints disabled

Default llama-server behavior: one 637 MiB host-RAM checkpoint every 8k tokens
during prefill (capped at 8 per session). On hermes workloads (tool calls shift
prefix every turn), all checkpoints are invalidated immediately — pure cost.
Gemma 4 (31b, 26b-moe) ballooned llama-server RSS to ~23 GiB with swap thrashing.

Fix in macro: `--checkpoint-every-n-tokens -1 --ctx-checkpoints 2 --cache-ram 2048`

Wait — the macro still has `--ctx-checkpoints 2`. Individual models that need
checkpoints fully off must override with `--ctx-checkpoints 0 --cache-ram 0`
in their cmd block. Gemma-31b comment says "disabled" but doesn't actually
override the macro. **TODO: audit yaml or make per-model overrides explicit.**

If your workload sends the same long prefix repeatedly (stable RAG system prompt),
re-enable per model with `--ctx-checkpoints 4 --checkpoint-every-n-tokens 8192`.

---

## 2026-05-08 — speculative decoding experiment (gemma-31b + E2B draft)

**Goal:** does spec-decoding on R9700/Vulkan deliver a net throughput win?

Config: `gemma-31b-spec` entry in llama-swap.yaml. Main: UD-Q4_K_XL. Draft: E2B Q8_0.

**Parameter sweep results:**

| Config | Creative (PT) acc/tg/s | Code (PY) acc/tg/s |
|---|---|---|
| Q5_K_XL ctx=32k n-max=32 (recipe) | 31.9% / 14.0 | 42.6% / 25.9 |
| Q5_K_XL ctx=32k n-max=8 | 34.9% / 14.0 | **72.1%** / 25.3 |
| **Q4_K_XL ctx=65k n-max=8** | 27.9% / 15.8 | **75.6% / 29.9** ⭐ |

**Findings:**
- Acceptance scales with output predictability: code 70%+, creative ~35%.
- tg/s barely moves despite acceptance improving — Vulkan main↔draft sync overhead is the bottleneck, not draft compute.
- Spec is not a net win for general hermes use (14–30 tok/s vs 30–40 baseline on gemma-31b without draft).
- Clear win for deterministic workloads (code, structured output, translation).

**Gotcha:** `--chat-template-kwargs '{"enable_thinking":false}'` breaks under
llama-swap's `os/exec.Command` (no shell → quotes stripped → JSON parse error).
Fix: env var `LLAMA_CHAT_TEMPLATE_KWARGS={"enable_thinking":false}` (YAML single-quoted).

**Conclusion:** keep `gemma-31b-spec` as a research instrument, not production.
Re-evaluate when MTP (PR #22673) lands — fewer Vulkan sync points should close the gap.

---

## 2026-05-07 — boot OOM; GTT eviction root cause and applied fixes

**Incident:** host OOM at 00:45:39. systemd cgroup peak was only 1.1 GiB (well
under MemoryMax=24G). Root cause: amdgpu GTT allocated 16 GiB of host RAM for
model weights, invisible to systemd cgroup accounting.

**Why GTT bypasses MemoryMax:** GTT is allocated by the amdgpu kernel driver on
behalf of the process; those pages are charged to the kernel, not to the userland
cgroup. Any MemoryMax value is structurally ineffective against GTT.

**Why model went to GTT instead of VRAM:** `-c 262144 --parallel 2` pushed total
GPU demand ~1 GiB over 32 GiB VRAM. Vulkan allocator spilled the overflow to
GTT, then kept using GTT. `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1` alone does
not prevent GTT fallback on RDNA3/4+RADV.

**Applied fixes (all in service + yaml):**

| Fix | Effect | Applied |
|---|---|---|
| `GGML_VK_ALLOW_SYSMEM_FALLBACK=0` | forbids initial alloc to GTT; fails loudly instead | llama-swap.service |
| `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1` | disables host-visible VRAM heap (needed together with above) | llama-swap.service |
| `GGML_VK_ENABLE_MEMORY_PRIORITY=1` | marks buffers max-priority; ~10s grace before TTM evicts under pressure | llama-swap.service |
| `--no-host` | reduces happy-state GTT: 1.20 GiB → 0.39 GiB (-67%); allows tighter gttsize cap | macro |
| `--parallel 1` | prevents thinking-runaway spiral in multiple slots | all big models |
| `--reasoning-budget 8192` | caps `<think>` tokens at 8k; default (-1) is unlimited | all big models |
| ctx reduced from 262144→131072 | fits in VRAM; KV halves | models |

**Flags investigated and rejected** (don't add these back):

- `--mlock`: locks host RAM, not VRAM. Wrong layer.
- `-fit off`: defensive only, doesn't prevent eviction.
- `GGML_VK_FORCE_MAX_BUFFER_SIZE`: sets rejection cap, not chunk size. No-op.
- `--cpu-moe`, `-ngl < 999`: catastrophic throughput hit.

**Empirical `--no-host` numbers** (gemma-26b-moe, -c 180000 --parallel 1):

| Metric | Without | With |
|---|---|---|
| GTT used | 1.20 GiB | **0.39 GiB** |
| Generation tok/s | 73.0 | 69.8 (-4%) |
| Prompt proc tok/s | 361 | 240 (-33%) |

Generation cost is acceptable; prompt-processing drop is the only tradeoff
(hits TTFT on long prompts, not generation throughput).
