# NEXUS HUD v4 — Living system concept

## 1. Organizing idea

**The desktop is a three-screen cutaway of one living machine: DP-1 is its decision-making mind, DP-2 exposes the silicon and data fabric that power it, and HDMI-A-3 traces the work and devices flowing through its edges.**

- **DP-1 (2560×1440, centre):** the machine's command surface—one calm organism-scale state, focused through the reactor and navigable by agents.
- **DP-2 (1920×1200, right):** a live schematic of the machine's internal buses, processors, memory, graphics, and storage.
- **HDMI-A-3 (1920×1200, left):** the machine's outward connections and active work—network, displays, peripherals, audio, Bluetooth, agents, and windows.

These are not three dashboards repeating CPU/RAM bars. A fact has one primary home. Other screens may show a small directional link or a cross-reference, never a second competing instrument.

## 2. The machine as topology

### Visual grammar

The base layer is a near-black navy field (`#040e16`) with sparse, fine node-and-link contours—not a wallpaper shader. Devices are labelled nodes; their actual hierarchy is drawn as parent-child branches. Traffic is shown moving along those links. Particle cadence and link brightness follow measured throughput; direction is explicit (RX/inbound versus TX/outbound). Quiet links remain visible as hairlines so topology survives idle periods.

Each node has exactly two essentials: **identity** and **one live vital**. For example, `Arc B580 · 54 °C`, `Samsung SSD 980 PRO 2TB · 46 °C`, or `G502 X PLUS · 95%`. A node never needs a decorative gauge to qualify as alive. Selection can reveal a small detail shelf, but does not change the topology into a card grid.

Use cyan for active paths and selection; green for healthy/available; amber for elevated thermal, low capacity, or waiting; magenta only for a distinct secondary GPU/agent family; red for a real alert. Neutral text carries most information. No hue-only state: pair color with a short state word or marker.

A missing telemetry key means **unknown**, rendered as `—` or a muted dotted link, never as a false zero. Proposed collector additions are explicitly marked below; until available, those node families remain labelled “not reporting” and are not fabricated from host assumptions.

### Internal silicon and data fabric (DP-2 primary)

- **CPU package:** one parent node with current package temperature and average clock; branch to CCD 1 and CCD 2 using `cpu_tccd1` / `cpu_tccd2`, then to the 24 indexed core nodes using `cpu_core_<i>`. Each core node's vital is its own utilization percent. The tree is physically grouped by CCD only when topology mapping is available; otherwise retain a transparent “core index” grouping rather than implying undocumented core-to-CCD assignments.
- **CPU load context:** package vital and core occupancy do not replace the DP-1 system load display. `load1/5/15`, `cpu_idle/cpu_total`, `cpu_temp`, `cpu_mhz_avg/max` give whole-machine context; `cpu_count` / `cpu_cores` determine core count.
- **GPU branches:** two separate child nodes, **Intel Arc B580** and **AMD Raphael iGPU**, with a single primary live vital each (temperature). Their detail on selection shows utilization, watts, frequency, and VRAM. The B580 is fed by `i_util`, `i_temp_pkg`, `i_pwr_w`, `i_pwr_cap_w`, `i_vram_used/total`, `i_vram_ch_avg/max`; the Raphael iGPU by `a_util`, `a_temp`, `a_pwr_w`, `a_freq_mhz`, `a_vram_used/total`. Legacy `gpu_*` keys are an alternate adapter path, not a third GPU.
- **PCIe fabric:** a real parent-child tree places graphics, NVMe, and any enumerated bus device beneath the host bridge/root port when PCIe ancestry is collected. Link width/speed may be a secondary vital. Proposed contract: `dev_pcie_count`, `dev_pcie{i}_{id,parent,name,class,link_gen,link_width,active}`. Do not draw invented root ports or assert a device path until the collector can identify it. Until then, show a labelled “PCIe ancestry pending” boundary around observed endpoints.
- **Storage:** disks sit on their discovered bus branch; partitions are indented under the owning disk. Existing collector output includes `blk_count`, `blk{i}_{name,model,size_bytes,type,rota,temp}`, `blk{i}p_count`, and `blk{i}p{j}_{name,size_bytes,fstype,label,mount,used_bytes,pct}`. `nvme_count`, `nvme{i}_{model,temp,temp2}` are a useful NVMe sensor cross-check. Disk read/write throughput is the animated link vitality (`disk_read_bps`, `disk_write_bps`), with `fs_root_*`, `fs_home_*` as capacity detail.
- **USB branch:** USB mass storage is recognizable today as `blk{i}_type=usb` (the live DataTraveler device is `sda`, with `OMARCHY_202609` mounted). A full USB tree must include HID and other non-block endpoints too. Proposed keys: `dev_usb_count`, `dev_usb{i}_{id,parent,name,vendor,product,class,connected,rate}`. Show the hub/port branch and one device node per enumerated endpoint; a keyboard, receiver, storage stick, and audio interface must not collapse into one “USB” count.
- **Memory and cooling context:** `mem_total_kb`, `mem_avail_kb`, `swap_total_kb`, `swap_free_kb`, `zram_*`, `dimm_count`, `dimm{i}_temp`, `i_fan_rpm`, plus `psi_{cpu,mem,io}_{some,full}`. DIMMs branch from memory controller when discoverable. Until module identity is exposed, nodes use stable `DIMM 0`, `DIMM 1` labels. Keep pressure and thermal hints on their owning branches.

