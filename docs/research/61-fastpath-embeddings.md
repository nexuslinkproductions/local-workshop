# 61 - CPU fast path for simple Chief commands (embeddings + rules)

Wave 61. Goal: "yo chief, open chrome" should pop up without waiting for Ornith. Date 2026-10-13 (CEST).
Code: `chief/fastpath/` (all paths below are relative to `LOCAL-AI-LAB/` unless they start with `~`).
No GPU was touched: CPU-only llama.cpp build, `-ngl 0 --device none`, no SYCL device, `bench/.gpu.lock` only held shared during the build.
Nothing was enabled in the live chief profile. No Hermes source was edited.

## 0. Bottom line

| question | answer | evidence |
|---|---|---|
| How fast is "open chrome" end to end? | Text in to window mapped: 37 ms (foot) to 365 ms (obsidian) warm, chromium 140 ms warm. The router itself is 0.05 to 0.5 ms; `hyprctl` dispatch is 12 to 14 ms; the rest is the app starting. | `chief/fastpath/results/e2e-rules.json` |
| Do we need an embedding model for it? | No. Regex rules alone route 69/69 of my fast-path test utterances. But rules alone generalise badly: 0/34 on paraphrases written to dodge them, 4/24 on a fresh holdout. | `results/round2/eval-rules-only-devset.json`, `...-holdout.json` |
| Which CPU embedder? | `embeddinggemma-300M-Q8_0` for the second tier: 11 to 14 ms per utterance, 430 MB RSS. `Qwen3-Embedding-0.6B-Q8_0` is slightly better on the dev paraphrases but 4x slower (43 to 56 ms p50) and 810 MB. `multilingual-e5-small` is fast (2 ms) but useless for this (see 3). | `results/embed-bench.json`, `results/round2/eval-*` |
| Is the NN tier safe to execute? | Not yet. On adversarial look-alikes it still executes 1 to 2 of 26 LLM-bound utterances wrongly (3.8 to 7.7 %). Rules tier: 0 false positives on 105 LLM-bound items across three sets (51 + 28 + 26). Recommendation: rules live, NN tier shadow-only until it has run on real traffic. | section 4, `results/round2/eval-*-holdout.log` |
| Where does it plug into Hermes? | `pre_gateway_dispatch` plugin hook (can drop the event so the LLM never runs). `pre_llm_call` cannot skip the LLM. Skeleton written, not enabled. | section 6 |

## 1. Measured vs assumed (read this first)

Measured on this box, logs in `chief/fastpath/results/`:
- Load time, RSS, per-utterance latency for 3 CPU embedders, 2 thread counts, DE and EN.
- Router accuracy on 4 sets (testset 120, devset 62, holdout 50), 3 modes (rules, nn, both), 3 models.
- End to end text-to-window latency for 5 apps, live launches, hyprctl polling plus Hyprland socket cross-check.
- Handlers: dry-run for everything; live for open/close (e2e bench), `wpctl` volume set-to-current-value, unmute, MPRIS Pause on a Stopped player (all no-ops by construction).

NOT measured, assumed or unverified:
- Cold page cache load times (all load numbers are warm; files had just been written or read).
- Any comparison against the current LLM path (Ornith time to first tool call). Not run: it needs the GPU.
- Which front end Marcel's microphone actually uses for Chief (Discord voice channel, Hermes Desktop, CLI voice mode, other). The hook point in section 6 is proven for gateway voice events only. CLI voice mode has no equivalent hook (assumption from reading `cli.py`, not tested).
- TTS of the fast-path reply. The plugin sends the reply as text through the delivery adapter; whether the voice front end speaks it was not verified.
- Live behaviour of `lock_screen` (`loginctl lock-session`), `screenshot` (`grim`), `timer` (`systemd-run --user`): dry-run command construction only, never executed. Spotify launch: dry-run only (it may resume playback on start).
- Real Chief STT transcripts. My utterances are clean typed text. STT errors ("chrom", dropped words, wrong case) are only partly covered by a 0.84 fuzzy match on app names.
- The machine was busy: load average 5 to 10 during every benchmark (other agents running SYCL jobs on CCD1 plus the desktop on CCD0). All latencies are therefore pessimistic for a quiet desktop.

