# KTransformers Intel Arc / XPU state — checked 2026-10-13

**Verdict:** The "Intel Arc / XPU" feature documented in `doc/en/xpu.md` is **stale/retired on main**: its code was moved to `archive/`, `install.sh` no longer accepts `--dev xpu`, and no Arc‑discrete commit has landed since May 2025. The only *live* Intel‑GPU work is a **new, narrow SYCL GPTQ‑INT4 MoE backend** (`KTRANSFORMERS_USE_SYCL=1`, merged 2026‑07‑17) that targets Intel **iGPU** as an expert‑offload companion to **CUDA** — explicitly *not* a pure‑Intel/A‑or‑B‑series discrete path. Net: **KTransformers is not a viable Arc‑only route for the B580.**

---

## 1. Does main still support Intel Arc / XPU? — Old path: NO (archived/orphaned). New path: yes, but not Arc‑only.

Repo is alive (default branch `main`, pushed 2026‑10‑12, not archived, 19.6k stars) [1].

The **old Arc path is orphaned**:

- README "Updates" — last Intel entry is **"May 14, 2025: Support Intel Arc GPU"**; every 2026 entry is CPU/AMX/AVX, SFT, NVIDIA (DeepSeek‑V4, GLM‑5), or Ascend NPU. No Arc mention since May 2025 [2].
- README §"KT original Code": *"The original integrated KTransformers framework has been archived to the `archive/` directory… The project now organizes the two capabilities [kt‑kernel inference + SFT] from the kt‑kernel source tree."* [2]
- Main root has **no `ktransformers/` package** (only `ktransformers.py`). The XPU optimize rules now live at `archive/ktransformers/optimize/optimize_rules/xpu/` (only `DeepSeek-V2-Chat.yaml`, `DeepSeek-V3-Chat.yaml`, `Qwen3Moe-Chat.yaml`), and `Dockerfile.xpu` at `archive/Dockerfile.xpu` [7][15].
- `install.sh` on main: grep for `xpu|intel|ipex` returns **nothing**; it only supports `sglang` / `kt-kernel` / `all` subcommands — `--dev xpu` is gone [5]. XPU params were added 2025‑05‑15 and removed by the **2025‑11‑10 restructure** ("Refactor: restructure repository to focus on kt‑kernel and KT‑SFT modules") [4].
- `doc/en/xpu.md` (last edit **2025‑05‑26**) and `doc/en/Docker_xpu.md` still sit on main but are **dangling**: they reference `ktransformers/local_chat.py` and `ktransformers/optimize/optimize_rules/xpu/*.yaml` (not on main), and Docker_xpu.md links `../../Dockerfile.xpu` (archived). `xpu.md` is **not in the doc TOC** (`doc/SUMMARY.md`) [3][6][14][24].
- Commit search for "intel" on main since 2025: the **only** hit is `2026-07-17 0c2912a5e [feat] Add SYCL backend for intel iGPU (#2089)`; everything else is 2025‑05 or earlier [8]. PRs/issues are similarly quiet: the newest Intel‑related PRs are the SYCL one and generic AVX‑VNNI CPU items; the Arc items (#1308, #1329) are still open from mid‑2025 [10][16][17].

The **new Intel path** (not the old one):

- PR **#2089 "Add SYCL backend for intel iGPU" merged 2026‑07‑17** (`merged: true, base: main`) [9]. Adds `kt-kernel/operators/sycl/gptq_int4_sycl-moe.hpp` (1267 lines) + runtime, a `KTRANSFORMERS_USE_SYCL` CMake option (default **OFF**), and a **Chinese‑only** tutorial `doc/zh/SYCL-GPTQ-INT4-Tutorial_zh.md` [9][11][10].
- The tutorial is explicit: *"不能替代 NVIDIA GPU，也不是纯 Intel GPU 推理后端"* — **cannot replace an NVIDIA GPU, and is not a pure‑Intel‑GPU inference backend.** The Intel GPU (via Level Zero / shared USM, *mainly aimed at shared‑memory Intel iGPU*) runs the symmetric‑GPTQ‑INT4 **experts**; Attention, Embedding, LM Head and `--kt-num-gpu-experts` experts stay on a **CUDA GPU** [10].
- CMake hard‑requires an **x86‑64 host with AVX2** and the **CUDA toolkit** (`FATAL_ERROR … SYCL GPTQ INT4:ON requires the CUDA toolkit for CPUInfer host‑stream scheduling`) [11]. On a B580‑only box with no NVIDIA GPU this path is **not a drop‑in**.
- Class: maintained (Jul 2026) but **narrow and CUDA‑dependent**; the A/B‑series *discrete* Arc story from 2025 is not maintained.

## 2. Root‑free pip install? — The old pins are still fetchable but belong to the archived path; the live pip package has no Intel path.

- Old doc pins [3]: `pip install ipex-llm[xpu_2.6]==2.3.0b20250518` and `pip install torch==2.7+xpu torchvision torchaudio --index-url https://download.pytorch.org/whl/test/xpu`.
  - `ipex_llm==2.3.0b20250518` **still exists** on PyPI (manylinux2010_x86_64 wheel, uploaded 2025‑05‑18) [20]. (ipex‑llm has had no new upload since ~Nov 2025.)
  - `download.pytorch.org/whl/xpu/` **still lists** `torch-2.7.0+xpu-cp311-cp311-linux_x86_64.whl` (and torch‑xpu up to 2.14.1+xpu, Oct 2026), plus `pytorch_triton_xpu-3.3.0` and `torchvision-0.22.x+xpu` [21][22]. So the exact pins **are installable today** — but they serve the **archived** Arc path, not main.
- `pip install ktransformers` == **0.7.0.post4** (wheel `py3-none-manylinux_2_35_x86_64`), `requires_dist = ["kt-kernel==0.7.0.post4", …]` with extras `sft` / `sglang` only — **no `xpu` extra and no `local_chat.py`** [19]. So the pip package gives you **no Intel path**.
- The **new SYCL path is source‑build only**: `git clone …; source /opt/intel/oneapi/setvars.sh; CPUINFER_USE_SYCL=1 ./install.sh` (needs `icpx`) [10]. No wheel. oneAPI itself is root‑free (the box already has `~/intel/oneapi` 2026.0 with `icpx`/`sycl-ls`), but the CMake **also needs a CUDA toolkit** for `cudart` [11].

## 3. OpenAI‑compatible server on the Intel path?

- **Old Arc path:** still documented as unsupported — `doc/en/xpu.md` "Known Limitations": *"Serving function is not supported on Intel GPU platform for now."* [3]
- **New SYCL path:** **supported via SGLang.** `python -m sglang.launch_server … --kt-method SYCL_GPTQ_INT4 …` exposes an OpenAI‑compatible endpoint (`curl http://localhost:30000/v1/chat/completions`) [10]. But this requires the CUDA GPU for attention/dense layers, so it is not a pure‑Arc server.

## 4. Model formats — old path eats GGUF (limited archs); new path is GPTQ‑INT4 only.

- **Old Arc path:** run with `--model_path <HF model dir>` (safetensors config) **plus `--gguf_path <gguf dir>`** — i.e. it *does* consume standard GGUF quantized weights [3][6]. Users actually ran `unsloth/DeepSeek-R1-0528-Q4_K_M-GGUF` [17]. Supported architectures are limited to the three XPU optimize YAMLs: **DeepSeek‑V2, DeepSeek‑V3, Qwen3Moe** [15].
- **New SYCL path:** symmetric **GPTQ INT4** HF safetensors (`sym=true, desc_act=false`, verified `group_size=128`), MoE models only (example: `Qwen/Qwen3.5-35B-A3B-GPTQ-Int4`). **No GGUF** [10].
- **Your local files** in `LOCAL-AI-LAB/models/llm/` are GGUF: `Qwen3.8-27B-OBLITERATED-IQ4_XS`, `Qwen3.8-27B-GSQ-RCO-IQ3_S`, `Qwen3.6-35B-A3B-UD-Q4_K_XL`, `Ternary-Bonsai-2-27B-PQ2_0`, `Qwen3-4B-Q4_K_M` (plus mmproj).
  - Format‑wise the **old** path would take GGUF — but **none of these GGUFs has an XPU optimize rule** (no Qwen3.6/Qwen3.5‑MoE, no Qwen3.8, no ternary‑Bonsai config; the XPU rule dir has only DS‑V2/V3/Qwen3Moe) [15], and that path is archived anyway.
  - The **new** path can't use them (GGUF not supported; needs GPTQ‑INT4 safetensors).
  - Conclusion: **KTransformers cannot currently consume your local GGUFs on Arc** (format or missing arch rule), on either path.

## 5. Reported tok/s on Arc — A770 only (2025, DeepSeek‑R1 hybrid); **no B580 number found**.

All from GitHub issues (user measurements unless noted); hardware/host stated:

| Config | Hardware / host | Result | Source |
|---|---|---|---|
| DS‑R1 Q4_K_M, `local_chat` cpuinfer 53 | Xeon 5th‑gen, **1× A770** | ~**7–8 tok/s** (user report) | [#1308](https://github.com/kvcache-ai/ktransformers/issues/1308) |
| DS‑R1 full Q4, threads 44 | Xeon 6th‑gen, **2× A770** | **1.9–2.9 t/s** (user) | [#1308](https://github.com/kvcache-ai/ktransformers/issues/1308) |
| DS‑R1‑0528 Q4_K_M, Docker | Xeon w5‑3525 (later corr. 16c), 512 GB DDR5, **1× A770** | **~1.6 t/s** (user) | [#1308](https://github.com/kvcache-ai/ktransformers/issues/1308) |
| BKC config, DS‑R1 | Xeon 8480, **2× A770** | prompt 0.88, eval **1.18 → 1.4 t/s** (user) | [#1329](https://github.com/kvcache-ai/ktransformers/issues/1329) |
| "should be ~**5–6 tps**" | expectation, no run shown | **maintainer claim**, not a measurement | [#1308](https://github.com/kvcache-ai/ktransformers/issues/1308) (aubreyli) |

- The spread (1.6 → 8 t/s) tracks CPU/RAM and config, not the GPU. These are all **DeepSeek‑R1 (671B) hybrid**, May–Jul 2025, pre‑archive.
- **No B580 tok/s figure** for KTransformers was found anywhere (docs, README, issues, PRs) → **not found**. The 2025 `xpu.md`/README claims B580 is "tested and developed" [3] but publish **no numbers**.
- No 2026 Arc number, and **no Qwen3.6‑35B‑A3B or Flash‑Next number on any Arc** → **not found**. The new SYCL path's tutorial publishes **no tok/s** either [10].

---

## Sources (all fetched this session)

1. `https://api.github.com/repos/kvcache-ai/ktransformers` — repo meta: default branch `main`, `pushed_at` 2026-10-12, `archived=false`, 19.6k stars, 523 open issues.
2. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/README.md` — Updates list (last Intel entry May 14 2025); "KT original Code" now archived; 2026 work is CPU/RAM/SFT/NVIDIA/Ascend.
3. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/doc/en/xpu.md` — Intel GPU Beta doc: claims A770/B580 tested; pins ipex-llm 2.3.0b20250518 + torch 2.7+xpu; "Serving … not supported"; `--gguf_path` + `local_chat.py` usage; last edited 2025-05-26.
4. `https://api.github.com/repos/kvcache-ai/ktransformers/commits?path=install.sh&per_page=25` — XPU params added 2025-05-15 (f3be33a31); removed by 2025-11-10 restructure (57d14d22b).
5. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/install.sh` — current install script; no `xpu/intel/ipex` strings; only sglang/kt-kernel/all subcommands.
6. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/doc/en/Docker_xpu.md` — XPU Docker guide; references `../../Dockerfile.xpu` (now archived); still shows `local_chat.py` run.
7. `https://api.github.com/repos/kvcache-ai/ktransformers/contents/` and `…/contents/archive` — root has no `ktransformers/` pkg; `archive/` holds `ktransformers/`, `Dockerfile.xpu`, `install.sh`.
8. `https://api.github.com/search/commits?q=repo:kvcache-ai/ktransformers+intel` — only 2026 Intel commit is `0c2912a5e [feat] Add SYCL backend for intel iGPU (#2089)`, 2026-07-17.
9. `https://github.com/kvcache-ai/ktransformers/pull/2089` (+ API) — SYCL iGPU backend, merged 2026-07-17; adds `operators/sycl/gptq_int4_sycl-moe.hpp` + zh tutorial; CMake `KTRANSFORMERS_USE_SYCL` OFF by default.
10. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/doc/zh/SYCL-GPTQ-INT4-Tutorial_zh.md` — new path: iGPU experts + CUDA attention; not pure-Intel; `CPUINFER_USE_SYCL=1 ./install.sh`; SGLang OpenAI server; GPTQ INT4 only.
11. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/kt-kernel/CMakeLists.txt` — `option(KTRANSFORMERS_USE_SYCL … OFF)`; requires icpx, x86-64/AVX2, and CUDA toolkit.
12. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/kt-kernel/README.md` — kt-kernel supports Intel CPUs (AMX/AVX), AMD CPUs (BLIS), NVIDIA (CUDA); no Intel‑GPU/Arc backend listed.
13. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/doc/SUMMARY.md` — TOC lists SYCL zh tutorial; `xpu.md` absent.
14. `https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/archive/README.md` — legacy README still lists "May 14, 2025: Support Intel Arc GPU".
15. `https://api.github.com/repos/kvcache-ai/ktransformers/contents/archive/ktransformers/optimize/optimize_rules/xpu` — XPU configs: only DeepSeek-V2-Chat, DeepSeek-V3-Chat, Qwen3Moe-Chat.
16. `https://github.com/kvcache-ai/ktransformers/issues/1364` — maintainer aubreyli: A/B-series Arc "supported via PR #1295"; multi-card (BattleMatrix) still "in progress" (2025-06-05).
17. `https://github.com/kvcache-ai/ktransformers/issues/1308` — A770 user tok/s: 7–8, 1.9–2.9, ~1.6; maintainer expectation 5–6 t/s; user ran unsloth GGUF.
18. `https://github.com/kvcache-ai/ktransformers/issues/1329` — A770 1.18 t/s (Xeon 8480, 2×A770), then 1.4 t/s.
19. `https://pypi.org/pypi/ktransformers/json` — current 0.7.0.post4; `requires_dist` = kt-kernel + extras `sft`/`sglang`; no xpu extra.
20. `https://pypi.org/pypi/ipex-llm/2.3.0b20250518/json` — the documented ipex-llm pin still on PyPI (2025-05-18).
21. `https://download.pytorch.org/whl/xpu/torch/` — `torch-2.7.0+xpu-cp311-cp311-linux_x86_64.whl` still listed (plus up to 2.14.1+xpu).
22. `https://download.pytorch.org/whl/xpu/pytorch-triton-xpu/` — `pytorch_triton_xpu-3.3.0` still listed.
