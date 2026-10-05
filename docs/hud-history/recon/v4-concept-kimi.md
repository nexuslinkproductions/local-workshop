# HUD v4 concept — "NERVOUS SYSTEM" (kimi lane)

A full reimagination of the three-monitor HUD. Not panels of metrics: the
machine drawn as one living organism whose anatomy you can read.

## Section index

1. Organizing idea — one sentence per monitor
2. Machinery insight — how every subsystem is shown
3. Per-monitor composition — ASCII wireframes with proportions
4. Module list — data keys, interaction, repaint trigger
5. Motion language — 7 recurring motions
6. Deletions from v3

---

## 1. Organizing idea

The v3 layout (and every candidate before it) organizes the desktop as a
cockpit: rectangular panels, each a gauge cluster, arranged on a grid. This
concept rejects the cockpit. The organizing idea is **anatomy**: the machine
is drawn as a body — a circulatory schematic, not a dashboard.

- **DP-1 (command, 2560×1440)** is the **brain stem and heart**: the reactor
  dial is the heart, the knot watermark is the mind behind it, and a single
  vertical "spinal cord" of light runs the full height of the screen carrying
  the system's vital rhythms (load, PSI stall, alert state) as travelling
  pulses — agents navigate it as the master map of the whole organism.
- **DP-2 (hardware, 1920×1200, right)** is the **body cavity**: a live
  anatomical schematic of the physical machine — CPU package with its two
  CCDs, both GPUs, PCIe tree, NVMe, USB, memory — drawn as connected organs
  with real flows of data/heat/power moving along the links between them.
- **HDMI-A-3 (ops, 1920×1200, left)** is the **field of attention**: the
  workspace/window/agent constellation drawn as a star chart — each window
  and agent is a body in orbit around the currently-focused one, with
  activity brightness and token-burn trails, so "what the machine is
  attending to" is read at a glance like a sky.

One sentence each: DP-1 is the heartbeat you command; DP-2 is the body you
maintain; HDMI-A-3 is the sky of work the machine is dreaming about.

The three screens are one organism seen at three zoom levels: rhythm (DP-1),
anatomy (DP-2), behavior (HDMI-A-3). No screen shows a "panel of metrics";
each shows a living view of the same system.

---

## 2. Machinery insight

Everything below is drawn on DP-2 (the anatomical schematic) unless noted.
The schematic is a **topology map**: nodes are organs, edges are buses, and
motion along the edges encodes live throughput. Rows of bars are forbidden
on this screen except inside node detail cards.

### The anatomical map (DP-2 field)

The field is laid out as a body seen from the front:

- **CPU package** — upper-left-centre, the largest organ. Drawn as a rounded
  silicon die outline containing **two CCD chambers** (`cpu_tccd1`,
  `cpu_tccd2` drive chamber fill hue: cyan→amber with temperature). Inside
  each chamber, its cores are small hexagonal cells (`cpu_core_<i>`,
  `cpu_cores`): cell brightness = utilization, cell edge warmth = frequency
  contribution (`cpu_mhz_avg`/`cpu_mhz_max` ratio modulates a subtle inner
  flicker). The package outline carries `cpu_temp` as a halo gradient and
  `i_pwr_w`-style power as a slow breathing rim (breath rate ∝ watts).
- **Memory banks** — a vertical stack of DIMM slots to the CPU's right
  (`dimm_count`, `dimm{i}_temp`): each DIMM a slim vertical capsule, fill =
  share of `mem_total_kb - mem_avail_kb`, warmth = its temp. Zram sits as a
  small compression vesicle attached to the stack (`zram_orig_mb`,
  `zram_used_mb`, `zram_ratio` — the vesicle visibly squeezes as ratio
  rises).
