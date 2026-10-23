# I1 motion evidence — v5 DP-2 deck

Acceptance criterion 3: a numeric trace showing an expand overshoot, a softer
return with none, idle drift that never stops, and a breath period of 5 to 6 s.

Reproduce (about 45 s, no display needed):

```
nexuslink.hud/v5/tools/deck-trace.py
```

The committed traces are in `v5/docs/i1-motion-traces/`
(`expand.json`, `deck.json`); re-parse them with
`deck-trace.py --json v5/docs/i1-motion-traces`.

## Numbers

Five runs of the tool on the same head, all PASS, plus a second five-run pass
during the VI repro. The overshoot is read the clock-free way (next section);
both the frame-sampled and the stretched reads are listed for every run so
nothing is hidden behind a range:

| pass | run | frame samples | frame grid | median frame tick | frame peak (lower bound) | stretched samples | stretched grid | stretched, on the deck's 347 ms timeline | stretched read | closed form |
|---|---|---|---|---|---|---|---|---|---|---|
| A | 1 | 25 | 39.2 ms | 48 ms | +4.857 % | 101 | 38.0 ms | 3.8 ms | **+4.873 %** | **+4.874 %** |
| A | 2 | 21 | 43.8 ms | 61 ms | +4.573 % | 93 | 45.0 ms | 4.5 ms | **+4.873 %** | **+4.874 %** |
| A | 3 | 26 | 35.1 ms | 37 ms | +4.806 % | 94 | 52.0 ms | 5.2 ms | **+4.869 %** | **+4.874 %** |
| A | 4 | 26 | 36.3 ms | 55 ms | +4.344 % | 85 | 53.0 ms | 5.3 ms | **+4.874 %** | **+4.874 %** |
| A | 5 | 23 | 39.5 ms | 55 ms | +4.060 % | 98 | 40.0 ms | 4.0 ms | **+4.871 %** | **+4.874 %** |
| B | 1 | 23 | 40.3 ms | 64 ms | +3.995 % | 106 | 36.0 ms | 3.6 ms | **+4.874 %** | **+4.874 %** |
| B | 2 | 24 | 37.8 ms | 54 ms | +4.439 % | 117 | 26.5 ms | 2.6 ms | **+4.874 %** | **+4.874 %** |
| B | 3 | 26 | 36.4 ms | 59 ms | +4.329 % | 109 | 31.0 ms | 3.1 ms | **+4.873 %** | **+4.874 %** |
| B | 4 | 22 | 42.8 ms | 55 ms | +3.985 % | 110 | 31.0 ms | 3.1 ms | **+4.869 %** | **+4.874 %** |
| B | 5 | 29 | 31.5 ms | 28.5 ms | +4.874 % | 117 | 31.0 ms | 3.1 ms | **+4.869 %** | **+4.874 %** |
| committed `expand.json` | — | 30 | 29.9 ms | 37.5 ms | +4.874 % | 113 | 32.0 ms | 3.2 ms | **+4.874 %** | **+4.874 %** |
| band | — | — | — | — | — | — | — | ≤ 10 ms | 4 to 6 % | 4 to 6 % |

Pass A is the recorded pass; pass B is the one the VI repro ran on this head.
The frame column swings with the frame clock (3.985 to 4.874 % across the passes
above, and the vertex-miss table below says how low it can go for a given frame
gap); the two clock-free reads do not (4.869 to 4.874 %).

The other signals. These are all measured on **frame samples**, so their spread
is the offscreen frame clock's, not the deck's; the numbers below are what seven
recorded passes actually printed, not a tight range:

