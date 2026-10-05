# LANE-C-REPORT — dev_* collector keys (BRIEF-V4-BUILD, lane C)

Files written: `collector/src/devices.rs` (new), `collector/src/main.rs` (wiring only:
`mod devices`, `DevPrev` state, `emit_devices` call in stream + poll, `audio_bt_poll`
timer in the slow lane). No other files touched.

## Verification (commands and exit codes)

| Command | Exit |
|---|---|
| `cargo build` (in `collector/`) | 0 |
| `cargo test` (0 tests exist) | 0 |
| `timeout 7 ./target/debug/hud-collect stream` (5 batches captured) | 124 (timeout, expected) |
| `./target/debug/hud-collect poll \| grep -c '^dev_'` | 110 keys, exit 0 |

Rate keys (`*_pct`, `*_pw`, `*_rd`, `*_wr`, `dev_nic_*_rx/tx`) need a previous frame.
They appear from batch 1 onward in stream mode. Poll mode is a single batch so they are
absent there. This matches the existing `i_pwr_w` / `disk_read_bps` design.

## Emitted keys and sources

All keys ride the existing 1 Hz stream cadence (`key<TAB>value`, `batch<TAB>n` sentinel).
A key for absent hardware is not emitted. No key below is ever a fabricated 0.

### CPU cores — `dev_core{i}_mhz`, `dev_core{i}_pct`

- `i` = physical core 0..11, SMT pairs grouped via
  `/sys/devices/system/cpu/cpu{N}/topology/thread_siblings_list` (e.g. "0,12"), so
  `dev_core0` = topology node `core0` (cpu0/cpu12) in `recon/devices-bus.json`.
- `dev_core{i}_mhz` — `/sys/devices/system/cpu/cpu{rep}/cpufreq/scaling_cur_freq`
  (kHz / 1000; `rep` = lowest thread id of the group).
- `dev_core{i}_pct` — `/proc/stat` `cpuN` lines: busy% of the SMT pair =
  100 × (1 − ΣΔidle / ΣΔtotal), idle = idle+iowait, against the previous batch.

### CCD temps — `dev_ccd0_t`, `dev_ccd1_t`

- `/sys/class/hwmon/hwmon*/temp{N}_label` == `Tccd1` → `dev_ccd0_t`, == `Tccd2` →
  `dev_ccd1_t`; value from sibling `temp{N}_input` (m°C / 1000). Hwmon name `k10temp`
  or `zenpower`. Live: hwmon5 (k10temp).

### DIMM temps — `dev_dimm{i}_t`

- `/sys/class/hwmon/hwmon*/name` == `spd5118` (or `spd5100`), value
  `temp1_input` (m°C / 1000), sorted hwmon order. Live: hwmon7, hwmon8 (DIMM slots
  0/1 in `devices-bus.json`).

### GPU vitals — `dev_gpu{i}_{temp,pct,pw,mhz,vram}`

`i` = same enumeration as `probe` mode `gpu{i}_*` (drm card order: gpu0 = Intel Arc
B580 `card0`, gpu1 = AMD Raphael iGPU `card1`).

| Key | Intel (xe) source | AMD (amdgpu) source |
|---|---|---|
| `dev_gpu{i}_temp` | hwmon `xe`, temp with label `pkg` (`/sys/class/drm/card0/device/hwmon/hwmon2/temp2_input`) | hwmon `amdgpu` `temp1_input` (edge) |
| `dev_gpu{i}_pct` | `.../device/gpu_busy_percent` (absent on this xe kernel: key not emitted) | `.../device/gpu_busy_percent` |
| `dev_gpu{i}_pw` | hwmon `energy1_input` delta (µJ → W), needs prior batch | hwmon `power1_input` (µW → W) |
| `dev_gpu{i}_mhz` | hwmon `freq1_input` (Hz), else `/sys/class/drm/card0/device/tile0/gt0/freq0/cur_freq` (MHz) | hwmon `freq1_input` (Hz → MHz) |
| `dev_gpu{i}_vram` | `.../device/mem_info_vram_used` (B → MiB; not exposed by xe: key not emitted) | `.../device/mem_info_vram_used` (B → MiB) |

`gpu_busy_percent`, `mem_info_vram_*` are read at
`/sys/class/drm/card{N}/device/`. Nvidia/other GPUs: no keys (no sysfs surfaces
used by the existing collector for them either).

### PCIe links — `dev_pcie_{bdf}_gen`, `dev_pcie_{bdf}_width`

