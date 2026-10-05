# Device topology inventory (A3a)

Host: OmarchyLink. Board: AMD Raphael platform, Ryzen 9 7900X, 64 GB DDR5, Intel Arc B580 (xe) + AMD Raphael iGPU (amdgpu). All paths verified live on 2026-09-28. Read costs measured with `time` loops (see per-node cost). Everything listed is cheap enough for 1 s polling except where noted.

## Tree

```
machine OmarchyLink
├─ cpu_pkg0  AMD Ryzen 9 7900X (socket 0, 12C/24T, family 25 model 97)
│  ├─ ccd0   CCD0 (die 0), L3 32 MiB, cpus 0-5,12-17
│  │  ├─ core0..core5   physical cores (SMT pairs cpuN/cpuN+12)
│  ├─ ccd1   CCD1 (die 1), L3 32 MiB, cpus 6-11,18-23
│  │  ├─ core6..core11  physical cores (SMT pairs cpuN/cpuN+12)
├─ mem       64.85 GB DDR5 (33 memory blocks x 2 GiB, block_size 0x80000000)
│  ├─ dimm0  SPD5118 temp sensor at i2c 20-0051
│  └─ dimm1  SPD5118 temp sensor at i2c 20-0053
├─ pci0000:00  AMD Raphael/Granite Ridge root complex
│  ├─ 00:00.0  Root Complex [1022:14d8]
│  ├─ 00:00.2  IOMMU [1022:14d9]
│  ├─ 00:01.1  PCIe bridge -> 01:00.0 (x8@16.0, max x16@32.0)
│  │  └─ 01:00.0  Intel switch upstream port [8086:e2ff] (x8@16.0)
│  │     ├─ 02:01.0 -> 03:00.0  Intel Arc B580 GPU (card0, xe) [8086:e20b]
│  │     └─ 02:02.0 -> 04:00.0  B580 HDMI/DP audio (snd_hda_intel) [8086:e2f7]
│  ├─ 00:01.2  PCIe bridge -> 05:00.0 (x4@16.0, max x4@32.0)
│  │  └─ 05:00.0  NVMe nvme0: KINGSTON SNV3S2000G 2 TB (nvme0n1)
│  ├─ 00:02.1  PCIe bridge -> 06:00.0 (x4@16.0)  ASM/AMD chipset switch
│  │  └─ 06:00.0 [1022:43f4]
│  │     ├─ 07:0a.0 -> 0f:00.0  Realtek RTL8125 2.5GbE (enp15s0, r8169)
│  │     ├─ 07:0b.0 -> 10:00.0  MediaTek MT7922 Wi-Fi 6E (wlp16s0, mt7921e)
│  │     ├─ 07:0c.0 -> 11:00.0  AMD 800-series USB3 xHCI (usb6, usb7)
│  │     └─ 07:0d.0 -> 12:00.0  AMD 600-series SATA (ahci, empty chain)
│  ├─ 00:02.2  PCIe bridge -> 13:00.0 (x4@16.0)
│  │  └─ 13:00.0  NVMe nvme1: Samsung 980 PRO 2 TB (nvme1n1)
│  ├─ 00:08.1  PCIe bridge -> 14:00.x (x16@16.0, internal APU fabric)
│  │  ├─ 14:00.0  AMD Raphael iGPU (card1, amdgpu) [1002:164e]
│  │  ├─ 14:00.1  Radeon HD Audio (snd_hda_intel)
│  │  ├─ 14:00.2  PSP/CCP crypto
│  │  ├─ 14:00.3  Raphael USB3 xHCI (usb1, usb2)
│  │  ├─ 14:00.4  Raphael USB3 xHCI (usb3, usb4)
│  │  └─ 14:00.6  Ryzen HD Audio (snd_hda_intel, analog)
│  ├─ 00:08.3  PCIe bridge -> 15:00.0 (x16@16.0)
│  │  └─ 15:00.0  Raphael USB2 xHCI (usb5)
│  ├─ 00:14.0  FCH SMBus (piix4_smbus, i2c-20: DIMM sensors)
│  ├─ 00:14.3  FCH LPC bridge
│  └─ 00:18.0-7  Data Fabric (k10temp on 00:18.3)
├─ usb tree
│  ├─ usb1/usb2 (14:00.3), usb3/usb4 (14:00.4), usb5 (15:00.0): root hubs, no devices
│  ├─ usb6 (11:00.0, 480M root)
│  │  ├─ 6-6  ASM107x hub (480M)
│  │  │  ├─ 6-6.1  Razer Kiyo webcam (uvcvideo + usb-audio)
│  │  │  ├─ 6-6.2  Corsair Slipstream receiver (usb-audio + usbhid x2)
│  │  │  ├─ 6-6.3  Logitech USB receiver (G502 X PLUS, usbhid x3)
│  │  │  └─ 6-6.4  ASUS TUF GAMING K7 keyboard (usbhid x3)
│  │  ├─ 6-7  MSI MYSTIC LIGHT (usbhid)
│  │  └─ 6-8  MediaTek Wireless_Device (btusb, bluetooth hci0)
│  └─ usb7 (11:00.0, 10G root)
│     ├─ 7-3  Kingston DataTraveler 3.0 flash drive (usb-storage, sda)
│     └─ 7-6  ASM107x hub (5G, no children)
├─ displays (all on card0 / Arc B580)
│  ├─ DP-1      Samsung LC27G7xT 2560x1440 @ (0,0)      [main]
│  ├─ DP-2      HP E24i G4 1920x1200 @ (2560,0)         [right]
│  └─ HDMI-A-3  HP Z24n G3 1920x1200 @ (-1920,0)        [left]
├─ input
│  ├─ kbd: ASUS TUF GAMING K7 (event13/14), Corsair Slipstream kbd (event6)
│  ├─ mice: Logitech G502 X PLUS (event11/mouse2), Corsair (event10/mouse0), ASUS K7 mouse (event17/mouse1)
│  └─ misc: Power Button x2, Video Bus, PC Speaker
├─ audio (pipewire)
│  ├─ sink: alsa_output.pci-0000_04_00.0.hdmi-stereo (B580 HDMI -> LC27G7xT)
│  ├─ sink: alsa_output.pci-0000_14_00.6.analog-stereo (Ryzen HD analog)
│  ├─ sink: alsa_output.usb-Corsair...analog-stereo (Slipstream headset)
│  ├─ sink: easyeffects_sink
│  ├─ source: alsa_input.usb-Corsair...mono-fallback (headset mic)
│  ├─ source: alsa_input.usb-...Razer_Kiyo-02.analog-stereo (webcam mic)
│  └─ source: alsa_input.pci-0000_14_00.6.analog-stereo
├─ net
│  ├─ enp15s0  RTL8125, UP, 1 GbE negotiated, 34:5a:60:dd:f5:a8
│  ├─ wlp16s0  MT7922, DOWN, 7a:7a:fe:81:86:9d
│  └─ lo       loopback
└─ bluetooth
   └─ hci0  MT7922 via usb 6-8 (btusb), no paired devices
```