Authorship caveat for the test sets: I wrote the rules, the exemplars and all four utterance sets myself, in one session. `testset.jsonl` was generated first (`make_testset.py`), then rules were written; the rules tier hitting 120/120 is partly my own bias, not independent evidence. The honest generalisation numbers are the dev set (rules 0/34) and the holdout (written after round 1, never used for tuning). Thresholds were chosen on `devset.jsonl` only.

## 2. CPU embedding models

Setup: `engines/llama.cpp-cpu/build/bin/llama-server` (new CPU-only build of `engines/llama.cpp-sycl-tip`, commit 358a420ec, `-DGGML_SYCL=OFF -DGGML_NATIVE=ON`, built `-j 6` under the jobcap/flock/ionice recipe; log `logs/fastpath-cpu-build.log`; `ldd` shows no SYCL/Level Zero/Vulkan libs). Server started by `chief/fastpath/serve_embed.sh`: `--embeddings -ngl 0 --device none -c 512 -np 1`, jobcap scope with taskset `0-5,12-17` (12 logical CPUs, 6 cores), default CPU weight (not niced, so the numbers match a real always-on helper). Models in `models/embed/` (checksums `models/embed/SHA256SUMS`): Qwen/Qwen3-Embedding-0.6B-GGUF, ggml-org/embeddinggemma-300M-GGUF, keisuke-miyako/multilingual-e5-small-gguf-q8_0 (an unofficial conversion of intfloat/multilingual-e5-small; I did not verify it against the original).

Method: `bench_embed.py`. Load = process spawn to `/health` ok plus the first embedding, median of 3 (warm cache). Latency = one HTTP POST per utterance over a keep-alive connection, 5 warmups discarded, then 50 runs per language (distinct utterances from testset+devset). Prefix is what the router actually sends (Qwen3 includes a 79-character instruction, which is why it is slower than a bare embedding would be). Raw per-run values are in the JSON.

| model | file MB | dim | load ms (median of 3) | RSS after load / after runs MB | threads | DE p50 / p95 ms | EN p50 / p95 ms | 257-exemplar index build |
|---|---|---|---|---|---|---|---|---|
| multilingual-e5-small Q8_0 | 125.8 | 384 | 409 | 197 / 223 | 6 | 2.44 / 3.85 | 2.11 / 3.28 | 0.5 s |
| | | | | 199 / 224 | 12 | 2.07 / 3.73 | 2.08 / 2.59 | 0.5 s |
| embeddinggemma-300M Q8_0 | 318.1 | 768 | 475 | 387 / 430 | 6 | 11.73 / 15.50 | 11.15 / 12.95 | 2.8 s |
| | | | | 389 / 431 | 12 | 14.06 / 17.49 | 14.42 / 23.34 | 3.4 s |
| Qwen3-Embedding-0.6B Q8_0 | 609.5 | 1024 | 492 | 750 / 810 | 6 | 55.7 / 83.5 | 42.9 / 52.4 | 11.3 s |
| | | | | 750 / 810 | 12 | 44.4 / 53.8 | 40.3 / 46.8 | 10.7 s |

All from `chief/fastpath/results/embed-bench.json` (stderr summary `results/embed-bench.stderr.log`). 12 threads does not help short inputs (gemma gets slower); use 6.
Not logged: an earlier run of the same bench before the Qwen3 instruction prefix was added measured Qwen3 at about 20 to 23 ms p50 (JSON overwritten, number from my console only). The instruction prefix costs about 2x latency and buys about 15 points of top-1 accuracy (0.806 vs 0.613 raw, 0.903 vs 0.742 centred, dev set, scratch script, not archived).

