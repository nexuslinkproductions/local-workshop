# I1 motion evidence — v5 DP-2 deck

Acceptance criterion 3: a numeric trace showing an expand overshoot, a softer
return with none, idle drift that never stops, and a breath period of 5 to 6 s.

Reproduce (about 40 s per run, no display needed):

```
nexuslink.hud/v5/tools/deck-trace.py
```

The committed traces are in `v5/docs/i1-motion-traces/`
(`expand.json`, `deck.json`); re-parse them with
`deck-trace.py --json v5/docs/i1-motion-traces`.

## What the exit status is, and what it is not

`deck-trace.py` exits on the **closed form**: the OutBack curve the deck actually
runs, read live off `CrewOrb.transitions[0].animations[0]` (easing type, parameter
and duration all come from the running object), evaluated analytically. Nothing
in that path reads a clock.

The frame-sampled peak and the stretched read stay in the output as **evidence**,
never as the verdict. The offscreen frame clock on this Mac ticks every 25 to
100 ms. A 347 ms curve peaks ~10 ms wide, so a frame sample can land 25 to 50 ms
off the vertex and read 0.5 to 1.0 points low through no fault of the deck. The
tool therefore reports the frame column as a two-sided bound — highest sample,
to highest sample plus what half the largest frame gap can cost at that vertex —
with its sample count and grid, and prints whether the closed form falls inside
it. Round 2 of this PR failed twice on that column while the curve was unchanged
(`+3.707 %` against a `+3.851 %` floor, `+3.784 %` against `+3.899 %`); the gate
now cannot fail that way, and a curve that really moved is still caught, because
the closed form is built from the live easing object.

## Numbers

