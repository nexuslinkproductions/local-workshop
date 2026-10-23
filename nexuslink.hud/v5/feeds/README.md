# v5 feeds

Four Python 3 readers that turn the real sources into the one JSON object each
HUD widget needs. Stdlib only, no third-party imports, no daemon, no cache
directory of their own.

| Reader | Live source | Fixture |
|---|---|---|
| `sessions.py` | `~/.hermes/state.db`, opened read-only | `v5/fixtures/sessions.json` |
| `link.py` | tailscale (`status --json`, `ping`), the tunnel unit, one ssh for battery and load | `v5/fixtures/link.json` |
| `apps.py` | `~/.local/state/nexuslink/apps.json` | `v5/fixtures/apps.json` |
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
mostly automation), so the count says nothing about what Marcel uses. A
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
file: `apps.py` only reads and ranks it.
