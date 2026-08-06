"""Fixed agentic trace for the drafter bench.

Five turns shaped like real tool-using work: one big prefill, a structured
tool-call, a diff, a long code generation, a short summary.

The assistant turns in the history are CANNED, not fed back from the model.
Every arm therefore sees a byte-identical prompt on every turn, so the only
thing that varies between arms is generation. Feeding real replies back would
let the contexts diverge after turn 1 and make the wall-times incomparable.

Prefill material is upstream stable-diffusion.cpp at the commit our image-gen
Dockerfile pins (a8a91b2) — public code, so the trace is reproducible off this
machine.
"""

from pathlib import Path

SOURCE = Path("/srv/selfhost/stable-diffusion.cpp/src/detailer.cpp")

SYSTEM = (
    "You are a terse senior C++ engineer working in an agentic coding harness. "
    "When asked for a tool call, emit only JSON. When asked for a patch, emit "
    "only a unified diff. Do not explain unless asked."
)

# Canned assistant replies. Short and plausible; their only job is to occupy
# the history so later turns carry realistic accumulated context.
CANNED = [
    "The letterbox scaling path recomputes the aspect ratio after clamping, so "
    "a zero-height mask silently divides by zero in the resize helper.",
    '{"name":"read_file","arguments":{"path":"src/detailer.cpp","start":180,"end":240}}',
    "--- a/src/detailer.cpp\n+++ b/src/detailer.cpp\n@@\n-    float ar = w / h;\n+    if (h <= 0) return {};\n+    float ar = w / h;",
    "Added bounds checks on both axes and a regression test covering the "
    "degenerate mask case.",
]


def build():
    src = SOURCE.read_text(encoding="utf-8", errors="replace")

    turns = [
        # 1. big prefill — the shape agentic work actually has
        f"Here is a source file from stable-diffusion.cpp:\n\n```cpp\n{src}\n```\n\n"
        "Find the most likely latent bug in the letterbox/resize handling. "
        "Answer in at most five sentences.",
        # 2. structured emission — tool-call JSON, highly predictable tokens
        "Emit a single tool call, JSON only, that reads the 60 lines around the "
        "function you suspect. Use the schema "
        '{"name": "read_file", "arguments": {"path": ..., "start": ..., "end": ...}}.',
        # 3. diff — structured, format-constrained
        "Produce a minimal unified diff that fixes the bug. Diff only, no prose.",
        # 4. sustained decode — the long-generation case
        "Write a self-contained C++ unit test (no framework, just main() and "
        "asserts) that would have caught this bug. Include edge cases for zero "
        "width, zero height, and extreme aspect ratios.",
        # 5. cheap turn — short output, dominated by prefill of the history
        "Summarise what changed in one sentence.",
    ]

    # Turn N's request = system + all prior (user, canned assistant) pairs + turn N.
    requests = []
    messages = [{"role": "system", "content": SYSTEM}]
    for i, user in enumerate(turns):
        messages = messages + [{"role": "user", "content": user}]
        requests.append(list(messages))
        if i < len(CANNED):
            messages = messages + [{"role": "assistant", "content": CANNED[i]}]

    return requests


TURN_LABELS = ["big-prefill", "tool-call", "diff", "long-codegen", "summary"]

# Per-turn generation caps. Sized so Qwen3.6's <think> block does not eat the
# whole budget and leave the turn truncated before it produces an answer -- the
# thinking tokens are themselves a big part of what spec decoding has to draft,
# so they belong in the measurement rather than being cut off. Still bounded, so
# one runaway arm cannot distort the wall-clock comparison.
MAX_TOKENS = [2000, 1400, 1800, 3000, 1300]

if __name__ == "__main__":
    reqs = build()
    for label, msgs in zip(TURN_LABELS, reqs):
        chars = sum(len(m["content"]) for m in msgs)
        print(f"{label:14s} messages={len(msgs):2d}  ~{chars:7d} chars  ~{chars // 4:6d} tok (est)")
