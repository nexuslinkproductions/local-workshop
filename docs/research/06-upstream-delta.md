# 06 — Upstream delta & SYCL feasibility (scout, 2026-10-12)

Scope: `git fetch` only — no merge, no pull, no checkout, no rebuild. GPU untouched
(ARC Raiders holds the B580). All shas are abbreviated; paths are repo-relative.

## Fetched refs (what moved)

| repo | local HEAD | origin tip after fetch | delta |
|---|---|---|---|
| `llm/llama.cpp` (origin `ggml-org/llama.cpp`) | `a97cce86a` 2026-09-27 *"common : avoid side effects around params parsing (#29537)"* | `358a420ec` 2026-10-12 *"graph: pad the KV dimension of the no-cache attention to 256 (#30416)"* | **354 commits** |
| `llm/llama.cpp-prism` (origin `PrismML-Eng/llama.cpp`, branch `prism`) | `adfffbe41` 2026-09-25 *"x86: SSE2/SSSE3 vec_dot for PTQ1_0 and PQ2_0 (#248)"* | `e8fd209c9` 2026-10-10 *"grammar: allow schema property order (#347)"* | **29 commits** |

Both local HEADs are ancestors of their origin tips → clean fast-forward if we ever choose to update.
Local builds of both repos are **gcc (`/usr/bin/c++`), Vulkan backend only** (`libggml-vulkan.so`; no
SYCL/CUDA/HIP artifacts in `build/`).

---

## 1. Stock delta — `ggml/src/ggml-vulkan` (28 commits)

```
0f701c882 vulkan: pack FMA for f16 accumulation, no dot product op (#29877)
08ffba21e vulkan: use ternary expressions to avoid switch lowering for CM2 quant block size (#30164)
b2f036c0f vulkan: fix buffer logging on 32-bit platforms after source split (#30326)
966baae76 vulkan: handle mul_mat_id duplicates in the prepass rather than looping (#29998)
404f557b5 vulkan: use 4 rows for NVIDIA MUL_MAT_ID MMVQ (#29274)
5e4878e97 vulkan: fix rms_norm workgroup count overflow (#30145)
ff5888f99 vulkan: fix TOP_K for +inf/NaN inputs and k = 1 on negative values (#30107)
dac308739 vulkan: extend sparse FA support to coopmat2 (#30003)          <- Intel/coopmat
4d756bc72 vulkan: fix amd iGPU slow checkpoint read (#30049)
58cb9138e vulkan: check for null vkEnumerateInstanceVersion (#29872)
6c59c4007 vulkan: fix Flash Attention shmem write out of bounds (#29988)
3c9e747f7 vulkan: revert mul_mat_id tile selection PR #29182 (#29936)
806eee984 vulkan: fix stale prealloc_y reuse across flash attention and soft_max (#29591)
b3daa077a vulkan: sparse flash attention for quantized K/V (#29639)
ebe18bee5 vulkan: Fix undeclared identifiers when -DGGML_VULKAN_RUN_TESTS=ON (#29912)
16c163d56 vulkan: fix rdna4 mat_vec tuning (#29934)
889edf43d qwen4exp : halve the indexer score memory (#29825)
9e258a6e0 vulkan: disable large matmul tile on Samsung GPUs with 32KB shared memory (#28531)
631109b34 ggml : add `alloc_buffer_n` to buffer type interface (#23671)
fb4b2737a vulkan: add logging to pipeline compile issues (#29794)
90c908d06 cpu: accept BF16 in src1 of mul_mat (#28937)
5c200e0c8 vulkan: Tune GDN kernel, fix Intel performance (#29476)        <- Intel perf
83dd71f86 vulkan : Load F32 A matrix 2 at a time when its 2-aligned (#29254)
94a0ae3e7 vulkan: MOE aware mat_mul_id tile selection (#29182)
0bc845d35 vulkan : reuse descriptor sets when bindings are constant (#29280)
66e665c42 vulkan: include functional header (#29597)
03a667aa3 vulkan: fuse qwen4exp's SCALE -> SIGMOID -> SCALE -> hc_post chain (#29520)
526247161 vulkan: fix wrong results when a mul_mat reads a slice of a larger cache (#28956)
```

