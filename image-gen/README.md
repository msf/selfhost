# image-gen

Local image generation on the R9700 — `stable-diffusion.cpp` (Vulkan) serving
Chroma, containerised so no Mesa/ROCm userspace lands on the host.

**Normal use goes through the `image-gen` skill**, which wraps GPU arbitration,
pre-warming and upscaling:

```sh
python3 ~/.claude/skills/image-gen/scripts/imagegen.py gen "a red fox" -o fox.png
python3 ~/.claude/skills/image-gen/scripts/imagegen.py down
```

Raw compose, for debugging the deployment itself:

```sh
docker compose build
curl -s http://127.0.0.1:8090/unload     # free the card first — see below
docker compose up -d

curl -s -X POST http://127.0.0.1:1234/v1/images/generations \
  -H 'content-type: application/json' \
  -d '{"prompt":"a red fox reading a book","size":"1024x1024","n":1}' \
  | jq -r '.data[0].b64_json' | base64 -d > out/test.png

docker compose down                      # give the card back to llama-swap
```

Models are read-only from `/media/simple/llm/image-gen` (ZFS `simple/llm`). The
model is loaded once at startup and stays in VRAM between requests.

## API

Three families, all served on :1234 (`examples/server/api.md` upstream):

| endpoint | shape |
|---|---|
| `POST /v1/images/generations` | OpenAI-compatible, returns `{data:[{b64_json}]}` |
| `POST /sdapi/v1/txt2img` | AUTOMATIC1111-compatible |
| `POST /sdcpp/v1/img_gen` | native, async — pairs with `GET /sdcpp/v1/jobs/{id}` |

There is **no** `POST /generate` (404), and `GET /sdcpp/v1/capabilities` **500s**
on this build — probe readiness with `GET /v1/models`.

The OpenAI route accepts only `prompt`, `n`, `size`, `output_format`,
`output_compression`. Seed, steps and negative prompt ride inside the prompt
string as native-schema JSON, which the server extracts and strips:

```
a red fox <sd_cpp_extra_args>{"seed":42,"sample_params":{"sample_steps":26}}</sd_cpp_extra_args>
```

Verified 2026-08-03: seed 42 twice → byte-identical PNGs; seed 7 → different.

The container is `restart: "no"` on purpose — while it is up, no LLM can load.

## It cannot run at the same time as an LLM

The card has 31.86 GiB. Chroma Q8 + t5xxl Q8 + vae needs **14.40 GiB**; a loaded
`llama-server` holds **14.64–23.41 GiB** depending on the model. Together they
exceed the card and the Vulkan queue dies mid-sample with
`vk::DeviceLostError` / `the CS has been cancelled because the context is lost`.

Free the card first — llama-swap reloads on the next request, so this is safe:

```sh
curl -s http://127.0.0.1:8090/unload      # GET, not POST
```

The durable fix is to register this as a member of llama-swap's `groups.all`
(`swap: true, exclusive: true`) so the two evict each other automatically instead
of colliding. Not done yet.

## Why mesa comes from backports

Only Mesa >= 26.x exposes `VK_KHR_cooperative_matrix` on RDNA4. On trixie's 25.0.7
RADV reports `matrix cores: none` for gfx1201 and matmul runs scalar shaders.

Measured 2026-08-03, 1024x1024 / 26 steps / seed 42 / Chroma Q8, card otherwise idle:

| mesa | per step | total (CLI) |
|---|---|---|
| 25.0.7 (host) | 10.8s | 303.64s |
| 26.1.2 (this image) | 7.6s | 217.34s |

## Performance

`--diffusion-fa` + `easycache` are set in the compose `command:` — together 1.75x
with no visible quality change. Rejected after measuring: `--steps 10` and
`--cfg-scale 1.0` are faster but visibly wreck output, because Chroma is
de-distilled and needs real CFG and a full step count.

**Warm requests are 70.94s at 1024x1024/26 steps, or 12.5-13.9s at 512x512.**

The default path is 512x512 + Lanczos to 1024 (~14.3s), ~4.9x faster than a
native 1024x1024 render and visually comparable — Chroma flattens above its
sweet spot. The skill does this; see its SKILL.md for the trade-off table.

Weights load **lazily, per component, inside the first request** — not at
startup. The startup line `total params memory size = 18528.14MB` is a size stat,
not an allocation; the port binds before any tensor is read. Measured on a cold
512x512 (2026-08-03): T5 read 16.04s, diffusion read 18.28s, VAE 0.52s, so
request 1 takes **49.01s** against 13.9s warm. Pre-warm with a throwaway
256x256/4-step request before anything user-visible.

Once weights are resident, T5 encoding is **0.26s** — the ~19s attributed to "T5"
in CLI benchmarks is disk → VRAM loading, not compute. So `--backend clip=cpu`
trades away something that is otherwise nearly free; only use it when VRAM forces it.

Still short of the <60s goal by ~1.18x. Untried, cheapest first: `--fa` (full flash
attention), 20 steps instead of 26 (needs a 1024 quality check), the ROCm/HIP
backend (`-DSD_HIPBLAS=ON`, needs `/dev/kfd` and ROCm >= 7.x which Debian does not
package), then a lighter model — Chroma is 8.9B, an SDXL-class UNet is ~3-4x
cheaper per step and needs no T5 at all.

## Gotchas

- `--diffusion-model`, never `-m`. The Chroma GGUF is a standalone UNet; `-m`
  expects a full checkpoint and fails with the misleading
  `get sd version from file failed`.
- `--vae-tiling` is required at 1024x1024 — untiled decode requests a single
  7.96 GiB buffer and fails regardless of free VRAM.
- `group_add` must be numeric (44/105). The debian base image has no `video` or
  `render` group, so `--group-add render` errors out.
- Vulkan needs only `/dev/dri`. `/dev/kfd` is for ROCm/HIP.

Background and full history: `wiki/llm/todos/local-image-generation.md`.