- **Arc B580 (dGPU)** — lower-left, a large angular organ on the PCIe trunk.
  `i_util` drives internal cell shimmer; `i_pwr_w`/`i_pwr_cap_w` drive the
  thickness/brightness of its power umbilical to the PSU rail; `i_temp_pkg`
  /`i_temp_vram`/`i_temp_mctrl`/`i_temp_pcie` are four thermal lobes inside
  the organ outline; `i_vram_used`/`i_vram_total` is a memory sac beside it
  with `i_vram_ch_max`/`i_vram_ch_avg` as channel striations; `i_fan_rpm`
  spins a small rotor glyph whose blade blur scales with rpm.
- **Raphael iGPU** — a small satellite organ fused to the CPU package edge
  (it *is* in the package): `a_util`, `a_vram_used`/`a_vram_total`, `a_temp`,
  `a_pwr_w`, `a_freq_mhz`. Deliberately drawn smaller and quieter — it is a
  vestigial organ on this machine, but still alive.
- **PCIe tree** — the trunk connecting CPU complex → both GPUs → NVMe
  controllers. Drawn as thick luminous vessels. **Flow particles** travel
  along each segment; particle rate/brightness ∝ measured throughput of the
  downstream device (disk bps for NVMe segments, GPU util as proxy for GPU
  segments). Link width encodes lane generation implicitly by device class.
- **NVMe storage** — right side, `nvme_count` drive organs
  (`nvme{i}_{model,temp,temp2}`), each a horizontal capsule with a thermal
  stripe (composite vs hottest-secondary as two tones) and a flow vein back
  to the PCIe trunk carrying `disk_read_bps`/`disk_write_bps` as particle
  streams (green = read inbound, cyan = write outbound). Proposed keys for
  queue pressure: `dev_nvme{i}_busy_pct` (from `/proc/diskstats` f12 delta,
  already flagged cheap in untapped.md).
- **USB / media** — small detachable pods hanging off a USB root hub node at
  the field's lower edge: `media_count`, `media{i}_name`. A pod appears with
  a dock-flash when mounted, detaches with a dissolve. Proposed:
  `dev_usb{i}_{name,class}` from sysfs for non-storage USB (keyboard/mouse/
  yubikey class glyphs only — identity, no data).
- **Peripherals with batteries** — a "limb ring" along the bottom edge:
  `bat_count`, `bat{i}_{name,pct,state}`. Each is a small organ with a
  charge sac; `Discharging` = slow drain animation of the sac, `Charging` =
  inbound trickle particles from the hub, `Full` = steady glow. Proposed:
  `dev_bat{i}_watts` (power_now) so the trickle rate is real.
- **Audio devices** — a small "ear" node near the hub: proposed
  `dev_audio{i}_{name,active}` (wpctl status via slow lane). Active stream =
  faint concentric ripple.
- **Displays** — the three monitors themselves appear as three small framed
  portals along the top edge of the map (the body seeing itself):
  `conn{i}_{name,status}` proposed from `/sys/class/drm/*/status`; DP-1's
  portal is lit brightest (it hosts the heart).
- **Network interfaces** — a pair of antenna-like ganglia at the map's right
  edge: `net_rx`/`net_tx` as inbound/outbound particle streams (rx green
  descending, tx cyan ascending), with proposed `dev_net{i}_{name,rx,tx}`
  per-interface split and `dev_wifi_{link_pct,dbm}` for the wireless
  ganglion's signal halo.
- **Bluetooth** — a faint piconet halo around the USB hub node: proposed
  `dev_bt{i}_{name,batt}` (bluetoothctl, slow lane ~15 s); devices appear as
  tiny satellites inside the halo.
- **PSI pressure gauges** — three small "artery pressure" bulbs on the
  spinal trunk: `psi_cpu_some/full`, `psi_mem_some/full`, `psi_io_some/full`.
  Bulb size pulses with `some`, a darker core with `full`. These are the
  body's blood pressure — the only "gauge" shapes allowed on the map.

Every node follows one rule: **identity + one live vital**, printed inside
or beside the organ in JetBrains Mono 11–12 px. Everything else is encoded
in the drawing itself (temperature = hue, throughput = particles, pressure
= pulse). Detail-on-demand: hovering/tapping a node opens its detail card
(the v3-style sensor rows survive only here, as a summoned card, not a
permanent panel).

