# 11 — llama.cpp SYCL backend build (Arc B580)

**Status: built and verified.** stock llama.cpp, SYCL/Level-Zero backend, at the same
upstream commit as the Vulkan tip build. No benchmark or model load was run (owned by
the testing lane).

## Artifact

| | |
|---|---|
| Worktree | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/llama.cpp-sycl-tip` |
| Commit | `358a420ec4ed59b6b0be08b1d1f71dd478b99a99` — *graph: pad the KV dimension of the no-cache attention to 256 (#30416)* |
| Same commit as | `engines/llama.cpp-vulkan-tip` (Vulkan tip) ✓ |
| State | detached HEAD, tree clean; worktree already existed at this commit (no `worktree add` needed) |
| Toolchain | oneAPI DPC++/C++ 2026.0.0 (20260331), MKL 2026.0, oneDNN 3.11.2, L0 loader 1.32 |
| Binaries | `build/bin/` — 547 ninja targets, incl. `llama-cli`, `llama-bench`, `llama-server`, `libggml-sycl.so.0.26.0` |

## Configure (exact cmake line)

```
source ~/intel/oneapi-env.sh
cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DGGML_SYCL_F16=ON \
  -DGGML_SYCL_DEVICE_ARCH=bmg \
  -DDNNL_DIR=/home/nexuslink/intel/oneapi/dnnl/2026.0/lib/cmake/dnnl
```

The first four flags are verbatim from the worktree's `docs/backend/SYCL.md` §II.
`-DGGML_SYCL_DEVICE_ARCH=bmg` is the doc's optional `GGML_SYCL_DEVICE_ARCH`
(`docs/backend/SYCL.md` L783); `bmg` is the Battlemage value the ggml-sycl CMake regex
accepts (L234) and it selects the XMX dequant-GEMM sub-group size 16 path. AOT via
`spir64_gen` confirmed present in `build.ninja`. `-DDNNL_DIR` points at the separately
installed SYCL oneDNN (below).

Resolved by cmake: `GGML_SYCL_TARGET=INTEL`, `Found oneDNN: .../libdnnl.so.3.11`,
`Found .../libtbb.so.12`, `MKL_SYCL target` available, `GGML_SYCL_SUPPORT_LEVEL_ZERO_API ON`.

## Build

```
flock -s /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock cmake --build build -j 20
```

- **Wall time: 221 s** (00:10:32 → 00:14:13 CEST, `-j 20` on a 16-core host).
- Exit 0. **0 errors.** Warnings only: one `unused parameter 'gate'` in `ggml-sycl.cpp:5108`
  and deprecated `sycl::parallel_for` in `fattn-common.hpp:896` — both benign, upstream.

## Verification

```
$ ZES_ENABLE_SYSMAN=1 build/bin/llama-cli --list-devices
Available devices:
  SYCL0: Intel(R) Arc(TM) B580 Graphics (12216 MiB, 436 MiB free)

$ build/bin/llama-bench --help      # exit 0
Build with Macros:
  GGML_SYCL_DNNL: yes
  GGML_SYCL_F16: yes
  GGML_SYCL_SUPPORT_LEVEL_ZERO_API: yes
```

B580 appears as the sole, eponymous `SYCL0` device; Vulkan is not built into this engine,
so it is a clean SYCL-only measurement target. (`free` MiB varies — the GPU was busy.)

## Root-free components fetched / fixed (no sudo anywhere)

1. **oneDNN was missing.** The existing `~/intel/install-oneapi.sh` package set has no
   oneDNN, and Arch splits no standalone SYCL-oneDNN package — the only root-free source is
   `intel-oneapi-toolkit` (2.06 GiB, `Provides: intel-oneapi-dnnl`). Fetched its URL with
   `pacman -Sp`, then extracted **only** `opt/intel/oneapi/dnnl/**` (`--strip-components=3`)
   into `~/intel/oneapi` (~110 MB on disk). Without it cmake logs
   "oneDNN not found, disabling oneDNN support" and `GGML_SYCL_DNNL` would be 0.

2. **`TBBConfig.cmake` hardcodes `/opt/intel/oneapi/tbb/latest`** (which does not exist on a
   root-free install), so `TBB::tbb` was never created → two cmake errors from
   `dnnl-config.cmake` and `MKL::MKL_SYCL target will not be available`.
   `install-oneapi.sh` rewrites absolute *symlinks* but not hardcoded path *strings* in cmake.
   Fix (one file, `~/intel/oneapi/tbb/2023.0/lib/cmake/tbb/TBBConfig.cmake`):
   `_tbb_root` `/opt/intel/oneapi/tbb/latest` → `"${CMAKE_CURRENT_LIST_DIR}/../../.."`.
   (The `_bin_version` var is empty in the NAMES pattern, so it already matches
   `libtbb.so.12`; only the root was wrong.)

3. **Runtime loader path.** `libggml-sycl.so` has `NEEDED libdnnl.so.3` but its RUNPATH
   covers only mkl/tbb, not dnnl. Appended
   `export LD_LIBRARY_PATH=/home/nexuslink/intel/oneapi/dnnl/2026.0/lib:$LD_LIBRARY_PATH`
   to `~/intel/oneapi-env.sh` — **source that file before any build/bin binary**, otherwise
   the SYCL backend fails to load. Verified from a clean env.

## Caveat for interpreting results

Built with **oneAPI 2026.0** (what is installed). The doc's News notes 2026.1 gives ~3.1×
SYCL prompt-processing on Arc (B570: 1331 vs 434 t/s) — a portion of the SYCL-vs-Vulkan gap
may be toolchain, not backend. Also, `-DGGML_SYCL_DEVICE_ARCH=bmg` bakes a single AOT device
image (no JIT fallback); if it ever proves device-incompatible, rebuild with the doc's plain
four-flag command (drops AOT, keeps a JIT-capable `spir64` build).

## Repro / run

```
source ~/intel/oneapi-env.sh
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/llama.cpp-sycl-tip
ZES_ENABLE_SYSMAN=1 build/bin/llama-cli -m <model.gguf> -ngl 99 -sm none -mg 0
```
