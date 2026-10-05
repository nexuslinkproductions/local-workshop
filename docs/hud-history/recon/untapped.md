# Untapped-data inventory (scout lane, 2026-09-28)

Scope: `nexuslink.hud/`, `candidates/HudN.qml` (fully read), `collector/src/main.rs`
(1164 lines, fully read), `collect.sh`, `/usr/share/omarchy/shell/`, live on-disk state.

## 1. EMITTED-BUT-UNUSED keys

| Key family | Emitted at | Note |
|---|---|---|
| `aguse_count`, `aguse{i}_{id,tokens,status}` | main.rs:762-768 | Zero `aguse` refs in HudN. Live files: `~/.local/state/omarchy/agents/usage/{claude,codex,fireworks}.json` — JSON also has `ready`, `todayPrompts`, `todaySessions`, `todayTokensByModel`, `recentDays[]` (7-day chart!), `limits[]`, `tierLabel`, `authHelpText`. Biggest free win. |
| `disk_rd_sectors`, `disk_wr_sectors` | main.rs:456-457 | Only `disk_read_bps/write_bps` consumed. |
| `cpu_cores` | main.rs:354 | HudN counts `cpu_core_N` keys instead. |
| `win{i}_iclass` | main.rs:980 | Fetched (field 4) but never inserted — free. |
| `gpu_util/gpu_vram_used/gpu_vram_total/gpu_temp` | main.rs:567-570 | nvidia-smi legacy path; consumed by HudN but undocumented in stream-keys.md. |

**Cap mismatches:** emit vs render — devsess 30 on disk / emit≤12 / render≤6; tmux emit8/render6;
ghev emit6/render8 (render>emit); win emit24/render12; ws emit16/render14; bat render4; nvme render4; media render4.

## 2. CHEAP ADDITIONS (one-two lines)

Inside files already opened:

| Key | Path / change point |
|---|---|
| `runq`, `tasks_total`, `last_pid` | `/proc/loadavg` fields 4-5 — dropped at main.rs:314-318 |
| `procs_running`, `procs_blocked`, `ctxt`, `proc_forks` | `/proc/stat` non-cpu lines — loop breaks at main.rs:324-326 |
| `mem_cached_kb`, `mem_dirty_kb`, `mem_shared_kb`, `commit_used_kb`, `commit_limit_kb` | `/proc/meminfo` match arms main.rs:399-405 |
| `net{i}_{name,rx,tx}` | `/proc/net/dev` same loop main.rs:414-433 |
| `disk_busy_ms`, `disk_io_now` | `/proc/diskstats` f[12]/f[8] same loop main.rs:447-455 (delta via existing Prev.disk) |
| `psi_irq_{some,full}` | `/proc/pressure/irq` — one tuple at main.rs:667-668 |
| `wifi_link_pct`, `wifi_dbm` | `/proc/net/wireless` |
| `uptime_idle_s` | `/proc/uptime` field 2 — main.rs:308-312 already splits |

New sysfs reads:

| Key | Path |
|---|---|
| `ac_online` | `/sys/class/power_supply/*/online` type==Mains (cf. omarchy-battery-status:71-81) |
| `bat{i}_watts` | `power_now` else `current_now`*`voltage_now` |
| `bat{i}_{cycles,level}` | `cycle_count`, `capacity_level` |
| `cpu_governor` | `scaling_governor` beside existing cpufreq sweep main.rs:697-719 |
| `amd_pstate` | `/sys/devices/system/cpu/amd_pstate/status` |
| `hwex{i}_{name,temp,rpm}` | hwmon names outside current match main.rs:619-660 (nct6775/it87, case fans) |
| `conn{i}_{name,status}` | `/sys/class/drm/card*-{DP,HDMI,eDP}-*/status` |
| `board_vendor/model`, `cpu_model` | `/sys/class/dmi/id/*`, `/proc/cpuinfo` model name |
| `bl_pct` | `/sys/class/backlight/*/brightness`+max (emit-if-present) |
| `nvme{i}_state` | `/sys/class/nvme/nvme*/state` |
| `pswpin/out`, `pgmajfault` rates | `/proc/vmstat` (needs a Prev slot) |

## 3. AGENT/IPC surfaces not yet used

File taps (verified present): notifications `~/.local/state/omarchy/notifications.json`
(`{dnd}`) + `notifications/history/*.json` (10 present); coffee `indicators/stay-awake`
file presence; clipboard-history.json depth; October `core-bootstrap.json` +
`october-activity.json` (workUnits/completedTurns); Hermes `kanban.db` +
`cron/jobs.json` + `cron/executions.db`; opencode.db tokens; Devin
`summaries/<session>.md` progress prose; Haze `STATUS.md`/`tasks/*/task.toml`/`TASKS.md`.

IPC reads: `media status` (full JSON incl. title/artist/artUrl/canGoNext),
`idle status`, `nightlight status`, `notifications dndState`, `omarchy.monitor
brightness`, `lock status`.

Drop-in TSV CLIs (same key<TAB>value contract): `omarchy-network-status --verbose`
(iface/ip/ssid/signal_dbm/bitrate/router_ping_ms/internet_ping_ms — ~5s cadence),
`omarchy-battery-status --shell` (rate W, time-to-empty, cycles, threshold),
`omarchy-powerprofiles-list --active-state` → `power_profile`,
`tailscale status --json`, `omarchy-update-available`.

QML-side imports available now: `Quickshell.Services.UPower` (displayDevice battery),
`Quickshell.Services.Notifications`, `Quickshell` SystemTray.

NEVER render: credentials.toml, mcp_config.json, opencode auth.json/service.json,
provider keys, bus-principals.json.

## 4. Top-5 viz per role (density-per-pixel)

COMMAND (DP-1): env-state chip row (media artist—title + dnd/coffee/nightlight/profile
glyphs); 4th reactor ring (psi_mem or rx/tx split quadrant — `ring()` helper already
takes frac+color); AGENTS per-harness micro-bars + token counts; ping as 3rd series on
NET trace; weather/pkg/theme into command STATUS.

HARDWARE (DP-2): full hwmon sensor wall (existing `sensorRows()` pattern absorbs new
rows); disk %util + queue depth; commit+cache+dirty gauges in MEMORY; governor +
amd_pstate + per-CCD delta row under core matrix; bat watts+cycles physics line.

OPS (HDMI-A-3): AGENT USAGE ledger (aguse + todayPrompts/Sessions/limits); 7-day
activity micro-chart per agent (recentDays[].messageCount → 7×3px cols); Hermes
cron/kanban strip; devin session enrichment (raise caps, summary marquee);
notification ticker + DND chip.

## UNRESOLVED
- October port 36229 HTTP API unknown (unprobed).
- `omarchy.system-update`/`omarchy.clock`/`omarchy.bluetooth` method sets unenumerated.
- `media{i}` has name only — mountpoint/capacity needs statvfs.
- idle statusJson shape assumed `{idleEnabled, stayAwake}`.
- `ag_devin_acp` heuristic may mis-count (main.rs:883-889).
