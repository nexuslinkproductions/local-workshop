# Knot silhouette against s2 (W1)

Status 2026-10-23, repair round 2 (executive round-3 ruling): **`Knot.qml` ships
with the trace fitted to s2, and the gate is the executive's ruling R2:
`band_iou >= 0.72` and `silhouette_iou_blur6 >= 0.53`, both on the 540 s2 knot
crop.** The written 0.90 is out of reach for a dot-field render of this
reference: no ring-free render can score above 0.8656 here, and the dot fill
costs the rest (below), so chasing 0.90 would mean thickening dots into tiles,
which the visual law forbids. The deviation is recorded here per R2.

Round 2 adds one measured change to the render: the rest dot field is dimmer.
It read V 0.831 against s2's 0.609 with C2's dot colour at `gain` 1.45, which
clipped most of the near side to white; it now reads V 0.632 with the brightness
run between two shader uniforms (Palette, below). The trace, the bake, the
scatter, the dot pitch and the stipple are unchanged.

Every number below is reproduced by one script, `tools/knot-iou.py`, with the
commands at the end.

## Headline numbers

| what | value |
|---|---|
| gate: `band_iou` at rest | **0.7304** (bar 0.72) |
| gate: `silhouette_iou_blur6` at rest | **0.5338** (bar 0.53) |
| shipped asset's own level set vs the s2 crop band | 0.8149 |
| the most any ring-free render can score on this crop | 0.8656 |
| render at rest vs its own trace | 0.8276 |
| dot coverage at rest | 0.0673 against the reference's 0.1153 |
| bright-pixel mean at rest (luminance > 0.35, 14,473 px) | RGB (109,151,161), V **0.632**; B >= G > R 100.0%; hue 170-230 deg 100.0%; lime 0.0% |
| rest vs `assembling: true, assembleProgress 1.0` | 0 of 291,600 crop px differ |

## Reference and crop

`hud-candidates/comp-r1/s2/s2-rest.png`, 2560x1440, the approved design (s2 wins
over s1 per `MAIN-SCREEN-BUILD.md`).

Crop: **540x540 at x=1010, y=280**, i.e. centred on `Tokens.centreX` 1280 and
`Tokens.goldenY1` 550, one knot box at 1:1. In that crop, at the meter's 0.10
luminance threshold, s2's knot plus its ring occupy 33,633 px (coverage 0.1153),
and 16,291 px (0.0559) at the 0.35 core threshold.

The still is not black: s2's page background is #0a0f1c (luminance 0.057), so
`--thr 0.10` sits 1.8x the background and the meter stays insensitive to it.

## Meters

Both on luminance, both after one translation search (+-12 px, step 2, then +-1
refine), because the Knot item is centred in its own 540 px frame:

