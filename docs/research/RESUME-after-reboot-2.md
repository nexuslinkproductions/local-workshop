# RESUME after reboot #2 (2026-10-13 ~11:00) — read this first, every lane

## What happened
At 10:43:08 the BRIEF-27 context sweep started llama-server at ctx 262144: GPU compute engine timed out,
engine reset, GPU page faults ("Fault response: Unsuccessful -ENOENT"), devcoredump. The run continued
anyway; at 10:48:17 the 131072 run, during a ~32K-token prefill, hit UR_RESULT_ERROR_DEVICE_LOST and
the B580 wedged ("device wedged, needs recovery"). The B580 drives all 3 monitors: screens went black,
Marcel had to hard reboot. Every agent died with it.

## New hard rules (enforced in code since 11:01)
- bench/gate.sh `gpu_reset_unacked`: after ANY xe reset/wedge/timed-out job this boot, gate_check and
  serve/gate-run.sh refuse every GPU job until a human runs `touch bench/.gpu-reset-ack` (or reboots).
  Never create that file yourself. Never use --force.
- Gemma context is capped at 65536 (ctx 65536 measured OK: decode 32 t/s, short prompt). 131072 and
  262144 are BANNED until a dedicated, Marcel-approved test; they crashed the GPU.
- Even at 65536, large prompts are untested: ramp prompt size 4K -> 8K -> 16K -> 32K, one at a time,
  sampling VRAM (DRM fdinfo or xe sysfs) during prefill, and run gate_check between steps. First reset,
  page fault, or VRAM free < 1.0 GiB: STOP that ladder, kill the server, report. Do not retry.

## State on disk (landed before the crash)
- serve/config.yaml (llama-swap, primary gemma4-12b on :18080, ttl 600), serve/gemma4-12b-launch.sh,
  serve/gate-run.sh, serve/screen_locate.py (written; live smoke not done), serve/local-ai.service (OFF).
- Hermes `local-ai` provider: check ~/.hermes/config.yaml (a backup config.yaml.bak-local-ai-* should
  exist); context was registered as 16384 -> Hermes refuses (< 64,000). Must become 65536.
- Profile ~/.hermes/profiles/jarvis/ exists: lean, all routes local (19 text routes + vision ->
  127.0.0.1:18080 gemma4-12b), 8 tools, no tool_search bridge, no hindsight, measured 6,497 Gemma
  tokens (system 2,950 + tools 3,547). Marcel renamed it: **Chief**. Profile id `chief`.
- research/25-gemma4-variants.md: no reasoning distill has independent evidence of beating base Gemma 4
  12B; 2 yuxinlu1 distills downloaded (Q4_K_M 6.87 GiB) as gated candidates; also downloaded
  models/llm/unsloth/gemma-4-12B-it-qat-GGUF/ (UD-Q4_K_XL, mmproj-F16, **mtp-gemma-4-12B-it.gguf** =
  multi-token-prediction draft head, 254 MB).
- research/28a-d platform research, BRIEF-30 bake-off harness in ~/.hermes/cache/scratch/bakeoff/
  (proxy.py, mock_upstream.py, run_bakeoff.py; real run not done).
- voice/bakeoff/british/: Kokoro bm_george/lewis/daniel/fable + Chatterbox VCTK clones (p256, p270,
  p274, p287); Kyutai and Kani renders were in progress (check what exists). Magpie by index only.

## Policy decided with Marcel
- Thinking OFF by default so replies start fast; thinking only on request or for maths/multi-step.
  Marcel does not want to sit through an empty wait while it thinks.
- Delegation lane: haiku until lunch (DeepSeek peak pricing).