### Connected world (HDMI-A-3 primary)

- **Network interfaces:** each interface becomes a named endpoint with link state and its own RX/TX flow. Existing `net_rx/net_tx` are host-wide byte counters and can drive only an aggregate trunk. Proposed: `dev_net_count`, `dev_net{i}_{name,kind,operstate,rx_bps,tx_bps,ip,ssid,signal_pct}`. Interface children lead toward LAN/Wi-Fi/internet only where the collector has evidence. Optional verbose CLI fields (SSID, signal dBm, ping) are useful secondary readings, never substitutes for per-interface throughput.
- **Displays:** each physical output appears as its connector node with identity, mode, and connection state. Known outputs are `DP-1`, `DP-2`, and `HDMI-A-3` with 2560×1440 / 1920×1200 / 1920×1200. Use `win{i}_mon`, `ws{i}_mon` for live workspace/window attachment, but do not mistake window placement for connector state. Proposed: `dev_display_count`, `dev_display{i}_{name,status,width,height,refresh_hz,scale,active}`.
- **Battery-backed peripherals:** `bat_count`, `bat{i}_{name,pct,state}` produce peripheral nodes with battery percent as the one vital. The live stream currently reports `G502 X PLUS · 95% · Discharging`; it is not a battery-backed computer battery assumption. Additional keys such as `bat{i}_watts` / `cycles` are future enrichments, not needed for identity and charge.
- **Audio:** show enumerated output/input devices and the currently routed endpoint, linked through the audio subsystem. One vital per node: mute/running state, or level where actually exposed. Proposed `dev_audio_count`, `dev_audio{i}_{id,name,direction,default,mute,volume_pct,active}`. No guessed artist/track or live meter in the absence of those taps.
- **Bluetooth:** each adapter and paired/connected peer is its own child; connection/battery is its vital when reported. Proposed `dev_bt_count`, `dev_bt{i}_{id,parent,name,kind,connected,battery_pct,rssi}`. Distinguish “paired” from “connected”; never render a peer as connected just because it was paired earlier.
- **Removable volumes:** `media_count`, `media{i}_name` identifies mounted removable names; the `blk_*` tree gives observed USB-backed disk and partitions. A mount name alone is not a bus/device identity; use `dev_usb_*` to join these properly.

### Agentic activity (DP-1 overview, HDMI-A-3 detail)

DP-1 reduces work to a single “active work” pulse around the reactor: agent/process counts, top active harness, and whether the system is under pressure. HDMI-A-3 expands this into agents, live Devin sessions, windows/workspaces, top processes, repository activity, and per-provider usage. Existing keys: `agents_tmux`, `agents_procs`, `ag_{devin,opencode,hermes,october,claude,codex,haze,build}_{procs,cpu}`, `ag_devin_acp`, `devsess_count`, `devsess{i}_{name,pid,live}`, `tmux*`, `win*`, `ws*`, `gh_*`, `ghev*`, and `aguse*`.