## Nodes, vitals, costs, collector keys

Cost legend: measured wall time of 100 reads via `cat` unless noted. All sysfs/proc reads land 0.60-0.66 ms per read. 1 s poll budget is fine for every node below.

### CPU

| id | parent | identity | vital (label, path, unit) | cost | keys |
|---|---|---|---|---|---|
| cpu_pkg0 | machine | AMD Ryzen 9 7900X 12-Core | Tctl, /sys/class/hwmon/hwmon5/temp1_input, mdegC | 0.62 ms/1k reads | dev_cpu0_id, dev_cpu0_parent, dev_cpu0_temp_mc |
| ccd0 | cpu_pkg0 | CCD0 die 0, L3 cpus 0-5,12-17 | Tccd1, /sys/class/hwmon/hwmon5/temp3_input, mdegC | 0.6 ms | dev_ccd0_id, dev_ccd0_parent, dev_ccd0_temp_mc |
| ccd1 | cpu_pkg0 | CCD1 die 1, L3 cpus 6-11,18-23 | Tccd2, /sys/class/hwmon/hwmon5/temp4_input, mdegC | 0.6 ms | dev_ccd1_id, dev_ccd1_parent, dev_ccd1_temp_mc |
| core0..core11 | ccd0/ccd1 | physical core N (cpus N, N+12) | cur freq, /sys/devices/system/cpu/cpuN/cpufreq/scaling_cur_freq, kHz | 0.61 ms | dev_core<i>_id, dev_core<i>_parent, dev_core<i>_freq_khz |

