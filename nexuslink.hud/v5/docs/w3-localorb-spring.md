# W3 LocalOrb: the sphere-field motion, repaired and measured

Repair card: `t_8c9850c9` (HUD v5 W3 REPAIR), raised by I1 `t_f7a6561e` from a
W2 defect note. Scope: `nexuslink.hud/v5/kit/LocalOrb.qml` only.

## The defect, measured

`LocalOrb.qml` drove its sphere-field scale with

```qml
readonly property real springStiffness: Motion.expandOmega * Motion.expandOmega   // 278.89
readonly property real springDamping: 2 * Motion.expandZeta * Motion.expandOmega  // 23.05
...
Behavior on scale { SpringAnimation { spring: root.springStiffness
                                      damping: root.springDamping
                                      mass: 1.0 } }
```

The numbers are the correct analytic pair for Motion's 0.69 / 16.7 spring, but
Qt 6.12's `SpringAnimation` does not evaluate that pair: it integrates in fixed
16 ms substeps, applies the spring term without a `dt` factor and clamps
`damping` to `[0, 1]`, so `damping 23.05` collapses to `1.0` and the response is
a barely damped explicit Euler spring. The result is not a 5.00 percent
overshoot: it is a divergence on the very first change of either input, with no
late frame required.

Trace of the shipped component at the deck's size (200 px, `sizeGb` 0.33,
activity 0 -> 1), offscreen with a 4 ms sampler (the runtime delivered 2 to 137 ms
grid), `fieldScale` read from the component:

| t (ms) | fieldScale, before the repair |
|---|---|
| 212 | 1.0000 |
| 240 | 0.12103 |
| 269 | 4.40018 |
| 278 | -10.4153 |
| 366 | -19798.8 |
| 382 | 68552.9 |
| 578 | 2.03e+11 |
| 1460 | -9.40e+40 |

All four runs (expand, expand with a 150 ms stalled frame, return, focus) leave
the scale range the same way: `max|v|` 9.40e+40 expand, 2.64e+33 stalled,
4.18e+40 focus, 1.19e+56 return. The return run diverges before its own trigger
- applying `activity: 1` at component creation is enough, which is why the
deck's LOCAL view was one feed write away from a broken frame. Raw traces:
`v5/docs/w3-localorb-traces/before/` (`tools/w3-localorb-trace.py` on the
pre-repair component).

W2 measured the same class of failure on the crew orb (`1.0 -> 26076` on a
150 ms stall) and the wave replaced it there; `CrewOrb`, `FindField`, `Focus`
and `LauncherArc` all carry the reasoning in comments. `LocalOrb` was the one
gauge left behind.

## The repair

The wave's measured pattern, with the direction split the card asks for:

```qml
readonly property real expandOvershoot: 1.15        // OutBack parameter, peak 1.04871
readonly property real targetScale: (1 + activityLift * activityAmount)
                                    * (1 + focusLift * focusAmount)
property real fieldScale: 1.0                       // what the field is drawn at

Component.onCompleted: root.fieldScale = root.targetScale    // stills stay deterministic

onTargetScaleChanged: { ... grow or settle to targetScale ... }

NumberAnimation { id: grow;   property: "fieldScale"; duration: Motion.expandMillis
                  easing.type: Easing.OutBack; easing.overshoot: root.expandOvershoot }
NumberAnimation { id: settle; property: "fieldScale"; duration: Motion.returnMillis
                  easing.type: Easing.OutCubic }
```

- `Easing.OutBack` at overshoot parameter 1.15 peaks at 1.04871, i.e. **4.87
  percent** - the same curve and the same peak `CrewOrb` (1.15) and `FindField`
  (1.15) already ship, inside the 4 to 6 band. `Motion.expandOvershoot` (0.05) is
  the target, not the parameter; `Motion.qml` carries no OutBack parameter yet,
  so it stays a local `readonly` with this comment, and the token is requested in
  the PR body.
- Expand runs on `Motion.expandMillis` (347 ms), return on `Motion.returnMillis`
  (444 ms) with `OutCubic`: monotone, no overshoot, slower than the expand,
  exactly what `Motion.returnZeta: 1.0` states.
