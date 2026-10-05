# v3 notes — HudV3.qml

Candidate: `candidates/HudV3.qml` (base `HudFinal3.qml`, 6,666 lines).
NOT deployed — `~/.config/omarchy/plugins/nexuslink.hud` untouched.

## What changed

### 1. Reactor (DP-1 hero, §3 of the brief)
- `defaultRects()` (command branch) now centres the chassis so the **dial
  face** — not the chassis box — sits on both axes of the field's free
  space (`axisX = W/2`, `axisY = sTop/2`; the title zone is already
  excluded by the field rect, the bottom strip band is subtracted via
  `nh()`). Dial targets ~55–62 % of field height; chassis width is solved
  so the two 18 % flank cards + margins leave exactly `dial` px for the
  dial band.
- SYSTEM rail slimmed `0.20 → 0.17` of width.
- Spark flanks `0.24 → 0.18` chassis width so the dial keeps the band.
- `dialCanvas` is a full rewrite: one Canvas paints everything per
  `tickSeq` pulse (while visible):
  - **4 rings** outer→inner: CPU, GPU power/cap, MEM, NET (rx+tx vs 60 MB/s).
    Hairline tracks, glow pass + core pass, hot-dot arc heads, ring tags
    (CPU/GPU/MEM/NET) at the arc tails, **18 segment notches** punched
    through every band.
  - **Orbiting tick corona**: 72 notches, one rev / 60 s driven by `animT`,
    with a lit head sector so the motion reads.
  - **Load-spike pulse**: `load1/cpuCount > ~0.55` boosts the outer ring's
    width + glow modulated by `root.pulse`.
  - **Dense inner telemetry** on a legibility disc: REACTOR label, hero %,
    `L 1/5/15`, `CPU °C · GPU W`, `MEM used/total`, `R/T` rates,
    `uptime · clock`, top proc, pulsing `ALERT` line.
  - **say() chip**: scrimmed rounded chip on the lower face for the ~3 s
    TTL (`win.sayFlash`).
- Focus flash: `focus(id)` sets `win.flashId`; `CPanel` and the chassis get
  a compositor-only accent outline (no canvas repaint) for ~1.4 s.

### 2. PixelKnot → fixed watermark
- `knotZone` (panelId `"knot"`, drag surface, resize grip, mask region,
  `defaultRects` entry, `rolePanelIds`/`panelLabels`/`itemFor`/`headSymbol`
  entries) is **gone entirely**.
- New `knotMark` Item inside `field`: `z:-2` (above the ambient shader,
  behind every panel), centred on the free-space axis, ~50 % of free-field
  height (49-row grid, px-quantized lands ≈48–49 %), `visible: isCommand`,
  idle silhouette ≈ 0.9 × 0.14 ≈ 12.6 % cell alpha, lifts to 1.0 during
  cycles. No MouseArea — clicks fall straight through.
- `component PixelKnot` rewritten to a **5-cycle transition set** with a
  shuffle-bag scheduler (jittered 30–60 s, `cycleSeconds:45`):
  0 SCATTER (per-cell vectors + d1/d2 staggers: decompose → hang →
  reconstruct with landing flash), 1 ASSEMBLE (left→right build front,
  cells rise into place, hold, ease back), 2 PULSE (concentric ring),
  3 SPARKLE RAIN (flare + decay + drizzle-down), 4 HUE TRACE (accent walks
  polar angle+depth order). `mirrorFlip` alternates the silhouette.
- Paint pump (`fxTimer`) runs **only while a cycle is active**, at the HUD
  tick rate, gated by `effVisible` — idle knot = zero wakeups, zero repaints.
- Persisted maps that still contain a `"knot"` entry are safely dropped by
  `sanitizeMap`/`roleIds` filtering on load.

### 3. Agent IPC surface
`IpcHandler` (target `nexuslink.hud`) gained:
`focus(id)` · `move(id, fx, fy)` · `resize(id, fw)` · `show(id)` ·
`hide(id)` · `layout(name)` · `panels()` · `say(text)`.

- Root helpers (`winForPanel`, `commandWindow`, `ipc*`) route through
  `winVariants.instances` — the missing delegate-scope piece is now bridged
  by `id: winVariants` on the `Variants`.
- Shared ids (`agents`, `status` exist on multiple roles) resolve to the
  command window first; use `panels()` output to pick a screen explicitly.
