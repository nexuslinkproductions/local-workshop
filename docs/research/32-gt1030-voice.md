# 32 — GT 1030 voice card: whisper.cpp STT on CUDA 12.9 (sm_61) vs CPU

Status: IN PROGRESS (written incrementally). Date: 2026-10-13.

## Setup (done, verified)

- Toolchain: `~/.local/cuda129-mamba/env` (conda-forge via micromamba), nvcc 12.9.86,
  cudart/cublas 12.9.x, host compiler `x86_64-conda-linux-gnu-g++` (gcc 13.4). System gcc 16 not used for CUDA.
  Log: `logs-gt1030/install-cuda129.log` (empty; env verified by `nvcc --version` and `ls env/lib`).
- whisper.cpp source: `engines/whisper.cpp` (commit 0c7be69, 2026-10-12).
- CUDA build: `voice/engines/whisper.cpp-cuda/bin/whisper-cli`, `whisper-server`
  (GGML_CUDA=ON, CMAKE_CUDA_ARCHITECTURES=61). Script: `voice/gt1030-stt/build-whisper-cuda.sh`.
  Log: `logs-gt1030/build-whisper-cuda.log` (BUILD_OK).
  - Attempt 1 failed at link (`undefined reference ... @libcudart.so.12`), log kept as
    `logs-gt1030/build-whisper-cuda-attempt1-linkfail.log`.
  - Attempt 2 failed because the conda ld did not find `libcudart.so.12`, `libcublas.so.12`,
    `libcublasLt.so.12`, `libgomp.so.1` at link time (`ld: warning: ... not found (try using -rpath or -rpath-link)`),
    log kept as `logs-gt1030/build-whisper-cuda-attempt2-rpathlink-missing.log`.
  - Fix: `-DCMAKE_EXE_LINKER_FLAGS/-DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath-link,$ENV/lib -Wl,-rpath,$ENV/lib"`
    plus `CMAKE_LIBRARY_PATH=$ENV/targets/x86_64-linux/lib`, clean build dir.
  - `ldd whisper-cli`: libcudart.so.12, libcublas.so.12, libcublasLt.so.12, libgomp.so.1 all resolve to the env; libcuda.so.1 from /usr/lib (driver).
- CPU build: `voice/engines/whisper.cpp-cpu/bin/whisper-cli` (GGML_CUDA=OFF, system gcc).
  Script: `voice/gt1030-stt/build-whisper-cpu.sh`. Log: `logs-gt1030/build-whisper-cpu.log` (BUILD_OK).
- Smoke test (GPU detected): `logs-gt1030/smoke/small-c1.log`:
  `ggml_cuda_init: found 1 CUDA devices (Total VRAM: 1993 MiB)`, device 0 = GT 1030, compute 6.1,
  `using CUDA0 backend`, small.en CUDA0 weights 487 MB, transcript correct, total 1803.59 ms (load 341 ms).

## Benchmark method

- Clips: `voice/gt1030-stt/clips/c{1,2,3}-*.wav` (16 kHz, mono, 16-bit; already in that format), reference text in `clips/refs.tsv`.
  Durations: c1 5.90 s, c2 4.81 s, c3 5.38 s.
- Each run: `voice/gt1030-stt/run_one.sh` → `flock -x bench/.gpu.lock` → `bench/watchdog.sh` → `taskset -c 6-11 whisper-cli -t 6 -l en -nt`.
  GPU runs sampled with `nvidia-smi --query-gpu=memory.used -lms 100`. Driver total 2048 MiB.
- 3 models × 3 clips × 3 reps × {GPU, CPU} = 54 runs. Driver: `voice/gt1030-stt/bench_stt.py`.
- Latency = whisper's own `total time` (encode+decode, model load excluded; load reported separately). Wall = full process incl. load.
- WER: word-level Levenshtein, lowercase, punctuation stripped, against refs.tsv.
- Raw per-run logs: `logs-gt1030/bench/{gpu,cpu}/<model>/<clip>-r<k>.{txt,err,rc,wall_ms,smi.csv}`. Results: `voice/gt1030-stt/results.json`.
- Watchdog note: the first bench pass aborted 4 runs with `ABORT-LAG psi_io_full` (IO PSI avg10 1.02–1.24 during model loads and from other lanes; rows in `bench/results-matrix.tsv`, not deleted).
  Re-run with `WATCH_IO_GRACE_S=20` (documented opt-in in watchdog.sh: skips only the io-full trip for the first 20 s; memory trips stay on).