What mattered more than the model: **centering** the vectors (subtract the mean exemplar vector, renormalise) and the **prefix**. Raw cosines of all three models were crushed into 0.89 to 0.96 for everything, so a threshold could not separate classes. Top-1 class accuracy on the 62 dev utterances, scratch experiment (not archived, my console): gemma 0.47 (no prefix, raw) up to 0.57 (`task: classification | query:`, centred); Qwen3 0.61 raw, 0.74 centred, 0.90 centred with instruction; e5 about 0.5 in every variant. The final per-model prefixes are in `chief/fastpath/models.py`.

## 3. The router

`chief/fastpath/router.py`: `Router.route(text) -> Route(intent, route, confidence, tier, slots, reason, lang, ms)`; `route` is `exec` (deterministic handler) or `llm` (hand to Ornith).

1. Normalise: lowercase, strip punctuation and wake/filler words ("yo chief", "hey", "bitte", "kannst du", "can you", trailing "for me", "real quick"...). Remember whether "chief" was said.
2. Tier 1, regex rules, EN + DE, anchored on both ends (any extra word means no match). Apps are resolved from the .desktop files (`apps.py`: 75 apps, 151 spoken keys, role aliases "browser/terminal/file manager", fuzzy 0.84 for STT typos). Unknown app => `llm` (never guess). "shut down" needs "chief" or a reflexive ("yourself", "dich").
3. Tier 2, embedding nearest neighbour over 257 exemplars in 21 (intent, sub) classes (incl. an explicit `llm` class of 48 hard negatives), per-class max cosine on centred vectors, app mention masked to `<app>`. Accept only if top class is not `llm`, cosine >= threshold, margin to best other class >= m, and slot validators pass (app found, duration parsed, number present). Guards added in round 2: question-form openers (how/why/what/wie/warum/was...) only allowed for time/screen intents; "time ... in/for/at" rejected; ambiguous app words ("files", "internet") ignored when pulled from free text; close/lock/shutdown need threshold + 0.05.
4. Below threshold, no app, or `llm` class => `llm`. `web_search` and `screen_question` are labelled and handed to Ornith (`screen_question` sets `attach_screenshot`).

Thresholds: `sweep.py` grid (thresh 0.40 to 0.94 step 0.02, margin 0/0.02/0.04/0.06) on `devset.jsonl` only; take the highest-accuracy cell with zero false positives and zero wrong executions, then add 0.02 headroom (the best cell sat on a cliff: Qwen3 at 0.62 already had 1 FP). Chosen: e5 0.86/0.06, gemma 0.68/0.06, Qwen3 0.66/0.0 (`results/sweep-*.json`).

Handlers (`handlers.py`, dry-run is the default in every CLI/test path):

| intent | handler | live-tested |
|---|---|---|
| open_app | `hyprctl dispatch hl.dsp.exec_cmd("<Exec>")`; if a window of that app exists, focus it instead (never a second instance by voice) | yes (5 apps, silent special workspace) |
| close_app | `hl.dsp.window.close({window="address:..."})` for every window of the app | command syntax verified by hand and by the bench cleanup; the handler path with a real window was not exercised ("not open" branch only) |
| focus_window | `hl.dsp.focus({window="address:..."})` | raw command verified on the already-active window; handler path not exercised live |
| volume | `wpctl set-volume/set-mute @DEFAULT_AUDIO_SINK@` | set to current value, unmute: yes; up/down: dry |
| media | MPRIS via `busctl --user call` (playerctl is not installed) | Pause on a Stopped player only |
| time/date | python `datetime`, EN/DE reply text | yes |
| timer | `systemd-run --user --on-active=Ns notify-send` | dry |
| screenshot, lock | `grim <file>`, `loginctl lock-session` | dry |
| chief_shutdown | returns `action="chief_shutdown"`, no command; host decides | n/a |
| web_search, screen_question | `handoff=True` | n/a |

