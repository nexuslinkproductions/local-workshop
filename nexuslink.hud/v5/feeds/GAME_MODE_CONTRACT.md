# Game mode: pause-heavy flag contract (proposed)

Status: **proposed. Not implemented anywhere yet.** F3 ships the writer and this
document only. The fleet dispatcher, the profile configs and the scheduler are
untouched, and this card schedules and starts nothing. Someone with dispatcher
ownership has to add the read described below; until then the flag file is inert.

Owner of the writer: `game_mode.py` in this directory (HUD v5 F3).
Contract version: 1, 2026-10-23.

## The file

    $HOME/.local/state/nexuslink/game_mode.json

- Created by the controller if the directory does not exist (0755 directory,
  0644 file).
- One JSON object, UTF-8, trailing newline, no other keys.
- Written atomically: a temp file in the same directory, `fsync`, then
  `os.replace`. A reader never sees a half-written object.
- Written only by `game_mode.py --status` and `game_mode.py --toggle`.
  `--dry-run` and `--no-write` suppress it. Nothing else writes it, ever.
- A `--fixture` run writes it only when the caller names `--state-dir` or
  `--flag-file`, and it reads the flag only from that same named path. It never
  reads the live flag, so a fixture snapshot cannot inherit a host value. When
  the named file already records a gaming run, its `since` is kept: the run
  started then, and a fixture tick is the next tick of that same run. Otherwise
  `since` is the moment of that run.

## The fields

| Field | Type | Meaning |
|---|---|---|
| `gaming` | boolean | a game process was running at the last controller tick |
| `pause_heavy` | boolean | today always equal to `gaming`; this is the one field a dispatcher reads |
| `since` | ISO 8601 UTC string, or `null` | first tick of the current gaming run, held stable across ticks; `null` when `gaming` is false |
| `updated_at` | ISO 8601 UTC string | when this evaluation ran; changes every tick |

Example, game running:

    {
      "gaming": true,
      "pause_heavy": true,
      "since": "2026-10-23T01:20:04Z",
      "updated_at": "2026-10-23T01:20:14Z"
    }

Example, no game:

    {
      "gaming": false,
      "pause_heavy": false,
      "since": null,
      "updated_at": "2026-10-23T01:41:52Z"
    }

`since` is not rewritten on every poll: it marks the moment the run started, so a
dispatcher can report "paused for 23 minutes" without bookkeeping of its own.

## How often a dispatcher should read it

Once per tick, at the start of the tick, with a single read: open, parse, decide.
Do not poll it inside the tick, do not watch it with a file monitor, and do not
read it faster than once every 10 seconds even if the tick is faster than that.
Ten seconds is the same floor as the feed's network cache (`game_mode_net.json`),
so a dispatcher reading at that rate can never see numbers newer than the
controller would produce anyway. The widget calls `--status` on its own timer;
if it stops, `updated_at` stops advancing, which is exactly what staleness
detection needs.

## What honouring it means

While `pause_heavy` is `true`:

1. **Hold new heavy jobs.** Do not admit a new heavy job to the lane; leave it
   queued with a visible reason ("game mode: paused"). "Heavy" means whatever the
   dispatcher already classifies as heavy (builds, renders, Fusion runs); this
   contract adds no new classification.
2. **Never kill, preempt or migrate a running job.** Pausing admission is safe;
   stopping work mid-flight is not. A job already running finishes.
3. **Keep the rest of the board moving.** Non-heavy work (reads, reviews,
   verifiers, quick fixes) is not held.

While `pause_heavy` is `false`:

4. **Resume normal admission** on the next tick. No separate "resume" signal
   exists; the flag going false is the signal.

Fail-open rules, in order:

5. File missing, unreadable, malformed, or missing either boolean: treat as
   **not paused**. The dispatcher must never hold jobs because of a file it
   cannot parse.
6. `updated_at` older than **300 seconds**: treat as **stale, not paused**, and
   say so once in the log. The controller ticks at least every 30 seconds while
   the deck is up; five minutes of silence means the controller is gone, and a
   gone controller must not pin the fleet.
7. Log one line per transition (`paused` -> `running`, `running` -> `paused`) and
   none per tick, so a game session does not flood the log.

Honouring the flag is a behaviour change to the dispatcher, so it needs its own
review and its own rollback (delete the read, keep the writer). It is deliberately
not part of this branch.

## What the controller writes besides the flag

| Path | Purpose | Cadence |
|---|---|---|
| `$HOME/.local/state/nexuslink/game_mode.json` | the flag above | every `--status` / `--toggle` |
| `$HOME/.local/state/nexuslink/game_mode_net.json` | ping+jitter cache for both targets, one round | refreshed at most every 10 s |
| `$HOME/.local/state/nexuslink/ptt.state` | simulated dictation/game state, fixture mode only (a `--toggle` with `--fixture`) | on `--toggle` |

Every write is atomic (temp file + `os.replace`). `--status` never writes a ptt
state; live `--toggle` does not either, because on Linux `ptt-toggle` owns that
file. `--ptt-state PATH` redirects the simulated state if a caller wants it
elsewhere.

A `--fixture` run writes none of these unless the caller names the path:
`--state-dir` covers all three, `--flag-file` the flag, `--cache-file` the net
cache. It also reads no host state in fixture mode (`~/.cache/ptt-toggle.state`,
the live flag and the live net cache are not consulted). `--toggle --fixture`
keeps its documented `ptt.state` write, the one host write a fixture run makes
on its own; the following tick only reads that file back when the same
`--state-dir` is named, so a round trip has to name it.

