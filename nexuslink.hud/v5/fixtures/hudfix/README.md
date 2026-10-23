# hudfix system fixtures (F8f)

Recorded inputs for `feeds/hudfix_system.py --fixture`. The whole directory is
one fixture: pass it as a whole and any action picks the file it needs.

`--fixture` also accepts a single file for the actions where one file is the
whole input (`system.failed-jobs` reads a launchctl capture, `system.recent-errors`
reads a log capture, `system.crash-reports` reads one `.ips`).

| File | Used by | Provenance |
|---|---|---|
| `launchctl-list.txt` | `system.failed-jobs` | Real `launchctl list` capture on NexusBook (macOS 26.4.1), trimmed to the header plus 14 rows (4 healthy, 6 failed, 4 killed by SIGKILL). Labels only, no paths. |
| `log-show.ndjson` | `system.recent-errors` | 8 real `log show --last 1h --style ndjson` Error rows, one per sender, trimmed to 8 keys, plus 2 synthetic `Fault` rows from `nexuslink-hud` so the fault path is exercised. |
| `systemctl-failed.json` | `system.units` | Shaped from the systemd 255 `systemctl --user --failed --output=json` schema. There is no Linux host in this build lane, so this one is written from the documented shape, not captured live. |
| `journalctl-last.json` | `system.units` | The last log line per unit, as the live path gets it from `journalctl --user -u <unit> -n 1 -o cat`. |
| `journalctl-errors.ndjson` | `system.recent-errors` (journal branch) | Shaped from `journalctl -p err -o json` entries. Same caveat: no live Linux host here. |
| `ps.txt` | `system.restart-shell` | Recorded shape of `ps -Ao pid=,ppid=,args=` on the Linux HUD host: one HUD quickshell, its hud-collect child, and a gateway line that the guard must refuse. |
| `cgroup.txt` | `system.restart-shell` | `/proc/<pid>/cgroup` for the HUD, naming `nexuslink-hud.service` under `user@1000.service`. |
| `uptime.json` | `system.uptime`, `system.load` | Shaped probe output, not a capture: `kern.boottime`, `uptime` text, `vm.loadavg`, `hw.ncpu`. The boot second 1792620000 (2026-10-21T22:00:00Z), its ctime text, `uptime_text` (1 day, 2:00) and `meta.now` agree, so the file supports one uptime reading only: 26 h. |
| `crash/*.ips` | `system.crash-reports` | Two small crash headers in the `.ips` layout (header line + a stub body). Dates are 2026-10-20 and 2026-09-14 so the quarantine age filter has one inside and one outside a 30-day window. |
| `meta.json` | all | `generated_at` and `now` for the fixture clock. Ages are computed from these, never from the wall clock or file mtimes, so a fixture run is byte-identical on any machine. |

Sanitising: no home paths, no tokens, no crash bodies. The log messages are
Apple's own `<private>` placeholders, as the real capture has them.