Gotcha worth knowing: Hyprland here is 0.56.2 with a Lua config. The legacy `hyprctl dispatch exec foo` fails with exit 7 (`hl.dispatch(exec foo)` Lua syntax error); dispatchers must be `hl.dsp.*` Lua calls, and failures print a warning but still exit 0, so `handlers._run` checks that stdout starts with `ok`. Anything in the lab that still says "launched with `hyprctl dispatch exec`" is broken on this build.

## 4. Routing accuracy

Sets (all `chief/fastpath/*.jsonl`, generators `make_*.py`): **testset** 120 (80 fast-path across 11 intents, EN 74 / DE 46, 40 must go to the LLM incl. near-misses like "how do I open a port in ufw", "wie spät ist es in tokio", "open photoshop"); **devset** 62 (38 paraphrases written to dodge the rules + 24 LLM look-alikes; used to pick prefixes and thresholds); **holdout** 50 (24 fast + 26 LLM look-alikes, written after round 1, never used for tuning).
Definitions: *false positive* = an item that belongs to the LLM (40 plain LLM + 5 screen_question + 6 web_search in testset) but was executed. *wrong exec* = executed with the wrong intent or slot. *missed* = belongs to a handler but went to the LLM (slow, safe). Accuracy counts an item right only if intent and slots are right.

### Round 1 (rules v1 + NN without guards), testset, frozen thresholds
Rules v0 (as first written) scored 119/120: the one miss was "can you see my screen" (the "can you" filler strip ate the verb); fixed before the NN runs. `results/rules-v0-testset.json`.

| mode / model | accuracy | false positives (of 51 LLM-bound) | wrong exec | missed fast path (of 69) | route ms p50 / p95 | file |
|---|---|---|---|---|---|---|
| both, e5-small | 120/120 | 0 | 0 | 0 | 0.01 / 6.3 | `results/round1/eval-e5-small-q8-both-testset.json` |
| both, gemma-300M | 119/120 | **1** | 0 | 0 | 0.01 / 18.2 | `results/round1/eval-embgemma-300m-q8-both-testset.json` |
| both, Qwen3-0.6B | 117/120 | **3** | 0 | 0 | 0.01 / 60.5 | `results/round1/eval-qwen3-emb-0.6b-q8-both-testset.json` |
| nn only, e5-small | 65/120 | 0 | 3 | 47 | 3.6 / 5.2 | `results/round1/eval-e5-small-q8-nn-testset.json` |
| nn only, gemma-300M | 111/120 | 1 | 0 | 5 | 14.1 / 19.5 | `results/round1/eval-embgemma-300m-q8-nn-testset.json` |
| nn only, Qwen3-0.6B | 110/120 | 3 | 1 | 2 | 51.6 / 71.4 | `results/round1/eval-qwen3-emb-0.6b-q8-nn-testset.json` |

Round 1 false positives (the worst error): Qwen3 executed "how do I take a screenshot on windows" (took a screenshot), "delete all the files in my downloads folder" (matched "files" as the file manager and closed it) and "wie spät ist es in tokio" (said the local time); gemma executed the screenshot one. Logs: `results/round1/eval-*-both-testset.log`.

### Round 2 (guards added after seeing the round 1 failures)
The testset is now contaminated for the NN tier (the guards target its failures), so its round 2 numbers are post hoc. The holdout is the real signal.

