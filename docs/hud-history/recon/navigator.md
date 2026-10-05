# Navigator recon (condensed from scout lane 7574c676)

All citations are paths under /usr/share/omarchy/shell unless absolute.

## Surface recipe (copy from Omarchy menu)
- One PanelWindow, four anchors, WlrLayer.Overlay, ExclusionMode.Ignore, transparent, namespace
  "nexuslink-navigator", fullscreen scrim + dismiss MouseArea (plugins/menu/Menu.qml:1017-1053).
- keyboardFocus bound to open state: `navOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None`
  (image-picker conditional, plugins/image-picker/ImagePicker.qml:370). Use the 75 ms
  Exclusive-then-OnDemand prime if the window stays mapped between opens
  (Ui/KeyboardPanel.qml:74-100, 251-259): OnDemand alone does not re-grab focus on re-open.
- Inner QML focus: keyCatcher Item with focus:true, Keys.priority BeforeItem, forceActiveFocus via
  Qt.callLater after map (Menu.qml:816, 1068-1117). Without it Exclusive grabs the seat and keys die.
- Exclusive routes all pointer input to the surface on Hyprland, so clicks on other monitors cannot
  dismiss it. Add transparent dismiss twins on the other outputs (Ui/KeyboardPanel.qml:335-375;
  ~/.config/omarchy/plugins/expose.window-overview/Overview.qml:1862-1925).
- Open on the monitor of the clicked tile: set `screen:` from the HUD Variants delegate modelData
  (HudV3 Hud.qml:3341-3343). Add the namespace to the no_anim layer rule
  (default/hypr/apps/omarchy-shell.lua:10) or fade in QML (menu has no open animation).

## Plugin ownership
- A `service` plugin may own many windows (plugins/lock/Service.qml:289-317,
  plugins/notifications/Service.qml:952-978). Navigator.qml next to Hud.qml, instantiated by the HUD
  root. Extra IpcHandler target "nexuslink.nav" in the same plugin is fine (shell.qml registers two).
- Caveat: saving any file under ~/.config/omarchy/plugins triggers reloadPlugins
  (shell.qml:1474-1491) and destroys non-keepLoaded services, so the navigator dies on HUD edits.

## Reuse from menu/clipboard
navStack push/pop (Menu.qml:687-715), Util.editsFilter type-to-filter (Ui/Util.qml:107-122),
tiered search score (plugins/menu/MenuModel.js:288-352), PointerMoveGate (Ui/PointerMoveGate.qml),
Color.menu.* tokens, serialized provider Process queue (Menu.qml:330-432), split list + preview layout
(plugins/clipboard/Clipboard.qml:452-580). Do better: breadcrumbs (menu has none), preview pane,
async sources, multi-action rows, open/close animation.

## Data sources
- Files: Qt.labs.folderlistmodel is installed (/usr/lib/qt6/qml/Qt/labs/folderlistmodel/, qmltypes
  22-269: folder, parentFolder, showDirsFirst, nameFilters, sortField, status Loading/Ready). Not used
  by any Omarchy plugin yet, so import inside the shell is UNPROVEN. Process+find fallback precedent:
  plugins/agents/Main.qml:24-33.
- Preview: Quickshell.Io FileView (text(), onLoaded). Cap large/binary files with `head -c 65536` via
  Process and a mime check; FileView on huge files is UNKNOWN.
- Actions: Util.execArgv for untrusted paths (Ui/Util.qml:57-64). Open `uwsm-app -- xdg-open <p>`,
  terminal `xdg-terminal-exec --dir=<p>`, copy path `printf %s <quoted> | wl-copy`
  (plugins/panels/network/Panel.qml:450), reveal `uwsm-app -- nautilus --new-window --select <p>`
  (--select UNPROVEN here) else xdg-open parent dir.
- Windows/processes: Quickshell.Hyprland toplevels in-process, `hyprctl dispatch focuswindow address:<a>`.
- Devices: omarchy-drive-info, omarchy-battery-status, omarchy-bluetooth-*, omarchy-network-status,
  powerprofilesctl. Settings: delegate to `omarchy-menu summon <route>`. Plugins: omarchy-plugin-list --json.

## Recommended architecture
Navigator.qml instantiated by the HUD root. Overlay PanelWindow per the recipe above, screen pinned to
the tile's output, dismiss twins elsewhere. Section registry
`{ id: { title, icon, load(ctx) -> rows, preview(item), actions(item) -> [{id,label,run}] } }`.
Nav state `navStack: [{section, path, selection, query}]`. Keys: Enter default action or descend,
Right descend/action sheet, Backspace/Left on empty query pop, Esc clear query then close, `/` focus
search. IPC target "nexuslink.nav": open(section, path), back(), close(), state().

## Risks
Focus stealing (Exclusive grabs pointer routing too); hot-reload kills an open navigator; large
directories (cap rows, rely on FolderListModel incremental load); untrusted paths (argv only).
