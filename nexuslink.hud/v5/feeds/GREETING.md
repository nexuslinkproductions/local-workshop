# GREETING: chief's startup line (HUD v5, Phase 2 item 10)

Read by chief after the boot brief card appears, and only then. Facts come from
`brief.json` (F4, `feeds/boot_brief.py`); this file only fixes the wording.

## The line

```
{fleet.finished} finished, {fleet.blocked} blocked, {needs_me.#} waiting on you.
```

Eight words when rendered with the fixture counts, one line, no greeting filler.
The budget rule under "Rules for chief" can shorten it.

## Placeholders (resolve with F4's own resolver)

F4 resolves placeholders with `lookup()` in `feeds/boot_brief.py`: dotted paths
into `brief.json`, `[n]` for list indices, and a `#` segment for a list's length.
Every placeholder below resolves through that function unchanged. No line numbers
here on purpose, because F4 is still moving: checked against F4 head `86160a9` on
`v5/f4-bootbrief` (PR #26), where `lookup()` and `placeholders()` sit next to each
other in that file, and against that head's own payload,
`feeds/golden/boot-brief.json`. All three placeholders in the table below resolve
with nothing left unresolved there, and so do the four spoken lines built from
them; the counts are `fleet.finished` 3, `fleet.blocked` 2 and `needs_me.#` 3.

| placeholder | `brief.json` key path | renders as |
|---|---|---|
| `{fleet.finished}` | `fleet.finished` | integer count of cards finished since last shutdown |
| `{fleet.blocked}` | `fleet.blocked` | integer count of cards blocked |
| `{needs_me.#}` | `needs_me.#` | length of the `needs_me` array: blocked board cards plus blocked digest items; failed cards are not counted |

Note the `.#` on the last one: `needs_me` is an array, so naming it without the
length operator would render the whole list, not a count. `{needs_me.#}` is F4's
own length operator and is the form that must be used. The build card names these
shorthand as finished, blocked and needs_me; the dotted and `#` forms are the
paths that actually resolve.

## Variants (one line each; the budget rule below decides which is spoken and shortens it when none fits)

| when | line |
|---|---|
| default, something needs him | `{fleet.finished} finished, {fleet.blocked} blocked, {needs_me.#} waiting on you.` |
| `needs_me.#` is 0 | `{fleet.finished} finished, {fleet.blocked} blocked. Nothing needs you.` |
| all three counts are zero | `Quiet night. Nothing finished, nothing blocked.` |

## Rules for chief

- Say the line once, right after the brief card appears. If Marcel skips the boot
  with a key, say nothing at all.
- Numbers only from `brief.json`. If a key is missing, drop that clause; never
  substitute or round a number.
- If `slack.available` is false, never mention Slack. F4 sets it false on this host.
- No filler: no "welcome back", no "master", no "sir", no time-of-day greeting.
- Budget: MAIN-SCREEN-BUILD.md Phase 2 item 10 caps the startup sequence at
  5 s, greeting included, and the startup card reads it the same way. The ruling
  at the end of these rules narrows that cap to the visual wake; the spoken line
  is measured against the window the wake leaves.
- Window: the cap minus chief's cue time in the startup card, so 5.00 s minus
  that cue. Current value, read off
  `hud-candidates/comp-r1/s4/startup-sequence/README.md` (timing table row F8 and
  its "Why the speech window is 1.72 s" paragraph, D2 repair of 2026-10-23): the
  cue is at 3.280 s, so the window is 5.00 - 3.280 = 1.72 s. That README is the
  source of the number, not the ruling below, which still quotes an older 4.30 s
  cue. Re-read the README whenever the startup card re-times; never round the
  number and never carry an old one over.
- What fits: at 150 words per minute the 8-word default line is about 3.2 s and
  the 4-word shortened line about 1.6 s, so the default does not fit the current
  window and is not spoken as written. A line longer than the window is not
  spoken inside the wake: measure the rendered file (`ffprobe
  -show_entries format=duration`) and shorten until it fits, dropping the
  finished clause first and the blocked clause second. The needs-me count goes
  last because it is the only clause Marcel has to act on. Never raise the
  speaking rate to make a longer line fit.
- Shortened all the way the line is `{needs_me.#} waiting on you.`: 4 words,
  about 1.6 s at that rate, which fits the current 1.72 s window with 0.12 s to
  spare. This is the line spoken on a normal boot. If the voice cannot render it
  inside the window, the ruling below decides the overrun; if it cannot render at
  all, skip speech for that boot. The brief is on screen either way.
- Ruling on the open decision (Mac head executive, 2026-10-23). It overrides
  item 10's plain scope instead of reading it: the 5.00 s cap bounds the visual
  wake, not the voice, so the spoken line may run past 5.00 s, with the ruling's
  own ceiling at about 6 s. At the current cue that is 6.00 - 3.280 = 2.72 s of
  speech, 1.00 s more than the window. The headroom does not rescue the 8-word
  default, which would run to 3.280 + 3.20 = 6.48 s, 0.48 s past that ceiling. It
  is headroom for a slow render of the shortened line and never a reason to put a
  cut clause back. The wake itself still ends at 5.00 s: the audio never extends
  the picture and never holds the screen, and any key stops the voice at any
  point, including mid-sentence.
- Open cross-artifact note, out of this file's scope: item 10 and the startup
  card both still say the whole sequence stops at 5.00 s
  (`startup-sequence/README.md`: "The sequence never runs past 5.00 s"). Under
  the ruling that sentence describes the visuals only, so the startup card needs
  to say so on its next re-time.

## Speech options on Linux (what each needs)

| option | what it is | needs on the HUD box (Linux) | tested from this Mac |
|---|---|---|---|
| Hermes `text_to_speech` tool | built into every Hermes session, including cron and headless runs; 11 built-in providers (`edge` default, `elevenlabs`, `openai`, `minimax`, `mistral`, `gemini`, `xai`, `deepinfra`, `neutts`, `kittentts`, `piper`) plus custom command providers | a `tts:` block in the profile `config.yaml`: `tts.provider`, then that provider's block (`tts.edge.voice`, `tts.edge.speed`, `tts.openai.model`, …). `edge` needs the `edge-tts` package and outbound wss to Microsoft's read-aloud endpoint (network). `openai` takes `tts.openai.api_key`, else `VOICE_TOOLS_OPENAI_KEY` or `OPENAI_API_KEY` (`tools/tts_tool_openai.py:56-62`). The built-in `piper` provider is the Python package `piper-tts`, which supplies `PiperVoice` (`tools/tts_tool.py:81,191-193`); it is not a binary. On first use it downloads its voice with `python -m piper.download_voices` into `<HERMES_HOME>/cache/piper-voices`, or into `tts.piper.voices_dir` when that is set (`tools/tts_tool_local.py:80,101,122`), so the first run needs network unless the voice is already cached or `tts.piper.voice` points at an existing `.onnx` (`tools/tts_tool_local.py:92-97`). The standalone `piper` binary is the separate row further down | **not tested.** No synthesis was run: no provider key and no outbound network were used. The tool hides itself from the tool list when its requirements fail, so a missing key looks like a missing tool |
| Hermes command provider (`tts.providers.<name>`, `type: command`) | wraps any local binary, e.g. espeak-ng or piper | a `command` template with placeholders for the input text path, the output path and the format (`text_path`, `output_path`, `format` in Hermes' command-provider docs), plus `output_format`, `timeout`, `max_text_length`; the binary on `PATH` | **not tested.** No local TTS binary was probed on the HUD host |
| chief voice | chief's own voice channel | **no documented command.** Only `chief-on` / `chief-off` (both accept `--dry-run`) are documented; `recon/05-local-ai.md:153-156` records that `chief-voice` is the state writer and that a Hermes voice hook never landed. One session-memory record mentions `say <text>` verbs in `chief/voice/chief-voice`, but no usage text or source is reachable on this Mac | **not tested and not documented.** Do not wire the HUD to it |
| `espeak-ng` / `espeak` | offline formant synth, renders a wav with `-w out.wav "text"` | the package only; robotic voice | **not tested.** Install state on the HUD box unknown |
| `piper` | offline neural TTS, stdin to wav | binary plus a voice `.onnx` + `.json`. Careful: on Arch, `pacman -S piper` installs a mouse-config GUI, not TTS | **not tested** |
| `pico2wave` | small offline synth, `-w out.wav "text"` | `libttspico-utils` | **not tested** |
| `festival` / `text2wave` | offline scheme TTS | festival plus a voice package; heaviest of the set | **not tested** |
| `spd-say` | speech-dispatcher client | a running `speech-dispatcher` daemon; cannot render to a file (`-w` waits, it does not write) | **not tested** |

Recommended path for the real HUD: let Hermes `text_to_speech` render the
greeting line to a file (`edge` when the box has network; the `piper` provider
once its voice is cached, or a command provider with a local binary, when it
must stay offline), then have Quickshell play that file with `pw-play` after
`startup.wav` and the brief card are done. Chief speaks the one-line greeting
above and nothing else. `brief.txt` from F4 is five lines, so it goes on screen
next to the card, never into the speaker: Phase 2 item 10 asks for a short
spoken line plus a shown brief, and speaking the file would break the one-line
rule.

### What could not be tested from this Mac

- Any actual speech synthesis: no provider key, no network call, no local TTS
  binary was run.
- Whether `edge`, `piper`, `espeak-ng`, `pico2wave` or `festival` exist on
  Marcel's Linux box: that host is not reachable from this Mac.
- Even the stand-in VPS probe failed at the network layer
  (`ssh -o BatchMode=yes arct-vps` exited 255 after a connect timeout; `nc` to
  ports 22 and 443 also timed out), so no Linux `command -v` evidence exists.
- The undocumented `say` verb in `chief/voice/chief-voice`.

## Startup cue (this card's artifact)

`startup.wav`, generated by `sfx.py` (numpy, no samples, no network):

| property | value |
|---|---|
| duration | 1.750000 s (84000 frames) |
| format | 48 kHz, mono, 16-bit PCM |
| loudness | -16.000 LUFS integrated (BS.1770 K-weighting + gating, measured in `sfx.py`) |
| true-peak ceiling | -1.5 dBTP stated, measured -4.536 dBTP (4x oversampled) |
| sample peak / RMS | -4.536 dBFS / -16.110 dBFS |
| size | 168044 bytes |
| regeneration | `python3 sfx.py --regenerate` (seeded, byte-identical) |
| assertions | `python3 sfx.py --self-check` |