| mode / model | set | accuracy | false positives | wrong exec | missed fast path | route ms p50 / p95 | file |
|---|---|---|---|---|---|---|---|
| rules only | testset (post hoc) | 120/120 | 0/51 | 0 | 0/69 | 0.01 / 0.05 | `results/round2/eval-rules-only-testset.json` |
| rules only | devset | 24/62 | 0/28 | 0 | 34/34 | 0.02 / 0.12 | `results/round2/eval-rules-only-devset.json` |
| rules only | holdout | 30/50 | 0/26 | 0 | 20/24 | 0.02 / 0.18 | `results/round2/eval-rules-only-holdout.json` |
| both, e5-small | holdout | 33/50 | 0/26 | 1 | 16/24 | 4.8 / 6.5 | `results/round2/eval-e5-small-q8-both-holdout.json` |
| both, gemma-300M | testset (post hoc) | 120/120 | 0/51 | 0 | 0/69 | 0.01 / 22.7 | `results/round2/eval-embgemma-300m-q8-both-testset.json` |
| both, gemma-300M | devset | 52/62 | 0/28 | 0 | 10/34 | 14.2 / 18.7 | `results/round2/eval-embgemma-300m-q8-both-devset.json` |
| both, gemma-300M | **holdout** | **46/50** | **1/26** | 0 | 3/24 | 14.3 / 21.3 | `results/round2/eval-embgemma-300m-q8-both-holdout.json` |
| both, Qwen3-0.6B | testset (post hoc) | 120/120 | 0/51 | 0 | 0/69 | 0.01 / 79.1 | `results/round2/eval-qwen3-emb-0.6b-q8-both-testset.json` |
| both, Qwen3-0.6B | devset | 54/62 | 0/28 | 0 | 8/34 | 71.6 / 99.5 | `results/round2/eval-qwen3-emb-0.6b-q8-both-devset.json` |
| both, Qwen3-0.6B | **holdout** | **44/50** | **2/26** | 0 | 4/24 | 56.7 / 134.3 | `results/round2/eval-qwen3-emb-0.6b-q8-both-holdout.json` |
| nn only, gemma-300M | holdout | 46/50 | 1/26 | 0 | 3/24 | 14.0 / 16.3 | `results/round2/eval-embgemma-300m-q8-nn-holdout.json` |
| nn only, Qwen3-0.6B | holdout | 45/50 | 2/26 | 0 | 3/24 | 51.5 / 70.6 | `results/round2/eval-qwen3-emb-0.6b-q8-nn-holdout.json` |

Holdout false positives: gemma "play some jazz for me" (executed MPRIS Play); Qwen3 the same plus "wie spät schließt der supermarkt" (answered the local time). Both are reversible and low harm, but they are exactly the class of error the NN tier will make on real speech. With n = 26 the 1 vs 2 difference between the models is noise; so is gemma 46 vs Qwen3 44 correct.
Holdout misses of the rules tier worth noting: "starte mir bitte mal den browser" and "chrome kannst du zumachen" (a filler word inside the command makes the app capture "mir bitte mal den browser", resolution fails, goes to the LLM). Safe, but the NN tier is not consulted after a rules "app not found".
Per language, gemma both holdout: EN 33/35, DE 13/15; testset rules: EN 74/74, DE 46/46 (small DE samples; only 15 DE items in the holdout).
e5-small: the NN tier adds almost nothing (holdout 33 vs 30 correct for rules alone, devset 0 recall). Drop it.

## 5. End to end latency, "yo chief open chrome" to window mapped

`bench_e2e.py`: text into `Router.route`, then `handlers.execute(dry_run=False)` with a `[workspace special:fastpath silent]` rule so nothing lands on a visible workspace, then poll `hyprctl clients -j` in a tight loop until a new mapped window of that app's class appears; the Hyprland socket2 `openwindow` event is timed in the same process as a cross-check. Windows are closed afterwards (not timed). 3 runs per app, rules tier, files `results/e2e-rules.json`. Spotify is dry-run only.

| app (utterance) | text to mapped, 3 runs, poll ms | same by socket event ms | route ms | hyprctl dispatch ms (median) | polls |
|---|---|---|---|---|---|
| chromium ("yo chief open chrome") | 169 / 141 / 139 | 163 / 140 / 137 | <= 0.48 | 12.8 | 33 to 38 |
| foot ("yo chief open the terminal") | 37 / 39 / 37 | 36 / 37 / 33 | <= 0.06 | 14.2 | 6 to 7 |
| nautilus ("yo chief open the file manager") | 322 / 92 / 101 | 321 / 91 / 99 | <= 0.07 | 11.5 | 22 to 85 |
| pavucontrol ("yo chief open pavucontrol") | 163 / 154 / 153 | 160 / 153 / 151 | <= 0.06 | 12.7 | 40 to 44 |
| obsidian ("yo chief open obsidian") | 470 / 364 / 365 | 469 / 359 / 362 | <= 0.05 | 12.6 | 98 to 130 |

