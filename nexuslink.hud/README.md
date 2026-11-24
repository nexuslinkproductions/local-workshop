# NEXUS System HUD (`nexuslink.hud`)

Persistent cyberpunk system dashboard for omarchy-shell. One transparent
panel per monitor on the wlr `background` layer (the same layer as the stock
wallpaper plugin), fed by a single persistent collector process. Only the
drawn deck takes pointer input; every other pixel of the screen-sized surface
passes clicks through to the desktop.

## Files

| File | Role |
|---|---|
| `manifest.json` | plugin manifest (`kinds: ["service"]`, entry `Hud.qml`) |
| `Hud.qml` | thin entry point: a `Loader` for `v4/HudV4.qml`, so load errors are logged instead of fatal |
| `v4/HudV4.qml` | the shell: stats stream, token ledger, IPC, and a `Variants` of one `PanelWindow` per output |
| `v4/Navigator.qml` | modal overlay browser (own `PanelWindow` on the `overlay` layer, own IPC target) |
| `v4/*.qml` | the screens and chrome (`CommandHub`, `BoardView`, `Workbench`, `DeviceBay`, ...), registered in `v4/qmldir` |
| `collect.sh` | collector front end: `probe`, `poll <gpu_kind>`, `stream <gpu_kind>` |
| `hud-collect` | prebuilt Rust collector (source in `../collector`); `collect.sh` hands over to it when it sits next to the script |
| `tokens/ledger.py` | token ledger, run every 60 s, writes `~/.local/state/nexuslink/tokens.json` |

## Screens

Each output gets one deck, picked by its name (`HudV4.qml`):

| Output | Deck |
|---|---|
| `DP-1` | `CommandHub` |
| `DP-2` | `BoardView` |
| `HDMI-A-3` | `Workbench` |
| any other | `CommandHub`, so no output renders empty |

Decks can be dragged and resized. Their position and size are saved to
`~/.config/omarchy/nexuslink/hud-state-v4.json`.

## Navigator

A modal browser drawn over everything: FILES, PROCESSES, DEVICES, AGENTS,
REPOS, USAGE. It is opened over IPC (bind a key to it), takes exclusive
keyboard focus while open, and `F1`..`F6` switch between its sections.

```sh
omarchy-shell nexuslink.nav open files    # open(section[, path])
omarchy-shell nexuslink.nav back | close | state
```

## IPC

Target `nexuslink.hud`: `version`, `status`, `panels`, `say <text>`,
`focus <id>`, `move <id> <fx> <fy>`, `resize <id> <fw>`, `show <id>`,
`hide <id>`, `layout <name>`, `selftest`, `framesAlive`, `reload`.

`status` returns JSON (cpu, memory, gpu kind, network rates, frame counter,
stats age, monitor count). `reload` restarts the collector processes if they
have stopped.

## Manage

```sh
omarchy plugin enable nexuslink.hud     # adds to shell.json plugins[]
omarchy plugin disable nexuslink.hud    # removes it
omarchy-shell shell rescanPlugins       # force re-scan after edits
```

Saving any file in this directory hot-reloads the plugin automatically.

## Notes

- Telemetry is one persistent `collect.sh stream auto` process for all
  windows, about one batch per second from `hud-collect`, or every 1.5 s from
  the bash fallback when `hud-collect` is not installed. Batches end with a
  `batch<TAB><n>` line, where `n` is the running batch count.
- GPU telemetry needs `nvidia-smi` (NVIDIA) or amdgpu sysfs
  (`/sys/class/drm/card*/device/gpu_busy_percent`, `mem_info_vram_*`, hwmon).
  Intel iGPUs typically expose no util/vram counters, so only temperature
  shows there (and only if a hwmon node exists).
