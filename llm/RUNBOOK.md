# RUNBOOK.md — operate / investigate / fix the local LLM stack

Entry point for a new session arriving to debug "hermes is slow", "llama-swap
is hung", "qwen restarted", or anything similar. Read this *before* touching
the yaml.

Companion docs:
- `AGENTS.md` — config layout, log locations, sizing, conventions.
- `lessons.md` (in `~/.claude/`) — accumulated rules from prior incidents.
- `triage/` — dated incident reports + diagnostic scripts.

## Stack at a glance

```
hermes (user bolotas, /srv/selfhost/hermes/, venv) ──┐
                                                     │ chat completions
                                                     ▼
                           llama-swap (user miguel, port 8090)
                                  │  spawns one child at a time
                                  ▼
                           llama-server (Vulkan/RADV → R9700, 32 GiB VRAM)
```

- llama-swap binds **127.0.0.1:8090** (proxy + admin endpoints).
- llama-server child listens on **127.0.0.1:9005** (port assigned per child).
- Single GPU pin via `GGML_VK_VISIBLE_DEVICES=1` in the systemd unit.
- Only **one model loaded at a time** (group `all`, swap=true, exclusive=true).
- Hermes config: `/home/bolotas/.hermes/config.yaml` (copy at
  `/srv/selfhost/llm/hermes-config.yaml`). Default model: `qwen-35b-moe`.

## First 60 seconds: health snapshot

```bash
bash /srv/selfhost/llm/triage/status.sh        # model / VRAM / GTT / RAM / swap
curl -s http://127.0.0.1:8090/running          # which model is up
curl -s http://127.0.0.1:9005/metrics \
  | grep -E 'prompt_tokens_seconds|predicted_tokens_seconds|requests_'  # live throughput
```

If something looks off, capture the slot timeline:

```bash
timeout 3 curl -sN http://127.0.0.1:8090/logs/stream/<MODEL> \
  | grep -E 'launch_slot_|n_past|forcing|restored|erased|print_timing' | tail -50
```

The SSE log replays from the model's last load, so this works any time.
**llama-server child stdout is NOT in journalctl** — it goes through
llama-swap's pipe and out the SSE endpoint only.

## Symptom → diagnosis → fix

### "Hermes hangs for several minutes on a single turn"

Check `n_decoded` in `print_timing` lines. If it keeps incrementing past
~8k tokens, the model is in **runaway generation** (post-thinking content
loop, or thinking that escaped the budget cap).

```bash
timeout 3 curl -sN http://127.0.0.1:8090/logs/stream/<MODEL> \
  | grep print_timing | tail -5    # is n_decoded still climbing?
```

Fix: `curl http://127.0.0.1:8090/unload` (evicts the model, clears the
slot). Hermes' next request triggers a cold reload (~30–90 s). **Don't
restart the systemd unit** — that's slower and drops state for nothing.

If `requests_deferred ≥ 1` in metrics, hermes' auxiliaries (compression,
session_search, vision) are queued behind the stuck slot — same fix.

### "Hermes prefill takes 1–3 min before a reply starts" (one-shot)

Look for `forcing full prompt re-processing` immediately after
`launch_slot_`. Two patterns:

| `n_past` | `slot.size` | Meaning | Action |
|----------|-------------|---------|--------|
| ≤ ~100 | huge | Pattern A — fresh session (different conv or hermes resumed a different chat). Expected one-time cost. | Wait; subsequent turns will hit cache. |
| `slot.size − 500..6000` | huge | **Was** Pattern B (Qwen `<think>` strip mismatch). Should be FIXED since 2026-05-17 via `preserve_thinking=true`. If you see it again, the env var didn't apply — verify llama-server started with `LLAMA_CHAT_TEMPLATE_KWARGS` set. | Check env, restart llama-swap if needed. |
| 1 | huge | Slot cache survived a model swap but client opened a brand-new chat. Same as Pattern A. | Wait. |

Reference: `triage/2026-05-16-prefix-invalidation.md` (root cause + the
chat-template excerpt that proves it).

### "Decode tok/s is half of normal"

Normal targets on R9700/Vulkan:
- gemma-31b-qat: ~56–65 tok/s with MTP (measured 2026-08-07; 25 tok/s without
  it, so a sudden drop to ~25 means the drafter failed to load — check the
  server log for `[spec]` warnings)
- qwen-27b dense: ~60–75 tok/s
- qwen-27b-mtp: ~80–120 tok/s (depends on draft acceptance)
- qwen-35b-moe (A3B): ~80–100 tok/s

If well below, in order of probability:

1. **Long context** — decode slows roughly linearly with KV size. At
   ~50k+ tokens, halving from peak is expected.