| signal | measured across passes | band |
|---|---|---|
| expand peak | 1.4194972 at 223 ms, every run (clock-free reads) | — |
| expand/return settle | frame-sampled, so it tracks the offscreen clock rather than the curve; the tool prints it per run and no band applies to it | — |
| return | min 1.0000, 0 rises, last 1.0000 every pass | ≥ 1.0, 0 rises |
| idle drift | max \|d\| 1.890 to 1.891 px, x range 1.65 to 1.85, y range 3.01 to 3.15 | > 0 |
| breath period | 5.74 to 5.85 s (131 to 150 samples at an 88 to 100 ms grid) | 5 to 6 s |
| token | `Motion.expandMillis` 347, `Motion.returnMillis` 444, `Motion.expandOvershoot` 5.00 % (spring band), `Motion.curveOvershoot5` 1.15 (read by `FindField`; `CrewOrb` carries the same 1.15 as a local literal), `Motion.driftAmpMax` 2.0, `Motion.breathPeriod` 5.8 | — |

Reading it:

* **Overshoot** is (peak − target) / travel, with travel = `CrewOrb.expandScale`
  − 1 = 0.4 (growth runs 1.0 → 1.4). The curve the deck runs is OutBack with
  parameter 1.15, whose peak is 1.0487431 of the travel = **4.874 %**, at
  223.3 ms of the 347 ms. Both five-run passes and the committed trace land on
  it.