Nothing under a profile config, nothing in cron, nothing in the Quickshell tree.

## Signals and how mode is decided

| Signal | Host | Used for |
|---|---|---|
| `pgrep -f PioneerGame`, `pgrep -f ArcRaiders` (override: `--pattern`, repeatable) | Mac and Linux | `game.running`, `game.process`, `game.pid` |
| `hyprctl clients -j`, window `class` / `initialClass` | Linux only | `game.class`; fills `game.running` when `pgrep` misses |
| `$HOME/.cache/ptt-toggle.state` | Linux, written by `ptt-toggle` | `mode` = `dictation` or `game` |
| `$HOME/.local/state/nexuslink/ptt.state` | fixture mode, written by a simulated `--toggle` | same, so a Mac demo can flip and read back |
| `$HOME/.cache/mouse-profile` (one line), `--mouse-profile`, or `mouse_profile` in the fixture | optional, none on this Mac | `mouse_profile` |

The simulated state is read only in fixture mode, when the caller named a state
dir with `--state-dir` or a file with `--ptt-state`; a bare `--status --fixture`
never reads it. The live path never reads or writes it.

`mode` is the dictation/game toggle, not the process: a `ptt-toggle` state of
`on`/`dictation`/`enabled`/`1` reports `dictation`; `off`/`game`/`gaming`/`0`
reports `game`; with no state file it falls back to `game` when a game process
runs and `unknown` otherwise. `game.running` stays independent, so
`needs_me: true` is reported when a game process runs while the toggle says
`dictation` (the two disagree; a human should look).

`pause_heavy` follows `game.running`, the process, not the toggle: the plan says
"pauses heavy Mac jobs while a game process runs". Toggling to dictation does not
resume the fleet while the game is still open.

## Network probe

Both targets are pinged in one round, in parallel, and cached together:

    ping -c 5 -W 1000 <router>      # macOS/BSD: -W is milliseconds
    ping -c 5 -W 1  <router>        # Linux iputils: -W is seconds

The router is the default-route gateway (`route -n get default` on macOS,
`ip route show default` on Linux), or `--gateway-host`. The public target is
`1.1.1.1` (`--public-host`). `rtt_ms` is the mean and `jitter_ms` is
`mdev`/`stddev` from the ping summary line. When there are no replies both are
`null` with a `reason`, loss stays a measured percentage; when the command
cannot run at all, all three are `null` with a `reason`. No zero is ever invented.

The cache is keyed on both targets, not just on time: `game_mode_net.json` stores
`gateway_host` and `public_host` next to the numbers, and a request for another
router or another public target inside the 10 s window is a miss. A round aimed
at a dead target therefore reports that target's null with its own reason
instead of inheriting the previous target's numbers.

`--dry-run` runs no probe at all: the gateway is not discovered, neither target
is pinged, the cache is neither read nor written, and both entries come back
`null` with reason `dry-run`. `--no-net` does the same for `--status` with
reason `network probe skipped (--no-net)`.

## Fixture schema

`--fixture PATH` takes a file, or a directory containing `game_mode.json`. Used
by the Mac (no `ptt-toggle`, no `hyprctl`) and by `--self-check`. Fields, all
optional and tolerated if partial:

| Key | Shape |
|---|---|
| `generated_at` | ISO UTC string; the reported `measured_at` for the fixture's net block |
| `ptt_state` | `"dictation"` / `"game"` / `"on"` / `"off"` (a real state file wins over this) |
| `mouse_profile` | string |
| `pgrep` | `[{"pid": N, "command": "..."}]`, a list of strings, or `{"running": bool, "process": "..."}`; `[]` means "pgrep printed nothing" |
| `hyprctl` | `hyprctl clients -j` output: a list, or `{"clients": [...]}` |
| `gateway_host`, `public_host` | strings |
| `ping` | `{"gateway": "<raw ping output>", "public": "<raw ping output>"}` parsed by the same parser as live |
| `net` | alternative to `ping`: a pre-computed `net` object copied through |
| `toggle` | `{"exit_code": 0, "output": "..."}`, reported when `--toggle` is simulated |
| `needs_me`, `needs_me_reason` | force attention in a fixture |

`nexuslink.hud/v5/fixtures/game_mode.json` is the shipped example. Its ping
blocks are internally consistent: the mean and the population stddev recomputed
from the `time=` samples match the summary line within 0.01, so the parser cannot
report a jitter the samples do not give. `--self-check` proves that on the
shipped file, not only on a generated one.

## Commands and exit codes

    game_mode.py --status  [--fixture PATH] [--json]     # one status object
    game_mode.py --probe   [--fixture PATH]              # network only
    game_mode.py --toggle  [--fixture PATH] [--dry-run]  # flips mode, writes state
    game_mode.py --self-check                            # hermetic, exit 1 on failure

Exit `0` for data and for honest absence (`{"ok": false, "reason": "...", "kind":
"missing" | "malformed"}`), `2` only for a bad argument or a path the caller named
that is not there. `kind` is `missing` for a fixture that is absent or empty and
`malformed` for one that is unreadable or not JSON; an operation the host refused
reports `unavailable` (no binary) or `failed` (the command ran and failed).

`--json` prints exactly one compact line on stdout (no indentation, UTF-8 kept as
is) for a `Process` consumer; without it the same object is pretty printed for a
human. Both are exactly one JSON object and nothing else.
