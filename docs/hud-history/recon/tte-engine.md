# ttfx / TTE engine study (condensed from scout lane 2c1305c6)

Source lane evidence: docs site chrisbuilds.github.io/terminaltexteffects (engine/basecharacter,
engine/motion/*, engine/animation/*, engine/eventhandler, engine/utils/gradient, effects/*),
github.com/omacom-io/ttfx (parity port of TTE v0.15.0, byte-identical frames). Raw .py sources were
not fetched; effect-internal defaults not echoed in docs are UNKNOWN.

## Engine model
- Each glyph is an EffectCharacter with a home coord (input_coord), a Motion and an Animation.
- Motion: Paths of Waypoints (optional bezier control points), `speed` in cells per frame, optional
  `ease` over the WHOLE path distance, `hold_time`, `loop`. Activating a path inserts an origin
  segment from the current position, so mid-flight re-targeting still lands. Position = eased
  distance along a polyline, not eased time between two points.
- Animation: Scenes of Frames, each frame held N ticks; scenes can sync to path progress
  (DISTANCE/STEP) or ease frame selection. Looping scenes count as complete.
- EventHandler chains phases with no timers: PATH_COMPLETE -> ACTIVATE_PATH / ACTIVATE_SCENE etc.
- An effect ends when no character has pending paths/scenes. Duration is emergent
  (max over cells of stagger + path steps + scene frames), never a hand-set constant.

## Gradients and the final-state lock
- Gradient(stops, steps): linear RGB between stops, spectrum length = sum(steps)+1, precomputed.
  loop=True closes the ring.
- build_coordinate_color_mapping(direction): every cell's FINAL colour is a pure function of its
  home coordinate (vertical/horizontal/diagonal/radial fraction -> spectrum index), computed BEFORE
  animating. Every effect ends with a final-gradient scene that walks each cell to that colour at
  its home coord. Whatever happens mid-flight, the last frame equals the resting state.
- Travelling colour: colour = spectrum[(directionIndex(coord) - wavefront(t)) mod S]. Time moves the
  wavefront, not each pixel through the whole palette.

## Effects that fit a 617-cell pixel logo
scattered (decompose -> ease home), unstable (glitch, explode to edges OUT_EXPO, reassemble
OUT_EXPO, gradient 8A008A->00D1FF->ffffff steps 12), crumble (drain colour, fall, bezier vacuum,
reform), expand (from centre), rings (disperse into spinning rings then reform; cut to 1 cycle,
60-80 frames per phase for a logo), spotlights (moving beams modulate brightness, no motion), sweep
(two passes: reveal then recolour, column order), decrypt (cipher noise resolves into the logo).
Runners-up: beams, synthgrid, swarm, blackhole.

## QML/JS port design
- Typed arrays allocated once: home hx/hy (Uint8), current px/py (Float32), per-cell waypoints
  flattened (Float32, K<=3), pStep/pMax (Uint16), easeId, holdLeft, colIdx/tgtIdx (Uint8), frmLeft,
  active flag + sparse active list.
- Spectrum precomputed per accent change (Uint8ClampedArray S*3); finalIdx[i] from the coordinate
  map, once per effect. Cache fill-style strings per (colour, alpha bucket); no per-frame string
  building.
- ONE timer, running only while an effect is active, tick-driven (not Date.now()): effect ends when
  the active list drains, plus a safety cap.
- Easing table: out_expo, in_out_cubic, out_back cover the chosen effects.
- 617 cells x (few float ops + one fillRect) is well under 2 ms per frame.

## Invariants
1. End state == base state by construction (envelope 0 at start and end), last frame is painted
   before the timer stops.
2. Logo always ~50% lit: base alpha ~0.5; decompose effects keep cells moving and visible, never
   fade the silhouette out.
3. Shuffle-bag scheduler with no immediate repeat, every 30-60 s.
4. Duration computed from the effect's own data.

## Diagnosis of v3 PixelKnot (HudV3.qml)
- Idle alpha idleA = 0.14 (line 3101) times knotMark opacity 0.9 (line 5698) = ~12.6% lit.
- fxTimer (3232-3236) calls endEffect before the final repaint, so the fully-home frame is skipped.
- pause() (3016) freezes a deformed frame when visibility flips (3024, 5708, 5688).
- effVisible gate (3235) skips paints but wall-clock time keeps running.
- SCATTER last cell finishes at 4800 ms but durFor(0) = 4600 ms (3285, 3189): cut off.
- SCATTER landing alpha plateaus at ~0.86 then hard-cuts (3290). HUE alpha flat idleA+0.80 (3322).
- HUE (3323) has no locked target colour and strobes each pixel through the whole palette.
- buildTrace() rank (3157-3178) is computed but never used.
- Durations live in durFor() (3187-3196) while timelines are magic constants in onPaint (3282-3323).
