# BRIEF: v4 visual design round 2 (competing directions)

Read R/BRIEF-V4-COMMON.md first. R = /run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/nexuslink.hud

## Operator verdict on round 1 (R/candidates/mock/*.html)
- "Too stock AI." Generic dark-navy + hairline + uppercase-tracked labels + cyan accent reads as template.
- Text overlaps in places. Zero tolerance now: every mock must pass R/verify/mockcheck.mjs.
- Reactor hard to read because the knot logo behind it is too bright. Keep the knot visibly lit
  (~50%), but give the reactor a dark backing (glass disc) and a real drop shadow so it separates.
- Fonts feel "too AI" (Adwaita Sans + JetBrains Mono are out as the primary voice).
- Wanted style: **neumorphism + glassmorphism mixed with cybercore**. Think tactile soft-extruded
  dark surfaces and frosted translucent glass slabs, plus cybercore energy (Y2K techno, holographic
  edge light, pixel/dot-matrix or wide technical display type, acid accents, scanline/grain), used
  with taste. Not neon-on-navy.
- Likes: the board schematic idea (DP-2). Wants more on it (see below).

## What each screen must be
- DP-1 (2560x1440) COMMAND HUB. An informational navigation hub that leads everywhere on the system
  and gives short useful insights on what is going on. The reactor stays centred (dense face kept,
  now readable). Around it: hub tiles that are entry points (Files, Processes, Devices, Agents,
  Repos/CI, Network, Storage, Media, Settings/System, Tokens), each showing one short live insight
  sentence, e.g. "2 updates ready: aether, mise-bin", "Chrome at 18% of a core", "nvme1 48°C, 1.3 TB
  free", "3 Devin sessions live", "50 unread GitHub notifications". Plus a utility strip (see below).
- DP-2 (1920x1200) BOARD SCHEMATIC, richer. Real inventory from R/recon/devices-bus.json (78 nodes):
  CPU package with 2 CCDs (CCD0 = cpus 0-5,12-17, CCD1 = 6-11,18-23) and 12 cores/24 threads,
  data fabric, 2 DIMMs (SPD5118 temp sensors on SMBus), PCIe root + 14 bridges with link gen/width,
  Arc B580 (xe) and Raphael iGPU (amdgpu), 2 NVMe with partitions, SATA controller, 4 xHCI USB
  controllers with the real USB tree (camera, 2 wireless receivers incl. Corsair Slipstream, ASUS TUF
  K7 keyboard, RGB controller, MT7922 Bluetooth, DataTraveler stick), 3 PCI audio devices with
  PipeWire sinks/sources, 2 NICs (enp15s0 up, wlp16s0 down), 3 displays with model names (Samsung
  LC27G7xT, HP E24i G4, HP Z24n G3), flow particles on links with real throughput (13 flow sources).
  Add a power/thermal lens toggle (heat tint per node) and a per-link bandwidth readout on hover.
- HDMI-A-3 (1920x1200) WORKBENCH + PATCH BAY, less limited: windows/workspaces with thumbnails-like
  cards, agent sessions with state and last activity, process ledger labelled "% of one core",
  repos with dirty/ahead state and CI, token ledger day/week/month, network interfaces, audio
  routes with volume, bluetooth, peripherals with battery, clipboard recents, downloads.

## New: the Navigator (drill-down UI)
Pressing a hub tile opens a full navigation system, "similar to Omarchy's menu but better": a
focused overlay surface with keyboard + mouse navigation, breadcrumbs, search-as-you-type, preview
pane, and actions. Show it in a 4th mock file `nav.html` as a working prototype with at least:
Files (browse ~ → Projects → a repo, preview a text file, actions: open, open terminal here, copy
path, reveal), and a second section of your choice (Processes or Devices). Arrow keys / Enter /
Backspace / `/` for search must work in the mock. Use realistic paths from this machine
(`ls ~`, `ls ~/projects`).

## Utilities (from R/recon/integrations-desktop.json, ranked by the inventory lane)
Media/MPRIS, notifications + DND, audio volume + sink, mic mute, clipboard history, screenshot /
OCR / colour picker, idle inhibit, weather, reminders/timers, system updates, workspace overview,
night light, power profile, network, disk usage, recent downloads, theme. Show real sample values
from that JSON where present.

## Fonts
Pick your own pairing that fits your direction and is NOT Adwaita Sans / JetBrains Mono / Inter /
Geist. Candidates (free): Departure Mono, Doto, Sixtyfour, Silkscreen, Kode Mono, Martian Mono,
Monaspace (Argon/Krypton/Xenon/Radon), Commit Mono, Chakra Petch, Tektur, Michroma, Oxanium,
Rajdhani, Share Tech Mono, Unica One, Space Mono. Download the font files (GitHub releases or
Google Fonts) into your own mock folder and load them with @font-face from relative paths, so the
mock is self-contained. Name the pairing and why in your README.

## Deliverable
Your folder (named in your dispatch): dp1.html (2560x1440), dp2.html, hdmi.html, nav.html, index.html,
fonts/, README.md (direction name, one-paragraph rationale, font pairing, what you changed vs round 1).
Real values from `L/hud-collect stream` (3 s), ~/.local/state/nexuslink/tokens.json, and the R/recon/*.json files.
Must be implementable in QML later: frosted glass = layered translucent rects + blurred backdrop
(MultiEffect blur of the static wallpaper layer is affordable once, not per frame), neumorphic depth =
two offset soft shadows, no per-frame filters over large areas.

## Gate (hard)
Before finishing, run `node R/verify/mockcheck.mjs <your folder>` (another lane is building it; if it
does not exist yet, wait and retry for up to 15 minutes). Fix everything it reports: overlapping text
boxes, text clipped by its container, text outside the viewport, contrast below 4.5:1 for body text.
Report its final output and exit code.

FORBIDDEN: editing other lanes' folders, any .qml/.rs, anything under ~/.config.
