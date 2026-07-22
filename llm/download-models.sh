#!/usr/bin/env bash
set -euo pipefail
# Sequential, resumable downloads of the priority GGUF set to /media/simple/llm/models/.
# Idempotent: skips files already present at expected size.

MODELS=/media/simple/llm/models
mkdir -p "$MODELS"

# repo|subdir|filename|expected_bytes
ITEMS=(
  "unsloth/gemma-4-31B-it-GGUF|gemma-4-31B-it|gemma-4-31B-it-UD-Q5_K_XL.gguf"
  "unsloth/gemma-4-31B-it-GGUF|gemma-4-31B-it|gemma-4-31B-it-UD-Q4_K_XL.gguf"
  "unsloth/gemma-4-31B-it-GGUF|gemma-4-31B-it|mmproj-F16.gguf"
  # QAT variant (added 2026-06-07): quantization-aware trained 4-bit.
  # 17.3 GB vs 18.8 GB PTQ. Near-BF16 quality at 4-bit footprint.
  "unsloth/gemma-4-31B-it-qat-GGUF|gemma-4-31B-it-qat|gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"
  "unsloth/Qwen3.6-27B-GGUF|Qwen3.6-27B|Qwen3.6-27B-UD-Q5_K_XL.gguf"
  "unsloth/Qwen3.6-27B-GGUF|Qwen3.6-27B|Qwen3.6-27B-UD-Q4_K_XL.gguf"
  "unsloth/Qwen3.6-27B-GGUF|Qwen3.6-27B|mmproj-F16.gguf"
  # MTP variants (added 2026-05-16): same quant, with embedded MTP head for
  # speculative decoding (`--spec-type draft-mtp`). Requires llama.cpp ≥ b9186
  # (PR #22673 merged 2026-05-16). See llm/enable-mtp-for-qwen.md.
  "unsloth/Qwen3.6-27B-MTP-GGUF|Qwen3.6-27B-MTP|Qwen3.6-27B-UD-Q4_K_XL.gguf"
  "unsloth/Qwen3.6-27B-MTP-GGUF|Qwen3.6-27B-MTP|mmproj-F16.gguf"
  "unsloth/gemma-4-26B-A4B-it-GGUF|gemma-4-26B-A4B-it|gemma-4-26B-A4B-it-UD-Q5_K_XL.gguf"
  "unsloth/gemma-4-26B-A4B-it-GGUF|gemma-4-26B-A4B-it|gemma-4-26B-A4B-it-UD-Q6_K_XL.gguf"
  "unsloth/gemma-4-26B-A4B-it-GGUF|gemma-4-26B-A4B-it|mmproj-F16.gguf"
  "unsloth/Qwen3.6-35B-A3B-GGUF|Qwen3.6-35B-A3B|Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
  "unsloth/Qwen3.6-35B-A3B-GGUF|Qwen3.6-35B-A3B|Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
  "unsloth/Qwen3.6-35B-A3B-GGUF|Qwen3.6-35B-A3B|mmproj-F16.gguf"
  "unsloth/Qwen3.6-35B-A3B-MTP-GGUF|Qwen3.6-35B-A3B-MTP|Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
  "unsloth/Qwen3.6-35B-A3B-MTP-GGUF|Qwen3.6-35B-A3B-MTP|mmproj-F16.gguf"
  # Higher-quality MoE quants (added 2026-05-07): MXFP4 is ~Q4_K_M-equivalent;
  # Draft model for speculative decoding on Gemma 4 31B (added 2026-05-08).
  # E2B is the smallest in the Gemma 4 family — picked as the official draft
  # candidate per the r/LocalLLaMA recipe.
  "unsloth/gemma-4-E2B-it-GGUF|gemma-4-E2B-it|gemma-4-E2B-it-Q8_0.gguf"
  "unsloth/Qwen3.5-0.8B-GGUF|Qwen3.5-0.8B|Qwen3.5-0.8B-Q8_0.gguf"
  # Smaller quant of gemma-31b for spec-decoding (added 2026-05-08): Q4 frees
  # ~3 GiB vs Q5_K_XL → more VRAM for ctx + draft model. Same family as our
  # existing Q5_K_XL.
)

for item in "${ITEMS[@]}"; do
  IFS='|' read -r repo subdir fname _ <<< "$item"
  dir="$MODELS/$subdir"
  out="$dir/$fname"
  url="https://huggingface.co/$repo/resolve/main/$fname"
  mkdir -p "$dir"
  echo "==> $subdir/$fname"
  # --continue-at - resumes partial downloads; -f fails on HTTP errors; -L follows redirects
  curl -fL --retry 5 --retry-delay 5 --continue-at - -o "$out" "$url"
done

echo "==> all downloads complete"
ls -lh "$MODELS"/*/*.gguf
