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

## Open items

- The qwen HUD recon report (hover bug root cause with file:line, dedupe map, device-detection path, ledger data source, waybar config, visual-language brief) is being written to
  `~/.hermes/cache/scratch/profiles-quest/09-omarchy-hud-brief.md`. **Read it before starting**; it is the fastest path into this codebase.
- `~/NEXUS_AI_CENTER/nexuslink.hud` is a redundant older copy — everything unique is in the repo now.