- Lock contention: the GPU lock was held by the B580 chief256k chain (`flock -x -w 7200`) during the re-run; my runs wait their turn.

## Results

Source: `python3 voice/gt1030-stt/aggregate_stt.py` over the raw files (54 runs, rc=0 for all, 3 clips × 3 reps per cell, so n=9 everywhere).

| mode | model | n | total ms (inference) | wall ms (incl. load) | load ms | RTF | WER | peak VRAM MiB |
|---|---|---|---|---|---|---|---|---|
| gpu | ggml-small.en | 9 | 1731 | 2023 | 263 | 0.339 | 0.000 | 876 |
| gpu | ggml-medium.en-q5_0 | 9 | 2399 | 3032 | 310 | 0.447 | 0.000 | 1252 |
| gpu | ggml-large-v3-turbo-q5_0 | 9 | 3171 | 4040 | 304 | 0.591 | 0.000 | 940 |
| cpu (6 cores) | ggml-small.en | 9 | 1673 | 2023 | 49 | 0.315 | 0.000 | — |
| cpu (6 cores) | ggml-medium.en-q5_0 | 9 | 4595 | 5059 | 53 | 0.914 | 0.000 | — |
| cpu (6 cores) | ggml-large-v3-turbo-q5_0 | 9 | 7024 | 7076 | 56 | 1.414 | 0.000 | — |

- Per-run raw: `logs-gt1030/bench/{gpu,cpu}/<model>/<clip>-r<k>.err` (whisper timings), `.txt` (hypothesis), `.smi.csv` (GPU, 100 ms samples), `.wall_ms`, `.rc`. Aggregated: `voice/gt1030-stt/results.json`.
- Peak VRAM = max `memory.used` sampled during the run (driver total 2048 MiB; baseline 4 MiB). Free ≥ 300 MiB requirement: all three pass (worst case medium, 796 MiB free).
- WER = 0.000 for every model on all 3 clips after number normalisation ("eighty percent" = "80%", "nine" = "9"). Before normalisation the scores differed only in formatting ("80%" vs "eighty percent"); the 3 clips are too easy to separate the models on accuracy. Hypotheses: `logs-gt1030/bench/gpu/*/c*-r1.txt`.
- Watchdog: 4 runs of the first pass were killed by `ABORT-LAG psi_io_full` during model loads (see method). Re-run with `WATCH_IO_GRACE_S=20`; no ABORT in the final pass.
- Lock: GPU and CPU runs both take `flock -x bench/.gpu.lock`; the B580 chief256k chain held the lock for long stretches, so runs queued (waits of up to ~10 min). The final CPU rep counts are from the runs that completed.

Reading: on this GPU the GT 1030 is not faster than 6 CPU cores for small.en (1731 vs 1673 ms), but medium is 1.9× faster and large-v3-turbo 2.2× faster than CPU. The real gain is moving that load off the CPU the desktop needs.

**Pick: ggml-large-v3-turbo-q5_0 on GPU.** It is the highest-accuracy of the three that fit (940 MiB peak, 1108 MiB free). The 3-clip WER cannot confirm that accuracy edge; it is the expected ranking from the model family, not measured here. Latency 3.2 s for a ~5 s clip. If Chief needs sub-2 s replies more than accuracy, switch to small.en (1.7 s, 876 MiB).

## Status at stop (2026-10-13 ~13:30)

- Stopped on Marcel's order after a kernel oops at 13:17:46 (xe_shrinker in kswapd0). Reboot required.
- Model pick (provisional): large-v3-turbo-q5_0 on GPU (940 MiB peak, 1108 MiB free). small.en if latency matters more (1.7 s).
- whisper-server HTTP test NOT verified: aborted by the watchdog at 13:28:55 (system `psi_mem_full`, from another lane); server rc=9, no answer.
- Kokoro bm_lewis/bm_fable on GT 1030: not started.
- Resume commands and full state: `voice/gt1030-stt/STATE.md`.
