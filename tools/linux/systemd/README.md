# nexuslink-hud-feeds: install and rollback (for the parent)

The worktree never installs, enables, starts or reloads this unit. Run these
commands yourself, in order. Model B is the decision (see ../FEED-MODEL.md).

## What the unit does

- Runs `/usr/bin/python3 ${NEXUSLINK_REPO}/nexuslink.hud/v5/feeds/supervisor.py`.
- Writes snapshots and the heartbeat to `$XDG_RUNTIME_DIR/nexuslink-hud/feeds/`.
  systemd creates that directory (RuntimeDirectory) and removes it on stop.
- Nice=19, idle I/O, CPUQuota=10%, Restart=on-failure, RestartSec=5.
- Does not change DeckMain. DeckMain's own Process path stays as the fallback.

## Preconditions

- The repo is at `~/hud-wt/main-live`, or you set `NEXUSLINK_REPO` in a drop-in (step 4).
- `/usr/bin/python3` exists (it does on this box: 3.14).
- The worktree is committed by the lead (the unit runs the committed file).

## 1. Verify the unit file (no install, no change to the user manager)

    systemd-analyze --user verify ~/hud-wt/main-live/tools/linux/systemd/nexuslink-hud-feeds.service

Expected: no output and exit 0.

## 2. Install (copy, then tell systemd)

    mkdir -p ~/.config/systemd/user
    install -m 0644 ~/hud-wt/main-live/tools/linux/systemd/nexuslink-hud-feeds.service ~/.config/systemd/user/nexuslink-hud-feeds.service
    systemctl --user daemon-reload

## 3. Enable and start

    systemctl --user enable --now nexuslink-hud-feeds.service
    systemctl --user status nexuslink-hud-feeds.service --no-pager

Check after about 60 seconds:

    cat "$XDG_RUNTIME_DIR/nexuslink-hud/feeds/supervisor.json"
    ls "$XDG_RUNTIME_DIR/nexuslink-hud/feeds/"

Expected: status active (running); `beat_at` within the last few seconds;
`sessions.json`, `link.json`, `metrics.json` and `apps.json` present. `ok` is
true in each, or false with an `error` (for example apps when its state file is
absent: the payload is then `ok: false, reason: missing`, which is an honest answer).

## 4. Override the repo location (optional, no file edit)

    systemctl --user edit nexuslink-hud-feeds.service

Add in the editor:

    [Service]
    Environment=NEXUSLINK_REPO=/absolute/path/to/repo

Then:

    systemctl --user daemon-reload
    systemctl --user restart nexuslink-hud-feeds.service

## Rollback (stop it, remove it, leave DeckMain on its Process path)

    systemctl --user disable --now nexuslink-hud-feeds.service
    rm -f ~/.config/systemd/user/nexuslink-hud-feeds.service
    rm -rf ~/.config/systemd/user/nexuslink-hud-feeds.service.d   # only if you made a drop-in
    systemctl --user daemon-reload
    systemctl --user reset-failed nexuslink-hud-feeds.service

Check it is gone:

    systemctl --user list-units 'nexuslink-hud*' --all

Expected: `0 loaded units listed.` The snapshot directory goes with the unit
(systemd removes the RuntimeDirectory on stop). If it is still there, it is safe
to remove: `rm -rf "$XDG_RUNTIME_DIR/nexuslink-hud"`.

After rollback DeckMain must run its own readers. The fallback rule in
../FEED-MODEL.md says so: a heartbeat older than 3 s means the supervisor is not running.

## Notes

- `Restart=on-failure` with a RuntimeDirectory: a restart empties the snapshot
  directory. Consumers must treat a missing snapshot as stale, not as zero.
- `Type=simple`: the unit is "active" once python starts. The heartbeat is the real
  liveness signal.
- Nothing here reads secrets. The unit has no environment beyond NEXUSLINK_REPO.
