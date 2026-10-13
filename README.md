# Local Workshop

Marcel's private workshop repo: everything that makes this Omarchy box ours, kept as one backup with PRs, branches and worktrees.
It holds the HUD plugins (Quickshell/QML) and the local AI setup: llama-swap serving, the Chief assistant evals, benchmark scripts and the research log.
It is a faithful backup of working source on this machine, not a portable install: many scripts hard-code `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB`.
Weights, engine builds, logs, raw result dumps and secrets never enter the repo (see `.gitignore`, enforced by `scripts/secret_scan.py`).
Git flow: `main` = release, `Development` = integration, work on `<type>/<slug>` branches, PR into `Development`, never push to `main`.

## Map

| Path | What |
|---|---|
| `AGENTS.md`, `CONTEXT.md` | ICM routers: where am I, where do I go. Read, then stop. |
| `nexuslink.hud/`, `nexuslink.medianotch/`, `nexuslink.taskbar/`, `collector/` | HUD plugins. This repo root is also `~/.config/omarchy/plugins`, so these stay at the root for now (phase 2 moves them under `hud/`). |
| `docs/` | `HANDOFF-HUD.md`, `hud-history/` (HUD), plus `research/` (numbered findings, markdown only), `reports/` (status pages), `notes/`. |
| `local-ai/serve/` | llama-swap `config.yaml`, launch scripts, `local-ai.service`, Hermes provider snippet. |
| `local-ai/bench/` | Benchmark, watchdog and matrix scripts (code only; state, logs and `.env` configs stay local). |
| `local-ai/evals/chief/` | Chief assistant eval harness (`run_suite.py`) and fixtures. Client-named files are held out. |
| `local-ai/voice/`, `local-ai/llm/`, `local-ai/imagegen/workflows/`, `local-ai/legacy/` | TTS/STT bench scripts, LLM build script, ComfyUI workflow JSON, old chat launchers. |
| `scripts/` | `secret_scan.py`: grep fallback scanner (gitleaks is not installed). |

Planned, not yet here: `system/` (sysctl, udev, tmpfiles, systemd units), `scripts/bin/`, `.github/` templates, `local-ai/chief/`.