### What lives on the other two screens

- **DP-1** keeps the reactor dial as the heart (fixed decision) with its
  four rings (CPU / GPU-power / MEM / NET). New: the **spinal cord** — a
  6–10 px vertical luminous column running the full field height at ~12%
  from the left edge, carrying slow travelling pulses: one pulse per second
  whose speed ∝ `load1/cpu_count`, whose color shifts cyan→amber→red with
  max PSI `full`. The cord is the organism's rhythm strip; the reactor is
  its heart. The knot watermark stays centred behind the dial at ~50%
  (fixed decision).
- **HDMI-A-3** draws the **constellation of attention**: the focused window
  (`win{i}_*` + Hyprland active) sits at centre; other windows are stars
  positioned by workspace orbit rings (`ws{i}_{id,name,mon,wins}`), size ∝
  recent CPU of their process, brightness ∝ recency of focus. Agents
  (`ag_*_{procs,cpu}`, `devsess{i}_*`, `tmux{i}_*`) are a second class of
  bodies with distinct glyph shapes (triangles vs circles), connected to
  their windows by faint tethers. Token burn (`aguse{i}_{id,tokens,status}`)
  renders as a slow meteor trail behind each agent body — the brighter the
  trail, the more it consumed today.

---

## 3. Per-monitor composition (ASCII wireframes)

Proportions are fractions of field width/height (the field excludes the
title zone, as in v3). All three keep the existing free-canvas drag engine
for the few remaining cards; the anatomical maps themselves are fixed
background scenes (like the v3 knot watermark — not draggable, click-through
outside interactive nodes).

### DP-1 — command (2560×1440) — "the heartbeat"

```
+--------------------------------------------------------------------+
| masthead: NEXUS · host · kernel · theme · clock          (h 0.04)  |
|--+--------------------------------------------------------------+--|
|  |                                                              |  |
|  |                    [ REACTOR DIAL ]                          |  |
|  |                  dial ≈ 0.55–0.62 H                          |  |
| S |              centred on SCREEN (w 0.50, h 0.50)             |  |
| P |              knot watermark behind @ 50%                     |  |
| I |                                                              |  |
| N |   left flank card          right flank card                  |  |
| A |   (load trace,             (net rx/tx +                      |  |
| L |    0.16w × 0.20h            psi bulbs,                       |  |
|   |    anchored to dial)       0.16w × 0.20h)                    |  |
| C |                                                              |  |
| O |                                                              |  |
| R |                                                              |  |
| D |                                                              |  |
|  |                                                              |  |
|  |  +----------------------------+  +-------------------------+   |  |
|  |  | AGENTS strip (0.44w)       |  | STATUS strip (rest)      |   |  |
|  |  +----------------------------+  +-------------------------+   |  |
|--+--------------------------------------------------------------+--|
  ^ spinal cord: x ≈ 0.06 W, full height, 6–10 px wide
```

- Spinal cord: full-height at x≈0.06 W (w ~0.004 W).
- Reactor chassis: centred at (0.50 W, ~0.46 H of free space); dial face
  0.55–0.62 of free height; two flank cards at 0.16 chassis-width each.
- Bottom strips: AGENTS 0.44 of open width, STATUS the remainder, bottoms
  flush with field bottom (same as v3 geometry).
- Everything else is empty dark field + ambient shader. The void is part of
  the design: the heart needs a chest cavity, not clutter.

### DP-2 — hardware (1920×1200) — "the body cavity"

