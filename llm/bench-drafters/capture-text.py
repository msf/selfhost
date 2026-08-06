"""Capture full output text for two arms so the greedy divergence can be read.

The hash gate in run-bench.py answers "is it identical" (no) but not "is it
equivalent" (unknown). Bitwise equality is the wrong bar for speculative
decoding on a GPU: the target verifies drafts in batches, so the matmul
reduction order differs from single-token decode, and an occasional argmax flip
is expected. What matters is whether the text is still correct work.
"""

import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from trace import MAX_TOKENS, TURN_LABELS, build  # noqa: E402

OUT = Path(__file__).parent / "results" / "text"
TURNS = [2, 4]  # diff and summary: short, structured, easy to compare by eye


def call(arm, messages, max_tokens):
    req = urllib.request.Request(
        "http://127.0.0.1:8090/v1/chat/completions",
        data=json.dumps({
            "model": arm, "messages": messages, "max_tokens": max_tokens,
            "stream": False, "temperature": 0.0, "top_k": 1, "top_p": 1.0, "seed": 42,
        }).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=1800) as r:
        m = json.load(r)["choices"][0]["message"]
    return (m.get("reasoning_content") or ""), (m.get("content") or "")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    requests = build()
    for arm in sys.argv[1:]:
        for i in TURNS:
            reasoning, content = call(arm, requests[i], MAX_TOKENS[i])
            p = OUT / f"{TURN_LABELS[i]}.{arm}.txt"
            p.write_text(f"===== REASONING =====\n{reasoning}\n\n===== CONTENT =====\n{content}\n")
            print(f"{p}  reasoning={len(reasoning)}c content={len(content)}c", flush=True)


if __name__ == "__main__":
    main()
