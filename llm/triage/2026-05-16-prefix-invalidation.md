# Prompt-cache invalidation: prefix divergence, not cache loss

**Date:** 2026-05-16
**Status:** **RESOLVED 2026-05-17** — root cause confirmed in Qwen 3.6 chat
template; fix applied to all qwen3.6 entries via `preserve_thinking=true`.
See "Resolution" section below.
**Symptom:** `forcing full prompt re-processing due to lack of cache data` fires
mid-session, costing minutes of prefill on R9700/Vulkan. Happens across
models (gemma, qwen 27b, qwen 35b moe — confirmed on both `qwen-27b-mtp`
and earlier non-MTP runs).

Supersedes — but does **not replace** — `2026-05-14-prompt-cache-miss.md`.
That doc focused on `n_past = 1` (full cache loss). This spike found a
second, more frequent pattern: small `n_past` deltas (~500–6000 tokens)
where the cache is still there but the *prefix doesn't match*.

## What the logs actually say

Example from a live `qwen-27b-mtp` session (2026-05-16, 23:40):

```
slot update_slots: id 0 | task 655 | n_past = 55575,
    slot.prompt.tokens.size() = 61424, seq_id = 0, pos_min = 61423, n_swa = 0
slot update_slots: id 0 | task 655 | Checking checkpoint with [60998, 60998] against 55575...
slot update_slots: id 0 | task 655 | Checking checkpoint with [60873, 60873] against 55575...
slot update_slots: id 0 | task 655 | forcing full prompt re-processing due to
    lack of cache data (likely due to SWA or hybrid/recurrent memory,
    see https://github.com/ggml-org/llama.cpp/pull/13194#issuecomment-2868343055)
slot update_slots: id 0 | task 655 | erased invalidated context checkpoint
    (pos_min = 60873, ... size = 277.113 MiB)
slot update_slots: id 0 | task 655 | erased invalidated context checkpoint
    (pos_min = 60998, ... size = 277.374 MiB)
```

The PR-13194 comment that llama-server points us at is about **SWA / hybrid
memory**. `n_swa = 0` here — qwen-27b is dense, no SWA. So the message text
is misleading. The actual reason the message fires is:

> client says "my prefix is N tokens long" → llama-server compares the first N
> tokens it has cached against the client's N → mismatch → force full
> re-process.

Confirmed across 5 days of `journalctl --user -u llama-swap` (data captured
during the spike):

| Pattern | Description                                          | Cost            | Bug? |
| ------- | ---------------------------------------------------- | --------------- | ---- |
| **A**   | `n_past = 1–150`, `slot.size` huge (10k–95k)         | full re-process | No — expected: client opened a fresh conversation, slot still cached the old one. |
| **B**   | `n_past` ≈ `slot.size` − **500 to 6000**, mid-session| full re-process | **Yes — this is the bug.** |
| **C**   | `n_past` ≈ `slot.size` − ≤ 300                       | restored from checkpoint | No — works as designed. |

Pattern B is what's hurting us. Frequency by day:

```
May 09:  4   May 10: 45   May 11: 25   May 12: 11
May 14: 18   May 15:  4   May 16: 14
```

A few of those are Pattern A (session switch). Most of the in-band ones are B.

## Leading hypothesis: thinking-content stripping

The recurring 500–6000 token delta band matches the size of a Qwen 3.6
`<think>...</think>` block (`--reasoning-budget 8192` caps it at 8k).

Working theory:

1. Turn N: client sends history H → llama-server emits assistant reply
   `<think>X</think><answer>Y</answer>` → slot caches tokens for *both* X
   and Y. `slot.size = len(H) + len(X) + len(Y)`.
2. Hermes stores **only Y** in conversation history (thinking is rendered to
   the user but not kept as part of the assistant turn).
3. Turn N+1: client builds the next prompt as `H + Y + new_user_msg`. The
   client-reported `n_past = len(H) + len(Y) + len(new_user_msg)` — but
   the slot cache has `H + X + Y` at the same positions. The X tokens are
   at positions that *should* contain Y tokens.
4. llama-server compares; tokens differ; force full re-process.

This is consistent with:
- `n_swa = 0` (not an SWA artefact).
- The slot is *not* being killed/restarted (no `load_model` in the gap).
- Deltas cluster in the 500–6000 range (typical reasoning-block size).
- Happens on every reasoning-capable model (qwen 3.6 family), regardless
  of MTP on/off.

