# W7 environment: motion and focus evidence

Card: HUD v5 W7 ENVIRONMENT (tanjiro). Files: `kit/Clock.qml`,
`kit/Focus.qml`, `kit/IdleDrift.qml`, plus the tests under `tests/w7/` and the
stills in `docs/w7-stills/`. Qt 6.12.0, `tools/qml-shot.sh` RHI path
(`api=metal`, `capture=readback`), `tools/qml-lint.sh`.

Reproduce everything below from the worktree root:

    nexuslink.hud/v5/tests/w7/run.sh <out-dir>

It sets up the `NexusHud/V5 -> v5/kit` import symlink in a temp dir, lints the
three components, runs the three numeric proofs through `qml`, renders the two
pixel proofs and all stills at 2560x1440.

## 1. Clock: fixed advance width, measured

`Clock` puts every digit in its own `0.62 em` cell and the colon in a
`0.26 em` cell (s1 `build.py:211-212`), and asks Satoshi for tabular figures
(`font.features: {"tnum": 1}`). Width is therefore a function of the string
length, not of the glyphs.

`ClockProof.qml` instantiates two real Clocks in the same box and reports:

    CLOCK time=01:11 implicitWidth=461.000 textWidth=460.320 cells=5
    CLOCK time=18:48 implicitWidth=461.000 textWidth=460.320 cells=5
    CLOCK resting  valid=false implicitWidth=461.000 cells=5
    CLOCK seconds  time=21:47:09 implicitWidth=713.000 cells=8
    CLOCK_CHECK PASS same_width=true resting_same_width=true

460.320 px = 4 x (0.62 x 168) + 1 x (0.26 x 168). Both times are identical to
the thousandth of a pixel, and the malformed-data resting state (`--:--`) keeps
the same width, so the deck never reflows when the feed drops.

Tabular figures are real on this build, not assumed. Four hidden Texts at
168 px, without and with tnum:

    TNUM off 0000=458.938 1111=222.422 delta=236.516
    TNUM on  0000=443.500 1111=443.500 delta=0.000

Satoshi's default figures are proportional (the "1" is 236 px narrower than
"0" over four glyphs); with tnum they are exactly equal. The cells do the
width work and tnum makes each glyph sit identically inside its cell.

Stills: `docs/w7-stills/clock-0111.jpg`, `clock-1848.jpg`.

## 2. Focus: dim, scrim, blur, springs

### What it does

`Focus { active, targetRect, content }` captures `content` once
(`ShaderEffectSource`, `hideSource`), draws one `MultiEffect` copy that is
blurred and dimmed over the whole component, then draws a second
`ShaderEffectSource` cropped to `targetRect` at full opacity on top. The effect
pass only paints pixels the HUD content covers, because the snapshot's alpha is
the content's alpha - the desktop showing through the panel is untouched.

Numbers, all from Tokens: `opacity = Tokens.focusDim` (0.26, inside the
0.18-0.3 band), `colorization = Tokens.focusScrim` (0.35) toward black,
`blurMax = 32`, `blur = Tokens.focusBlur / 32` (10 px at full progress, inside
the 8-12 band). `autoPaddingEnabled: false` so the blur is clipped at the
component edge instead of growing the item.

### Pixel proof

Flat #ff0000 content, 300x200, 100x60 focus rect in the middle:

    dim-proof-active    center=#ff0000 corner=#2b0000
    dim-proof-rest      center=#ff0000 corner=#ff0000
    dim-proof-desktop   center=#101010 corner=#370c0c

- `#2b0000` = 43/255 = 0.169 = 0.26 x (1 - 0.35): the dim opacity and the
  scrim compose exactly as specified, and the centre of the focus rect stays
  untouched #ff0000.
- Rest is untouched: both samples #ff0000.
- `dim-proof-desktop` puts the HUD content in the top-left quadrant, a
  #101010 panel background behind it and the focus rect bottom-right. The
  corner (content) is dimmed; the centre (bare panel, i.e. desktop through the
  panel) is exactly #101010, unchanged. Only HUD content is affected.
- Stills: `dim-active.jpg`, `dim-desktop.jpg`.

### Why no mask

The obvious implementation is a `MultiEffect` with `maskInverted: true` and the
focus rect as mask. On this Qt 6.12 offscreen RHI path the inversion is not
honoured: probes with a visible, layer-enabled white mask (non-inverted and
thresholded at 0.5) mask correctly, while the same setup with
`maskInverted: true` draws the full effect everywhere (`corner=#ff0000`,
`center=#ff0000`, i.e. the mask is ignored). A mask sourced from an invisible
or off-screen provider produces no texture at all. The crisp crop on top is the
measurable equivalent, avoids a shader regeneration at focus time, and behaves
the same for a 112 px widget and a 900x620 card. The still
`focus-active.jpg` uses the large card case.

### Spring trace

