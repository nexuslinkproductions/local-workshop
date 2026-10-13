# 15 — Alternative MoE-offload engines built beside llama.cpp (Arc B580)

Checked and built 2026-10-13, 00:23–00:34 CEST. Two engines were **built from source
root-free** on this box: **ik_llama.cpp** (Vulkan + AVX-512 CPU) and the **Strata SYCL
target**. KTransformers and a set of other candidates are **research only**.

Scope limits honoured: **no model was loaded and no benchmark was run** (another agent
owns the GPU). Builds took the shared GPU lock
(`flock -s …/bench/.gpu.lock`); the only GPU-touching thing attempted was a device
enumeration, which the engine did not support (see §2.3).

## Verdict

| Engine | Built here? | Arc backend | Model format | Worth racing? |
|---|---|---|---|---|
| **ik_llama.cpp** | **Yes** — `engines/ik_llama.cpp/build`, exit 0 | Vulkan (present, **unmaintained**) + CPU AVX-512 (its real strength) | standard GGUF | **Yes**, as the CPU-expert kernel donor; see caveats §2.4 |
| **Strata SYCL** | **Yes** — `engines/strata/build-sycl/strata`, exit 0 | SYCL / oneAPI (native, non-Docker) | **its own pack** (repacked from GGUF) | **Yes**, but only after a large download + pack (§3) |
| KTransformers (XPU) | No — dead end | old XPU path archived; new SYCL path needs CUDA | GPTQ-INT4 or GGUF(archived) | **No** |
| vLLM XPU | No | real Intel XPU backend | safetensors | Maybe later (§5) |
| ninfer-offload | No | none (CUDA-only) | own `.ninfer` | **No** |

## 1. Box (re-measured)

Ryzen 9 7900X (Zen4, AVX-512 incl. VNNI/VBMI/BF16), 61 GiB RAM, 16 cores, ~986 GB free
on `/home`. Arc B580 12 GB on `xe`; oneAPI 2026.0 root-free at `~/intel/oneapi`
(`~/intel/oneapi-env.sh`); `ocloc` 26.31 at `/usr/bin/ocloc`; `glslc` 2026.3 at
`/usr/bin/glslc`; Vulkan 1.4.357. Both builds ran while the bench lane held/queued the
GPU lock; they are CPU compiles and never touched the GPU.

## 2. ik_llama.cpp — built ✅