- `/sys/bus/pci/devices/{bdf}/current_link_speed` ("16.0 GT/s PCIe" → gen 4) and
  `/sys/bus/pci/devices/{bdf}/current_link_width` ("8" → 8). Emitted for every BDF
  exposing both files (36 devices live: 72 keys). Host-bridge/function devices
  without link files are skipped.

### NVMe — `dev_nvme{i}_{t,rd,wr}`

- `i` = controller number, `/sys/class/nvme/nvme{i}` (nvme0 = KINGSTON, nvme1 =
  Samsung, same mapping as `devices-bus.json`).
- `dev_nvme{i}_t` — `temp1_input` (m°C / 1000) of the hwmon dir inside the
  controller dir (`/sys/class/nvme/nvme{i}/hwmon*/`).
- `dev_nvme{i}_rd` / `dev_nvme{i}_wr` — `/proc/diskstats` row `nvme{i}n1`,
  fields 6/10 (read/write sectors) × 512 B, delta over previous batch (B/s).

### NICs — `dev_nic_{name}_{up,rx,tx}`

- Every iface in `/sys/class/net/` except `lo` (live: `enp15s0`, `wlp16s0`).
- `dev_nic_{name}_up` — `/sys/class/net/{name}/operstate` ("up" → 1, else 0).
- `dev_nic_{name}_rx` / `_tx` — `/proc/net/dev` `{name}:` row, fields 1/9
  (rx/tx bytes), delta over previous batch (B/s). Zero is a true measured rate
  (e.g. wifi down, no traffic), not a placeholder.

### USB — `dev_usb_{vid:pid}_{name,batt}`

- Devices = dirs in `/sys/bus/usb/devices/` that are neither interfaces (contain
  `:`) nor root hubs (`usbN`); 9 devices live.
- `{vid:pid}` — `idVendor` / `idProduct` files in the device dir (e.g. `046d:c547`).
- `_name` — `product` file, else `manufacturer`; device skipped when both empty.
- `_batt` — `/sys/class/power_supply/*/capacity` whose `device` symlink resolves
  under that USB device dir (longest-prefix match, so a hub never swallows a leaf
  battery). Live: `046d:c547` (G502 X PLUS receiver) at 90%.
- Duplicate vid:pid on the bus: first device (sorted) wins.

### Audio — `dev_audio{i}_{name,sink,vol}`

- Slow lane (~3 s refresh, cached, dumped each 1 Hz batch): `pactl list sinks`.
  `_name` = `Description:`, `_sink` = `Name:`, `_vol` = mean channel percent of the
  `Volume:` line. 4 sinks live (Corsair USB, Ryzen analog, Easy Effects, HDMI).
  Stale keys are dropped on each refresh (sinks that vanish do not linger).

### Bluetooth — `dev_bt_paired`, `dev_bt_conn`

- Slow lane, gated on `/sys/class/bluetooth/hci0` existing (radio absent → no keys).
  `bluetoothctl devices Paired` / `devices Connected`, counted `Device ` lines.
  Live: 0 and 0 (hci0 present, no paired devices: a true count, not a placeholder).

### Fans — `dev_fans{i}_rpm`

- Every `fan{N}_input` across `/sys/class/hwmon/hwmon*/`, sorted by (hwmon, N);
  `i` = running index. Live: hwmon2 (xe) fan1, the Arc B580 fan, ~1000 RPM.

## Syscall budget

Per 1 Hz frame: /sys + /proc reads only (no subprocess; ~200 small sysfs reads,
dominated by the 36-device PCIe walk). The two subprocess probes (`pactl`,
`bluetoothctl`) run in the existing slow-lane thread at ~3 s cadence, never per
frame, matching the `gh`/`tmux`/`hyprctl` pattern already in main.rs.

## Verified sample (stream, batch 1+)

```
dev_ccd0_t 63        dev_dimm0_t 50      dev_dimm1_t 49
dev_core0_mhz 4972   dev_core0_pct 10    dev_fans0_rpm 1012
dev_gpu0_temp 39     dev_gpu0_pw 42     dev_gpu0_mhz 1200
dev_gpu1_temp 50     dev_gpu1_pct 0     dev_gpu1_pw 17     dev_gpu1_mhz 600  dev_gpu1_vram 15
dev_pcie_0000:00:01.1_gen 4   dev_pcie_0000:00:01.1_width 8
dev_nvme0_t 39  dev_nvme0_rd 40750  dev_nvme0_wr 112743
dev_nic_enp15s0_up 1  dev_nic_enp15s0_rx 104666  dev_nic_enp15s0_tx 10650
dev_usb_046d:c547_name USB Receiver  dev_usb_046d:c547_batt 90
dev_audio0_vol 60   dev_bt_paired 0    dev_bt_conn 0
```