- `move`/`resize` take **field fractions** (same units `panels()` reports)
  and land on `commitRect` → snap(12 px) + clamp, then `resolveLayout` +
  `persist` — identical to a mouse drop.
- `show`/`hide` write `hiddenMap` + `persist` + `reflowTimer` — identical
  to the settings chips.
- `layout(name)`: `default` (factory field, unhide all), `focus` (hero set
  per role; command swells the chassis to ~86 % free height), `sparse`
  (hero + status only). Unknown names return `unknown layout <n>`; calls
  against hidden/missing panels report it instead of a bare `ok`.
- `say(text)` flashes on the command reactor face (~3 s TTL, 120-char cap).

### 4. CPU levers applied
- `tickHz` default `30 → 20`; settings chips now `[15, 20, 30, 60]` (all
  original choices retained, 20 selectable, persisted values 15/20/30/60
  all honoured on load).
- `tick()` converge-guard: when no eased scalar moved and no batch landed,
  `sv` keeps the **old object** — every `s()`/`svCore()` binding stops
  re-evaluating; `tickSeq` only pulses on batch/motion/scroll.
- `TraceCanvas` + `PwrDial` repaint only when `live && effVisible &&
  seriesSig changed` — a tickSeq pulse that would redraw identical pixels
  is skipped.
- `dialCanvas` paints solely on `tickSeq` (+accent/say changes) while
  `visible`; hidden chassis = no raster work.
- `effVisible(it)` walks parents — role-hidden/hidden-ancestor canvases
  never mark themselves dirty.
- All face strings are built inside `onPaint` at tick cadence — no
  per-frame string formatting bindings.

### 5. Shader — qt_TexCoord0 warning
- New `candidates/ambient.vert`: the Qt6 default quad-grid vertex stage
  declared explicitly (`qt_Vertex`/`qt_MultiTexCoord0` in, `qt_TexCoord0`
  out at location 0, `qt_Matrix`/`qt_Opacity` UBO).
- `candidates/ambient.vert.qsb` built with
  `qsb --glsl "100 es,310 es,440" --hlsl 50 --msl "12,20"` — same 7-variant
  target set as `ambient.qsb`. `--dump` confirms `qt_TexCoord0` output.
- `ambientField` gained `vertexShader: "ambient.vert.qsb"` so the fragment
  input always has a real matching output — addresses the journal's
  "fragment shader input 'qt_TexCoord0' with explicit location has no
  matching output" warning.
- **DEPLOY NOTE**: `ambient.vert.qsb` must sit next to the deployed
  `ambient.qsb`/`Hud.qml`. If it is missing the ShaderEffect will fail to
  load the vertex stage. `ambient.frag` itself needed no change — the
  shader was structurally correct; the warning came from the missing
  vertex output, not the fragment input.
- `shaderOn`/`shaderIntensity` unchanged (default 0.7, slider persisted).
  Reducing plasma bloom count in `ambient.frag` was **deferred** — the
  fragment shader is already cheap relative to the old 30 Hz canvas churn;
  revisit if `perf.md` still shows a hotspot after the tick gates land.

## Verification
- `qmllint HudV3.qml` → exit 0, **0 errors**. During the work a nested
  `function F()` inside `onPaint` was found to stall qmllint's whole
  semantic pass (47 output lines vs ~7,000) — hoisted to Canvas-level
  `fontSpec()`/`pad2()`; the pass now runs and the warning profile matches
  the baseline (unqualified-access noise, missing `qs.Commons`/`qs.Ui`
  modules, pre-existing QProcess signal-handler warnings).
- `qmlformat` parses the full file clean.
- Brace/audit greps: no `knot` in `rolePanelIds`, `panelLabels`,
  `itemFor`, `defaultRects`, `hiddenMap` call sites, or mask regions; no
  `MouseArea`/`panelId`/`layoutMap`/`masked` in `knotMark`; all 21
  `itemFor` targets exist; every `IpcHandler` method maps to a root
  helper → window delegate method chain.

## Deferred / watch items
- Plasma-bloom reduction in `ambient.frag` (deferred — see above).
- `layout(name)` applies the preset to **every** screen (per-role
  semantics); a screen-scoped variant could be added if agents ask for it.
- `focus`/`move`/`resize`/`say` on hidden panels return an explanatory
  string instead of `ok` — intentional, so agents get feedback.
- The dial face freezes its clock/orbit when the telemetry stream is fully
  quiet (tickSeq gate) — resumes on the next batch.
