# LLM Stack Wiki

## Overview
- **Host**: hopper (Debian server)
- **GPU**: Radeon AI PRO R9700 (32GB VRAM) + Phoenix2 iGPU (16GB shared)
- **Runtime**: llama.cpp via Vulkan/RADV driver
- **Orchestrator**: llama-swap (port 8090) - lazy model loading, one model at a time
- **Models**: GGUF format on ZFS dataset at /media/simple/llm/models/

## Models (from llama-swap.yaml)

| Model | Type | Quant | Context | VRAM |
|-------|------|-------|---------|------|
| gemma-31b-qat | Gemma 4 dense 31B QAT + MTP | UD-Q4_K_XL | 131k | ~23.3 GiB |
| qwen-27b | Qwen 3.6 dense 27B | UD-Q5_K_XL | 131k | ~25 GiB |
| gemma-26b-moe | Gemma 4 26B-A4B | UD-Q6_K_XL | 131k | ~24.8 GiB |
| qwen-35b-moe | Qwen 3.6 35B-A3B | UD-Q5_K_XL | 131k | ~23 GiB |
| gemma-e4b | Gemma 4 E4B | Q6_K_L | 32k | ~8 GiB |
| qwen-4b | Qwen3 4B | Q4_K_M | 32k | ~4 GiB |

## Critical Config Details
- **Single group, exclusive=true**: Only one model loaded at a time
- **--no-mmap**: Big models read into transient buffer, shipped to VRAM, freed (no 22GB pinned in page cache)
- **--parallel 1**: Single slot per model
- **--reasoning-budget 8192**: Cap thinking tokens
- **KV cache**: q8_0 quantized (flash-attn + q8 required to fit large contexts)
- **SWA checkpoints**: Disabled on all models (caused OOM thrashing)

## Known Issues
1. **VRAM→GTT eviction**: Silent RAM consumption causing OOM. Mitigated by:
   - GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1
   - GGML_VK_ALLOW_SYSMEM_FALLBACK=0
   - GGML_VK_ENABLE_MEMORY_PRIORITY=1
2. **ZFS ARC**: Capped at 8GB via /etc/modprobe.d/zfs.conf
3. **Memory cgroup**: GTT is invisible to cgroup, MemoryMax=24G doesn't protect against GPU allocations

## Operations
```bash
# Status
systemctl --user status llama-swap.service

# List models
curl -s http://127.0.0.1:8090/v1/models | jq '.data[].id'

# Trigger cold load + read VRAM breakdown
curl -s -m 240 http://127.0.0.1:8090/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen-27b","messages":[{"role":"user","content":"OK"}],"max_tokens":4}' > /dev/null
timeout 3 curl -sN http://127.0.0.1:8090/logs/stream/qwen-27b | grep -E 'common_params_fit_impl|common_memory_breakdown_print'

# Live monitoring
/srv/selfhost/llm/triage/dashboard.sh

# State dump
sh /srv/selfhost/llm/triage/snapshot.sh > /tmp/llm-$(date +%s).log
```

## Directory Structure
```
/srv/selfhost/llm/
├── llama-swap.yaml       # Model definitions (source of truth)
├── llama-swap.service    # systemd --user unit
├── install.sh, update.sh, bench.sh
├── download-models.sh
├── zfs-arc.conf          # → /etc/modprobe.d/zfs.conf
├── README.md             # User-facing ops manual
├── AGENTS.md             # Agent guidance
└── triage/               # Incident docs + diagnostic scripts
    ├── dashboard.sh      # Live monitoring
    ├── snapshot.sh       # State dump
    ├── check-vram-after-load.sh
    ├── stress-vram-pinning.sh
    └── *.md              # Incident writeups
```

## Future Work
- Speculative decoding / MTP for Qwen 3.6 (waiting on upstream PRs)
- Vision: --mmproj support (mmproj-F16.gguf already on disk)
- Caddy proxy at llm.mfilipe.eu (Tailscale-only)
