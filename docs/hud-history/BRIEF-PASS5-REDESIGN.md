# BRIEF — HUD v3 flagship redesign (DP-1 agentic command surface)

Base file: `candidates/HudFinal3.qml` (6,197 ln — just patched: `resolveLayout("")`
tidy-up is now clamp-only; morph only runs on drop/resize anchor passes).
Deliverable: `candidates/HudV3.qml` — a full candidate, NOT a diff.
Do NOT deploy. Output must pass `qmllint` (if unavailable, ensure balanced
braces + legal QML).

The user's verdict on the current build: "main monitor needs to be the main
attraction, full overview, agentic OS basically, agentically/programmatically
navigatable for agents." Style stays (dark panel, hairline frames, cyan accent,
circuit ambient) but with **more life** and **lower CPU**.

## 1. Reactor — bigger, truly centred, denser

Current centre is a ~500 px dial that reads small/limited. Rebuild it:

- Centred on BOTH axes of the field's free space (not the raw screen —
  account for title zone + bottom strips). Target ~55–62% of field height.
- Multi-ring face (outer→inner): CPU%, GPU power-vs-cap, MEM%, NET throughput.
- Inner face content, all live: big % hero, load1/5/15, CPU temp, GPU pwr W,
  mem used/total, net rx/tx, uptime, wall clock, top proc name+%, alert state.
- Orbiting tick marks / segmented arc divisions; ring pulse on load spikes;
  subtle rotation of a tick layer (slow, ~1 rev per 60 s, easing, cheap).
- The dial face is a Canvas; draw ONCE per `tickSeq` change, not per frame.

## 2. PixelKnot — background watermark, always alive

Reimplement the knot (inline `component PixelKnot`, grid already embedded —
see `knotCells`/`knotW`/`knotH` at ~line 2881) as a **non-draggable
background element**:

- Dead-centre of the DP-1 field, BEHIND everything (z below panels, above
  the ambient shader), ~45–55% of field height — much larger than now.
- Always visible: NOT a panel — remove it from `rolePanelIds`/`layoutMap`/
  mask entirely; place via anchors on the field. No MouseArea (clicks pass
  through), not in the settings visibility list. It is part of the field.
- Dim idle presence (~12–18% alpha silhouette), brightened during cycles.
- **Transition animation cycles** every ~30–60 s (user's words: "switching
  the way it looks by animating a transition, possibly decomposing and
  reconstructing back into the logo"). At least 5 distinct cycles:
  1. Decompose→recompose: cells scatter (random offsets+fade) then fly back
     into place — staggered by per-cell delay seeded from cell index.
  2. Column-sweep assemble: cells build left→right like a loading pass.
  3. Pulse rings: concentric brightness wave from the knot's centre.
  4. Sparkle rain: random cells flare then decay.
  5. Hue trace: accent colour sweeps through cell depth/angle order.
- Idle between cycles = static dim grid (zero repaint). During a cycle,
  repaint at `tickSeq` cadence only while `cycleActive`.
- Rotate/mirror micro-variation between cycles is welcome but keep the
  silhouette readable — it's the NLP celtic knot.

## 3. DP-1 as "agentic OS" — overview + agent navigation API

The command monitor should read like an orchestration console:

- Keep SYSTEM rail, flank cards, procs drawer, agents/status strips — but
  reorganise around the enlarged centred reactor (reactor axis = knot axis =
  screen centre). Panels may be slimmer; the reactor+knot stack is the hero.
- **Extend the IpcHandler surface** (currently toggleAll/refresh/section/
  tokens/status/stats). Add, all returning `"ok"` or JSON:
  - `focus(id)` — flash/highlight a panel border briefly.
  - `move(id, fx, fy)` / `resize(id, fw)` — set layoutMap entries (clamped,
    snap, persist) — agents can programmatically rearrange the canvas.
  - `show(id)` / `hide(id)` — hiddenMap toggles.
  - `layout(name)` — apply named layout presets (e.g. "default", "focus",
    "sparse"): recompute defaultRects variants + persist.
  - `panels()` — JSON dump of {id, fx, fy, fw, visible, collapsed} — agents
    can introspect the canvas before driving it.
  - `say(text)` — optional: flash text on the command monitor's reactor
    face / status strip for agent→user signalling (cheap, ~3 s TTL).
- These must be wired through the SAME functions the mouse uses
  (commitRect/resolveLayout/persist) so agent edits behave identically.

## 4. CPU optimisation (see recon/perf.md — measured ~65–85% of a core)

Concrete, required:
- **Repaint gating**: every Canvas only repaints on `tickSeq` change AND
  only when its series actually changed since last paint (store last-
  painted tickSeq per canvas; skip no-op paints). Collapsed/hidden panels'
  canvases must not paint at all (visible check + `enabled` guard).
- **Default tickHz 20** (was 30); keep the 15/30/60 settings chips.
- **Shader budget**: cap `u_time`-driven ShaderEffect work — the ambient
  field runs at shaderIntensity ≤ 0.6 on screens where a window is focused
  on that output? NO — simpler: add a `shaderQuality` (0=off, 1=half-res
  via small source rect? Qt has no half-res ShaderEffect cheaply) — the
  practical lever: keep existing on/off+intensity controls and default
  intensity 0.7; make the frag do ONE plasma bloom not two if intensity<0.5
  requires a uniform branch (qsb recompile — SKIP if risky; just document).
- **tick() binding storm**: batch all eased writes into ONE `sv` object
  replacement (single binding re-evaluation downstream) — it already builds
  `nv` then assigns; ensure `tickSeq` bumps AFTER sv assignment so canvases
  read stable state.
- Kill per-frame bindings: audit for properties recomputed at tickHz that
  only need per-batch (1 s) cadence — e.g. string formatting of values that
  only change per batch should be computed in `applyBatch`, not bindings.
- The `qt_TexCoord0` shader-link warning in journalctl: investigate
  ambient.frag/.qsb interface; if the fragment input has no vertex output,
  fix the vertex shader or regenerate the .qsb so the warning is gone.

## 5. Keep (non-negotiable)

- Free-canvas drag/resize/snap/persist engine (now actually working —
  don't regress it; test the dragRelease→commitRect→resolveLayout(did)
  path stays identical semantics).
- Storage device tree on DP-2 (blk_* keys), tokens panel+popup+ledger
  pulse, all monitor roles, mask-based click-through, settings sheet,
  accent presets, collapse-all.
- Typography pairing (fontUi Adwaita Sans / fontMono JetBrainsMono NF) and
  the alpha ladder.
- All three screens must still work; DP-1 is the hero, hardware/ops keep
  their current content (layout polish welcome, no content removals).

## 6. "More life" — restrained motion vocabulary

- Reactor ring pulse on load>80%, halo breath on alert.
- Flank-card mini-traces scroll (already eased).
- Knot cycles as described (the main "alive" surface).
- Hover: 120 ms scale/alpha lifts on interactive chips (some exist).
- NO gratuitous blur/glow stacks — life comes from motion, not filters.

## Verification the lane must do

- `qmllint` the output; fix all errors.
- Brace/delimiter balance check.
- Grep-audit: every `IpcHandler` method has a function; every `itemFor`
  target exists; knot no longer in `rolePanelIds`/`hiddenMap` toggle list.
- Write `recon/v3-notes.md`: what changed, CPU levers applied, any deferred
  items (e.g. shader recompile if qsb toolchain missing).
