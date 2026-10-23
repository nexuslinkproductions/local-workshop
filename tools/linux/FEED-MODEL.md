# Feed process model: measured decision

Status: decided (model B: one supervisor under systemd --user). Not enabled.
The parent installs and enables the unit (see tools/linux/systemd/README.md).
Nothing in this worktree starts, enables or reloads a service.

Host: Linux, Python 3.14, systemd 262 (user manager). The host is shared with
other workers; load average was 3.4 to 7.9 during the runs. Read the numbers as
an order of magnitude, not a lab value.

## Models

- A, today: DeckMain runs one Quickshell `Process` per reader, armed by two
  `Timer`s (10 s and 60 s). Each run starts a fresh `python3`.
- B: `nexuslink.hud/v5/feeds/supervisor.py` runs as one process under systemd
  --user. It imports the readers once, forks one child per run, and writes one
  snapshot per reader plus a heartbeat. DeckMain reads the files.

## Method

`tools/linux/feed-model-bench.py`, 60 s per run, run sequentially under
`nice -n 19 ionice -c3`. Same readers and cadence in both models: sessions, link
(`--fixture`, no ssh), metrics every 10 s; apps and df every 60 s. CPU is process
CPU time (utime + stime, children included) as a share of one core over the
window's wall time. The live link adds 58.9 ms per link run (reports/fb.md),
computed as 6 x 58.9 ms = 0.353 s per minute and added to all three rows alike.

Two samples. Sample 1 is the run of this card on 2026-10-23 13:28 to 13:31.
Sample 2 is an earlier run of the same bench at 13:15 to 13:19 (its raw JSON is
in the scratch folder `profiles/minato/cache/scratch/p-bench/`). Its numbers are
close to sample 1, so the result does not hang on one minute.

## Numbers

| Measure | A: Process per reader | B: supervisor, core four | B: core four + 5 optional |
|---|---|---|---|
| CPU % of one core, sample 1 | 1.123 | 0.268 | 0.412 |
| CPU % of one core, sample 2 | 1.222 | 0.256 | 0.494 |
| CPU % with live link, sample 1 | 1.713 | 0.855 | 0.998 |
| CPU % with live link, sample 2 | 1.811 | 0.845 | 1.082 |
| Process spawns per minute | 20 (19 readers + df) | 21 (20 + df) | 31 (30 + df) |
| Peak processes alive | 5 | 2 | 2 |
| Memory, sample 1 | child peak avg 22.1 MB, max 25.8 MB (each run) | supervisor VmHWM 23.9 MB, 1 thread | VmHWM 24.7 MB |
| Avg wall per run ms, sample 1 | sessions 41.4, link 40.3, metrics 34.1, apps 36.3, df 5.5 | sessions 51.0, link 54.2, metrics 50.9, apps 50.6 | 50 to 52 each; callcap 51.1, chief 50.8, level 50.5, recent 50.6, game_mode 50.9 |
| Kills, skipped ticks | n/a | 0, 0 | 0, 0 |

CPU per run, sample 1: A about 34 ms (0.674 s for 20 spawns); B about 8 ms (0.162 s
for 21 runs). The gap is the interpreter start, which B pays once.

Sample 1 raw files: reports/p-bench-process.json, reports/p-bench-supervisor.json,
reports/p-bench-supervisor-optional.json.

Known skew, in B's disfavour: the supervisor window is 60.25 s and runs the t=60
tick, so it ran sessions 7 times against 6 for A. Corrected, B is a little cheaper
than shown.

Budget: 3% of one core for all readers together. B with the optional jobs and a
live link is 1.0% (sample 1) and 1.1% (sample 2). Inside budget.

Not measured: the Quickshell side of model A (Process objects, stdout collection,
QML JSON.parse). A is a Python replay of the same spawn pattern, so A is an
underestimate and B's advantage is, if anything, understated.

## Failure isolation

A is read from DeckMain.qml (armFeed, the feed Processes with StdioCollector, and
the watchdog in freshnessTick). Not run live: this card does not run Quickshell
outside the private shell, and the Process contract is what is read here.
B is run in `--self-check` (the case names are the ones the check prints).

