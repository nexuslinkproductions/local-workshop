# Swarm renderer decision (C2 spike)

Builder: kakashi (ds4f), 2026-10-23. Cards t_87db5cdb (spike), t_0f6ab81e
(repair after VERIFY t_b44c03a3) and t_a04985b6 (repair after the round-2
re-verify t_87ec78ea). Winner: **option A, raymarched tube SDF with
procedural dot cells**, for the knot. The crew orb ships on option B's vertex
path, because A's sphere branch does not render at orb size; the numbers for both
paths are in section 6.

Reference for the visual gate: `hud-candidates/comp-r1/s2/s2-knot-frame.jpg`
(720 x 720, the s2 knot frame; s2 is the target, s1 is superseded). All stills
are rendered at the same framing: ring radius = 0.30 x 720 = 216 px, so a pixel
in a render is a pixel in the reference.

## 1. What was built

| | technique | files |
|---|---|---|
| A | one quad; the fragment shader raymarches a tube SDF of the traced knot (baked 1024^2 centre-line distance texture, sphere-tracing), then draws round-dot cells on the surface at the hit. The radius is the projected scale (perspective) times a per-cell jitter; there is no depth-size term on the knot. Brightness and colour are what ramp with depth | `spike/shaders/swarm_a.frag`, shipped as `kit/shaders/swarm.frag` |
| B | vertex expansion: GridMesh, one vertex per dot read from the data texture; each fragment tests the 3 x 3 texels around its cell and keeps the front-most. The radius carries a depth term (perspective alone does not read at orb size) | `spike/shaders/swarm_b.vert`, `swarm_b.frag`, shipped as `kit/shaders/swarm_vertex.vert`, `swarm_vertex.frag` |
| C | one quad; the fragment shader finds its own cell, then walks the 3 x 3 cell neighbourhood in the baked cell lists | `spike/shaders/swarm_c.frag` |

Geometry: `spike/geometry/trace_knot.py` traces `knot-source.svg` (logo-r1) into
23 chains / 3,320 px of centre line at knot height 540; `make_swarm.py` turns
that into a 3D lattice shell and bakes every data texture. Options A, B and C
share that one cloud, so the comparison is between rasterisation strategies, not
between geometries.

## 2. Visual, the three options (spike stills)

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
`c-knot-compare.jpg` (reference | render | overlay).

## 3. Visual, as shipped (repair t_0f6ab81e)

The repair changed the dot geometry, not the rasterisation. The defect was that a
disc of radius 0.0115 sat against a 0.01617 pitch: diameter 1.42 x pitch, so
neighbouring discs overlapped and every lattice cell filled into a square tile.
At 1080 the knot read as a mosaic of touching squares instead of round points
with gaps.

What changed, and why in these amounts:

- **Dot radius 0.0115 to 0.0086.** The disc now fits inside its cell: cell fill
  0.375 against the reference's 0.36 (measured by `spike/dots.py`), instead of
  0.418 with whole cells lit.