```
+--------------------------------------------------------------------+
| masthead: ANATOMY · board · cpu model · governor         (h 0.04)  |
|--------------------------------------------------------------------|
|  [display portals: DP-1 · DP-2 · HDMI-A-3]               (h 0.05)  |
|                                                                    |
|   +------------------+        PSU/power rail (right edge, w 0.03)  |
|   | CPU PACKAGE      |                    |                        |
|   | (w 0.34, h 0.34) |   PCIe trunk vessels from package           |
|   | +-----+ +-----+  |===========+=================+               |
|   | |CCD 0| |CCD 1|  |           |                 |               |
|   | |hexes| |hexes|  |    +------v------+   +------v------+        |
|   | +-----+ +-----+  |    | ARC B580    |   | NVMe stack  |        |
|   |  iGPU satellite  |    | (w 0.30,    |   | (w 0.26,    |        |
|   +------------------+    |  h 0.30)     |   |  h 0.34)    |        |
|        | DIMM stack       |  VRAM sac    |   | capsules    |        |
|        | (w 0.08)         |  fan rotor   |   | +temp stripe|        |
|        v                  +--------------+   +-------------+        |
|   [zram vesicle]                |                 |                  |
|                                 |                 |                  |
|   USB hub node ---- media pods / bt halo / audio ear               |
|   (w 0.20, h 0.12, anchored bottom-left-centre)                    |
|                                                                    |
|   battery limb ring (bottom edge, h 0.10): bat organs in a row     |
|--------------------------------------------------------------------|
| STATUS strip (full width, h 0.05): cross-refs to DP-1/ops one-liners|
+--------------------------------------------------------------------+
```

- The map occupies ~0.86 of field height between portals and STATUS.
- Nodes are positioned on a fixed anatomical grid (not free-drag); only the
  detail cards and STATUS are panels in the drag engine.
- PSI artery bulbs ride the PCIe trunk at three points (cpu/mem/io).

### HDMI-A-3 — ops (1920×1200) — "the sky of work"

```
+--------------------------------------------------------------------+
| masthead: FIELD · ws count · win count · agents live     (h 0.04)  |
|--------------------------------------------------------------------|
|   workspace orbit rings (concentric, centred 0.42 W, 0.45 H):      |
|                                                                    |
|        · ws1 ring (r 0.18H)      · ws2 ring (r 0.30H)              |
|                 (focused window = central sun, ~0.06H glyph)       |
|                                                                    |
|      o win        o win                                            |
|          o agent△        o win     <- bodies on their ws rings,    |
|     o win      (SUN)        o agent△   tethered to windows         |
|          o win        o tmux▫                                      |
|                                                                    |
|   meteor trails = todayTokens per agent (aguse)                    |
|                                                                    |
|   +-----------------------------------------------------------+    |
|   | LEDGER card (right column, w 0.24, h 0.55): tokens/repo/  |    |
|   | github unread — the sky's almanac                         |    |
|   +-----------------------------------------------------------+    |
|   +-----------------------------------------------------------+    |
|   | OPS ACTIONS card (right column, w 0.24, h 0.18)           |    |
|   +-----------------------------------------------------------+    |
|--------------------------------------------------------------------|
| STATUS strip (full width, h 0.05): notifications ticker + dnd chip  |
+--------------------------------------------------------------------+
```

- The constellation occupies the left ~0.72 W; the right 0.24 W holds the
  only two "panel" survivors on this screen (ledger + actions).
- Click a body → `hyprctl dispatch focuswindow address:<addr>`; click a
  workspace ring → `hyprctl dispatch workspace <id>`; click an agent body →
  its tmux/session attach action (existing spawn patterns).

---

## 4. Module list

Legend: **trigger** = what causes repaint. All canvases keep the v3 rule:
repaint only on data change / tickSeq pulse while visible; one shared clock.

### DP-1 (command)

