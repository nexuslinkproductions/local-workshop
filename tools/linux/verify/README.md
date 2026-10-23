# verify: full bleed HUD proofs

Two pieces, both read only against the live session:

- `verify-bleed.sh [output]` (default `DP-2`) checks the layer geometry with
  `hyprctl layers -j` + `hyprctl monitors -j`, captures the output with
  `grim -o <output>` into a private temp png, and runs `crop_check.py` on it.
- `crop_check.py <png> --bar 26 --field 06080a --edge 8` checks four edge
  strips of a capture: rows `bar..40` (the 26 px bar is excluded), columns
  `0..8`, columns `w-8..w`, rows `h-8..h`.

## Exact commands for the parent (live session, after the plugin install)

    tools/linux/verify/verify-bleed.sh DP-2

Expected on success:

    monitor DP-2: 2560x1440 at 0,0
    nexuslink-hud: level=0 x=0 y=0 w=2560 h=1440
    PASS  hud at 0,0
    PASS  hud width 2560 equals monitor width
    PASS  hud height 1440 equals monitor height
    omarchy-bar: level=2 x=0 y=0 w=2560 h=26
    PASS  omarchy-bar on level 2
    PASS  no omarchy-background layer on DP-2
    ... crop_check: VERDICT: PASS (4 of 4 strips)
    VERDICT: PASS (DP-2)

Useful variants:

    tools/linux/verify/verify-bleed.sh --dry-run DP-2     print commands, run nothing
    KEEP=1 tools/linux/verify/verify-bleed.sh DP-2        keep the capture, prints its path
    tools/linux/verify/verify-bleed.sh --image shot.png   analyse an existing capture (no hyprctl, no grim)
    python3 tools/linux/verify/crop_check.py shot.png --bar 26 --field 06080a --edge 8

Exit codes: 0 every check passes, 1 a check failed, 2 usage or tool error
(no hyprctl, no jq, no grim, unreadable image).

The script never changes compositor state: it only reads `hyprctl`, and `grim
-o` grabs one output. Layers are matched by namespace, not by address:

- `nexuslink-hud` must exist on the output with `x=0 y=0 w=<monitor w>
  h=<monitor h>`. A height below the monitor height means the exclusive zone
  is still applied (`ExclusionMode.Auto`).
- `omarchy-background` must be absent on the output, or it is reported as
  `WARN ... covered by map order` when its level is below the HUD level, or
  on the same level at a lower index (drawn first, under the HUD). Any other
  case is a FAIL.
- `omarchy-bar` must be on level 2.

`crop_check.py` per strip: share of pixels within 6 per channel of the field
colour (pass at 99.5 percent or more), mean colour, mean absolute difference
to the same strip of the wallpaper scaled to the capture size, and the
wallpaper's own distance to the field. A strip passes only if the field share
passes and it does not match the wallpaper (MAD above 8). When the wallpaper
itself is within 8 of the field colour at that strip the wallpaper arm prints
`wallpaper=n/a`: no pixel test can separate the two there, and the layer
geometry is the proof instead.

## What is proven, and how (VA finding 3)

- Top strip: by pixels. `crop_check.py` has detection power only there. The
  current wallpaper differs from the field colour only in the top strip.
- Left, right and bottom: by geometry only, not pixels. `wallpaper=n/a` on
  those strips means the wallpaper is within 8 of the field colour there, so a
  pixel pass says nothing about the wallpaper at those edges.
- Geometry (every edge): `hyprctl layers -j` gives `nexuslink-hud` (or
  `nexuslink-hud-v5`) on the output at layer origin x=0 y=0 with w and h equal
  to the monitor size, and no `omarchy-background` surface left above it.

## Geometry mode (no pixels, no grim)

    tools/linux/verify/verify-bleed.sh --geometry [output]
    tools/linux/verify/verify-bleed.sh --geometry --layers-json F --monitors-json G [output]

- Live by default (`hyprctl layers -j`, `hyprctl monitors -j`; a non JSON first
  line is stripped). The fixture flags read files instead, for tests.
- Per output one line, `PASS` or `FAIL`, with the numbers it read. Without an
  output name every monitor is checked and a monitor with no HUD layer is
  `SKIP`; with a name, a missing HUD layer is `FAIL`.
- Exit 0 all PASS, 1 a FAIL, 2 usage or unreadable JSON.

Fixtures in `fixtures/`:

    verify-bleed.sh --geometry --layers-json fixtures/layers-good.json --monitors-json fixtures/monitors-dp2.json     # exit 0
    verify-bleed.sh --geometry --layers-json fixtures/layers-bad-y26.json --monitors-json fixtures/monitors-dp2.json  # exit 1

`layers-bad-y26.json` is the shape from before the fix (HUD at y=26, h=1414,
wallpaper above it).

## Hud ready marker

`hud-ready-marker.patch` (against ff0fefe, `nexuslink.hud/v4/HudV4.qml`) adds
the readiness marker that the background clone needs before it removes the
wallpaper (see nexuslink.background/README.md). It is a patch, not applied
here: HudV4.qml belongs to another lane.

