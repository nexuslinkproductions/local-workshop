# API Drift Audit — v4/ (read-only, codex verifier)

## Findings

### B1) `qmldir` missing exported component types
- `v4/qmldir:1-14` exports only singletons (Topology, FlowBus, Style, Theme) + GlassPane, EmbossedTile, Tag, ScanOverlay, KnotField. Missing: `Navigator`, `CommandHub`, `BoardView`, `Workbench`, `UtilityDock`. Runtime: `Type ... is not a type`. **BLOCKER**

### B2) Unknown-sentinel contract mismatch (Topology → Workbench)
- `v4/Topology.qml:18,38` sentinel = `{ "__nxUnknown": true }`; `v4/Workbench.qml:257-266` checks only undefined/null/"" then `String(x)` → `"[object Object]"`. **BLOCKER**

### W3) Kind-enum drift (Topology → Workbench filters)
- Workbench asks `netif`/`pw_sink`/`pw_source`/`bluetooth`/`xhci`/`usb_roothub`/`usb_hub`; Topology emits `nic`/`audio`/`bt`/`usb`. Sections silently empty. **WARN**

### W4) Style API drift
- `v4/Workbench.qml:51` uses `Style.f.body`; Style has `display`/`mono`/`px*`/`ls*`. Guarded fallback, no crash. **WARN**

### B5) CPU-budget violation — perpetual timers in UtilityDock
- `v4/UtilityDock.qml:450-455` + poll instances to ~603: repeating 2s–60s timers independent of telemetry cadence. **BLOCKER**

### B6) CPU-budget violation — perpetual timers in CommandHub
- `v4/CommandHub.qml:291-315`: 3s AV poll + 30s power poll. **BLOCKER**

### B7) Fabricated telemetry — Workbench zero-fallback
- `v4/Workbench.qml:65-68,138-140,186-195`: `num(undefined)→0` on absent keys produces fake zeros. **BLOCKER**

## Verdict: FAIL (4 blockers). Verifier: codex `verifier` profile, cross-checked both sides of each pair.