L3->CCD mapping from /sys/devices/system/cpu/cpuN/cache/index3/shared_cpu_list: 0-5,12-17 = ccd0; 6-11,18-23 = ccd1. die_id in topology/ confirms.

### Memory

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| mem | machine | 64854784 kB total DDR5 | MemAvailable, /proc/meminfo, kB | 0.66 ms | dev_mem0_id, dev_mem0_parent, dev_mem0_avail_kb |
| dimm0 | mem | SPD5118 sensor i2c 20-0051 | temp, /sys/class/hwmon/hwmon7/temp1_input, mdegC | 0.6 ms | dev_dimm0_id, dev_dimm0_parent, dev_dimm0_temp_mc |
| dimm1 | mem | SPD5118 sensor i2c 20-0053 | temp, /sys/class/hwmon/hwmon8/temp1_input, mdegC | 0.6 ms | dev_dimm1_id, dev_dimm1_parent, dev_dimm1_temp_mc |

No dmidecode. EDAC mc sysfs exists but exposes no per-DIMM rows. Two SPD5118 sensors implies 2 populated DIMM slots.

### PCIe devices (vital = current link state unless noted)

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| pci_00_01_1 | pci0000:00 | AMD PCIe bridge, x8@16.0 | current_link_speed, /sys/bus/pci/devices/0000:00:01.1/current_link_speed, GT/s str | 0.61 ms | dev_pcie0_id, dev_pcie0_parent, dev_pcie0_link |
| gpu_arc | pci_01_00_0 | Intel Arc B580 [8086:e20b], card0, driver xe | pkg temp, /sys/class/hwmon/hwmon2/temp2_input, mdegC | 0.61 ms | dev_gpu0_id, dev_gpu0_parent, dev_gpu0_temp_mc |
| snd_arc | pci_02_02_0 | B580 HDMI audio [8086:e2f7] | card present, /proc/asound/cards (card 1 PCH), bool | 0.62 ms | dev_snd0_id, dev_snd0_parent, dev_snd0_present |
| nvme0 | pci_00_01_2 | KINGSTON SNV3S2000G 2 TB, nvme0n1 | composite temp, /sys/class/hwmon/hwmon1/temp1_input, mdegC | 0.6 ms | dev_nvme0_id, dev_nvme0_parent, dev_nvme0_temp_mc |
| nvme1 | pci_00_02_2 | Samsung 980 PRO 2 TB, nvme1n1 | composite temp, /sys/class/hwmon/hwmon0/temp1_input, mdegC | 2.5 ms (100 reads 0.250 s) | dev_nvme1_id, dev_nvme1_parent, dev_nvme1_temp_mc |
| nic_eth | pci_07_0a_0 | Realtek RTL8125 2.5GbE (r8169) | temp, /sys/class/hwmon/hwmon6/temp1_input, mdegC | 0.6 ms | dev_nic0_id, dev_nic0_parent, dev_nic0_temp_mc |
| nic_wifi | pci_07_0b_0 | MediaTek MT7922 Wi-Fi (mt7921e) | phy temp, /sys/class/hwmon/hwmon9/temp1_input, mdegC | 5.5 ms (100 reads 0.547 s) | dev_nic1_id, dev_nic1_parent, dev_nic1_temp_mc |
| xhci_chipset | pci_07_0c_0 | AMD 800-series USB3 xHCI (usb6/7) | temp, /sys/class/hwmon/hwmon4/temp1_input, mdegC | 0.6 ms | dev_xhci0_id, dev_xhci0_parent, dev_xhci0_temp_mc |
| sata0 | pci_07_0d_0 | AMD 600-series SATA (ahci) | link state, /sys/bus/pci/devices/0000:12:00.0/current_link_speed | 0.6 ms | dev_sata0_id, dev_sata0_parent, dev_sata0_link |
| gpu_apu | pci_00_08_1 | AMD Raphael iGPU [1002:164e], card1, amdgpu | edge temp, /sys/class/hwmon/hwmon3/temp1_input, mdegC | 0.6 ms | dev_gpu1_id, dev_gpu1_parent, dev_gpu1_temp_mc |
| snd_apu_hdmi | gpu_apu (14:00.1) | Radeon HD Audio | card present, /proc/asound/cards (card 2), bool | 0.62 ms | dev_snd1_id, dev_snd1_parent, dev_snd1_present |
| psp | gpu_apu (14:00.2) | AMD PSP/CCP crypto | driver bound, /sys/bus/pci/devices/0000:14:00.2/driver (ccp), bool | 0.6 ms | dev_psp0_id, dev_psp0_parent, dev_psp0_bound |
| xhci_apu0 | gpu_apu (14:00.3) | Raphael USB3 xHCI (usb1/2) | driver bound, xhci_hcd | 0.6 ms | dev_xhci1_id, dev_xhci1_parent, dev_xhci1_bound |
| xhci_apu1 | gpu_apu (14:00.4) | Raphael USB3 xHCI (usb3/4) | driver bound, xhci_hcd | 0.6 ms | dev_xhci2_id, dev_xhci2_parent, dev_xhci2_bound |
| snd_apu_analog | gpu_apu (14:00.6) | Ryzen HD Audio analog | card present, /proc/asound/cards (card 3), bool | 0.62 ms | dev_snd2_id, dev_snd2_parent, dev_snd2_present |
| xhci_apu2 | pci_00_08_3 | Raphael USB2 xHCI (usb5) | driver bound, xhci_hcd | 0.6 ms | dev_xhci3_id, dev_xhci3_parent, dev_xhci3_bound |
| smbus0 | pci0000:00 | FCH SMBus (i2c-20, DIMM sensors) | driver bound, piix4_smbus | 0.6 ms | dev_smbus0_id, dev_smbus0_parent, dev_smbus0_bound |
| datafabric | pci0000:00 | AMD Data Fabric 00:18.0-7 | Tctl via k10temp on 00:18.3 (same as cpu_pkg0 vital) | 0.6 ms | dev_df0_id, dev_df0_parent |

