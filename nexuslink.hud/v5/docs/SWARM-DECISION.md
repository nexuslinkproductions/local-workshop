# Swarm renderer decision (C2 spike)

Builder: kakashi (ds4f), 2026-10-23. Card t_87db5cdb.
Winner: **option A, raymarched tube SDF with procedural dot cells.** It wins on
visual match and on cost, so no trade-off has to be argued.

Reference for the visual gate: `hud-candidates/comp-r1/s2/s2-knot-frame.jpg`
(720 x 720, the s2 knot frame; s2 is the target, s1 is superseded). All stills
are rendered at the same framing: ring radius = 0.30 x 720 = 216 px, so a pixel
in a render is a pixel in the reference.

## What was built

| | technique | files |
|---|---|---|
| A | one quad; the fragment shader raymarches a tube SDF of the traced knot (baked 1024^2 centre-line distance texture, sphere-tracing), then draws round-dot cells on the surface at the hit, sized and tinted by depth | `spike/shaders/swarm_a.frag` |
| B | vertex expansion: GridMesh 160 x 120, one vertex per dot read from the data texture, each fragment tests the four dots of its cell and keeps the front-most | `spike/shaders/swarm_b.vert`, `swarm_b.frag` |
| C | one quad; the fragment shader finds its own cell, then walks the 3 x 3 cell neighbourhood in the baked cell lists (a data-texture neighbour lookup) | `spike/shaders/swarm_c.frag` |

Geometry: `spike/geometry/trace_knot.py` traces `knot-source.svg` (logo-r1) into
23 chains / 3,320 px of centre line at knot height 540; `make_swarm.py` turns
that into a 3D lattice shell at a 3.80 px dot pitch (measured from s2) and bakes
every data texture. Options A, B and C share that one cloud, so the comparison
is between rasterisation strategies, not between geometries.

## 1. Visual

Numbers from `spike/score.py` (masks on luminance thresholds, centroid aligned,
best shift searched). Coverage and dot counts are absolute and comparable across
renderers; IoU on a dot field is dominated by dot phase, so the silhouette IoU
(6 px box blur, fixed 0.02 threshold) and the chamfer distance are the shape
numbers to read.

| measure | reference | A | B | C |
|---|---|---|---|---|
| coverage @0.10 | 0.0493 | 0.0392 | 0.0686 | 0.1306 |
| coverage @0.35 | 0.0206 | 0.0148 | 0.0136 | 0.0518 |
| dot peaks @0.35 | 1740 | 2044 | 5548 | 16850 |
| dot area median | 1 px² | 1 px² | 3 px² | 9 px² |
| silhouette IoU (blur 6) | - | **0.260** | 0.181 | 0.198 |
| silhouette IoU (blur 12) | - | **0.353** | 0.257 | 0.273 |
| chamfer mean / p90 | - | **8.7 / 20.6 px** | 17.9 / 41.3 | 18.4 / 40.3 |

Read: A's dot field sits closest to the reference curve (chamfer 8.7 px against
a 3.8 px dot pitch and a 216 px ring), its dot count is within 18 percent of the
reference, and its coverage is the closest of the three. B's dots are visibly
elongated because the disc is clipped at triangle boundaries inside each mesh
cell; C overdraws (17k peaks) because every dot in a 3 x 3 cell neighbourhood is
tested from every fragment and the nearest-depth winner varies inside a dot.

Side-by-side sheets: `spike/stills/a-knot-compare.jpg`, `b-knot-compare.jpg`,
`c-knot-compare.jpg` (reference | render | overlay). Shipped components:
`spike/stills/swarm-knot-720.png`, `spike/stills/swarm-sphere-320.png`.

### The geometry ceiling (read this before Wave 1)

The traced logo-r1 artwork does not have the same proportions as the s2 knot. A
solid fill of the trace scores a best-shift IoU of only 0.193 against
`s2-knot-frame.jpg` (`python3` one-off, recorded here): the trace's arms reach
1.28 x the ring radius while s2's stay inside it, and the trace's central band
is thicker. That caps what any renderer can score. A reaches 0.260 silhouette
IoU, which is *above* the solid-fill ceiling because dot fields overlap softly
after the blur. Wave 1's "IoU above 0.9" target in `MAIN-SCREEN-BUILD.md` is not
reachable from this trace; the knot needs either a re-trace fitted to s2 (two
scale parameters plus a vertical squash, expected to lift the ceiling to roughly
0.35) or a hand-built s2 geometry. Filed as a finding, not silently worked
around.

