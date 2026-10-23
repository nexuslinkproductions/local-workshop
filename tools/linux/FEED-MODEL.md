# Feed process model: decision and measurements

Status: decided. Model B (one supervisor under systemd --user, writing snapshots)
wins. Ready to enable. The parent enables it; nothing here starts, enables or
reloads anything.

Measured 2026-10-23, 13:15 to 13:19 CEST, on the shared Linux box (16 cores,
load average 3.4 to 6.8 during the runs). Raw JSON: scratch
`p-bench/process.json`, `p-bench/supervisor.json`, `p-bench/supervisor-optional.json`.

## Measured table (60 s window per row, same readers, same cadence)

Cadence in both models: sessions, link (fixture), metrics every 10 s; apps and
df every 60 s. Each job runs once at the window start, so the window holds
6 runs of each 10 s job and 1 run of each 60 s job.

| Measure | A: DeckMain Process per reader | B: supervisor, core four | B: supervisor, core four plus 5 optional |
|---|---|---|---|
| CPU seconds in 60 s (children included) | 0.7332 | 0.1539 (supervisor 0.1521 + df 0.0018) | 0.2965 (supervisor 0.2957 + df 0.0008) |
| CPU, percent of one core | 1.222 | 0.256 | 0.494 |
| Same plus live link (58.9 ms x 6 runs = 0.3534 s) | 1.811 | 0.845 | 1.082 |
| Process spawns per minute | 20 (19 readers + df) | 21 (20 readers + df) | 31 (30 readers + df) |
| Peak processes alive at once | 5 | 2 | 2 |
| Memory per process | each python3 reader peaks at 21.8 MB average, 25.9 MB max; 5 can be alive at once | one resident supervisor, peak RSS (VmHWM) 23.8 MB | VmHWM 32.3 MB |
| Threads | n/a (one process per run) | 1 | 1 |
| Average wall per run: sessions / link / metrics / apps | 45.4 / 44.2 / 39.7 / 36.0 ms | 50.6 / 50.7 / 50.9 / 52.1 ms | 50.8 / 51.1 / 50.9 / 51.1 ms |
| Average wall per run: optional jobs | n/a | n/a | callcap 76.2, chief 51.1, game_mode 51.4, level 51.2, recent 52.2 ms |
| Kills, skipped ticks | n/a | 0, 0 | 0, 0 |
| Load average 1 min, start to end | 3.36 to 4.96 | 4.96 to 6.81 | 6.81 to 6.59 |

The optional row is the budget check. Budget for all readers together: 3 percent
of one core. Measured: 0.49 percent for the readers, 1.08 percent with a live
link on top. Inside budget.

Notes on the numbers:
- CPU is process CPU time from the kernel (utime plus stime). Percent is that
  over the 60 s wall. The host is shared, so wall-clock and load noise move the
  per-run wall times, not the CPU totals much.
- Model A's per-run wall is measured with a 5 ms reap loop. Model B reaps in its
  50 ms loop (POLL_S), so its per-run wall carries up to 50 ms of reap latency.
  Its CPU is not affected. Model B's df wall (100 ms) comes from the bench's
  100 ms poll and is not comparable; ignore it.
- Model A is a Python replay of DeckMain's Process pattern. It does not count the
  Quickshell side (Process objects, stdout collection, JSON.parse in QML). So
  model A is an underestimate, and B's advantage is, if anything, understated.
- One 60 s run per model, no repeats. The gap (about 5x on the core four) is far
  larger than the run-to-run noise seen in the load average, but it is one sample.
- The optional jobs were not measured for model A (DeckMain binds only the four).
- link is measured with `--fixture`, as the card asks. The live link line adds
  58.9 ms per run (reports/fb.md, ssh included), computed from the 6 link runs.
- `exit` in the bench JSON reads null. That is a bench bug: os.wait4 reaped the
  supervisor, so Popen.returncode was never set. The supervisor's own exit is
  covered by `--once` and `--self-check`.

## Decision

Model B. Enable the supervisor unit (tools/linux/systemd/README.md), keep model A
as the fallback path inside DeckMain.

Why:
1. CPU: 0.26 percent of one core against 1.22 percent (0.85 against 1.81 with a
   live link). Measured, one run each.
2. Memory: one 24 MB process for the session, against five short-lived python3
   processes at about 22 MB each.
