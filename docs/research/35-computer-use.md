# 35 — Computer use: act layer for Chief on Hyprland 0.56 / Wayland (2026-10-13)

**Result:** `serve/computer_act.py` + `serve/act.py` built; **10/10 actions verified** from the test page's own event log on a throwaway window on HDMI-A-5 (10/10 on the last 3 completed runs after the final fixes; earlier runs were 9/10 from a lost first click and a harness focus bug, see Caveats). No GPU, no system install, nothing run through a model.

## 1. Options (full survey with source URLs: `35a-options-survey.md`)

| # | Option | Wayland/Hyprland 0.56 | No-root | Verdict |
|---|---|---|---|---|
| 1 | Hyprland IPC `hyprctl dispatch 'hl.dsp.*'` (cursor.move, focus, send_shortcut, window.*) | native, global coords incl. negative x | yes | **use** for position + focus. No click/scroll dispatcher exists |
| 2 | Virtual pointer (`zwlr_virtual_pointer_v1`) / uinput pointer for buttons + wheel | works | yes (user ACL on /dev/uinput) | **use uinput** for buttons/wheel (python-evdev already in /usr/bin/python3) |
| 3 | `wtype` (virtual keyboard) — already installed | works on Hyprland (not GNOME/KDE) | yes | **use** for type/keys |
| 4 | ydotool / dotool | uinput; ydotool needs daemon; ydotool absolute move broken on negative x (#164) | partial | skip — not installed, #1+#2 cover it |
| 5 | Hermes `computer_use` → cua-driver 0.21 (already in `~/.hermes/tools`) | X11/XWayland only; native Wayland = opt-in beta + experimental Hyprland plugin | binary yes | not ready for native Hyprland; keep for XWayland apps. **Not tested here** (would drive the live desktop) |
| 6 | AT-SPI (pyatspi/dogtail) | tree works, but only window-local coords on Wayland; Chromium needs `--force-renderer-accessibility`; no input | yes | later, as a *locator* complement to screen_locate |
| 7 | portal RemoteDesktop/libei | upstream xdg-desktop-portal-hyprland lacks it | — | skip |

Ranking for Hyprland 0.56 (reliability / latency / safety / no-root): **1+2+3 combined (chosen)** > cua-driver (XWayland) > AT-SPI (locate only) > portal. Latency (not benchmarked): a click includes a deliberate ~0.4 s uinput-device attach wait plus ~0.3 s of settle/nudge; keys/type are a single wtype spawn.

## 2. Design (what was built)

- `serve/computer_act.py` — absolute **global** layout coords (same space as `screen_locate.py` output, negative x ok).
  - position: `hyprctl dispatch 'hl.dsp.cursor.move({x,y})'`; button/wheel: transient uinput relative device `chief-computer-act` (created per call, closed after; 1 px ±nudge so the client gets pointer-enter before the press); keys: `wtype`.
  - cursor is **restored** after click/scroll.
- `serve/act.py "<instruction>"` — parses `[double-|right-]click <target>`, `type`, `key|press`, `scroll up|down|left|right [N]`, `focus`; for clicks calls `screen_locate.py <target> --monitor M` → x,y → `computer_act.py`. Offline selftest: `act.py --selftest`.
- Test fixture: `bench/act-test/{page.html,server.py,run.py}`.

### Exact commands
```
A=serve/computer_act.py            # runs with /usr/bin/python3 (has evdev); default = DRY-RUN
$A --only 'REGEX' click X Y [--button left|right|middle] [--double] [--yes]
$A --only 'REGEX' type "text" --yes
$A --only 'REGEX' key "ctrl+l" --yes
$A --only 'REGEX' scroll DX DY [--at X Y] --yes       # DY>0 = down, notches
$A focus --window 'REGEX' | --monitor HDMI-A-5 --yes
serve/act.py "click the Save button" --monitor DP-1 --only firefox --yes
bench/act-test/run.py              # full 10-action test (opens/closes its own window)
```
Output is one JSON line `{cmd, plan, target, status: done|dry-run|refused|error, reason}`; exit 0 = done/dry-run.

### Safety gates
1. **Dry-run by default**; executes only with `--yes` (or `y/N` on a tty).
2. **Target-window gate**: click/scroll target = window under the point; type/key target = active window; `focus --window` target = the matched window. `--only REGEX` (or `CA_ONLY`) refuses anything whose `class | title` doesn't match. Verified: a click at a Discord window with `--only ca-test-page` → `refused`.
3. Deny-list windows (keepass/bitwarden/1password/polkit/pinentry/gcr-prompter/hyprlock/password/sudo) always refused.
4. `type` refuses dangerous patterns (`curl|sh`, `rm -rf`, `mkfs`, `dd if=`, fork bomb). `key` refuses any super/logo/win chord (would hit Hyprland binds).
5. `focus --window` must match **exactly one** window.
6. Every executed action appended to `serve/computer_act.log` (JSONL; `CA_LOG` to redirect).

## 3. Test results (throwaway chromium `--app` window, separate profile, floating 700x480 on HDMI-A-5, local test server; verified from page event log)

| # | Action | Result |
|---|---|---|
| 1 | click large button (220x80) | PASS |
| 2 | click small target (14x14 px) | PASS |
| 3 | right-click zone | PASS (`contextmenu`) |
| 4 | double-click zone | PASS (`dblclick`) |
| 5 | click text input | PASS (`focus`) |
| 6 | type "hello wayland" | PASS (input value exact) |
| 7 | shortcut `ctrl+k` | PASS (`ctrl+k` keydown) |
| 8 | key `Return` | PASS |
| 9 | scroll down 3 notches over scroll box (`--at`) | PASS (`scrollTop>0`) |
| 10 | focus window by name (focus moved away first, then back; active address checked via hyprctl) | PASS |
| bonus | `act.py "click the large button"` with a stub locator → real click | PASS |
| neg | click outside `--only` → refused; `super+q` → refused; `curl x \| sh` → refused; no `--yes` → dry-run, no event reached page | all OK |

Self-check: window closed, chromium+server+temp profile gone, uinput device gone, cursor restored to its pre-run position (printed before/after equal), nothing installed, no files outside `LOCAL-AI-LAB`. During the run Marcel's windows were not clicked/typed into; the only side effect on them is a brief focus change (focus is moved back to the previously active window). The test window was floating, so his tiling layout was not changed.

## 4. Caveats / honest limits

- **screen_locate not exercised live**: `http://127.0.0.1:18080/v1/models` didn't answer (and I was told no GPU), so the locate→act chain was tested with a stub locator returning fixed coordinates (`SCREEN_LOCATE=<script>` override). With the real endpoint down, `act.py "click x"` returns a clean `target not found … Connection refused` error (verified).
- First click into a **freshly mapped** window can be lost (1 of 3 early runs): the test harness now waits 1.5 s after first paint. Real use against long-lived windows isn't affected; if a click reports `done` on a brand-new window, verify and retry once. (Adding the ±1 px nudge helped but didn't alone cure it.)
- `done` means "events injected", not "effect happened" — Chief must re-screenshot/`screen_locate` to verify (same as Hermes computer_use `unverifiable`).
- `type` is US-layout (wtype). Fractional monitor scale: `screen_locate` already maps back to logical coords; all three monitors are scale 1 today.
- Gates are by window **class/title regex**, not by pixel content: a dialog inside an allowed window is still allowed. Use a narrow `--only`.
- Hyprland Lua syntax verified here: `hl.dsp.focus({ window = "address:0x…" })`, `hl.dsp.window.close({ window = "address:…" })`, `hl.dsp.exec_cmd(cmd, {float=true, monitor=…, size=…, move=…})`.

## 5. How Chief calls it

Plain `terminal` (a bash call): `serve/act.py "<instruction>" --only <app regex>` first without `--yes` (prints plan + located point), show Marcel/log it, then re-run with `--yes`. No MCP/Hermes tool wrapper needed (YAGNI); if wanted later it's a 10-line wrapper over the same CLI. Pair every action with a follow-up `screen_locate` to verify.

## 6. Needs Marcel's OK

- Letting Chief run with `--yes` (autonomous) on real apps; suggest a standing rule: `--yes` only with `--only` set, and per-app allow-list.
- Whether to also enable the Hermes `computer_use` (cua-driver) for XWayland apps — untested, would move his real cursor/focus.
- Optional: install `dotool`/`ydotool` — **not needed**, nothing system-wide was installed.
- Optional: bring up the vision endpoint (18080) so a live locate→click run can be done on the test page.