The live example is a snapshot, not a fixed visual fixture: 24 CPU cores; two NVMe disks (`Samsung SSD 980 PRO 2TB`, `KINGSTON SNV3S2000G`); a USB `DataTraveler 3.0`; G502 X PLUS at 95%; 3 removable volume names; 12 Devin-session lock entries; 2 attached tmux sessions; and three connected GPU/processor identities indicated by the brief as Arc B580 plus Raphael iGPU (two GPU branches, not three). Other live readings include CPU temperature 75 °C, NVMe 42–46 °C, DIMMs 50 °C, root/home 39%, and `load1` near 5.3. The displays' dimensions and names are from the supplied measured inventory. Values are illustrative and will change.

## 3. Monitor compositions

Rectangles below describe the *visual field*, not fixed draggable panel boxes. Fractions are normalized to each screen (`x, y, w, h`); slight overlap means a link crosses an open field, not that content collides. Keep generous open canvas around the structures. The screen frame is not a bezel.

### DP-1 — Command / organism overview

2560×1440, centre. **The screen is the machine's nervous-system overview and agentic command surface.** The reactor stays centred on the physical screen centre at `(0.5, 0.5)`—not in the leftover space between panels. The always-lit pixel-knot logo remains centred behind it at roughly 50% presence. The knot is a watermark, not data, button, or panel.

```text
 y=0.00  ┌──────────────────────────────────────────────────────────┐
         │ masthead + state ribbon                         (0.04h) │
 y=.09   │  system / pressure     ╲ active-work flow  ╱ quick rail │
         │   .22w × .18h           ╲             ╱      .20w×.34h  │
 y=.30   │     ┌──────────── knot behind ─────────────┐           │
         │     │            REACTOR                   │           │
         │     │          centre (.50,.50)             │           │
 y=.71   │     └──────────────────────────────────────┘           │
         │     .38w × .46h  /  3 arcs + one hero state             │
 y=.83   │ agents & active task strip     ─────       status dock │
         │ .27w×.09h                                  .22w×.08h   │
 y=1.00  └──────────────────────────────────────────────────────────┘
          x=0                 .50                                  1
```

- Hero system module: `(0.055, 0.10, 0.22, 0.18)`—a large readable CPU/load number with a quiet load trace and pressure/thermal cue.
- Reactor: visual bounds about `(0.31, 0.27, 0.38, 0.46)`; centred exactly at `(0.50,0.50)`. One primary CPU arc, two restrained GPU-power/memory arcs; state labels stay directly legible. Keep its clock/value stable and central.
- Knot watermark: centred on screen beneath the reactor; around `0.48w × 0.66h`, low contrast, always lit at ~50%. It yields visually to content rather than being clipped/repositioned behind free space.
- Command rail: `(0.76, 0.10, 0.19, 0.34)`—few launch/action targets, no sensor inventory.
- Active work and agent status: bottom-left `(0.055,0.82,0.30,0.10)`—compact harness activity and one selected task line.
- Status dock: bottom-right `(0.75,0.84,0.20,0.08)`—clock, host/state, notifications or health summaries only.
- No detailed core matrix, device tree, sensor wall, window list, or duplicated network graph on this screen.

### DP-2 — Hardware / silicon and fabric

1920×1200, right. **The screen is a legible motherboard schematic: one processor spine branches through memory, GPUs, PCIe endpoints, and storage.** The visual flow starts with the CPU at upper centre; paths descend to device groups. Avoid a tiled wall of independent hardware cards.

```text
 y=0.00  ┌────────────────────────────────────────────────┐
         │ HARDWARE / machine identity + bus legend  .06h │
 y=.09   │ CPU package + CCD1/CCD2 + 24 core nodes        │
         │                 .90w × .20h                     │
 y=.33   │ memory / DIMM     ╲ PCIe spine ╱  Arc B580     │
         │ .22w×.18h          ╲           ╱  .25w×.22h    │
 y=.56   │ sensors + PSI  ── fabric ─────── Raphael iGPU  │
         │ .24w×.20h     /          ╲       .24w×.18h     │
 y=.77   │ NVMe branches + USB storage ─── IO/flow footer │
         │ .52w×.19h                    .30w×.14h         │
 y=1.00  └────────────────────────────────────────────────┘
          x=0                 .50                     1
```

