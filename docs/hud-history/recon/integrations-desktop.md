# Desktop/system integrations inventory (A4)

Scope: Omarchy/Hyprland utilities reachable from the HUD, ranked by daily usefulness.
Probing was read-only: state reads and help/summary text only. No toggles, no launches.
All IPC targets enumerated via `qs ipc -n -p /usr/share/omarchy/shell show` and
`omarchy-shell shell listPlugins` (44 plugins). 440 omarchy-* commands carry
`# omarchy:summary=` lines. User plugins in ~/.config/omarchy/plugins:
community.window-overview, crmne.hyprmoncfg, expose.window-overview,
nexuslink.hud, nexuslink.medianotch, nexuslink.taskbar.

`in_hud` was checked by grepping R/candidates/HudV3.qml plus the live collector key
set (`hud-collect stream`, 240 lines/batch). Collector emits but HUD never renders:
weather, pkg_updates, theme_name. Collector emits and HUD renders: net_*, fs_root/blk
tree, media{i}_name (removable mounts, not MPRIS), bat_count, ag_*/aguse*.

## Ranked inventory

### 5 — highest daily value

1. **media-mpris** — Media/MPRIS now-playing. Read: `omarchy-shell media status` (22 ms).
   Sample: `{"hasPlayer":false,"hasMedia":false,"playing":false,"title":"","artist":"",...}`.
   Action: `omarchy-shell media playPause` (also next/previous/sourceSwitch). Poll 2 s.
   In HUD: no. Full title/artist/artUrl JSON; medianotch plugin proves the demand.

2. **notifications-dnd** — Notifications + DND. Read: `omarchy-shell notifications isDnd`
   → `off`; history dir `~/.local/state/omarchy/notifications/history/` has 10 JSON files,
   newest `{"summary":"T7 unmounted"}`; state file `notifications.json` = `{"version":3,"dnd":false}`.
   Action: `omarchy-shell notifications toggleDnd`. Poll 5 s. In HUD: no.
   DND chip + unread count is a top daily status; history dir is a free ticker.

3. **audio-volume** — Audio sink volume + switch. Read: `wpctl get-volume @DEFAULT_AUDIO_SINK@`
   (8 ms) → `Volume: 0.95`. Sinks present: CORSAIR Slipstream receiver (default), Ryzen HD
   analog, HDMI LC27G7xT. Action: `omarchy-audio-output-volume up`,
   `omarchy-audio-output-switch`. Poll 3 s. In HUD: no. Touched many times a day.

4. **idle-inhibit** — Stay-awake (coffee). Read: `omarchy-shell idle status` →
   `{"enabled":true,"stayAwake":false,"screensaver":150,"lock":300,"idle":false,...}`.
   Action: `omarchy-toggle-idle`. Poll 15 s. In HUD: no. Daily presentation/recording toggle.

5. **weather** — Read: `omarchy-weather-status` (304 ms, wttr.in wrapper) →
   `Vienna · Temp 23°C · Wind ↖19km/h`. Action: `omarchy-shell omarchy.weather toggle`.
   Poll 900 s. In HUD: no, but the collector already emits a `weather` key every 15 min.
   Free win: render what is already collected.

### 4 — strong dock candidates

6. **clipboard-history** — Read: `~/.local/state/omarchy/clipboard-history.json` length
   (13 ms) → 31 entries, newest a text entry. Action: open the existing overlay via
   `omarchy-shell shell call omarchy.clipboard toggle {}`. Poll 10 s. In HUD: no.

7. **screenshot-suite** — Screenshot/record/OCR/colour picker. grim, slurp, tesseract,
   hyprpicker all installed; no recorder running. Actions: `omarchy-capture-screenshot`,
   `omarchy-capture-region`, `omarchy-capture-text` (OCR), `hyprpicker` (colour),
   `omarchy-capture-screenrecording`. Poll 30 s for last-shot thumbnail. In HUD: no.

8. **mic-mute** — Read: `wpctl get-volume @DEFAULT_AUDIO_SOURCE@` → `Volume: 1.00`
   (no MUTED suffix). Action: `omarchy-audio-input-mute`. Poll 3 s. In HUD: no.

9. **reminders-timers** — Read: `omarchy-reminder show -j` →
   `{"count":0,"active":false,"reminders":[]}`. Action: `omarchy-reminder 25 "break"`
   (pomodoro via minute timers); overlay plugin omarchy.reminders exists. Poll 10 s.
   In HUD: no.

10. **system-updates** — Read: `checkupdates | wc -l` → 2 (aether, mise-bin);
    `omarchy-update-available` (486 ms) → "Omarchy is up to date". Action:
    `omarchy-shell omarchy.system-update refresh`, apply via `omarchy-update`.
    Poll 1800 s. In HUD: no, but collector already emits `pkg_updates` every 15 min.

11. **workspace-overview** — Read: `hyprctl workspaces -j` (4 ms) → 3 workspaces,
    5 windows. Action: Exposé overlay `qs ipc -p /usr/share/omarchy/shell -t expose call
    toggle ''` (user plugin expose.window-overview v5.0.0). In HUD: partially
    (WINDOWS/NAV panel on HDMI-A-3); the Exposé launch button is missing.

