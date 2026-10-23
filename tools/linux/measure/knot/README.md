# tools/linux/measure/knot: evidence that the knot breathes locally

Tools plus templates for KNOT-SPEC.md and the wave 2 addendum v2.1
(KNOT-SPEC-ADD.md). Everything is pure numpy and PIL; no GPU is needed except
for the renders. All numbers were measured on this machine on 2026-10-23
(700x700 item, knotPx 540, 1 unit = 0.6 px).

## knot_port.py

CPU port of the vertex stage (spec A to F) at v2.1. Default read path is the
v2 point texture knot-points2-keep.png (the production set, original positions): 5 texels per point, 16 bit xyz, normal, s,
q, cls, then (u, occl, 0) in texel 5, so u drives waves, events and sparks and
occl drives the under-strand dimming (occl2 = clamp(occl * 1.19, 0, 1),
brightness *= 1 - 0.65 occl2, radius *= 1 - 0.25 occl2). `--tex` plus
`--tpp 4` reads the v1 texture instead (u falls back to s, occl = 1).
`motion="base"` reproduces the original commit dacc1c5 model (yaw 30, pitch 18,
scale 2 percent, per lobe phase 0..0.07, no local terms).

v2.1 in the port: lobe centres 34.0, 142.4, 266.4 degrees; slow FM on every
lobe clock (0.06 cycles at 31, 38, 45 s); per point phase offset
0.035 * (hash(pid) - 0.5) cycles; u everywhere on the strand; soft limiter on
the summed local displacement, default `exp` (`lim * (1 - exp(-dl / lim)) / dl`,
what knot.vert ships, L = 0.10 R); `--limit tanh` is the original addendum form.
Both pass M1 at the v4 amplitudes (1.979 and 2.358 px), see KNOT-SPEC-ADD.md item 4.

    python3 knot_port.py --t 1.5 --json

Checked against the GPU shader: compare_gpu.py gave a median nearest neighbour
distance of 1.146 px at t = 0 (p95 2.512) and 1.598 px at t = 3 (p95 2.654),
so the decode, the local terms and the projection all agree with K1b.

## knot_report.py

Metrics M1 to M6 of KNOT-SPEC-ADD.md. 6 s (144 frames) for jumps, the heat map
and coverage; 60 s (1440 frames) for the spectra, Hann window, DC removed,
per arc-length bin (32 bins over u) and for the aggregate series.

    python3 knot_report.py --outdir <dir> --prefix final-
    python3 knot_report.py --motion base --prefix base- --text baseline.txt

Writes <pre>report.txt (PASS or FAIL per metric with the number),
<pre>report.json, <pre>heatmap.png, <pre>series-6s.csv, <pre>series-60s.csv,
<pre>spectrum.csv. Measured v2.1: mean local 5.07 px, peak 10.48 px,
M1 jump 2.298 px PASS, M2 limited peak 4.235 percent of R PASS (raw 7.865,
exp form 3.716), M3 arc cv 0.053 FAIL on the literal time-averaged reading
(per-frame spatial cv 0.364, 15 distinct max bins), M4 1.000 PASS,
M5 aggregate peak 14.9 percent PASS with 10 distinct bin peaks, M6 1.000 PASS.
Verdict 7 of 8; the one failure needs a static spatial envelope, not an
amplitude or period change.

Baseline (original model): zero local displacement everywhere, 2 of 6 criteria.

## render_seq.sh

    tools/linux/measure/knot/render_seq.sh <scene.qml-template> <outdir> [stride]

One process per frame through tools/linux/v5-shot.sh at 700x700, TVALUE
substituted by sed. 6 s at 24 fps, frame i is t = i/24, stride 12 renders 12
frames (t = 0, 0.5 ... 5.5), stride 1 all 144 (about 30 s on the B580).
Writes frames.txt ("t path" per line). Scene templates that import "kit" and
"live" relatively need those symlinks inside the output dir.

## contact_sheet.py

    python3 contact_sheet.py <framesdir-or-frames.txt> <out.png> [cols rows]

4x3 by default, time written under every frame in Satoshi.

## compare_gpu.py

    python3 compare_gpu.py <gpu.png> <t> [--motion v2|base] [--port-png out.png]

