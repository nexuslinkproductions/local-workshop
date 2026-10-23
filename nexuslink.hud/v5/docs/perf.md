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
| rest, placeholder knot slot | 240 | 1.98 ms | 1.63 ms | 3.24 ms | 6.80 ms |
| rest, **with `kit/Knot.qml`** | 240 ×2 | 3.02 / 2.15 ms | 2.79 / 1.43 ms | 4.15 / 5.46 ms | 9.89 / 10.51 ms |
| crew focus (dim + scrim + blur) | 240 ×2 | 0.84 / 0.87 ms | 0.74 / 0.76 ms | 2.10 / 2.22 ms | 2.77 / 3.00 ms |
| launcher focus | 240 ×2 | 0.92 / 0.87 ms | 0.77 / 0.77 ms | 2.25 / 2.05 ms | 2.99 / 2.82 ms |

A 60 Hz frame is 16.7 ms, so the whole deck costs 12 to 18 percent of one frame
at rest and about 5 percent while a widget owns focus. The rest figures carry the
first frames (pipeline compilation for the two swarm shaders), which is why
`p50` is well under the mean; the two with-Knot runs straddle each other, so the
honest statement is **1.4 to 2.8 ms p50, 3.0 ms mean at worst**. The focus states
are cheaper, not dearer: with `hideSource` on, the stage is replaced by one
blurred copy instead of the swarms, and a single blurred quad is cheaper than two
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
