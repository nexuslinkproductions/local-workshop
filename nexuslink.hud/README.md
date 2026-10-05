# NEXUS System HUD (`nexuslink.hud`)

Persistent cyberpunk system dashboard for omarchy-shell, rendered on the
desktop's `bottom` layer — above the wallpaper, below your windows. One
instance per monitor, all fed by a single lightweight poller.

## Files

| File | Role |
|---|---|
| `manifest.json` | plugin manifest (`kinds: ["service"]`, entry `Hud.qml`) |
| `Hud.qml` | service entry point: polling, Variants + PanelWindow per screen, IPC |
| `HudSection.qml` | collapsible section (header chevron + animated body) |
| `HudRow.qml` | stat row: label, optional gauge, value |
| `collect.sh` | stats collector; `probe` (host/kernel/gpu kind) + `poll` (dynamic stats) |

## Sections

- Header: `◢◤ NEXUS//hostname`, kernel, uptime, date/clock, output + active workspace
- `SYSTEM` — cpu % gauge, load avg, cores, cpu temp, uptime
- `MEMORY` — ram + swap gauges
- `GPU` — util/vram/temp (nvidia-smi or amdgpu sysfs; hidden if neither)
- `STORAGE` — df gauges for `/` and `$HOME` (dedupes when same mount)
- `NETWORK` — rx/tx rates from `/proc/net/dev` deltas
- `AGENTS` — tmux session count + running agent processes

## Interactions

- Click a section header to collapse/expand it (animated).
- Click the NEXUS header block to collapse/expand everything.
- IPC: `omarchy-shell nexuslink.hud toggleAll` / `refresh` / `status` —
  bind `omarchy-shell nexuslink.hud toggleAll` to a keybind in Hyprland.

## Manage

```sh
omarchy plugin enable nexuslink.hud     # adds to shell.json plugins[]
omarchy plugin disable nexuslink.hud    # removes it
omarchy-shell shell rescanPlugins       # force re-scan after edits
```

Saving any file in this directory hot-reloads the plugin automatically.

## Notes

- Polls every 1.5 s; one `bash collect.sh poll` per tick, ~zero cost.
- GPU telemetry needs `nvidia-smi` (NVIDIA) or amdgpu sysfs
  (`/sys/class/drm/card*/device/gpu_busy_percent`, `mem_info_vram_*`, hwmon).
  Intel iGPUs typically expose no util/vram counters — the section shows
  "telemetry n/a" there (temp only if a hwmon node exists).
- Collapse state is per shell session; nothing is persisted.