3. Failure: a hang, a crash or garbage stdout costs one job one snapshot, and
   the snapshot says so (ok false, error, ran_at, last_ok_at). Model A freezes
   the number with no flag (see the failure table).
4. Freshness: model B writes ran_at and ttl_s, so DeckMain can judge age on its
   own 1 Hz clock. This is the SHARED3 freshness contract, which model A cannot
   meet without a watchdog bolted on.

What B costs:
- A resident process that must be watched. The heartbeat and the fallback rule
  cover that.
- DeckMain reads files (FileView) instead of Process stdout, so the feed region
  changes (worker S2 owns it).
- With `Restart=on-failure` and `RuntimeDirectory`, a restart empties the
  snapshot directory. Consumers must treat a missing snapshot as stale.

## Failure isolation: what the consumer sees

Model A is read from DeckMain.qml (lines 405 to 418 timers, 292 to 296
sessions, 307 to 310 link, 330 to 333 metrics handlers). Not run live: Quickshell
was not run against any live session, by rule. The Qt behaviour is from the
Process and Timer contract.

| Case | A: DeckMain today | B: supervisor (self-check proves it) |
|---|---|---|
| Hangs forever | The Timer sets `running = true` again. Setting it while the Process runs does nothing, so no new run starts and onStreamFinished never fires. The number freezes with no timeout. | Killed at the job timeout (self-check: "hang killed at timeout", 503 ms for a 0.5 s timeout). Snapshot: ok false, error "timeout after Ns", payload kept, last_ok_at kept. Other jobs keep their cadence ("loop not blocked by hang or crash": good job 13 runs in 3 s). |
| Crashes (signal or exit) | onStreamFinished fires with empty or partial text. readJson returns null, the handler returns. The number freezes, silently. | Recorded: ok false, error "signal 9" (self-check "crash isolated") or "exit N". Payload kept. Other jobs unaffected. |
| Garbage stdout | readJson returns null, the handler returns. The number freezes, silently. | Recorded: ok false, error "stdout is not one JSON object" (self-check "junk stdout rejected"). NaN and Infinity are refused too ("non-finite number rejected"). Payload kept. |

## How DeckMain consumes model B (contract for the feed region)

- Snapshot: `$XDG_RUNTIME_DIR/nexuslink-hud/feeds/<name>.json` for sessions, link,
  metrics, apps (and the optional jobs when enabled). Fields: name, ok, ran_at
  (epoch seconds, run start), ttl_s (3 x the job interval), duration_ms, payload
  (the reader's JSON, its generated_at untouched), last_ok_at (epoch or null),
  and error plus stderr_tail when ok is false.
- Freshness, on the 1 Hz clock nowSec (SHARED3 rule b): the snapshot is stale
  when nowSec - ran_at > ttl_s, or when payload.generated_at is older than the
  feed's ttl. A stale feed shows "--", dims to 0.45 and shows "STALE Nm". ok
  false also shows the stale state, with the error as the reason. Re-evaluated
  every second, so a dead supervisor flips the state with no new data.
- Heartbeat: `$XDG_RUNTIME_DIR/nexuslink-hud/feeds/supervisor.json`, fields pid,
  started_at, beat_at (epoch seconds), heartbeat_s (1.0), jobs, spawns, kills,
  skipped, runs, run_ms. Rewritten about once a second.
- Fallback rule: when nowSec - beat_at is greater than 3 x heartbeat_s (3 s), the
  supervisor is dead or hung. DeckMain then runs the readers itself, through the
  model A Process path, until beat_at is fresh again. A slow reader does not
  trip it: the loop never waits on a child.

## Files

- nexuslink.hud/v5/feeds/supervisor.py: rewritten loop (no waits on children),
  heartbeat, envelope fields, self-check cases by name.
- tools/linux/feed-model-bench.py: fixed; runs both models and the optional row.
- tools/linux/systemd/nexuslink-hud-feeds.service: the unit (verify rc 0).
- tools/linux/systemd/README.md: exact install and rollback for the parent.
- tools/linux/FEED-MODEL.md: this file.

Reproduce: `python3 nexuslink.hud/v5/feeds/supervisor.py --self-check`, then
`python3 tools/linux/feed-model-bench.py --model process --seconds 60`,
`... --model supervisor --seconds 60`, `... --model supervisor --optional --seconds 60`.