The first run of each app is the coldest (nautilus 322 ms vs about 95). Poll and event agree within 1 to 5 ms, so polling resolution (one `hyprctl clients` call is about 4 ms) is not distorting the numbers. Of the total, the Chief-side cost (route + dispatch) is 13 to 15 ms; the rest is the application. A dry run of text to "launch command ready" (no launch) is 3.3 to 3.7 ms median, 4.4 to 5.0 p95 for all six apps including spotify.

Same measurement when the utterance needs the NN tier ("i want to use chromium now"; per-app phrase chosen automatically in dry-run so that the NN tier, not the rules, routes it correctly), 3 runs each, server already running:

| NN model | route ms (range over all runs) | text to mapped ms: chromium / foot / nautilus / pavucontrol / obsidian (median of 3) | file |
|---|---|---|---|
| gemma-300M | 15.1 to 22.9 | 166 / 57 / 119 / 183 / 366 | `results/e2e-nn-embgemma-300m-q8.json` |
| Qwen3-0.6B | 52.7 to 83.1 | 222 / 97 / 164 / 212 / 411 | `results/e2e-nn-qwen3-emb-0.6b-q8.json` |

So the NN tier costs about 15 to 20 ms (gemma) or 55 to 80 ms (Qwen3) on top of the same app start time. Dry-run text to dispatched via NN: gemma median 19.4 to 20.6 ms; Qwen3 59.8 to 108 ms (noisier, load average 7 to 9).

Not measured: the Ornith path for comparison. Not included: STT latency, TTS, wake-word.

## 6. Where it plugs into Hermes without source edits

Source read: `~/.hermes/hermes-agent`.

| need | finding | cite |
|---|---|---|
| A hook that can stop the LLM from running | `pre_gateway_dispatch`: once per incoming `MessageEvent`, before auth and dispatch. Return `{"action":"skip"}` to drop the event, `{"action":"rewrite","text":...}` to replace the text. Callbacks may be `async`. | `hermes_cli/plugins.py:136-139` (contract), `gateway/run_inbound.py:73-107` (implementation), `gateway/run_inbound.py:232` (call site), `hermes_cli/lifecycle.py:32-38` + `hermes_cli/plugins.py:1878` (async invoke) |
| Where a voice transcript enters | Discord-style voice channel: transcript becomes `MessageEvent(message_type=VOICE, text=transcript)` and goes through `adapter.handle_message`, so the hook sees the text. | `gateway/run_voice.py:351-355` |
| Where it does NOT see text | Audio attachments (voice notes) are transcribed after the hook, in `_enrich_inbound_voice`; at hook time `event.text` is empty. | `gateway/run_inbound.py:1731`, `:1515-1518`, `:1944` |
| Sending the reply without the LLM | `gateway._delivery_adapter_for(source)` then `await adapter.send(chat_id, text)` (same calls Hermes uses for STT echo). Text only. | `gateway/authz_mixin.py:285`, `gateway/run_inbound.py:1511` |
| `pre_llm_call` | Runs on every turn, but its return value is only *context appended to the user message*; it cannot skip the call. Useful for handing Ornith a hint (e.g. "take a screenshot") after a `screen_question` label. | `agent/turn_context.py:793-846` (`_collect_pre_llm_call_context`), `:1172` |
| `pre_transcription` | Exists, but only `prompt`, `language`, `model` are mutable; cannot short-circuit. | `tools/transcription_command.py:214-222` |
| CLI voice mode | STT output is wrapped in `_VoiceInputMessage`; I found no plugin hook between STT and the agent there. A fast path for the CLI would need a wrapper around the transcript (not built, not verified). | `cli.py:829-840` |
| How a user plugin is found and enabled | Directory plugins under `get_hermes_home()/plugins` (profile aware), opt-in through the `plugins.enabled` allow-list in the profile `config.yaml`. | `hermes_cli/plugins_discovery.py:209` and `:122-131` |
| Precedent for the exact hook | The installed `ponytail` plugin registers `pre_gateway_dispatch` and `pre_llm_call` with `ctx.register_hook`. | `~/.hermes/plugins/ponytail/__init__.py:195-203` |

