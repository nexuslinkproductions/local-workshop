# BRIEF-35: Computer use (act layer) for Chief on Hyprland/Wayland — 2026-10-13

Goal: Chief can not only SEE and POINT (serve/screen_locate.py: 2-stage crop-zoom, 16/16 synthetic,
4/6 live) but also ACT on Marcel's Linux desktop: move/click/double-click/right-click, type, press keys,
scroll, focus windows/workspaces, safely and with confirmation.

## Facts
- Arch/Omarchy, Hyprland 0.56.2 with a LUA config: legacy `hyprctl dispatch movecursor/focuswindow`
  FAILS. Working forms (verified today): `hyprctl dispatch 'hl.dsp.cursor.move({ x = -960, y = 600 })'`,
  `hyprctl dispatch 'hl.dsp.focus({ monitor = "HDMI-A-5" })'`, `hl.dsp.focus({ direction = "l" })`,
  `hl.dsp.window.move({ monitor = "DP-2" })`, `hl.dsp.exec_cmd`. Lua API stubs:
  /usr/share/hypr/stubs/hl.meta.lua (read it for click/key/sendshortcut equivalents).
- Monitors: DP-2 Samsung 2560x1440 at 0,0 (main), DP-1 HP 1920x1200 at 2560,0, HDMI-A-5 HP 1920x1200 at
  -1920,0 (left, AMD iGPU). Window list: `hyprctl clients -j`. Screenshots: grim.
- /dev/uinput has a user ACL rw for nexuslink; ydotool is not installed (ydotoold needs uinput);
  wtype may exist (check). No sudo needed for user-space installs; if a system package is clearly the
  right tool, list it for Marcel instead of installing.
- Hermes itself has a computer_use tool/skill (load skill `computer-use` and read it) and the cua
  project (trycua) has Linux support of some kind: evaluate both as options vs a thin native layer.

## HARD REQUIREMENT (Marcel, 2026-10-13): never steal his cursor or keyboard focus
Background-first input, in this order: (1) AT-SPI accessibility actions (doAction/setText on a11y
elements) and keys sent to a target window without focusing it (Hyprland 0.56 Lua dispatcher for
window-targeted shortcuts, if it exists in /usr/share/hypr/stubs/hl.meta.lua); (2) app-level control
(Chromium via CDP, CLI, D-Bus); (3) an agent-owned SEPARATE desktop with its own seat and cursor
(headless/nested compositor) for GUI apps that need real clicks; (4) explicit opt-in only: the real
pointer, gated on Marcel idle (ext-idle-notify), save/restore cursor + focused window, abort the
instant he moves. Every test checks `hyprctl cursorpos` before/after: his cursor must not move.
Follow the Hermes skill `computer-use` (background-first).

## Do
1. Survey options (cite sources): Hermes computer_use on Linux/Wayland, trycua cua on Linux,
   ydotool/dotool/wtype/wlrctl, Hyprland-native Lua dispatch for clicks/keys, AT-SPI accessibility tree
   (for exact element coordinates without vision). Rank by reliability on Hyprland 0.56 + Wayland,
   latency, safety, and no-root setup.
2. Build the smallest working layer: LOCAL-AI-LAB/serve/computer_act.py with subcommands
   `click X Y [--button left|right|middle] [--double]`, `type "text"`, `key "ctrl+l"`, `scroll dx dy`,
   `focus --window <class|title> | --monitor <name>`, all in absolute global coordinates matching
   screen_locate.py output; plus `act.py "<instruction>"` that chains screen_locate -> confirm -> act
   (print the planned action and require `--yes` or an interactive y/N; default is dry-run).
3. Test ONLY on a throwaway window on the LEFT monitor (HDMI-A-5): open a test page (e.g. a local HTML
   file with buttons that log clicks/keys to a file, launched in a separate browser profile/window),
   run 10 actions (clicks on small/large targets, typing, a shortcut, scroll), verify each from the
   page's log file. Marcel is using the machine: keep cursor moves minimal, restore the cursor to where
   it was, never touch his other windows, never send keys to a window you did not open.
4. Write research/35-computer-use.md: options table, chosen design, test results (10/10?), exact
   commands, safety gates, how Chief calls it (Hermes tool or terminal), and what needs Marcel's OK.
Self-check: no stray windows/processes left, test window closed, cursor restored, nothing installed
system-wide.