- CPU package cluster `(0.06,0.10,0.88,0.22)` anchors the board. Draw a clear package → CCD → core hierarchy; fit 24 individually labelled utilization nodes without turning them into bars.
- Memory and DIMMs `(0.06,0.36,0.22,0.20)` attach to the CPU/memory-controller side. Pressure cues are small and on-branch.
- PCIe fabric is the central path from `(0.49,0.34)` through the middle of the screen, with real discovered parent-child links, not decorative spokes.
- Arc B580 `(0.69,0.35,0.25,0.21)` and Raphael iGPU `(0.69,0.59,0.25,0.17)` remain distinct children. Their detail rails expand in place.
- NVMe and USB storage `(0.06,0.62,0.54,0.34)` shows two NVMe disks, their partitions, and the USB DataTraveler as a sibling path. Branch labels preserve bus type and mount status.
- Sensors/PSI `(0.37,0.59,0.24,0.16)` are peripheral to topology, rendered as a narrow sensor ribbon instead of another card grid.
- Thermal criticality uses amber/red only at the node/vital; ordinary values remain neutral. Keep a short path legend at the top (activity, idle, unknown).

### HDMI-A-3 — Operations / connected-world console

1920×1200, left. **The screen is a patch-bay and workbench: live software work, network traffic, displays, audio, Bluetooth, and human-connected peripherals meet at labelled edges.** The left edge is local activity; the centre is the system boundary; connected-world endpoints occupy the right and lower edges.

```text
 y=0.00  ┌────────────────────────────────────────────────┐
         │ OPS / clock / DND / profile / live summary .06h│
 y=.09   │ windows + workspaces      ╲ boundary ╱ network│
         │ .30w×.34h                  ╲         ╱ .28w×.26h│
 y=.40   │ agents / sessions ──────── CORE ───── endpoints│
         │ .30w×.25h                  │       displays    │
 y=.66   │ repo + process ledger      │       audio / BT  │
         │ .30w×.22h                  │       .28w×.31h   │
 y=.91   │ usage + ops actions        batteries / USB     │
         │ .30w×.07h                  .35w×.08h           │
 y=1.00  └────────────────────────────────────────────────┘
          x=0                 .50                     1
```

- Workbench left rail `(0.05,0.10,0.30,0.80)` groups navigable windows/workspaces, agent/session activity, repository feed, process list, and provider usage. Each group is a view onto a work stream, not an ornamental box.
- Patch-bay trunk runs through the centre around `x=.50`, linking the machine boundary to endpoints. Network direction uses opposing RX/TX flows and a small numeric readout.
- Network module `(0.67,0.10,0.28,0.25)` shows interfaces branching toward LAN/Wi-Fi only where enumerated; global RX/TX counters remain explicitly aggregate until per-interface keys land.
- Endpoint field `(0.67,0.40,0.28,0.47)` gives connectors for DP-1/DP-2/HDMI-A-3; audio input/output; Bluetooth adapter/peers; battery-backed peripherals; and USB devices. Identity plus one vital per node.
- Bottom status strip `(0.05,0.92,0.90,0.06)` carries low-frequency GitHub/unread, package count, weather/theme, and DND state. Keep these slow sources visually still between updates.

## 4. Visual system and readability