- **Dot pitch 0.01617 to 0.01907.** That constant is the pitch in the surface's
  own coordinates: 0.01907 x 216 = 4.12 px per lattice step on the tube, with no
  foreshortening applied. It is not what `spike/dots.py` reports for the render.
  The same nearest-neighbour metric reads **3.16 px at 720** on our still and
  4.12 px on the s2 frame, and the gap is projection, not density: s2's dots sit
  on a flat sigil, so their spacing is unaffected by viewing angle, while ours
  wrap around a tube whose normal turns away from the screen. The azimuthal
  spacing of a dot on a surface tilted by theta is pitch x cos(theta), and the
  area-weighted mean of cos over the visible half of a tube is pi/4 = 0.785;
  3.16 / 4.12 = 0.767. Read 3.16 px as the measured spacing of the shipped
  render and 4.12 px as the s2 lattice on its flat plane, not as the same
  quantity.

  The dot count does not close the same way: `spike/dots.py` counts 3,069 peaks
  at 0.35 on our 720 still against 1,740 on s2, and 1.76x is a real surplus.
  Two things produce it, both geometry rather than lattice tuning: the trace
  carries more dot-bearing surface than the flat sigil (its arms reach 1.28 x the
  ring radius, see the geometry ceiling below), and the foreshortened side of each
  tube packs more dots into a screen pixel than a flat plane does. The per-cell
  fill still matches (0.375 against s2's 0.36), so the 4x crops read the same way
  even though the count does not.
- **Brightness floor 0.30 to 0.55 of the depth ramp, accent mix 0.55 to 0.72,
  gain 1.0 to 1.28.** With discs that no longer tile, the far side of the tube
  fell under any threshold (0.30 floor x 0.55 accent = 0.10 luminance at the
  core) and the frame read as a dim smear. The floor keeps every dot above the
  threshold while the near side still reads brighter, so the depth cue survives.
- **Dot edge:** the anti-aliasing band went from 0.42 r to 0.34 r with a shorter
  upper tail (`smoothstep(r - aa, r + 0.5 aa, d)`). A 3 px dot cannot afford a
  1 px soft rim on both sides of a 1.5 px radius; the old ramp ate the core.

| measure at 720 | s2 reference | before the repair | after the repair |
|---|---|---|---|
| coverage @0.35 | 0.02055 | 0.01472 | **0.02220** |
| dot peaks @0.35 | 1740 | 2028 | 3069 |
| dot area median | 7 px² | 2 px² | 3 px² |
| merge (components / peaks) | 0.875 | 0.674 | **0.834** |
| cell fill (lit area / peak / pitch²) | 0.36 | 0.418 | **0.375** |
| component aspect median | 1.0 | 2.0 | 1.5 |
| round share (aspect <= 1.5) | 0.869 | 0.364 | 0.625 |
| silhouette IoU (blur 6) | - | 0.2585 | **0.3048** |
| silhouette IoU (blur 12) | - | 0.3516 | 0.3761 |
| chamfer mean | - | 8.81 px | **8.15 px** |

The "before" column is `spike/options/a_knot.qml` and the "after" column is the
shipped `static/swarm-still.qml`, both at the pose the s2 frame is scored at
(yaw 0, tilt 0.0401; the still pins `phase: 0` for exactly that reason). The
still is rendered on the deck's `#06080a` background while the spike stills are on
black, which is worth about 0.0014 of coverage, so the two columns are as close
to like for like as the two stills allow.

Against the acceptance bands the repair asked for, at 720:

- silhouette IoU blur 6: 0.3048, floor 0.260 (the before figure was 0.2585,
  which is where the 0.260 in the card comes from, rounded up).
- chamfer mean: 8.15 px, ceiling 8.7 px (before: 8.81 px).
- coverage @0.35: 0.02220, reference 0.02055, so +8 percent, inside the plus or
  minus 25 percent band.

What is still different: our field is finer than s2's, 3069 peaks against 1740,
with 3 px² dots against 7 px². The trace has more dot-bearing surface than the
flat s2 sigil (the tube wraps around, and the traced arms reach 1.28 x the ring
radius), so the same pitch yields more, smaller dots. The per-cell fill and the
gap ratio match s2, which is what makes the 4x crops read the same way; the dot
count does not, and that is a geometry consequence, not a 1 px threshold effect.

### The geometry ceiling (read this before Wave 1)

The traced logo-r1 artwork does not have the same proportions as the s2 knot. A
solid fill of the trace scores a best-shift IoU of only 0.193 against
`s2-knot-frame.jpg` (`python3` one-off, recorded here): the trace's arms reach
1.28 x the ring radius while s2's stay inside it, and the trace's central band is
thicker. That caps what any renderer can score. Wave 1's "IoU above 0.9" target
in `MAIN-SCREEN-BUILD.md` is not reachable from this trace; the knot needs either
a re-trace fitted to s2 (two scale parameters plus a vertical squash, expected to
lift the ceiling to roughly 0.35) or a hand-built s2 geometry. Filed as a
finding, not silently worked around.

## 4. Cost

`spike/timing/swarm-bench.cpp` (QQuickRenderControl + RHI, the C0 harness path,
one frame per loop iteration, `rhi->finish()` after each frame so the GPU work is
included, `benchPhase` advanced per frame). 300 frames per case, one process per
case, warm-up inside the process. Metal, Apple Silicon, macOS 26.4.1, Qt 6.12.0.
The spike table below is the builder's original run of that harness.

| case | mean ms | p50 ms | p95 ms | max ms |
|---|---|---|---|---|
| A 540 x 540 | **0.567** | 0.500 | 1.197 | 1.649 |
| B 540 x 540 | 0.971 | 0.839 | 1.601 | 2.626 |
| C 540 x 540 | 1.019 | 0.892 | 1.755 | 3.150 |
| A 1080 x 1080 | **0.757** | 0.687 | 1.402 | 1.811 |
| B 1080 x 1080 | 1.527 | 1.397 | 2.120 | 3.299 |
| C 1080 x 1080 | 1.885 | 1.783 | 2.520 | 3.130 |

### The shipped components, three warm repeats each

Each row is three separate runs of the same harness at 300 frames; the number
shown is the median of the three, and the spread is min to max of the three. The
run-to-run spread is quoted because the verifier's three runs and the builder's
single run disagreed by up to 15 percent on p95 (see the note under the table).

| case | mean ms (spread) | p95 ms (spread) | share of a 33 ms tick |
|---|---|---|---|
| Swarm 540 | 0.588 (0.561 to 0.661) | 1.088 (1.087 to 1.144) | 1.8 percent |
| Swarm 1080 | **0.944** (0.879 to 0.953) | 1.737 (1.633 to 1.755) | 2.9 percent |
| SwarmSphere 224 | **0.773** (0.772 to 0.804) | 1.283 (1.213 to 1.338) | 2.3 percent |
| SwarmSphere 320 | **1.069** (1.006 to 1.213) | 1.612 (1.497 to 2.136) | 3.2 percent |
| A sphere branch 224 | 0.498 (0.460 to 0.508) | 1.050 (0.885 to 1.069) | 1.5 percent, renders nothing |
| A sphere branch 320 | 0.507 (0.455 to 0.534) | 1.038 (0.943 to 1.088) | 1.5 percent, renders nothing |

Risk note for SwarmSphere. The orb used to be the most expensive ambient item in
the kit even though it covers a quarter of the knot's pixels: 1.03 ms at 224 px
and 1.39 ms at 320 px on the pre-repair mesh. The vertex path pays a fixed
triangle cost (19,200 quads, 38,400 triangles) that tracks the mesh, not the
pixels, so that number was mostly geometry. The round-3 repair cut the mesh to
96 x 60 (5,670 quads, 11,340 triangles) where one texel is one dot, and the orb
now measures **0.77 ms at 224 and 1.07 ms at 320**, cheaper than before even
though the fragment stage reads a 3 x 3 texel block instead of four corners: the
padding texels (R = 255) reject on the first fetch, and there are three times
fewer triangles to shade. At the 30 Hz tick that is 2.3 and 3.2 percent of one
core-second for one orb, about 7 to 10 percent for a three-orb row. If I1
measures more than that on the live shell, the mesh can drop to 72 x 45 and lose
a quarter of the triangles; the dot count would stay the same, only the quad
grid gets coarser, and the quads stay wider than a disc at both deck sizes.

Note on C at 540, p95. The builder's row says 1.755 ms; the verifier's three runs
said 1.481; this repair's three runs say 1.414, 1.444 and 1.624 (median 1.444).
The means agree (1.019 builder, 0.965 verifier, 0.979 here). So the p95 of a 300
frame run moves about 15 percent run to run, which is enough to explain the
disagreement: the builder's 1.755 is the high end of the same distribution, not a
different renderer. Read p95 rows as plus or minus 15 percent.

## 5. Ambient tick, 24 to 30 Hz

`kit/Swarm.qml` and `kit/SwarmSphere.qml` no longer animate with
SequentialAnimation. Each has one `Timer` at `interval: 33` ms (30.3 Hz) that
advances a `phase` value in 0 to 1; every animated uniform is a pure function of
`phase` (`yaw = 0.10 sin(2 pi phase)`, `tilt = 0.045 sin(2 pi phase + 1.1)` on the
knot, 0.16 and 0.09 rad on the orb). The tick handler is three lines of
arithmetic, the geometry is static, there is one ShaderEffect per swarm, and
there is no Canvas.

The phase advances by the wall clock time that actually passed since the last
tick, capped at 500 ms, rather than by a fixed 33 ms step. A timer that is late
(a coarse timer, a busy main thread, an OS that throttles a background process)
then stretches the step size but keeps the 5.5 s cycle; a resume after a long
stall cannot jump the pose.

### Breath, and why only the orb has one

`kit/Motion.qml` carries the breath tokens (period 5.8 s, 40 percent in / 60
percent out, scale 0.02, brightness 0.14). Until this repair neither swarm read
them, and the only period either component ran was the 5.5 s rotation wander.
`kit/SwarmSphere.qml` now runs a second accumulator on the same 33 ms tick
(`breathPhase`), eased with smoothstep on both legs, driving `u_breathScale`
(1.000 to 1.020) and `u_breathBright` (1.000 to 1.140) into the fragment shader.
The rotation wander stays at 5.5 s and `speed` does not touch the breath: two
orb periods on screen would look like a pulse, one is the ambience.

Traced from a QML probe against the shipped component with the tick live
(`spike/probe/breath-trace.qml`, 155 samples over 13.06 s at 11.9 Hz under the
offscreen throttle; `evidence/c2-repair-r3/breath-trace.txt` and
`breath-summary.txt`):

- breath min **0.0001**, max **1.0000**; scale 1.0000 to 1.0200; brightness
  1.0000 to 1.1400;
- measured period **5.71 s** from the two breath peaks (2.35 s and 8.07 s) and
  **5.75 s** from three rising crossings of 0.5 (1.22, 7.00, 12.73 s), against
  the 5.8 s token;
- rise 0.05 to 0.95 takes 1.64 s and the fall takes 3.14 s, a 34 / 66 split of the
  measured period, which is the 40 / 60 token after the smoothstep's flat ends
  are taken out.

`animate: false` pins the breath at 0, so every still in this document is a still
frame with scale 1.0 and brightness 1.0, exactly as before the breath landed.

The knot does not breathe. Whether it should is a bridge-triage call, and the
reason to leave it out of this repair is that any change to `kit/shaders/swarm.frag`
would disturb a knot geometry the round-2 verify passed (silhouette IoU 0.3048,
chamfer 8.15 px); the orb's breath is additive in its own shader and touches
nothing else.

Measured on this Mac with the Qt `qml` runtime and the offscreen platform, which
is the only place a QML timer can be watched here:

- control: a plain QML `Timer` at 33 ms fires at 13.0 to 18.5 Hz from an
  offscreen process on this box, so the platform throttles short timers no matter
  what the deck does;
- `kit/Swarm` under the same throttle: `phase` reaches 0.268 to 0.272 after
  1.59 s of wall time, an implied cycle of 5.79 to 5.94 s against the 5.50 s
  target, so the cycle survives the throttle.

The 30 Hz rate itself has to be confirmed on Linux/Quickshell, where the deck is
a foreground Wayland client and no such throttle applies. The harness used for
the stills cannot prove it either way: `tools/qml-shot.sh` does not advance the
animation, which is why the stills pin `animate: false` and `phase: 0`.

## 6. The orb: option A against option B

`MAIN-SCREEN-BUILD.md` constraint 4 says the orb is the same renderer on a
sphere. The verifier measured option B's dots at orb size as dashes and streaks
rather than round points, and asked for both paths with numbers instead of a
decision taken alone. Here they are.

**Option A, the raymarch sphere branch.** Does not render. The fragment shader
builds its view ray nearly orthographically (object xy = px / pxPerUnit) but
places the dot centres with `project()`, which applies a perspective scale
`camDist / (camDist - z)`; at the orb's dot pitch (3.0 px at 224, 4.3 px at 320)
that mismatch is larger than the dot radius, so almost every fragment rejects
every dot. Measured on this Mac with `static` probes off the same pack: the
sphere at dotR 0.0100 and pitch 0.0268 gives max luminance 23 to 30 of 255 at 540
and 1080 and 0 to 1 of 255 at 224 and 320, i.e. 0.0000 lit at 0.35. Its cost is
0.50 ms at 224 and 0.51 ms at 320, which is the cost of a march that hits nothing.
This is not a tuning problem (an oversized dotR 0.05 and stipple 1.0 produce a
ring at the limb and a black middle, which is the same projection mismatch seen
from the other side); it needs the ray construction and `project()` made
consistent, which is a shader change for both the orb and the knot.

**Option B, the vertex path.** After the round-3 repair it draws round points.
What was wrong was structural, not a radius to tune: the bake stored the dots in a
nearest-neighbour *walk order*, so texel (i, j) and texel (i, j + 1) were
neighbours along the walk but far apart on the sphere. The mesh is a regular grid
whose vertices are moved onto the dots' screen positions, so those texel pairs
became ribbon quads across the sphere, and a dot's disc was drawn only by whichever
ribbons crossed it: measured at 224 px, a 3.4 px disc came out as a 1 to 2 px dash
with one straight edge, which is the "dust" the round-2 verify saw. Three more
things were wrong with it:

- the stipple hash was taken from the fragment's own cell, so the four quads
  meeting at one dot disagreed about whether that dot exists, and every kept part
  was a clipped quadrant of the disc;
- the output alpha was a hard 1.0 whatever the coverage mask said, so no disc had
  an antialiased edge;
- the pitch was 0.0268 (3.0 px at 224) for a 0.0085 radius (0.95 px), so even a
  perfect disc was under 2 px across.

What the orb is now:

- **Ring layout** (`orb_cloud` in `make_swarm.py`): row j is a ring of one polar
  angle, its dots spread evenly around it and jittered by up to 45 percent of a
  step, so texel neighbours are neighbours on the sphere in both axes and every
  quad is a small patch of surface. 96 columns x 60 rows, 3,664 dots, one dot per
  texel.
- **Positions stored exactly**, quantised to 1/127 unit (0.9 px at 224), instead
  of being snapped to a cube lattice.
- **Dot size from depth, not only perspective**: radius = `u_dotR` x the projected
  scale x `mix(0.55, 1.0, near)`, where `near` is 0 at the limb and 1 at the point
  nearest the camera. At 224 that is 2.0 px on the near side, 1.7 px at mid and
  1.1 px at the limb: a 1.8x size run on top of the brightness ramp. Perspective
  alone spans 1.3x and is invisible at this size.
- **3 x 3 texel test** in the fragment stage instead of the four cell corners:
  GridMesh gives vertex i the texcoord i / (n - 1), but the two conventions in
  circulation differ by half a texel, and a one-texel disagreement renders a dot
  as a half disc with a straight edge.
- **Per-dot jitter** on size (0.85 to 1.15) and brightness (0.86 to 1.10), so the
  field reads as a point cloud and not as a stamped grid.
- **Premultiplied output**: alpha is the coverage mask, so the disc edge is
  antialiased the same way as the knot's.

| orb measure, `spike/dots.py` at 0.35 | before (head 3ce2188) | after | card floor |
|---|---|---|---|
| 224 px: component area median | 1 px2 | **4 px2** | at least 3 |
| 224 px: component aspect median | 2.0 | **1.0** | at most 1.5 |
| 224 px: round share | 0.437 | **0.831** | at least 0.7 |
| 320 px: component area median | 2 px2 | **8.5 px2** | at least 4 |
| 320 px: component aspect median | 1.5 | **1.0** | at most 1.5 |
| 320 px: round share | 0.568 | **0.860** | at least 0.7 |
| coverage at 0.35, 224 / 320 | 0.0544 / 0.0504 | **0.1332 / 0.1341** | - |

Visual check at 4x (crops in `evidence/c2-repair-r3/`):
`orb-224-centre-x4.jpg` and `orb-320-centre-x4.jpg` show round discs with dark
gaps all round, and `orb-224-centre-x4-native.jpg` is a crop of a native 4x render
(896 px) rather than an upscale, so nothing there is interpolation. The near side
of the disc is both larger and brighter than the limb, and section 5's breath rides
on top of that.

The honest difference from the reference: ours reads as a cleaner, brighter field
than s2's orb. At the same 0.35 threshold the reference covers 0.059 of its disc
and ours covers 0.170, so 2.9x. The geometry is not the reason: scaled to 224, s2
puts 3.4 px discs on a 4.8 px pitch and we put 3.4 px discs on a 5.9 to 8.8 px
pitch, which is the same disc-to-pitch ratio and a slightly sparser lattice. The
difference is brightness and blur: most of each s2 disc falls under the threshold
because the design's orb is soft and dim, while our discs are solid. If bridge-triage
wants the orb dimmer, the knob is `u_gain` in `kit/SwarmSphere.qml` (0.95 now, and
`mix(0.62, 1.0, near)` in the shader sets the depth ramp); the geometry does not
need to move.

What ships: option B, with the ring layout and the dot geometry above, and this is
a recorded deviation from constraint 4, not an interpretation of it. Option A's
sphere branch is cheap enough (0.50 ms) that porting it would be worth a card of
its own: make the ray construction perspective-consistent, then the same
raymarcher serves the knot and the orb and the deviation disappears.

## 7. Risk: portability, and per option

Shared portability rules (found by building and running the packs):

One `.qsb` runs unchanged on both hosts. Every pack is baked with `tools/qsb.sh`
default (`--qt6`: GLSL 100 es, 120, 150 plus HLSL 5.0 plus MSL 1.2).

- No `textureSize`, no derivatives, no `uint`, no dynamic loop bounds: none of
  those exist in ESSL 100, and `qsb` fails the bake if you use them.
- Image textures are uploaded **premultiplied**: a byte stored in RGB reads back
  as `value * alpha / 255`. Every data texture is written with alpha 255 on every
  texel, and a byte that must be exact cannot live in a texel with alpha 0. This
  cost most of the spike's debugging time and is the single most likely trap for
  the next card. The orb grid broke this rule until this repair: `encode_grid`
  left its 8,430 padding texels at RGBA 0, so they decoded as index 0 (the lattice
  corner) instead of the padding marker the shader tests for. Both grids now mark
  padding with R = 255 and A = 255 (`encode_grid` and `encode_orb`), and a rebake
  into the same renderer is pixel-identical at 224 and 320, which is the check
  that the marker is inert. The knot SDF was already all-alpha-255.
- `Item.focus` is FINAL in Qt 6.12, so the dim input is `focusLevel`.
- Offscreen stills on Linux: `tools/qml-shot.sh` needs a display or an EGL
  capable path for the RHI mode (`api=` in its output says which backend it got).
  A `--glsl`-only pack renders black on Metal; do not bake with `--glsl` for a
  still on this Mac.

Per option:

- **A (shipped, knot):** one 64 step sphere-tracing loop per fragment, with a
  texture fetch and a `sqrt` per step, plus six more field evaluations for the
  gradient and one for the dot cell. Cost therefore scales with the knot's
  screen area, not with the dot count: 0.94 ms at 1080 is the ceiling for the
  sizes in the plan, but a full-screen swarm (a focus view, an expanded stage)
  would cost about 4 ms at 2560 x 1440 if the ring stayed at 0.30 x width. The
  march is bounded by a 1.34 radius sphere, so most pixels outside the knot pay
  only the bound test. Its portability risk is the 64 step loop: ESSL 100 needs
  a constant loop bound (it has one) and some mobile GLES drivers are slow at
  branchy loops, so a GLES fallback path should be measured on the Linux host
  before the deck ships.
- **B (shipped, orb):** samples a texture in the **vertex** stage, which needs
  `GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS > 0`. That holds on every GPU Qt 6.12
  supports, but it is the one thing Linux must see render before anyone trusts
  the orb. A dot is drawn by the quads of the mesh that have it as a corner, so
  two conditions have to hold: the four texels around a dot must be its spatial
  neighbours (the ring layout guarantees it, the old walk order did not), and the
  quad must be wider than the disc, or the disc gets cut to a square by the quad
  edges. At the shipped sizes the mesh cell is 2.36 px against a 2.0 px near disc
  at 224 and 3.37 px against a 2.9 px disc at 320, so a finer mesh or a bigger
  dot would bring the squares back. The fragment reads a 3 x 3 block of texels
  per pixel, and the padding texels reject on the first fetch, so its cost tracks
  the triangle count rather than the pixels (section 4).

## 8. Shader packs: exact commands and hashes

One command per pack, run from the repository root, `tools/qsb.sh` defaults
(`--qt6`, targets glsl 100es, 120, 150 plus hlsl 50 plus msl 12), exit 0 each.
These were re-run for this repair, so the hashes below are the packs as
committed on this branch. The two vertex hashes from the round-2 verdict
(`8219edec...`, `b7cebe0f...`) belong to the packs before the orb rework and no
longer apply; the knot hash `db40...` is unchanged.

    tools/qsb.sh nexuslink.hud/v5/kit/shaders/swarm.frag nexuslink.hud/v5/kit/shaders/swarm.frag.qsb
    tools/qsb.sh nexuslink.hud/v5/kit/shaders/swarm_vertex.vert nexuslink.hud/v5/kit/shaders/swarm_vertex.vert.qsb
    tools/qsb.sh nexuslink.hud/v5/kit/shaders/swarm_vertex.frag nexuslink.hud/v5/kit/shaders/swarm_vertex.frag.qsb

    swarm.frag.qsb          db40771043ec6902be358d50b407bb36f0ddf0482967b81e0b162c44f3067016
    swarm_vertex.vert.qsb   232190228572d8121467ea4c332b9ba87689410a198c8242e5d489e892a4f6c0
    swarm_vertex.frag.qsb   4771c550e419991f379a7afbc7b86a8ef1a900d9f5b7a7cf9aa7728e5404641d

The knot pack is unchanged by this repair (the knot shader did not move, and the
720 still is pixel-identical to the round-2 head render). Both vertex packs are
new: the vertex stage now resolves its texel index exactly and declares the two
breath uniforms, and the fragment stage reads the 3 x 3 block, the depth size term
and the premultiplied mask. Re-running the three commands on the committed sources
reproduces these hashes byte for byte, with a clean tree afterwards.

The spike-only packs (`spike/shaders/swarm_a.frag.qsb`, `swarm_b.*`,
`swarm_c.frag.qsb`) are not part of what ships and were not rebaked by this
repair.

## What ships

`kit/Swarm.qml` (knot, option A) and `kit/SwarmSphere.qml` (orb, option B path,
see section 6), with `kit/shaders/swarm.frag|.qsb`,
`kit/shaders/swarm_vertex.vert|.frag|.qsb`, `kit/assets/swarm-knot-sdf.png` and
`kit/assets/swarm-orb-grid.png` (96 x 60, one dot per texel, ring layout).

Both components expose `size`, `accent`, `focusLevel`, `activity`, `speed`,
`phase` and `animate`; the orb's `phase` is what Wave 1 uses to run several orbs
out of step, and `animate: false` is what the static stills use to hold a pose.
The orb additionally exposes read-only `breath`, `breathScale` and `breathBright`
plus `breathPhase`, so a test can watch the breath without reading the shader
(section 5). Wave 1 drives those properties and never touches a shader.

Integration request (the integrator owns `kit/qmldir`):

    Swarm 1.0 Swarm.qml
    SwarmSphere 1.0 SwarmSphere.qml
