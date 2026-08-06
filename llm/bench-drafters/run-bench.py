"""Run the drafter bench: one fixed agentic trace against each spec-decoding arm.

Usage:
    python3 run-bench.py                  # all arms
    python3 run-bench.py bench-mtp ...    # named arms only
    python3 run-bench.py --smoke          # turn 1 only, every arm — cheap load test

Writes results/<timestamp>.json plus a markdown table on stdout.

Deliberate choices:
  - Greedy pass (temp 0, top_k 1) is the correctness gate, not a speed run.
    Speculative decoding is output-preserving by construction, so any arm whose
    greedy output differs from the no-draft baseline has a bug and is
    disqualified regardless of how fast it went.
  - Sampled pass uses the live entry's real sampler settings, so the acceptance
    rate reflects deployment rather than a best case.
  - Wall time is measured client-side. Server-reported tok/s excludes queueing
    and detokenisation; end-to-end latency is what agentic work actually pays.
"""

import argparse
import hashlib
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from trace import MAX_TOKENS, TURN_LABELS, build  # noqa: E402

SWAP = "http://127.0.0.1:8090"
HERE = Path(__file__).parent
RESULTS = HERE / "results"

ARMS = [
    "bench-baseline",
    "bench-mtp",
    "bench-dflash-bf16",
    "bench-dflash-q8",
    "bench-eagle3-f16",
    "bench-eagle3-q4",
]

GREEDY = {"temperature": 0.0, "top_k": 1, "top_p": 1.0, "seed": 42}
SAMPLED = {"temperature": 0.7, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "seed": 42}


