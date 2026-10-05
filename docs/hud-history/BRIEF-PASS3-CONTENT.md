# BRIEF-PASS3-CONTENT — NEXUS HUD true per-screen differentiation + richer telemetry

## Context

Quickshell/QML (Qt6) desktop HUD for Omarchy/Hyprland, `service` plugin on
`WlrLayer.Bottom`, one fullscreen `PanelWindow` per `Quickshell.screens`.
User verdict on pass-2 (HudN): "screens basically show very similar
information — GPU 3 times, storage etc. I need DIFFERENT information on
each screen. Top procs don't say what is being measured. Feels cheap —
want full control + overview." Be far more creative with the telemetry.

**Base file (READ FIRST):**
`/run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/nexuslink.hud/candidates/HudN.qml`

Frozen collector contract: `recon/stream-keys.md` (read it — additive-only,
tolerate missing keys). Agent surface intel: `recon/agentic-surface.md`.

## Mission — the differentiation contract (HARD RULE)

**Each metric gets exactly ONE primary home.** A panel/stat may appear on a
second screen ONLY as a one-line summary in that screen's STATUS strip —
never as a duplicated graph, bar set, or sensor sheet. Audit HudN: GPU0/GPU1
panels, STORAGE, MEMORY, TOP PROCS, NETWORK currently render on multiple
screens — kill the duplicates.

### DP-1 — "command" (Samsung, primary, showcase)
The cinematic overview: reactor dial, hero clocks/uptime/load, big smooth
traces, compact AGENTS count strip, compact launch rail, STATUS. Sparse and
premium — NO per-core matrix, NO full GPU sensor sheet, NO storage detail
(a single GPU power dial or util hero is fine — the *detail* is DP-2's job).

### DP-2 — "hardware" (HP E24i)
ALL the silicon telemetry lives here and ONLY here: both GPU sensor sheets
(every `i_*`/`a_*` key incl. vram channel temps, energy/cap), enlarged
per-core matrix, NVMe/DIMM/CCD temps, PSI some/full, zram ratio, cpu MHz
avg/max, fs mounts + disk rw, PERIPHERALS batteries, media mounts. Get
creative: power-vs-cap dial with headroom glow, PSI pressure sparklines,
per-CCD thermal compare, per-core heatmap cells (color=load), VRAM channel
histogram. No agents/repo/launch/window panels at all.

### HDMI-A-3 — "ops" (HP Z24n)
The work console and ONLY home for: AGENTS expanded (per-harness chips,
devin ACP, session locks, tmux attach), REPO ACTIVITY feed, WINDOWS/NAV,
LAUNCH rail, quick actions, TOP PROCS. No GPU sheets, no core matrix —
one-line "GPU B580 42°C" cross-ref in STATUS max.

### TOP PROCS — semantics fix (REQUIRED everywhere it appears)
Label the measurement: header "TOP PROCESSES · %CPU (1s)" + show each row's
raw % value AND a sub-label of what it is (e.g. `65% cpu`); consider a
second sortable signal column (RSS MB) or a mode toggle CPU↔MEM on click.

## Creativity bar (the "don't feel cheap" ask)

- Data viz beyond bars: dials, heatmap cells, dual-sided net trace
  (rx up / tx down split), histograms, event feed with per-type glyphs,
  session-lock timeline chips (live=green pulse / stale=faded), tmux
  attach affordance, unread badge pulse.
- Micro-motion everywhere consistent with the 30Hz animT/sv easing idiom —
  new panels get eased scalars too, not instant jumps.
- Section headers gain a right-aligned mini-stat (e.g. STORAGE · "256G free",
  AGENTS · "5 live"), so collapsed panels still tell you something.
- If `bat_count=0`, `win_count=0`, `gh_ok=0` → designed empty states
  (dim glyph + "no peripherals" / "collector idle"), not blank boxes.
  NOTE: live capture showed `win_count=0` while windows existed — before
  blaming the collector, run `~/.config/omarchy/plugins/nexuslink.hud/
  hud-collect stream` for ~5s and grep `win_count|ws_count` to see whether
  the keys flow; if keys flow, fix the parse/display path.

## Constraints (MUST hold)

- PanelWindow per screen on Bottom layer; no implicit sizes on it; mask
  covers every interactive item; IPC fns + collapse map + collector Process
  + ambient.qsb ShaderEffect reference all preserved.
- Single file, imports per HudN's existing set only.
- Palette: cyan #00e5ff green #39ff14 magenta #ff2bd6 amber #ffb300
  alert #ff3b4e plate #040e16.
- `/usr/lib/qt6/bin/qmllint` → 0 errors. Report: path, lines, what's unique
  per screen, dup-audit summary, viz added, risks.

Produce `candidates/HudP.qml` only — no deploy, no restart.