| meter | definition | what it answers |
|---|---|---|
| `band_iou` **gate** | threshold at 0.10, 9 px morphological closing (dots merge into strand bands), IoU | is this the same knot shape |
| `silhouette_iou_blur6` **gate** | threshold at 0.35, 6 px box blur, threshold the blur at 0.02, IoU (the C2 verifier's `score.py` meter) | same as before, but dot-phase and dot-brightness sensitive |

`band_iou` is the headline because a dot swarm of a different lattice can never
put the same pixels in the same places as the reference. The blur6 number stays
for comparability with C2 (0.260 on the old render).

## The trace, fitted to s2

The previous run measured the s2 *cloud* (`hud-candidates/comp-r1/s2/src/knot/
knot3d.json`, 4384 points) through s2's own renderer and found it ceilings at
**0.766 band** against this crop: the still disagrees with its own cloud by 10 to
20 px in the lower-right lobe, so no transform fixes it (sweeps over pose,
camera, anisotropy and an affine ICP are in the run-1 history of this file).
That is why this run re-traces the knot from the still, as the card says.

`tools/knot-iou.py trace` builds the strand band like this:

1. `lum > 0.10`, then a 9 px closing: s2's dots (926 of them, median 14 px each)
   merge into continuous strand bands.
2. A **7 px opening**. s2's knot is not only the ribbon: its own README says the
   mark is 9 filled pieces, **6 thick ribbon + 3 thin ring**, and the ring is
   dotted about five times more sparsely. Its arcs are 2 to 8 px thick and the
   closing attaches parts of them to the knot, so the opening drops them. At 5 px
   one 10 px wide ring strip survives on the far left (x 23..34, y 280..340) and
   renders as a stray dotted crescent, which is a "no rings" violation; 7 px
   removes it and costs 0.004 `band_iou`.
3. A radial cut at r <= 276 px, the gap between the outermost lobe tip (260 px
   from the crop centre) and the ring beyond it.
4. Components under 2,000 px (background grain) are dropped. The knot itself is a
   single 50k px blob, so the floor never touches the mark.

The result is a 50,416 px band: bbox x 28..506, y 9..493, strand half width
**13.04 px** (median signed distance on the medial ridge; the 2A/P estimator says
25.6 px because crossings and lobe tips are thicker than a strand and inflate it,
so the ridge number is the strand).

The bake then writes `kit/assets/swarm-knot-sdf-s2.png` (1024x1024):

- **R** = distance to the band's centre lines, G = 1.0 so the renderer's ring
  channel can never hit, A = 255 because Qt premultiplies image textures,
- **B** = distance to the nearest dot of the **scattered cloud** the startup
  sequence begins from (see Assembly), same units.

Numbers that fall out of the trace and are hardcoded in `Knot.qml`:

- Swarm's tube radius is a fixed 0.05640288 unit, so the renderer needs
  **231.16 px per unit** for that tube to be 13.04 px wide,
- therefore a 540 px `Knot` drives a **770.5 px** `Swarm`. The overhang is empty:
  the shader writes `vec4(0)` outside the tube,
- the lobe tip lands at 1.25 units, inside the shader's 1.34 unit march bound and
  inside the 1.45 unit texture.

The shipped asset's own level set (with a 1 px silhouette offset, see the sweep)
scores **0.8149** against the reference band, and the plain traced band scores
0.8656. The second number is the ceiling; the first is what the shader is told to
produce.

**Keep `pxPerUnit` in sync.** A 1.5% mismatch between the bake's px-per-unit and
`Knot.qml`'s cost 0.09 `band_iou` when it happened by accident, because a uniform
1.5% scale error moves every edge by 4 px.

**The default asset is never re-baked.** `kit/assets/swarm-knot-sdf.png` is C2's
file and stays byte-identical to `d0e9268` (sha256 `f3cb7e33…`); the s2 trace
ships beside it as `swarm-knot-sdf-s2.png` and `Knot` passes it through Swarm's
`sdfSource`.

## Why 0.90 is out of reach, and what the gate is

s2's reference band is 58,246 px after the same closing. The triquetra trace is
50,416 px of it. The remaining **7,830 px (13.4%)** are s2's ring: 2,597 px beyond
the r 276 cut, plus ring arcs inside it that the opening and the component floor
remove. The card says the Knot has **no rings**, so a spec-compliant render cannot
draw them, and

    50,416 / 58,246 = 0.8656

is the highest `band_iou` any ring-free Knot can reach against this crop, even if
its still reproduced the traced band exactly, pixel for pixel.

The render lands at 0.7304, so the rest of the gap is the renderer, not the
geometry (render vs its own trace: 0.8276). Two measured causes, both bounded by
the visual law:

1. **No glow means sparse dots.** s2's dots carry a soft halo, so its band reads
   58% covered at the meter's threshold. Swarm draws hard round discs at a 0.48
   pitch ratio (C2's repair: discrete points with dark gaps). At that ratio the
   discs cover a third of the band at 0.10, so the closed band comes out about
   1.2 px narrower per side than the geometry.
2. **The lobe tips.** The band is 40 px wide at the top lobe's apex, but the
   tube's height above the plane goes to zero as the band narrows, so the dots at
   the tips are the dimmest and the first to fall under the threshold.

Ruling R2 therefore sets the gate at **0.72 band and 0.53 blur6**, which this
build meets at 0.7304 / 0.5338. Do not chase 0.90 by thickening dots into tiles.

## Palette (R3) and dot brightness (E-4)

s2's knot is azure to ice; `Tokens.acid` is a state colour, not the rest colour.
`Knot.accent` defaults to **`Tokens.ice` (#8fd8e8)**, and the shader's depth mix
darkens the far dots toward azure (0.72 x) and lifts the cores toward white,
which is the s2 range. `accent` stays a property, so the integrator can push acid
for a focus or assemble cue.

Bright pixels at rest (luminance > 0.35, 14,473 px), mean RGB **(109,151,161)**,
**V 0.632**, **B >= G > R 100.0%**, **hue in the 170-230 degree window 100.0%**,
**lime 0.0%**. The s2 crop reads (93,137,152), V 0.609, on its own 16,291 bright
px: B >= G > R 94.8%, hue window 94.9%, and 3.1% lime, which is its ring. Both
shares are reported because they are different meters: "azure/ice" is the
B >= G > R share, and the hue window is the one that would catch a colour
drifting out of s2's ramp. The pre-repair build measured 96.8% and 90.3%, so the
old label "96% azure/ice" named neither cleanly. Lime is 0.0% under both.

Brightness (E-4): C2's dot colour at `gain` 1.45 clipped most of the near side to
white, so the rest frame read **V 0.831** against s2's 0.609. The dot field now
runs between two shader uniforms, **`brightFloor` 0.72 and `brightTop` 0.86, at
`gain` 1.0**, i.e. the depth shading's two ends, both defaulted in `Swarm.qml` to
C2's 0.55 / 1.0 so the shipped Swarm frame stays byte-identical. `dotRadius` is
raised 0.0086 -> 0.0092 unit (1.99 -> 2.13 px, 0.48 x the 4.41 px pitch, still
inside its cell) to carry the 0.35-luminance core that the dimmer dots lose to
the shader's anti-aliasing ramp; `silhouette_iou_blur6` thresholds that core, so
without it the gate drops to 0.5265.

The measured ladder (rest crop, the same meters as the gate):

    gain floor top  dotR    band_iou  blur6   bright V
    1.45 0.55  1.00 0.0086  0.7218    0.5346  0.831   round 2
    1.00 0.55  1.00 0.0086  0.7200    0.5295  0.678
    1.00 0.70  0.80 0.0086  0.7210    0.5265  0.601
    1.00 0.70  0.80 0.0092  0.7301    0.5314  0.610
    1.00 0.72  0.86 0.0092  0.7304    0.5338  0.632   SHIPPED

The price of the dimmer field is the dot footprint: coverage at 0.10 rises from
0.0623 to **0.0673 (+8%)**, because the compensating radius widens the disc that
the meter sees, and `band_iou` follows it up (the closed band is closer to s2's
now). Dot pitch, stipple, dot count, scatter, trace and geometry are unchanged.
Swarm's own defaults are untouched.

## Breath (R5, was F8)

Swarm's ambient motion is one 5.5 s cycle, and `breathSkew` says where in it the
motion turns around. `Knot` passes **0.4**, so the knot runs out in **2.2 s** and
back over **3.3 s** (40/60) on the shipped sine shape; Swarm's default 0.5 is the
untouched symmetric sine, so no existing caller changes. The warp is in time, not
in the wave, which is why the phase-0 pose (yaw 0, tilt 0.0401 rad) is unchanged
and the stills stay comparable with s2.

## Assembly (R4)

The plan asks for "the knot assembles from scattered points". The scatter is baked
into the asset's **B channel**: `tools/knot-iou.py trace` lays 1,659 dots on the
traced band at a 5.5 px pitch and moves each one by a hashed offset of up to
**28 px** (seed 17). That distance field is what the shader blends:

    dist = mix(sqrt(B^2 + z^2) - R_SCATTER, tube, assembleProgress)

At 0 the marched surface is the scattered cloud, at 1 it is the traced tube, and
the branch is skipped entirely at 1 so the rest frame is untouched. `R_SCATTER`
is 0.010 unit = 2.3 px, the size of a settled dot (2.1 px).

Why a blend and not a per-dot displacement: a fragment of a raymarched surface
only exists where the ray hits the surface, so a dot displaced further than its
own radius has nothing left to draw it — the run-2 attempt (a 0.34 unit = 38 px
per-cell displacement) rendered a black frame at 0.3. Warping the sampled field
per cell breaks the Lipschitz bound the sphere trace needs. A blend of two
1-Lipschitz fields is 1-Lipschitz, so the march stays valid and the surface
morphs continuously from the cloud into the tube.

Measured on the 540 crop (lit px at the 0.10 threshold, bbox, gate numbers):

| state | lit px | bbox | `band_iou` | `blur6` |
|---|---|---|---|---|
| progress 0.0 | 15,855 | x 9..526, y 30..505 | 0.4242 | 0.4343 |
| progress 0.3 | 22,271 | x 26..505, y 21..492 | 0.6968 | 0.5631 |
| progress 0.6 | 22,882 | x 30..505, y 30..492 | 0.7423 | 0.5555 |
| progress 1.0 | 19,637 | x 30..505, y 34..492 | 0.7304 | 0.5338 |
| rest (`assembling: false`) | 19,637 | x 30..505, y 34..492 | 0.7304 | 0.5338 |

At 0 the cloud is 28 px wider than the settled mark on each side and its `band_iou`
is 0.42: the shape is not there yet. The intermediate states carry more lit px
than rest because blending the two fields swells the surface before it settles;
the count returns to 19,637 at 1.0. Rest and progress 1.0 are byte-identical
(0 of 291,600 crop px differ).

## Default Swarm frame (R1, was F2)

The properties W1 adds to `Swarm.qml` (`sdfSource`, `assemble`, `gain`,
`brightFloor`, `brightTop`, `dotRadius`) and `breathSkew` all default to the
shipped values, the shader's assemble branch is skipped at `u_assemble = 1`, and
the default asset is untouched. Proof, not assertion: `static/swarm-still.qml`
rendered at 720x720 on `d0e9268` and on this head differs in **0 of 518,400 px**
(max delta 0), and the two PNGs are byte-identical (sha256 `0004e8cf…`).

## Sweeps (run-2 build: acid accent, gain 1.28, each with `pxPerUnit` synced)

    variant                        band_iou   cut    blur6
    opening 5, offset 0             0.7142   0.7467  0.5541
    opening 7, offset 0             0.7112   0.7436  0.5387
    opening 9, offset 0             0.7085   0.7409  0.5328
    opening 5, offset 1             0.7260   0.7582  0.5481  (keeps the ring strip)
    opening 5, offset 2             0.7084   0.7382  0.5338
    opening 5, offset 0, gain 2.2   0.7197   0.7524  0.5591
    opening 7, offset 1     SHIPPED 0.7218   0.7539  0.5327

These rows are the parameter sweep as measured before the palette change; the
round-2 ice build moved the shipped row to 0.7218 / 0.5346, and the round-3
brightness to 0.7304 / 0.5338 (see Palette). The 1 px silhouette offset is the
measured compensation for the dot inset and is the reason the shipped row beats
the other ring-free rows. Larger offsets lose, because dilating the silhouette
also dilates the enclosed holes and the reference has none there. Gain 2.2 would
add +0.0055 but brightens every dot toward solid; C2's 1.28 is kept as the Swarm
default, and `Knot` now dims through `brightFloor` / `brightTop` rather than
gain. Opening 5 with offset 1 scores 0.004 higher than the shipped row but leaves
the ring strip in the still, so it is not shipped.

## Stills

`docs/knot-stills/`, 2560x1440 deck frames and 540 crops, JPEG, 44-71 KB each:

| state | deck | crop |
|---|---|---|
| rest (`assembling: false`) | `docs/knot-stills/knot-rest-deck.jpg` | `docs/knot-stills/knot-rest-540.jpg` |
| progress 0.0 | `docs/knot-stills/knot-a00-deck.jpg` | `docs/knot-stills/knot-a00-540.jpg` |
| progress 0.3 | `docs/knot-stills/knot-a30-deck.jpg` | `docs/knot-stills/knot-a30-540.jpg` |
| progress 0.6 | `docs/knot-stills/knot-a60-deck.jpg` | `docs/knot-stills/knot-a60-540.jpg` |
| progress 1.0 | `docs/knot-stills/knot-a100-deck.jpg` | `docs/knot-stills/knot-a100-540.jpg` |

Side by side, like for like (s2's 540 crop left, the render's 540 crop right, the
same crop box, 1:1): `docs/knot-stills/knot-vs-s2.jpg`.

Side by side against the reference the R2 ruling names,
`hud-candidates/comp-r1/s2/s2-knot-frame.jpg`: `docs/knot-stills/knot-vs-s2-frame.jpg`.
Both panels are 720x720 and the bright knot (luminance > 0.35) is **389 px wide =
54.0% of the frame in each**. The s2 panel is that file as it ships. The render
panel is `knot-rest-deck.jpg` cropped to 874x874 around the knot's bright bbox
centre and resampled to 720 (0.824x), so the knot lands at the same size in the
same-sized panel; its own deck frame has the knot at 476 px in 2560x1440. The
reference frame carries s2's dotted ring and sits on black, the Knot has no ring
by spec and sits on the deck's `#0a0f1c`.

## Reproduce

From the worktree root, Python 3 with PIL only — **no numpy**; the tool is stdlib
plus PIL and reproduces the previous numpy build's **fit numbers** exactly: the
same input gives band 50,416 px, strand half width 13.04 px, 231.16 px per unit,
a 770.5 px Swarm and the 0.8149 level-set IoU. The texture it bakes is not the
pre-scatter one: `trace` also writes the scatter channel into B, so the documented
bake is `kit/assets/swarm-knot-sdf-s2.png` at sha256
**`c7f17c93a74c6baa135a68bd5796d2ccfa7f186fd766d02022ad619f5262231e`**, byte for
byte the committed asset. (The pre-scatter bake of `d7616bd` was `67df623f…`; its
B channel is zero, so it cannot carry the assemble scatter.)

    # 1. bake the trace + scatter into the knot's own asset and print the fit
    /usr/bin/python3 tools/knot-iou.py trace \
        --out nexuslink.hud/v5/kit/assets/swarm-knot-sdf-s2.png

    # 2. render + measure one state (writes <prefix>-deck.jpg and -540.jpg/.png)
    /usr/bin/python3 tools/knot-iou.py still --rest --out /tmp/knot-rest
    /usr/bin/python3 tools/knot-iou.py still --progress 0.0 --out /tmp/knot-a00
    /usr/bin/python3 tools/knot-iou.py still --progress 0.3 --out /tmp/knot-a30

    # 3. measure any still against the crop, gated at both R2 bars
    /usr/bin/python3 tools/knot-iou.py measure <still.png>

    # 4. the s2 cloud's own ceiling (why the trace is fitted to the still)
    /usr/bin/python3 tools/knot-iou.py ceiling --t 21.5

`trace` prints the band, half width, px-per-unit, Swarm size, the level set's
predicted IoU and the scatter cloud; `measure` prints `band_iou`,
`silhouette_iou_blur6`, both coverages and the translation it found, and exits 1
below `--min-band` (default 0.72) or `--min-blur` (default 0.53), so one command
gates the card on both R2 bars. The defaults are the shipped
configuration (threshold 0.10, closing 9, opening 7, r_max 276, 2,000 px floor,
1 px silhouette offset, scatter 5.5 px pitch / 28 px offset / seed 17). The stills
on this card were made with `--rest` and `--progress 0.0/0.3/0.6/1.0` at the
default 2560x1440 deck frame; the 540 crop is taken at x=1010, y=280.

## Files this card touches

- `nexuslink.hud/v5/kit/Knot.qml` (new, this card's)
- `nexuslink.hud/v5/kit/assets/swarm-knot-sdf-s2.png` (new: R tube, B scatter;
  C2's `swarm-knot-sdf.png` is untouched)
- `nexuslink.hud/v5/kit/Swarm.qml` — seven added properties, all defaulted to the
  shipped values: `sdfSource`, `assemble`, `gain`, `brightFloor`, `brightTop`,
  `dotRadius`, `breathSkew`
- `nexuslink.hud/v5/kit/shaders/swarm.frag` + `swarm.frag.qsb` (the assemble
  blend, skipped at `u_assemble = 1`; the dot brightness floor and top as
  uniforms, defaulted 0.55 / 1.0)
- `nexuslink.hud/v5/docs/knot-stills/*` (evidence, including both side-by-sides)
- `tools/knot-iou.py`, this file
