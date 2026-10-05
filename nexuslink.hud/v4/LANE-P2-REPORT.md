# LANE-P2 REPORT — Workbench patch bay → APPS NAVIGATOR (lane D3)

Scope owned: `v4/Workbench.qml`, `v4/AppGrid.qml` (new), `v4/qmldir` lane-D/N block.
Operator verdict: the right-column patch bay was clutter — removed wholesale,
replaced by an integrated .desktop launcher.

## Claims + evidence

### C1. Patch bay removed entirely

NETWORK INTERFACES, AUDIO ROUTES, BLUETOOTH+PERIPHERALS, DISPLAYS, USB
FABRIC and LINK FLOWS panes deleted (LINK FLOWS shared the same column —
removed per the verdict). All feeding code deleted with them: `topo`
handle, `topoRows()`, `flowRows()`, `flowRowCache`, `isUnk()`, `fmtBytes()`
(patch-bay-only callers), and the `PatchSection` component.

Evidence:

```
$ grep -n "topo\|flowRow\|PatchSection\|isUnk\|fmtBytes\|patch\|PATCH" v4/Workbench.qml
→ only "dispatch" substring hits on hyprctl lines 145,440,445,559 (unrelated)
```

This also retires audit finding W3 (kind-enum drift `netif`/`pw_sink`/`xhci`
vs Topology's `nic`/`audio`/`usb`) — no Topology kind filters remain in
Workbench, and the screen no longer touches `Topology.nodes/flows`.

### C2. APPS NAVIGATOR pane (new `v4/AppGrid.qml`, 518 lines)

- **Enumeration**: one `FolderListModel` per root — `~/.local/share/applications`
  then `/usr/share/applications` (`nameFilters: ["*.desktop"]`, `showDirs: false`,
  `sortField: Name`). Merged in XDG precedence order; first-seen desktop-file-id
  wins so the user root shadows the system root even when the shadowing file is
  itself skipped (correct freedesktop masking).
- **Skip rules**: `Hidden=true`, `NoDisplay=true`, `Type!=Application`, and
  unreadable/missing-Name files never reach the model.
- **Decode**: `DesktopEntries.byId(id)` first (locale-aware Name/Icon/Exec/
  genericName/runInTerminal — the same call chain `nexuslink.taskbar` uses
  live). Misses fall back to one shared synchronous `FileView` (`blockLoading`)
  that parses only the `[Desktop Entry]` group — the brief's FLM+FileView path.
- **Sort**: name ascending, case-folded `localeCompare`.
- **Filter**: Navigator-style query buffer — printable keys append, Backspace
  chops, live `refilter()` matches name/id/genericName/exec; footer count shows
  `filtered/total`.
- **Launch**: `Quickshell.execDetached(["gtk-launch", <desktop-file-id>])` —
  argv only, zero shell involvement (stricter than a `bash -lc` wrapper; the
  desktop-file-id is passed as one argv element, never concatenated).
  `Terminal=true` entries are handled by gtk-launch itself.
- **Icons**: `Quickshell.iconPath(name, true)` resolved at row build (cached);
  absolute icon paths pass through as `file://`; unresolvable names draw a "▢"
  fallback glyph — never a fake image (BRIEF §3 honesty).
- **Keyboard nav**: host `PanelWindow` is `WlrKeyboardFocus.None`, so the pane
  arms `HyprlandFocusGrab` (`hyprland_focus_grab_v1`) on this window — obtained
  via the `QsWindow.window` attached property, the `WindowInterface` object the
  grab's `ProxyWindowBase::forObject` accepts. Click the filter field → grab +
  QML focus; ↑↓/PgUp/PgDn/Home/End move `sel`, Enter launches, Esc clears the
  query then releases the grab; compositor `cleared` (click outside the window)
  disarms too. `active` is bound (never assigned imperatively — that would drop
  the binding). All mouse paths work with or without the grab.
- **Visual**: identical head-row/recssed-well/row-card vocabulary as
  PatchSection/Navigator (accent tick, `fDisp` 10px ls3 title, `fMono` 8px hint,
  `well` recessed field, `ink` rows with edge/accent borders) inside the
  existing `GlassPane`; palette resolved through the same `col()` fallback
  guard Workbench uses, plus real `Style.c` tokens (`dim`/`faint`/`recess`).

### C3. harness/token lists

`harnessIds`: `["devin","opencode","haze","claude"]` → `["devin","opencode","haze"]`.
`tokOrder`: `["devin","opencode","haze","claude","codex","fireworks"]` →
`["devin","opencode","haze","fireworks"]`. Workspaces/windows, agent sessions,
process ledger, repos/CI, token ledger, UtilityDock untouched. Masthead now
reads `WORKBENCH+APPS NAV`.

### C4. qmllint

```
$ /usr/lib/qt6/bin/qmllint Workbench.qml AppGrid.qml   (run from v4/)
→ exit 0, zero warnings
```

`qmlformat` is not in this lane's permitted toolset; both files follow the
normalized house style (4-space indent, same brace/spacing conventions as the
existing formatted sources).

### C5. First ~10 desktop entries the model resolves (live dirs)

`ls` shows 19 local + 80 system `.desktop` files; `comm -12` shows 3 shadowed
ids (`foot`, `imv`, `mpv` — user copies win, e.g. local `imv` "Image Viewer"
masks the system's NoDisplay one); `grep -l "NoDisplay=true\|Hidden=true"`
finds 30 system files (29 of them unshadowed) → ~67 resolved rows.

Name-sorted head (name · desktop-file-id · icon · root):

| # | Name | id | Icon | root |
|---|------|----|------|------|
| 1 | Aether | aether.desktop | aether | sys |
| 2 | AURICLE | auricle.desktop | auricle | local |
| 3 | Avahi SSH Server Browser | bssh.desktop | network-wired | sys |
| 4 | Avahi VNC Server Browser | bvnc.desktop | network-wired | sys |
| 5 | Avahi Zeroconf Browser | avahi-discover.desktop | network-wired | sys |
| 6 | Basecamp | Basecamp.desktop | basecamp | local |
| 7 | btop++ | btop.desktop | btop | sys |
| 8 | Chromium | chromium.desktop | chromium | sys |
| 9 | cliamp | cliamp.desktop | cliamp | sys |
| 10 | CMake | cmake-gui.desktop | CMakeSetup | sys |

Evidence command:

```
grep -H -m1 -E "^Name=" /usr/share/applications/*.desktop ~/.local/share/applications/*.desktop
grep -l "NoDisplay=true|Hidden=true" /usr/share/applications/*.desktop ~/.local/share/applications/*.desktop  → 30
comm -12 <(ls /usr/share/applications|sort) <(ls ~/.local/share/applications|sort) → foot,imv,mpv(+mimeinfo.cache)
```

## Deployed

Copied to `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/`:
`Workbench.qml`, `AppGrid.qml`, `qmldir`.

## Caveats / notes for the gate

- Keyboard path requires `hyprland_focus_grab_v1` (Hyprland — satisfied on
  this host). If the protocol is absent the grab never activates and the pane
  is mouse-only by design; no fake focus is claimed.
- While the grab is armed it owns keyboard input until Esc/click-outside —
  indicated by the lit filter border + `KEYS·n/m` count.
- Shell was NOT restarted (per instructions) — live render not verified here.