def post(path, payload, timeout=1800):
    req = urllib.request.Request(
        f"{SWAP}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get_text(path, timeout=30):
    try:
        with urllib.request.urlopen(f"{SWAP}{path}", timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.URLError:
        return ""


def vram_gib():
    """Read VRAM from the driver. Never calculate it -- see lessons.md."""
    try:
        out = subprocess.run(
            ["rocm-smi", "--showmeminfo", "vram"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (subprocess.SubprocessError, FileNotFoundError):
        return None
    for line in out.splitlines():
        if "GPU[0]" in line and "Used" in line:
            return round(int(line.split()[-1]) / 1024**3, 2)
    return None


def unload():
    get_text("/unload")
    for _ in range(60):
        time.sleep(1)
        v = vram_gib()
        if v is not None and v < 2.0:
            return v
    return vram_gib()


def run_turn(arm, messages, max_tokens, params):
    payload = {"model": arm, "messages": messages,
               "max_tokens": max_tokens, "stream": False, **params}
    t0 = time.monotonic()
    resp = post("/v1/chat/completions", payload)
    wall = time.monotonic() - t0

    msg = resp["choices"][0]["message"]
    content = msg.get("content") or ""
    # Qwen3.6 is a thinking model and llama-server splits the <think> block out
    # into reasoning_content. Hashing content alone made every arm look
    # identical during the 2026-08-06 smoke run: turns truncated at max_tokens
    # while still thinking, so content was "" everywhere and the output-identity
    # gate compared empty to empty. Both halves go into the hash.
    reasoning = msg.get("reasoning_content") or ""
    usage = resp.get("usage") or {}
    return {
        "wall_s": round(wall, 3),
        "completion_tokens": usage.get("completion_tokens"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "timings": resp.get("timings"),
        "sha256": hashlib.sha256((reasoning + "\x00" + content).encode()).hexdigest()[:16],
        "chars": len(content),
        "reasoning_chars": len(reasoning),
        "finish_reason": resp["choices"][0].get("finish_reason"),
    }


def run_pass(arm, requests, params, label, turns):
    out = []
    for i in turns:
        r = run_turn(arm, requests[i], MAX_TOKENS[i], params)
        r["turn"] = TURN_LABELS[i]
        out.append(r)
        tok = r["completion_tokens"]
        rate = f"{tok / r['wall_s']:.1f} tok/s" if tok and r["wall_s"] else "?"
        trunc = " TRUNC" if r["finish_reason"] == "length" else ""
        print(f"    {label:8s} {TURN_LABELS[i]:14s} {r['wall_s']:7.2f}s  "
              f"{str(tok):>5} tok  {rate:>12}  {r['sha256']}{trunc}", flush=True)
    return out


def bench_arm(arm, requests, turns):
    print(f"\n=== {arm} ===", flush=True)
    before = unload()
    print(f"    card cleared to {before} GiB", flush=True)

    log_mark = len(get_text("/logs/upstream"))

    t0 = time.monotonic()
    try:
        warm = run_turn(arm, requests[0], 16, GREEDY)
    except Exception as e:  # noqa: BLE001 - an arm that will not load is a result
        print(f"    LOAD FAILED: {type(e).__name__}: {e}", flush=True)
        return {"arm": arm, "error": f"{type(e).__name__}: {e}",
                "upstream_log": get_text("/logs/upstream")[log_mark:][-4000:]}
    load_s = time.monotonic() - t0
    loaded = vram_gib()
    print(f"    loaded in {load_s:.1f}s (incl. one warm request), VRAM {loaded} GiB",
          flush=True)

    if loaded is not None and loaded > 30.5:
        print("    WARNING: <1.4 GiB headroom -- OOM risk on this host", flush=True)

    res = {
        "arm": arm,
        "load_s": round(load_s, 1),
        "vram_gib": loaded,
        "warm_sha": warm["sha256"],
    }
    # A failure partway through a pass must not abort the remaining arms. On
    # 2026-08-06 an HTTP 502 on one arm propagated and killed the whole run,
    # losing the two arms that had not been reached yet.
    for name, params in (("greedy", GREEDY), ("sampled", SAMPLED)):
        try:
            res[name] = run_pass(arm, requests, params, name, turns)
        except Exception as e:  # noqa: BLE001
            print(f"    {name} FAILED: {type(e).__name__}: {e}", flush=True)
            res[name] = res.get(name, [])
            res.setdefault("error", f"{name}: {type(e).__name__}: {e}")
    res["upstream_log"] = get_text("/logs/upstream")[log_mark:][-20000:]
    return res


def summarise(results):
    base = next((r for r in results if r["arm"] == "bench-baseline" and r.get("greedy")), None)
    base_total = sum(t["wall_s"] for t in base["greedy"]) if base else None
    base_hashes = [t["sha256"] for t in base["greedy"]] if base else None

    lines = [
        "| arm | VRAM GiB | load s | greedy total s | vs baseline | sampled total s | output match |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in results:
        greedy, sampled = r.get("greedy") or [], r.get("sampled") or []
        if not greedy:
            note = (r.get("error") or "no data")[:44]
            lines.append(f"| {r['arm']} | {r.get('vram_gib', '—')} | "
                         f"{r.get('load_s', '—')} | FAILED | — | — | {note} |")
            continue
        g = sum(t["wall_s"] for t in greedy)
        s = sum(t["wall_s"] for t in sampled) if sampled else None
        speedup = f"{base_total / g:.2f}x" if base_total else "—"
        # Only comparable when both passes covered the same turns.
        if base_hashes and len(base_hashes) == len(greedy):
            match = "yes" if [t["sha256"] for t in greedy] == base_hashes else "**NO**"
        else:
            match = "—"
        lines.append(f"| {r['arm']} | {r['vram_gib']} | {r['load_s']} | {g:.1f} | "
                     f"{speedup} | {f'{s:.1f}' if s else '—'} | {match} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("arms", nargs="*", default=None)
    ap.add_argument("--smoke", action="store_true",
                    help="turn 1 only -- verifies every arm loads and drafts")
    args = ap.parse_args()

    arms = args.arms or ARMS
    turns = [0] if args.smoke else list(range(len(TURN_LABELS)))
    requests = build()

    RESULTS.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = RESULTS / f"{'smoke' if args.smoke else 'bench'}-{stamp}.json"

    results = []
    for arm in arms:
        results.append(bench_arm(arm, requests, turns))
        out_path.write_text(json.dumps(results, indent=2))  # checkpoint after each arm

    print(f"\n{summarise(results)}\n\nraw: {out_path}")


if __name__ == "__main__":
    main()