Five consecutive runs on this head (PR #52, `v5/integrator`), **all exit 0**.
Each run is five independent expand attempts, so the five rows below are 25
attempts:

| run | closed form, all 5 attempts | frame lower bound, 5 attempts | frame samples per attempt | frame grid | exit |
|---|---|---|---|---|---|
| 1 | +4.874 % | +4.542 to +4.844 % | 19 to 33 | 28.0 to 48.7 ms | 0 |
| 2 | +4.874 % | +3.927 to +4.874 % | 22 to 34 | 27.7 to 40.0 ms | 0 |
| 3 | +4.874 % | +4.249 to +4.871 % | 22 to 27 | 34.1 to 42.9 ms | 0 |
| 4 | +4.874 % | +3.889 to +4.805 % | 19 to 27 | 33.3 to 47.1 ms | 0 |
| 5 | +4.874 % | +3.585 to +4.873 % | 21 to 28 | 33.1 to 44.1 ms | 0 |

Every attempt in every run read the same closed form, `+4.874 %`, and every
closed form fell inside its own frame bound (`5 of 5` in each run). Three frame
lower bounds sit under the 4 % floor of the band (3.585, 3.889, 3.927) — those are
the readings the round-2 verifier saw as failures.

The other signals, from the same five runs:

| signal | measured across the five runs | band |
|---|---|---|
| expand peak | 1.4194972 at 223 ms (closed form, every attempt) | — |
| stretched read | +4.868 to +4.874 % (82 to 112 samples, 31.0 to 58.5 ms grid = 3.1 to 5.8 ms on the deck's 347 ms timeline) | 4 to 6 % |
| return | min 1.0000, 0 rises, last 1.0000 in every run | ≥ 1.0, 0 rises |
| idle drift | max \|d\| 1.890 to 1.891 px, x range 1.679 to 1.794, y range 3.038 to 3.135 | > 0 |
| breath period | 5.776 to 5.823 s (119 to 127 samples at a 102.6 to 110.1 ms grid) | 5 to 6 s |
| committed traces | `expand.json` and `deck.json` regenerated from the current probes, re-parsed with `--json`, exit 0 | — |
| token | `Motion.expandMillis` 347, `Motion.returnMillis` 444, `Motion.expandOvershoot` 5.00 % (spring band), `Motion.curveOvershoot5` 1.15 (read by `FindField`; `CrewOrb` carries the same 1.15 as a local literal), `Motion.driftAmpMax` 2.0, `Motion.breathPeriod` 5.8 | — |

Reading it:

* **Overshoot** is (peak − target) / travel, with travel = `CrewOrb.expandScale`
  − 1 = 0.4 (growth runs 1.0 → 1.4). The curve the deck runs is OutBack with
  parameter 1.15, whose peak is 1.0487431 of the travel = **4.874 %**, at
  223.3 ms of the 347 ms. Every one of the 25 attempts lands on it.
* **Return** reaches exactly 1.0000, never dips below it (`min` ≥ 1.0) and never
  rises while falling (`rises` = 0 in every run): monotone, no overshoot. Its
  token is the slower one (`Motion.returnMillis` 444 against the expand's 347);
  the frame-sampled settle times of the two legs are clock-bound and are not
  used as evidence of any ordering.
* **Idle drift** peaks at 1.890 to 1.891 px on `Motion.driftAmpMax` = 2.0 every
  run, with an x range of 1.679 to 1.794 px and a y range of 3.038 to 3.135 px:
  two sine terms at period and period × phi, so the deck is never fully still and
  never repeats. A second `IdleDrift` moves the launcher and find pill on its own
  phase (`phaseOffset` 0.37, `Motion.driftAmpMin`, period × phi), so the chrome
  and the widget band never move in step. The 96 px clock is the one fixed
  element: a 2 px wobble on type that large reads as broken typography, not as
  life.
* **Breath** measured 5.776 to 5.823 s across the five runs against
  `Motion.breathPeriod` = 5.8 s, by timing the mid-level crossings across two
  full cycles. The shell renders it in the swarm shader at a 30 Hz tick, not in a
  wrapper animation.

## Why the peak is not read off the frame samples

The offscreen `qml` runtime on this Mac advances animations at whatever rate its
render loop manages, and this kit's frames are expensive. Measured on the expand
probe (`CrewOrb` at 224 px with its sub-swarms painted), consecutive distinct
`growth` values arrive **26 to 133 ms** apart, and the timer that samples them
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

That table is the whole story of the frame column: frame-only captures of this
same curve gave 4.48, 3.89, 4.51, 4.68 and 4.79 % in round 1, 3.585 to 4.874 % in
the five runs above, while the curve itself did not change. A 3.585 % reading is
one frame landing ~40 ms off the vertex — a correct sample of the wrong instant.
More samples did not fix it (the 4.48 % run had 48, 53 and 62 samples per attempt
in round 1) and more samples cannot fix it: at a 50 ms frame clock, every sample
is 0 to 25 ms off, and the read is whatever that frame happened to catch. That is
why the column is a bound now.

So the probe measures the same curve three ways (`tests/i1/CrewExpandTrace.qml`):

| read | how | why it is trustworthy |
|---|---|---|
| frame | the real `CrewOrb`, deck size (224), deck tokens, sampled on the probe's 4 ms timer | it is the deck's own component running; reported as a **two-sided bound** — the peak is at least the highest sample and at most that sample plus the vertex-miss allowance the measured frame gap implies, and the report says whether the closed form falls inside |
| stretched | the same easing, read off the live object that moves the orb (`CrewOrb.transitions[0].animations[0]`: duration, easing type and the OutBack parameter come from there, `stretchSetup.ok` in the trace proves the copy carries them), re-run on the probe's own property over 10 × the duration | an easing curve's peak **value** does not depend on its duration: stretching multiplies every sample time and leaves every value alone, so a ~45 ms frame becomes a 4.5 ms step on the deck's own 347 ms timeline. Reported as evidence, not gated: the same clock still samples it |
| closed form | the same parameters evaluated in 0.05 ms steps: `value(t) = 1 + (c+1)(t−1)³ + c(t−1)²`, `c` = the easing overshoot read off the live transition | no clock in it at all; **this is the number the 4 to 6 % band is checked against**, and the probe's own sweep and the tool's independent evaluation have to agree to 1e-6 or the run fails |

## Where each number is measured, and why there

Two probes, because the two signals need very different sampling:

| probe | measures | reason |
|---|---|---|
| `tests/i1/CrewExpandTrace.qml` | expand + return, three ways (frame, stretched, closed form) | The same `CrewOrb`, at the deck's size (224) and with the deck's `Motion` tokens, plus the live transition's own parameters stretched and evaluated so the vertex stops depending on the frame clock |
| `tests/i1/DeckTrace.qml` | idle drift + breath on the composed deck | 5.8 s and 13 s periods do not care about a ~100 ms grid |

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
