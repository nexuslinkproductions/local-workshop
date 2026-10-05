# LANE-B3-REPORT — Reactor identity layer + knot variants/async effects

Scope honored: `v4/CommandHub.qml` and `v4/KnotField.qml` (edited),
`v4/LANE-B3-REPORT.md` (new). No other files touched — Workbench.qml,
HudV4.qml, Style.qml, Theme.qml, qmldir all byte-identical. Mirror synced to
`~/.config/omarchy/plugins/nexuslink.hud/v4/` via `install -m 0644` (verified
with `cmp`; no shell restart needed — QML reloads on file watch).

## 1. REACTOR IDENTITY (CommandHub.qml)

The DP-1 dial now carries the machine's own presence instead of a generic
CPU gauge. All circle/centering/shadow invariants untouched (reactor still
`anchors.centerIn: parent`, same shadow disc stack, same canvases).

- **Identity band** (dialArcs telemetry pass, `arcText()` helper,
  CommandHub.qml:1466-1504): per-glyph arc text at r = 0.935·R — inside the
  corona notches (0.965R), outside the outer ring glow (~0.905R).
  - Top arc: `NEXUSLINK · YURI` — chrome-dim wordmark, `·` separator,
    `YURI` in Style.c.accent (display font). Glyph widths measured with
    `measureText` so the arc self-centres; `top=true` walk keeps glyph tops
    outward, `top=false` lays the bottom plate upright.
  - Bottom arc: `<screenName> · <kernel>` (e.g. `DP-1 · 7.2.5-3-OMARCHY`),
    mono, ice-dim — the machine serial plate. Repaints ride the existing
    per-stats-frame dialArcs pass; zero new idle cost, no new timers.
- **Face** (CommandHub.qml:1595+): `R E A C T O R` replaced by the persona
  nameplate `Y U R I` (same display-font/tracking treatment). Hero numeral
  unchanged (still cpu% + `%`, alert-red override kept). New **subtitle**
  under the hero: `◆ <HOST> · <STATE> · UP <uptime>` — host from the probe
  key `stats.host` ("OMARCHYLINK", falls back to "NEXUSLINK" pre-probe),
  state = `AWAKE` / `ALERT` (root.alert) / `DARK` (telemetry link stale).
- **Status glyph row** (one line, under the subtitle): `● LINK` (accent2 /
  alert), `◆ n SESS` (accent when live devin sessions > 0, else faint),
  `▲ <maxTemp>°|NOMINAL` (alert / faint). Live-session count derives from
  `devsess{i}_live` keys (CommandHub.qml:265-275: `liveSess`).
- `seedFor()` (djb2 string hash, CommandHub.qml:281) feeds the knot:
  `seed: root.seedFor(root.screenName)` — DP-1 keeps variant 0 (acid KNOT)
  and gets a deterministic per-screen async stream.

## 2. KNOT VARIANTS (KnotField.qml)

`variant: 0|1|2|3` (wraps mod 4) selects weave matrix + colourway;
`accent` defaults to the variant colourway but remains overridable.

| v | name | cells | accent | weave |
|---|------|-------|--------|-------|
| 0 | KNOT | 617 | Style.c.accent (acid lime) | original matrix, byte-identical |
| 1 | LINK | 504 | Style.c.accent2 (cyan/ice) | twin interlocked rings, weave gaps |
| 2 | TREFOIL | 495 | Style.c.magenta | parametric trefoil ribbon |
| 3 | SIGIL | 306 | Style.c.warn (amber) | gated double ring + nodes + core |

- Matrices are baked `knotRowsLink` / `knotRowsTrefoil` / `knotRowsSigil`
  (48×49, generated procedurally, verified cell-for-cell against generator
  output). `matrixFor(variantIdx())` feeds `buildCells()`; `ang`/`rn`/`rank`
  derive automatically, so every effect works on every weave.
- `variantDefs[]` holds per-variant `{accent,hi,lo}` pulled from Style.c
  tokens + one new `cViolet` harmonic; `buildHueStops()` builds
  `[accent,hi,lo,accent]` so the HUE trace swings through each variant's
  own palette.
- `onVariantChanged` reseeds + rebuilds cells + hue stops + repaints —
  live switching works (a navigator variant-picker can flip it).

## 3. ASYNC ANIMATION

- **Seeded per-instance stream**: `seed` property (<0 = auto-drawn from
  time×random×variant at completion; callers pin an int for a stable
  personality — CommandHub passes `seedFor(screenName)`). One LCG (`rnd()`)
  now feeds cell scatter vectors/delays, cadence jitter, bag shuffle,
  mirror parity and per-run params — sibling knots on different seeds can
  never phase-align; same seed = deterministic replay.
- **Phase-in**: first cadence arm lands 6–20 s in (seeded), then the
  jittered 30–60 s cadence resumes — instances desync from the start.
- **ALTER**: `startEffect` re-draws `effDir` (±1 travel direction),
  `effPhase` (orbit head start) and `effJit` (0.85–1.15 pace) per run;
  ASSEMBLE sweeps either way, PULSE expands or implodes, HUE swirls both
  directions, mirrorFlip still alternates.
- **New effects** (same cycleTimer/fxTimer pair — no perpetual clock):
  - `orbit` (5, 5400 ms): lit bead + quadratic comet tail runs the trace
    `rank` order; bead head lerps toward white.
  - `cascade` (6, 3800 ms): brightness front sweeps rows top↔bottom,
    carrying cells ~1.6 px along travel.
  - `beat` (7, 3000 ms): cardiac double-gaussian swell, core leads rim
    (per-cell radial lag via `rn`).
  All three envelope to the lit base state (`min(ms, dur-ms)` guards), so
  pause()/endEffect() still settle correctly. `play()` accepts ids 0–7 and
  the new name strings; the shuffle-bag now cycles all eight.

## Compatibility / invariants kept

- Workbench.qml untouched: `KnotField { px:…; running:false }` gets
  variant 0, lime accent, one static base paint, zero timers — verified.
- HudV4's knot-lit probe reads `cells/effect/elapsed/effectDur/idleGlow/
  kcx/kcy/maxR/cols` — all unchanged for effects 0–4; during new effects
  5–7 the probe's mean-alpha reads as base (transient under-report only —
  settle metrics unchanged).
- v3fix invariants: idleGlow 0.56, terminal frame = base, pause() settles,
  SCATTER tail fade, effectDur ≥ latest flight — all preserved.

## Evidence

- `qmllint -I . CommandHub.qml KnotField.qml` → exit 0, no output.
- Matrix audit (python): all 4 arrays 49×48, zero diffs vs reference
  (knotRows vs deployed original; variants vs generator).
- Runtime smoke (`qml` runtime, offscreen, stub Style): all four variants
  paint distinct weaves with correct accents; seeded mirror parity differs
  per instance; `play("orbit"/"cascade"/"beat"/"hue"/"scatter")` all run
  and settle (`onSettled` fired, runCount incremented, effect → −1).
- PNG dumps of base frames (v0–v3) + mid-flight ORBIT/CASCADE/BEAT frames
  confirm correct silhouettes (verified via ImageMagick pixel dumps).
