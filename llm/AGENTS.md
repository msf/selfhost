# AGENTS.md — guidance for LLMs/agents operating in this dir

Conventions and entry points for any agent (Claude, hermes, etc.) doing
troubleshooting, sizing, or making changes to the LLM stack on hopper.

- **Triaging a live issue?** Read `RUNBOOK.md` first — symptom → fix table,
  health-check sequence, common operations.
- **Day-to-day human ops** (model config, common commands): see `README.md`.
- This file: config layout, log locations, sizing conventions, change rules.

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

## Shared binary locations (multi-user)

Both `miguel` and `bolotas` can manage these via `adm` group (setgid 2775):

```
/srv/selfhost/llm/llama.cpp/current    → latest llama.cpp release (b9189+)
/srv/selfhost/llm/llama-swap/current   → v211
```

**Update llama.cpp:** `bash /srv/selfhost/llm/update.sh` (downloads + symlinks)
**Switch version:** `ln -sfn /srv/selfhost/llm/llama.cpp/llama-XXXX /srv/selfhost/llm/llama.cpp/current` + restart service
**Update llama-swap:** download from <https://github.com/pmb659/llama-swap/releases>

## Where the configuration lives

```
/srv/selfhost/llm/
├── README.md              ← user-facing ops manual
├── AGENTS.md              ← this file
├── llama-swap.yaml        ← model definitions (source of truth)
├── llama-swap.service     ← systemd --user unit (port 8090)
├── enable-mtp-for-qwen.md ← MTP setup notes + sampler params + caveats
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

   Example output for the old PTQ gemma-31b at `-c 131072` (validated
   2026-05-07; that entry was replaced by gemma-31b-qat on 2026-08-07, but the
   output format is unchanged):
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

## Active features

- **MTP for Qwen 3.6** (since 2026-05-16). PR #22673 merged on
  llama.cpp b9186; the flag is **`--spec-type draft-mtp`** (note: not
  `--spec-type mtp` as in the original PR draft — renamed pre-merge on
  2026-05-13). Available on the `qwen-27b-mtp` and `qwen-35b-moe-mtp`
  llama-swap entries; the non-MTP counterparts stay around for A/B.
  Hard constraint from upstream: `--parallel 1` is mandatory; we
  already set that everywhere. Prefill is slightly slower, decode is
  ~1.85–2× faster at ~75–93% draft acceptance on our smoke tests.
  Full setup notes + sampler params: see `enable-mtp-for-qwen.md`.

- **New in b9910+**: `--spec-draft-backend-sampling` (on by default) —
  offloads draft token sampling to GPU backend instead of CPU.
  Potential MTP decode speedup.

- **New in b10000+**: `--spec-type draft-dflash` — Flash-decoding draft
  speculative type. Worth testing against `draft-mtp` for Qwen 3.6.

## llama.cpp upgrade notes

Currently on b9189. b10025 downloaded and ready at
`/srv/selfhost/llm/llama.cpp/llama-b10025/`. Key changes:

- `--spec-draft-n-max` default: 16→3 (we override to 5, unaffected)
- `--spec-draft-p-min` default: 0.75→0.00 (less greedy)
- Draft model fit fix (b9910) — MTP stability
- Prompt cache RAM hard limit (b9908)
- Prompt cache refactor (b10011)

See wiki: `/srv/selfhost/wiki/llm/todos/llm-stack-todos.md`

## Future work to track

- **Multi-spec chains** (<https://github.com/ggml-org/llama.cpp/pull/22546>) —
  "spec: allow multiple spec types (chains of speculators)". Lets you
  combine n-gram cache + draft model + MTP and pick best at runtime.
  Not yet merged as of 2026-05-16.

## Conventions

- All infra is YAGNI + reproducible + documented. Changes go into the
  yaml or the unit, with a comment explaining **why** (not what).
- Inline comments in `llama-swap.yaml` show the per-model VRAM forecast.
  Update them when ctx or flags change.
- Empirical tests (cold load + dashboard) confirm the forecast before
  closing out a fix.