- Two animations rather than one `Behavior`: a Behavior can hold only one
  animation, so it would have to use the expand curve on the way down as well,
  and `Motion.returnOvershoot` is 0. `onTargetScaleChanged` picks by comparing
  the new target with the value on screen, which is correct mid-flight too.

## Growth trace

Closed form of the shipped curve, exactly what `QEasingCurve::easeOutBack`
evaluates for `NumberAnimation`, sampled at the card's 8 ms grid (8 percent
lift, 1.0000 -> 1.0800). `tools/w3-localorb-trace.py` prints this table from the
parameters the component publishes at run time, so it cannot drift from the QML.

| t ms | fieldScale | of the lift |
|---|---|---|
| 0 | 1.000000 | 0.00 % |
| 8 | 1.007431 | 9.29 % |
| 16 | 1.014424 | 18.03 % |
| 24 | 1.020991 | 26.24 % |
| 32 | 1.027146 | 33.93 % |
| 40 | 1.032900 | 41.13 % |
| 48 | 1.038267 | 47.83 % |
| 56 | 1.043259 | 54.07 % |
| 64 | 1.047889 | 59.86 % |
| 72 | 1.052170 | 65.21 % |
| 80 | 1.056113 | 70.14 % |
| 88 | 1.059732 | 74.67 % |
| 96 | 1.063040 | 78.80 % |
| 104 | 1.066048 | 82.56 % |
| 112 | 1.068770 | 85.96 % |
| 120 | 1.071219 | 89.02 % |
| 128 | 1.073407 | 91.76 % |
| 136 | 1.075346 | 94.18 % |
| 144 | 1.077049 | 96.31 % |
| 152 | 1.078529 | 98.16 % |
| 160 | 1.079799 | 99.75 % |
| 168 | 1.080871 | 101.09 % |
| 176 | 1.081758 | 102.20 % |
| 184 | 1.082472 | 103.09 % |
| 192 | 1.083027 | 103.78 % |
| 200 | 1.083434 | 104.29 % |
| 208 | 1.083707 | 104.63 % |
| 216 | 1.083858 | 104.82 % |
| **224** | **1.083899** | **104.87 %** (peak) |
| 232 | 1.083844 | 104.80 % |
| 240 | 1.083705 | 104.63 % |
| 248 | 1.083494 | 104.37 % |
| 256 | 1.083225 | 104.03 % |
| 264 | 1.082910 | 103.64 % |
| 272 | 1.082561 | 103.20 % |
| 280 | 1.082192 | 102.74 % |
| 288 | 1.081814 | 102.27 % |
| 296 | 1.081441 | 101.80 % |
| 304 | 1.081085 | 101.36 % |
| 312 | 1.080759 | 100.95 % |
| 320 | 1.080476 | 100.59 % |
| 328 | 1.080248 | 100.31 % |
| 336 | 1.080087 | 100.11 % |
| 344 | 1.080007 | 100.01 % |

