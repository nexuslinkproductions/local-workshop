# HUD v4 plan (figure-it-out, conductor fleet)

Root: /run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/nexuslink.hud
Decision trail: .audit/v4.tsv

## Frame

Operator asks: a useful, alive, fully reimagined three-monitor HUD. DP-1 is the
main attraction and an agentic overview. Deep insight into machinery and every
connected device. More utilities and integrations. Everything movable. CPU down.

### Done predicate (each item is checked on the live artifact, fresh quickshell PID)

- P1. TOP PROCS on DP-1 and HDMI-A-3 shows >=3 rows with real process names.
- P2. Reactor centre and knot centre are within 8 px of DP-1 screen centre (1280,720).
- P3. No panel rect leaves its screen field (fx+fw<=1, fy+fh<=1 from `panels` IPC)
      and the STATUS panel renders fully in a DP-1 screenshot.
- P4. Every draggable panel moves via IPC `move`, and the move survives a shell restart.
      Pointer-drag path verified by code trace (no synthetic pointer on this box) and by operator.
- P5. Knot mean lit brightness never drops below 45% of accent across 3 transition cycles
      (sampled by the harness), and every cycle ends on the base lit state.
- P6. DP-2 topology node count equals the device inventory count from recon/devices.md.
- P7. At least 10 integrations/utilities are live, each with real data and one working action.
- P8. quickshell CPU <= 15% of one core averaged over 60 s idle. Baseline measured 76.4% (30 s, PID 1871285).
- P9. Zero new warnings from Hud*.qml / module files in journalctl for the fresh PID.

### Scope and rigor

Large. One 6.6k-line QML file becomes a module set, collector gains device and
integration keys, three screens are recomposed. Rigor high: the live desktop is the
product, but every step is reversible (backups of Hud.qml, candidates/ dir). Gates are
the harness (verify/hudcheck.py) plus an independent verifier of a different model family.

## Graft decision (concept A = luna, concept B = kimi)

Both concepts agree on the spine: the machine as a live topology with flows on real
links, one primary home per fact, missing data shown as unknown. Grafted target:

- DP-1 "command / overview". Reactor stays screen-centred and KEEPS its v3 dense face
  (operator said "i like the reactor"; both concepts wanted to strip it, operator wins).
  Knot centred behind it, always ~50% lit, ttfx-style transitions. Around the reactor:
  a subsystem ring of summary tiles (silicon, storage, network, devices, agents, tokens)
  that each jump/focus to their home screen, kimi's vertical "vital spine" pulse strip on
  one edge (load, PSI, alert as travelling pulses), and a utility dock (the integrations).
  Agent IPC surface stays and grows (see architecture).
- DP-2 "board schematic". Kimi's anatomical layout with luna's honesty rules. CPU package
  with CCDs and 24 cores, memory/DIMMs, PCIe tree, both GPUs, NVMe + partitions, USB tree.
  Every node shows identity + one vital; links carry flow particles driven by real
  throughput. Detail shelves open on click.
- HDMI-A-3 "workbench + patch bay". Luna's layout. Left: windows/workspaces, agents and
  sessions, processes, repos/CI, token ledger. Right: patch bay of external endpoints
  (network interfaces, displays, audio, bluetooth, batteries, USB peripherals).
- Deleted: ambient hex/plasma shader, orbiting tick corona, CPanel ornament set,
  per-screen launch rail + status strip template, duplicate cross-screen metrics.
  Kimi's star-chart constellation is not built (novel but less useful for navigation).

## Phases

- Wave A (parallel, now): A1 v3 live bug fixes. A2 ttfx engine study. A3 device inventory.
  A4 integrations/utilities inventory. A5 verification harness + baseline. A6/A7 two
  structurally distinct architecture sketches (arena). A8 HTML mocks of the graft. A9 CPU
  forensics on the live shell (after A1 deploys).
- Plan gate (lead): pick/graft architecture, freeze the module contract and data shape.
- Wave B (parallel builders, disjoint files): shell + store + layout engine; collector
  dev_* and integration keys; one builder per module (reactor, knot, subsystem ring,
  vital spine, utility dock, board schematic, storage branch, GPU nodes, workbench,
  patch bay, token ledger, settings).
- Wave C: independent verification (codex verifier + sol-verifier), harness run against
  P1..P9, fix loop, deploy, screenshots.
