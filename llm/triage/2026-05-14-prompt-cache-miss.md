# Prompt Cache Miss — Full KV Re-processing on Every Turn

**Date:** 2026-05-14  
**Status:** open / under investigation  
**Symptom:** llama-server logs show `forcing full prompt re-processing due to lack of cache data`
on requests with 90k+ token conversations, causing 5-10 minute stalls.

## Observed log pattern

```
update_slots: id  0 | task 2003 | n_past = 1, slot.prompt.tokens.size() = 95650
update_slots: id  0 | task 2003 | Checking checkpoint with [94641, 94641] against 1...
update_slots: id  0 | task 2003 | Checking checkpoint with [94129, 94129] against 1...
update_slots: id  0 | task 2003 | forcing full prompt re-processing due to lack of cache data (likel...
update_slots: id  0 | task 2003 | erased invalidated context checkpoint (pos_min = 94129 ...)
update_slots: id  0 | task 2003 | erased invalidated context checkpoint (pos_min = 94641 ...)
update_slots: id  0 | task 2003 | n_tokens = 0, memory_seq_rm [0, end)
```

Key observation: `n_past = 1` while the conversation has 95650 tokens.
Checkpoints exist at positions ~94k in host RAM (from `--cache-ram 2048`) but are
invalidated because n_past=1 — they're "ahead" of the current VRAM cache state.

## Root cause hypotheses

### H1 (most likely): VRAM eviction corrupts KV cache
Host memory pressure (known issue, multiple OOMs) causes amdgpu TTM to evict VRAM
pages that hold the KV cache, even with `GGML_VK_ALLOW_SYSMEM_FALLBACK=0`.
The flag prevents *new allocations* from spilling to GTT, but doesn't protect
*existing VRAM pages* from being evicted under extreme kernel pressure.
llama-server detects invalid VRAM state, resets the slot to n_past=1.
Host-RAM checkpoints survive (they're not in VRAM) but are now useless.

### H2: llama-swap restarts llama-server (health check failure)
If llama-server becomes unresponsive (OOM-kill, GPU hang, timeout), llama-swap
kills and restarts it. New process starts with empty KV cache (n_past=0 or 1).
BUT: in this case host-RAM checkpoints would also be gone (process restart).
The fact that checkpoints DO exist argues against a full restart — unless
llama-swap persists checkpoint data across restarts (unlikely).

### H3: Slot reset due to cancelled/timed-out generation
If hermes times out mid-generation and disconnects, llama.cpp may roll the slot
back to a previous stable state. If the rollback overshoots (goes to n_past=1),
subsequent requests see an empty cache with stale checkpoints.

## What to investigate

1. **Correlate with restarts**: `journalctl -u llama-swap --since today | grep -E "starting|health|restart|kill"` 
   — if H2, timestamps before the cache-miss events should show a restart.

2. **GTT eviction events**: `dmesg | grep -i "amdgpu\|ttm\|evict"` right after the incident.
   Also check `cat /proc/$(pgrep llama-server)/status | grep VmRSS` during long sessions.

3. **Slot state before/after**: Add a monitoring loop:
   ```bash
   while true; do
     curl -s http://127.0.0.1:9005/slots | python3 -c \
       "import sys,json; s=json.load(sys.stdin)[0]; print(s['n_past'], s['is_processing'])"
     sleep 10
   done
   ```
   If n_past drops suddenly between requests without a restart, that's H1 or H3.

4. **llama-server metrics**: once `--metrics` is enabled (task 1 in parent issue),
   watch `llamacpp_kv_cache_usage_ratio` in Grafana for sudden drops.

## Why it matters

At 240 tok/s prefill (Vulkan/R9700), processing 95k tokens = ~7 minutes.
hermes default timeout is much shorter → cascading 500/502 errors, slot locked
`is_processing=true`, manual `/unload` required. Effectively unusable for long sessions.

## Mitigation (while root cause unknown)

- Keep active conversations under 50k tokens in hermes.
- Run `triage/status.sh` periodically; unload on first sign of n_past stagnation.
- Consider `--ctx-size 65536` for all dense models (forces hermes to summarize earlier).

## Open questions

- Does llama.cpp have any mechanism to detect VRAM corruption and recover gracefully?
- Does `GGML_VK_ENABLE_MEMORY_PRIORITY=1` actually protect the KV cache pages,
  or just new allocation preference?
- Is there a way to persist KV cache to disk (like llama-server's `--slot-save-path`)
  so a restart can recover from where it left off?
