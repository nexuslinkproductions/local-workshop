# GT 1030 voice card — STATE (2026-10-13 ~13:30)

STOPPED by Marcel's order after kernel oops at 13:17:46 (xe_shrinker in kswapd0; kswapd0 dead; memory PSI full ~35-50%). Reboot required. No processes of this lane are running; nvidia-smi 4 MiB; `bench/.gpu-reset-ack` not created; lock not held.

## Done and verified
- CUDA 12.9 toolchain: `~/.local/cuda129-mamba/env` (nvcc 12.9.86, cudart/cublas 12.9, host gcc 13.4 conda-forge).
- CUDA whisper.cpp: `voice/engines/whisper.cpp-cuda/bin/whisper-cli`, `whisper-server` (BUILD_OK; sm_61; `ldd` resolves cudart/cublas to env). Fix for link: `-Wl,-rpath-link,$ENV/lib` in EXE/SHARED linker flags + `CMAKE_LIBRARY_PATH=$ENV/targets/x86_64-linux/lib`.
- CPU whisper.cpp: `voice/engines/whisper.cpp-cpu/bin/whisper-cli` (BUILD_OK).
- Benchmark: 54 runs, all rc=0 (`voice/gt1030-stt/results.json`, aggregate with `python3 voice/gt1030-stt/aggregate_stt.py`).

| mode | model | total ms (inference) | RTF | peak VRAM MiB |
|---|---|---|---|---|
| gpu | small.en | 1731 | 0.339 | 876 |
| gpu | medium.en-q5_0 | 2399 | 0.447 | 1252 |
| gpu | large-v3-turbo-q5_0 | 3171 | 0.591 | 940 |
| cpu 6 cores | small.en | 1673 | 0.315 | — |
| cpu 6 cores | medium.en-q5_0 | 4595 | 0.914 | — |
| cpu 6 cores | large-v3-turbo-q5_0 | 7024 | 1.414 | — |

WER 0.000 on all 3 clips for every model after number normalisation (3 clips cannot separate the models on accuracy).

Pick (provisional): large-v3-turbo-q5_0 on GPU (fits, 1108 MiB free). Alternative for latency: small.en.

## NOT done
- whisper-server HTTP test: FAILED to run. Watchdog aborted it at 13:28:55 (`psi_mem_full` system-wide, from the gemma lane), server rc=9, no HTTP answer. Not a server fault — unverified.
- Kokoro bm_lewis/bm_fable on GT 1030: not started.

## Resume after reboot
1. Check the host: `nvidia-smi` (GT 1030 must show 4 MiB), `journalctl -k -b | grep -i "xe\|kswapd" | tail` (confirm the reboot cleared the oops).
2. Rebuild is NOT needed (binaries in `voice/engines/whisper.cpp-{cuda,cpu}/bin`). If missing: `bash voice/gt1030-stt/build-whisper-cuda.sh` and `build-whisper-cpu.sh` (both under `flock -s bench/.gpu.lock`).
3. HTTP test (one run at a time, under lock + watchdog; stops the server after):
   `bash voice/gt1030-stt/serve-test.sh` (output: `logs-gt1030/serve-test.out`). Only if `/proc/pressure/memory` full avg10 < 1.0.
4. Start command for the service (after the test passes):
   The service holds no lock; start it with
   `WATCH_IO_GRACE_S=20 bash bench/watchdog.sh gt1030-whisper-server -- taskset -c 6-11 voice/engines/whisper.cpp-cuda/bin/whisper-server -m models/stt/whisper/ggml-large-v3-turbo-q5_0.bin --host 127.0.0.1 --port 8178 -t 6 -l en`
   HTTP one-liner: `curl -s http://127.0.0.1:8178/inference -F file=@voice/gt1030-stt/clips/c2-battery.wav -F response_format=json`
   Note: watchdog wraps the server; its memory-PSI trip will kill it under system memory pressure (intended).
5. Optional: re-run the bench with `python3 voice/gt1030-stt/bench_stt.py gpu` (lock-serialised; slow while the B580 chain holds the lock).

## Logs
- `logs-gt1030/build-whisper-cuda*.log` (attempts 1-2 failed, final BUILD_OK), `logs-gt1030/build-whisper-cpu.log`
- `logs-gt1030/bench/{gpu,cpu}/...` raw per run; `logs-gt1030/bench-run.log`
- `logs-gt1030/serve-test.log`, `logs-gt1030/serve-test.out`, `logs-gt1030/serve-test-run.out`
- `bench/results-matrix.tsv`: ABORT-LAG rows from this lane (4 io-trips from the first pass, 1 mem-trip at 13:28:55) — not deleted.
- Kokoro: not started.
