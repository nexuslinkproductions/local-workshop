# Agentic surface recon (85169080's sibling lane report, captured 2026-09-27)

Condensed findings for future HUD passes. Full details in session history.

## Agent usage seam (highest leverage)
`/usr/bin/omarchy-agent-usage-update` writes `~/.local/state/omarchy/agents/usage/<id>.json`;
the stock `omarchy.agents` panel auto-discovers ANY `<id>.json` dropped there.
Schema: `{id,name,ready,hasLocalStats,todayPrompts,todaySessions,todayTotalTokens,
todayTokensByModel,recentDays[],limits[],modelUsage{},usageStatusText,authHelpText,
tierLabel,schemaVersion:1}`. A HUD writer can register devin/opencode/hermes/october
records without plugin code.

## Live session/progress sources
- Devin: `~/.local/share/devin/cli/session_locks/*.lock` (name=session, content=PID,
  live if /proc/<pid> exists) — COLLECTED as `devsess{i}_{name,pid,live}`.
  Summaries: `cli/summaries/*.md` have "Current State" progress prose.
- Hermes: `~/.hermes/kanban.db` (sqlite task board), `~/.hermes/cron/jobs.json`
  (jobs w/ next run, errors), `sessions.db`, per-profile dirs
  (atlas/itachi/levi/roger/yuri/zenitsu). CLIs: `hermes status|cron list|kanban`.
- opencode: `~/.local/share/opencode/opencode.db` (message table w/ tokens),
  `~/.config/opencode/service.json` HAS A PASSWORD — never display.
- October: `~/.config/October/core/runtime/core-bootstrap.json` (state/port/pid),
  `october-activity.json` (workUnits/completedTurns/outcome counters),
  `plan-cache.json`, `project-chat-history/*.json`, core port 36229 (unverified API).
- Haze: repo `STATUS.md`, `tasks/<id>/task.toml` (fail-to-pass specs),
  dogfood `TASKS.md` checkbox kanban (T1–T11 done).

## Launchables (gtk-launch ids)
devin-desktop, october (user dir, `~/Applications/october/AppRun`), foot (terminal),
org.gnome.Nautilus, chromium, spotify, obsidian, nvim, Discord (webapp), 
devin-desktop-url-handler. Agent TUIs share app-id `org.omarchy.agent`.
No: code, windsurf, alacritty, kitty, thunar, firefox, google-chrome-stable, steam.

## Omarchy IPC targets (omarchy-shell <target> <method>)
shell(ping,applyTheme,rescanPlugins,reloadConfig,toggleBarTransparency,
listPlugins,summon,hide,toggle,call,...), lock(lock,status,preview),
idle(status,enable,disable,toggle = coffee mode), media(status,playPause,next,
previous,sourceNext...), background(refresh,set,setInstant,transition),
notifications(dnd,toggleDnd,clear,dismissAll,invokeLast,showHistory),
osd(show,close,state = HUD toasts), nightlight(status,toggle,enable,disable),
omarchy.{bar,monitor(brightness!),clock,bluetooth,system-update,power,network,
agents(open/refresh/next)}, expose(open/toggle + settings).

## Quick actions worth HUD buttons
coffee mode (`idle toggle`), nightlight toggle, media controls, theme switch
(`omarchy theme list`, `omarchy-theme-set`), wallpaper picker, screenshot
(`omarchy capture screenshot region|fullscreen`), screen record
(`omarchy-capture-screenrecording`), system update check (`omarchy-update-available`
exit 0 = pending), lock (`omarchy-shell lock lock`), notifications clear.

## Hyprland
focuswindow `address:0x…`, `workspace N` dispatch work; agent window classes:
Devin, October, Hermes (frameless "Hermes HUD"), foot, org.omarchy.agent TUIs.

## Secrets — NEVER render
~/.local/share/devin/credentials.toml, mcp_config.json, opencode auth.json,
opencode service.json (password), provider keys in opencode.json, Cookies,
state.vscdb, bus-principals.