| Module | Data keys | Interaction | Repaint trigger |
|---|---|---|---|
| `reactor` (dial, kept) | cpu_idle/cpu_total, i_pwr_w, i_pwr_cap_w, mem_total_kb, mem_avail_kb, net_rx, net_tx, load1/5/15, cpu_temp, uptime_s, proc0_{name,cpu}, alert state | click face → cycle centre readout (clock/load/top-proc); say() chip target | tickSeq pulse on batch; eased ring motion only while values glide |
| `spine` (spinal cord) | load1, cpu_count, psi_{cpu,mem,io}_full, alert | none (ambient); hover shows numeric tooltip strip | 1 Hz pulse spawn; pulses animate via shared clock, canvas repaints only while a pulse is in transit |
| `knot` watermark (kept) | none (decorative) | none (click-through) | fxTimer only during a transition cycle (v3 gate retained) |
| `flankL` (load trace card) | load1/5/15 history | drag/resize (free-canvas); header collapse | batch + eased glide window |
| `flankR` (net + psi card) | net_rx/net_tx history, psi_*_{some,full} | drag/resize; click psi bulb → flash DP-2 trunk | batch + glide |
| `agentsStrip` | agents_tmux, agents_procs, ag_*_{procs,cpu}, ag_devin_acp | click chip → focus agent window (hyprctl) | batch (1 Hz) |
| `statusStrip` | host, kernel, theme_name, weather, pkg_updates, uptime_s, cross-ref one-liners | click weather/pkg → refresh | slow lanes (90 s/15 min) + batch |

### DP-2 (hardware / anatomy)

| Module | Data keys | Interaction | Repaint trigger |
|---|---|---|---|
| `anatomyCanvas` (the whole map background: organs, vessels, portals) | all dev/hw keys below | hover node → detail card; click node → pin card; click-through elsewhere | per-batch signature of the keys it draws; particles animate on shared clock, repaint only while any flow > 0 |
| cpu organ | cpu_core_<i>, cpu_cores, cpu_count, cpu_temp, cpu_tccd1, cpu_tccd2, cpu_mhz_avg, cpu_mhz_max, load1/5/15 | hover → per-core matrix card (v3 matrix survives here as summoned card) | batch |
| memory organ | mem_total_kb, mem_avail_kb, dimm_count, dimm{i}_temp, zram_* | hover → commit/cache/dirty detail (proposed `dev_mem_{cached,dirty,commit}_kb`) | batch |
| gpu0 organ (B580) | i_util, i_freq_mhz, i_temp_pkg/vram/mctrl/pcie, i_vram_ch_max/avg, i_fan_rpm, i_pwr_cap_w, i_pwr_w, i_vram_used/total | hover → v3 GPU sheet as card; click fan → toggle fan curve via omarchy IPC if present | batch |
| gpu1 organ (iGPU) | a_util, a_vram_used/total, a_temp, a_pwr_w, a_freq_mhz | hover → small card | batch |
| nvme organs | nvme_count, nvme{i}_{model,temp,temp2}, disk_read_bps, disk_write_bps; proposed `dev_nvme{i}_busy_pct` | hover → smart/queue card | batch |
| usb/media pods | media_count, media{i}_name; proposed `dev_usb{i}_{name,class}` | click pod → open mount in file manager (gtk-launch nautilus path) | batch + udev-ish appearance flash |
| battery organs | bat_count, bat{i}_{name,pct,state}; proposed `dev_bat{i}_watts` | click → power profile cycle (omarchy-powerprofiles) | batch (slow, 5 s lane ok) |
| net ganglia | net_rx, net_tx; proposed `dev_net{i}_{name,rx,tx}`, `dev_wifi_{link_pct,dbm}` | click → omarchy-network-status verbose card | batch |
| display portals | proposed `dev_conn{i}_{name,status}` (drm status) | click portal → `omarchy.monitor brightness` OSD | 15 s slow lane |
| audio ear | proposed `dev_audio{i}_{name,active}` | click → media status/controls | 5 s slow lane |
| bt halo | proposed `dev_bt{i}_{name,batt}` | none v1 | 15 s slow lane |
| psi bulbs | psi_{cpu,mem,io}_{some,full} | click → flash corresponding organ | batch |
| `statusStrip` | cross-refs (cpu hero %, gpu W, bat worst %) | — | batch |

### HDMI-A-3 (ops / constellation)

