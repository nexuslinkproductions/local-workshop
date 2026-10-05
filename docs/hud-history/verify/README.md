# nexuslink.hud verification harness

`hudcheck.py` decides whether the HUD v4 is done. It runs the P1..P9 done
predicate from `R/PLAN-V4.md` against the live shell, prints one verdict line
per check, and writes all raw values to `verify/out/<timestamp>.json`.
Python 3 stdlib only.

## Usage

```
python3 verify/hudcheck.py [--cpu-seconds N] [--knot-seconds N]
                           [--restart-check] [--shots]
                           [--only P4,P8] [--out PATH]
```

Defaults: `--cpu-seconds 60`, `--knot-seconds 150`, no restart check, no shots,
output `verify/out/<ts>.json`. Run it from anywhere; paths resolve from the
script location.

Exit code 0 only when every executed check is VERIFIED. INCONCLUSIVE also
exits non-zero. Exit code 2 means the run itself failed, for example when the
output file cannot be written.

## Consumed contract

The harness prefers the `selftest` IPC method:

```
omarchy-shell nexuslink.hud selftest
```

It must return JSON in screen pixels:

```
{"screens":[{"screen":"DP-1","w":2560,"h":1440,"procRows":int,
  "reactorCenter":[x,y]|null,"knotCenter":[x,y]|null,
  "knotLit":{"min":0..1,"cur":0..1,"cycles":int}|null,
  "panels":[{"id","x","y","w","h","movable":bool}],
  "topologyNodes":int|null,
  "integrationsLive":[{"id","ok":bool}]}]}
```

v3 has no `selftest` method. Every check that needs it then reads NOT VERIFIED
with the IPC error recorded, and never crashes. P3 and P4 fall back to the
existing `panels` IPC, which reports field fractions fx, fy, fw, fh per
screen. `hyprctl monitors -j` supplies screen pixel sizes for that fallback.
`move` keeps its existing signature: `omarchy-shell nexuslink.hud move <id> <fx> <fy>`.

## Checks

| ID | Rule | Notes |
|---|---|---|
| P1 | procRows >= 3 on DP-1 and HDMI-A-3 | selftest only |
| P2 | reactorCenter and knotCenter within 8 px of (w/2, h/2) on DP-1 | Euclidean distance, selftest only |
| P3 | every panel rect inside its screen | selftest pixels with 1 px slack, else panels fractions fx+fw <= 1 and fy+fh <= 1 |
| P4 | every movable DP-1 panel moves by IPC and returns | see below |
| P5 | min knotLit.min >= 0.45 and cycles increased | samples selftest every 2 s for --knot-seconds |
| P6 | DP-2 topologyNodes == node count in recon/devices-bus.json | INCONCLUSIVE when that file is missing or unreadable |
| P7 | integrationsLive ok count >= 10 | ids deduped across screens |
| P8 | quickshell utime+stime delta <= 15 percent of one core over --cpu-seconds | INCONCLUSIVE when the PID changes mid-sample |
| P9 | journalctl --user _PID=<pid> lines mentioning nexuslink.hud, minus the `Parameter "mouse" is not declared` warnings, count == 0 | uses the P8 PID |

## P4 in detail

Panels come from selftest (`movable: true`) or, in fallback, every DP-1 panel
that is visible and not hidden, because v3 places all panels on the free
canvas. For each panel the harness records its rect, searches a free spot on a
48 px grid at least 96 px away from the original centre, moves the panel
there, re-reads, requires at least 24 px of centre movement, and moves the
panel back. `--restart-check` also runs `omarchy-restart-shell` between the
move and the re-read, so the assertion covers restart survival.

The QML layout resolver may shove neighbours on every drop. The harness
therefore snapshots all DP-1 rects before the first move, repairs drift above
12 px for up to three passes afterwards, and records the final residual.
Moves snap to the 12 px grid, so a restored panel can sit up to 12 px from its
snapshot position. Before the first move the harness copies
`~/.config/omarchy/nexuslink/hud-state.json` to `verify/out/<ts>-hud-state-preP4.json`
as a manual recovery point. IPC `move` resolves shared panel ids like agents
and status to the DP-1 window, which is why only DP-1 panels are moved or
restored.

## Shots

`--shots` screenshots every monitor with grim after the checks. DP-1 is
usually covered by windows, so the harness records its workspace, moves the
cursor to the DP-1 centre, switches to an empty workspace from
`hyprctl workspaces -j`, or to a fresh unused number, else 9, then writes
`verify/out/<ts>-<monitor>.png`, switches back, restores the previously focused
monitor and the cursor position. This hyprctl speaks the Lua dispatcher API
(`hl.dsp.focus`, `hl.dsp.cursor.move`), and the operator shares the desktop, so
every switch and restore is verified and retried, and all attempts are
recorded. Shot failures do not change the exit code; the checks do.

## Artifacts

- `verify/out/<timestamp>.json`: full run record, raw selftest and panels JSON,
  monitors, every check with verdict and measured values, shots, summary.
- `verify/out/<timestamp>-<monitor>.png`: screenshots, one per monitor.
- `verify/out/<timestamp>-hud-state-preP4.json`: layout state backup taken
  before the first P4 move.
- `verify/out/baseline-v3.json`: the v3 baseline captured on 2026-09-28 with
  `python3 verify/hudcheck.py --cpu-seconds 60 --knot-seconds 30`.

## Baseline summary

The v3 baseline expects P3 and P4 to verify through the panels fallback.
P1, P2, P5, P6 and P7 read NOT VERIFIED because v3 lacks selftest. P8
measures the known v3 idle CPU cost. P9 counts the known QML warnings for the
live quickshell PID.
