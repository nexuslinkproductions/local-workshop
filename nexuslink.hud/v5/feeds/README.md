# v5 feeds

Four Python 3 readers that turn the real sources into the one JSON object each
HUD widget needs. Stdlib only, no third-party imports, no daemon, no cache
directory of their own.

| Reader | Live source | Fixture |
|---|---|---|
| `sessions.py` | `~/.hermes/state.db`, opened read-only | `v5/fixtures/sessions.json` |
| `link.py` | tailscale (`status --json`, `ping`), the tunnel unit, one ssh for battery and load | `v5/fixtures/link.json` |
| `apps.py` | `~/.local/state/nexuslink/apps.json` | `v5/fixtures/apps-list.json` |
| `metrics.py` | `~/.local/state/nexuslink/metrics.json` | `v5/fixtures/metrics.json` |

`_common.py` is the shared plumbing (envelope, UTC stamps, JSON io, exit-code
contract). A later reader in the same folder can `import _common` and inherit
the shape without copying it.

## The contract

Every reader, in both modes:

* prints **exactly one JSON object** on stdout and nothing else;
* `--json` = one compact line (what a `Process` consumer parses), default = the
  same object pretty printed (what a human reads);
* every time value is UTC ISO-8601 with a trailing `Z`, plus the raw epoch where
  the source has one;
* **missing or malformed data is an answer**: `{"ok": false, "reason": "...",
  "kind": "missing" | "malformed"}` and **exit 0**, so a HUD tick never sees a
  broken process. Absence of rows (no open sessions, no windows) is `ok: true`
  with a zero count, not an error;
* **exit 2 only for a bug or a bad invocation** (unexpected exception, bad CLI
  argument). A data problem never reaches it;
* no secrets, and no absolute home paths — `~` stands in for the home prefix.
  Where a path *is* the content (a session title, a window id) it stays as it is;
* `--fixture PATH` never touches the live source, the network or a process. The
  only write any of these readers performs is `link.py`'s RTT ring buffer.

Nothing in this folder is imported by the kit. The integrator (`DeckMain.qml`)
runs a reader with `Process` (or reads the same JSON from a file with
`FileView`) and hands the values to the components as properties.

## Running one

From the repo root, in the worktree:

    python3 nexuslink.hud/v5/feeds/metrics.py --fixture nexuslink.hud/v5/fixtures/metrics.json --json
    python3 nexuslink.hud/v5/feeds/sessions.py --json          # live, read-only
    python3 nexuslink.hud/v5/feeds/link.py --json              # live probes
    python3 nexuslink.hud/v5/feeds/apps.py --json              # live state file

Per-reader flags worth knowing:

| Flag | Reader | Meaning |
|---|---|---|
| `--db PATH` | sessions | state database (default `~/.hermes/state.db`); exists so a test can point at a generated database |
| `--since-min 30` | sessions | only sessions touched inside this window |
| `--limit 8` | sessions | how many sessions to emit |
| `--state PATH` | link | RTT ring buffer (default `~/.local/state/nexuslink/rtt.json`) |
| `--peer NAME` | link | tailscale peer; default is the first online non-exit peer |
| `--ssh-host HOST` | link | ssh target for battery/load (default `mac`, or `$NEXUS_HUD_SSH_HOST`) |
| `--ring-cap 240` | link | ring buffer length |
| `--samples 24` | link | RTT samples published |
| `--apps PATH` | apps | live launcher state file |
| `--metrics PATH` | metrics | live metrics state file |

## Self-checks

    sh nexuslink.hud/v5/feeds/run-self-checks.sh

or one at a time:

    python3 nexuslink.hud/v5/feeds/sessions.py --self-check
    python3 nexuslink.hud/v5/feeds/link.py --self-check
    python3 nexuslink.hud/v5/feeds/apps.py --self-check
    python3 nexuslink.hud/v5/feeds/metrics.py --self-check

Each self-check builds its own fixture tree under `$TMPDIR`, runs the reader as
a **subprocess** (so it tests the real CLI contract, not an internal function),
and asserts shape, values, absent/malformed handling and — for `sessions.py` —
that the database is untouched: sha256, size, `mtime_ns` and the absence of
`-wal`/`-shm`/`-journal` sidecars before and after, plus a write attempt through
the same connection that must be refused. It exits non-zero if any assertion
fails, including a malformed-input case that the reader failed to answer with
`ok: false` / exit 0. None of them points at a live path.

`link.py` additionally proves the shell-out budget: its ssh collector is called
through an injected runner that counts calls, and the check fails unless there
was exactly **one** ssh call for battery and load.