## 2. Cost

`spike/timing/swarm-bench.cpp` (QQuickRenderControl + RHI, the C0 harness path,
one frame per loop iteration, `rhi->finish()` after each frame so the GPU work is
included, `benchPhase` advanced per frame so the wander animation is real).
300 frames per case, one process per case, warm-up inside the process. Metal,
Apple Silicon, macOS 26.4.1, Qt 6.12.0.

| case | mean ms | p50 ms | p95 ms | max ms |
|---|---|---|---|---|
| A 540 x 540 | **0.567** | 0.500 | 1.197 | 1.649 |
| B 540 x 540 | 0.971 | 0.839 | 1.601 | 2.626 |
| C 540 x 540 | 1.019 | 0.892 | 1.755 | 3.150 |
| A 1080 x 1080 | **0.757** | 0.687 | 1.402 | 1.811 |
| B 1080 x 1080 | 1.527 | 1.397 | 2.120 | 3.299 |
| C 1080 x 1080 | 1.885 | 1.783 | 2.520 | 3.130 |

At a 30 Hz tick the deck's budget is 33 ms per frame. A costs 0.76 ms at 1080,
2.3 percent of the tick; the whole ambient swarm stays far inside the idle
budget of plan constraint 3.

Shader complexity proxy (counted from the sources, same for the qsb pack):

| | texture reads / px | loops | ALU proxy |
|---|---|---|---|
| A | 1 per march step, 64 max, plus 6 for the normal and 1 for the dot | 1 x 64 with break | 2 hash, 1 sqrt-based SDF per step, no matrix per step |
| B | 4 (one per cell corner) + 1 per vertex | none in the fragment | 1 mat3 per candidate dot (4), 1 hash |
| C | 9 cell counts + sum of the 3 x 3 cell counts (measured mean 90, worst 111 x 9) | 2 nested, 9 x 128 with breaks | 1 mat3 per candidate dot, 1 hash per hit |

C is the only option whose per-pixel work scales with local dot density, which is
why it loses on p95 (3.15 ms max at 540) even though its average is close to B.

## 3. Risk: Linux Qt 6.12 / GLES vs Metal

One `.qsb` runs unchanged on both. Every pack is baked with `tools/qsb.sh`
default (`--qt6`: GLSL 100 es, 120, 150 plus HLSL 5.0 plus MSL 1.2), so the same
file carries the Metal and the GLES program.

Rules the shaders already obey, found by building them:

- No `textureSize`, no derivatives, no `uint`, no dynamic loop bounds: none of
  those exist in ESSL 100, and `qsb` fails the bake if you use them.
- Image textures are uploaded **premultiplied**: a byte stored in RGB reads back
  as `value * alpha / 255`. All data textures are written with alpha 255, and a
  byte that must be exact cannot live in a texture with alpha 0. This cost most
  of the spike's debugging time and is the single most likely trap for the next
  card.
- `Item.focus` is FINAL in Qt 6.12, so the dim input is `focusLevel`.
- The vertex path (option B, used by `SwarmSphere`) samples a texture in the
  vertex stage. That needs `GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS > 0`, which holds
  on every GPU Qt 6.12 supports, but it is the one thing Linux must see render
  before anyone trusts the orb.
- Offscreen stills on Linux: `tools/qml-shot.sh` needs a display or an EGL
  capable path for the RHI mode (`api=` in its output says which backend it got).
  A `--glsl`-only pack renders black on Metal; do not bake with `--glsl` for a
  still on this Mac.

## What ships

`kit/Swarm.qml` (knot, option A) and `kit/SwarmSphere.qml` (orb, option B path,
see its header for why the sphere does not use the raymarch), with
`kit/shaders/swarm.frag|.qsb`, `kit/shaders/swarm_vertex.vert|.frag|.qsb` and
`kit/assets/swarm-knot-sdf.png`, `kit/assets/swarm-orb-grid.png`.

The iOS/GLSL files Linux must confirm are exactly:

    kit/shaders/swarm.frag.qsb
    kit/shaders/swarm_vertex.vert.qsb
    kit/shaders/swarm_vertex.frag.qsb

Both components expose `size`, `accent`, `focusLevel`, `activity`, `speed`;
`SwarmSphere` also `phase`. Wave 1 drives those and never touches a shader.

Integration request (the integrator owns `kit/qmldir`):

    Swarm 1.0 Swarm.qml
    SwarmSphere 1.0 SwarmSphere.qml