## Measured fact: the current wallpaper is nearly the field colour

`~/.local/state/omarchy/current/background` resolves to
`/home/nexuslink/.config/omarchy/nexuslink/hud-bg.png` (5120x1440, mean
`#03070b`, min 1, max 48). Mean absolute difference to the field `#06080a` at
the audit strips: top 2.81, left 4.61, right 4.98, bottom 2.82. At left and
right 100 percent of wallpaper pixels are already within 6 of the field; at
top and bottom 97.8 and 98.0 percent. Consequence: a wallpaper border in the
dark left, right or bottom edges is pixel indistinguishable from the field,
so `crop_check.py` cannot see it and the `hyprctl` geometry assertion is the
only reliable proof there. The top strip is the one place with a detectable
difference (2.2 percent of wallpaper pixels outside tolerance).

## Self test transcript

Images synthesized by `work3/A3/make-test-images.py` (2560x1440, field
`#06080a`, 26 px bar `#181e24`, widget blocks in the middle; the fail images
paste real wallpaper pixels). Log: `work3/A3/selftest.log`.

    $ python3 crop_check.py pass.png --bar 26 --field 06080a --edge 8
    image: pass.png (2560x1440)
    field: #06080a tol=6 pass_share>=99.50% wallpaper_mad>8.0
    top    x=0..2560 y=26..40 share=100.00% mean=#06080a wallpaper_mad=  2.81 wp_field_mad= 2.81 wallpaper=n/a PASS
    left   x=0..8 y=26..1440 share=100.00% mean=#06080a wallpaper_mad=  4.61 wp_field_mad= 4.61 wallpaper=n/a PASS
    right  x=2552..2560 y=26..1440 share=100.00% mean=#06080a wallpaper_mad=  4.98 wp_field_mad= 4.98 wallpaper=n/a PASS
    bottom x=0..2560 y=1432..1440 share=100.00% mean=#06080a wallpaper_mad=  2.82 wp_field_mad= 2.82 wallpaper=n/a PASS
    VERDICT: PASS (4 of 4 strips)                                   exit 0

    $ python3 crop_check.py fail-top.png --bar 26 --field 06080a --edge 8
    top    x=0..2560 y=26..40 share= 97.82% mean=#03060a wallpaper_mad=  0.00 wp_field_mad= 2.81 wallpaper=n/a FAIL (field share 97.82% < 99.50%)
    left/right/bottom PASS
    VERDICT: FAIL (1 of 4 strips)                                   exit 1

    $ python3 crop_check.py fail-left.png --bar 26 --field 06080a --edge 8
    left   x=0..8 y=26..1440 share=100.00% mean=#040709 wallpaper_mad=  3.19 wp_field_mad= 4.61 wallpaper=n/a PASS
    VERDICT: PASS (4 of 4 strips)                                   exit 0

The last one is the documented limitation, not a bug: 3 px of real wallpaper
from the dark left edge (mean `#040709`) are inside the 6 per channel
tolerance of the field, so a colour test cannot flag them. Use the bright
variant, 3 px taken from the wallpaper's brightest block, for a failing case:

    $ python3 crop_check.py fail-left-bright.png --bar 26 --field 06080a --edge 8
    left   x=0..8 y=26..1440 share= 99.31% mean=#05080c wallpaper_mad=  4.85 wp_field_mad= 4.61 wallpaper=n/a FAIL (field share 99.31% < 99.50%)
    VERDICT: FAIL (1 of 4 strips)                                   exit 1

Old captures, reported for reference only (scaled, not 2560x1440):

    live-dp2.jpg (1600x900)       VERDICT: FAIL (4 of 4 strips), shares 87.28 / 84.71 / 97.48 / 97.28
    live-user-1280.png (1280x738) VERDICT: FAIL (2 of 4 strips), left 99.86, right 84.76, bottom 84.60

`verify-bleed.sh` was exercised against the live compositor without capturing
(geometry block, grim hidden from PATH) and correctly reports the current,
not yet fixed state:

    monitor DP-2: 2560x1440 at 0,0
    nexuslink-hud: level=0 x=0 y=26 w=2560 h=1414
    FAIL  hud not at 0,0 (x=0 y=26)
    PASS  hud width 2560 equals monitor width
    FAIL  hud height 1414 != monitor height 1440 (exclusive zone still applied?)
    omarchy-bar: level=2 x=0 y=0 w=2560 h=26
    PASS  omarchy-bar on level 2
    omarchy-background: level=0 x=0 y=0 w=2560 h=1440
    WARN  omarchy-background present on DP-2 at level 0 (hud level 0); covered by map order
    verify-bleed: grim not found                                        exit 2

That is the same geometry the lead measured: the HUD starts below the 26 px
bar. After the fix the first two FAIL lines must turn into `y=0` and
`h=1440`, and the background line into `PASS no omarchy-background layer`.

`verify-bleed.sh --image pass.png` returns `VERDICT: PASS (DP-2)`, exit 0;
`verify-bleed.sh NOPE-1` returns `FAIL monitor NOPE-1 not found`, exit 1.
