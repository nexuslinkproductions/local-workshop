# AGENTS.md

L0 router for Local Workshop. Read this, then `CONTEXT.md`, then stop. Do not crawl.

- Private repo. Backup of working source for the HUD and the local AI setup on Marcel's Omarchy box.
- Git: `main` = release, `Development` = integration. Branch off `Development`, PR into `Development`. Never push to `main`, never force-push.
- Stage with explicit pathspecs. Never commit secrets, `.env`, weights, engine builds, logs, raw result dumps, or any file over 5 MB.
- Run `python3 scripts/secret_scan.py $(git diff --cached --name-only)` before every commit; any hit blocks the commit.
- The live HUD runs from `~/.config/omarchy/plugins` (a checkout of this repo). Do not edit files there; use a worktree.
- GPU and long runs are standalone processes under `flock` on `LOCAL-AI-LAB/bench/.gpu.lock`, never inside an agent.
