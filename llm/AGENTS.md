# AGENTS.md — guidance for LLMs/agents operating in this dir

Conventions and entry points for any agent (Claude, hermes, etc.) doing
troubleshooting, sizing, or making changes to the LLM stack on hopper.

For day-to-day human ops (model config, common commands), see `README.md`.

## Where the logs are

Everything from llama-swap and the llama-server children flows into the
**user systemd-journald** (UID 1000, miguel). **No dedicated log files
exist** — the llama-swap binary has no `--log-file` flag, and the
llama-server children inherit the parent's stdout.

```bash
# Full history
journalctl --user -u llama-swap.service --no-pager

# Last N lines, without HTTP request noise
journalctl --user -u llama-swap.service -n 200 --no-pager \
  | grep -viE 'GET|POST|HTTP|404'

# Time window
journalctl --user -u llama-swap.service --since "1 hour ago"
journalctl --user -u llama-swap.service --since "2026-05-07 00:30" \
                                        --until "2026-05-07 01:00"

# OOM / unit-kill events
journalctl --user -u llama-swap.service \
  | grep -iE 'oom|killed|signal: killed|consumed.*memory peak'

# Kernel ring buffer (root for full visibility) — use this to spot
# amdgpu eviction events, OOM-killer firing, etc.
sudo dmesg -T | grep -iE 'amdgpu|oom|killed process'
journalctl -k --since "1 hour ago" | grep -iE 'amdgpu|oom'
```

journald is persistent on this host (`/var/log/journal/` exists, not
tmpfs). Logs survive reboots. Volume so far is ~65 KiB/day for
llama-swap; the default `SystemMaxUse=10% of /var` (~6.7 GiB) covers
≥1 year of logs comfortably. No explicit retention has been configured.

## Where the configuration lives

```
/srv/selfhost/llm/
├── README.md              ← user-facing ops manual
├── AGENTS.md              ← this file
├── llama-swap.yaml        ← model definitions (source of truth)
├── llama-swap.service     ← systemd --user unit (port 8090)
├── zfs-arc.conf           ← /etc/modprobe.d/zfs.conf staged content
├── install.sh, update.sh, bench.sh, download-models.sh
├── triage/                ← incident docs + diagnostic scripts
│   ├── 2026-05-07-oom-after-boot.md       ← full GTT-eviction OOM writeup
│   ├── llama-server-flags-deepdive.md     ← flag + env var survey
│   ├── snapshot.sh                         ← state dump at a moment
│   ├── stress-vram-pinning.sh              ← eviction-under-pressure test
│   ├── check-vram-after-load.sh            ← pass/fail VRAM placement
│   └── dashboard.sh                        ← streaming dstat-style live view
```

Hermes config (default model, aliases): `~/.hermes/config.yaml`.

## Where to start when troubleshooting

Capture state before changing anything:

```bash
sh /srv/selfhost/llm/triage/snapshot.sh > /tmp/llm-$(date +%s).log
```

For live observation during stress / debugging / heavy inference:

```bash
/srv/selfhost/llm/triage/dashboard.sh        # 1s tick, runs forever
```

Columns: `t cpu% wa% mem swp si so r_MB w_MB gpu% vram gtt arc llama%`.
Header reprints every 50 rows.

## Critical things to remember

1. **VRAM→GTT eviction** is the known persistent issue on this stack.
   Partial mitigations are in place via env vars
   (`GGML_VK_ALLOW_SYSMEM_FALLBACK=0`,
   `GGML_VK_ENABLE_MEMORY_PRIORITY=1`) and the llama-server flag
   `--no-host`. The structural fix is `amdgpu.gttsize=3072` in
   `/etc/modprobe.d/amdgpu.conf` (root + reboot).
   **Do NOT use the literal `amdgpu.gttsize=3072` form** — that is the
   kernel-cmdline syntax; modprobe.d wants `options amdgpu gttsize=3072`.

