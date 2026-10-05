# Dev/agent integrations inventory (A11)

Scope: DEV and AGENT integrations for an agentic-OS HUD, ranked by usefulness.
Probing was read-only: sqlite `mode=ro` queries, state-file reads, `pgrep`/`ps`/`ss`,
`gh` reads. No secrets, tokens or credential contents were printed or stored; auth
was confirmed by presence only (`gh auth status` shows a redacted token).

`in_hud` was checked by grepping R/candidates/HudV3.qml plus the live collector key
set (`hud-collect stream`). Already streamed and rendered: ag_* harness chips,
devsess{i} Devin session locks, ag_devin_acp, tmux{i}, gh_ok/gh_unread/ghev{i},
agents_procs, TOKENS ledger panel + popup. Streamed but thin: ag_build_*. Not in
HUD: listening dev servers, local git dirty state, hermes cron/kanban, MCP names,
docker, systemd --user.

## Ranked inventory

### 5 — highest daily value

1. **token-ledger** — Token/cost ledger across all providers. Read: parse
   `~/.local/state/nexuslink/tokens.json` (16 ms). Sample: 6 providers, updated
   2026-09-28T14:49Z; devin day 160.0M in / 35.9M out; opencode day 31.3M in /
   0.46M out, $0.22; claude/codex/fireworks null (no local feed). Action:
   `omarchy-shell nexuslink.hud tokens` (popup toggle, already wired). Poll 60 s.
   In HUD: yes. Spend across every harness in one glance; the 60 s ledger pulse
   already exists.

2. **opencode-db** — OpenCode sessions/running/models. Read:
   `sqlite3 'file:~/.local/share/opencode/opencode.db?mode=ro' "SELECT substr(title,1,44), agent, datetime(time_updated/1000,'unixepoch') FROM session ORDER BY time_updated DESC LIMIT 6;"` + `pgrep -c opencode` (2 ms).
   Sample: 58 sessions; newest "A11.md brief execution" (build); 9 opencode procs
   (8 `opencode run --auto` lanes); model mix by message: kimi-k3 381, glm-5-3 232,
   deepseek-v4.1-flash 160, mimo-v2.6-flash 105; providers haze 43 / opencode-go 14 /
   conductor-relay 1. Action: `kill $(pgrep -f 'opencode run --auto')` stops all
   runaway lanes at once. Poll 5 s. In HUD: chips only (ag_opencode_{procs,cpu});
   no per-session list or kill action. This is the fleet that actually burns tokens
   on this box.

3. **devin-sessions** — Devin CLI sessions + ACP + desktop windows. Read: live-lock
   sweep of `~/.local/share/devin/cli/session_locks/*.lock` with `kill -0` (39 ms) +
   `SELECT count(*) FROM sessions` (2 ms, sessions.db is 690 MB + 294 MB WAL but the
   count is indexed). Sample: 9 live of 38 locks; 13 sessions, newest "Locating lost
   HUD rework session" (swe-2-max, bypass); 5 `devin acp` procs; desktop windows on
   ws 7 and ws 1. Action: `hyprctl dispatch focuswindow class:devin-desktop`.
   Poll 10 s. In HUD: yes (devsess{i}_{name,pid,live}, ag_devin_acp stream); the
   missing piece is one-click focus per session. Highest-count agent surface.