### 3 — useful, situational

12. **network** — Read: `omarchy-network-status` → `ethernet\tenp15s0`
    (192.168.0.112/24, wlp16s0 DOWN). Action: `omarchy-shell omarchy.network toggle`
    (panel has speedTest/showQr). In HUD: yes (net_if/net_addr/net_rx/net_tx trace).

13. **power-profile** — Read: `powerprofilesctl get` → `performance`. Action:
    `omarchy-powerprofiles-set power-saver`. Poll 30 s. In HUD: no.

14. **nightlight** — Read: `omarchy-shell nightlight status` →
    `{"enabled":false,"temperature":null}` (hyprsunset not running). Action:
    `omarchy-shell nightlight toggle`. Poll 30 s. In HUD: no.

15. **session-actions** — Lock/suspend/reboot. Read: `omarchy-shell lock isLocked` →
    false. Actions: `omarchy-system-lock`, `omarchy-system-sleep-lock`,
    `omarchy-system-reboot`, `omarchy-system-shutdown`. In HUD: no.

16. **theme** — Read: `omarchy-theme-current` → Hackerman (font JetBrainsMono Nerd Font,
    channel stable, omarchy 4.0.4-1). Action: `omarchy-theme-bg-next`,
    `omarchy-theme-switcher`. In HUD: collector emits `theme_name`, v3 never renders it.

17. **omarchy-menu** — Action-only launcher: `omarchy-shell shell call omarchy.menu
    toggle {}`. No polling. In HUD: no. One button reaches every other Omarchy action.

18. **display-brightness** — Read: `omarchy-brightness-display` → 50 (ddcutil getvcp 10
    confirms 50/100 on DP-2). Action: `omarchy-brightness-display +10` or IPC
    `omarchy-shell omarchy.monitor brightness 70`. Poll 30 s. In HUD: no.

19. **recent-downloads** — Read: `ls -t ~/Downloads | head -3` → astralmon-main.bundle,
    Devin-linux-x64-3.10.35(.tar.gz). Action: `nautilus ~/Downloads`. Poll 60 s. In HUD: no.

20. **disk-usage** — Read: `df -h /` → 256G/103G used/41%. Action: `omarchy-drive-info`.
    In HUD: yes (fs_root_pct + blk device tree on DP-2). Only a free-space chip is missing.

21. **agents-widget** — Read: `omarchy-shell omarchy.agents refresh` → ok. Action:
    `omarchy-shell omarchy.agents next`. In HUD: yes for data (ag_*/aguse* keys stream);
    the stock widget's next/refresh cycle is the missing action.

### 2 — low value on this machine today

22. **bluetooth** — Read: `bluetoothctl show` (3 ms) → Powered: yes, Name: OmarchyLink;
    `bluetoothctl devices Connected` → none, zero paired. Action:
    `omarchy-shell omarchy.bluetooth toggle`, `omarchy-bluetooth-power off`. Rank 2:
    radio on, no peripherals.

23. **keyboard-layout** — Read: `hyprctl devices -j` main keyboard → "English (US)"
    (asus-tuf-gaming-k7). Action: `hyprctl switchxkblayout <kbd> next`. Rank 2:
    single-layout user.

24. **trash** — Read: `gio trash --list | wc -l` → 5 (easyeffects dirs). Action:
    `gio trash --empty` (destructive, confirm). Poll 120 s. Rank 2.

25. **calendar-agenda** — Read: `cal -3` → September 2026 grid, today Mon 28. No khal or
    calcurse installed; clock plugin has a calendar panel
    (`omarchy-shell omarchy.clock toggle`). Rank 2: no event source exists.

26. **network-speedtest** — On-demand only: `omarchy-shell omarchy.network speedTest`
    (~15 s per run); disk variant `omarchy-disk-speedtest`. Rank 2: nothing to poll.

### 1 — skip

27. **vpn-tailscale** — No tailscale/nordvpn CLI, no tailscaled/nordvpnd units, no
    wireguard links; omarchy.tailscale plugin disabled. Action would be
    `omarchy-install-service-tailscale` first. Rank 1.

28. **screensaver** — Idle service auto-runs it at 150 s
    (`screensaverStarted:false,"screensaver":150`). Manual launch:
    `omarchy-launch-screensaver`. Rank 1.

## Notes for the utility-dock design

- The 5 ranked-5 items plus clipboard, capture suite, mic, reminders, updates give 10
  live integrations with real data and one working action each (plan P7).
- Three integrations need no new collector code: weather, pkg_updates, theme_name are
  already emitted on the ~15 min misc lane; v3 just never reads them.
- IPC reads are all ≤ 25 ms except weather (304 ms, cached by collector) and
  omarchy-update-available (486 ms, 30 min poll).
- Action verbs that open shell UI (clipboard overlay, Exposé, menus) go through
  `omarchy-shell shell call <plugin> toggle {}` or the plugin's own IPC target; none of
  these were executed during recon.
- Cost column in the JSON is the measured wall time of the read command on this box.
