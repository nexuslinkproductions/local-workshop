# hudfix - the maintenance engine behind the utility views

One CLI, one safety model, for every "useful action" in an expanded HUD view
(`MAIN-SCREEN-BUILD.md`, "UTILITY VIEWS"). F8a owns this spine and the storage
actions; F8b to F8f add `hudfix_<domain>.py` modules next to it.

    hudfix.py list   [--json]                     every action, its class, whether this host can run it
    hudfix.py plan   ACTION [--path P] [--json]    dry run: exact items, exact bytes, what run would do
    hudfix.py run    ACTION --confirm ACTION       perform it
    hudfix.py status [--json]                     host, action census, quarantine and log state
    hudfix.py --self-check                        prove it on a throwaway tree, exit 1 on failure

`hudfix.py --json list` prints one compact line; the default is the same object
pretty printed. Nothing else ever goes to stdout - `list`, `plan`, `run` and
`status` each emit exactly one JSON object.

## Classes

| class | what it means | confirmation |
|---|---|---|
| `read` | never changes anything; `run` is the same observation and reports `changed: false` | none |
| `safe` | a change the tool itself can undo, or a benign write; the plan rides along in the run object | none |
| `reversible` | every deletion is a move into quarantine, so the MANIFEST row is the way back | `--confirm <action>`, exactly |
| `destructive` | the underlying tool has no recovery path; the action's `doc` says why | `--confirm <action>`, exactly |

Exit codes: `0` for data, a plan, a completed run and honest absence
(`{"ok": false, "reason": "..."}`); `2` for a caller or programming error and for
every `run` refusal (unknown action, missing or mismatched `--confirm`, a
Linux-only action run on this host, a module that raised, a `read` action that
reported a change); `1` only from `--self-check`.

## The module contract

Put `hudfix_<domain>.py` in `nexuslink.hud/v5/feeds/` next to `hudfix.py`. The
spine imports every `hudfix_*.py` there at startup and merges its `ACTIONS` dict;
a missing module is not an error, so the six F8 cards land in any order.

```python
ACTIONS = {
    "<name>": {
        "class": "read|safe|reversible|destructive",
        "doc": "one sentence, shown in list and in the UI",
        "plan": plan_action,        # plan(ctx) or plan()  -> dict, see below
        "run": run_action,          # run(ctx, confirm) / run(ctx) / run()
        "linux_only": False,        # optional
        "requires": ["pacman"],     # optional commands that must exist
    },
}
```

The callables are dispatched by arity, so a module written against the card text
(`plan()` with no arguments, `run(ctx, confirm)`) works unchanged. A module that
wants `ctx` in the plan takes one argument.

`plan` returns a dict; the spine fills in anything the module leaves out:

```python
{"ok": True,
 "items": [{"path": "~/.npm/_cacache", "bytes": 680923229, "files": 4039,
            "kind": "dir", "owner": "npm", "rel": "optional/path/in/quarantine"}],
 "count": 2, "bytes": 680935588,
 "would": {"verb": "move", "count": 2, "bytes": 680935588, "to": "~/.../cache-npm"},
 "notes": ["what the action keeps, and why"],
 "skipped": [{"path": "~/.cache/foo", "reason": "absent"}]}
```

`count` and `bytes` default to `len(items)` and the item sum. `items` are only
the paths the action itself enumerated - never a directory it did not walk - and
`rel` preserves structure inside the quarantine (`rel="old/thing"` lands at
`<quarantine>/<date>/<action>/old/thing`). `would` is what `run` would do; a
`read` action's `would` is `{"verb": "read"}`.

`run(ctx, confirm)` returns:

```python
{"ok": True, "changed": True, "count": 2, "bytes": 4104,
 "moved": [{"path": "~/.npm/_cacache", "destination": "~/.../cache-npm/_cacache",
            "bytes": 4096}]}
```

`run` re-enumerates at run time, so the `plan` inside a run object is the
pre-flight and the `result` is the authoritative list of what actually moved.

`ok: false` means "could not do it" and the spine exits 2; "nothing to do" is
`ok: true, changed: false`. A module may return `{"ok": false, "reason": "...",
"usage": true}` (or raise `hudfix.UsageError`) to mean the caller asked wrong -
exit 2 from `plan` as well. A plain `{"ok": false, "reason": "..."}` is honest
absence: exit 0 from `plan`, exit 2 from `run`.

A module that declares no valid `class`, or no callable `plan`/`run`, is listed
with `class: "invalid"`, `available: false` and its error in `list`; it cannot
run. The spine never guesses a class.