`FocusProof.qml` drives the real component: `active: true`, sample
`springProgress` every frame, `active: false` at 900 ms, sample the return.

    FOCUS in   ... peak 1.04272..1.05028 (one sample per frame)
    FOCUS out  ... monotone decay, 1.00000 -> 0.00000 in 408 ms of samples
    FOCUS summary in_peak=1.04272 out_final=0.00000 progress_final=0.00000 effectsVisible=false

- Expand overshoot: the easing's analytic peak is 1.050389, i.e. 5.04 percent
  (OutBack overshoot 1.17), inside the 4-6 percent band and matching
  `Motion.expandOvershoot` 0.05. Peak at 64 percent of the duration, 222 ms of
  347. Sampled runs land between 1.0427 and 1.0503 because a trace can only
  catch the apex on a frame boundary.
- Return: monotone (`monotone=True` over all 20 samples), reaches exactly
  0.00000, and `effectsVisible=false` afterwards, so the content is drawn
  directly again with no residual effect pass. Configured duration 444 ms; the
  sampled run reaches zero 408 ms after the first out sample, the rest is
  frame quantisation.
- Both are `Motion` durations (`expandMillis` 347, `returnMillis` 444) and
  non-linear (OutBack for the expand, `Motion.curveSoftOut` bezier for the
  return). Nothing linear.

### Two implementations rejected by measurement

1. `SpringAnimation` with `Motion`'s zeta/omega: k = omega^2 = 278.9,
   c = 2 * zeta * omega = 23.05. Qt 6.12's spring integrator diverges at that
   stiffness in an offscreen run (sampled values 4.46, -10.99, 42.5, -142.7,
   498.5, 71485.9, ... and then ~1e80). Stable only at low stiffness, where it
   cannot reach 347 ms. The component uses the closed-form equivalent
   (duration + overshoot) at the same Motion numbers, and the trace above is
   the measured result.
2. `MultiEffect.maskInverted` - see above.

## 3. IdleDrift: two sines, irrational ratio, clean stop

`amplitude` px, `period` seconds. Displacement is

    dx = A * g * (0.62 sin(a) + 0.38 sin(b))
    dy = A * g * (0.62 sin(a + 1.13) + 0.38 sin(b + 2.31))

with `b` running at `period * Tokens.phi`. The frequency ratio is the golden
ratio, so the path never closes.

Trace (`IdleProof.qml`, amplitude 2.0, period 2.0 s so several cycles fit in a
short run; the deck defaults are 2 px / 13 s):

    IDLE config amplitude=2 period=2 secondaryPeriod=3.23607 ratio=1.618034 transformsAtStart=2
    IDLE drift ... dx/dy sweep, phase and phaseSecondary advance
    IDLE stop_begin t=8.009 dx=0.17113 dy=0.51747
    IDLE stop_done  dx=0.00000 dy=0.00000 transforms=1
    IDLE restart    dx=0.00000 dy=0.00000 transforms=2
    IDLE summary    transformsEnd=2 dxEnd=-0.49171 dyEnd=-1.87989

- Range over 67 samples, 8 s: dx -1.968..1.889, dy -1.983..1.960, max radius
  1.9914 for amplitude 2.0 (the weights sum to 1, so the bound holds).
- Secondary period 3.23607 s = 2 x 1.618034, ratio exactly phi.
- Non-repeat: after k primary periods the secondary phase has advanced
  k / phi cycles - 0.618, 1.236, 1.854, 2.472 - never an integer, so no two
  primary periods land on the same point.
- Stop: `enabled: false` fades the gain out over the Motion return (444 ms);
  the offset goes 0.517 -> 0.328 -> 0.248 -> 0.077 -> 0.000, the two phase
  animations stop, the phases park at 0 and the target's own transform list is
  restored (2 -> 1 transforms: one Rotation that was there before, and no
  drift Translate). No jump, no residue.
- Restart: `enabled: true` re-appends the Translate (1 -> 2) and drift resumes
  from phase 0.
- `phase` (0..1), `phaseSecondary` and `phaseRadians` are readable properties,
  exposed for the future nano-swarm links; `previewTime` pins both phases for
  stills and traces. Stills at t = 0.6 s and t = 3.4 s show different
  displacements: `idle-a.jpg`, `idle-b.jpg` (amplitude raised to 18 px in the
  still scene only, so the 1-2 px deck drift is visible).

## 4. Lint

    LINT files=3 warnings=0 errors=0 exit=0

`tools/qml-lint.sh nexuslink.hud/v5/kit/{Clock,Focus,IdleDrift}.qml`, Qt
6.12.0. The tests directory lints clean as well: `LINT files=17 warnings=0
errors=0 exit=0`.

## 5. Request for the integrator

`kit/qmldir`, after the Wave 0 singletons:

    Clock 1.0 Clock.qml
    Focus 1.0 Focus.qml
    IdleDrift 1.0 IdleDrift.qml

No new `Tokens` or `Motion` values are needed: every number used already
exists. `Focus` expects to fill its parent (it has no implicit size);
`IdleDrift` may be declared anywhere and only needs `target`.
