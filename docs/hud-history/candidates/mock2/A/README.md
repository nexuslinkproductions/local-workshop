# Frosted Field

## Direction

Frosted translucent slabs float over a graphite-plum field, with faint print grain, opposed soft shadows, holographic cyan/rose rim light, and a restrained pixel-display language. Neumorphic depth gives panels tactile weight while glass translucency separates navigation, data groups, and routes. A measured cybercore layer adds acid-lime state cues, fine scanline texture, and the 48 × 49 lit pixel-knot as DP-1's energetic centrepiece. The reactor remains centred on a dark, deeply shadowed circular glass disc so its dense telemetry stays readable. DP-2 keeps an explicit inventory-board hierarchy, with the same iridescent edge lighting carried into HDMI-A-3. This direction builds on round one's warmer graphite field and rounded slabs, while now balancing them with Y2K techno energy rather than avoiding it.

## Font pairing

- **Chakra Petch 500** for navigation, headings, and interface text. Its wide geometric forms give the interface a distinct Y2K technical voice while remaining readable at panel sizes.
- **Share Tech Mono 400** for measurements, paths, timestamps, and dense telemetry. It gives the data face a crisp instrument quality without making all the interface text monospace.

Both are local WOFF2 assets in `fonts/` and are loaded through relative `@font-face` URLs. They are open-source Google Fonts distributed under the SIL Open Font License.

## Screens

- `dp1.html`: DP-1 command hub at 2560 × 1440. Ten entry tiles show machine insights and route to the Navigator. The reactor face shows a live-collector snapshot. The bottom dock samples integrations.
- `dp2.html`: DP-2 board schematic at 1920 × 1200. The CPU card shows both CCDs and all 12 cores. The board includes 2 SPD5118 DIMM sensors, AMD Data Fabric, the PCIe root and 14 bridges, both GPUs, two NVMe drives and partitions, four xHCI controllers, USB devices, audio endpoints, two NICs, and three named displays. The thermal lens button tints the node surfaces; hovering bridge chips reveals link details. All 13 configured flow sources are listed.
- `hdmi.html`: HDMI-A-3 workbench and patch bay at 1920 × 1200. It includes window/workspace cards, live agent-session states, process percentages explicitly labelled as a percent of one core, repository activity, day/month token totals, interface state, audio, Bluetooth, peripherals, clipboard, downloads, displays, and local utilities.
- `nav.html`: working mouse and keyboard Navigator. Browse `~` → `projects` → `haze`, preview `Cargo.toml`, and choose Open, Open terminal here, Copy path, or Reveal. The Processes tab provides a second navigable section. Arrow keys move the selection, Enter opens/selects, Backspace moves to the parent, and `/` focuses search. Actions are prototype affordances only.
- `index.html`: direction overview and entry point.

## Data provenance

Representative samples were read from a three-second `hud-collect stream`, `~/.local/state/nexuslink/tokens.json`, `recon/devices-bus.json`, and `recon/integrations-desktop.json`. File Navigator names and the workspace manifest preview were checked against `ls ~`, `ls ~/projects`, and `/home/nexuslink/projects/haze/Cargo.toml`. Samples are static design-time snapshots, not claims of live HTML collection. Where an integration has no player or no connected Bluetooth devices, the sample says so.

## QML implementation note

Glass can map to layered `Rectangle`s with translucent fills and edge gradients. Use one blurred static wallpaper layer behind the panels; do not blur each large panel every frame. Each slab uses two opposing soft shadows to express depth. The grain and low-amplitude scanline texture are static. The thermal lens is a state change of node colors, not a per-frame image filter.

## Assets

`fonts/chakra-petch-latin-500-normal.woff2` and `fonts/share-tech-mono-latin-400-normal.woff2` are local Latin WOFF2 files. Font copyrights are held by their respective authors and the SIL Open Font License applies.
