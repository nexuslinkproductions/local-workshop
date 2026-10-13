# BRIEF-34: Chief at 256K context, reliably and fast (program lead) — 2026-10-13

You are the PROGRAM LEAD for this goal. Marcel wants Chief (Gemma 4 12B on the Intel Arc B580) to run a
full 256K context reliably, with no effort and great speed. You plan, run the GPU work in sequence, and
spawn your own leaf subagents (delegate_task) for research, reading and writing so you stay on the
decisions. Leaves run on whatever model the dispatcher gives them; give them complete, self-contained
briefs.

## Read first (in this order, do not crawl)
research/RESUME-after-reboot-2.md (hard rules), research/31-long-context-and-gt1030.md (VRAM math,
crash hypotheses, ladder design, -nkvo, compaction), research/27-gemma-in-hermes.md (serving setup,
64K ramp), research/26-b580-acceleration.md (MTP 2.25x), the tail of research/00-plan.md.

## Hard rules (non-negotiable)
- One GPU job at a time: `flock -x bench/.gpu.lock` (others queue on it: a speed agent, a kernel
  profiler, a voice agent). Wrap chains: `flock -x -w 7200 bench/.gpu.lock env MATRIX_LOCKED=1 bash X`.
- bench/gate.sh must pass; never --force; never create bench/.gpu-reset-ack (only Marcel may).
- Every server through bench/watchdog.sh + jobcap quiet mode; after EVERY step:
  `journalctl -k -b | grep -E 'GT0|wedged|DEVICE_LOST|Timedout'`. First reset/fault/DEVICE_LOST: stop the
  ladder, kill the server, write it up, do not retry, report.
- Display now: main + right monitor on the B580, left monitor on the AMD iGPU (survives a B580 wedge).
- Allowed reversible root change for the test only: `sudo sh -c 'echo 10000 >
  /sys/class/drm/card0/device/tile0/gt0/engines/ccs/job_timeout_ms'` (default 5000, resets on reboot;
  check the card index first: the B580 is the xe device 0000:03:00.0). Restore 5000 when done.
- Do not change Chief's live serve/config.yaml until a setting has passed the full ladder; keep backups.

## Workstreams (sequence GPU work; parallelise the rest via leaves)
1. VRAM budget at 256K: measure free VRAM now (one monitor moved off the B580); test KV cache types
   q8_0 vs q5_1/q4_0 (quality: perplexity on a fixed text + needle retrieval, see 4), -ub 512 vs 1024,
   mmproj placement (CPU or GT 1030 via the build's flags, if any; --no-mmproj-offload), with and without
   the MTP draft head (+ its own KV). Target: 256K loaded with >= 1.0 GiB free.
2. Crash root cause, carefully: at ctx 131072 ramp prefill 4K -> 8K -> 16K -> 32K -> 64K with -ub 512,
   sampling VRAM and GPU job durations (gpu_scheduler tracepoints if readable; else timing), first with
   the default 5000 ms timeout; only if it fails at a step, retry that single step once with 10000 ms.
   Then 262144 the same way. Report which knob makes it stable.
3. RAM fallback: a `gemma4-12b-long` entry with --no-kv-offload (-nkvo): measure load, VRAM, decode
   t/s at 8K/32K/64K filled, prefill t/s. Keep it if it is the only stable 256K path.
4. Quality at long context: a needle-in-a-haystack + multi-needle test (e.g. 5 facts spread through
   32K/64K/128K/256K of real text from LOCAL-AI-LAB/research/*.md) per KV type; record accuracy.
5. Speed at long context: decode t/s with 32K/128K already in context (MTP on), prefill t/s per stage;
   prompt-cache reuse (repeated prefix) timing.
6. Output: the recommended Chief long-context config (flags, KV type, -ub, timeout need or not, which
   llama-swap ids: fast 64K, long 256K), applied to serve/config.yaml ONLY after it passed 1-5, with
   Chief compaction thresholds updated for the long id (research/31 section 5 rule: threshold_tokens
   explicit, summary prefill must stay within a size proven stable).

## Deliverable
research/34-chief-256k.md written incrementally: per-workstream tables, every number with a log path,
crash timeline if any, final config diff, rollback commands. Self-check at the end: lock released, no
server left running, job_timeout_ms restored to 5000, no unexplained kernel lines this boot.
