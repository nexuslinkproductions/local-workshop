# Prompt to continue the HUD build (paste into the `default` profile)

Continue phase 3 of my Omarchy HUD build.

Read these first, in order:
1. `docs/HANDOFF-HUD.md` in the private repo `nexuslink-omarchy` (working tree `~/.config/omarchy/plugins`, branch `Development`) — deliverables, acceptance criteria, open items.
2. `docs/hud-history/` — the briefs, plans and lane reports from the earlier build passes.
3. `docs/visual-reference.jpeg` — the visual direction to merge into the current look.
4. `~/.hermes/cache/scratch/profiles-quest/09-omarchy-hud-brief.md` — recon: architecture, the hover-bug findings, the dedupe map, device detection, the token ledger, the shell modules, and the visual-language notes.

Then plan and execute with my crew. Route the work, do not grind it all yourself:
- **Orchestration:** meliodas (opus) or minato for the plan and decomposition. You hold the goal spine, dispatch, and verify landings.
- **Build:** shikamaru and kakashi (ds4f) as builders; zenitsu (qwen, UI/visual) for the design pass; gowther for specs/data work; tenten for hud-collect (Rust) and Omarchy shell changes.
- **Frontend polish pair:** claude-sonnet-5-5 at medium effort + qwen3.8-flash at high.
- **Verification:** neji (independent, never the builder) re-checks every landing. Builders never grade their own work.
- **Bot-to-bot handoff:** `hermes -p <handle> chat -c "Agent Inbox" --create-if-missing -Q -q "<brief>"`. Note `delegate_task` only spawns children inside your own profile — it cannot reach another crew member.

Work rules: all work on `Development`, PR-based, never main. Verify with live smoke on the actual desktop (quickshell reload of the running HUD), not unit tests. Keep every change reversible. Commit as you go.

Deliverables, in this order:
1. **Dedupe map first** — the same information currently appears twice across the three surfaces. Map it, commit the map, then remove the duplicates.
2. **Fix the hover behaviour** in the apps panel — elements that should brighten on hover currently read as a discovery highlight that resets.
3. **Devices panel** — always visible, never behind a tab, and it must auto-detect hotplug. Verify against the Focusrite Scarlett 2i2 and the Sennheiser MKE 600.
4. **Token ledger** — add Claude and Codex usage (claude is wired but shows "Waiting for auth"; codex is already live).
5. **Visual pass** — merge the reference style with the current one. More widgets, buttons and icons so it reads as a usable app interface integrated with the desktop. **No left-side navigation** — keep the current systematic layout.
6. **Hermes integration** — surface what Hermes and the crew are doing on the background; reuse the existing agents tile rather than adding a second surface.

The hover bug is in the **Workbench APPS tab** (confirmed) — fix it there, in the AppGrid/Workbench hover path, not the medianotch glyphs.

Report back with: what each bot did, what landed on `Development`, and anything you could not verify.
