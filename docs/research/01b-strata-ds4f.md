# Strata (Niko1221/Strata) — Intel Arc B580 + Qwen3.8 Flash-Next recipe

Race lane B (independent of `01-strata.md`). Read-only recon: GitHub REST API + raw.githubusercontent.com +
huggingface.co API. Nothing cloned, nothing built. All numbers below are quoted from what was read; repo
revision read = default branch `main`, repo `pushed_at` 2026-10-12T17:28:20Z, 22,639 stars, 849 open issues,
MIT, "language": C++, latest release `v0.1.43.1` (2026-10-12).

Provenance note: two reads of `GET /repos/Niko1221/Strata` minutes apart returned different `description`
strings (one said "125B MoE ... NVIDIA GPU", the other "on any consumer hardware"). Both were live API reads;
treat repo blurbs as unstable, the docs as the source.

## Backends (evidence: file path + URL)

| Backend | Status | Evidence |
|---|---|---|
| CUDA | primary, shipped engine | `src/kernels/cuda/*.cu` (≈50 kernels), `CMakeLists.txt` — https://github.com/Niko1221/Strata/tree/main/src/kernels/cuda |
| HIP/ROCm (AMD) | first-class via `--backend hip` | `cmake/hip_backend.cmake`, `include/strata/hip_compat/cuda_runtime.h`, `tests/hip/*` — https://github.com/Niko1221/Strata/blob/main/cmake/hip_backend.cmake |
| **SYCL / oneAPI (Intel)** | **experimental port of the whole engine, off by default** | `sycl/` (236 files), entry `sycl/CMakeLists.txt`, top-level option `-DSTRATA_ENABLE_SYCL=ON` — https://github.com/Niko1221/Strata/blob/main/docs/INTEL_ARC.md |
| CPU (Strata's own kernels) | only the *expert share* beside a GPU — AVX1/AVX2/AVX-512 GEMV + pool; **not a standalone backend** | `include/strata/kernels/cpu/`, `src/kernels/cpu/` — https://github.com/Niko1221/Strata/tree/main/src/kernels/cpu |
| Vulkan | **not an inference backend.** Appears only in the *vision/image encoder* path on AMD/Windows | `docs/` + PRs #1768, #1789, #2060 ("images ... through Vulkan") — https://github.com/Niko1221/Strata/pull/2060 |
| Metal / OpenCL (as a runtime target) | none found in the tree | full tree scan, 3,414 entries |

`setup.py` accepts `--backend` with `choices=["cuda","hip","sycl"]` (setup.py:4926). There is no CPU backend.
`lights` on the Intel path: SYCL + Level Zero, **not Vulkan** — the repo's Vulkan mentions are AMD vision.
`docs/INTEL_ARC.md`: "the Intel build is a separate CMake target, off by default"; "**no ready-made Intel
engine** in the release zips. You build it from source on Linux."

## Intel Arc status

- Arc support landed in 0.1.39 as `sycl/` ported from PR #423 by maxfridbe ("INTEL B70 32gb support", closed).
  Maintainer, issue #573: "the maintainers have no Intel GPU ... Every result on Arc hardware below comes from
  the community." (docs/INTEL_ARC.md; https://github.com/Niko1221/Strata/issues/573)
- **B580 is a named, first-class id in the Intel setup path**: `sycl/setup_intel.py:45` —
  `INTEL_ARC = {... "e20b": ("Arc B580", 12.0) ...}`; detection walks `/sys/class/drm/cardN` for vendor 0x8086
  under `xe`/`i915`. AOT target for the B580 = **`bmg-g21`** ("B580, B570 and Pro B60: bmg-g21", docs/INTEL.md
  "How to build it"). https://github.com/Niko1221/Strata/blob/main/sycl/setup_intel.py
- Linux only. "There is no Windows path yet" (docs/INTEL_ARC.md "Windows"); a community Windows 11 port exists
  only as an issue body (#1552), self-described, not in the repo.
- Multi-GPU on Arc is **broken**: `--peer-device` is stubbed ("the second-GPU expert tier is not ported to SYCL
  yet", `sycl/src/core/peer_experts.cpp`); `--layer-split` across two SYCL devices dies with
  `UR_RESULT_ERROR_DEVICE_LOST` then "Cannot submit to a queue with a dependency from a graph that is associated
  with a different context" (`sycl/src/core/verify.cpp:1706`) — command-graph capture is single-context.
  docs/A770_SPEED_SPEC.md ("Dual-GPU on the A770 + B580 ... BROKEN in the SYCL port"); issue #1861 (2× B580,
  same crash). Single GPU works in that same report: "decode 33.4 tok/s".
- Known-good env on `xe`: `SYCL_CACHE_PERSISTENT=0` (persistent JIT cache segfaults on Xe2),
  `STRATA_VERIFY_NO_HOST=1` **required whenever part of the experts is not in VRAM** (NaN logits without it),
  `ONEAPI_DEVICE_SELECTOR=level_zero:*` for multi-device, `IGC_EnableDPEmulation` only matters on Alchemist.
  `sycl/serve/strata-sycl.sh` sets `STRATA_VERIFY_DEVICE_PLAN=1 STRATA_VERIFY_NO_HOST=1 STRATA_STAGER_THREADS=12`.
- Hard rule: **never allocate past VRAM.** "On the `xe` driver, an allocation past VRAM can push buffers into RAM
  until the machine runs out of memory and stalls" ... "A 262K request did exactly that" (docs/INTEL.md).

## Flash-Next recipe (12 GB GPU + 64 GB RAM, Intel Arc B580)

Model = Qwen3.8-Flash-Next, 125B MoE, 24,576 experts, 48 layers, 10 active per token; runs as GGUF.
Repo's RAM pick for 64 GB: **IQ2_XS** (recommended) or IQ3_XXS / IQ3_S (docs/MODELS.md).

Files (sizes from the HuggingFace tree API, `?recursive=true&expand=true`):

| File | Size |
|---|---|
| `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` → `IQ2_XS/...-00001-of-00002.gguf` (shard 1, experts+dense) | **39.23 GB** |
| same repo → `IQ2_XS/...-00002-of-00002.gguf` (shard 2, the 28.8 GB lookup-table tensor) | **28.80 GB** |
| same repo → `mmproj-...-BF16.gguf` (vision, optional; images are **not** wired on Intel) | 0.91 GB |
| MTP draft layer, pulled by `tools/mtp_fetch.py` from `Qwen/Qwen3.8-Flash-Next` (BF16, 360 GB in 131 shards) via HTTP range reads | "~6 GB" (docs/MODELS.md) |
| Alternatives, same repo: Q2_0 37.62 GB + 28.80; IQ3_XXS 47.04 + 28.80; IQ3_S 54.82 + 28.80; Coder IQ1_M 29.61 + 28.80 | — |

Docs quote the download as "66-76 GB for the three smaller sizes"; 64 GB RAM "runs every size". Shard 2 is
**never loaded**: it stays on the SSD and is read by row.

Build (Linux, Docker path that `setup --backend sycl` itself uses — docs/INTEL_ARC.md; about 6 min image,
~3 min build, 13 GB image):

```sh
cd Strata
docker build -t strata-sycl-dev sycl/tools
H=$(basename "$PWD")
# For the B580: AOT=bmg-g21  (docs list bmg-g31=B70, bmg-g21=B580/B570/Pro B60; the example line in the docs
# shows bmg-g31 and must be changed for a B580.)
docker run --rm -u $(id -u):$(id -g) -v "$PWD/..:/work" -e AOT=bmg-g21 -e REPO=/work/$H \
    -e BUILD_DIR=/work/$H/build-sycl-aot strata-sycl-dev "cd /work/$H && bash sycl/tools/build.sh strata"
./setup.sh --backend sycl --model IQ2_XS --context 32768
```

Non-Docker variant (docs/INTEL_ARC.md "Build without Docker"): install
`intel-oneapi-compiler-dpcpp-cpp intel-oneapi-mkl-devel ninja-build cmake git`, then
`cmake -S sycl -B build-sycl -G Ninja -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx
[-DSTRATA_SYCL_AOT=bmg-g21] && cmake --build build-sycl --target strata`, and point setup at the binary with
`STRATA_SYCL_BIN` (`build-sycl/sycl/strata` if the top-level option was used). `ocloc` (package `intel-ocloc`)
is needed for the AOT build; without AOT the first start JITs every kernel (~47 s, and `SYCL_CACHE_PERSISTENT=0`
means it repeats).

Engine flags the Intel config carries (docs/INTEL.md, `sycl/setup_intel.py:to_sycl`): `--stream-experts`
(no host copy; every expert not in the VRAM cache is read from a pinned host mirror, `STRATA_MIRROR_MIB`),
KV streaming `--kv-resident 32768` from 64K up, VRAM reserve 1,024 MiB up to 32K / 2,048 MiB above (300 MiB only
on a card under 12 GB), MTP `--spec 4 --spec-min-p 0.5 --mtp <draft>`, `--ple-io ram`, expert profile
`data/expert-profile-sycl.bin`.
On this box: **B580 = exactly 12.0 GB** as reported by the id table, so `small_card()` (`0 < vram < 12.0 or i915`)
is false — the B580 gets the normal reserves, not the A750-style RAM-arena config. With 12 GB, most of the
~36 GB of IQ2_XS experts sit in the pinned host mirror and are read over PCIe.

## Reported speeds with hardware (all quotes, no extrapolation)

| Where | Hardware | Number |
|---|---|---|
| docs/INTEL_ARC.md table, PR #423 | **Arc B580 12 GB, WSL2** | "IQ2_XS ~21 tok/s, Coder ~15 tok/s; **device loss also seen**" |
| issue #573 (Niko1221, 2026-10-04) | same tester | "about 15-21 tok/s and also saw a device loss, so on a 12 GB card it is very much experimental for now" |
| issue #1552 (community, self-reported, W11 native port, engine 0.1.40.4) | **Arc B580 12 GB**, Ryzen 5 5600, 64 GB | "21.0 tok/s" decode; 74,213-token prompt + 3,649 out tokens at 17.8 tok/s; 256K context claim. Not in-repo, unverified |
| issue #1861 (2026-10-10) | **2× B580**, engine 0.1.41-sycl AOT bmg-g21, Swift IQ3_XXS | single GPU: "prompt 41.7 tok/s, decode 33.4 tok/s"; two GPUs: engine dies on first request |
| docs/A770_SPEED_SPEC.md | A770 16 GB (i915/xe), Coder IQ1_M | ceiling "~12.0-12.6 tok/s"; A770+B580 layer split broken |
| docs/INTEL_ARC.md | Arc Pro B70 32 GB (author), B50 16 GB, single B60 24 GB, 2×B60 | 70-78 / 23-27 / 11.9 / 56-61 tok/s decode |

## Server / API mode

Yes, and it is the *same* server on Intel — "behind the same Strata server: OpenAI and Anthropic APIs,
streaming, tool calls, MCP and the web app all unchanged" (docs/INTEL.md, line 3).
`serve/server.py` (6,627 lines) serves `POST /v1/chat/completions`, `POST /v1/messages`,
`POST /v1/responses`, `GET /v1/models`, `/models`, `/props`, `/slots`, `/health`, `/mcp`; default port 8080;
web app at `http://127.0.0.1:8080` (README). Intel wraps it from outside without editing `serve/`:
`sycl/serve/server_intel.py` ("the same server, with the Intel pieces added from outside", 314 lines) plus
`sycl/serve/strata-sycl.sh` as the engine `exe` (`docker run --device /dev/dri ...`), and
`sycl/serve/xe_telemetry.py` for Arc GPU telemetry in the Monitor tab. MCP server: `tools/strata_mcp.py`.
`run-<model>.sh` written by setup starts `server_intel.py`.

## Verdicts

**"Runs on B580 GPU" — VERIFIED (runs), with unresolved stability risk.** The B580 is a named id in the Intel
setup path, and independent community reports show it decoding on B580 hardware (15-21 tok/s on 12 GB via WSL2
per the repo's own table and the maintainer; 21 tok/s and 33.4 tok/s in two further reports). Caveats that are
part of the verdict: Linux + Docker + from-source build only, AOT target `bmg-g21`, no images, engine marked
experimental with **device loss observed on the B580 specifically**, and 2-card splits crashing. "Verified" here
means the engine has run real tokens on a B580, not that it is supported or stable on one.

**"Runs CPU-only with useful speed" — NOT VERIFIED.** No CPU backend exists: `setup.py --backend` choices are
`cuda|hip|sycl`; the README's requirements table lists NVIDIA/AMD/Arc GPUs and a GPU driver; the CPU code in
`src/kernels/cpu/` is the expert *share* computed alongside the GPU in every documented mode. The only
documented CPU-device execution is the SYCL kernel parity suite run with
`ONEAPI_DEVICE_SELECTOR=opencl:cpu`, where "14 of 25 pass" and it is explicitly "a check that the kernels compile
and compute, not a test of an Arc" (docs/INTEL_ARC.md).

## Fit against this machine (facts only)

- Arc B580 12 GB → `e20b`, "Arc B580", 12.0 in `sycl/setup_intel.py`; AOT `bmg-g21`. ✔
- Level Zero 1.32 + intel-compute-runtime present → matches the docs' Linux prerequisite
  (`intel-opencl-icd libze1 libze-intel-gpu1`) and the B60 report's "Level Zero V2, NEO 26.09.x" stack. ✔
- Mesa ANV Vulkan 26.2.2 is **irrelevant** to this path (SYCL/Level Zero, not Vulkan). ✔
- torch 2.14+xpu / CUDA-less host: irrelevant — Strata ships its own engine; the Python layer is stdlib +
  the setup venv.
- RAM: 64 GB total. Holds the pinned mirror for IQ2_XS in principle (experts ~36 GB minus what 12 GB of VRAM
  caches), but no B580-class measurement of that mirror's size exists in the repo — the closest is the B70
  IQ3_S case (22 GiB VRAM cache + host mirror). Treat 12 GB + 64 GB as **unmeasured for this model size**;
  the observed B580 numbers were IQ2_XS (~21 tok/s) and Coder (~15 tok/s). One documented failure mode to
  watch: on i915 a single `sycl::malloc_host` above a few GB failed (`STRATA_MIRROR_MIB` 8,192 refused) —
  documented for the A750, not for `xe`/B580.

## Gaps I could not close (no fabrication)

- No B580 test in the repo's own `bench/results/`; all B580 rows are PR/issue text.
- No documented `--check`/VRAM figure for a 12 GB card with IQ2_XS resident-expert counts.
- Windows/native and multi-B580 paths are unusable as documented.
