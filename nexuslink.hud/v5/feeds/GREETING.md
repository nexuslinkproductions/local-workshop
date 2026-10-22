# GREETING — chief's startup line (HUD v5, Phase 2 item 10)

Read by chief after the boot brief card appears, and only then. Facts come from
`brief.json` (F4, `feeds/boot_brief.py`); this file only fixes the wording.

## The line

```
{fleet.finished} finished, {fleet.blocked} blocked, {needs_me} needs you.
```

Eight words, one line, no greeting filler.

## Placeholders (must match F4's `brief.json` keys)

| placeholder | `brief.json` key path | renders as |
|---|---|---|
| `{fleet.finished}` | `fleet.finished` | integer count of cards finished since last shutdown |
| `{fleet.blocked}` | `fleet.blocked` | integer count of cards blocked |
| `{needs_me}` | `needs_me` | `len(brief["needs_me"])` — cards blocked or failed, one per entry |

The build card names these shorthand as finished, blocked and needs_me; the
dotted forms above are the exact key paths in F4's JSON, so F4's phrasing rule
(every placeholder resolves to a key path in the same object) holds without a
translation table. `{needs_me}` resolves to the array itself; the count is the
array length, never a separate number.

## Variants (still one line, still under 20 words)

| when | line |
|---|---|
| default, something needs him | `{fleet.finished} finished, {fleet.blocked} blocked, {needs_me} needs you.` |
| `needs_me` is empty | `{fleet.finished} finished, {fleet.blocked} blocked. Nothing needs you.` |
| all three counts are zero | `Quiet night. Nothing finished, nothing blocked.` |

## Rules for chief

- Say the line once, right after the brief card appears. If Marcel skips the boot
  with a key, say nothing at all.
- Numbers only from `brief.json`. If a key is missing, drop that clause; never
  substitute or round a number.
- If `slack.available` is false, never mention Slack. F4 sets it false on this host.
- No filler: no "welcome back", no "master", no "sir", no time-of-day greeting.
- Keep it under six seconds spoken. If the rendered line would run longer, read
  the default variant only.

## Speech options on Linux (what each needs)

| option | what it is | needs on the HUD box (Linux) | tested from this Mac |
|---|---|---|---|
| Hermes `text_to_speech` tool | built into every Hermes session, including cron and headless runs; 11 built-in providers (`edge` default, `elevenlabs`, `openai`, `minimax`, `mistral`, `gemini`, `xai`, `deepinfra`, `neutts`, `kittentts`, `piper`) plus custom command providers | a `tts:` block in the profile `config.yaml`: `tts.provider`, then that provider's block (`tts.edge.voice`, `tts.edge.speed`, `tts.openai.model`, …). `edge` needs the `edge-tts` package and outbound wss to Microsoft's read-aloud endpoint (network); `openai` needs `VOICE_TOOLS_OPENAI_KEY`; `piper` needs the piper binary and a voice `.onnx` locally | **not tested.** No synthesis was run: no provider key and no outbound network were used. The tool hides itself from the tool list when its requirements fail, so a missing key looks like a missing tool |
| Hermes command provider (`tts.providers.<name>`, `type: command`) | wraps any local binary, e.g. espeak-ng or piper | a `command` template with placeholders for the input text path, the output path and the format (`text_path`, `output_path`, `format` in Hermes' command-provider docs), plus `output_format`, `timeout`, `max_text_length`; the binary on `PATH` | **not tested.** No local TTS binary was probed on the HUD host |
| chief voice | chief's own voice channel | **no documented command.** Only `chief-on` / `chief-off` (both accept `--dry-run`) are documented; `recon/05-local-ai.md:153-156` records that `chief-voice` is the state writer and that a Hermes voice hook never landed. One session-memory record mentions `say <text>` verbs in `chief/voice/chief-voice`, but no usage text or source is reachable on this Mac | **not tested and not documented.** Do not wire the HUD to it |
| `espeak-ng` / `espeak` | offline formant synth, renders a wav with `-w out.wav "text"` | the package only; robotic voice | **not tested.** Install state on the HUD box unknown |
| `piper` | offline neural TTS, stdin to wav | binary plus a voice `.onnx` + `.json`. Careful: on Arch, `pacman -S piper` installs a mouse-config GUI, not TTS | **not tested** |
| `pico2wave` | small offline synth, `-w out.wav "text"` | `libttspico-utils` | **not tested** |
| `festival` / `text2wave` | offline scheme TTS | festival plus a voice package; heaviest of the set | **not tested** |
| `spd-say` | speech-dispatcher client | a running `speech-dispatcher` daemon; cannot render to a file (`-w` waits, it does not write) | **not tested** |

Recommended path for the real HUD: let Hermes `text_to_speech` render the
greeting line to a file (`edge` when the box has network, the `piper` provider or
a command provider when it must stay offline), then have Quickshell play that
file with `pw-play` after `startup.wav` and the brief card are done. The spoken
text should be `brief.txt` from F4 verbatim, so speech can never disagree with
the numbers on screen.

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
