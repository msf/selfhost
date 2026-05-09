# llm — local LLM serving on hopper

`llama-swap` (port `8090`) fronts `llama-server` (llama.cpp / Vulkan / RADV) on the
Radeon AI PRO **R9700 (32 GiB)**. OpenAI-compatible API; one process per active
model, lazy-loaded on first request, evicted after `ttl`.

## Layout

```
/srv/selfhost/llm/
  llama-swap.yaml       # model definitions  (source of truth)
  llama-swap.service    # systemd --user unit (listens on 0.0.0.0:8090)
  llama-server.env      # legacy single-server env (kept for fallback)
  llama-server.service  # legacy single-server unit (disabled)
  install.sh            # bootstrap llama.cpp + llama-swap + first model
  update.sh             # pin to latest llama.cpp release
  bench.sh              # llama-bench sweep
  download-models.sh    # pull priority GGUF set to /media/simple/llm/models/
  zfs-arc.conf          # → /etc/modprobe.d/zfs.conf  (8 GiB ARC cap)
```

## Memory hygiene

A first run with a 22 GiB GGUF + the llama-swap default of "load on demand,
keep until ttl" pushed host RAM to a 25.4 GiB peak and triggered a kernel OOM.
The current config defends against that on **four** layers:

1. **`MemoryMax=24G`** on `llama-swap.service` — cgroup hard cap, systemd kills
   *the service* before the host panics. *Caveat:* GTT (host RAM mapped to
   the GPU by amdgpu) is **not** charged to the cgroup, so this alone does
   not protect against a Vulkan-allocator GTT spill — see #4.
2. **`--no-mmap`** on the four big models — file is read into a transient heap
   buffer, shipped to VRAM, freed. No 22 GiB pinned in the kernel page cache.
3. **Single group, `swap: true`, `exclusive: true`** — only one model loaded
   at a time across the whole instance.
4. **`GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1` + `GGML_VK_ALLOW_SYSMEM_FALLBACK=0`**
   — both required, both set in `llama-swap.service`'s `Environment=`. Without
   the second var, the Vulkan backend on RDNA3/4 + RADV silently routes the
   model to GTT (host RAM via amdgpu). On 2026-05-07 a boot OOM was caused by
   exactly this — see `triage/2026-05-07-oom-after-boot.md`.

System-wide companion: **`/etc/modprobe.d/zfs.conf` → ARC capped at 8 GiB**
(see `zfs-arc.conf` in this dir for the file + install instructions). ZFS ARC
defaults to ~half of system RAM, which conflicts with the llm RAM budget.

Binaries (user-space, versioned, symlinked via `current/`):
- `~/.local/share/llama.cpp/current/llama-server`
- `~/.local/share/llama-swap/current/llama-swap`

GGUFs at `/media/simple/llm/models/<model-dir>/` (ZFS dataset, 1.3 TiB free).

## Operations

```bash
systemctl --user status  llama-swap.service
systemctl --user restart llama-swap.service
journalctl  --user -u    llama-swap.service -f

# List all configured models
curl -s http://127.0.0.1:8090/v1/models | jq '.data[].id'

# Hit a specific model — llama-swap routes by the "model" field
curl -s http://127.0.0.1:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-31b","messages":[{"role":"user","content":"hi"}]}'
```

`-watch-config` is on, so editing `llama-swap.yaml` reloads without a service
restart.

## GPU pinning

Two Vulkan devices on hopper:

| Device   | PCI       | What       | VRAM     |
|----------|-----------|------------|----------|
| Vulkan0  | 03:00.0   | R9700 dGPU | 31.9 GiB |
| Vulkan1  | 12:00.0   | Phoenix2   | 16 GiB shared |

`llama-swap.service` sets `GGML_VK_VISIBLE_DEVICES=1` so only the R9700 is
visible to llama.cpp → it becomes `Vulkan0` → `-mg 0` in the per-model `cmd`.

The iGPU stays free for desktop / VAAPI / Immich ML.

## Models

See `llama-swap.yaml`. Defaults: `-fa on -ctk q8_0 -ctv q8_0` (flash-attn + KV
quantized to q8 — required to fit large contexts in VRAM).

| Name             | Class            | Quant        | ctx     |
|------------------|------------------|--------------|---------|
| `gemma-31b`      | Gemma 4 31B dense| `UD-Q5_K_XL` | 131072  |
| `qwen-27b`       | Qwen 3.6 27B dense| `UD-Q5_K_XL`| 131072  |
| `gemma-26b-moe`  | Gemma 4 26B-A4B  | `MXFP4_MOE`  | 131072  |
| `qwen-35b-moe`   | Qwen 3.6 35B-A3B | `MXFP4_MOE`  | 131072  |
| `gemma-e4b`      | Gemma 4 E4B      | `Q6_K_L`     | 32768   |
| `qwen-4b`        | Qwen3 4B         | `Q4_K_M`     | 32768   |

To push to 256K context: drop ctx-ladder profile or expect partial CPU offload
via `--override-tensor` for dense ~22 GB models.

## TODO

- Speculative decoding / MTP via draft model (gemma-e4b → gemma-31b, qwen-4b → qwen-27b) once the llama.cpp PR lands. Track upstream PRs.
- Vision: `--mmproj` from each model's `mmproj-F16.gguf` (already on disk).
- Caddy proxy at `llm.mfilipe.eu` (Tailscale-only).

## Methodology lineage

Benchmark notes from the Framework 13 era live in
`/srv/selfhost/blog/site/blogpost/AGENTS.md` (`reorg-llm-bench-files` branch on
the blog repo). They captured the Apr 2026 sweep across 11 models on the
laptop's 890M iGPU. The hopper R9700 setup here supersedes that.