- **Peak overshoot 4.87 percent** at 224 ms, inside the 4 to 6 band.
- **Settled to within 2 percent of the lift at 288 ms** (Motion's analytic 347 ms
  is the 4/(zeta*omega) constant; OutBack's tail is shorter). Reached exactly
  1.0800 at 347 ms and stays there.
- Runtime measurement of the same run (offscreen, 4 ms sampler, the QML runtime
  delivers a 11 to 62 ms grid): peak 1.083732 = **4.67 percent**, settle 292 ms,
  `max|v|` 1.0837. The coarser grid explains the difference; across runs the
  measured peak sits between 4.4 and 4.9 percent and the closed form is the exact
  value, so the runtime number is corroboration, not the specification.
- Focus lift (4 percent, `focusLevel` 0 -> 1): peak 1.041776 runtime / 1.041950
  closed form = **4.44 / 4.87 percent**, settle 278 / 288 ms.
- Return (activity 1 -> 0, 1.0800 -> 1.0000): minimum 1.000000, **0.00 percent
  below rest**, settles in 314 ms runtime / 320 ms closed form. Monotone.

## Stalled frame

The same expand with the event loop blocked for 150 ms at the trigger (the frame
W2 measured `1.0 -> 26076` on): peak 1.083895, **4.87 percent**, settle 413 ms,
`max|v|` 1.083895. A time-based curve is evaluated at its true elapsed time after
a stall - the animation can *skip* the peak but cannot exceed it, because the
value is `start + lift * ease(t / duration)` with `ease` bounded in
`[0, 1.04871]` for the whole duration. There is no integrator state to blow up.

For completeness, the composed deck itself (not just the component):
`tests/w3/LocalDeepTrace.qml` drives `DeckSurface.modelActivity` 0 -> 1 in the
`local` deep view and samples the composed orb - 1.0000 -> 1.08365 peak -> 1.0800
and flat, on the deck scene's ~100 ms grid.

## Where the evidence lives

| Path | What |
|---|---|
| `v5/tests/w3/LocalOrbTrace.qml` | the harness; samples `LocalOrb.fieldScale` |
| `v5/tests/w3/trace-expand.qml` | activity 0 -> 1 |
| `v5/tests/w3/trace-expand-stall150.qml` | the same with a 150 ms blocked frame |
| `v5/tests/w3/trace-return.qml` | activity 1 -> 0 |
| `v5/tests/w3/trace-focus.qml` | `focusLevel` 0 -> 1 |
| `v5/tests/w3/LocalDeepAudit.qml` | the `local` deep view's structure (focus id, orb box, scale) |
| `v5/tests/w3/LocalDeepTrace.qml` | the same lift through the composed deck |
| `v5/tools/w3-localorb-trace.py` | runs the four runs, scores them, prints the 8 ms table |
| `v5/tools/w3-deep-still-check.py` | diffs a focused still against the unfocused one (deep view only inside focusRect) |
| `v5/stills/w3-local-deep.qml` | the still: the deck's `local` deep view at 2560x1440 |
| `v5/docs/w3-localorb-traces/{before,after}/` | raw TRACE lines |

Reproduce:

```
v5/tools/w3-localorb-trace.py --json v5/docs/w3-localorb-traces/after
v5/tools/deck-shot.sh v5/stills/w3-local-deep.qml v5/stills/w3-local-deep.png
```

Exit 0 means: expand and focus inside 4 to 6 percent, return with no below-rest
overshoot, no divergence in any run including the stalled one.

## The `local` deep view after the change

`v5/stills/w3-local-deep.jpg` - `deck-shot.sh` at 2560x1440, exit 0,
`distinct=184`, `mode=rhi api=metal`. Structure from
`tests/w3/LocalDeepAudit.qml` on the same tree:

```
focusId local, focusActive true, focusRect [1804, 390, 660, 340]
LocalOrb: visible, size 200 px, box [1804, 390, 200, 200], 171 dots,
          fieldScale 1.000000 at rest, targetScale 1.000000,
          expandOvershoot 1.15, expandMillis 347, returnMillis 444
```

`modelActivity` is the fixtures' 0.0, so the orb is at rest in this still - which
is the point: the rest layout and the rest silhouette do not move. The lift
itself is the trace above.

Pixel check (`tools/w3-deep-still-check.py`): the same still rendered twice, once
as shipped and once with `focusRequest: ""` (a one-line copy of
`stills/w3-local-deep.qml`), then diffed - **10,759 pixels changed, 100.0 percent
of them inside focusRect [1804, 390, 660, 340]**, focus-box mean luminance 11.22
and the deck's brightest pixel dropping from 146 to 41 when the focus is cleared
(the acid orb dots are the bright content there). So the deep view is drawn, and
it is drawn exactly where the audit says it is.

## Not in this card: the other three gauges carry the same spring

`PulseRing.qml:110-111`, `DotArc.qml:70-71`, `DotBar.qml:90-92` and
`IconTile.qml:102-107` pass the same analytic pair to `SpringAnimation`, so they
diverge the same way. This card's acceptance is "no other component file
touched", so they are reported, not patched here: follow-up card `t_34fe7635`.

Also noticed while rendering (pre-existing, not W3's): `LauncherArc` still loads
glyphs by URL (card `t_9778a241`) and `DeckSurface.qml:99` declares
`signal focusChanged(string)` on top of `focusId`'s own change signal, which Qt
reports as `Duplicate signal name: invalid override` (deck warning, unchanged by
this card).