- **Type:** Adwaita Sans for headings, labels, and prose; JetBrainsMono Nerd Font for readings, units, clocks, indices, and short IDs. Use sentence case. Numeric values use fixed-width alignment.
- **Scale:** 16 px mastheads, 13 px module headings, 11–12 px labels, 12–13 px values, and a 36 px DP-1 hero metric; reactor centre value 22 px. Never depend on sub-9 px text. Simplify content before shrinking it.
- **Colour:** canvas `#040e16`, stable dark panel surfaces, neutral `#d7e8ed` at 100/70/50/35% text tiers. Cyan `#00e5ff` is the primary active-path accent; green `#39ff14`, magenta `#ff2bd6`, amber `#ffb300`, and alert `#ff3b4e` carry meaning, not decoration.
- **Surfaces:** 6 px quiet panels, 1 px hairline at 22% neutral alpha, a single 2 px active marker where necessary. Do not surround every topology node with its own panel. The screen gets at most one subtle frame line.
- **Geometry:** 4 px base grid; 8 px row rhythm; 12–16 px group/panel breathing room. Layouts remain freely draggable/resizable/snappable and persisted as already decided.
- **Data marks:** meters are quiet 4 px tracks and solid fills; traces have only baseline/two guides and a numeric value outside the plot. Paths are hairlines with moving particles only when data changes. No continuous grid motion.
- **Interaction affordance:** selection is a wash and a short rail, not a glow ring. Small detail rails expand from a selected topology node; the node remains in place so the operator retains orientation.

## 5. Modules, data, interaction, repaint triggers

`Existing` means keys already in the collector contract or directly observed in the live stream. `Proposed` means an additive collector contract that must be implemented before the UI can claim that visibility. Every module tolerates missing fields.

### DP-1 modules

| Module | Data keys | Interaction | Repaint trigger |
|---|---|---|---|
| System hero + load trace | Existing: `cpu_idle`, `cpu_total`, `cpu_temp`, `load1`, `load5`, `load15`, `cpu_mhz_avg`, `cpu_mhz_max`, `psi_cpu_some`, `psi_cpu_full` | Agent IPC `focus` to the hero; click the trace to pin a 1/5/15 view | ~1 s stream batch; draw trace only on new sample or changed value |
| Reactor dial | Existing: derived CPU busy from `cpu_idle/total`; `i_pwr_w`, `i_pwr_cap_w`, `i_util`, `a_pwr_w`, `mem_total_kb`, `mem_avail_kb`, `net_rx/net_tx`; `clock` source from shell | Focus/pin a ring; `say` can announce a short agent context; no continuous ring rotation | Telemetry batch and clock minute/second boundary; arcs ease only on changed input |
| Knot watermark | No telemetry; fixed pixel-knot artwork | Not clickable, not draggable, not an agent target | Initial composition; ttfx transition events only |
| Command rail | `agents_tmux`, `agents_procs`, `gh_unread`, plus action availability; IPC API | Existing `show`, `hide`, `panels`, `layout`, `move`, `resize`; launch via `gtk-launch` / `omarchy-shell` | Relevant state or visibility/action change |
| Active work strip | Existing `ag_*_procs`, `ag_*_cpu`, `ag_devin_acp`, `devsess*`, `tmux*` | Select harness/session for a detail/focus action; never spawn by passive selection | Stream batch; per-session list only when entries differ |
| Status dock | Existing `host`, `kernel`, `theme_name`, `bat*`, `pkg_updates`, `weather`; optional IPC notification/profile state | Click to focus status or invoke allowed Omarchy IPC | Input key change; weather/package slow-lane updates only |

### DP-2 modules

