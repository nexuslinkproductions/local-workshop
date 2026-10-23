# I1 motion evidence — v5 DP-2 deck

Acceptance criterion 3: a numeric trace showing an expand overshoot, a softer
return with none, idle drift that never stops, and a breath period of 5 to 6 s.
All four are measured on the composed deck, not on a component in isolation.

Reproduce (13 s, no display needed):

```
nexuslink.hud/v5/tools/deck-trace.py
```

The probe (`v5/tests/i1/DeckTrace.qml`) samples `DeckSurface.crewGrowth`,
`DeckSurface.idleDriftX/Y` and a `SwarmSphere.breath` at an 8 ms target, flipping
`focusId` to `crew` at t = 1200 ms and back to `""` at t = 3200 ms. The parser
prints the four numbers and exits non-zero if any of them leaves its band. The
raw trace of the run quoted below is committed as
`v5/docs/i1-motion-trace.json` (22 KB); re-parse it with
`deck-trace.py --json v5/docs/i1-motion-trace.json`.

## Numbers, three consecutive runs

| run | expand peak | overshoot | expand settle | return min | return rises | return settle | drift max | breath period |
|---|---|---|---|---|---|---|---|---|
| 1 | 1.4195 | **+4.87 %** | 348 ms | 1.0000 | 0 | 409 ms | 1.891 px | **5.839 s** |
| 2 | 1.4192 | **+4.79 %** | 293 ms | 1.0000 | 0 | 337 ms | 1.891 px | **5.825 s** |
| 3 | 1.4178 | **+4.44 %** | 255 ms | 1.0000 | 0 | 386 ms | 1.891 px | **5.808 s** |
| band | — | 4 to 6 % | — | ≥ 1.0 | 0 | — | > 0 | 5 to 6 s |
| token | — | `Motion.expandOvershoot` 5.00 % | `Motion.expandMillis` 347 | — | — | `Motion.returnMillis` 444 | `Motion.driftAmpMax` 2.0 | `Motion.breathPeriod` 5.8 |

Reading the table:

* **Overshoot** is (peak − target) / travel, with travel = `CrewOrb.expandScale`
  − 1 = 0.4 (growth runs 1.0 → 1.4). So 1.4195 is 4.87 % over the target and the
  three runs sit at 4.4 to 4.9 %, inside the approved 4 to 6 % band. The spread
  across runs is sampling, not motion: the probe catches the peak on a ~20 to
  40 ms grid, and the analytic token value is 5.00 % (`zeta` 0.69, `omega` 16.7).
  W2 measured 4.85 % on the same component in isolation, which brackets these.
* **Return** reaches exactly 1.0000, never dips below it (`min` ≥ 1.0) and never
  rises on the way down (`rises` = 0 in all three runs): monotone, no overshoot.
  It is also slower than the expand on the token pair (444 ms against 347 ms).
* **Idle drift** peaks at 1.891 px on `Motion.driftAmpMax` = 2.0, with an x range
  of ~1.71 px and a y range of ~3.1 px over the capture: two sine terms at
  period and period × phi, so the deck is never fully still and never repeats.
  A second `IdleDrift` instance moves the launcher and find pill on its own phase
  (`phaseOffset` 0.37, `Motion.driftAmpMin`, period × phi), so the chrome and the
  widget band never move in step. The 96 px clock is the one fixed element: a
  2 px wobble on type that large reads as broken typography, not as life.
* **Breath** measured 5.839 / 5.825 / 5.808 s against `Motion.breathPeriod` =
  5.8 s, i.e. mid-level crossings timed across two full cycles. The shell
  renders it in the swarm shader at a 30 Hz tick, not in a wrapper animation.

## Why the sample grid is honest

The first version of the probe rendered the deck at full size and lost samples to
a 60 ms timer grid, measuring 3.63 % overshoot on one run — under the band, and a
sampling artefact rather than the motion. The probe now renders the deck at a
quarter scale and with the surface unpainted (`visible: false`): Qt's animation
driver still ticks every frame for an invisible item, so the sampler gets a ~20
to 40 ms grid and the same motion measures 4.4 to 4.9 % every time. The sampling
limitation is stated rather than smoothed over; the analytic token that both the
component and the deck read is 5.00 %.

## Where each number comes from

| number | owner | read by the deck as |
|---|---|---|
| expand spring 0.69 / 16.7 rad/s | `Motion.expandZeta/expandOmega` | `CrewOrb` transition |
| 5.00 % overshoot, 347 ms | `Motion.expandOvershoot`, `Motion.expandMillis` | `CrewOrb`, `Focus`, `FindField` |
| return 1.0 / 9.0, no overshoot, 444 ms | `Motion.returnZeta/returnOmega`, `Motion.returnMillis` | `CrewOrb`, gauges |
| breath 5.8 s, 40 / 60 | `Motion.breathPeriod/breathInhale/breathExhale` | `Swarm`, `SwarmSphere` shader uniforms |
| drift 2.0 px, 13 s | `Motion.driftAmpMax`, `Motion.driftPeriodMax` | `IdleDrift` on the band group |

Nothing on the deck is linear: every transition above is a spring or an
`Easing.OutBack`/`OutCubic` pair, and Qt 6.12's 4-value `bezierCurve` (which
evaluates as linear) is not used anywhere — `Motion.curveInOut6` is the six-value
form the gauges read.