## 2. Stock delta — `ggml/src/ggml-sycl` (17 commits)

```
f9a95aeb2 sycl: guard DMMV reads at row tails (#29338)
1e6f04a75 sycl : accelerate MXFP4 MoE with arithmetic decoding and weight reordering (#29809)
3d65c90d0 sycl : Q5_K reorder-layout MMVQ and fused GLU (#29375)
46baf1f1f sycl: FWHT optimizations (#29605)
ff30363a0 sycl: fuse the delta-net alpha gate (add + unary + mul) (#29687)
000bee54a sycl: stage bulk uploads (model loading) through a pinned ring buffer (#29608)
847f447c3 sycl: add grouped MoE XMX GEMM (#29245)                       <- Xe XMX
9b4ed0ca5 sycl: remove duplicate block-size defines from op headers (#29507)
005a1e127 [SYCL] fix the issue in mixed different model GPUs in FA (#29071)
d2a79e604 sycl: accelerate GLM MLA prefill with MKL flash attention (#29171)
5e5b628eb sycl : fattn_kv_buffers cleanup (#27689)
78651c410 sycl: add IQ3_S multi-column MMVQ (#29500)
392ded654 SYCL: Q8_0 DMMV ESIMD and MMVQ wide load (#29186)
b93328954 sycl: large register file for D=512 FA vec kernels (#29062)
c328acc91 sycl : do not use slow oneDNN reference matmul and fattn (#28985)
631109b34 ggml : add `alloc_buffer_n` to buffer type interface (#23671)
2a53ace3b SYCL: reduce tensor allreduce sync with pinned host buffers (#29604)
```

## 3. Stock delta — architectures / speculative / kv-cache / MoE / server

**New or heavily-touched architectures** (`src/models/*`, `src/llama-model.cpp`; 34 commits touch `src/models`):
```
a9d27ac69 model :  support for Prism Bonsai 2 27B (#29600)             <- see §5
649dcb103 add GLM-5.3-Flash (GLM5-Next) support (#27773)              <- "flash"/"next"
b9acf138a feat: add GLM5Next MTP, optimize (#29928)                   <- MTP
c061df198 Qwen4Exp: add MTP (#29761)                                  <- MTP
462524043 model : add K2 Horizon dense and MoVA support (#29535)
22bdcc4cd mimo : support dflash (convert + feature extraction) (#29650)  <- draft
a11f57ba9 model : fix DFlash output head sharing (#30111)
75118a3a5 convert : support Qwen3.5 embedding models (#27920)         <- qwen3.5
4fbc76dec model: support embeddinggemma2 (text+vision+audio) (#30054)
2b36825cb convert : write Gemma embedding scale for DFlash drafts (#29802)
```

**Speculative / MTP / NextN / draft (stock):**
```
1fb7ef3e3 spec : add probabilistic sampling for simple draft and MTP (#27694)
8330e9696 spec : fix n-gram drafts rejected at temp > 0 after truncation (#29924)
d280808f5 common : stop accepting draft tokens at EOG (#29638)
781dbc5ac spec: properly handle mtmd input for mtp (#30257)
448147d42 llama: share the nextn tensor flags between models (#30097)
f0c41e016 models : consolidate nextn row cropping into shared helpers (#30017)
1a3011cc0 llama : re-reserve the sched when the nextn extraction flags change (#30020)
310991409 llama: remove the gather path of the glm5-next sparse attention (#30042)
05af0d2b1 glm5-next: give dead indexer slots unique scatter rows (#29745)
77757a346 examples : fix draft sampling and rejection handling (#30095)
4453b535f llama : preserve original batch order for speculative decoding layer inputs (#29019)
f1ea20621 batch: migrate speculative, mtmd and server to batch_ext (#29385)
```