| Module | Data keys | Interaction | Repaint trigger |
|---|---|---|---|
| CPU package/CCD/core topology | Existing: `cpu_count`, `cpu_cores`, `cpu_core_<i>`, `cpu_temp`, `cpu_mhz_avg/max`, `cpu_tccd1/2` | Select core/CCD to expand its concise sensor shelf; drag group as a single free-canvas module | Batch; per-core markers only when utilization changes |
| Memory and DIMM branch | Existing: `mem_total_kb`, `mem_avail_kb`, `swap_total_kb`, `swap_free_kb`, `zram_*`, `dimm_count`, `dimm{i}_temp`, `psi_mem_*`; proposed `dev_dimm{i}_{id,name}` | Select DIMM; no false identity when proposed name unavailable | Batch or DIMM/pressure value change |
| PCIe fabric spine | Proposed: `dev_pcie_count`, `dev_pcie{i}_{id,parent,name,class,link_gen,link_width,active}` | Select branch; detail rail shows observed ancestry and negotiated link where reported | Topology scan/change; data-flow rate changes update only affected path |
| Arc B580 node + detail | Existing: `gpu_kind/name`, `gpu{N}_{kind,name}`, `i_util`, `i_temp_pkg`, `i_temp_vram`, `i_temp_mctrl`, `i_temp_pcie`, `i_vram_ch_*`, `i_fan_rpm`, `i_pwr_cap_w`, `i_energy_uj`, `i_pwr_w`, `i_vram_used/total` | Select GPU for VRAM channels/power/thermal; collapse detail without hiding its node | Batch; selective redraw of changed thermal/power/VRAM elements |
| Raphael iGPU node + detail | Existing: `a_util`, `a_vram_used/total`, `a_temp`, `a_pwr_w`, `a_freq_mhz` | Select for utilization/VRAM/power detail | Batch; change-only values |
| NVMe / USB storage tree | Existing: `blk_*`, `nvme_count`, `nvme{i}_{model,temp,temp2}`, `disk_read_bps`, `disk_write_bps`, `fs_*`; proposed `dev_usb*` for complete peripherals | Select disk/partition; mounted volume may open/focus through an explicit action only | Topology/mount change; IO sample; temperature/capacity threshold change |
| Sensor ribbon | Existing: `cpu_tccd*`, `nvme*`, `dimm*`, `psi_*`, `i_fan_rpm`, `i_temp_*`; proposed `hwex*` | Click a sensor family to focus its hardware node | Relevant key change; no global-clock repaint |

### HDMI-A-3 modules

| Module | Data keys | Interaction | Repaint trigger |
|---|---|---|---|
| Windows and workspace switcher | Existing: `win_count`, `win{i}_{addr,ws,wsid,class,title,mon}`, `ws_count`, `ws{i}_{id,name,mon,wins}` | Click window → `hyprctl dispatch focuswindow address:<addr>`; click workspace → `hyprctl dispatch workspace <id>` | Hyprland slow lane (~3 s) or focus/workspace selection |
| Agent + session workbench | Existing: `ag_*`, `ag_devin_acp`, `devsess*`, `agents_tmux`, `agents_procs`, `tmux*` | Select/focus relevant session; `say` reports concise selected context | Process batch, tmux ~5 s, or changed session/workspace list |
| Repository activity + usage ledger | Existing: `gh_ok`, `gh_user`, `gh_unread`, `ghev*`, `aguse*`; optional richer local history is not required | Select event/repository; usage opens provider detail, not credentials | GitHub ~90 s; agent usage only on file refresh; stable between updates |
| Process ledger | Existing: `proc{0..5}_{name,cpu}` | Select row to focus matching window when resolvable | Each telemetry batch; row diff only |
| Network patch bay | Existing aggregate: `net_rx`, `net_tx`; optional verbose CLI fields; proposed `dev_net*` | Select interface; reveal address/SSID only when safe and reported | ~1 s rates or ~5 s network status; path particle density follows throughput |
| Display endpoints | Existing: `win*_mon`, `ws*_mon`, supplied screen inventory; proposed `dev_display*` | Select output to reveal mode/refresh; target workspace/window context | Connector/topology change; workspace/window slow lane |
| Audio endpoints | Proposed `dev_audio_count`, `dev_audio{i}_{id,name,direction,default,mute,volume_pct,active}` | Select default route or open audio utility; no speculative playback controls | Audio service event or sampled state change |
| Bluetooth peers | Proposed `dev_bt_count`, `dev_bt{i}_{id,parent,name,kind,connected,battery_pct,rssi}` | Select peer; optionally open system Bluetooth settings | Bluetooth event or slow bounded poll; no idle animation |
| Batteries + USB peripherals | Existing: `bat*`, `blk*`; proposed `dev_usb*` | Select device; storage mount open only through explicit action; battery detail on selection | Batch on key change; connection/removal event when available |
| Ops status strip | Existing: `gh_unread`, `pkg_updates`, `weather`, `theme_name`; IPC for DND/profile/media if integrated | `omarchy-shell` methods as supported; click status target | Slow-lane update or IPC property change |

### Shared behavior and data contract

