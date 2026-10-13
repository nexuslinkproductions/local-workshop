#!/usr/bin/env bash
# Build whisper.cpp with CUDA 12.9 for the GT 1030 (GP108, sm_61).
# CUDA 13 dropped sm_61: do not change to the system CUDA or CUDA 13.
# Host compiler: conda-forge gcc 13 (system gcc 16 is rejected by CUDA 12.9).
set -euo pipefail
LAB="$HOME/NEXUS_AI_CENTER/LOCAL-AI-LAB"
ENV="$HOME/.local/cuda129-mamba/env"
SRC="$LAB/engines/whisper.cpp"
OUT="$LAB/voice/engines/whisper.cpp-cuda"
export PATH="$ENV/bin:$PATH" CUDA_HOME="$ENV" CUDAToolkit_ROOT="$ENV"
# clean dir every time: a stale cache kept the first failed link flags
rm -rf "$OUT"
cd "$LAB"
cmake -S "$SRC" -B "$OUT" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_LIBRARY_PATH="$ENV/targets/x86_64-linux/lib" \
  -DCUDAToolkit_ROOT="$ENV" \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,$ENV/lib -Wl,-rpath,$ENV/lib" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath-link,$ENV/lib -Wl,-rpath,$ENV/lib" \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=61 \
  -DCMAKE_CUDA_COMPILER="$ENV/bin/nvcc" \
  -DCMAKE_CUDA_HOST_COMPILER="$ENV/bin/x86_64-conda-linux-gnu-g++" \
  -DCMAKE_C_COMPILER="$ENV/bin/x86_64-conda-linux-gnu-gcc" \
  -DCMAKE_CXX_COMPILER="$ENV/bin/x86_64-conda-linux-gnu-g++" \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_SERVER=ON
cmake --build "$OUT" -j 6 --target whisper-cli whisper-server
echo BUILD_OK
