# Enable MTP for Qwen3.6 on hopper

## What MTP is, in one paragraph

Qwen3.6 models ship with an extra **Multi-Token Prediction** head trained
jointly with the main model. At decode time, llama.cpp uses that head as a
*draft model embedded in the same GGUF* — speculative decoding without a
second model file. Reported speedup is **1.4–2×** generation throughput at
unchanged quality. The MTP head adds tensors (~5–8% extra weight bytes) but
no extra KV cache.

## Sources

- Upstream guide: <https://unsloth.ai/docs/models/qwen3.6#mtp-guide>
- llama.cpp PR that merged MTP: <https://github.com/ggml-org/llama.cpp/pull/22673>
  (merged 2026-05-16). Cuts the older `--spec-type mtp` over to
  `--spec-type draft-mtp`.
- MTP-enabled GGUF repos on HF:
  - <https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF>
  - <https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF>

The non-MTP repos (`Qwen3.6-27B-GGUF`, `Qwen3.6-35B-A3B-GGUF`) do **not**
carry the MTP head and cannot be used with `--spec-type draft-mtp`.

## Requirements

| Component | Version |
| --- | --- |
| llama.cpp | b9186 or newer (PR #22673 merged on b9186) |
| Model file | An `*-MTP-GGUF` build, same quant as you'd otherwise use |

Verify with:

```bash
/home/miguel/.local/share/llama.cpp/current/llama-server --version
/home/miguel/.local/share/llama.cpp/current/llama-server --help \
  | grep -- '--spec-type'        # must list `draft-mtp`
```

## Flags

Minimum addition to a normal `llama-server` invocation:

```
--spec-type draft-mtp
--spec-draft-n-max <N>
```

`N` is the number of tokens the MTP head proposes per step.

- **N=2–3** is what the PR recommends (~75% acceptance, 1.85–2× decode).
- **N=6** is what the unsloth CLI example uses; unsloth's own text notes
  acceptance drops from 83% → 50% at N=4 on their workload, so 6 is on the
  optimistic side. Worth measuring per-workload before settling.

### Hard constraints from the PR

- **`--parallel 1` is mandatory.** MTP currently does not batch across slots.
  We already use `--parallel 1` everywhere — keep it.
- **Prompt processing gets a bit slower** (extra device→host embedding
  transfers). The win is on generation, not prefill.
- A non-MTP GGUF will fail to load when `draft-mtp` is requested. Keep MTP
  on a separate llama-swap entry — don't toggle in place.

## Sampler params (from unsloth)

Thinking mode (default for Qwen3.6):

| Use case | temp | top_p | top_k | min_p | presence_penalty |
| --- | --- | --- | --- | --- | --- |
| General | 1.0 | 0.95 | 20 | 0.0 | 1.5 |
| Precise coding | 0.6 | 0.95 | 20 | 0.0 | 0.0 |

Non-thinking mode (`--chat-template-kwargs '{"enable_thinking":false}'`):

| Use case | temp | top_p | top_k | min_p | presence_penalty |
| --- | --- | --- | --- | --- | --- |
| General | 0.7 | 0.8 | 20 | 0.0 | 1.5 |
| Reasoning | 1.0 | 0.95 | 20 | 0.0 | 1.5 |

Note: llama-server takes these as *defaults* (`--temp`, `--top-p`,
`--top-k`, `--min-p`, `--presence-penalty`). Clients (OpenAI-style payloads)
can still override per request.

## How this is wired up on hopper

- Models live under `/media/simple/llm/models/Qwen3.6-{27B,35B-A3B}-MTP/`.
- `llm/download-models.sh` pulls the MTP GGUFs alongside the non-MTP ones.
- `llm/llama-swap.yaml` has two extra entries:
  - `qwen-27b-mtp` (alias: `qwen-mtp`) — MTP-enabled, opt-in
  - `qwen-35b-moe-mtp` (alias: `qwen-moe-mtp`) — MTP-enabled, opt-in
- The existing `qwen-27b` and `qwen-35b-moe` entries are unchanged so we
  can A/B without touching production defaults.

## How to compare

Both entries serve the same UD-Q4_K_XL quant; flip the model name to A/B
identical prompts.

```bash
# baseline (no MTP)
curl -s http://127.0.0.1:8090/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen-27b","messages":[{"role":"user","content":"<prompt>"}],"max_tokens":512}' \
  | jq '.usage, .timings'

# MTP enabled
curl -s http://127.0.0.1:8090/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen-27b-mtp","messages":[{"role":"user","content":"<prompt>"}],"max_tokens":512}' \
  | jq '.usage, .timings'
```

Per llm/AGENTS.md, pull the full per-model load + perf log via the
llama-swap SSE stream:

```bash
timeout 3 curl -sN http://127.0.0.1:8090/logs/stream/qwen-27b-mtp \
  | grep -E 'spec|draft|accept|prompt eval time|eval time|tokens per second'
```

Look for the speculative decoding stats block — acceptance rate, drafted
tokens per step, accepted tokens per step. If acceptance is <50%, lower
`--spec-draft-n-max`; if it's 80%+, try raising it.

## Rollback

The MTP entries are additive. To disable, point clients back at `qwen-27b`
/ `qwen-35b-moe` (the non-MTP entries are untouched). Removing the MTP
entries from `llama-swap.yaml` requires a service restart.
