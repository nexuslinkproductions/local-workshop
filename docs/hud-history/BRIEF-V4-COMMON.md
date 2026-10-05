# Common context for every v4 lane (read first)

Root (R): /run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/nexuslink.hud
Plan: R/PLAN-V4.md (read the Frame, Done predicate and Graft decision sections).
Live plugin dir (L): /home/nexuslink/.config/omarchy/plugins/nexuslink.hud
  Hud.qml (entry, currently == R/candidates/HudV3.qml), ambient.qsb, hud-collect (Rust
  collector binary, source R/collector/src/main.rs), collect.sh, tokens/ledger.py, manifest.json.
Collector contract: `L/hud-collect stream` prints `key<TAB>value` lines, each ~1 s batch ends
  with `batch<TAB>n`. Keys documented in R/recon/stream-keys.md and R/recon/untapped.md.
Monitors: DP-1 2560x1440 at x=0 (main, centre). DP-2 1920x1200 right. HDMI-A-3 1920x1200 left.
Stack: QML on Quickshell (Qt 6), wlr "bottom" layer, one PanelWindow per screen, window
  `mask:` makes only drawn panels clickable. qmllint: /usr/lib/qt6/bin/qmllint. qsb: /usr/lib/qt6/bin/qsb.
IPC: `omarchy-shell nexuslink.hud <method> [args]` (methods: status stats toggleAll refresh
  section tokens focus move resize show hide layout panels say).

## Facts already established (do not re-derive)
- `omarchy-shell restart` is NOT a restart (it is an IPC call to a missing target).
  The real restart is `omarchy-restart-shell`. It refuses while the session is locked.
  A file save hot-reloads QML, but IPC function tables and compiled shaders only refresh
  on a real restart.
- The ambient shader link warning is fixed (frag derives uv from gl_FragCoord).
- TOP PROCS bug: QML reads `stats.proc_n`, collector emits only proc0..5_{name,cpu}.
- Baseline CPU: quickshell 76.4% of one core, 30 s average, v3 live.
- Fonts: "Adwaita Sans" (UI), "JetBrainsMono Nerd Font" (numbers).
- QML `color` properties need Qt.rgba()/hex, never "rgba(...)" strings (Canvas strings are fine).
- Never call mutating functions from inside a binding (caused binding loops before).

## Rules for every lane
- Write only the files your dispatch names. Other lanes run in parallel on other files.
- FORBIDDEN: git clean/reset/checkout/restore/add -A, sudo, deleting files you did not create,
  editing anything under ~/.config unless your dispatch says so, restarting the shell unless
  your dispatch says so.
- Deliverables are files on disk. Your final message lists exact paths and the real exit
  codes of your verification commands. No summaries without evidence.
- Comments in code only for a non-obvious why. No phase-narrating comments.
- Prose you write: short declarative sentences, no em-dashes.
