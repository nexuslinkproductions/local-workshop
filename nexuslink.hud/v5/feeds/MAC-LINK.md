# Mac link feed and typed Mac actions (F1)

Two stdlib-only Python 3 tools behind the Mac Link Explorer on the v5 deck.

| File | Role |
|---|---|
| `mac_link.py` | one JSON status sample of the Mac, collected in ONE shell round trip and cached 10 s |
| `mac_actions.py` | typed actions with a safe/unsafe class; refuses unless `--confirm` or `--dry-run` |
| `../fixtures/mac_link.txt` | a recorded collector output, used by `mac_link.py --self-check` |

Both run on this Mac with no arguments and no third-party packages. Neither
writes to the operator's config or the live HUD tree.

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
| `collected_at` | when the Mac was sampled (the Mac's clock, UTC ISO); `null` with a reason in a fixture that carries no `@@NOW` |
| `cached`, `cache_age_s` | true when this answer came from the 10 s cache |
| `mac.battery` | `percent`, `state`, `remaining`, `present`, `power_source` |
| `mac.load` | `avg` (`[1, 5, 15]` minutes), `load1_frac` (load1 / cores), `cores` |
| `mac.memory` | `pressure` (`normal`, `warning`, `critical`), `pressure_raw`, `free_pct` |
| `mac.soc_temp_c` | SoC temperature in C, or `null` with a reason (see below) |
| `mac.thermal` | `scheduler_limit` and `speed_limit` when `pmset -g therm` reports them |
| `mac.uptime_s`, `mac.uptime_human` | from `kern.boottime`, `uptime` text as the fallback; both `null` with a reason in a fixture that carries no `@@NOW` |
| `tunnel` | `peer`, `up`, `rtt_ms`, `route` (`direct` or `relay`) |
| `kanban` | `running` count and `items` (`id`, `title`, `assignee`, `started_at`, `age_s`); `age_s` is `null` in a fixture that carries no `@@NOW`, covered by the list-level reason `kanban.items` |
| `devin` | `running` count and `items` (`pid`, `model`, `command`); when no process carries `--model`, `model` is `null` and the list-level reason `devin.items` says why |
| `reasons` | dotted key -> one short reason, for every null value (one key per null path, plus one per list when per-item values are null) |

Exit codes: `0` for data and for honest absence (`{"ok": false, "reason": ...}`,
`kind` says missing or malformed), `2` only for a caller error (bad `--host`, a
fixture path that does not exist, a programming error). A fixture or cache file
that is not UTF-8 is malformed input, not a crash: the fixture answers
`ok: false` with exit 0, and the cache is treated as a miss and rewritten.

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

The kanban call strips four Hermes markers for that one subprocess:
`HERMES_DELEGATED_CHILD_CONTEXT`, `HERMES_KANBAN_TASK`,
`HERMES_KANBAN_RUN_ID` and `HERMES_KANBAN_CLAIM_LOCK`. Those markers fence
board *mutations*; this is a read-only list, and without the strip the same
command that works over ssh reports the board unreadable when the feed is run
inside a Hermes worker.

### SoC temperature is null on this Mac, on purpose

`pmset -g therm` prints only `Note: No thermal warning level has been recorded`
here; it records no temperature on Apple Silicon, and the real sensor needs
root (`powermetrics`). The key is `null` and `reasons["mac.soc_temp_c"]` says
exactly that. A plausible number would be a lie. `scheduler_limit` and
`speed_limit` are parsed when the machine throttles and carry their own
`reasons["mac.thermal.scheduler_limit"]` / `["mac.thermal.speed_limit"]` entry
when it does not, so the two nulls there are explained too.

### Cache

`~/.local/state/nexuslink/mac_link.json`, written atomically (temp file plus
`os.replace`). The TTL is 10 s and not configurable: two calls inside the window
run zero collectors. Cache age uses the reader's clock, not the Mac's, so a
skewed Mac clock cannot freeze the cache. An entry dated in the future is a
miss, not a fresh hit: a reader clock stepped back recollects instead of
pinning a stale sample as fresh. Fixture mode never reads or writes the cache,
and a failed collection is not cached.

Measured on this Mac (2026-10-23): one live collection 2.1 to 3.4 s, of which
the kanban CLI is 1.0 to 4.5 s; `tailscale ping` 0.3 s; every local probe under
50 ms. A cached call is 0.05 to 0.08 s.

### Fixture purity

`--fixture` reads no host state and no clock, apart from the one clock read that
stamps `generated_at` (the envelope requires it). A fixture with no `@@NOW`
line therefore reports `collected_at`, `mac.uptime_s`, `mac.uptime_human` and
every `kanban.items[].age_s` as `null`, each with a reason, so two runs of the
same fixture are byte-identical minus `generated_at`. The reader-clock fallback
in `parse_collector` is live mode only, and it says so under `reasons["mac.now"]`.

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
| `status` | safe | `sw_vers -productVersion; uptime; pmset -g batt; pgrep -fl '[c]affeinate' || true` | nothing |
| `lock` | unsafe | `pmset displaysleepnow` | nothing; the screen locks when the Mac requires a password after display sleep |
| `sleep` | unsafe | `pmset sleepnow` | nothing |
| `wake` | unsafe | `caffeinate -dims` (background) | nothing; records `~/.local/state/nexuslink/caffeinate.pid` |
| `wakeoff` | unsafe | `kill -TERM <recorded caffeinate pid>` | a caffeinate PID recorded by `wake` whose command line is caffeinate |
| `start-bot <profile>` | unsafe | `<hermes> -p <profile> gateway run` (background) | a Hermes profile name; records `~/.local/state/nexuslink/bots/<profile>.pid`; refuses if that PID is alive |
| `stop-bot <profile>` | unsafe | `kill -TERM <recorded pid>` | a live PID file for that profile whose `ps` command line carries `-p <profile>` |

Rules the code enforces:

- `--dry-run` prints the command it would run and exits 0. The line is
  reader-facing: a program under the home directory shows as `~` (see below),
  so compare it with the table after that substitution.
- An unsafe action with neither `--confirm` nor `--dry-run` refuses with exit 2
  and one line on stderr, and runs nothing. It is not silently dry: a caller
  that forgot the flag learns it.
- Running one needs `--confirm <action-name>` with the name equal to the
  action. A mismatched name refuses with exit 2 and one line on stderr, and
  nothing runs, with or without `--dry-run`.
- `status` reports `ok: true` with caffeinate off, which is its usual state:
  the `pgrep` probe ends with `|| true`, so a no-match does not fail the whole
  script, and `caffeinate` comes back `{"on": false, "pids": []}`.
- `stop-bot` never signals a pattern and never uses `pkill -f`. It reads the
  recorded PID, asks `ps -o command=` for that PID, and refuses unless the
  command line is a `hermes`/`devin` runtime carrying that profile's
  `-p/--profile`. A PID that is gone, unreadable, or belongs to something else
  is refused.
- `wakeoff` is the same rule for `caffeinate`.
- A refusal names the program it found, never another process's command line:
  `pid 5150 is not caffeinate (command: python3)`. The full argv of a foreign
  process can carry paths and flags that are none of this tool's business.
- The `command` field and the `--dry-run` line show a program under the home
  directory as `~` (`~/.local/bin/hermes -p kakashi gateway run`). The argv
  that runs keeps the absolute path, which a process spawned without a login
  shell needs.
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
and hosts the dispatcher. If the operator wants a different runtime, it is the one
line in `build_plan` plus this table.

## Self-checks

```
$ python3 nexuslink.hud/v5/feeds/mac_link.py --self-check
...
self-check ok: 112 passed, 0 failed
$ python3 nexuslink.hud/v5/feeds/mac_actions.py --self-check
...
self-check ok: 77 passed, 0 failed
```

`mac_link.py --self-check` parses the recorded fixture and asserts every key,
proves each null carries its own reason (fixture, a four-line broken variant set
and the partial fixture), and runs the same fixture through the CLI. It proves
fixture purity: a copy of the fixture with the `@@NOW` pair removed is parsed
twice with `time.time` pinned to two epochs an hour apart, the two payloads are
identical minus `generated_at`, the clock is read exactly once per run (the
`generated_at` stamp), and `collected_at`, `mac.uptime_s`, `mac.uptime_human`
and every `kanban.items[].age_s` are `null` with a reason; the same file then
runs twice through the CLI 1.1 s apart and matches minus `generated_at`. It
proves two calls inside 10 s run one collector, that an aged cache collects
again, and that a cache dated in the future is a miss rather than a fresh hit.
An empty fixture and a non-UTF-8 fixture take the `ok: false` path with exit 0,
while a partial fixture is `ok: true` with nulls and reasons
(`partial-ok-true`). It proves a non-UTF-8 cache is a miss that gets rewritten,
proves a missing fixture exits 2, and proves `ssh_runner` makes exactly one
`ssh` call with the expected argv by stubbing `subprocess.run` (no connection
is opened). Every CLI subprocess runs with a stub PATH whose commands log and
exit 1, so an accidental real invocation fails the run.

`mac_actions.py --self-check` checks the typed table, the dry-run line for
`sleep`, the bare-refusal path for `sleep`, `lock`, `wake` and `start-bot`, the
wrong-confirm path, the profile matching and PID rules, and the `status` parser.
It runs the real `STATUS_SCRIPT` against a stub PATH where `pgrep` exits 1, and
asserts the script exits 0 and the action returns `ok: true` with
`caffeinate.on` false. It also asserts the `start-bot` display line carries no
absolute home path while the argv keeps it, and that a refusal names only the
program it found (`python3`, never that process's command line). It executes no
unsafe action: every unsafe path is refused before a plan is built, and the
stub logs are asserted free of any state-changing command.

Every execution in the self-check goes through `RecordingRuntime`, which records
the argv and spawns nothing: `list-dir` on a temporary directory is planned and
recorded, never run as a real `ls`, and the run asserts no runner was touched.
The only processes either self-check spawns are its own `python3` CLI runs and
the one `/bin/sh` that runs `STATUS_SCRIPT` against a stub PATH; no collector
command and no action command reaches the Mac.