### Context

| member | what it gives you |
|---|---|
| `ctx.quarantine(action, items)` | move the enumerated items and append the MANIFEST rows; returns `{ok, moved, count, bytes, dir, manifest, errors}` |
| `ctx.measure(path)` | `{path, kind, bytes, files}`; `kind` is `missing`, `file`, `dir`, `symlink` or `other`; never raises |
| `ctx.root(key, default)` | a path honouring `--root key=PATH` |
| `ctx.path_arg()`, `ctx.option(key)` | the `--path` and `--param k=v` values |
| `ctx.host()` | `{system, linux, release, machine}` |
| `ctx.which(name)` | is that command on `PATH` |
| `ctx.quarantine_dir(action)` | `<root>/<local date>/<action>` |
| `ctx.now()`, `ctx.iso_now()`, `ctx.day` | UTC time, UTC ISO stamp, local date |
| `ctx.log(record)` | append one JSONL record (the spine already does this per plan and run) |

Take `ctx` as your first argument if you need any of it. To be imported by the
spine a module does `import hudfix` (the spine registers itself under that name
before discovery).

## Quarantine and log

    ~/NEXUS_AI_CENTER/_QUARANTINE/<YYYY-MM-DD>/<action>/<item>
    ~/NEXUS_AI_CENTER/_QUARANTINE/<YYYY-MM-DD>/MANIFEST.tsv

One manifest per day, one row per item, header first:

    iso_utc	action	original_path	bytes	destination
    2026-10-23T00:21:35Z	cache-npm	/Users/marcel/.npm/_cacache	4096	/Users/.../cache-npm/_cacache

The original path is absolute so a restore is `mv` back. Directory names use the
local date (what a human sees in Finder); timestamps are UTC ISO-8601. The helper
refuses `/`, `$HOME`, the quarantine root, any path that contains the quarantine
root, and anything that vanished before the move - and it only ever moves paths
that came out of the action's own enumeration.

Three manifest layouts exist in this quarantine, and the reader handles all of
them instead of guessing: this engine's five columns, the 2026-10 legacy five
(`orig_path new_path size_kb reason date`, size in KB) and a three-column
write-off (`date name reason`, no path at all). A row it cannot map keeps nulls
and is counted under `rows_without_source`, and `bytes_exact: false` says a
total leans on a KB figure. `quarantine-list` reports `formats`,
`by_action` and `rows_without_source` for exactly that reason.

    ~/.local/state/nexuslink/hudfix.log

One JSON line per `plan` and per `run`, refusals included:

    {"ts":"2026-10-23T00:21:35Z","event":"run","action":"cache-npm",
     "class":"reversible","items":2,"bytes":4110,"result":"ran","exit":0,
     "host":"Darwin","duration_ms":3,"confirmed":true}

`result` is `planned`, `absent`, `refused`, `ran` or `failed`. `list` and
`status` are not logged - they change nothing. `--log PATH` overrides for a test.
`confirmed` is true only when `--confirm` matched the action name exactly; a
missing or mistyped token logs `false` beside `"result": "refused"`, so the
field never claims that a refusal was confirmed. Fixture-mode calls are never
logged, refusals included: `--fixture` replays a recording and writes nothing.

## Host gating

A `linux_only` action, or one whose `requires` command is absent, refuses with
`{"ok": false, "reason": "not this host", "detail": "no pacman", "host": "Darwin"}`:
exit 0 from `plan`, exit 2 from `run`. The UI greys the tile out from
`list[].available` and keeps the detail for the tooltip. `available` means "this
host has the OS and the command"; a daemon that is down (`docker`) only shows up
in the plan, which reports the daemon's own error.

## Storage actions (F8a)