| Module | Data keys | Interaction | Repaint trigger |
|---|---|---|---|
| `skyCanvas` (constellation background) | win_count, win{i}_{addr,ws,wsid,class,title,mon}, ws_count, ws{i}_{id,name,mon,wins} | click body → focuswindow; click ring → workspace dispatch | hypr lane (3 s) + focus-change events |
| agent bodies | ag_{devin,opencode,hermes,october,claude,codex,haze,build}_{procs,cpu}, devsess_count, devsess{i}_{name,pid,live}, tmux_n, tmux{i}_{name,win,att} | click → attach/focus; hover → session summary marquee (devin summaries) | batch + 5 s tmux lane |
| meteor trails (token burn) | aguse_count, aguse{i}_{id,tokens,status} | hover → 7-day micro chart (recentDays via usage JSON file tap) | 20 s cache lane |
| `ledgerCard` | tokens.json (FileView), gh_ok, gh_unread, ghev_count, ghev{i}_{type,repo,age_s} | click repo row → open; click badge → clear | 60 s ledger pulse + 90 s gh lane |
| `actionsCard` | omarchy IPC (idle toggle, nightlight, media, lock, notifications clear) | buttons (existing OPS ACTIONS set) | event-driven only |
| `statusStrip` | notifications dnd, ticker from history, cross-ref one-liners | click dnd chip → toggle | 5 s lane |

Proposed `dev_*` keys (all cheap, already opened files per untapped.md):
`dev_nvme{i}_busy_pct`, `dev_bat{i}_watts`, `dev_net{i}_{name,rx,tx}`,
`dev_wifi_{link_pct,dbm}`, `dev_usb{i}_{name,class}`,
`dev_audio{i}_{name,active}`, `dev_bt{i}_{name,batt}`,
`dev_conn{i}_{name,status}`, `dev_mem_{cached,dirty,commit}_kb`,
`dev_cpu_governor`, `dev_board_{vendor,model}`, `dev_cpu_model`.
Additive-only; every module tolerates absence (contract rule retained).

---

## 5. Motion language

Seven recurring motions. Durations/easings follow design-pass.md §5 unless
noted; the shared clock drives all; nothing moves when telemetry is quiet.

1. **Flow particles** (the signature motion): small 2–3 px motes travelling
   along vessel paths (PCIe trunk, NVMe veins, net ganglia, charge
   trickles). Rate ∝ throughput (0 motes at idle — stillness means idle),
   brightness ∝ saturation vs a per-link soft cap. Motion is per-particle
   linear along the path with `OutCubic` spawn fade (120 ms) and fade-out at
   arrival (120 ms). Trigger: continuous while flow > 0; canvas repaints
   only while at least one particle is alive.
2. **State-change flash**: a node/organ edge flashes once (accent → white →
   accent, 240 ms, `OutCubic`) when its state class changes: battery
   Discharging→Charging, media pod dock/undock, alert set/clear, agent
   session live/dead (`devsess{i}_live` flips). Never loops.
3. **Spinal pulses** (DP-1): one pulse packet spawned per second at the
   cord's base, travelling upward; travel time 1.2 s at load 0 → 0.5 s at
   load ≥ cpu_count; color from PSI `full` max (cyan → amber at 10% → red
   at 25%). Easing: linear travel, `InCubic` brightness ramp at head.
4. **Knot transitions** (kept from v3): the 5-cycle shuffle-bag set
   (SCATTER / ASSEMBLE / PULSE / SPARKLE RAIN / HUE TRACE), 30–60 s jittered
   scheduler, ttfx-style staggered cell choreography. Unchanged; it is the
   mind dreaming behind the heart.
5. **Breath rims**: organ power rims (CPU package, B580 umbilical) breathe
   with a 3–6 s period inversely ∝ watts (higher power = faster, shallower
   breath), amplitude capped at 0.08 alpha — a slow biological cue, the only
   permitted continuous ambient motion besides particles. Honors
   reduced-motion (frozen at mid-breath).