* **Return** reaches exactly 1.0000, never dips below it (`min` ≥ 1.0) and never
  rises while falling (`rises` = 0 in every pass): monotone, no overshoot. Its
  token is the slower one (`Motion.returnMillis` 444 against the expand's 347);
  the frame-sampled settle times of the two legs are clock-bound and are not
  used as evidence of any ordering.
* **Idle drift** peaks at 1.890 px on `Motion.driftAmpMax` = 2.0 every pass, with
  an x range of 1.65 to 1.85 px and a y range of 3.01 to 3.15 px: two sine terms
  at period and period × phi, so the deck is never fully still and never
  repeats. A second `IdleDrift` moves the launcher and find pill on its own
  phase (`phaseOffset` 0.37, `Motion.driftAmpMin`, period × phi), so the chrome
  and the widget band never move in step. The 96 px clock is the one fixed
  element: a 2 px wobble on type that large reads as broken typography, not as
  life.
* **Breath** measured 5.74 to 5.85 s across passes against `Motion.breathPeriod`
  = 5.8 s, by timing the mid-level crossings across two full cycles. The shell
  renders it in the swarm shader at a 30 Hz tick, not in a wrapper animation.

## Why the peak is not read off the frame samples

The offscreen `qml` runtime on this Mac advances animations at whatever rate its
render loop manages, and this kit's frames are expensive. Measured on the expand
probe (`CrewOrb` at 224 px with its sub-swarms painted), consecutive distinct
`growth` values arrive **26 to 100 ms** apart, and the timer that samples them
fires twice inside one frame. A 347 ms curve whose vertex is ~10 ms wide cannot
be resolved by a clock that coarse: what matters is not how many samples a run
took but how far the nearest animation frame lands from the vertex.

Offsets along this curve, from the closed form (percent of travel lost):

| nearest frame to the vertex | overshoot read |
|---|---|
| 0 ms | 4.874 % |
| 5 ms | 4.851 % |
| 10 ms | 4.784 % |
| 12.5 ms | 4.735 % |
| 25 ms | 4.358 % |
| 35 ms | **3.925 %** |
| 50 ms | 3.130 % |

That table is the whole story of the earlier readings: frame-only captures of
this same curve gave 4.48, 3.89, 4.51, 4.68 and 4.79 % while the curve itself did
not change. 3.89 % is one frame landing 35 ms off the vertex — a correct sample
of the wrong instant. More samples did not fix it (the first 4.48 % run had 48,
53 and 62 samples per attempt) and more samples cannot fix it: at a 50 ms frame
clock, every sample is 0 to 25 ms off, and the read is whatever that frame
happened to catch.

So the probe measures the same curve three ways (`tests/i1/CrewExpandTrace.qml`):

| read | how | why it is trustworthy |
|---|---|---|
| frame | the real `CrewOrb`, deck size (224), deck tokens, sampled on the probe's 4 ms timer | it is the deck's own component running; used as a **lower bound** in both directions — no frame sample may sit above the curve's maximum, and the run fails if the frame peak falls further below it than the measured frame gap can explain |
| stretched | the same easing, read off the live object that moves the orb (`CrewOrb.transitions[0].animations[0]`: duration, easing type and the OutBack parameter come from there, `stretchSetup.ok` in the trace proves the copy carries them), re-run on the probe's own property over 10 × the duration | an easing curve's peak **value** does not depend on its duration: stretching multiplies every sample time and leaves every value alone, so a ~45 ms frame becomes a 4.5 ms step on the deck's own 347 ms timeline |
| closed form | the same parameters evaluated in 0.05 ms steps: `value(t) = 1 + (c+1)(t−1)³ + c(t−1)²`, `c` = the easing overshoot read off the live transition | no clock in it at all; this is the number the 4 to 6 % band is checked against, and the probe's own sweep and the tool's independent evaluation have to agree to 1e-6 |

All three agree: the frame samples never exceed the curve maximum and land 0.0 to
0.9 points below it depending on where the frame clock happens to tick (the
vertex-miss table above explains every one of them), the stretched read is within
0.005 points of the closed form in every run recorded so far, and the closed form
is 4.874 % — 0.87 points above the 4 % floor of the band and 1.13 below its
ceiling.

## Where each number is measured, and why there

Two probes, because the two signals need very different sampling:

| probe | measures | reason |
|---|---|---|
| `tests/i1/CrewExpandTrace.qml` | expand + return, three ways (frame, stretched, closed form) | The same `CrewOrb`, at the deck's size (224) and with the deck's `Motion` tokens, plus the live transition's own parameters stretched and evaluated so the vertex stops depending on the frame clock |
| `tests/i1/DeckTrace.qml` | idle drift + breath on the composed deck | 5.8 s and 13 s periods do not care about a ~90 ms grid |

The expand was first measured on the full deck and that was **not good enough to
report**: the deck's binding churn during a state change starves the offscreen
sampler to ~100 ms. The component-scale probe is faster (25 to 100 ms frames)
but not fast enough for a ~10 ms vertex, which is why the reported number no
longer comes from frame samples at all. The deck is still the thing measured for
drift and breath, and the expand probe instantiates the deck's own component, at
the deck's own size, reading the deck's own tokens and the live transition's own
easing — so the number is the deck's transition, measured where it can be
measured honestly.

## Where each number comes from

| number | owner | read by the deck as |
|---|---|---|
| expand spring 0.69 / 16.7 rad/s | `Motion.expandZeta/expandOmega` | `LocalOrb` and the gauges' focus spring |
| 4.874 % OutBack peak, 347 ms | the `1.15` literal at `kit/CrewOrb.qml:426` (also `:524`, `:531`, `:539`) and `Motion.expandMillis` | `CrewOrb.transitions[0]`, which the probe reads live. `Motion.curveOvershoot5` carries the same 1.15 but only `FindField` reads it; `CrewOrb`'s own literal is still a local constant, an open token request in W2's file |
| return 1.0 / 9.0, no overshoot, 444 ms | `Motion.returnZeta/returnOmega`, `Motion.returnMillis` | `CrewOrb`, gauges |
| breath 5.8 s, 40 / 60 | `Motion.breathPeriod/breathInhale/breathExhale` | `Swarm`, `SwarmSphere` shader uniforms |
| drift 2.0 px, 13 s | `Motion.driftAmpMax`, `Motion.driftPeriodMax` | `IdleDrift` on the band group and the chrome group |

Nothing on the deck is linear: every transition above is a spring or an
`Easing.OutBack`/`OutCubic` pair, and Qt 6.12's 4-value `bezierCurve` (which
evaluates as linear) is not used anywhere — `Motion.curveInOut6` is the six-value
form the gauges read.