## What rules out the older hypotheses

The 2026-05-14 doc proposed VRAM eviction (H1), llama-swap restart (H2),
and rollback overshoot (H3). Evidence against each for Pattern B:

- **Not H1/H2**: checkpoints in host RAM are *erased explicitly* with their
  original sizes (62 / 277 MiB), then full re-process starts. The slot
  is alive, no `load_model` between turns.
- **Not H3**: deltas are *positive* (cache has more than client), not negative.

H1 still likely explains the older `n_past = 1` events (Pattern A or the
very-cold subset of A). Two bugs in one logfile; this spike addresses B.

## Compression: ruled out for now

Hermes config has `compression.enabled: true, threshold: 0.7,
protect_last_n: 20`. Threshold tripping happens at ~92k tokens
(`0.7 × 131072`). Most Pattern B events here occur at slot sizes
**4k–60k**, well below the threshold. So in-flight compression isn't the
cause of the current event stream, but it could amplify the same class
of issue in long sessions — keep on the radar.

## Next-session investigation plan

These are the concrete steps to confirm or refute the thinking-strip
hypothesis. Keep the spike small.

1. **Capture one offending pair end-to-end.** Pin `qwen-27b-mtp`, run a
   short reasoning prompt, dump:
   - request body sent to llama-server (`curl ... -v` or
     `tcpdump -i lo port 9005`) — specifically the `messages` array.
   - llama-server response body, look for `reasoning_content` vs
     `content`.
   - next turn's request body. Diff the assistant message in turn N+1
     against the response from turn N. If turn N+1 omits the
     `reasoning_content`, hypothesis confirmed.

2. **Confirm via llama-server flag.** Try `--reasoning-format none` (or
   whatever flag stops llama-server from emitting `<think>` blocks at
   all). If Pattern B disappears, it's the thinking-strip.

3. **Check hermes message storage.** Locate where hermes stores assistant
   turns (likely under `/home/bolotas/.hermes/`). Inspect whether the
   `reasoning_content` field is kept. If not, that's the root cause on
   the client side.

4. **Read the PR-13194 comment** referenced in the warning text — even
   though our case isn't SWA, the comment may describe llama-server's
   prefix-match logic and confirm the truncation behaviour.

## Possible mitigations (don't apply yet — confirm cause first)

- Disable thinking for hermes sessions: send
  `--chat-template-kwargs '{"enable_thinking":false}'` (already wired on
  `gemma-31b-spec`). Cheapest fix, but loses the reasoning benefit.
- Have hermes echo the prior turn's `reasoning_content` back in the
  history so the prefix matches.
- Use a llama-server flag that suppresses `<think>` blocks from the
  response so hermes has nothing to strip.

## Why it matters

At ~240 tok/s prefill on R9700, every Pattern B event burns
~`slot.size / 240` seconds. A 60k-token slot = 4 min of wasted prefill
per occurrence, ~14 occurrences/day = ~1 h/day of pure overhead, and
each event blocks the slot so hermes turns appear to "hang." The decode
speedup from MTP (~2×) is dwarfed by repeated full prefills.

## Resolution (2026-05-17)

The thinking-strip hypothesis was wrong about *where* the strip happens.
It's not hermes that drops the reasoning — hermes correctly persists
`reasoning_content` (run_agent.py:9028) and replays it on the wire
(run_agent.py:9191 `_copy_reasoning_content_for_api`). The strip is in
**Qwen 3.6's own chat template** (`chat_template.j2` lines 76–107):

```jinja
{# walk messages backwards, find the most recent non-tool-response user
   message; record its index as ns.last_query_index #}
{%- set ns = namespace(multi_step_tool=true,
                       last_query_index=messages|length - 1) %}
...
{# in the forward render loop, for assistant messages: #}
{%- if (preserve_thinking is defined and preserve_thinking is true)
       or (loop.index0 > ns.last_query_index) %}
    {{- '<|im_start|>' + message.role + '\n<think>\n'
        + reasoning_content + '\n</think>\n\n' + content }}
{%- else %}
    {{- '<|im_start|>' + message.role + '\n' + content }}
{%- endif %}
```

So historical assistant turns (those at `loop.index0 <= last_query_index`,
i.e. older than the most recent user message) render **without** the
`<think>` block. The slot's KV cache still holds the thinking tokens
generated last turn → prefix mismatch → full re-prefill.