6. **Focus gravity** (HDMI-A-3): when focus changes, the whole constellation
   re-orbits over 350 ms `InOutCubic`: the newly focused body glides to the
   centre as the old sun drifts back to its ring. Meteor trails stretch
   during the glide then settle. Trigger: hyprland active-window event.
7. **Alert halo** (retained, restrained): the 1.8 s single-surface pulse
   from design-pass §3 — only on the spinal cord and the offending organ;
   stops the instant the condition clears.

Forbidden motion (carried from design-pass): no comets, no rotating tick
rings, no scanlines, no perpetual blinking, no breathing on healthy status
chips, no animated grids.

---

## 6. What gets deleted from v3

Subtraction is the concept. These go entirely:

1. **The column-grid panel layout on DP-2 and HDMI-A-3.** `matrix`,
   `sensors`, `gpu`, `gpu2`, `storage`, `periph`, `memory` as permanent
   panels — all replaced by the anatomical map. Their *content* survives
   only as summoned detail cards on node hover/click. The screen stops
   being a parts catalog and becomes a body.
2. **WINDOWS/NAV, TOP PROCESSES, AGENTS (expanded), REPO ACTIVITY, LAUNCH,
   NETWORK as permanent ops panels** — replaced by the constellation.
   LAUNCH rail is deleted outright (the operator has rofi/keybinds; the sky
   shows *running* things, not launchable things). NETWORK panel's trace
   survives as the net ganglion particles on DP-2 and a one-line cross-ref
   in STATUS.
3. **The reactor's dense inner telemetry face** (hero %, L1/5/15, temps,
   mem, net, uptime, top proc, alert line all crammed in the dial): the
   dial face returns to clock + one hero value + ring tags (design-pass
   recipe). The data it carried now lives on the spine and the flanks,
   where it has room to breathe.
4. **Per-panel scanlines, double bezels, corner brackets, chamfer stacks**
   (CPanel's full ornament set) — already flagged in design-pass §2; v4
   completes the deletion: one surface, one hairline, one accent cue.
5. **The 72-notch orbiting tick corona and hot-dot arc heads on the dial** —
   the heart beats; it does not spin jewelry.
6. **Duplicate cross-home summary strips beyond one line.** v3's STATUS
   cross-references shrink to single one-liners; the anatomy/constellation
   views make most cross-refs unnecessary (you can *see* the GPU on DP-2).
7. **The settings sheet's per-panel visibility chip grid for deleted
   panels.** The map scenes are fixed; settings keeps: accent presets,
   ambient shader on/off + intensity, tick rate, detail-card persistence,
   reset layout (for the few remaining cards).
8. **`tokens` as a separate panel** — folded into the ops LEDGER card.
9. **Empty-state dash-wrapped one-liners** — replaced by the designed empty
   states (a missing battery simply has no organ on the limb ring; absence
   is drawn as absence, not as a panel saying "no data").

What is *kept*, explicitly: the reactor dial (screen-centred), the knot
watermark with its transition engine, the free-canvas drag/resize/snap
engine + JSON persistence (now serving ~6 cards instead of ~20 panels), the
agent IPC surface (focus/move/resize/show/hide/layout/panels/say — `layout`
presets redefined over the new card set), the ambient shader, the collector
contract and its additive-only rule, and the CPU budget gates (converged-skip,
per-canvas signatures, effVisible).

---

## Acceptance self-check

- Q1 organizing idea: §1, one sentence per monitor. ✓
- Q2 machinery insight: §2, every listed subsystem (CPU/CCDs/cores, both
  GPUs, PCIe, NVMe, USB, batteries, audio, displays, network, bluetooth)
  has a drawn form + identity + one live vital; topology with live flows
  preferred over bar rows. ✓
- Q3 wireframes: §3, three ASCII frames with width/height fractions. ✓
- Q4 modules: §4, every module names existing keys or proposed `dev_*`
  keys, interaction, repaint trigger. ✓
- Q5 motion: §5, seven motions with duration/easing/trigger. ✓
- Q6 deletions: §6, explicit list. ✓