Upstream `https://github.com/ikawrakow/ik_llama.cpp`, shallow clone at
**`2959611ea`** (*Better IQ3_XXS_R4 TG performance on AVX512+VNNI CPUs (#2633)*,
2026-10-12) into `engines/ik_llama.cpp`. This fork last fully synced with mainline
llama.cpp in **Aug 2024**; model support is maintained independently and is current.

### 2.1 Configure (exact)

```
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON -DGGML_SYCL=OFF -DLLAMA_CURL=OFF
```
exit 0. Resolved: `Found Vulkan: /usr/lib/libvulkan.so (1.4.357) found components:
glslc glslangValidator`; `GL_KHR_cooperative_matrix`, `GL_NV_cooperative_matrix2`,
`GL_EXT_integer_dot_product`, `GL_EXT_bfloat16` all "supported by glslc";
`ARCH_FLAGS = -march=native`.

### 2.2 Build (exact)

```
flock -s -w 5400 /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock \
  cmake --build build -j 20
```
- **Exit 0. 0 errors.** Wall **6 min 11 s** (00:23:28 → 00:29:39), 317 ninja targets.
- `-w 5400` is the only deviation from the prescribed command (an added safety bound so
  the build cannot block forever behind the bench lane's exclusive lock).
- Artifacts: `build/bin/{llama-cli,llama-server,llama-bench,llama-sweep-bench,…}` and one
  combined shared lib `build/ggml/src/libggml.so` (65 MB).

### 2.3 Verification (no model, no GPU)

- **AVX-512/VNNI IQK path IS compiled in** (this is the point of the fork):
  `objdump -d build/ggml/src/libggml.so | grep -c vpdpbusd` → **18869**;
  `grep -c 'vfmadd.*zmm'` → **229747**; symbol `iqk_has_fancy_simd` present.
  (`-march=native` on this Zen4 defines all five of `__AVX512F/VNNI/VL/BW/DQ__`, so
  `HAVE_FANCY_SIMD` is active — verified by preprocessor probe, not assumed.)
- **Vulkan backend linked**: `ggml_backend_vk_{init,reg_devices,get_device_count,…}` and
  `ggml_cpu_has_vulkan` exported; `ggml-vulkan-shaders.cpp` + `vulkan-shaders.spv` generated.
- **B580 runtime NOT verified.** ik has no `--list-devices` (only `-dev`/`--main-gpu`), so
  the device cannot be enumerated without a model load — which was out of scope. Treat
  the Vulkan path as *built but unproven on this card*.
- `llama-server` links `libggml.so` (rpath set) — runnable from `build/bin` without an
  env script.

### 2.4 Model support and formats

- **Reads standard GGUF as-is** (same as llama.cpp); the fork-exclusive IQK/Trellis quants
  are optional extras.
- **Archs present in this build** (`src/llama-arch.cpp`): `qwen3moe`, `qwen3next`,
  **`qwen35moe`**, **`qwen35`**, **`qwen4exp`**, `deepseek4`, `glm4moe`, `gpt-oss`,
  `gemma4`, `mistral4`, `lfm2moe`, … — i.e. **all three local race models are covered**:
  | local model | arch | ik supports |
  |---|---|---|
  | Qwen3.8-27B-OBLITERATED IQ4_XS | `qwen35` (dense) | ✅ |
  | Qwen3.6-35B-A3B UD-Q4_K_XL | `qwen35moe` | ✅ (arch), ⚠ see below |
  | Qwen3.8-Flash-Next (ISTA IQ3_XXS) | `qwen4exp` | ✅ (`build_qwen4exp`) |
- **MoE offload flags** (`common/common.cpp`, `docs/parameters.md`): `-cmoe/--cpu-moe`,
  `-ncmoe/--n-cpu-moe N`, `-ot/--override-tensor` (e.g. `exps=CPU`), `-rtr/--run-time-repack`,
  and `-dple/--defer-ple` — the last one is **specific to Qwen3.8-Flash-Next** (defers the
  per-layer token-embedding tables, PR #2389; also covers DeepSeek-V4.1 engram tables).
- **⚠ Unsloth `_XL` caveat.** The README: *"Do not use quantized models from Unsloth that
  have `_XL` in their name. These are likely to not work with ik_llama.cpp."* The local
  race model `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` is exactly such a file. The caveat is
  narrowed to `_XL` files **containing `f16` tensors** ("all others are fine"), but this is
  the single most likely failure mode for the ik run and must be checked first.
- **⚠ `-rtr` warning.** For hybrid CPU/GPU MoE, do **not** use `-rtr`: it repacks
  RAM-resident tensors to row-interleaved form and, because k-quants (Q2_K…Q6_K) have no
  row-interleaved CUDA path, forces those matmuls onto the CPU — lowering prompt speed.
  Relevant because the local `_XL` file is K-quant based.
- **⚠ No SWA KV compression** (upstream issue #1607; maintainer confirms in #1765) — the
  fork's run is equivalent to llama.cpp `--swa-full`. Matters for sliding-window models.

### 2.5 Launch — OpenAI-compatible server

```
engines/ik_llama.cpp/build/bin/llama-server \
  -m <model>.gguf -c 65536 -ngl 999 --cpu-moe \
  -fa on -ctk q8_0 -ctv q8_0 --host 127.0.0.1 --port 8080
# or: --n-cpu-moe N   /   -ot "\.ffn_(up|down|gate)_exps=CPU"
# Flash-Next only: add -dple
```
Same OpenAI API surface as llama.cpp (so any client pointed at llama.cpp works). README
shows `llama-server --model … --ctx-size 4096 [-ngl 999]` at `http://127.0.0.1:8080`.

### 2.6 Reported tok/s on comparable hardware (sources read, not reproduced)

| Config | Hardware | Result | Source |
|---|---|---|---|
| Qwen3.6-35B-A3B, MoE experts offloaded, **MTP** speculative | RTX 4070 Super 12 GB, Ryzen 7 9700X, 48 GB DDR5 | **110 tok/s** decode | [A] (r/LocalLLaMA report u/janvitos, via a blog) |
| Qwen3.6-35B-A3B IQ4_XS, upstream `mtp-bench.py` same quant | same | 79.8–89.1 tok/s | [A] |
| CPU-only quantized TG, ik vs mainline | Xeon E5-2683 v4 | 5.05 vs 2.70 tok/s (~2×) | [B] (project discussion #164, project-reported) |
| Gemma4 26B-A4B UD-Q4_K_XL, `-ngl 999 --n-cpu-moe 30` | Ryzen 9 7945HX (Zen4) + RTX 5070 Ti 16 GB, WSL | ik **pp 2181 vs 577** (3.8× faster) but **tg 6.86 vs 30.10** (4.4× **slower**) | [C] issue #1765 (wontfix) |
| Qwen3-35B-A3B IQ4_XS, `--cpu-moe -ngl 999 -c 131072` | Ryzen 7 5800X (AVX2) + GTX 1660 Super | ik **pp 118.8 vs 239.8** (2× slower), **tg 10.40 vs 15.69** (1.5× slower) | [D] issue #1699 |
| Gemma4 26B, CPU-only | 13-yr-old Xeon, 128 GB DDR3 | 5.2 tok/s | [E] Neomind Labs |

**The honest read:** ik's advantage is **CPU-side prompt processing and CPU-only decode**,
and it is *not* uniformly faster — two filed reports show ik **slower than mainline on
token generation** for CPU-expert MoE (Gemma4 4.4× slower TG; Qwen3-MoE 1.5× slower TG).
Its Vulkan backend is explicitly outside the maintainer's supported set. So ik is worth
racing **only** with a clear A/B against the stock Vulkan/SYCL build on the same model, and
with the `_XL`/`-rtr` traps in mind.

## 3. Strata SYCL target — built ✅ (non-Docker)

Upstream `https://github.com/Niko1221/Strata`, checkout at **`a0116b2`** in
`engines/strata`. The Intel Arc engine is Strata's own engine ported to SYCL (PR #423),
experimental, off by default, Linux-only. The docs' primary route is Docker; this build
used the documented **non-Docker** path with the installed root-free oneAPI.

### 3.1 Configure (exact)

```
source ~/intel/oneapi-env.sh          # DPC++ 2026.0.0 (icpx/icx), MKL 2026.0
cmake -S sycl -B build-sycl -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
  -DSTRATA_SYCL_AOT=bmg-g21 \
  -DSTRATA_GGML_DIR=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/strata-ggml
```
exit 0. `STRATA_GGML_DIR` points at the existing `engines/strata-ggml` tree, whose HEAD
`3cf03257f2…` **equals the commit the SYCL CMakeLists pins**, so cmake used it directly and
**no network fetch happened** (otherwise `FetchContent` clones llama.cpp). Resolved:
`IntelLLVM 2026.0.0`, `STRATA_HAVE_AVXVNNI_INTRINSICS — Success`, `ggml commit: 3cf0325`.
One benign warning: *"no python3 with numpy found — iq_parity and its fixtures are not
registered"* (a test fixture, not the engine).

### 3.2 Build (exact)

```
flock -s -w 5400 /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock \
  cmake --build build-sycl --target strata -j 20
```
- **Exit 0, "Build succeeded."** Wall **3 min 49 s** (00:29:39 → 00:33:28), 127 targets.
- Warnings only (dpct header `unused function`, one `unused variable` in ggml) — no errors.
- **Artifact: `engines/strata/build-sycl/strata`** — 81.5 MB ELF x86-64, dynamically
  linked; links `libze_loader.so.1` (Level Zero) + `libmkl_sycl_blas.so.6` (and the other
  MKL-SYCL libs) → the SYCL GPU path is real.
- Cache confirms: `STRATA_SYCL_AOT:STRING=bmg-g21` (B580/B570/Pro B60 AOT image, via
  `ocloc`), `STRATA_SYCL_PARITY:BOOL=ON`, `STRATA_GGML_DIR=…/strata-ggml`.
- **Not run** (running it needs the card; the kernel-parity `ctest` is a GPU test, out of
  scope). AOT `bmg-g21` bakes a single device image; docs note the fallback is to drop AOT
  for a JIT `spir64` build if it proves device-incompatible.

### 3.3 Model format — its **own repack**, not raw GGUF

Strata does not read GGUF directly at runtime. It needs a **native pack** produced from the
GGUF by `tools/iq_pack.py`:
```
python tools/iq_pack.py --gguf Qwen3.8-Flash-Next-…-00001-of-00002.gguf --out pack/iq3_xxs
```
and then the engine takes `--pack <iq pack> --native <shard1> --ple-gguf <shard2>`.
`setup.py` supports `--gguf-dir DIR` ("use GGUF files you already have"), so the local
ISTA-DASLab Flash-Next shards **may** be reusable instead of re-downloading — but setup's
own sizes (below) and pinned revisions are the reference. Download/repack sizes
(`setup.py MODELS`), family `qwen` = Flash-Next:

| Strata model | download | RAM needed | expert arena |
|---|---|---|---|
| Q2_0 | 66.4 GB | 48 GB | 34.0 GB |
| IQ2_XS | 68.0 GB | 48 GB | 35.5 GB |
| **IQ3_XXS** | **75.8 GB** | **60 GB** | 42.9 GB |
| IQ3_S | 83.6 GB | 62 GB | 50.3 GB |
| IQ1_M (Coder) | 58.4 GB | 32 GB | 23.4 GB |
| UD-Q4_K_XL | 111.3 GB | 48 GB | 77.0 GB (NVIDIA-only, experimental) |
| UD-IQ4_XS | 93.7 GB | 48 GB | 59.5 GB |

IQ3_XXS wants **60 GB RAM** — this box has 61 GiB, so that tier is very tight; IQ3_S
(62 GB) does not fit. The local ISTA Flash-Next IQ3_XXS is **not fully downloaded yet**
(shard 1 `DOWNLOADING`, shard 2 `PENDING` per `models/llm/MANIFEST-matrix.tsv`).

### 3.4 Launch — OpenAI-compatible server

Docker route (what `setup --backend sycl` uses):
```
./setup.sh --backend sycl --model IQ3_XXS --context 32768 --port 8085
# then run-<model>.sh, or re-run setup
```
Native / by hand (engine + server, from `docs/INTEL.md`):
```
STRATA_VERIFY_DEVICE_PLAN=1 STRATA_VERIFY_NO_HOST=1 \
build-sycl/strata --pack <iq pack> --native <shard1> --ple-gguf <shard2> \
  --expert-profile data/expert-profile-coder.bin --expert-cache auto --stream-experts \
  --prefill auto --spec 4 --spec-min-p 0.5 --max-context 8192 --tokens <ids> --max-new 64 --greedy

# OpenAI/Anthropic server (non-Docker):
python sycl/serve/server_intel.py --engine strata --config strata-<model>.json --port 8080
```
API: OpenAI `/v1/chat/completions` (+ `logprobs`), Anthropic `/v1/messages`, base
`http://127.0.0.1:8080/v1`. Env that matters: `SYCL_CACHE_PERSISTENT=0`,
`ZES_ENABLE_SYSMAN=1`, `STRATA_VERIFY_NO_HOST=1` (required on `xe` when experts are not all
resident). If answers come back empty, send `reasoning_effort: none`. Keep ~1.5 GB VRAM
free — on `xe` over-allocation spills to RAM and can livelock the box.

### 3.5 Reported tok/s (as published)

| Config | Hardware | Result | Source |
|---|---|---|---|
| IQ3_S, 11.5k/24.6k experts resident | Arc Pro B70 32 GB, xe, 60 GB RAM | decode **30 (prose)–41 (code)** tok/s; 4K prompt 980–1000 tok/s | Strata `docs/INTEL_ARC.md` (maintainer) |
| IQ3_XXS, `--layer-split` | 2× Arc Pro B70 | 66 tok/s decode, 394 tok/s prompt | PR #423 (community) |
| Coder IQ1_M | 2× Arc Pro B60 24 GB | 56.6 tok/s decode, 428 tok/s prompt | `bench/results/2026-10-04-…` |
| Coder IQ1_M, 4042/12288 experts mirrored | 1× Arc Pro B60 24 GB | 11.9 tok/s decode | same |
| IQ2_XS ~21 / Coder ~15 tok/s, **device loss also seen** | **Arc B580 12 GB, WSL2** | — | PR #423 (community) |

**No B580 number exists for any 3-bit Strata build**, and the only B580 evidence is
WSL2-only with reported device loss. Treat Strata on this card as unproven.

## 4. KTransformers Intel XPU — research only, **dead end**

The documented Arc/XPU path is **retired on main**: the `ktransformers/` package and
`Dockerfile.xpu` moved to `archive/`, `install.sh` no longer accepts `--dev xpu` (removed
in the 2025-11-10 restructure), and no Arc-discrete commit has landed since May 2025. The
only live Intel-GPU work is a **narrow SYCL GPTQ-INT4 MoE backend** (`KTRANSFORMERS_USE_SYCL=1`,
merged 2026-07-17, PR #2089) that targets an Intel **iGPU** as an expert companion to a
**CUDA** GPU — its own tutorial says it "cannot replace an NVIDIA GPU and is not a
pure-Intel-GPU backend", and its CMake hard-requires the CUDA toolkit. Not usable on a
B580-only box. Old path could read GGUF (archs DeepSeek-V2/V3, Qwen3Moe only) but is
archived; new path needs symmetric GPTQ-INT4 safetensors. Reported Arc numbers are A770 +
DeepSeek-R1 from mid-2025 (1.6–8 tok/s, user reports in #1308/#1329); **no B580 figure**.
Sources: `kvcache-ai/ktransformers` README, `doc/en/xpu.md`, `archive/`, PR #2089,
`doc/zh/SYCL-GPTQ-INT4-Tutorial_zh.md`, issues #1308/#1329/#1364.

## 5. Other engines with expert offload that touch Arc (research only)

| Engine | Arc backend | Offload mechanism | Repack | OpenAI server | Arc tok/s (source) |
|---|---|---|---|---|---|
| **vLLM XPU** | real Intel XPU backend (V1, TP/PP/DP/EP) | `--cpu-offload-gb` + **`--cpu-offload-params experts`** (not expert-aware by default) | safetensors | yes | Flash-Next **4.26 → 9.46 tok/s** with `--cpu-offload-params experts`, one XPU card, `--cpu-offload-gb 47` (vLLM #54593) |
| **SGLang XPU** | Xe2/BMG Arc B-series (docs verified on B580) | UVM expert offload is **CUDA-only**; XPU MoE = fully resident MXFP4 W4A16 | safetensors | yes | none found on Arc |
| llama.cpp forks | da3dsoul = SYCL Arc B70; Xtopia = Vulkan Arc B390; rest CUDA-only | hot-expert VRAM cache / disk streaming | GGUF | llama-server | da3dsoul's SYCL expert cache only **ties** stock `-ncmoe`; Xtopia B390 34.2→37.7 tg128 (shader tuning) |
| LM Studio | Vulkan runtime | "Force MoE expert weights onto CPU" = `--n-cpu-moe` | GGUF | yes | none found on Arc (A770 "0 GPUs" reports) |
| Ollama | Vulkan default since 0.30 (AMD+Intel) | **no user flag**; `--n-cpu-moe` pass-through PR #16688 **closed** | GGUF | yes | none found on Arc |
| ninfer-offload | **none — CUDA-only** (sm_89/sm_120a) | `--moe-offload`: experts on CPU (AVX2), attention/router on GPU | own `.ninfer` | yes | 19.2–24.1 tok/s, **RTX 4060 Ti only** |

Notes: vLLM XPU MoE quantization is currently broken (INC returns `UnquantizedFusedMoEMethod`,
so int4 MoE materialises as bf16 → OOM on an Arc Pro B70; vLLM #47937) — the 9.46 tok/s
figure is a bright spot but the path is fragile. Flash-Next outside llama.cpp/Strata exists
only as ninfer-offload (CUDA) and a private CUDA vLLM build (Intel `llm-scaler` #649). No
`qwen35moe` engine outside the llama.cpp family was found.

## 6. Recommendation for the race

1. **ik_llama.cpp** — race it with `-ngl 999 --cpu-moe` on **Qwen3.8-27B-OBLITERATED IQ4_XS**
   (`qwen35`, no `_XL` trap) and on the **Flash-Next `qwen4exp`** file with `-dple`. Expect
   its CPU PP win and be ready for a TG loss; the `_XL`/`-rtr` traps are the first things to
   check. Its Vulkan-on-B580 runtime is unverified — if it fails, fall back to the stock
   `llama.cpp-vulkan-tip`/`-sycl-tip` binaries and keep ik as the CPU reference.
2. **Strata SYCL** — finish the Flash-Next IQ3_XXS download, run `tools/iq_pack.py`, then
   `setup.sh --backend sycl` or the by-hand line. It is the only engine with Flash-Next-specific
   expert caching, but B580 evidence is WSL2-only with device loss and the IQ3_XXS RAM ask
   (60 GB) is at this box's ceiling.
3. **Skip** KTransformers and ninfer-offload. Keep vLLM XPU as a later experiment only
   (fragile quant path, safetensors-only, big install).

## Sources

[A] https://bayesiansapien.github.io/cere-bro/inference-efficiency/2026-05-21-ik-llamacpp-mtp-cpu-offload-qwen36 — r/LocalLLaMA report (u/janvitos), 110 tok/s Qwen3.6-35B-A3B, RTX 4070 Super + Ryzen 7 9700X.
[B] https://aifoss.dev/blog/ik-llamacpp-review-cpu-inference-2026 — review; cites ik discussion #164 (~2× CPU TG); states "no active Metal, ROCm, or Vulkan support in the fork".
[C] https://github.com/ikawrakow/ik_llama.cpp/issues/1765 — Gemma4 26B-A4B CPU-expert: ik pp 3.8× faster, tg 4.4× slower; maintainer: no SWA KV compression (#1607); closed wontfix.
[D] https://github.com/ikawrakow/ik_llama.cpp/issues/1699 — Qwen3 MoE IQ4_XS `--cpu-moe`: ik ~2× slower PP, ~1.5× slower TG vs mainline.
[E] https://www.neomindlabs.com/2026/06/08/running-gemma-4-26b-at-5-tokens-sec-on-a-13-year-old-xeon-with-no-gpu/ — Gemma4 26B CPU-only 5.2 tok/s on an old Xeon.
[F] `engines/ik_llama.cpp` README + `docs/parameters.md` + `docs/build.md` (commit 2959611ea) — supported backends ("CPU and CUDA only"), `_XL` warning, `-rtr` warning, AVX-512 flags, `--cpu-moe`/`-n-cpu-moe`/`-ot`/`--defer-ple`.
[G] `engines/strata` at a0116b2 — `docs/INTEL_ARC.md`, `docs/INTEL.md` ("How to run it by hand"), `setup.py` MODELS, `tools/iq_pack.py`, `sycl/CMakeLists.txt`, `sycl/serve/server_intel.py`.
[H] https://github.com/Niko1221/Strata/pull/423 — Intel SYCL port; B580 WSL2 ~21 tok/s + device loss.
[I] https://github.com/kvcache-ai/ktransformers — README, `doc/en/xpu.md`, `archive/`, PR #2089 (SYCL iGPU, CUDA-required), issues #1308/#1329/#1364.
[J] https://github.com/vllm-project/vllm/issues/54593 — Flash-Next on Intel XPU, 4.26 vs 9.46 tok/s with `--cpu-offload-params experts`; https://github.com/vllm-project/vllm/issues/47937 — XPU MoE dequant-to-bf16 OOM.
[K] https://docs.sglang.io/docs/hardware-platforms/xpu — SGLang XPU on B580, MXFP4 MoE, no UVM offload.
[L] https://github.com/1872183316/ninfer-offload — CUDA-only (RTX 40/5090), `.ninfer` format.
[M] https://github.com/da3dsoul/Qwen3.8-Flash-Next-LlamaCpp-MoE-Cache-Arc-Experiments — SYCL expert cache on Arc B70 ties stock `-ncmoe`.
[N] https://github.com/ollama/ollama/pull/16688 — `num_cpu_moe` PR closed (no user expert-offload flag in Ollama).