2. **GTT eviction (VRAM→host)** — check `cat /sys/class/drm/cardN/device/mem_info_gtt_used`
   (the card with non-zero VRAM use). If GTT > 1 GiB and growing, TTM is
   migrating weights to host RAM. See lessons.md 2026-05-07 (`--no-host`
   mitigation; structural fix is `amdgpu.gttsize=3072` via modprobe.d).
3. **Swap thrash** — `/proc/pressure/io` `avg10 > 10` means real disk
   stall. Likely host RAM pressure from llama-server's host buffers
   (should be near-zero with `--no-host`).
4. **Spec-decode acceptance dropped** — check `draft_n` vs
   `draft_n_accepted` in `print_timing`. If acceptance < 50%, draft is
   wasting work. Lower `--spec-draft-n-max` on the yaml entry.

### "Hermes errored 5xx after the model swapped"

`-watch-config` reloads on any yaml edit, killing the in-flight model.
If you (or anyone) modified `llama-swap.yaml` mid-request, hermes saw
the disconnect. Wait for the next cold load to finish, then resume.

```bash
journalctl --user -u llama-swap --since '5 min ago' | grep -E 'Configuration|exited'
```

### "Kernel OOM'd the host"

GTT growth bypasses the cgroup `MemoryMax`. Read
`triage/2026-05-07-oom-after-boot.md`. Short version: `--no-host` on every
big model + `GGML_VK_ALLOW_SYSMEM_FALLBACK=0` env (set in the systemd
unit) prevents the silent spill. If it still happens, the structural fix
is `options amdgpu gttsize=3072` in `/etc/modprobe.d/amdgpu.conf` + reboot.

## Common operations

```bash
# Evict the currently-loaded model (clears stuck slot, frees VRAM)
curl http://127.0.0.1:8090/unload

# Force a model to load (warms cache, triggers GGUF read from ZFS)
curl -s -m 300 http://127.0.0.1:8090/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"<MODEL>","messages":[{"role":"user","content":"OK"}],"max_tokens":4}'

# Live dashboard (cpu/mem/swap/gpu/vram/gtt — 1s tick)
/srv/selfhost/llm/triage/dashboard.sh

# Capture full state snapshot to a file (use BEFORE risky changes)
sh /srv/selfhost/llm/triage/snapshot.sh > /tmp/llm-$(date +%s).log

# Restart llama-swap (rare — prefer /unload first)
systemctl --user restart llama-swap

# Reload config without restart (llama-swap auto-watches the yaml;
# any edit to llama-swap.yaml triggers reload + child restart)
```

## Change-management rules

1. **Never edit `llama-swap.yaml` while hermes is mid-turn** — the
   auto-reload kills the in-flight model.
2. **Annotate every yaml change with WHY** (a one-line comment). Inline
   numbers (VRAM, ctx, tok/s) come from real `common_memory_breakdown_print`
   readings, not formulas.
3. **Test before commit:** smoke load + grep the SSE for
   `common_memory_breakdown_print` to confirm fit; for behavior changes,
   run a 2-turn probe (`/tmp/two_turn_test.py` template) and compare
   `prompt_tokens_details.cached_tokens` before/after.
4. **Never `git add -A`** — stage explicit paths.

## Active known-good config (as of 2026-05-17)

- All Qwen 3.6 entries: `LLAMA_CHAT_TEMPLATE_KWARGS={"preserve_thinking":true}`
  env. Eliminates Pattern B. See `triage/2026-05-16-prefix-invalidation.md`.
- MTP entries (`qwen-27b-mtp`, `qwen-35b-moe-mtp`): `--temp 0.7` (down
  from Unsloth's general default 1.0 — better for tool-using agents).
- All big models: `--no-host`, `--parallel 1`, `--reasoning-budget 8192`,
  `--no-mmap`. SWA models: checkpoints disabled (`-cpent -1
  --ctx-checkpoints 0 --cache-ram 0`). See lessons.md 2026-05-07.

## Pointers

- `AGENTS.md` — config/log/layout reference.
- `README.md` — user-facing ops manual.
- `triage/2026-05-07-oom-after-boot.md` — VRAM/GTT eviction deep-dive.
- `triage/2026-05-14-prompt-cache-miss.md` — Pattern A (full cache loss).
- `triage/2026-05-16-prefix-invalidation.md` — Pattern B (resolved).
- `triage/2026-05-08-speculative-decoding.md` — gemma-31b-spec setup
  (historical; that entry was removed 2026-08-07 in favour of Gemma 4 MTP).
- `enable-mtp-for-qwen.md` — MTP flags + caveats.
- `~/.claude/lessons.md` — cross-session rules accumulated from incidents.
