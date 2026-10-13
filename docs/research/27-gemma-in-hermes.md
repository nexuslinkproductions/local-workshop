# 27 — Gemma 4 12B wired into Hermes as `chief` (2026-10-13)

Status: DONE, smoke-tested live at ctx 65536. llama-swap stopped, GPU lock released, no reset this boot.

## What changed (keys old -> new)

| File | Change |
|---|---|
| `LOCAL-AI-LAB/serve/config.yaml` | `gemma4-12b` capabilities `context: 16384 -> 65536`. `llama-swap -validate`: valid, 5 models. |
| `~/.hermes/config.yaml` (default profile) | added `providers.local-ai.context_length: 65536` (via `hermes config set`). Main model unchanged: `model.default=claude-opus-5-5`, `model.provider=anthropic`. Backup: `~/.hermes/config.yaml.bak-local-ai-20261013-110338`. |
| Profile `jarvis` -> `chief` | `hermes profile rename jarvis chief`. Dir `~/.hermes/profiles/chief`, alias `~/.local/bin/chief` (old `jarvis` alias removed). `profile.yaml` keeps `previous_names: [jarvis]`. |
| `profiles/chief/config.yaml` | `terminal.cwd` `.../profiles/jarvis/workspace -> .../profiles/chief/workspace`. Backup: `config.yaml.bak-chief-20261013-110338` (pre-fix). |
| `profiles/chief/SOUL.md` | "You are Jarvis" -> "You are Chief". |
| `profiles/chief/workspace/AGENTS.md` | heading and cwd line -> Chief. |
| `LOCAL-AI-LAB/bench/ramp-gemma-64k.py` | new: one prefill step of the ramp, VRAM sampling, journal reset check. |

Unchanged on purpose: `serve/gemma4-12b-launch.sh` (already `-c 65536`), `serve/gate-run.sh`, `serve/screen_locate.py`, delegation and auxiliary settings, `local-ai.service` (still OFF).

Chief profile model: `provider: local-ai`, `default: gemma4-12b`, `context_length: 65536`. Thinking is per model id via llama-swap `setParamsByID`.

## Commands

- Start the server (loads on first request, unloads after 600 s idle):
  `cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB && llama-swap -config serve/config.yaml -listen 127.0.0.1:18080`
- Talk to Chief: `chief` (alias), or `hermes -p chief chat -Q --provider local-ai -m gemma4-12b -q "..."`
- Thinking on: use model id `gemma4-12b-think` (same weights, no reload). Thinking off: `gemma4-12b`.
- Stop: `pkill -TERM -f '^llama-swap -config serve/config.yaml'`
- VRAM: `python3 bench/arc-vram.py`
- Screen locate (never clicks): `python3 serve/screen_locate.py "<target>" --monitor DP-1`
- Not enabled: `serve/local-ai.service`. Marcel decides.

## Smoke results (live, GPU lock held by this run)

| # | Test | Result |
|---|---|---|
| a | `hermes -p chief chat ... -m gemma4-12b`, "capital of Austria" | PASS. "The capital of Austria is Vienna." 34 s incl. cold load. Session `20261013_110420_f1ee78`. |
| b | Tool turn: read first 3 lines of RESUME-after-reboot-2.md | PASS. Returned the exact first line. 9 s. Session `20261013_110714_571913`. |
| c | Thinking off `gemma4-12b`, train question (correct: 17:07) | Answer "17:03" (WRONG). 1.2 s, 6 completion tokens, 0 reasoning chars. |
| c | Thinking on `gemma4-12b-think`, same question, max_tokens 4000 | Answer "17:07" (correct). 19.1 s, 583 completion tokens, 1195 reasoning chars. |
| c | Thinking on, max_tokens 1500 (first try) | FAIL by budget: finish=length, empty answer, 52 s. Thinking eats the budget. |
| d | `screen_locate` "the clock in the top bar" on DP-1 | PASS. (1311, 13), 6.4 s. Vision check: clock text "Tuesday 11:08" spans x≈1233–1326 at y≈12. |
| d | `screen_locate` 'the window title "Hermes"' on DP-1 | PASS, borderline. (1112, 15), 6.6 s. Vision check: label spans x≈1113–1158 (centre ≈1136). Point is at the left edge, ~24 px off centre. |
| e | Idle unload | PASS. Last request ~11:09, `unloaded` at 11:20:39. VRAM used 10309 MiB under load -> 1823 MiB after. |

Prompt-size ramp at ctx 65536 (one step each, VRAM sampled 1 s during request, journal checked before/after):

| Prompt tokens | Prefill t/s | Secs | VRAM free min (MiB) | Journal resets |
|---|---|---|---|---|
| 3,181 | 606 | 5.2 | 1395 | 0 |
| 4,127 | 2853* | 1.4 | 1390 | 0 |
| 8,223 | 686 | 12.0 | 1334 | 0 |
| 16,416 | 707 | 23.2 | 1293 | 0 |
| 32,799 | 702 | 46.7 | 1368 | 0 |

*4,127 reused a cached prefix from the 3,181 run (same seed), so its speed is not a prefill number.
Ladder ends at 32K per RESUME. A full 64K prefill is NOT tested. Stop rule (reset, wedge, VRAM free < 1.0 GiB) was never hit.

Kernel: 0 `GT0: reset` / `DEVICE_LOST` / `Timedout` / `devcoredump` / `Fault response` lines this boot. `gpu_reset_unacked` rc=1 throughout. `bench/.gpu-reset-ack` never created.

Chief token budget (from RESUME, earlier measurement, not re-measured): system 2,950 + tools 3,547 = 6,497 tokens.

## Known gaps

- Thinking-off arithmetic was wrong on the one test. Use `gemma4-12b-think` for maths.
- Thinking-on needs a generous max_tokens (4000 worked; 1500 did not).
- Screen-locate confidence is structural, not measured accuracy. One clock hit and one title hit at the edge.
- 64K full prefill and any decode at >32K context: untested. Needs a Marcel-approved step.

## Rollback

- Stop server: `pkill -TERM -f '^llama-swap -config serve/config.yaml'`
- Remove Hermes provider key: `cp ~/.hermes/config.yaml.bak-local-ai-20261013-110338 ~/.hermes/config.yaml`
- Revert profile name: `hermes profile rename chief jarvis`, then restore `profiles/jarvis/config.yaml` path and `SOUL.md` wording by hand.
- Revert context metadata: in `serve/config.yaml`, `gemma4-12b` capabilities `context: 65536 -> 16384` (metadata only; the launch flag `-c` is unchanged).