| action | class | gate | what it does |
|---|---|---|---|
| `cache-npm` | reversible | - | `~/.npm/_cacache`, `~/.npm/_logs` |
| `cache-uv` | reversible | - | `~/.cache/uv` |
| `cache-pip` | reversible | - | `~/.cache/pip` |
| `cache-cargo` | reversible | - | registry cache + src, git db; `bin/` and the index stay |
| `cache-yay` | reversible | linux, yay | `~/.cache/yay` |
| `cache-pacman` | reversible | linux, pacman | superseded `*.pkg.tar.*`, newest version of each package kept |
| `cache-top` | read | - | top 10 children of `~/.cache` with their known owner |
| `cache-evict` | reversible | - | one named `~/.cache` child; refuses a path it cannot attribute |
| `hermes-scratch` | reversible | - | scratch older than 7 d, `~/.hermes/logs/*.log` older than 14 d |
| `trash` | reversible | - | trash items older than 30 d |
| `journal-vacuum` | destructive | linux, journalctl | `journalctl --vacuum-time=14d`; journald rewrites its own segments, so nothing can be quarantined |
| `orphans-list` | read | linux, pacman | lists orphans; no removal action exists |
| `snapshots-list` | read | linux, btrfs | lists snapshots; never deletes one |
| `disk-health` | read | smartctl or nvme | wear, power-on hours, temperature, media errors; never runs sudo |
| `disk-btrfs` | read | linux, btrfs | scrub and balance status |
| `docker-df` | read | docker | `docker system df` |
| `docker-prune` | destructive | docker | builder cache + dangling images; a pruned layer has no copy to quarantine |
| `quarantine-list` | read | - | the last 7 days of MANIFEST rows, the restore instructions |

Age thresholds are stated in every plan. `cache-top` never clears anything:
`cache-evict` needs an explicit `--path`, takes only one direct child of the
cache root (a relative name or an absolute path to that child, nothing deeper),
and refuses a name with no known owner (`attributed: false` in `cache-top`).

Attribution is a name rule, not a prefix rule. A cache directory carries an
owner when its name equals a pattern in `ATTRIBUTION` or continues that pattern
after `-`, `_` or `.`: `uv` and `uv-3` are uv, `mystery-thing` has none. The
longest matching pattern wins, so `pip-tools` is pip-tools and not pip. `gh` is
the GitHub CLI only as an exact name: `ghostty` is a terminal emulator and
`pipenv` is not pip, so both stay unattributed and neither can be evicted.
`cache-evict` takes the owner from the child's own name, so a deeper path is
refused even when its last component looks like a known cache.

"Exact" is byte for byte: no whitespace trimming and no case folding. `gh `,
` gh` and `GH` are three names that are not `gh`, so `cache-top` reports them
`attributed: false` and `cache-evict` refuses them with nothing moved. The case
rule is a deliberate trade-off: on APFS `GH` and `gh` normally resolve to the
same directory, while on a case-sensitive Linux filesystem they are two
directories. Folding case would make `GH` evictable on Linux; refusing an
unknown spelling is the safe direction, and the cost is that a directory
created as `GH` has to be renamed to `gh` (or `ATTRIBUTION` taught its owner)
before it can be cleared.

`cache-pacman` keeps the newest copy of each package and orders versions with
pacman's own `vercmp` rule (`hudfix_storage._vercmp`): epochs first, then
numeric segments by value, then the release. `foo-1.10-1` is newer than
`foo-1.9-1`, so `1.9` is the superseded file and `1.10` stays.

## Test hooks

`--module-dir PATH` (where to discover modules - the spine's own self-check
points it at a throwaway probe module), `--root KEY=PATH` (point a logical root
at a substitute, e.g. `--root npm=/tmp/fake/.npm`), `--path PATH` (an action's
target), `--param k=v` (an action's option), `--quarantine-root PATH`,
`--log PATH`, and `--fixture PATH` on `list`/`plan`/`status` to replay a recorded
object for UI work. Fixture mode replays the file and nothing else: it runs no
module discovery, lists no directory, reads no host state and writes no log
line, so the same file prints the same bytes under any `$HOME`. A named file
that does not exist is exit 2; a file that exists but cannot be read as one JSON
object (empty, truncated, a list) is exit 0 with `{"ok": false, "reason": "...",
"kind": "fixture"}` so the UI can show the bad recording instead of a crash.
`run` refuses `--fixture` with exit 2.

## Self-checks

    python3 nexuslink.hud/v5/feeds/hudfix.py --self-check          # 105 checks
    python3 nexuslink.hud/v5/feeds/hudfix_storage.py --self-check  # 193 checks

Both build their tree under `$TMPDIR`, drive the real CLI as a subprocess, and
assert the tree digest before and after every plan, the exit code of every
refusal, the MANIFEST row for every move, and one log line per plan and per run.
They never read or write a real cache, a real snapshot, or the real quarantine.

## What this doc does not promise

The Linux paths (`pacman`, `btrfs`, `journalctl`, `nvme`) cannot run on this Mac,
so their parsing is exercised only through the gates and the self-checks; Linux
verifies the live path. `disk-health` on this Mac reads the real drive through
`smartctl` without root, which works here; a host that needs root gets a refusal
that says so and the command to run by hand.