| Case | A: DeckMain today | B: supervisor |
|---|---|---|
| Reader hangs forever | armFeed returns while `proc.running` is true, so no new run starts. The watchdog in freshnessTick sets running false once `now - startSec > feedSpecs.timeout` (8 s for the 10 s feeds), sets `killed` and `reason = "timeout"`, and the next tick re-arms. The number is stale for the run, not frozen. The card's premise (blocks forever) does not hold in this worktree; the watchdog was not exercised live. | "hang killed at timeout": killed by SIGKILL on its process group at the job timeout (0.5 s timeout, 502 ms). Snapshot: ok false, error "timeout after 0.5s", payload kept, last_ok_at kept. "loop not blocked by hang or crash": the good job ran 13 times in 3 s. |
| Reader crashes (signal) | onStreamFinished gets empty text, readJson gives null, feedFail "no json". | "crash isolated": ok false, error "signal 9", payload kept. Exit codes give "exit N". |
| Garbage or NaN on stdout | readJson fails, lastFeedError "parse", feedFail. | "junk stdout rejected", "non-finite number rejected": ok false, error "stdout is not one JSON object", payload kept. |

## Decision

Model B.

1. CPU: 0.27% (sample 1) and 0.26% (sample 2) against 1.12% and 1.22% for A on the
   four readers, about 4 to 5 times less. With the live link, 0.86% against 1.71%.
2. Spawns: B forks a warm parent, about 8 ms per run. A starts an interpreter, about
   34 ms per run, 20 times a minute.
3. Failure: a hang, a crash or garbage costs one job one snapshot, and the snapshot
   says so (ok false, error, ran_at, last_ok_at). A's failure is a number that
   goes stale through a watchdog living in the UI process.
4. Freshness: B writes ran_at and ttl_s, so DeckMain judges age on its own 1 Hz clock
   (SHARED3 rule b). That is the freshness contract without a watchdog bolted on.

Costs of B: a resident process to watch (the heartbeat and the fallback rule
cover it); DeckMain reads files (FileView) instead of Process stdout, so the feed
region changes (worker S2 owns it); with Restart=on-failure and RuntimeDirectory,
a restart empties the snapshot folder, and a missing snapshot must count as stale,
not zero.

## How DeckMain consumes B (contract for the feed region)

- Snapshot: `$XDG_RUNTIME_DIR/nexuslink-hud/feeds/<name>.json`. Fields: name, ok,
  ran_at (epoch seconds, run start, wall clock), ttl_s (3 x the job interval),
  duration_ms, payload (the reader's object, generated_at untouched), last_ok_at
  (epoch or null), and error plus stderr_tail when ok is false.
- Freshness, on the 1 Hz clock nowSec: stale when nowSec - ran_at > ttl_s, or when
  payload.generated_at is older than the feed's ttl. Stale shows "--", dims to 0.45
  and shows "STALE Nm". ok false is shown as stale, with the error as the reason.
  Re-judged every second, so a dead supervisor flips the state with no new data.
- Heartbeat: `$XDG_RUNTIME_DIR/nexuslink-hud/feeds/supervisor.json`: pid,
  started_at, beat_at (epoch seconds), heartbeat_s (1.0), jobs, spawns, kills,
  skipped, runs, run_ms. Rewritten at least once a second.
- Fallback rule: when nowSec - beat_at > 3 x heartbeat_s (3 s), the supervisor is
  dead or hung. DeckMain runs the readers itself through the model A Process path
  until beat_at is fresh again. A slow reader does not trip it: the loop never
  waits on a child.

## Files

- nexuslink.hud/v5/feeds/supervisor.py: no waits on children, heartbeat, envelope
  fields, self-check cases by name.
- tools/linux/feed-model-bench.py: fixed exit field (it read null).
- tools/linux/systemd/nexuslink-hud-feeds.service and README.md: unit and install
  and rollback commands.
- tools/linux/FEED-MODEL.md: this file.

Reproduce: `python3 nexuslink.hud/v5/feeds/supervisor.py --self-check`, then
`python3 tools/linux/feed-model-bench.py --model process --seconds 60`,
`... --model supervisor --seconds 60`, `... --model supervisor --optional --seconds 60`.
