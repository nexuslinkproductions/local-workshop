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
the summed local displacement, default `tanh` (the addendum form),
`--limit exp` reproduces the `lim * (1 - exp(-dl / lim)) / dl` variant that
the shader used in wave 1.

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