- Maintain one primary home for each detailed fact: DP-1 shows summary, DP-2 shows silicon and storage, HDMI-A-3 shows work and external endpoints.
- Extend telemetry additively. Prefix new device families `dev_*`; include stable IDs, parent IDs, and meaningful state. Device links require a real parent relationship before they imply topology.
- Every endpoint renderer has a consistent `identity + one vital` contract and a separate, optional detail model. Missing keys create explicit unknowns, not invented nodes, values, or connectivity.
- Existing IPC remains the only command surface: focus, move, resize, show, hide, layout, panels, say. On-screen utilities use the existing Omarchy/Hyprland process interfaces; never execute from an ambiguous topology click.
- Free-canvas drag/resize/snap and JSON persistence stay. Drawn interactive regions alone enter the window mask; empty canvas remains click-through. A node tap may select; a deliberate action affordance executes.

## 6. Motion language

Motion clarifies a change, not a permanent “alive” effect. Durations/easing below are visual targets, not permission for a continuous 30 Hz repaint.

| Recurring motion | Duration / easing | Trigger and visual job |
|---|---|---|
| 1. Flow particles on active links | Traverse in 700–1400 ms, linear along the path; rate is throughput-proportional and capped | RX/TX, disk IO, or measured device traffic changes. Particles stop at idle; static hairline topology stays visible. |
| 2. Value and vital settle | 220 ms `OutCubic` | New telemetry differs by at least 0.5 percentage point or one display unit; avoid jitter while making state change readable. |
| 3. Reactor arc easing | 220–360 ms `OutCubic` | CPU/GPU/memory value update. Arcs move to value, not around the dial; no comet or rotating ticks. |
| 4. Device arrival/removal flash | 360 ms `OutCubic`, one edge wash then settle | A real topology/connectivity scan adds/removes a node. The label and state remain readable after the flash. |
| 5. Thermal/pressure alert pulse | 1.8 s single-surface soft pulse, only while alert is active; reduced-motion disables | Threshold enters alert. Use a brief halo on the owning path/node; stop at recovery, never pulse ordinary healthy devices. |
| 6. Knot ttfx transitions | 900–1600 ms transition, eased scatter/recompose with long still intervals | Explicit knot transition cycle, staggered and infrequent (roughly every 30–60 s), with constant ~50% visual presence. Not coupled to telemetry. |
| 7. Selection / detail reveal | 120 ms `OutCubic`; body reveal 180 ms `InOutCubic` | Operator or agent selects a node or expands a detail shelf; no scale bounce or spatial jump. |
| 8. Panel reflow after drag | 220 ms `OutCubic`; pointer-led drag itself is direct | Existing free-canvas move/snap/reflow operation completes. Persisted layout changes only on commit. |

Idle nodes, screen edges, plot grids, text, and the healthy knot glow remain still. Respect reduced-motion by drawing current values directly, suppressing flashes and nonessential transitions, and retaining direct pointer movement. Offscreen, collapsed, and unchanged modules do not repaint.

## 7. What v4 removes from v3

This is a structural subtraction, not a skin pass.

1. **Remove the idea that every screen is a role-specific panel workbench.** Replace three bundles of cards with three coordinated scales of one topology: organism overview, internal fabric, connected-world patch bay.
2. **Remove the freestanding panel as the default unit of meaning.** The bus/link diagram organizes hardware and external devices. Cards become selective detail shelves, not the primary visual grammar.
3. **Remove four-segment reactor density.** Keep the required screen-centred reactor, but limit it to one dominant CPU arc and at most two labelled secondary arcs. No packed telemetry face repeating every DP-1 metric.
4. **Remove constantly orbiting ticks, comets, rotating dashed rings, decorative arc passes, and ambient plasma/hex-grid shader.** Data-flow particles are meaningful and bounded; blank space is deliberate.
5. **Remove the knot's old free-space centring and five competing continuous effects.** The logo is fixed to screen centre behind the reactor, always present near 50%, with controlled ttfx-style transitions only.
6. **Remove the assumption that a handful of standalone sensor sheets are “deep insight.”** Build an explicit CPU/CCD/core + PCIe + GPU/NVMe/USB topology and expose missing bus data as missing, not as visual guesswork.
7. **Remove cross-screen status-strip repetition as the main linking mechanism.** The screens share path language and selection context; detailed metric duplication is prohibited.
8. **Remove the uniform “every monitor has a launch rail, status strip, and card inventory” template.** DP-1 is sparse and centred, DP-2 is a board schematic, HDMI-A-3 is a patch bay plus workbench.
9. **Remove default ambient shader motion and per-frame ornamental repaint.** A single shared clock is used only where a visible easing transition needs it; data-driven canvases repaint on changed signatures.
10. **Remove unsupported device claims.** No fictional PCIe ancestry, connector state, audio endpoint, Bluetooth peer, USB HID inventory, or network-interface breakdown. Stage these as additive collector work.

