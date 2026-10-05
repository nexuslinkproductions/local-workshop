# LANE-P1-REPORT — CommandHub/UtilityDock/arc telemetry

Lane files touched: `v4/CommandHub.qml`, `collector/src/devices.rs` (+ this
report). `v4/UtilityDock.qml` inspected, deliberately unchanged (see §2).

## 1. codex / claude removed from provider & agent lists

- `CommandHub.qml` `tileInsight("agents")` live-harness key list — was
  `["devin","opencode","hermes","october","claude","codex","haze","build"]`,
  now `["devin","opencode","hermes","october","haze","build"]` (skeys, ~L718).
- `CommandHub.qml` `tokBars()` provider order — was
  `["devin","opencode","haze","codex","claude"]`, now
  `["devin","opencode","haze","fireworks"]` (~L894). `fireworks` is a real
  provider in `~/.local/state/nexuslink/tokens.json`, so the chart keeps its
  four-bar shape with only providers that exist.
- `grep codex|claude` over `v4/CommandHub.qml`, `v4/UtilityDock.qml`,
  `collector/src/devices.rs` → zero matches. (`Navigator.qml`/`Workbench.qml`
  still carry claude/codex rows — outside this lane's ownership.)

## 2. DEVIN / OCTOBER launch affordances

- AGENTS tile: `devin` and `october` fact rows now carry `launch` desktop ids
  (`devin-desktop`, `october` — both verified present in
  `~/.local/share/applications/`). Launch runs through the existing argv-only
  wrapper: `root.execArgv(["gtk-launch", <id>])`.
- Affordance cues: launchable rows get a `↗` tag in the label; a dead row
  shows `↗ launch` (accent2) instead of the unknown glyph.
- Implementation note — FactRow delegates sit inside EmbossedTile's `content`
  data, *under* its trailing full-tile `hoverArea` MouseArea, so a MouseArea
  nested in the delegate can never receive a click. `HubTile` therefore gains
  `rowLaunchArea`: a MouseArea held as a property and parented to the tile
  root at `z:4` (above `hoverArea`), which hit-tests the click against the
  facts column (`factsGlass.mapFromItem` + row-height division). Launchable
  row → `gtk-launch`; anything else re-emits `htile.clicked()` so the normal
  tile activation (`activateTile` → `openNav`) is unchanged. The overlay is
  `enabled` only when the tile has a launchable row, so all other tiles keep
  their original single-area click path.
- `UtilityDock.qml`: **no launcher/agent cell exists** — the 17-cell strip is
  media/notif/vol/mic/bt/clip/cap/idle/wthr/rem/upd/ws/night/pwr/disk/dl/theme,
  all system-utility integrations. Nothing suitable to hang DEVIN/OCTOBER on;
  left unchanged per the "if a launcher cell exists" condition.

## 3. Masthead garbage digits

- `CommandHub.qml:425` rendered `" · " + root.width + "×" + root.height` —
  `Item.width/height` are `real`; the panel's fractional height stringified to
  `1329.9999…` producing the "2432×1329 9999999999" tail. Both sides now go
  through `Math.round(...)` → `COMMAND HUB · DP-1 · 2432×1330`.

## 4. Arc telemetry — `dev_gpu0_pct` via xe gtilde deltas

- Selftest (`HudV4.integrationsLive`) checks
  `s.i_util !== undefined || s.dev_gpu0_pct !== undefined`. Both were
  permanently absent: xe exposes **no** `gpu_busy_percent`
  (`/sys/class/drm/card0/device/gpu_busy_percent`: No such file) — the two
  emitters only read that file, so nothing ever produced a busy% key.
  `dev_gpu0_temp/mhz/pw` were in fact already emitting; `_pct` is the one the
  gate needs.
- Fix (`devices.rs` `emit_gpus`, `GpuKind::Intel` arm): when
  `gpu_busy_percent` is absent, derive busy% from xe's per-GT idle counters —
  `tile{N}/gt{M}/gtidle/idle_residency_ms` (present here: gt0, gt1).
  `busy = (1 - Δidle/Δwall_ms)·100`, busiest GT wins, clamped 0–100. Delta
  state rides a new `DevPrev.gpu_idle` map keyed `(gpu, tile, gt)`; the first
  frame only seeds counters (same absent-then-live contract as
  `cpu_core_*`/`dev_nvme_*`). The `gpu_busy_percent` path is kept first for
  i915-era kernels.
- Sanity: `idle_residency_ms` sampled 2 s apart — gt0 +2 ms (≈100 % busy,
  compositor on 3 displays), gt1 +1902 ms (≈5 % busy) → `dev_gpu0_pct 100`
  is honest.
- `cargo build --release` clean (rustc 1.88, zero warnings).

### Evidence — `target/release/hud-collect stream auto` (batch 0 vs 1)

```
batch 0: dev_gpu0_temp 54   dev_gpu0_mhz 2850
batch 1: dev_gpu0_temp 54   dev_gpu0_mhz 2850   dev_gpu0_pw 78   dev_gpu0_pct 100
```

- Installed over `~/.config/omarchy/plugins/nexuslink.hud/hud-collect`
  (`rm` + `cp` — ETXTBSY while the live stream held the old inode; the running
  process keeps it until the coordinator restarts the shell). Post-install
  `hud-collect poll` emits `dev_gpu0_temp/mhz` + full `dev_gpu1_*` (amdgpu).

## Verify

- `qmllint` (qt6 6.11.2) exit 0 on `CommandHub.qml` and `UtilityDock.qml`.
- Shell NOT restarted — deploy/restart is the coordinator's step; the new
  binary lands on the next `collect.sh stream auto` respawn.
