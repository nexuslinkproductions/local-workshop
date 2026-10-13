# Brief: wire Gemma 4 12B into Hermes as Marcel's local assistant brain (2026-10-13)

Read first: research/22-jarvis-assistant.md, research/20-serving-layer.md, research/10-test-matrix.md
(Gemma 4 sections), serve/config.yaml, serve/hermes-provider.yaml, serve/gate-run.sh,
bench/configs/matrix-gemma4-12b-qat-sycl-nothink.env (the measured winning flags),
bench/grounding-test.sh + bench/grounding-score.py (the 2-stage crop logic that scored 16/16).

## Measured facts (do not re-derive)
Gemma 4 12B QAT Q4_0 + mmproj on llama.cpp SYCL (engines/llama.cpp-sycl-tip), -ngl 99, ctx 16384,
q8_0 KV, -fa on, -b/-ub 1024, -lm dio, thinking OFF: load 2 s, 9.27 GiB VRAM, prompt 791 t/s,
decode 27 t/s, TTFT 80 ms / first sentence 478 ms with cached system prefix, tool calls pass,
PSI ~0. Thinking is Gemma's default and eats the whole token budget unless turned off.
Grounding: full screen 8/16 (fails small icons/links), 2-stage quadrant crop-and-zoom 16/16.

## Build (user space only, no sudo)
1. serve/config.yaml (llama-swap): make `gemma4-12b` the primary model with the measured flags,
   launched through serve/gate-run.sh + bench/watchdog.sh + jobcap quiet mode
   (CPUS=6-11,18-23 CPUW=20) + ionice -c 3, ttl 600. Thinking: do NOT pass a global
   `--reasoning off`; instead make thinking switchable per request. Verify what this llama.cpp build
   honours per request (`chat_template_kwargs: {"enable_thinking": bool}`, `reasoning_effort`);
   if per-request control does not work, expose two llama-swap model ids on the SAME weights
   (`gemma4-12b` thinking off, `gemma4-12b-think` thinking on). Keep qwen3.6 as an on-demand entry.
   Validate with `llama-swap -config serve/config.yaml -validate` style check if available.
2. Hermes provider: back up ~/.hermes/config.yaml to config.yaml.bak-local-ai-<timestamp>, then add
   a `local-ai` provider (base_url http://127.0.0.1:18080/v1, models gemma4-12b and
   gemma4-12b-think if used) using `hermes config set` only (config.yaml is guarded for file tools;
   never sed). Do NOT change the main model, delegation lane, or auxiliary settings.
3. Screen tool: write LOCAL-AI-LAB/serve/screen_locate.py: `screen_locate.py "<target description>"
   [--monitor DP-1]` takes a grim screenshot of that monitor, runs the 2-stage crop-and-zoom against
   the local endpoint (stage 1 picks the quadrant, stage 2 locates inside it), maps back to absolute
   screen coordinates and prints JSON {x, y, monitor, confidence, ms}. Reuse grounding-score.py's
   mapping code instead of rewriting it. It never clicks; clicking stays a separate approved action.
4. Smoke test end to end (take `flock -x bench/.gpu.lock` for the duration, release after; other
   agents queue on it): start llama-swap on 127.0.0.1:18080, then
   a) `hermes chat -Q --provider local-ai -m gemma4-12b -q "<short English question>"` returns an answer;
   b) a tool-using turn works through Hermes (e.g. ask it to read a file in LOCAL-AI-LAB);
   c) thinking on vs off on the same question: report reasoning tokens and time for each;
   d) screen_locate.py finds the top-bar clock on DP-1 (check the result against a vision check of
      the same screenshot) and one window title from `hyprctl clients -j`;
   e) idle unload: after ttl the model unloads and VRAM returns;
   then stop llama-swap. Do NOT enable or start the systemd unit; Marcel decides that.
Rules: watchdog + jobcap on every model run; bench/gate.sh refuses while ARC Raiders runs (never
--force); after each GPU run grep `journalctl -k --since <start>` for 'GT0: reset'/'DEVICE_LOST'.

## Output
research/27-gemma-in-hermes.md written incrementally: what changed (file paths, config keys old ->
new), the exact commands Marcel uses (start/stop, how to talk to it, how to toggle thinking), smoke
test results with numbers, rollback commands.

Self-check (mandatory): config backup exists; `hermes config get` shows main model unchanged;
every smoke test PASS/FAIL with evidence; no llama-swap/llama-server left running; lock released.
