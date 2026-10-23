# W3/W4 gauges: the spring pair, repaired and measured

Repair card: `t_34fe7635` (HUD v5 W3/W4 REPAIR), raised by shino from
`t_8c9850c9` (LocalOrb, PR #55). Scope: `kit/PulseRing.qml`, `kit/DotArc.qml`,
`kit/DotBar.qml`, `kit/IconTile.qml`. No other component file is touched.

## The defect, measured

All four gauges drove their focus / selection animation with the analytic spring
pair, converted from `Motion` at mass 1:

```qml
readonly property real springStiffness: Motion.expandOmega * Motion.expandOmega   // 278.89
readonly property real springDamping: 2 * Motion.expandZeta * Motion.expandOmega  // 23.05
...
Behavior on scale { SpringAnimation { spring: root.springStiffness
                                      damping: root.springDamping
                                      mass: 1.0 } }
```

`DotBar.qml` had the same pair inline at 91-92, `IconTile.qml` had it twice
(`returnOmega` for the dim, expand/return picked by `selected` for the scale).

The numbers are the correct analytic pair for Motion's 0.69 / 16.7 expand
spring, but Qt 6.12's `SpringAnimation` does not evaluate that pair: it applies
the spring term without a `dt` factor and clamps `damping` to `[0, 1]`, so
`damping 23.05` collapses to `1.0` and the response is a barely damped explicit
Euler spring. Same root cause shino established on LocalOrb in `t_8c9850c9`.
The result is not a 5.00 percent overshoot on a 347 ms curve: it is a divergence
on the very first change of the input, with no late frame required.

Every run below is `tests/w3/GaugeSpringTrace.qml` at the deck's own sizes
(PulseRing 156 px, DotArc 216 px, DotBar 132 px / 12 segments, IconTile 96 px),
driving `focusLevel` 0 -> 1 (the tile's `selected` for its scale, `focusLevel`
for its dim) and reading the component's own animated value. Raw TRACE lines:
`v5/docs/w3-gauges-traces/before/` and `.../after/`.

`PulseRing`, expand, first samples after the trigger at 215 ms:

| t (ms) | art scale, before the repair |
|---|---|
| 215 | 1.000000 |
| 260 | 0.560516 |
| 288 | -4.707628 |
| 297 | 20.939668 |
| 346 | -824.840758 |
| 376 | -9898.880042 |
| 457 | 4925129.186047 |
| 664 | -50589541012002.11 |

All twelve scale runs (four components x expand / expand with a 150 ms stalled
frame / return) leave the scale range, `max|v|`:

| component | expand | expand, 150 ms stall | return |
|---|---|---|---|
| PulseRing | 1.36e+40 | 4.57e+33 | 4.96e+54 |
| DotArc | 1.13e+39 | 1.58e+34 | 2.06e+56 |
| DotBar | 1.13e+39 | 1.58e+34 | 4.96e+54 |
| IconTile (scale) | 1.70e+39 | 2.85e+35 | 8.91e+55 |

IconTile's dim channel is the exception, and it fails differently: `returnOmega`
9 gives a spring of 81 with damping clamped to 18 -> 1, which does not blow up
but runs far too fast. The 0.70 fade is already at 0.300041 (the floor) at the
first sample after its trigger, 133 ms later, where the 444 ms reference curve
is still at 0.5406; scored against that reference the run deviates by 23.75
percent of the travel. The traces in `before/` carry the same numbers: `23.75`,
`40.23` and `31.16` percent for dim expand, dim expand with the stall and dim
return.

## The repair

The wave's measured pattern, with the direction split the card asks for:

```qml
readonly property real expandBackOvershoot: 1.15       // OutBack parameter, peak 1.04871
readonly property real targetScale: <the resting geometry> * (1 + focusLift * focusAmount)
property real artScale: 1.0                            // what the art is drawn at
property bool motionReady: false

Component.onCompleted: { root.artScale = root.targetScale; root.motionReady = true }

onTargetScaleChanged: { if (!motionReady) return; ... grow or settle to targetScale ... }

NumberAnimation { id: grow;   property: "artScale"; duration: Motion.expandMillis
                  easing.type: Easing.OutBack; easing.overshoot: root.expandBackOvershoot }
NumberAnimation { id: settle; property: "artScale"; duration: Motion.returnMillis
                  easing.type: Easing.OutCubic }
```

- `Easing.OutBack` at overshoot parameter 1.15 peaks at 1.04871, i.e. **4.87
  percent**, the curve `CrewOrb`, `FindField`, `LauncherArc` and now `LocalOrb`
  already ship. `Motion.expandOvershoot` (0.05) is the target, not the parameter;
  `Motion.qml` has no OutBack parameter yet, so it stays a local `readonly` with
  that comment in all five components, and the token
  (`Motion.expandBackOvershoot: 1.15`) is requested in the PR body.
- Expand runs on `Motion.expandMillis` (347 ms), return on `Motion.returnMillis`
  (444 ms) with `OutCubic`: monotone, no overshoot, slower than the expand,
  exactly what `Motion.returnZeta: 1.0` states.
- Two animations rather than one `Behavior`: a Behavior can hold only one
  animation, so it would have to use the expand curve on the way down too, and
  `Motion.returnOvershoot` is 0. `onTargetScaleChanged` picks by comparing the
  new target with the value on screen, correct mid-flight too.
- `IconTile`'s dim is a fade, not a lift: it takes the return curve
  (`OutCubic` over `Motion.returnMillis`) in both directions, because
  overshooting a dim would light the tile past full strength or push it below
  `Tokens.focusDimMax` (0.30). Its `selected` scale is a lift and gets the
  OutBack expand and the OutCubic return.
- Property names: `artScale` (PulseRing, DotArc), `barScale` (DotBar),
  `tileScale` / `tileOpacity` (IconTile). `targetScale` is published on the
  three gauges, `targetOpacity` / `restScale` on the tile, so the probe and the
  deck audit score against the component's own number instead of a copy.

### The startup artifact this repair had to avoid

`Component.onCompleted` snaps the animated value to its target, because at
creation a binding goes from its declared default to the real value and without
a guard the first frames animate in from the wrong place. The deck composes
`DotArc` at 144 px (`referenceSize` 216), so the art belongs at 0.666667 - and
the first version of this repair drew it at **0.691172** at 120 ms: a 444 ms
settle from 1.0 fired before `onCompleted` and kept writing after the snap. The
`motionReady` flag (set at the end of `onCompleted`, checked in the change
handler) removes it. `tools/w3-gauge-deck-audit.py` checks every gauge in every
deep view against its own target for exactly this reason, and the deck stills
below are pixel-identical to the base commit.

## After: every run in band

`v5/tools/w3-gauge-spring-trace.py` (exit 0) at an 8 ms closed-form grid plus a
measured column at the runtime's 20 to 150 ms grid, and the agreement between
the two:

| component | channel | expand peak (closed) | measured peak | return | 150 ms stall | agreement (expand / return / stall) |
|---|---|---|---|---|---|---|
| PulseRing | scale | 1.041950 = 4.87 % | 1.041683 | 1.040000 -> 1.000000, 0.00 % past | 1.041695 | 0.50 / 0.45 / 1.18 % |
| DotArc | scale | 1.041950 = 4.87 % | 1.041883 | 1.040000 -> 1.000000, 0.00 % past | 1.041950 | 0.32 / 0.31 / 0.00 % |
| DotBar | scale | 1.041950 = 4.87 % | 1.041949 | 1.040000 -> 1.000000, 0.00 % past | 1.041922 | 0.05 / 0.49 / 0.00 % |
| IconTile | scale | 1.062924 = 4.87 % | 1.062925 | 1.060000 -> 1.000000, 0.00 % past | 1.062883 | 0.05 / 0.49 / 0.00 % |
| IconTile | dim | 0.300000 (fade) | 0.300000 | 0.300000 -> 1.000000, 0.00 % past | 0.300000 | 0.31 / 0.26 / 0.49 % |

The agreement column is the measured samples scored against the closed form at
the same timestamps over the best-fit phase offset (max deviation as a share of
the travel), which is what ties the runtime to the curve: the measured column on
its own cannot read a 4.87 percent peak off a 30 ms grid, and a green closed form
could otherwise hide a component animating something else.

Closed form of the shipped expand curve, exactly what
`QEasingCurve::easeOutBack` evaluates for `NumberAnimation`, at the card's 8 ms
grid, as a share of the travel (the same percentages for all four lifts: 4
percent for the three gauges, 6 percent for the tile):

| t ms | scale at 4 % travel | of the lift |
|---|---|---|
| 0 | 1.000000 | 0.00 % |
| 8 | 1.003715 | 9.29 % |
| 24 | 1.010496 | 26.24 % |
| 40 | 1.016450 | 41.13 % |
| 56 | 1.021630 | 54.07 % |
| 72 | 1.026085 | 65.21 % |
| 88 | 1.029866 | 74.67 % |
| 104 | 1.033024 | 82.56 % |
| 120 | 1.035610 | 89.02 % |
| 136 | 1.037673 | 94.18 % |
| 152 | 1.039265 | 98.16 % |
| 168 | 1.040436 | 101.09 % |
| 184 | 1.041236 | 103.09 % |
| 200 | 1.041717 | 104.29 % |
| 216 | 1.041929 | 104.82 % |
| **224** | **1.041950** | **104.87 %** (peak) |
| 240 | 1.041852 | 104.63 % |
| 256 | 1.041613 | 104.03 % |
| 272 | 1.041281 | 103.20 % |
| 288 | 1.040907 | 102.27 % |
| 304 | 1.040543 | 101.36 % |
| 320 | 1.040238 | 100.59 % |
| 336 | 1.040043 | 100.11 % |
| 347 | 1.040000 | 100.00 % |

Peak overshoot **4.87 percent** at 224 ms, inside the 4 to 6 band, settled to
within 2 percent of the lift at 288 ms, exact at 347 ms.

## Stalled frame

The same expand with the event loop blocked for 150 ms at the trigger: peak
bounded by 1.041950 (`PulseRing` measured 1.041695, `DotArc` 1.041950, `DotBar`
1.041922, `IconTile` 1.062883), and the measured samples fit the closed form at
a **+150 ms phase offset** within 1.18 percent of the travel. That offset is the
mechanism, not noise: the animation driver advances by elapsed wall time on its
next tick, so a 150 ms stall shows the curve 150 ms further along. A time-based
curve can *skip* the peak that way but cannot exceed it, because the value is
`start + travel * ease(t / duration)` with `ease` bounded in `[0, 1.04871]` for
the whole duration. There is no integrator state to blow up: the before numbers
in the same run were 4.57e+33 (PulseRing), 1.58e+34 (DotArc, DotBar) and 2.85e+35
(IconTile).

## The deck, re-rendered

The deck composes PulseRing and DotArc in the `mac` deep view, DotBar and DotArc
in `storage`, and nothing in this set in `launcher` (the launcher draws
`LauncherArc`). All four gauges get `focusLevel: 0` there, so these stills are
the at-rest regression check: the motion repair must be invisible.

| still | focusRect | gauges found (visible, size, art scale, dots) |
|---|---|---|
| `v5/stills/w3-gauge-deep-mac.png` | [126.5, 945, 600, 340] | PulseRing 156 px, 1.000000, 144 dots; DotArc 144 px, 0.666667, 28 dots |
| `v5/stills/w3-gauge-deep-storage.png` | [1803.5, 640, 660, 240] | DotBar 360 px x2, 1.000000, 12 dots each; DotArc 160 px, 0.740741, 28 dots |
| `v5/stills/w3-gauge-deep-launcher.png` | [1064, 844, 1400, 456] | none of the four (the launcher draws LauncherArc) |
| `v5/stills/w3-icontile-states.png` | n/a | `kit/icons/TileStates.qml`, the W4 state sheet: idle, launch count, running, selected, focusLevel 1 |

IconTile is not composed into `DeckSurface` (the launcher draws `LauncherArc`),
so its state view is the W4 sheet, re-rendered from this branch.

Rendered with `v5/tools/deck-shot.sh <still> <png>`: 2560x1440, exit 0 for all
four, `mode=rhi api=metal`, `distinct` 174 / 168 / 164 / 84.

Pixel check against the same stills rendered on the base commit (`7fb4151`) with
`v5/tools/w3-still-diff.py`:

| still | changed px above noise 2 | max channel delta | verdict |
|---|---|---|---|
| mac | 0 | 1 | unchanged |
| storage | 0 | 1 | unchanged |
| launcher | 0 | 1 | unchanged |
| icontile states | 0 | 1 | unchanged |

The W3 component harness (`stills/w3-gauge-harness.qml`, PulseRing / DotArc /
DotBar / LocalOrb side by side) is also unchanged: 0 changed pixels. So the
repair moves the motion and nothing else.

`v5/tools/w3-gauge-deck-audit.py` (exit 0) reads the composed item tree for all
three views: focusId matches the request, focusRect is non-empty, the gauges a
view composes are visible, every visible gauge paints its dots and draws at its
own published target scale (`artScale == targetScale` to 2e-3). That last check
is what caught the startup artifact above.

## qmllint

`./tools/qml-lint.sh nexuslink.hud/v5`: **282 warnings, 0 errors** on this branch
(81 files) and 282 warnings, 0 errors on the base commit (`7fb4151`, 79 files
with the four still entry files copied in, 75 without). Every new file in this
branch lints at 0; `tests/w3/GaugeSpringTrace.qml` carries one `qmllint disable
unqualified missing-property` line at the top, because a probe that picks its
component at run time reads its subject from a JS variable and that is outside
what qmllint can type.

## Where the evidence lives

| Path | What |
|---|---|
| `v5/kit/PulseRing.qml`, `DotArc.qml`, `DotBar.qml`, `IconTile.qml` | the repair |
| `v5/tests/w3/GaugeSpringTrace.qml` | probe: samples the shipped component's animated value, one run per `--component/--channel/--mode/--stall` |
| `v5/tests/w3/GaugeDeepAudit.qml` | the composed deck's item tree for one deep view |
| `v5/tools/w3-gauge-spring-trace.py` | 15 runs, closed form, agreement, bands; exit 1 on a band miss |
| `v5/tools/w3-gauge-deck-audit.py` | the three deep views: focus id, rect, visible gauges, resting scale, dots |
| `v5/tools/w3-still-diff.py` | two stills, changed pixels and their bounding box |
| `v5/stills/GaugeDeepStill.qml` + `w3-gauge-deep-{mac,storage,launcher}.qml` | the deck stills and their entry files |
| `v5/stills/w3-gauge-deep-{mac,storage,launcher}.png`, `w3-icontile-states.png` | the renders |
| `v5/docs/w3-gauges-traces/{before,after}/` | raw TRACE lines for all 15 runs each |

Reproduce:

```
v5/tools/w3-gauge-spring-trace.py --json v5/docs/w3-gauges-traces/after
v5/tools/w3-gauge-deck-audit.py --json /tmp/w3-audit
v5/tools/deck-shot.sh v5/stills/w3-gauge-deep-mac.qml /tmp/after-mac.png
v5/tools/w3-still-diff.py /tmp/base-mac.png /tmp/after-mac.png
```

## Not changed here

- `Tokens.qml` and `Motion.qml`: no new token. The OutBack parameter is a local
  literal in all five components that use it (`LocalOrb`, and these four), and a
  request for `Motion.expandBackOvershoot: 1.15` is open in the `t_8c9850c9` PR.
- Pre-existing deck warnings, unchanged by this card: `DeckSurface.qml:99`
  declares `signal focusChanged(string)` on top of `focusId`'s change signal
  ("Duplicate signal name: invalid override"), and `LauncherArc` still resolves
  glyphs by URL (`icons/arc-raiders.qml` missing, card `t_9778a241`).