Bridge-only nodes (00:01.0, 00:02.0, 00:03.0, 00:04.0, 00:08.0, 01:00.0, 02:0x, 06:00.0, 07:0x, 00:14.3, 00:18.x) are structural. They get id/parent keys but no vital beyond link state where the file exists.

### USB

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| usb_hub6 | xhci_chipset | ASM107x hub 6-6 (480M) | speed, /sys/bus/usb/devices/6-6/speed, Mb/s | 0.60 ms | dev_usbhub0_id, dev_usbhub0_parent, dev_usbhub0_speed |
| cam_kiyo | usb_hub6 | Razer Kiyo 6-6.1 (uvcvideo, usb-audio) | speed, /sys/bus/usb/devices/6-6.1/speed, Mb/s | 0.60 ms | dev_cam0_id, dev_cam0_parent, dev_cam0_speed |
| rcvr_corsair | usb_hub6 | Corsair Slipstream 6-6.2 | speed, /sys/bus/usb/devices/6-6.2/speed | 0.60 ms | dev_usbrcvr0_id, dev_usbrcvr0_parent, dev_usbrcvr0_speed |
| rcvr_logi | usb_hub6 | Logitech receiver 6-6.3 (G502 X PLUS) | battery, /sys/class/power_supply/hidpp_battery_0/capacity, % | 0.63 ms | dev_mouse0_id, dev_mouse0_parent, dev_mouse0_batt_pct |
| kbd_asus | usb_hub6 | ASUS TUF GAMING K7 6-6.4 | speed, /sys/bus/usb/devices/6-6.4/speed | 0.60 ms | dev_kbd0_id, dev_kbd0_parent, dev_kbd0_speed |
| msi_mystic | usb6 | MSI MYSTIC LIGHT 6-7 | speed, /sys/bus/usb/devices/6-7/speed | 0.60 ms | dev_rgb0_id, dev_rgb0_parent, dev_rgb0_speed |
| bt_radio | usb6 | MediaTek Wireless_Device 6-8 (btusb) | hci present, /sys/class/bluetooth/hci0, bool | 0.6 ms | dev_bt0_id, dev_bt0_parent, dev_bt0_present |
| usb_hub7 | xhci_chipset | ASM107x hub 7-6 (5G) | speed, /sys/bus/usb/devices/7-6/speed | 0.60 ms | dev_usbhub1_id, dev_usbhub1_parent, dev_usbhub1_speed |
| flash_kingston | usb7 | Kingston DataTraveler 3.0 7-3 (sda) | speed, /sys/bus/usb/devices/7-3/speed, Mb/s | 0.60 ms | dev_flash0_id, dev_flash0_parent, dev_flash0_speed |