**KV-cache / MoE offload (`--n-cpu-moe` / `-ot` paths):**
```
210791069 kv-cache: fix restoring mismatched KV cache rotation by saving exact rotation metadata (#28498)
d6cf9acb2 llama : add a GPU cache for MoE experts kept in host memory (#29887)
c811cb8f0 llama: support MoE cache over multiple GPUs (#30112)
6753a033f ggml: refactor selective expert copying to user code (#29943)
99b95488c model: add support for clef decision model (text-only) (#29831)
0bb496dbd llama: support both embd + raw tokens in batch (#29622)
```
Note: the `--n-cpu-moe` / `--override-tensor` **flag surface is unchanged** in the delta
(`git log -S'n-cpu-moe'` and `-S'override-tensor'` over `a97cce86a..origin/master` → empty); the change is
under the hood (new host-memory MoE expert cache, now multi-GPU).

**Server / tools:**
```
b42b7e6d3 server: use port 9931 by default (#30159)                    <- behavior change
aa94f2086 args: add LLAMA_ARG_SLOT_SAVE_PATH env for --slot-save-path (#30272)
033df86b6 server : preserve context checkpoints across slot save/restore (#26004)
23b0202a1 server: leave a busy slot untouched when a request pins it (#30295)
62a6f74ba server: add component tests (#30312)
a518119d3 llama: keep the backend sampling graph static across ubatches (#30223)
4d60b4d08 common, server : report model input/output modalities in GET /models (#29987)
d775ebf36 server: return HTTP 400 for invalid embedding requests (#29060)
a4cb4c61f llama, server: add /v1/systemone API (#29818)
680a03628 server : support typed content input for /v1/embeddings endpoint (#29556)
```

## 4. Prism delta — all 29 commits (`adfffbe41..origin/prism`)

```
e8fd209c9 2026-10-10 grammar: allow schema property order (#347)
668256445 2026-10-10 cuda: ptq1 sm86 rows1 (#340)
6684606ac 2026-10-09 ci: add Linux and Windows SYCL release packages (#339)      <- SYCL
8eaee8b7f 2026-10-09 cuda: fold the MoE router weighting and expert reduction into one kernel (#107)
2a42998c5 2026-10-09 cuda: PQ2_0 mat-vec kernel for 3-8 columns on Ada (#306)
8b0c19c8c 2026-10-09 CUDA: replace GGML_FA_ALL_QUANTS with GGML_FA_QUANTS (#28079) (#317)
56f21fb10 2026-10-09 kv-cache : limit seq_rm to the used cell range (#311)
bf197c43d 2026-10-09 server : reuse the buffers of evicted prompt checkpoints (#312)
527ea4d9f 2026-10-09 common : take the top-k straight from the logits when top-k starts the chain (#313)
5e9365f05 2026-10-09 metal: process five PTQ1 rows in dense mat-vec (#225)
0d1825501 2026-10-08 cuda: avoid short-query MMA FA crash with quantized V (#189)
c53526a09 2026-10-09 vulkan: dedicated mul_mat_vec shader for PTQ1_0 (dequant path) (#252)   <- Vulkan B580
4fbda1292 2026-10-07 arm: NEON + i8mm vec_dot for PTQ1_0 (#290)
d71861677 2026-10-07 speculative: enable prompt lookup for DFlash1 drafters (#334)
6bfcd79a2 2026-10-05 arm: NEON vec_dot for PQ2_0 (#265)
46d253262 2026-10-06 vulkan: support GPUs without hardware DP4A in mul_mat_vec_ptq1_0 ... (#291)  <- Vulkan
8e18ce3be 2026-10-05 cuda: keep the GDN state gather when its ids memory is reused (#318)
eaecb50c7 2026-10-05 speculative: add opt-in prompt lookup for DFlash2 (#304)
2459f68b5 2026-10-02 cuda: fused FWHT quantizer for 64-wide warps (#303)
a14c7de99 2026-10-02 sycl: XMX path for PQ2_0 and PTQ1_0 on 16-wide DPAS devices (#294)      <- SYCL BMG
f13265492 2026-10-02 webgpu: route up to 8 columns through the mat-vec kernel (#301)
f450c768f 2026-10-02 sycl: FWHT for widths above 512 and Kronecker sizes (#302)              <- SYCL
88c4bc60b 2026-09-29 cuda: bound mmvq rows by the per-slot stride for MUL_MAT_ID (#258)
3285e757a 2026-09-29 dflash: add beam selection and optimize small PQ2_0 verify batches (#284)
445fa8209 2026-09-29 metal: process four GDN state rows per SIMD group (#292)
5244ceade 2026-09-29 cuda: Bonsai 2 27B at the full 262k window with the MTP head on 12 GB Ada (#221)
87268f775 2026-09-28 sycl: dequantize PTQ1_0 and PQ2_0 prompt batches to FP16 (#278)         <- SYCL
79971a480 2026-09-27 metal: fold SwiGLU into the signed FWHT, and narrow the last qwen35 layer ... (#287)
84445367f 2026-09-27 sycl: pick the src1 fp16 conversion from the runtime oneDNN switch (#288) <- SYCL
```

