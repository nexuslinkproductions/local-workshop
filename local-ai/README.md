# LOCAL AI LAB

Local AI on the Intel Arc B580 (12 GB VRAM) — no cloud, no NVIDIA. Set up 2026-09-27.

## What's here

| Path | What |
|---|---|
| `imagegen/ComfyUI/` | ComfyUI 0.37 + PyTorch 2.14 XPU (Intel GPU backend) |
| `imagegen/workflows/` | Ready-made Qwen-Image-2.1 workflow (GGUF-adapted) |
| `llm/llama.cpp/` | Stock llama.cpp master, Vulkan build |
| `llm/llama.cpp-prism/` | PrismML fork (`prism` branch) — required for ternary GGUFs |
| `llm/setup-llm.sh` | Rebuild/update everything (incremental, re-runnable) |
| `models/image/` | Image weights (transformer, encoders, VAE) |
| `models/llm/` | Chat model GGUFs |
| `notes/` | Detailed docs (LLM.md, IMAGEGEN.md) |

## Chat models — talk to a local assistant

```bash
./chat-obliterated.sh          # Qwen3.8-27B OBLITERATED → http://127.0.0.1:8081
./chat-bonsai.sh               # Ternary-Bonsai-2-27B      → http://127.0.0.1:8082
./chat-bonsai-abliterated.sh   # Bonsai Abliterated        → http://127.0.0.1:8083
```

Each serves llama.cpp's built-in web chat UI + an OpenAI-compatible API (`/v1`).
All three have **vision** — drop an image in the chat box (projectors: official
`mmproj` GGUFs; Bonsai's is shared, OBLITERATED's bf16 one runs on CPU to save VRAM).

| Model | Size | VRAM | Speed (measured) | Character |
|---|---|---|---|---|
| Qwen3.8-27B-OBLITERATED IQ4_XS | 14.4 GiB | partial (40/65 layers) | ~7 tok/s | uncensored, greedy+rep 1.15, thinking off |
| Ternary-Bonsai-2-27B PQ2_0 | 6.7 GiB | full | ~26 tok/s | reasoning model, thinks by default (xhigh) |
| Bonsai-2-27B **Abliterated** PQ2_0 | 6.8 GiB | full | ~26 tok/s | same + refusal weights removed |

Bonsai is the daily driver — 3.7x faster because it fits whole in VRAM.
OBLITERATED is heavier and partially CPU-offloaded; use it when you want the
deep model. Do NOT add a system prompt to OBLITERATED (reintroduces refusals).

**VRAM rule:** run ONE chat model at a time. The GPU can't fit two.

## Image generation — Qwen-Image-2.1

```bash
cd imagegen/ComfyUI && .venv/bin/python main.py --listen 127.0.0.1
# → http://127.0.0.1:8188, then load imagegen/workflows/image_qwen_image_2_1_t2i.json
```

Unified t2i + image-edit model, native 2048x2048, transparent-image support.
Uncensored-GGUF transformer (Q5_K_M, 5.2 GB) + two int8 encoders + VAE.

**Speed LoRAs** (in `models/image/loras/`, add a LoraLoader node):
- `turbo8_lora_step2500.safetensors` — 8-step turbo, ready workflow at
  `imagegen/workflows/turbo8_t2i.json`
- `Qwen-Image-2.1-Fun-Acc-4Step.safetensors` — Alibaba PAI 4-step accelerator

License: **Qwen Research License — non-commercial only.**

## Performance notes (B580)

- Vulkan driver: Mesa ANV 26.2 (KHR_coopmat matrix cores active)
- `-fa` (flash attention) on everywhere; pin `--device Vulkan0` (Vulkan1 = Ryzen iGPU)
- IQ4_XS spills ~3 GB to host RAM at -ngl 48 — that is the -ngl ceiling; higher OOMs at load
- Optional: `--cache-type-k q8_0 --cache-type-v q8_0` for longer contexts
- sglang/vLLM are not viable — no CUDA; llama.cpp Vulkan + torch-XPU are the
  two working GPU paths on Battlemage

## Sources

- OBLITERATED GGUF pulled from T7 (`03 - Projects/ai-models/`); full 94 GB
  safetensors + Q8_0 remain on the T7 if ever needed
- Bonsai PQ2_0 copied from Windows Hermes models dir; abliterated variant from
  HF `BoldingBuilds/Ternary-Bonsai-2-27B-Abliterated-PQ2_0-GGUF`
- Image weights: HF `abenzerps/Qwen-Image-2.1-Uncensored-GGUF` + `Comfy-Org/Qwen-Image-2.1`