Retain the fixed decisions: Quickshell/QML on wlr `bottom`; native Canvas, QtQuick.Shapes, qsb ShaderEffect only where justified, and Text (no web views); click-through mask; free-canvas move/resize/snap and JSON persistence; DP-1 centre reactor and centred ~50% knot; agent IPC; the three monitor roles; and the CPU budget.

## 8. Implementation boundary and performance

The visual mock is not a web implementation proposal. Production remains QML on Quickshell, using Canvas for link/traces, QtQuick.Shapes for stable paths/arcs, Text for labels, and a small compiled ShaderEffect only if the knot transition proves cheaper/clearer than Canvas. No web views and no full-screen animated filter stack.

- One collector stream and one shared data model feed all outputs. Preserve the `key<TAB>value` additive contract and ~1 s batch framing.
- Cache derived topology and its paint signature; a change to one device must not dirty every canvas. Repaint only changed links/nodes/traces, and only while visible.
- Keep the interface under 15% of one core at idle. Idle topology is static. Particle animation exists only on active links and should be rate-limited; skip its timer when no path is active.
- Prefer event/slow-lane updates for connector, Bluetooth, audio, USB, and window structure. Do not poll hardware per pixel or invent a high-frequency collector loop.
- Proposed device discovery lands as additive collector keys. Panels degrade cleanly when absent; the first safe release can show the actual observed inventory with explicit topology-pending labels.
- Keep monitor-level interaction areas precise. Windows and launchers above the wlr bottom-layer HUD remain unobstructed. The drawn-region mask remains the only interactive surface.

## 9. Live evidence and assumptions

The requested live stream was sampled for approximately three seconds from `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud` using `./hud-collect stream`. It returned multiple ~1 s batches. Machine-specific mock/document values are from those batches, with small ordinary sample variation; they are not promises of a constant state.

- At least 24 cores are reported (`cpu_count=24`, `cpu_cores=24`); `cpu_tccd1` and `cpu_tccd2` are both emitted. Live core utilization keys span `cpu_core_0` through `cpu_core_23`.
- Existing GPU streams identify Intel values under `i_*` and AMD under `a_*`; the brief supplies the operator-facing identities Arc B580 and Raphael iGPU. The brief specifies these two branches.
- Two NVMe models were live: Samsung SSD 980 PRO 2TB and KINGSTON SNV3S2000G. A USB storage disk was live as DataTraveler 3.0. Their block-device partition topology was also emitted (`blk_*`), beyond the summarized stream contract.
- `bat0` was G502 X PLUS at 95% and Discharging. The stream also reported three removable-volume names and three `aguse` entries (Claude and Fireworks had status text; Codex had an empty status). Zero tokens in that moment are not a general provider-usage claim.
- Live Windows/agents included four reported windows, three workspaces, 12 Devin session-lock records (not all live), two tmux sessions, and GitHub unread count 50. A session-lock record is not itself a live agent process.
- `recon/devices.md` was not present when checked. Therefore no additional USB, PCIe, audio, Bluetooth, or per-interface inventory is asserted. Their proposed fields are discovery requirements, not machine facts.
- Measured monitor inventory from the brief: DP-1 2560×1440 main/centre; DP-2 1920×1200 right; HDMI-A-3 1920×1200 left.

**Acceptance lens:** the concept is successful when each live node can answer “what is it, where is it connected, and what is its current vital?” without implying missing inventory. Each screen's first glance should communicate its distinct scale before the operator reads a single detail row.
