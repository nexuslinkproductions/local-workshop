#!/usr/bin/env bash
# CPU-only whisper.cpp baseline (system gcc, no CUDA). Same source as the CUDA build.
set -euo pipefail
LAB="$HOME/NEXUS_AI_CENTER/LOCAL-AI-LAB"
SRC="$LAB/engines/whisper.cpp"
OUT="$LAB/voice/engines/whisper.cpp-cpu"
cd "$LAB"
rm -rf "$OUT"
cmake -S "$SRC" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=OFF \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=OFF
cmake --build "$OUT" -j 6 --target whisper-cli
echo BUILD_OK