---

## 5. Does stock now support the Prism PQ2_0 / PTQ1_0 types? — **No.**

- Origin/master `ggml/include/ggml.h` enum is **byte-identical to local HEAD** at the tail:
  `GGML_TYPE_Q1_0 = 41, GGML_TYPE_Q2_0 = 42, GGML_TYPE_COUNT = 43`. No PQ types added.
- `git grep -l -E 'PQ2_0|PTQ1_0' origin/master` → **0 files**; `ggml.c` → 0 hits.
- Prism side still defines them privately: `ggml/include/ggml.h:435 GGML_TYPE_PQ2_0 = 142`,
  `:436 GGML_TYPE_PTQ1_0 = 143`, plus `GGML_FTYPE_MOSTLY_PQ2_0 = 128 / PTQ1_0 = 129`; 82 files reference them.

**Consequence: one stock build cannot load Prism-format (`PQ2_0`/`PTQ1_0`) GGUFs** — the loader has no
such type. The two builds stay complementary.

**Nuance worth knowing:** stock *did* pick up the Bonsai-2-27B architecture — `a9d27ac69 model : support
for Prism Bonsai 2 27B (#29600)` (authored by `bri-prism`, co-authored by ggml-org's Gerganov). It adds
`prism.hadamard.*` KV metadata (`src/llama-arch.{cpp,h}`, `src/llama-model.cpp`, `src/models/qwen35.cpp`,
`conversion/{base,qwen}.py`, `gguf-py/gguf/constants.py`) — i.e. stock can run a Bonsai-2 **re-quantized
to stock types** (`Q1_0`/`Q2_0`/`MXFP4`…), not the native Prism files.

## 6. SYCL feasibility on this box

**Host facts (read-only):**
- GPU: `Intel Corporation Battlemage G21 [Arc B580]` (BMG-G21, Xe2 / 16-wide DPAS). `xe` driver;
  `level-zero-loader 1.32.0`, `intel-compute-runtime 26.31.39395.13`, `vulkan-intel/mesa 26.2.2`,
  `vulkan-icd-loader`, `clinfo` present. Kernel `7.2.5-3-omarchy` (≥6.8 → `GGML_SYCL_HOST_MEM_FALLBACK` OK).
- `/dev/dri/renderD128..130` are `crw-rw-rw-` (world-rw) → L0 access works even though the user is **not**
  in `render`/`video` (`groups` = `nexuslink wheel docker`). No `usermod` needed here, unlike the docs' advice.
- `/opt/intel` **absent**; no `icpx`, `icx`, `sycl-ls` on PATH → oneAPI not installed.

**Packaging (Arch):**
- `extra/intel-oneapi-toolkit 2026.0.1.27` — single package, `Provides: intel-oneapi-dpcpp-cpp,
  intel-oneapi-mkl, intel-oneapi-dnnl, intel-oneapi-dpl, intel-oneapi-tbb, intel-oneapi-base-toolkit=2026.0.1.27`,
  `Depends: level-zero-loader`. **2.06 GiB download / 9.05 GiB installed**, installs under
  `/opt/intel/oneapi/2026.0/` (`bin/icpx`, `bin/icx`, `bin/sycl-ls`, `…/dnnl 3.11.2`, `…/dpl 2022.12`,
  `…/mkl 2026.0`; libs registered via `/etc/ld.so.conf.d/intel-oneapi-toolkit.conf`).
  → one `pacman -S intel-oneapi-toolkit` covers the whole documented dependency set.
- Also available separately: `extra/intel-oneapi-dpcpp-cpp 2026.0.0_947` (compiler only),
  `extra/onednn 3.11.3` (DNNL). AUR carries `intel-oneapi-basekit-2025 2025.3.2-1` (and older
  `intel-oneapi-basekit`), not needed since `extra` has the toolkit.
- Sources: `pacman -Ss/-Si` on this box; https://archlinux.org/packages/extra/x86_64/intel-oneapi-toolkit/files/
  (installs to `/opt/intel/oneapi/2026.0/bin/icpx|icx|sycl-ls`, dnnl/dpl/mkl present);
  https://archlinux.org/packages/extra/x86_64/intel-oneapi-dpcpp-cpp/ (2026.0.0_947-1, 162.7 MB);
  https://aur.archlinux.org/packages/intel-oneapi-basekit-2025 (2025.3.2-1).

**Docs at origin tip (`docs/backend/SYCL.md`, read via `git show origin/master:...`):**
- Verified-devices table lists **`Intel Arc B-Series | Support | Arc B580`** explicitly; also Arc A-Series,
  built-in Arc (MTL/ARL/LNL), Data Center Max/Flex.
- News 2026.09: recommends **oneAPI Toolkit 2026.1**; measured on **Arc B570** prompt-processing
  1331 vs 434 t/s (3.1×) vs the 2025.3 build. Arch Linux appears in the verified-OS row.
- Build (Linux): `./examples/sycl/build.sh` or
  `cmake -B build -DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx [-DGGML_SYCL_F16=ON]`.
  Deps listed: DPC++ compiler/runtime, oneDPL, oneDNN, oneMKL.
  `docs/build.md` §SYCL just links here; its §Intel oneMKL is the **CPU-BLAS** path (not GPU).
- B580-relevant knobs: `GGML_SYCL_DEVICE_ARCH` (AOT offload-arch), `GGML_SYCL_ENABLE_MKL_FA[+_MAX_KV]`,
  `GGML_SYCL_XMX_GATHER_TYPES` (Arc A/B XMX dequant-GEMM, e.g. `GGML_SYCL_XMX_GATHER_SHAPES` bit 1/2/4/8
  are the Xe2 XMX shapes), `GGML_SYCL_SPARSE_FA`, `GGML_SYCL_ENABLE_VMM`, and
  `GGML_SYCL_USM_SYSTEM` (documented as **Xe2+/BMG, Linux only, needs `CONFIG_DRM_XE_GPUSVM`**).
  Precision: `GGML_SYCL_DYNAMIC_PRECISION` `F16` (fast) / `BF16` / `TF32` (Xe2+).

**Prism fork SYCL status** (this is the part that matters for Bonsai):
- `a14c7de99 sycl: XMX path for PQ2_0 and PTQ1_0 on 16-wide DPAS devices (#294)` — adds an XMX/DPAS path
  for the Prism-private types on **Xe2 (Battlemage, Lunar Lake)**; replaces the FP16-dequant prompt path
  (`87268f775`) and MMVQ. Reported on Arc Pro B50 / oneAPI 2026.1 / L0 / `xe`: **27B PQ2_0 pp128 148→346 t/s
  (2.33×)**, tg64 12.4→16.5 (+33%); 27B PTQ1_0 pp128 127→348 (2.74×). Gate knob `GGML_SYCL_DISABLE_XMX=1`.
- `ggml/src/ggml-sycl/CMakeLists.txt` builds that XMX path **only when `GGML_SYCL_DEVICE_ARCH` is all
  16-wide DPAS** (`bmg|xe2|xe3|pvc|lnl|ptl|wcl|nvl|cri`); otherwise it prints
  *"…includes a device without 16-wide DPAS, not building the PQ2_0/PTQ1_0 XMX path"*. → for the B580 the
  knob is **`-DGGML_SYCL_DEVICE_ARCH=bmg`**.
- `6684606ac ci: add Linux and Windows SYCL release packages (#339)` + `docs/backend/SYCL-RELEASE.md`:
  Prism now ships SYCL release archives (Linux x64 FP32/FP16), built on plain Ubuntu runners and targeting
  **oneAPI 2025.3.3**, needing the matching oneMKL/oneDNN/SYCL runtime installed to run. No GPU needed to
  *build* them, and they say compilation does not validate correctness/perf on Intel GPU.
- Version note: Prism release pkgs assume **oneAPI 2025.3.3**; stock docs recommend **2026.1**; Arch ships
  **2026.0.x**. A SYCL build here is therefore between the two vendor-verified points — expected to work,
  but not a blessed combination.

## 7. Recommendations

| action | verdict | why |
|---|---|---|
| **Update stock** (`a97cce86a`→`358a420ec`, ff) | **Yes** | 354 commits for a pure-Vulkan rebuild; direct wins on the B580: `5c200e0c8` (Intel perf GDN), `dac308739`/`b3daa077a` (sparse quantized-KV FA), `526247161`/`6c59c4007` (Vulkan correctness); plus kv-cache (`210791069`), the host-mem MoE expert cache (`d6cf9acb2`, `c811cb8f0`) that underpins `--n-cpu-moe`/`-ot`, and the Bonsai-2 arch. Cheap, low risk, no GPU during build. Caveat: it still **cannot load Prism PQ2_0/PTQ1_0 files** (§5). |
| **Update prism** (`adfffbe41`→`e8fd209c9`, ff) | **Yes** | 29 solid commits: Vulkan `mul_mat_vec` PTQ1_0 shader (`c53526a09`) and DP4A-less fallback (`46d253262`) on our exact backend, speculative prompt-lookup for DFlash (`d71861677`, `eaecb50c7`), plus the SYCL XMX path we'd want. Fast-forward, no conflict. |
| **Try SYCL** | **Yes, highest-upside — after the game closes** | Everything needed is one `pacman -S intel-oneapi-toolkit` (2.06 GiB). The B580 is a *listed verified* SYCL device, and Prism's fork has a kernel specifically tuned for it (§6): BMG 27B PQ2_0 ~2.3× pp / +33% tg over the current prism path. Build is CPU-only and won't touch the GPU; only running/benchmarking does — so sequence it after ARC Raiders exits. Use `-DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DGGML_SYCL_F16=ON -DGGML_SYCL_DEVICE_ARCH=bmg`; Prism = the fork that also runs the native Bonsai PQ2_0/PTQ1_0 weights. |

**One-build-for-both:** not possible today — stock has no `PQ2_0`/`PTQ1_0` types, so the Prism fork remains
required for the native Bonsai files. If both are wanted, plan two build trees (or SYCL + a shared oneDNN).

**Watch-items already landed that affect this box's plans:**
- `b42b7e6d3 server: use port 9931 by default (#30159)` — pin `--port` in any systemd unit.
- `210791069` KV-cache rotation metadata — re-validates exactly the 32K→262K context question in `00-plan.md` risk #4.
