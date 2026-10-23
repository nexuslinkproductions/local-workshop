# Swarm renderer decision (C2 spike)

Builder: kakashi (ds4f), 2026-10-23. Cards t_87db5cdb (spike) and t_0f6ab81e
(repair after VERIFY t_b44c03a3). Winner: **option A, raymarched tube SDF with
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
| A | one quad; the fragment shader raymarches a tube SDF of the traced knot (baked 1024^2 centre-line distance texture, sphere-tracing), then draws round-dot cells on the surface at the hit, sized and tinted by depth | `spike/shaders/swarm_a.frag`, shipped as `kit/shaders/swarm.frag` |
| B | vertex expansion: GridMesh 160 x 120, one vertex per dot read from the data texture, each fragment tests the four dots of its cell and keeps the front-most | `spike/shaders/swarm_b.vert`, `swarm_b.frag`, shipped as `kit/shaders/swarm_vertex.vert`, `swarm_vertex.frag` |
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
- **Dot pitch 0.01617 to 0.01907** (3.49 to 4.12 px at the s2 framing). The
  reference's own lattice measures 4.12 px by the nearest-neighbour median of its
  dot peaks and 4 to 5 px by the first ring of the autocorrelation of its dot
  mask, so the shipped lattice was 15 to 18 percent finer than s2. That is why
  the dot count came out 1.75 x the reference and why the coverage had to be
  bought with oversized discs. `u_rTube`, `u_rRing` and the baked SDF are
  unchanged; only the procedural lattice and the dot radius moved.
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
| SwarmSphere 224 | 1.032 (0.966 to 1.108) | 1.532 (1.427 to 1.636) | 3.1 percent |
| SwarmSphere 320 | 1.385 (1.360 to 1.447) | 2.084 (1.951 to 2.347) | 4.2 percent |
| A sphere branch 224 | 0.498 (0.460 to 0.508) | 1.050 (0.885 to 1.069) | 1.5 percent, renders nothing |
| A sphere branch 320 | 0.507 (0.455 to 0.534) | 1.038 (0.943 to 1.088) | 1.5 percent, renders nothing |

Risk note for SwarmSphere. The orb is the most expensive ambient item in the kit
even though it covers a quarter of the knot's pixels: 1.03 ms at 224 px and
1.39 ms at 320 px, about twice the knot's cost at 1080 px. The reason is the
vertex path itself, 19,200 quads (38,400 triangles) per frame, so the cost
tracks the mesh and not the pixel count: a larger orb is nearly free, three orbs
on screen cost three times as much, and the fixed triangle cost is paid whether
or not a dot survives the fragment test. At the 30 Hz tick that is 3.1 percent
and 4.2 percent of one core-second for one orb, about 9 to 13 percent for a
three-orb row. If I1 measures that on the live shell, halving the GridMesh
resolution (80 x 60) halves both the triangle count and the dot count; the orb
has enough dots to spare after the stipple (section 6).

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

**Option B, the vertex path.** Renders, and after the repair it shows round dots
with gaps. Two things were wrong: the disc was 1.007 x the pitch wide, so
neighbouring dots fused, and the shell is a dense cube-lattice sample (19,200
points, about 9,600 visible in the disc), so at orb size the kept dots land about
one pitch apart and read as a mesh rather than a point cloud. The repair halves
the relative dot radius (0.0135 to 0.0085 against a 0.0268 pitch) and drops a
share of the lattice points with a per-dot hash (`u_stipple`, 0.30).

| orb measure | before | after |
|---|---|---|
| 320 px, peaks @0.35 | 13185 | 4372 |
| 320 px, components / merge | 2161 / 0.164 | 1597 / 0.362 |
| 320 px, component area median, aspect | 4 px², 1.5 | 2 px², 1.5 |
| 224 px, peaks @0.35 | 4755 | 2174 |
| 224 px, components / merge | 2592 / 0.545 | 1328 / 0.603 |

Visual check at 4x (the crops are in `evidence/c2-repair/`): 320 px reads as
isolated round points with dark gaps and no continuous structure; 224 px reads
the same way, with the dots quantised harder because a 224 px orb gives a 3 px
pitch.

What ships: option B, with the dot geometry and stipple above, and this is a
recorded deviation from constraint 4, not an interpretation of it. Option A's
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
  as `value * alpha / 255`. All data textures are written with alpha 255, and a
  byte that must be exact cannot live in a texture with alpha 0. This cost most
  of the spike's debugging time and is the single most likely trap for the next
  card.
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
  the orb. Its dots are also clipped by construction at triangle boundaries
  inside each mesh cell unless the four surrounding quads are all drawn (they
  are, which is why the field is round after the repair); if the mesh resolution
  drops under the dot pitch, corners start to lose dots and the shape goes back
  to dashes. The fragment also does four data-texture fetches per pixel, so its
  cost tracks the triangle count rather than the pixels (section 4).

## 8. Shader packs: exact commands and hashes

One command per pack, run from the repository root, `tools/qsb.sh` defaults
(`--qt6`, targets glsl 100es, 120, 150 plus hlsl 50 plus msl 12), exit 0 each.
These were re-run for this repair, so the hashes below are the packs as
committed on this branch. The hashes recorded in the previous verdict
(`f44feea5...`, `2ff64aa4...`, `05e277cf...`) belong to the packs before the dot
repair and no longer apply.

    tools/qsb.sh nexuslink.hud/v5/kit/shaders/swarm.frag nexuslink.hud/v5/kit/shaders/swarm.frag.qsb
    tools/qsb.sh nexuslink.hud/v5/kit/shaders/swarm_vertex.vert nexuslink.hud/v5/kit/shaders/swarm_vertex.vert.qsb
    tools/qsb.sh nexuslink.hud/v5/kit/shaders/swarm_vertex.frag nexuslink.hud/v5/kit/shaders/swarm_vertex.frag.qsb

    swarm.frag.qsb          db40771043ec6902be358d50b407bb36f0ddf0482967b81e0b162c44f3067016
    swarm_vertex.vert.qsb   8219edece5d0c930c749d736ea58745e90aca42b3d6964c062c09e3219900770
    swarm_vertex.frag.qsb   b7cebe0f1c8d626714a017432ddc1759a46047fe3be776ca9510f59e590cbdd5

The spike-only packs (`spike/shaders/swarm_a.frag.qsb`, `swarm_b.*`,
`swarm_c.frag.qsb`) are not part of what ships and were not rebaked by this
repair.

## What ships

`kit/Swarm.qml` (knot, option A) and `kit/SwarmSphere.qml` (orb, option B path,
see section 6), with `kit/shaders/swarm.frag|.qsb`,
`kit/shaders/swarm_vertex.vert|.frag|.qsb`, `kit/assets/swarm-knot-sdf.png` and
`kit/assets/swarm-orb-grid.png`.

Both components expose `size`, `accent`, `focusLevel`, `activity`, `speed`,
`phase` and `animate`; the orb's `phase` is what Wave 1 uses to run several orbs
out of step, and `animate: false` is what the static stills use to hold a pose.
Wave 1 drives those properties and never touches a shader.

Integration request (the integrator owns `kit/qmldir`):

    Swarm 1.0 Swarm.qml
    SwarmSphere 1.0 SwarmSphere.qml
