# I1 perf evidence — v5 DP-2 deck

Two things acceptance asks for: the idle-cost reasoning (one shader per swarm at
a 24 to 30 Hz tick, no Canvas, no per-frame JS geometry) and a measured
frame-time figure for the deck at 2560x1440 on this Mac. The live shell gate
(idle CPU over 60 s warm, RSS within +30 MB) runs on Linux on the real
compositor; this file gives the local number it will be compared against.

## Measured frame time, 2560x1440, Metal

`spike/timing/swarm-bench.cpp` (C2's QML bench: QQuickRenderControl + RHI, N
frames, cycles the root's `benchPhase` so nothing is cached). Build once:

```
cmake -S nexuslink.hud/v5/spike/timing -B nexuslink.hud/v5/spike/timing/.build \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew/opt/qt
cmake --build nexuslink.hud/v5/spike/timing/.build --parallel 4
```

then per still:

```
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
QML_IMPORT_PATH=<NexusHud/V5 -> v5/kit> \
  nexuslink.hud/v5/spike/timing/.build/swarm-bench \
    nexuslink.hud/v5/stills/i1-deck-rest.qml 2560 1440 240
```

| state | frames | mean | p50 | p95 | max |
|---|---|---|---|---|---|
| rest, with `kit/Knot.qml` | 240 ×4 | 2.23 / 3.03 / 2.33 / 1.98 ms | 1.96 / 2.97 / 1.92 / 1.63 ms | 3.25 / 3.63 / 5.64 / 3.24 ms | 3.74 / 4.07 / 6.40 / 6.80 ms |
| crew focus (dim + scrim + blur) | 240 ×4 | 0.70 / 0.77 / 0.87 / 0.84 ms | 0.63 / 0.64 / 0.76 / 0.74 ms | 1.69 / 1.70 / 2.22 / 2.10 ms | 2.29 / 2.52 / 3.00 / 2.77 ms |
| launcher focus | 240 ×3 | 0.71 / 0.68 / 0.87 ms | 0.62 / 0.58 / 0.77 ms | 1.67 / 1.42 / 2.05 ms | 2.27 / 2.35 / 2.82 ms |

A 60 Hz frame is 16.7 ms, so the whole deck costs 12 to 18 percent of one frame
at rest and about 4 to 5 percent while a widget owns focus. The rest figures
carry the first frames (pipeline compilation for the two swarm shaders), which is
why `p50` sits under the mean; the runs spread because the machine was also
building and rendering this branch, so the honest statement is **1.6 to 3.0 ms
p50, 2.2 to 3.0 ms mean, 6.8 ms worst single frame**. The focus states are
cheaper, not dearer: with `hideSource` on, the stage is replaced by one blurred
copy instead of the swarms, and a single blurred quad is cheaper than two
full-screen shader passes on this GPU.

## Why idle cost stays where it is

* **One shader per swarm.** `Swarm.qml` and `SwarmSphere.qml` are the only
  `ShaderEffect`s on the deck (knot, crew shell). No `Canvas` anywhere:
  `grep -rn Canvas nexuslink.hud/v5/` matches only prose in comments.
* **30 Hz tick, not 60.** Both swarms advance `phase`/`breathPhase` from a
  `Timer { interval: 33 }` and move their uniforms by the wall-clock delta, so
  the fragment pass is the same at 30 or 60 Hz but the uniform upload is half as
  often (`Tokens.swarmTickHz` 30, `swarmTickHzMin` 24).
* **No per-frame JS geometry.** Every dot field (crew sub-swarms, `LocalOrb`,
  `DotArc`, `DotBar`) is a static model whose delegates are positioned at build
  time; the only per-frame values are spring-driven property bindings.
* **The kit's own text and dots do not animate per frame.** `IdleDrift` moves one
  `Translate` per group (two property writes per tick), the gauges animate one
  `level` property with a `NumberAnimation`, and the clock repaints once a
  minute (the seconds are not shown).
* **Feeds are lazy.** `DeckMain.qml` runs its readers on a 10 s timer (link,
  sessions, metrics) and a 60 s timer (apps, `df`). The fleet-pulse rule ("cache
  10 s, never faster") is the cadence of the whole feed layer.
* **Focus costs nothing while it is idle.** `kit/Focus.qml` captures the stage
  into a `ShaderEffectSource`, but only renders the dim/blur copy while
  `active`: both consumers are `visible: root.effectsVisible`, so at rest the
  capture is not in the render tree and no full-frame texture is taken. The
  rest bench above (1.4 to 2.8 ms p50 for a 2560x1440 frame including two
  full-screen swarm passes) could not be that low if a live 1440p capture were
  also running.

## What this number does not cover

* The Quickshell layer itself (panel window, IPC, `Process` spawns). Not
  measurable on this Mac: Quickshell is not installed here and there is no
  Wayland compositor, which is exactly why `DeckMain.qml` and `DeckSurface.qml`
  are split.
* Idle CPU of the live shell over 60 s and RSS: Linux's gate on the real box.
  For reference, the pre-change figure in the plan is 20 to 23 percent of one
  core; this deck replaces a `Canvas` PixelLogo with two shaders and adds no
  per-frame JS, so the expectation is at or below that, but expectation is not
  evidence and the Linux gate is the evidence.
* GPU time is the frame time above, not a profiler capture: `swarm-bench`
  measures wall clock per rendered frame including the RHI submit, which is the
  number that matters for a 60 Hz budget.