Root hubs usb1-usb5, usb6, usb7 are structural (id/parent keys only).

### Displays

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| disp_dp1 | gpu_arc | Samsung LC27G7xT 2560x1440 @0,0 | status, /sys/class/drm/card0-DP-1/status, str | 0.61 ms | dev_disp0_id, dev_disp0_parent, dev_disp0_status |
| disp_dp2 | gpu_arc | HP E24i G4 1920x1200 @2560,0 | status, /sys/class/drm/card0-DP-2/status | 0.61 ms | dev_disp1_id, dev_disp1_parent, dev_disp1_status |
| disp_hdmi3 | gpu_arc | HP Z24n G3 1920x1200 @-1920,0 | status, /sys/class/drm/card0-HDMI-A-3/status | 0.61 ms | dev_disp2_id, dev_disp2_parent, dev_disp2_status |

Geometry/make/model from `hyprctl monitors -j` (4 ms, fine at 1 s but cache it).

### Input

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| input_kbd | kbd_asus | ASUS TUF GAMING K7 (event13/14) | present, /proc/bus/input/devices grep, bool | 0.67 ms | dev_input0_id, dev_input0_parent, dev_input0_present |
| input_mouse | rcvr_logi | Logitech G502 X PLUS (event11/mouse2) | battery (same as dev_mouse0_batt_pct) | 0.63 ms | dev_input1_id, dev_input1_parent |
| input_corsair | rcvr_corsair | Corsair Slipstream kbd+mouse (event6-10) | present, /proc/bus/input/devices, bool | 0.67 ms | dev_input2_id, dev_input2_parent, dev_input2_present |

### Audio (pipewire nodes)

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| pw_sink_hdmi | snd_arc | alsa_output.pci-0000_04_00.0.hdmi-stereo | node present, pw-dump, bool | 15 ms (20 dumps 0.305 s) | dev_pw0_id, dev_pw0_parent, dev_pw0_present |
| pw_sink_analog | snd_apu_analog | alsa_output.pci-0000_14_00.6.analog-stereo | node present, pw-dump | 15 ms | dev_pw1_id, dev_pw1_parent, dev_pw1_present |
| pw_sink_corsair | rcvr_corsair | alsa_output.usb-Corsair...analog-stereo | node present, pw-dump | 15 ms | dev_pw2_id, dev_pw2_parent, dev_pw2_present |
| pw_src_corsair | rcvr_corsair | alsa_input.usb-Corsair...mono-fallback | node present, pw-dump | 15 ms | dev_pw3_id, dev_pw3_parent, dev_pw3_present |
| pw_src_kiyo | cam_kiyo | alsa_input.usb-...Razer_Kiyo-02.analog-stereo | node present, pw-dump | 15 ms | dev_pw4_id, dev_pw4_parent, dev_pw4_present |
| pw_src_analog | snd_apu_analog | alsa_input.pci-0000_14_00.6.analog-stereo | node present, pw-dump | 15 ms | dev_pw5_id, dev_pw5_parent, dev_pw5_present |

One pw-dump per batch serves all six nodes. 15 ms is fine at 1 s but should be one shared call, not six.