## What each payload looks like

Top level of every reader:

    {"ok": true, "source": "<name>", "mode": "live" | "fixture",
     "generated_at": "2026-10-22T23:06:49Z", ... , "<payload key>": ...}

`source_file` (apps, metrics) names the file read, home-shortened.
`warnings` appears only when something was tolerated (a dropped entry, a column
missing upstream). `degraded` (link only) lists probes that failed while the rest
of the payload still answered.

### sessions

`sessions[]`, newest activity first, shaped for `CrewOrb`:

| key | meaning |
|---|---|
| `id` | six-character id (the unique tail of the session id) |
| `full` | full session id, the join key for anything else that speaks Hermes |
| `parent` | parent session id tail, or null — this is what makes sub-swarms possible |
| `model` | short form (`claude-` stripped, `deepseek-` → `ds-`), same spelling as the fixtures |
| `agent` | `profile_name`, else `source` |
| `source` | `local`, `kanban`, `oneshot`, ... |
| `state` | `active` (idle ≤ 90 s), `idle` (≤ 600 s), `stale`, `unknown` |
| `tools` | tool calls in the session |
| `tokens` | input + output tokens |
| `started_at` / `started_iso` | when it began |
| `last_activity_at` / `last_activity_iso` | last sign of life |
| `idle_s`, `age_s` | seconds since last activity / since start |
| `title` | session title, truncated to 200 characters |
| `activity` | `last_activity_description`, e.g. `receiving stream response` |

The live query is one SELECT: `ended_at IS NULL`, not archived, not hidden,
`started_at` or `last_activity_at` inside `--since-min`. It selects only the
columns that exist (`PRAGMA table_info`), so a schema change upstream degrades to
a warning instead of an exception.

### link

`link{}`, the same object `v5/fixtures/link.json` carries:

| key | meaning |
|---|---|
| `route` | `direct` when the ping went via a LAN address, `relay` when it went via DERP |
| `tunnel` | `systemctl --user is-active hermes-peer-mac-tunnel.service`, or the tailscale backend state when systemd is absent |
| `rtt_ms` | `{median, last, min, max, count, samples[]}` — rolling window from the ring buffer |
| `pulse_period_s` | `clamp(22 / median_ms, 0.9, 6.0)`: the breath `PulseRing` runs at |
| `mac` | `{load[3], load1_frac, cores, batt, state, rem, up_min}` from the one ssh |
| `peers` | `[{name, on}]` for the tailnet |

`mac.load` is all or nothing: one non-finite value in the triple (`NaN`,
`Infinity`, a string that is not a number) makes `load` and `load1_frac` null,
because the slot is the meaning — dropping the bad element would slide the 5 or
15 minute value into the 1 minute slot. This is the same rule the live ssh path
keeps: an unreadable load line drops the whole triple. `state` and `rem` are
text or null; a non-string never becomes `"nan"`/`"inf"`.

The ring buffer is the only file any reader writes:
`~/.local/state/nexuslink/rtt.json`, `{"version": 1, "samples": [{"ts", "epoch",
"ms", "route"}]}`, newest last, trimmed to `--ring-cap`, written atomically via a
temp file and `os.replace`. A corrupt ring is reset with a warning, never an
exception. `--fixture` does not touch it. Live mode always derives
`pulse_period_s`; a fixture that states its own value keeps it, so the snapshot
stays exactly as recorded.

Why a ring at all: no single cheap combined call exists for the link (recon:
6.8 + 14.3 + 3.9 + 46 ms as four probes), and nothing on the box kept a history
of link quality, so a sparkline had nothing to draw.

### apps

`apps[]` is the ranked list; unranked tiles (feature slot, denylisted apps) come
after it. `arc[]` is the tile order for the launcher arc. Every tile carries
`arc_index` (0..n-1) whatever its rank.

Ranking: `launches + 3.0 while running + recency bonus` (2.0 under 6 h, 1.5
under 24 h, 1.0 under 72 h, 0.5 under 7 d), ties broken by `slot` then `id`, so
two runs on the same file produce the same order. `size: "feature"` tiles are
never ranked — Arc Raiders has a fixed slot at the end of the arc.

**Chromium is denylisted.** Its launch counter on this box is dominated by
headless agent runs (recon/03-feeds.md: about 6.7k `app-*.scope` instances,
mostly automation), so the count says nothing about what the operator uses. A
denylisted app keeps its arc slot and its tile, gets `rank: null` and an
`excluded` reason, and rejoins the ranking only when the payload marks the count
user-driven (`"user_driven": true`). The rule and the reason are also emitted in
`ranking.denylist`, so the UI never has to hard-code it.

