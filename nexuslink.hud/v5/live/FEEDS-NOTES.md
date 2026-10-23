# v5 data feeds

All four feeds are hidden Items with `property bool active`; they poll only while the deck
sets active true. Outputs are read-only properties shaped as listed below.

## LinkFeed.link + feeds/maclink.sh
- Source: `tailscale status` picks the macOS peer (`marcels-macbook-pro`), then
  `tailscale ping --c 1 --timeout 2s <peer>` for RTT and route. Mac body from ONE
  `ssh -o BatchMode=yes -o ConnectTimeout=3 mac 'pmset -g batt; sysctl -n vm.loadavg;
  sysctl -n kern.boottime; pmset -g therm'`, cached 10 s in `${XDG_RUNTIME_DIR:-/tmp}/nexuslink-v5/`.
  `mac.thermal` is "nominal" or "throttled" (CPU_Speed_Limit below 100), null when unread.
- Kanban: second ssh, cached 30 s in `<cache>/maclink-kanban.json`:
  `hermes kanban list --json` on the Mac, counted by top-level status on the Mac (sed),
  so only `{"running","ready","blocked"}` crosses the wire. Read-only. `mac.kanban` is null
  when the board is unreadable.
- Cache guard: mtime check plus `flock -w 5` on maclink-ssh.lock; `timeout 12` on ssh.
- Ring: last 60 RTT samples in `<cache>/maclink-rtt` (`epoch rtt`, one per 12 s poll);
  median/min/max/last computed per run. tunnel down + null RTT when ping fails; mac fields null when ssh fails.
- Interval: deck-visible Timer 12 s, `triggeredOnStart`, skipped while a run is in flight.
- Cost: ~0.1 s CPU per run, one ssh per 10 s, ping 2 s worst case. No new poller in QML.
- Reuse: v4's `stats` map has no Mac link or battery keys, so this is the only source;
  the script mirrors the v4 fixture shape (fixtures/link.json).
- Known: `tailscale ping mac` fails (alias is ssh-only), hence the status lookup.

## StorageFeed.disks
- Source: `df -PT -B1 -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay`.
- One run on activation, then every 60 s while active. Command runs once per activation
  (Timer `triggeredOnStart`), not per widget.
- Dedupe by device: btrfs subvolumes (/var/log, /home, /var/cache/pacman/pkg) collapse to
  ROOT; /boot skipped. Label = ROOT for /, else upper-cased mount basename.
- Cost: under 10 ms, no state written.
- Reuse: v4 displays disk via its own probe keys, not through a feed; no `stats` key was
  suitable (no per-disk fs/mount shape), so df is parsed directly.
- Live: ROOT btrfs 48%, T7 exfat 82%, 82CC5F65CC5F5311 ntfs3 72%, DATA ntfs3 1%.

## LocalAiFeed.localAi
- Source: FileView (`watchChanges: true`, atomicWrites) on
  `/run/user/1000/chief/metrics.json`. No timer at all.
- Keys mapped: `model` -> model/active, `vram_used_mib` -> vramGb and sizeGb (GB,
  one decimal; model file size is not published by the poller), `tokens_per_s` -> tokS,
  `queue` > 0 -> activity 1 else min(1, tokS/40).
- File absent (today it is, chief-overlay service disabled): present false, active false,
  zeros, the widget shows "idle". onLoadFailed resets to that state.
- Cost: zero when absent; one inotify watch when the poller starts writing.

## FindFeed (query, filter, results, busy, note)
- 120 ms single-shot Timer restarted on every query edit or filter change; spawns
  `Process { command: ["yuri","search", query.trim(), "-n","8","--json"] }` (argv, no shell).
- Stale runs: monotonic `_seq` compared in `onStreamFinished`, plus `proc.running = false`
  before a new start. `busy` true from spawn to finish.
- Parsed shape: yuri returns `{title, path, kind, score, line, snippet}`; kind is recomputed
  from the extension (md, code, doc, pdf, image, else file).
- Empty query: results [], no process. filter "downloads": results [], note
  "Downloads is not indexed yet", debounce stopped.
- Cost: one yuri process per typing pause, ~40 ms; nothing while idle.
- Reuse: no v4 feed existed; `yuri search "hud" -n 8 --json` produced the shape above.

## Measured (offscreen quickshell run, feeds/ loaded together)
- LINK: tunnel active, route direct, rtt last 4 ms, median 9, samples 5 deep, mac batt
  100 charged, load [8.88,12.59,16.4], up_min 19034.
- DISKS: 4 rows as listed above. LOCAL: present false (no metrics.json). FIND: 8 md hits.
- Downloads path and localAi present path exercised in a second scene (values above).
