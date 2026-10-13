# Image Generation — ComfyUI on Intel Arc B580 (XPU)

Local image-gen stack running on the Intel Arc B580 (12 GB VRAM) via PyTorch XPU.
No NVIDIA/CUDA involved. Verified working end-to-end on this machine.

## Layout

```
LOCAL AI LAB/
├── imagegen/
│   ├── ComfyUI/            <- repo + .venv (Python 3.14.7)
│   │   ├── custom_nodes/ComfyUI-GGUF/   <- leejet fork (GGUF loader nodes)
│   │   └── extra_model_paths.yaml       <- points at ../models/image
│   └── workflows/
│       └── image_qwen_image_2_1_t2i.json  <- official t2i template, UNETLoader swapped to UnetLoaderGGUF
├── models/image/
│   ├── diffusion_models/qwen-image-2.1-UC-Q5_K_M.gguf                          (5.22 GB)
│   ├── text_encoders/qwen3vl_8b_int8_convrot.safetensors                       (9.35 GB)
│   ├── text_encoders/qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors (9.47 GB)
│   └── vae/qwen_image_2.1_vae_bf16.safetensors                                 (0.68 GB)
└── notes/IMAGEGEN.md
```

## Launch

```bash
cd "/run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/LOCAL AI LAB/imagegen/ComfyUI"
.venv/bin/python main.py --listen 127.0.0.1
```

UI: http://127.0.0.1:8188 — then drag `imagegen/workflows/image_qwen_image_2_1_t2i.json`
onto the canvas (or Workflow > Open).

Useful flags: `--lowvram` (aggressive offload if OOM), `--cpu-vae` (VAE decode on CPU).

## Stack versions (verified)

- ComfyUI 0.37.0 · comfyui-frontend-package 1.53.6 · workflow-templates 0.11.70
- Python 3.14.7 (system interpreter, venv at `ComfyUI/.venv`)
- torch 2.14.0+xpu, torchvision 0.29.0+xpu, torchaudio 2.11.0+xpu, triton-xpu 3.8.0
  (from https://download.pytorch.org/whl/xpu — stable wheels work fine on 3.14)
- `torch.xpu.is_available()` → True; device `xpu:0 Intel(R) Arc(TM) B580 Graphics`
- comfy-kitchen 0.2.35 (eager backend on XPU; triton backend present but disabled),
  comfy-aimdo 0.5.5
- ComfyUI-GGUF custom node: gguf 0.19.0, protobuf 7.36.2

## Models (all under `models/image/` via extra_model_paths.yaml)

| Role | File | Size | Source |
|---|---|---|---|
| Diffusion (transformer) | `qwen-image-2.1-UC-Q5_K_M.gguf` | 5.22 GB | `abenzerps/Qwen-Image-2.1-Uncensored-GGUF` |
| Text encoder (VL) | `qwen3vl_8b_int8_convrot.safetensors` | 9.35 GB | `Comfy-Org/Qwen-Image-2.1` |
| Prompt-enhancer (PE) | `qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot.safetensors` | 9.47 GB | `Comfy-Org/Qwen-Image-2.1` |
| VAE | `qwen_image_2.1_vae_bf16.safetensors` | 0.68 GB | `Comfy-Org/Qwen-Image-2.1` |

The official t2i workflow loads BOTH text encoders — `qwen3vl_8b` is the main
encoder (`clip_name`) and `qwen3.5_9b_pe_t2i` is the prompt-enhancer model
(`clip_name_1`, used by the TextGenerate/QwenImage21Cache refine path).

To re-download or add files:

```bash
uvx --from "huggingface_hub[cli]" hf download <repo> <file> \
  --local-dir "<LAB>/models/image/<category>"
# hf preserves repo subdirs under --local-dir; flatten afterwards if needed.
```

## VRAM notes (12 GB B580)

- Resident footprint at load: Q5_K_M transformer (~5.2 GB) + int8 VL encoder
  (~9.3 GB) + VAE — the encoders and VAE offload; ComfyUI reports NORMAL_VRAM
  mode and manages swapping automatically. Peak resident stays under 12 GB
  because weights stream/offload between stages.
- If the PE encoder + VL encoder + DiT contend, `--lowvram` trades speed for
  headroom. The GGUF Q5_K_M choice (~5.2 GB) vs the int8 safetensors (~7.3 GB)
  buys ~2 GB of slack.
- `weight_dtype`/`dequant_dtype`: leave "default" — dequantizes to compute dtype.
- Startup log warns "Could not autodetect AIMDO implementation, assuming Nvidia" —
  harmless on XPU; comfy-kitchen falls back to its eager backend.

## License caveat

Qwen-Image-2.1 (and the UC uncensored finetune derived from it) is released under
the **Qwen Research License — NON-COMMERCIAL use only**. Outputs and weights may
not be used commercially. Check `LICENSE`/README in `Comfy-Org/Qwen-Image-2.1`
and `abenzerps/Qwen-Image-2.1-Uncensored-GGUF` before any other use.

## Maintenance

```bash
# update ComfyUI
cd "<LAB>/imagegen/ComfyUI" && git pull
# update deps after pull
uv pip install --python .venv/bin/python -r requirements.txt
# update GGUF node
cd custom_nodes/ComfyUI-GGUF && git pull
```