### metrics

`metrics{}` mirrors `v5/fixtures/metrics.json` block for block, with `null` for
a block that is absent or the wrong type and the block's name listed in
`missing`. Partial blocks survive: a `host` with only `loadavg` and `cores`
still yields `load1_frac` (`loadavg[0] / cores`). Derived values added here:
`tokens_today.total` and `.top`, `screens_count`, `windows_count`,
`kanban.total`, `snapshot_age_s`.

Junk inside a block (a screen without an id, a non-string window, a token count
that is not a number) is dropped with a `warnings` entry rather than failing the
whole payload: the HUD dims one gauge, not the deck. `loadavg` is the exception:
one non-finite element nulls the whole triple (and `load1_frac` with it), so a
5 or 15 minute value can never be reported as the 1 minute ratio. A finite
partial list still works.

## What is not here

`fleet.py`, `chief.py`, `gamemode.py` and `yuri.py` belong to other cards; the
Linux-only state files `/run/user/1000/chief/metrics.json` and
`~/.cache/ptt-toggle.state` are theirs to read. This folder does not stub them
and does not fake their values. `v5/fixtures/apps.json` is the launcher card's
state matrix (`default`, `all`, `arcRaiders`) that DeckMain's FileView reads.
`apps.py` takes an array of app entries, so it answers that matrix with
`ok: false, kind: malformed`; its own fixture is `v5/fixtures/apps-list.json`,
and its self-check runs on that file.

---

## Call capture and local AI bridges (F7: callcap, chief, level)

Three thin Python 3 readers behind the call-capture and local-AI widgets. They
report state and expose one action each. They do not re-implement the tools they
wrap: what they print is what the Linux box measured or left on disk.

| Script | Answers | Action |
|---|---|---|
| `callcap.py` | is a call being recorded, for how long, where, and the last three captures | `--start LABEL`, `--stop --confirm stop` |
| `chief.py` | which local model is loaded, VRAM, tokens/s, how old the reading is | `--on`, `--off` |
| `level.py` | two-channel peak and RMS level for the meter, 10 Hz maximum | none (read only) |

### Local models and call capture run on Linux, never on this Mac

`callcap`, `chief-on`, `chief-off`, `pactl`, `parec` and `pw-record` are Linux
binaries. None of them exists on the Mac, and no local model runs there. On the
Mac these readers are fixture-only or read the Linux box over the tunnel; there
is nothing here to start, and a Mac that appears to start a model is a Mac
printing a stub's log line.

That is why every path has a fixture: the Mac builds and tests the widget end to
end, the Linux box does the live check.

### Contract (same as every v5 reader)

- Exactly one JSON object on stdout, newline terminated, nothing else. `--json`
  makes it one compact line; without it the same object is pretty printed.
- `--fixture PATH` reads a snapshot instead of the host and runs no command.
- `"source"` says where the answer came from, and it takes exactly two values:
  `"fixture"` when `--fixture` was read, `"live"` when the value came off the
  host. Every envelope carries it, the `ok: false` ones included, and it is never
  the reader's name and never a path, so a widget can tell a replay from a
  reading with one string compare.
- Exit `0` for data and for honest absence (`{"ok": false, "reason": "..."}`).
  Exit `2` for a caller error: bad arguments, a missing file the caller named, or
  an action that was refused or failed.
- Timestamps are UTC ISO 8601. `level.py --rate` adds milliseconds, because a
  10 Hz meter cannot be ordered on whole seconds.
- Missing or malformed input never raises. An empty log, a partial metrics
  object, a zero-byte WAV: all are answers, not crashes.
- No secrets, no tokens, no absolute home paths in the payload (`~` stands in).
  The one exception is `--dry-run`, whose job is to print the exact argv it would
  run, so its `command` and `would_run` keep the absolute path. An action that
  actually runs, or fails, reports the shortened path.
- Reads are cached for 10 s at `~/.local/state/nexuslink/<name>.json`, written
  atomically (temp file plus `os.replace`), with `cached` and `cache_age_s` in the
  answer. `--no-cache` bypasses it; `--cache PATH` moves it. A cached `chief.py`
  answer is still honest about the reading's age: the cache stores the metrics
  file's mtime and every answer recomputes `metrics_age_s` and `stale` from it, so
  a cached answer goes stale on the same clock as a fresh one. A metrics file that
  changed under the cache is re-read, not served from the cache.
- `--self-check` runs the whole shape, the refusals, the rate limit and the
  fixture parity, and exits non-zero on a single failure. It needs no Linux host.