Rasterises the port's points as dots and reports the nearest neighbour distance
from every GPU dot centroid to the nearest port dot.

## make_video.sh

    work2/K2/make_video.sh [framesdir] [out.mp4]

Encodes frame-%04d.png at 24 fps with the bundled ffmpeg (libx264, crf 16,
yuv420p). 144 frames give a 700x700, 24 fps, 1.79 MB six second loop.

## Templates

knot-scene-tmpl.qml in work2/K2 is work2/K1/knot-scene.qml with the t property
set to TVALUE, so the same scene renders at any instant.

## v5 additions (round 4, KNOT-SPEC-R4)

knot_port.py mirrors round 4: no yaw, pitch 1.6 deg (71/97 s) and roll 1.6 deg
(83/113 s), a 7 s scale pulse of 0.8 percent peak to peak, lobe clocks at
9/11/13 s, fronts at 11/15 s (ribbon) and 12/16 s (ring) with a 0.10 window,
events in 9/13 s slots with a 3 s rise, curl 0.022 R, and the summed local
limiter at 4 percent of R. Default texture is knot-points4.png (11 texels per
point, 24 rows): texels 0..4 are the round 3 data, 5..7 are form 1 (position in
two texels, normal in the third) and 8..10 are form 2. The port also decodes
the morph schedule (60 s cycle: 33 s hold, 12 s out, 3 s hold, 12 s back) and
the per point stagger from the lobe weights, it negates a baked form
normal that points away from N3 so the blended normal never passes through
zero, and it falls back to er when the dirW sum would be degenerate mid morph
(the shader does the same).

knot_report.py now runs gates R1 to R8 of section 4 and prints, for every gate,
the band the code actually compares against. R8 needs a render (acid share of
bright pixels, lobe luminance ratios, clipped pixels) and prints
SKIPPED_RENDER when no render metrics are supplied; render_metrics.py and
lobe_lum.py fill it in the render run.

    python3 knot_report.py --outdir <dir> --prefix r4-

Gate bands the code compares against (knot_report.py, constants at the top:
R2_MAX_STEP = 1.6 px, R4_MAX_ACC = 0.35 px/frame^2, R3 band [7.0, 10.8] px
peak / [2.0, 5.0] px mean / 9.0 px p99, R5 >= 20 px form 1 and >= 35 px form 2,
hold fraction [0.50, 0.60], R1 4 deg p2p and 0.8 percent at 6 to 8 s, R6 lag
>= 1.0 s, R7 loops 9 to 16 s with ripples 8 to 14 s, R8 acid share < 2 percent
and lobe luminance ratio <= 1.4):

    R1  yaw span 0.000 deg (must be 0), pitch p2p <= 4.0 deg, roll p2p <= 4.0 deg,
        scale p2p <= 0.80 percent with period 6.0 to 8.0 s
    R2  max per frame step of any dot < 1.6 px
    R3  hold windows only: peak local in [7.0, 10.8] px, mean in [2.0, 5.0] px,
        99th percentile <= 9.0 px
    R4  max per frame change of the step vector < 0.35 px per frame squared
    R5  mean screen displacement at x = 1 >= 20 px (form 1), >= 35 px (form 2),
        hold fraction in [0.50, 0.60], weights non decreasing per leg
    R6  pairwise lobe breath lag >= 1.0 s and three distinct periods
    R7  every wave loop in [9, 16] s, ripple slots in [8, 14] s
    R8  acid share of bright pixels < 2 percent, lobe luminance ratio <= 1.4,
        clipped pixels about 0 (render metrics only)

Measured on 2026-10-23 on the final knot-points4.png (sha1 bc15e194, 120 s at
24 fps, exp limiter, L = 4 percent of R, runtime 11.8 s): R1 pass (yaw 0.000,
pitch 3.122, roll 2.983 deg p2p, scale 0.800 percent at 7.0 s), R2 pass
0.9372 px, R3 pass (peak 9.450 px, mean 3.501 px, p99 7.314 px), R4 pass
0.1131 px/frame^2, R5 pass form 1 25.998 px and form 2 41.504 px, hold 0.6000
(0.6014 counted on the frame grid), weights monotone, R6 pass (lags 217.3 /
165.8 / 132.9 s), R7 pass (11/15/12/16 s loops, 9 and 13 s ripples), R8
SKIPPED_RENDER. Verdict PASS, 13 pass, 0 fail.