### Network

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| net_eth | nic_eth | enp15s0 UP 34:5a:60:dd:f5:a8 | operstate, /sys/class/net/enp15s0/operstate, str | 0.64 ms | dev_net0_id, dev_net0_parent, dev_net0_state |
| net_wifi | nic_wifi | wlp16s0 DOWN 7a:7a:fe:81:86:9d | operstate, /sys/class/net/wlp16s0/operstate | 0.64 ms | dev_net1_id, dev_net1_parent, dev_net1_state |
| net_lo | machine | lo loopback | operstate, /sys/class/net/lo/operstate | 0.64 ms | dev_net2_id, dev_net2_parent, dev_net2_state |

### Bluetooth

| id | parent | identity | vital | cost | keys |
|---|---|---|---|---|---|
| bt_hci0 | bt_radio | hci0 MT7922 controller | powered/present, /sys/class/bluetooth/hci0, bool | 0.6 ms | dev_btctl0_id, dev_btctl0_parent, dev_btctl0_present |

`bluetoothctl devices` returns empty (no paired devices). 2.2 ms per call, poll at 5 s if device list is wanted.

## Throughput sources for animated link flows

| flow link | source | unit | cost |
|---|---|---|---|
| net_eth <-> machine | /proc/net/dev (enp15s0 rx/tx bytes, delta) | B/s | 0.66 ms |
| net_wifi <-> machine | /proc/net/dev (wlp16s0 rx/tx bytes, delta) | B/s | 0.66 ms |
| nvme0 <-> machine | /proc/diskstats (nvme0n1 sectors read/written x 512, delta) | B/s | 0.64 ms |
| nvme1 <-> machine | /proc/diskstats (nvme1n1 sectors x 512, delta) | B/s | 0.64 ms |
| flash_kingston <-> machine | /proc/diskstats (sda sectors x 512, delta) | B/s | 0.64 ms |
| gpu_arc engines | /sys/class/drm/card0/device/tile0/gt0/engines/{rcs,bcs,ccs} (xe; no busy% file, use gtidle or fdinfo) | % | 0.6 ms |
| gpu_apu engines | /sys/class/drm/card1/device/gpu_busy_percent | % | 0.65 ms |
| gpu_apu vcn | /sys/class/drm/card1/device/vcn_busy_percent | % | 0.65 ms |
| gpu_arc power | /sys/class/hwmon/hwmon2 power: only power1_crit/cap exposed (400 W crit, 200 W cap). No live power1_input on xe. Use temp2 (pkg) as the load proxy | mdegC | 0.61 ms |
| gpu_apu power | /sys/class/hwmon/hwmon3/power1_input (PPT) | uW | 0.63 ms |
| gpu_arc freq | /sys/class/drm/card0/device/tile0/gt0/freq0/cur_freq | MHz | 0.64 ms |
| cpu_pkg0 load | /proc/stat aggregate delta | % | 0.6 ms |
| mem throughput | not measurable per-DIMM; use /proc/meminfo Dirty/Writeback deltas as proxy | kB/s | 0.66 ms |

xe engine stats note: /sys/class/drm/card0/device/tile0/gt0/engines/rcs etc. hold only timeout/timeslice knobs, no busy counters. Per-client GPU busy is in /proc/*/fdinfo (drm-engine-*). For a single board-level number, use cur_freq (2817/2850 MHz at idle-ish) or sample fdinfo of the compositor.

## Notes for the schematic builder

- All parent ids above come from realpath ancestry in sysfs. Nothing guessed.
- The Arc B580 sits behind an Intel switch (01:00.0) on bridge 00:01.1, x8@16.0 current vs x16@32.0 max on the root port. The link downgrade is real and worth rendering.
- Both NVMe drives run x4@16.0 at their max width. nvme0 (Kingston) is on chipset bridge 00:01.2, nvme1 (Samsung) is direct on 00:02.2.
- All three displays hang off card0 (Arc). card1 (iGPU) has no connected outputs.
- Wi-Fi is DOWN. Bluetooth has zero paired devices. Both still get nodes since the silicon is present.
- hidpp_battery_0 (G502 at 95%, discharging) is the only power_supply node.
