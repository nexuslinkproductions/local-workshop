# RESUME after reboot (2026-10-13 09:45) — read first

The PC was rebooted at 09:45; every agent and process died mid-task. Resume from files on disk, do not redo finished work.

State after reboot (orchestrator verified):
- NVIDIA driver active: GT 1030 is `Vulkan1` (2 GB); B580 is still `Vulkan0` and `SYCL0`; Ryzen iGPU is `Vulkan2`. Keep every config on Vulkan0/SYCL0.
- Monitor names CHANGED: DP-1 2560x1440 (main), DP-2 1920x1200, HDMI-A-3 1920x1200 (were DP-3/DP-4/HDMI-A-5). Fix any `grim -o DP-4` / `-o DP-3` in bench scripts to the new names before taking screenshots.
- Root tunings re-applied and now persistent: nvme0n1 scheduler bfq (udev rule), THP defrag defer+madvise and zram mem_limit 12G (tmpfiles).
- All model downloads are done and verified (research/21-small-quants.md): Gemma 4 12B QAT Q4_0 + mmproj, Gemma 4 12B Q8_0, Gemma 4 E4B Q4_K_M + mmproj, Qwen3.6 IQ3_XXS/Q3_K_XL, MiniCPM Q4_K_M/mix_q3, UI-Venus i1-Q3_K_M/i1-Q4_K_M. No downloads running.
- Nothing is loaded; no llama-server; GPU lock free.
- Voice is ENGLISH ONLY (Marcel). Piper rejected as sounding bad.