4. **github-prs-ci** — PRs + CI + notifications. Read (830 ms, network):
   `gh pr list --author @me --state open --json number,title --jq length`,
   `gh run list --limit 1 --json status,conclusion,name`,
   `gh api notifications --jq length`. Sample: auth ok (nexuslinkproductions,
   scopes repo/workflow); 4 open PRs authored in haze (#245 docs handoff,
   #244 HRN-7 MCP, #243 HRN-5, #225 automations); 0 review-requested; latest CI
   "Security" = FAILURE on main 14:07Z; 50 unread notifications. Action:
   `gh pr view 243 --web` / `gh run view --log-failed`. Poll 120 s. In HUD:
   partially (gh_ok/gh_unread/ghev_* stream every 90 s); PR count and CI
   conclusion chips are missing. A red Security run on main is exactly what this
   HUD should shout about.

5. **agent-procs** — Per-harness process CPU. Read: `ps -eo comm,pcpu` awk rollup
   (47 ms). Sample: opencode 130% (9 procs), october-desktop 32%, devin 5%;
   collector emits ag_{devin,opencode,hermes,october,claude,codex,haze,build}_{procs,cpu}
   plus agents_procs=22. Action: `hyprctl dispatch focuswindow class:october`.
   Poll 3 s. In HUD: yes (harness chips). Tells you which harness is eating the box.

### 4 — strong candidates

6. **dev-servers** — User-owned listening dev servers. Read: `ss -ltnp | grep users:`
   (24 ms). Sample: 12 sockets; next-server *:3000 (pid 1697452), october-core
   127.0.0.1:34441/36229/38463, devin acp :36767, october-desktop :37433, windsurf
   language_servers :39113/40697/41745/44075. Action: `xdg-open http://localhost:3000`.
   Poll 30 s. In HUD: no. One read answers "what dev servers are up" with pid
   attribution.

7. **git-repos** — Dirty/ahead/behind for top-level repos. Read: per-repo
   `git status --porcelain | wc -l` + `git rev-list --left-right --count HEAD...@{upstream}`
   (39 ms for all). Sample: astralmon 0 (0/0), cursor-plugins 1 (0/0), haze 2
   (ahead 0 behind 1); NEXUS_AI_CENTER top level: only AURICLE is a repo, 0 (0/0);
   archive dirs 00_BRIEF..05_VAULTS and node_modules skipped. Action:
   `cd ~/projects/haze && git pull --rebase`. Poll 60 s. In HUD: no (REPO ACTIVITY
   shows GitHub events, not local working-tree state).

### 3 — useful, situational

8. **hermes-usage** — Hermes usage rollups. Read: newest `~/.hermes/usage/*.json`
   (14 ms). Sample: 8 files; newest gpt-5.6-luna via openai-codex, 3.01M total
   tokens (2.89M cache-read), 65 api_calls, cost_status=included. Action:
   `omarchy-shell nexuslink.hud tokens` (haze row already aggregates these).
   Poll 60 s. In HUD: yes via ledger. Drill-down, not a new chip.

9. **hermes-cron** — Hermes cron jobs. Read: `~/.hermes/cron/jobs.json` (14 ms).
   Sample: 3 jobs, all enabled=false, last_status ok (daily-social-digest,
   october-oss-repo-sync, october-oss-pipeline). Action:
   `hermes cron enable f9cc3990de9f`. Poll 300 s. In HUD: no. A "cron: 0/3 on"
   chip catches silent scheduler death.

10. **mcp-servers** — Configured MCP server names. Read: `~/.claude.json`
    mcpServers + `grep '^\[mcp_servers' ~/.codex/config.toml` + hermes config.yaml
    (23 ms). Sample: claude: october-bus-static; codex: october-bus-static;
    hermes: blender, figma, higgsfield, linkedin, meta-instagram, microsoft-learn,
    playwright, github, october_bus + 4 qwen-mm-plugins; opencode.json: none.
    Action: `hermes mcp list`. Poll 300 s. In HUD: no. Static config; names only,
    secrets stay in the files.

11. **october-desktop** — October desktop + bus bridge. Read:
    `pgrep -c -f october-desktop` + `ls ~/.config/October/chat-sessions | wc -l`
    (94 ms). Sample: 7 procs (ws 4 window), 2 bus-bridge node procs on :36229,
    0 chat-session files; october-core 1.0.53 on 34441/38463. Action:
    `hyprctl dispatch focuswindow class:october`. Poll 10 s. In HUD: yes
    (ag_october_* chips). No session list to mine yet.

### 2 — low value today

12. **systemd-user** — User services + timers. Read:
    `systemctl --user list-units --type=service --state=failed | wc -l` (3 ms).
    Sample: 0 failed, 0 timers, 15 running (omarchy-crash-watch, hyprmoncfgd,
    gnome-keyring). Action: `systemctl --user restart omarchy-crash-watch.service`.
    Poll 30 s. In HUD: no. Only worth a chip on failure; today a green zero.

13. **hermes-kanban** — Kanban board. Read:
    `sqlite3 'file:~/.hermes/kanban.db?mode=ro' 'SELECT status,count(*) FROM tasks GROUP BY status'`
    (2 ms). Sample: 0 tasks (schema has status/priority/claim_lock/project_id).
    Action: `hermes kanban`. Poll 120 s. In HUD: no. Empty board, nothing to show.

14. **build-test-runners** — Test/build runners. Read:
    `pgrep -af 'cargo (build|test)|pytest|vitest|next-server'` (18 ms). Sample:
    next-server v15.5.25 on :3000 (6% cpu); no cargo/pytest running; haze
    package.json has test/test:api/build/tauri scripts. Action:
    `cd ~/projects/haze && npm run test`. Poll 15 s. In HUD: yes (ag_build_* chip).
    Scripts are static config; only the running server is live data.

15. **claude-codex-cli** — Claude/Codex CLI presence. Read: `which claude codex` +
    `ls ~/.claude/projects` (8 ms). Sample: both installed via mise; no claude
    transcripts, no running procs; codex logs_2.sqlite has no token columns mined;
    ledger marks both "no local feed" (omarchy snapshot ready:false, "Waiting for
    auth"). Action: `claude auth login`. Poll 300 s. In HUD: yes (ledger rows).
    Only the auth nudge is new.

16. **tmux** — Read: `tmux ls` (2 ms). Sample: no server running (exit 1);
    collector emits tmux_n=0, agents_tmux=2. Action: `tmux new -A -s main`.
    Poll 5 s. In HUD: yes (tmux{i}_{name,win,att} + attach). Rank low until tmux
    is actually used.

### 1 — skip

17. **docker-podman** — Read: `docker ps` (8 ms). Sample: permission denied on
    /var/run/docker.sock (user not in docker group), 0 running; podman not
    installed. Action would be `sudo usermod -aG docker nexuslink` first. In HUD:
    no. Nothing to show.

## Notes for the agentic-OS design

- Four of the five rank-5 items already have collector keys or a ledger pulse; the
  new work is chips and actions (PR count, CI conclusion, per-session opencode
  list, devin focus), not new backends.
- The two missing data planes worth adding: `ss -ltnp` dev-server list (24 ms) and
  per-repo git dirty state (39 ms). Both are cheaper than the existing github lane.
- gh reads cost 0.4-1.2 s each; keep them on the existing ~90 s slow lane. Never
  poll gh from the 1 s frame.
- sessions.db (devin) is 690 MB with a 294 MB WAL; the indexed count is 2 ms, but
  any message_nodes scan should stay in the ledger's incremental cursor, not the
  collector.
- Cost column in the JSON is the measured wall time of the read command on this box.
