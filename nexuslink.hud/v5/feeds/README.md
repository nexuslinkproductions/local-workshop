# v5 feed bridges (F7: callcap, chief, level)

Three thin Python 3 readers behind the call-capture and local-AI widgets. They
report state and expose one action each. They do not re-implement the tools they
wrap: what they print is what the Linux box measured or left on disk.

| Script | Answers | Action |
|---|---|---|
| `callcap.py` | is a call being recorded, for how long, where, and the last three captures | `--start [LABEL]`, `--stop --confirm stop` |
| `chief.py` | which local model is loaded, VRAM, tokens/s, how old the reading is | `--on`, `--off` |
| `level.py` | two-channel peak and RMS level for the meter, 10 Hz maximum | none (read only) |

## Local models and call capture run on Linux, never on this Mac

`callcap`, `chief-on`, `chief-off`, `pactl`, `parec` and `pw-record` are Linux
binaries. None of them exists on the Mac, and no local model runs there. On the
Mac these readers are fixture-only or read the Linux box over the tunnel; there
is nothing here to start, and a Mac that appears to start a model is a Mac
printing a stub's log line.

That is why every path has a fixture: the Mac builds and tests the widget end to
end, the Linux box does the live check.

## Contract (same as every v5 reader)

- Exactly one JSON object on stdout, newline terminated, nothing else. `--json`
  makes it one compact line; without it the same object is pretty printed.
- `--fixture PATH` reads a snapshot instead of the host and runs no command.
- Exit `0` for data and for honest absence (`{"ok": false, "reason": "..."}`).
  Exit `2` for a caller error: bad arguments, a missing file the caller named, or
  an action that was refused or failed.
- Timestamps are UTC ISO 8601. `level.py --rate` adds milliseconds, because a
  10 Hz meter cannot be ordered on whole seconds.
- Missing or malformed input never raises. An empty log, a partial metrics
  object, a zero-byte WAV: all are answers, not crashes.
- No secrets, no tokens, no absolute home paths in the payload (`~` stands in).
- Reads are cached for 10 s at `~/.local/state/nexuslink/<name>.json`, written
  atomically (temp file plus `os.replace`), with `cached` and `cache_age_s` in the
  answer. `--no-cache` bypasses it; `--cache PATH` moves it.
- `--self-check` runs the whole shape, the refusals, the rate limit and the
  fixture parity, and exits non-zero on a single failure. It needs no Linux host.

### level.py is deliberately not cached

The 10 s cache rule exists so a cheap widget does not re-run an expensive probe.
A meter is the opposite: the read **is** the measurement. A cached level is a
level from ten seconds ago drawn as if it were now, which is the one lie a meter
must never tell. `level.py --rate` therefore reads continuously at the asked rate
and `--once` re-measures on every call. Every other reader in `v5/feeds/` caches.

## The exact Linux commands wrapped

`callcap.py` (from the `linux-microphone-processing` skill; the wrapper records
one WAV, channel 1 the mic, channel 2 the far end, s16le 48 kHz stereo):

    callcap start <label>    -> ~/calls/<YYYYmmdd-HHMM>-<label>/call.wav + meta.txt (pid, source, sink)
    callcap stop             -> closes the file, prints duration and size
    callcap status           -> REC or idle per directory
    pgrep -af "ffmpeg .*calls/"     (the skill's own truth check for a live recorder)

Status is assembled from what the tool leaves behind, cheapest and most reliable
first: the `pid` in `meta.txt` (alive via `os.kill(pid, 0)`), then the ffmpeg
process above, then `callcap status`. Elapsed time for a live capture is the WAV
size divided by 192000 bytes/s, so it needs no timestamp and survives a clock
step; `elapsed_source` says which route was used.

`chief.py` (from `recon/05-local-ai.md`, `LOCAL-AI-LAB/chief`):

    /run/user/1000/chief/metrics.json        written by chief-state-watch at <=1 Hz, atomic
    chief/bin/chief-on                       loads the profile's model on :18080
    chief/bin/chief-off                      unloads it, polls for llama-server to exit
    chief/bin/selftest.sh                    the tool's own check

`model`, `tokens_per_s`, `queue`, `vram_used_mib` and `vram_total_mib` are read
straight out of that file. VRAM is the per-pid `fdinfo` sum the poller already
computed; the B580 has no sysfs VRAM entry, so nothing here tries to invent one.
`metrics_age_s` is the file's mtime age; over 5 s (five missed 1 Hz ticks) the
payload says `"stale": true` and the dock should dim rather than show a dead
number as live.

`level.py` (PipeWire):

    pactl get-default-sink                        -> <sink>, monitor node is <sink>.monitor
    parec --device <sink>.monitor --format=s16le --rate=48000 --channels=2 --raw --latency-msec=50
    pw-record --target <sink>.monitor --rate 48000 --channels 2 --format s16 --latency 50ms -

`parec` is preferred; `pw-record` is the fallback. One block per sample
(`48000 / rate` frames), peak and RMS computed here in `array` arithmetic, no
`audioop` (removed in Python 3.13) and no numpy.

## Reading it from the deck

    callcap.py --status --json                   poll on demand; the cache caps it at 10 s
    callcap.py --start standup                   one tap; refuses if a capture is live
    callcap.py --stop --confirm stop             destructive: ends a live call capture
    chief.py --status --json                     same
    chief.py --on / chief.py --off               one tap each
    level.py --rate 10                           stream; one line per 100 ms

`--dry-run` prints the exact argv and runs nothing: the safe way to show an
action in a test or a UI preview.

Stopping a live call recording is the destructive case in this set, so it needs
the literal token: `--stop --confirm stop`. Without it the reader refuses, exits
2, and does not touch the binary. Starting a second capture while one is running
is refused the same way, because the second recorder would fight the first for
the source.

## Fixtures

| File | Shape | Where it comes from |
|---|---|---|
| `../fixtures/callcap.json` | the mapped payload of a live capture plus three finished ones | the wrapper's documented layout; callcap prints text, so there is no JSON to copy |
| `../fixtures/chief.json` | `/run/user/1000/chief/metrics.json` | `recon/05-local-ai.md` keys; the numbers are placeholders, labelled as such in the file |
| `../fixtures/level.json` | 130 samples at 10 Hz: speech, silence, a clipped burst, speech, silence | synthetic and deterministic, regenerated by `level.py --make-fixture PATH`; a real monitor capture from the Linux box replaces it unchanged in shape |

A copied snapshot is stale by construction (`metrics_age_s` grows, `stale` is
true). That is the honest reading: the fixture proves the shape, the Linux
capture proves the contents.

## Self-checks

    python3 nexuslink.hud/v5/feeds/callcap.py --self-check
    python3 nexuslink.hud/v5/feeds/chief.py --self-check
    python3 nexuslink.hud/v5/feeds/level.py --self-check

Each prints one `FAIL`/`ok` line per check on stderr and one JSON object on
stdout, and exits non-zero if anything failed. They create their own fixture
trees under `$TMPDIR`, use stub binaries to prove the action paths without a real
tool, and never touch `~/calls`, `/run/user/1000/chief/` or a real recording.

## Shared plumbing

The generic half of each file (envelope, UTC stamps, atomic write, cache,
exit-code runner) is duplicated on purpose: this branch is based on
`v5/main-deck` before `v5/w8-feeds` lands, and a reader that imports a module
that is not in the tree does not run. When `feeds/_common.py` is merged, the
three copies fold into it mechanically; nothing in the payload changes.