Skeleton: `chief/fastpath/plugin/` (`plugin.yaml`, `__init__.py`). Modes via `CHIEF_FASTPATH`: `shadow` (default: route and log to `~/.hermes/profiles/chief/logs/fastpath-shadow.jsonl`, execute nothing, never skip), `dry`, `live`, `off`. Handles `VOICE` and `TEXT` events (typed chat gets the fast path too). Fails open on any exception. NN tier only if `FASTPATH_EMBED_TAG` names a model and a `serve_embed.sh` server is running; otherwise rules only. `selfcheck.py` exercises the rules, the handler command construction, and the plugin with a fake gateway/adapter (shadow does not skip; dry skips and replies "It's HH:MM."; an LLM question is not intercepted; off does nothing). It passed. It was not loaded by a real Hermes gateway.

To enable later (not done): symlink `chief/fastpath/plugin` to `~/.hermes/profiles/chief/plugins/chief-fastpath`, add `chief-fastpath` to `plugins.enabled` in the chief `config.yaml`, restart the gateway, run in shadow for a few days, read the JSONL.

## 7. Recommendations

1. Ship the rules tier first (live): 0 false positives on all three sets, 0.01 to 0.5 ms, no model, no RAM. Needs a real-transcript shadow run to see how STT noise hits it.
2. Run the NN tier (`embeddinggemma-300M`, 6 threads, about 430 MB RSS, started lazily: 0.48 s load) in shadow only, and compare its decisions with what the LLM ends up doing. Before letting it execute, restrict it to reversible intents (open, focus, volume, time, play/pause) and keep close_app, lock_screen and chief_shutdown rules-only (currently they just need threshold + 0.05; this restriction is not implemented).
3. Grow `exemplars.py` from real shadow logs. At n = 62 / 50 the gemma vs Qwen3 difference is within noise, and Qwen3 costs 4x the latency and 2x the RAM, so gemma is the default pick.
4. Fix the rules tier hole: when a rule matches but the app capture fails, try `find_in_text` before giving up.
5. Replace `hyprctl dispatch` for launching with a direct write to the Hyprland command socket if the 12 to 14 ms ever matters (not measured, idea only).

## 8. Files

`chief/fastpath/`: `router.py` (rules + NN + route), `handlers.py`, `apps.py`, `exemplars.py`, `models.py`, `serve_embed.sh`, `plugin/{plugin.yaml,__init__.py}`, `selfcheck.py`, benches `bench_embed.py` `bench_e2e.py` `sweep.py` `eval.py` `run_eval_all.py`, data `testset.jsonl` `devset.jsonl` `holdout.jsonl` and their `make_*.py`, `results/` (all JSON/logs cited above). Elsewhere: `engines/llama.cpp-cpu/` (105 MB build), `models/embed/` (3 GGUF, 1.1 GB), `logs/fastpath-cpu-build.log`. Index cache: `~/.cache/chief-fastpath/`.
Reproduce: `python3 chief/fastpath/bench_embed.py`, `python3 chief/fastpath/sweep.py`, `python3 chief/fastpath/run_eval_all.py results/round2`, `python3 chief/fastpath/bench_e2e.py [--nn-tag TAG]` (needs `serve_embed.sh` running for the NN tag), `python3 chief/fastpath/selfcheck.py`.
