# Mac link feed and typed Mac actions (F1)

Two stdlib-only Python 3 tools behind the Mac Link Explorer on the v5 deck.

| File | Role |
|---|---|
| `mac_link.py` | one JSON status sample of the Mac, collected in ONE shell round trip and cached 10 s |
| `mac_actions.py` | typed actions with a safe/unsafe class, dry run by default, confirm to run |
| `../fixtures/mac_link.txt` | a recorded collector output, used by `mac_link.py --self-check` |

Both run on this Mac with no arguments and no third-party packages. Neither
writes to Marcel's config or the live HUD tree.

## mac_link.py

```
python3 nexuslink.hud/v5/feeds/mac_link.py --host local --json
python3 nexuslink.hud/v5/feeds/mac_link.py --host ssh:mac --json     # from the Linux HUD
python3 nexuslink.hud/v5/feeds/mac_link.py --fixture nexuslink.hud/v5/fixtures/mac_link.txt --json
python3 nexuslink.hud/v5/feeds/mac_link.py --self-check
```

Payload, one object on stdout:

| Key | Meaning |
|---|---|
| `ok`, `source`, `mode`, `generated_at` | the shared feed envelope (`mode` is `live` or `fixture`) |
| `host` | the requested runner: `local` or `ssh:<host>` |
| `collected_at` | when the Mac was sampled (the Mac's clock, UTC ISO) |
| `cached`, `cache_age_s` | true when this answer came from the 10 s cache |
| `mac.battery` | `percent`, `state`, `remaining`, `present`, `power_source` |
| `mac.load` | `avg` (`[1, 5, 15]` minutes), `load1_frac` (load1 / cores), `cores` |
| `mac.memory` | `pressure` (`normal`, `warning`, `critical`), `pressure_raw`, `free_pct` |
| `mac.soc_temp_c` | SoC temperature in C, or `null` with a reason (see below) |
| `mac.thermal` | `scheduler_limit` and `speed_limit` when `pmset -g therm` reports them |
| `mac.uptime_s`, `mac.uptime_human` | from `kern.boottime`, `uptime` text as the fallback |
| `tunnel` | `peer`, `up`, `rtt_ms`, `route` (`direct` or `relay`) |
| `kanban` | `running` count and `items` (`id`, `title`, `assignee`, `started_at`, `age_s`) |
| `devin` | `running` count and `items` (`pid`, `model`, `command`) |
| `reasons` | dotted key -> one short reason, for every null value |

Exit codes: `0` for data and for honest absence (`{"ok": false, "reason": ...}`,
`kind` says missing or malformed), `2` only for a caller error (bad `--host`, a
fixture path that does not exist, a programming error).

### One collector

`collector_script()` builds ONE shell string that prints every value once
between `@@NAME` markers, and the runner is one call:

| `--host` | runner |
|---|---|
| `local` | `/bin/sh -c <script>` on this Mac |
| `ssh:mac` | `ssh -o BatchMode=yes -o ConnectTimeout=... mac <script>` |
| `--fixture PATH` | reads a recorded output, same parser, no command |

The parser (`parse_collector`) is shared by all three. The commands, each
verified on this Mac (macOS 26.4.1, Apple Silicon):

| Value | Command |
|---|---|
| hostname | `scutil --get LocalHostName` (`hostname -s` reports the generic `Mac`) |
| battery | `pmset -g batt` |
| load | `sysctl -n vm.loadavg` |
| cores | `sysctl -n hw.ncpu` |
| uptime | `sysctl -n kern.boottime` (`uptime` text as the fallback) |
| memory free | `memory_pressure -Q` |
| pressure level | `sysctl -n kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical) |
| thermals | `pmset -g therm` |
| RTT | `tailscale ping --c=1 <peer>` (default peer `omarchylink`, the HUD host) |
| cards | `hermes kanban list --status running --json` |
| Devin runs | `pgrep -fl '(^|/)devin( |$)'` |

Absolute fallbacks for `hermes` and `tailscale` matter: a non-interactive ssh
shell gets `/usr/bin:/bin:/usr/sbin:/sbin`, where neither binary is on PATH.

The kanban call strips `HERMES_DELEGATED_CHILD_CONTEXT` and `HERMES_KANBAN_TASK`
for that one subprocess. Those markers fence board *mutations*; this is a
read-only list, and without the strip the same command that works over ssh
reports the board unreadable when the feed is run inside a Hermes worker.

### SoC temperature is null on this Mac, on purpose

`pmset -g therm` prints only `Note: No thermal warning level has been recorded`
here; it records no temperature on Apple Silicon, and the real sensor needs
root (`powermetrics`). The key is `null` and `reasons["mac.soc_temp_c"]` says
exactly that. A plausible number would be a lie. `cpu_scheduler_limit` and
`speed_limit` are still parsed when the machine throttles.

### Cache

`~/.local/state/nexuslink/mac_link.json`, written atomically (temp file plus
`os.replace`). The TTL is 10 s and not configurable: two calls inside the window
run zero collectors. Cache age uses the reader's clock, not the Mac's, so a
skewed Mac clock cannot freeze the cache. Fixture mode never reads or writes the
cache, and a failed collection is not cached.

Measured on this Mac (2026-10-23): one live collection 2.1 to 3.4 s, of which
the kanban CLI is 1.0 to 4.5 s; `tailscale ping` 0.3 s; every local probe under
50 ms. A cached call is 0.05 to 0.08 s.

## mac_actions.py

```
python3 nexuslink.hud/v5/feeds/mac_actions.py --list --json
python3 nexuslink.hud/v5/feeds/mac_actions.py sleep --dry-run     # prints: pmset sleepnow
python3 nexuslink.hud/v5/feeds/mac_actions.py sleep --confirm sleep
python3 nexuslink.hud/v5/feeds/mac_actions.py --self-check
```

| Action | Class | Exact command | What it needs |
|---|---|---|---|
| `open-app <name>` | safe | `open -a <name>` | an installed app name |
| `screenshot` | safe | `screencapture -x -t jpg <path>` | Screen Recording permission for the calling process; default `~/Desktop/nexus-<timestamp>.jpg`, override with `--path` |
| `list-dir <path>` | safe | `ls -la -- <path>` | a path the Mac user can read |
| `status` | safe | `sw_vers -productVersion; uptime; pmset -g batt; pgrep -fl '[c]affeinate'` | nothing |
| `lock` | unsafe | `pmset displaysleepnow` | nothing; the screen locks when the Mac requires a password after display sleep |
| `sleep` | unsafe | `pmset sleepnow` | nothing |
| `wake` | unsafe | `caffeinate -dims` (background) | nothing; records `~/.local/state/nexuslink/caffeinate.pid` |
| `wakeoff` | unsafe | `kill -TERM <recorded caffeinate pid>` | a caffeinate PID recorded by `wake` whose command line is caffeinate |
| `start-bot <profile>` | unsafe | `<hermes> -p <profile> gateway run` (background) | a Hermes profile name; records `~/.local/state/nexuslink/bots/<profile>.pid`; refuses if that PID is alive |
| `stop-bot <profile>` | unsafe | `kill -TERM <recorded pid>` | a live PID file for that profile whose `ps` command line carries `-p <profile>` |

Rules the code enforces:

- `--dry-run` prints the exact command and exits 0.
- Every unsafe action is dry by default. Running one needs
  `--confirm <action-name>` with the name equal to the action. A mismatched
  name refuses with exit 2 and one line on stderr, and nothing runs.
- `stop-bot` never signals a pattern and never uses `pkill -f`. It reads the
  recorded PID, asks `ps -o command=` for that PID, and refuses unless the
  command line is a `hermes`/`devin` runtime carrying that profile's
  `-p/--profile`. A PID that is gone, unreadable, or belongs to something else
  is refused.
- `wakeoff` is the same rule for `caffeinate`.
- All files written are PID files under `~/.local/state/nexuslink/` and the
  screenshot the caller asked for (default `~/Desktop`). Nothing writes to
  `~/.config` or the live HUD tree.

`--list` prints one JSON object with `name`, `class`, `usage`, `command`,
`needs`, `confirm` per action. Execution prints one JSON object (`ran`, `exit`,
`stdout`, `stderr`, plus a parsed `status` object for the `status` action).
Exit codes: `0` success or dry run, `1` the action ran and failed, `2` refused
or a caller error.

`start-bot` decision: a bot runtime on this Mac is the profile's Hermes gateway
(`hermes -p <profile> gateway run`), the long-lived process that receives work
and hosts the dispatcher. If Marcel wants a different runtime, it is the one
line in `build_plan` plus this table.

## Self-checks

```
$ python3 nexuslink.hud/v5/feeds/mac_link.py --self-check
...
self-check ok: 75 passed, 0 failed
$ python3 nexuslink.hud/v5/feeds/mac_actions.py --self-check
...
self-check ok: 53 passed, 0 failed
```

`mac_link.py --self-check` parses the recorded fixture and asserts every key,
runs the same fixture through the CLI, proves two calls inside 10 s run one
collector (and an aged cache collects again), proves an empty and a partial
fixture take the `ok: false` and per-key-null paths with exit 0, proves a
missing fixture exits 2, and never opens an ssh connection.

`mac_actions.py --self-check` checks the typed table, the dry-run line for
`sleep`, the default-dry and wrong-confirm paths, the profile matching and PID
rules, and the `status` parser. It executes no unsafe action: every unsafe path
goes through `RecordingRuntime`, and the run asserts that no action command and
no spawn reached it. The one real execution is `list-dir` on a temporary
directory.
