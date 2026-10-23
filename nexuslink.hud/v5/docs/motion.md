# I1 motion evidence — v5 DP-2 deck

Acceptance criterion 3: a numeric trace showing an expand overshoot, a softer
return with none, idle drift that never stops, and a breath period of 5 to 6 s.

Reproduce (about 15 s, no display needed):

```
nexuslink.hud/v5/tools/deck-trace.py
```

The committed traces are in `v5/docs/i1-motion-traces/`
(`expand.json`, `deck.json`); re-parse them with
`deck-trace.py --json v5/docs/i1-motion-traces`.

## Numbers

Four passes of the tool, all PASS:

| pass | expand peak | overshoot | expand settle | return min | return rises | drift max | breath period |
|---|---|---|---|---|---|---|---|
| committed trace | 1.4190 | **+4.75 %** | 265 ms | 1.0000 | 0 | 1.891 px | **5.771 s** |
| 2 | 1.4179 | **+4.48 %** | 248 ms | 1.0000 | 0 | 1.890 px | 5.783 s |
| 3 | 1.4178 | **+4.44 %** | 276 ms | 1.0000 | 0 | 1.891 px | 5.843 s |
| 4 | 1.4190 | **+4.75 %** | 268 ms | 1.0000 | 0 | 1.891 px | 5.800 s |
| band | — | 4 to 6 % | — | ≥ 1.0 | 0 | > 0 | 5 to 6 s |
| token | — | `Motion.expandOvershoot` 4.87 % (OutBack 1.15) / 5.00 % (zeta 0.69, omega 16.7) | `Motion.expandMillis` 347 | — | — | `Motion.driftAmpMax` 2.0 | `Motion.breathPeriod` 5.8 |

Reading it:

* **Overshoot** is (peak − target) / travel, with travel = `CrewOrb.expandScale`
  − 1 = 0.4 (growth runs 1.0 → 1.4). Four passes give 4.44 to 4.75 %, inside the
  approved 4 to 6 % band. The peak lands at 168 to 226 ms, which is where the
  curve's vertex is.
* **Return** reaches exactly 1.0000, never dips below it (`min` ≥ 1.0) and never
  rises while falling (`rises` = 0 in every pass): monotone, no overshoot. It
  also settles slower than the expand from the same starting point, on the
  longer token (`Motion.returnMillis` 444 against 347).
* **Idle drift** peaks at 1.891 px on `Motion.driftAmpMax` = 2.0 every pass, with
  an x range of ~1.8 px and a y range of ~3.1 px: two sine terms at period and
  period × phi, so the deck is never fully still and never repeats. A second
  `IdleDrift` moves the launcher and find pill on its own phase (`phaseOffset`
  0.37, `Motion.driftAmpMin`, period × phi), so the chrome and the widget band
  never move in step. The 96 px clock is the one fixed element: a 2 px wobble on
  type that large reads as broken typography, not as life.
* **Breath** measured 5.771 to 5.843 s against `Motion.breathPeriod` = 5.8 s, by
  timing the mid-level crossings across two full cycles. The shell renders it in
  the swarm shader at a 30 Hz tick, not in a wrapper animation.

## Where each number is measured, and why there

Two probes, because the two signals need very different sampling:

| probe | measures | reason |
|---|---|---|
| `tests/i1/CrewExpandTrace.qml` | expand + return | The same `CrewOrb`, at the deck's size (224) and with the deck's `Motion` tokens, in a scene small enough to sample every ~30 ms |
| `tests/i1/DeckTrace.qml` | idle drift + breath on the composed deck | 5.8 s and 13 s periods do not care about a ~90 ms grid |

The expand was first measured on the full deck and that was **not good enough to
report**: the deck's binding churn during a state change starves the offscreen
sampler to ~100 ms, while the expand peak is one instant ~180 ms into a 347 ms
curve, so detected peaks scattered from 1.2 to 4.9 % on the same curve — a
sampling artefact, not motion. The offscreen `qml` tool's best grid on this Mac is
25 ms (measured: 40 ticks/s on an empty scene), which the component-scale probe
achieves (29 to 37 ms in practice). The deck is still the thing measured for
drift and breath, and the expand probe instantiates the deck's own component, at
the deck's own size, reading the deck's own tokens — so the number is the deck's
transition, measured where it can be measured honestly.

## Where each number comes from

| number | owner | read by the deck as |
|---|---|---|
| expand spring 0.69 / 16.7 rad/s | `Motion.expandZeta/expandOmega` | `CrewOrb` transition |
| 4.87 % OutBack peak, 347 ms | `Motion.curveOvershoot5`, `Motion.expandMillis` | `CrewOrb`, `Focus`, `FindField` |
| return 1.0 / 9.0, no overshoot, 444 ms | `Motion.returnZeta/returnOmega`, `Motion.returnMillis` | `CrewOrb`, gauges |
| breath 5.8 s, 40 / 60 | `Motion.breathPeriod/breathInhale/breathExhale` | `Swarm`, `SwarmSphere` shader uniforms |
| drift 2.0 px, 13 s | `Motion.driftAmpMax`, `Motion.driftPeriodMax` | `IdleDrift` on the band group and the chrome group |

Nothing on the deck is linear: every transition above is a spring or an
`Easing.OutBack`/`OutCubic` pair, and Qt 6.12's 4-value `bezierCurve` (which
evaluates as linear) is not used anywhere — `Motion.curveInOut6` is the six-value
form the gauges read.