### R4: what the acceleration gate caught

The first round 4 run failed R4 at 0.3906 px/frame^2 on one ring dot at
t = 56.17 s (the second png moved it to 0.4720 at t = 56.29 s), while the next
largest frame was 0.336 and the p99 was 0.0139. The probe (work3/B2/
probe_r4c.py) isolated it to the curl term D: that dot's curl displacement sat
exactly on the curl cap (R * 0.025 = 11.25 units, a hard plateau) for five
frames and the cap released in one frame, so the term's own acceleration was
0.905 px/frame^2 while B, C, E and the morph together were under 0.02. About
half of all dots sit on that plateau, because the curl field is driven 4 to 5
times past the knee. The old saturation was an exponential soft cap,
`dlim * (1 - exp(-dl0/dlim))`, which still has a 1.4 percent slope at 4x the
knee, so where the curl field dips near a critical point the plateau ends in a
one frame step in speed.

Fix: saturate with tanh instead, `dlim * tanh(dl0/dlim)` (written as
1 - 2/(exp(2u)+1) in both knot.vert and knot_port.py so the two agree to
float precision). tanh's shoulder is 35 times flatter at 4x the knee and has no
corner anywhere. R4 went 0.3906 -> 0.1131 and R3 stayed in band (peak 9.472 ->
9.450 px, mean 3.706 -> 3.501 px): the curl's working point is unchanged, only
the kink at the edge of the plateau is gone. This was a limiter kink, not a
position discontinuity: no dot ever jumps, the step vector changes by less
than 1 px per frame and the total step is 0.94 px.

### Why the round 3 numeric targets are withdrawn

Marcel: "The knot is now moving too much, it must be soft and gentle and its
missing the morphing animations, less swaying left/right that looks weird."

The old targets were assistant defaults, not numbers Marcel ever asked for:
20 to 26 px local peaks came from the round 2 brief, the M7 band 9.0 to 12.5 px
mean and 19.0 to 27.0 px peak were derived from it, M1 (jump < 2.5 px) and
M2 (local peak < 10 percent of R) followed the same amplitude, and M8/M9 were
invented in round 3 to describe the bulge and the lobe breathing. They all
gate on how MUCH the knot moves and on how fast the side to side sway goes,
which is exactly what Marcel rejected. Round 4 replaces them:

- yaw is gone entirely (R1 pins the span to 0, the old M1 only capped the
  step it caused), so there is no left/right sway left to be "too much"
- the local motion is gated by a band that is now the design intent, not a
  borrowed default: R3 asks for 7 to 10.8 px peak and 2 to 5 px mean in the
  hold windows, which is the 40 percent reduction the spec asks for; the old
  M7 band would FAIL round 4 by design
- R2 and R4 gate smoothness instead of size: no dot may step more than 1.6 px
  in a frame and the per frame displacement may not change by more than
  0.35 px per frame squared, so "gentle" is a property of the curve, not of an
  amplitude
- R5 is new and gates the thing that was missing: the morph must actually
  travel (>= 20 px for form 1, >= 35 px for form 2), must hold 50 to 60 percent
  of the time and must be monotone per leg
- R6 and R7 pin the time structure (lobe lags >= 1 s, loops 9 to 16 s,
  ripples 8 to 14 s) so a slow, wide motion cannot be faked by shrinking
  amplitudes
- R8 keeps the render gates of round 3 (acid share, lobe luminance, clipping)
  because they are about the picture, not about the motion amount

## v4 additions (repair round 3)

- knot_report.py: M8 (bulge peak px of the front term C, measured as full sum minus
  sum without C, both after the limiter, >= 14 px) and M9 (ribbon width swing per
  lobe over 6 s, >= 25 percent). M7 text now prints the band it gates on.
- lobe_lum.py: mean and p95 luma and clipped fraction per lobe of a render.
- crest_map.py: samples the render luminance at the port's projected points per arc
  bin and frame; prints the crest bin per frame and the correlation with the port.
- bulge_strip.py: render next to the same render with the port's bulge points ringed.
- contact_sheet.py: SHEET_CELL=500 makes bigger tiles.