#### level.py is deliberately not cached

The 10 s cache rule exists so a cheap widget does not re-run an expensive probe.
A meter is the opposite: the read **is** the measurement. A cached level is a
level from ten seconds ago drawn as if it were now, which is the one lie a meter
must never tell. `level.py --rate` therefore reads continuously at the asked rate
and `--once` re-measures on every call. Every other reader in `v5/feeds/` caches.

### The exact Linux commands wrapped

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
    chief-on                                 loads the profile's model on :18080
    chief-off                                unloads it, polls for llama-server to exit

`chief-on` and `chief-off` are the only chief commands this wrapper runs. With
`--bin-dir DIR`, that directory is the only one searched: the flag does not fall
through, so an empty or wrong `--bin-dir` means "not on this host" rather than
"look somewhere else". Without it, the lookup is `PATH`, then `~/.local/bin`,
then `~/NEXUS_AI_CENTER/04_PROJECTS/LOCAL-AI-LAB/chief/bin` (the `LAB_BIN`
constant).
`chief/bin/selftest.sh` is the tool's own check and is **not wrapped**: no code
path here runs it.

`model`, `tokens_per_s`, `queue`, `vram_used_mib` and `vram_total_mib` are read
straight out of that file. VRAM is the per-pid `fdinfo` sum the poller already
computed; the B580 has no sysfs VRAM entry, so nothing here tries to invent one.
`metrics_age_s` is the file's mtime age on a live read; over 5 s (five missed
1 Hz ticks) the payload says `"stale": true` and the dock should dim rather than
show a dead number as live. A `--fixture` read has no age at all (see Fixtures).

`level.py` (PipeWire):

    pactl get-default-sink                        -> <sink>, monitor node is <sink>.monitor
    parec --device <sink>.monitor --format=s16le --rate=48000 --channels=2 --raw --latency-msec=50
    pw-record --target <sink>.monitor --rate 48000 --channels 2 --format s16 --latency 50ms -

`parec` is preferred; `pw-record` is the fallback. One block per sample
(`48000 / rate` frames), peak and RMS computed here in `array` arithmetic, no
`audioop` (removed in Python 3.13) and no numpy.

`--rate` pacing sits on a fixed grid, `t0 + k * (1 / rate)`. A late wake-up
delivers that sample late; the next sample returns to the grid. Slots that
already passed are skipped, never replayed, and no two lines are closer than
half a period, so one slow wake-up cannot burst the stream. The wait for a slot
is sliced into 5 ms sleeps: a single long `sleep` oversleeps by tens of
milliseconds on a loaded host, and that oversleep is what turns 10 Hz into 6 Hz.

### Reading it from the deck

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

### Fixtures

| File | Shape | Where it comes from |
|---|---|---|
| `../fixtures/callcap.json` | the mapped payload of a live capture plus three finished ones | the wrapper's documented layout; callcap prints text, so there is no JSON to copy |
| `../fixtures/chief.json` | `/run/user/1000/chief/metrics.json` | `recon/05-local-ai.md` keys; the numbers are placeholders, labelled as such in the file |
| `../fixtures/level.json` | 130 samples at 10 Hz: speech, silence, a clipped burst, speech, silence | synthetic and deterministic, regenerated by `level.py --make-fixture PATH`; a real monitor capture from the Linux box replaces it unchanged in shape |

A `--fixture` read reads no clock and no host state, so it makes no freshness
claim: `metrics_age_s` and `stale` are null, `metrics_age_reason` says why, and
the snapshot's own `ts` comes through as `snapshot_ts` in UTC ISO. A snapshot is
not stale; it is a recording, and only a live read has an age. The fixture
proves the shape, the Linux capture proves the contents.

### Self-checks

    python3 nexuslink.hud/v5/feeds/callcap.py --self-check
    python3 nexuslink.hud/v5/feeds/chief.py --self-check
    python3 nexuslink.hud/v5/feeds/level.py --self-check

Each prints one `FAIL`/`ok` line per check on stderr and one JSON object on
stdout, and exits non-zero if anything failed. They create their own fixture
trees under `$TMPDIR`, use stub binaries to prove the action paths without a real
tool, and never touch `~/calls`, `/run/user/1000/chief/` or a real recording.

### Shared plumbing

The generic half of each file (envelope, UTC stamps, atomic write, cache,
exit-code runner) is duplicated on purpose: this branch is based on
`v5/main-deck` before `v5/w8-feeds` lands, and a reader that imports a module
that is not in the tree does not run. When `feeds/_common.py` is merged, the
three copies fold into it mechanically; nothing in the payload changes.
