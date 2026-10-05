# HANDOFF — Omarchy background HUD, phase 3 (frontend + Hermes integration)

Written 2026-10-05. Carry-over from the profile/crew session. Everything here is self-contained:
the new session needs no access to that session's history.

## Repo (work here, not in a copy)

- **github.com/nexuslinkproductions/nexuslink-omarchy** (private)
- Working tree = `~/.config/omarchy/plugins` — this IS the live Omarchy plugin dir, in place. Nothing was moved.
- Branches: `main` = release, **`Development` = work base** (checked out). Ship = PR to Development; release = Development to main.
- `.gitignore` tracks only `nexuslink.*/`, `collector/`, `docs/`. Third-party plugins in that dir stay untracked.
- `plugins/nexuslink.hud/` = the QML HUD (Hud.qml is v3 in place, `v4/` holds the newer component set).
- `plugins/nexuslink.medianotch/`, `plugins/nexuslink.taskbar/` = the other two surfaces.
- `collector/` = Rust `hud-collect` source (produces the live stream the HUD reads).
- `docs/hud-history/` = prior briefs, plans, lane reports, design mockups (`candidates/`). Read these first, they contain decisions already made.
- NOT in the repo: fonts at `~/.local/share/fonts/nexushud` (14M, install step documented separately), runtime state `~/.config/omarchy/nexuslink/hud-state*.json`.

## What phase 3 must deliver (Marcel's request, verbatim intent)

1. **Token ledger: add Claude and Codex.** He now uses both. Find the real usage source (Hermes logs / state db / provider usage files), then add those two providers to whatever the ledger renders today.
2. **Fix the hover bug.** In the apps panel, icons and elements are lit up at rest, and darken when the cursor passes over them. It reads as a "discovery" highlight that keeps resetting. Root cause first — find the state binding, do not patch the symptom.
3. **Visual direction.** Merge the current look with the reference `~/Downloads/WhatsApp Image 2026-10-05 at 5.58.54 PM.jpeg` (a copy should be committed under `docs/`). Wanted: more widgets, buttons and icons so it feels like a usable app interface integrated with the desktop and the background, futuristic, feels like a native extension of Hermes rather than a separate app.
   - **He does NOT want a left-side navigation menu.** Keep the existing systematic layout.
   - All three backgrounds are up for restyle: the concept is fine, the visual style is not what he is after.
4. **De-duplicate.** The same information must never appear twice in different forms anywhere across the dashboards. Produce a dedupe map first, then remove.
5. **Devices panel: always visible, never behind a tab, and auto-detecting.** It must pick up hotplug. New hardware to verify against: **Focusrite Scarlett 2i2** and **Sennheiser MKE 600** mic. Use a real detector (udev / `pactl subscribe` / pw-dump), not a poll-on-load snapshot.
6. **Background + Hermes integration.** The overall goal is an all-in-one Hermes workstation: the background HUD should surface what Hermes is doing. Later add-on: a **waybar module showing crew/bot status**.

## Lanes and skills to use

- Frontend pair: **Sonnet 5.5 medium + qwen 3.8 flash at high reasoning** (Marcel's pick).
- Skills available: superpowers (brainstorming, writing-plans, subagent-driven-development, verification-before-completion), `archify`, pstack / `poteto-mode`, Matt Pocock's skills, `frontend-design`, `ui-ux-pro-max`, plus newly installed `adversarial-ux-test`, `accessibility-review`, `web-design-guidelines`, `ux-copy`.
- Verification rule: mechanism + live smoke + behavioral matrix on the actual desktop, never unit-test theater. A builder never grades itself.

## Acceptance criteria

- Ledger shows Claude + Codex usage, sourced from a real data path, with the source named in the code.
- Hover behaves correctly (hover = brighten, not the reverse), proven on the live HUD.
- No info shown twice anywhere across the three surfaces; dedupe map committed.
- Devices panel visible without a tab click, and picks up a freshly plugged Scarlett 2i2 without a restart.
- Visual pass matches the merged direction; no left nav; reads as one integrated interface.
- All work on `Development`, PR-based, HUD still runs (`hud-collect` + quickshell reload verified after each change).

## Recon findings (from the phase-3 recon agent — full detail in the scratch brief)

- **Architecture.** The dashboard is a Quickshell/QML plugin: `Hud.qml` loads `v4/HudV4.qml`; one
  PanelWindow per output on `WlrLayer.Background`. Rust `hud-collect stream auto` feeds it at 1 Hz.
  Three surfaces: **DP-1 = CommandHub** (reactor), **DP-2 = BoardView** topology + OPS,
  **HDMI-A-3 = Workbench** (process/token/agent panes + APPS and DEVICES tabs).
- **The deployed code is ahead of `~/NEXUS_AI_CENTER/nexuslink.hud`** — e.g. `CommandHub.qml` there
  lacks the LANE-AI1 changes, and `deploy.sh` never ships `v4/`. The live plugin dir is the truth.
- **Hover bug:** no lit→dark binding exists in the v4 AppGrid. The only literal match is the
  medianotch transport glyphs (`Notch.qml:740`, white→cyan reads darker). AppGrid hover only adds a
  `ruleDark` keyline, and selected rows ignore hover (`AppGrid.qml:826-828`). **Surface CONFIRMED by Marcel
  (2026-10-05): the Workbench APPS tab.** So the fault is in the Workbench/AppGrid hover path
  (v4/AppGrid.qml plus the Workbench APPS wiring), not the medianotch glyphs.
- **Dedupe map exists:** 11 rows — tokens ×3, devices ×5, processes ×4, agents ×4-5, clock ×5.
- **Devices:** today's detection is a sysfs USB scan (1 Hz) plus a slow `pactl list sinks` lane.
  The MKE 600 is invisible by design — it is a Scarlett Mic1 input, confirmed live via
  `pactl list sources`. Fix: enumerate sources + a generic hotplug delegate. No udev/Python daemon.
- **Token ledger:** `tokens/ledger.py` → `~/.local/state/nexuslink/tokens.json`. It already folds
  the Omarchy usage snapshots: **codex is live** (~150M tok/day), **claude is wired but shows
  "Waiting for auth"**. `~/.hermes/usage/*.json` is already being collected.
- **There is no waybar.** The bar is `~/.config/omarchy/shell.json` Quickshell modules, and
  `omarchy.agents` is already the provider lane. A crew-status module = clone of `plugins/agents/`,
  or simply reuse the HUD's agents tile.
- **Visual language ("Codex blue-glass"):** keep the 3-deck layout and no left rail; acid-and-ice
  palette. Borrow the ring-gauge, card glow, template-store strip and the Lucide-in-well icon idiom
  as roughly five token-level edits.

## Open items

- The qwen HUD recon report (hover bug root cause with file:line, dedupe map, device-detection path, ledger data source, waybar config, visual-language brief) is being written to
  `~/.hermes/cache/scratch/profiles-quest/09-omarchy-hud-brief.md`. **Read it before starting**; it is the fastest path into this codebase.
- `~/NEXUS_AI_CENTER/nexuslink.hud` is a redundant older copy — everything unique is in the repo now.