2. **GTT is invisible to the cgroup**. `MemoryMax=24G` on
   `llama-swap.service` does NOT protect against allocations the
   amdgpu driver makes outside the cgroup. If you see an OOM kill where
   the cgroup peak was below the limit, GTT growth was the cause.

3. **`-watch-config` restarts the running model on any yaml change**,
   even when the changed block is unrelated. That triggers an evict +
   cold reload (~50-110s). Edit the yaml carefully when an active
   hermes session is in flight.

4. **journald `--user` vs system**. llama-swap runs as `--user`, so its
   logs live in the UID 1000 user-journal. Always pass `--user` to
   journalctl.

5. **VRAM sizing — never forecast, just load and read.** llama-server
   itself prints the authoritative memory breakdown at load time. Do not
   derive it from GGUF metadata; the naive formula overestimates by
   ~30% for dense Qwen models. **The child stdout/stderr is NOT in the
   systemd journal** — llama-swap captures it on its own pipe and exposes
   it via an SSE endpoint. The right procedure is:

   ```bash
   # 1. trigger cold load + smoke probe
   curl -s -m 240 http://127.0.0.1:8090/v1/chat/completions \
     -H 'content-type: application/json' \
     -d '{"model":"<NAME>","messages":[{"role":"user","content":"OK"}],"max_tokens":4}' > /dev/null
   # 2. read the FULL llama-server log via per-model SSE stream
   timeout 3 curl -sN http://127.0.0.1:8090/logs/stream/<NAME>
   # or grep the key lines:
   timeout 3 curl -sN http://127.0.0.1:8090/logs/stream/<NAME> \
     | grep -E 'common_params_fit_impl|common_memory_breakdown_print'
   ```

   Example output for gemma-31b at `-c 131072` (validated 2026-05-07):
   ```
   common_memory_breakdown_print: |   - Vulkan0 ... | 32624 = 32104 + (27461 = 20861 + 6077 + 522) + -26942 |
   common_params_fit_impl: projected to use 27461 MiB of device memory vs. 32104 MiB of free device memory
   common_params_fit_impl: will leave 4643 >= 1024 MiB of free device memory, no changes needed
   ```
   That's 27461 MiB = 20861 (model) + 6077 (context) + 522 (compute);
   margin 4643 MiB. Annotate the yaml comment with these exact numbers.

   The SSE replays the model's last load from the beginning, so it's
   readable any time after the model has started. `timeout 3` bounds
   the otherwise-indefinite stream.

6. **Two flags that must be on every interactive model.** `--parallel 1`
   (otherwise llama.cpp default is 4 slots — each can independently
   stick) and `--reasoning-budget 8192` for any reasoning-capable model
   (otherwise default is `-1` = unrestricted, and qwen 3.6 / deepseek /
   gpt-oss can spiral inside one `<think>` block until they hit ctx).
   Documented in lessons.md.

## Future work to track

- **Speculative decoding / MTP for Qwen 3.6**. Two upstream PRs (both not
  merged as of 2026-05-07):
  - <https://github.com/ggml-org/llama.cpp/pull/22546> — "spec: allow
    multiple spec types (chains of speculators)". Architecture-agnostic.
    Lets you combine n-gram cache + draft model + MTP and pick best at
    runtime.
  - <https://github.com/ggml-org/llama.cpp/pull/22673> — "llama + spec:
    MTP Support". Multi-Token Prediction targeted at **Qwen 3.6 27B**
    and **Qwen 3.6 35B-A3B** specifically (our models). 1.5–2× gen
    speedup, ~75% draft acceptance, <10% memory overhead, opt-in via
    `--spec-type mtp`. Vulkan support in progress.
  When either lands in a release we pull, evaluate and benchmark on
  the R9700.

## Conventions

- All infra is YAGNI + reproducible + documented. Changes go into the
  yaml or the unit, with a comment explaining **why** (not what).
- Inline comments in `llama-swap.yaml` show the per-model VRAM forecast.
  Update them when ctx or flags change.
- Empirical tests (cold load + dashboard) confirm the forecast before
  closing out a fix.