This was true regardless of MTP, regardless of provider, regardless of
hermes — it is template behaviour. The PR-13194 warning text the server
prints is misleading for this case (it mentions SWA but the bug fires
for `n_swa = 0` too; SWA is a different cache-loss path).

### Fix

Pass `preserve_thinking=true` to the chat template. This overrides the
strip-on-history clause and keeps `<think>` blocks on every assistant
turn. The rendered prompt then matches the slot cache verbatim.

Applied via the env-var form (llama-swap's arg-array shell-less spawn
strips outer quotes on `--chat-template-kwargs`, same problem the
`gemma-31b-spec` entry already documents):

```yaml
env:
  - 'LLAMA_CHAT_TEMPLATE_KWARGS={"preserve_thinking":true}'
```

Applied to all 4 Qwen 3.6 entries in `llm/llama-swap.yaml`:
`qwen-27b`, `qwen-27b-mtp`, `qwen-35b-moe`, `qwen-35b-moe-mtp`.

Also lowered `--temp 1.0 → 0.7` on the two MTP entries (the only ones
with explicit sampler overrides) — for a tool-using agent workload,
1.0 increases the chance of malformed tool arguments and off-target
reasoning. 0.7 + `top-p 0.95` + `top-k 20` is a more conservative
posterior for hermes; clients can still override per-request.

### Validation (2026-05-17, qwen-35b-moe-mtp testbed)

Clean 2-turn probe (`/tmp/two_turn_test.py`), same prompts, fresh slot:

| metric                       | baseline | preserve_thinking | delta  |
| ---------------------------- | -------- | ----------------- | ------ |
| turn 1 completion tokens     |      741 |               784 |     ~= |
| turn 2 prompt tokens         |      223 |               891 |   +4 × |
| turn 2 cached_tokens         |    **0** |           **847** | +inf   |
| turn 2 new tokens to prefill |      223 |            **44** |  -5 ×  |
| turn 2 wall time             |   60.5 s |          **12.1 s** | -5 ×  |
| `forcing full prompt re-processing` in slot log | ✓ | ✗ | gone |

The 4× larger prompt is the reasoning history now being preserved
(~3 KiB chars ≈ ~750 tokens added). Despite that, total wall time
dropped 5× because the prompt matches the cache and only the new user
message (44 tokens) needs to be prefilled.

### Trade-offs and follow-ups

- **Context growth.** Every turn now carries the full reasoning trace.
  At `--reasoning-budget 8192` (capped), worst-case ~8 K tokens of
  thinking per turn; typical ~2–4 K. Hermes' `compression.threshold: 0.7`
  will trip earlier — that's the intended bound, but worth watching on
  long sessions whether the compressor handles `reasoning_content`
  cleanly (it should — compression operates on stored messages, and
  `reasoning_content` is just a field). Track in next-week observation.
- **Whitespace edge cases.** Hermes does `.strip()` on `reasoning_content`
  at write time (`run_agent.py:9000`). If the model emitted specific
  leading/trailing whitespace inside the `<think>` block, there could be
  a residual fine-grained mismatch. The validation run didn't show any
  (cache hit rate was 95 %), but if Pattern B reappears intermittently
  this is the next place to look.
- **Non-Qwen reasoning models.** This fix is Qwen 3.6 template-specific.
  If we ever run another `<think>`-emitting model (DeepSeek, Kimi K2,
  Minimax M2.7, GLM 4.6), check that model's chat template for an
  equivalent kwarg before assuming it inherits the fix.
- **Gemma 4 SWA models** are untouched — they use the SWA checkpoint
  mechanism which we already fully disabled (`-cpent -1`, see lessons.md
  2026-05-07). Different bug, different fix.

## Pointers

- This file: `llm/triage/2026-05-16-prefix-invalidation.md`
- Prior doc (different pattern): `llm/triage/2026-05-14-prompt-cache-miss.md`
- Live log: `journalctl --user -u llama-swap | grep -E 'forcing full|restored context|erased invalidated'`
- Hermes config (copy for inspection): `/srv/selfhost/llm/hermes-config.yaml`
  (canonical at `/home/bolotas/.hermes/config.yaml`)
- Relevant llama.cpp PRs:
  - <https://github.com/ggml-org/llama.cpp/pull/13194> — SWA prompt-cache logic
  - <https://github.com/ggml-org/llama.cpp/pull/16391> — `--cache-ram` prompt cache
