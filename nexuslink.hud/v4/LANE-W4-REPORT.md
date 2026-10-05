# LANE-W4-REPORT — Navigator FILES section: mounts sidebar, explorer parity, rich preview

Scope honored: edits confined to `v4/Navigator.qml` only (deployed mirror
`~/.config/omarchy/plugins/nexuslink.hud/v4/` synced; no shell restart, same
file lands on next read). Fresh dispatch — prior W4 lane wrote nothing;
baseline was the file at 1421 lines.

## 1. Mounts sidebar (explorer roots)

- `FileView mountsFile` reads `/proc/mounts` (`watchChanges:false` — procfs
  can't inotify; reload on nav open + 4 s pulse via `mountsTimer` while the
  files section is up). Reuses the exact FileView pattern `tokFile` sets.
- `parseMounts(text)` filters: pseudo-fstype blocklist
  (proc/sysfs/devpts/devtmpfs/tmpfs/cgroup*/squashfs/snap-adjacent/overlay/
  autofs/fuse.portal/gvfsd/debugfs/tracefs/pstore/bpf/…), mountpoint
  allowlist `/`, `/home*`, `/boot*`, `/mnt/*`, `/media/*`, `/run/media/*`,
  plus any `/dev/*`-backed or net-fs (nfs/cifs/sshfs/…) mount not under
  plumbing prefixes (`/proc /sys /dev /run /snap /var /tmp /etc /usr`).
  Octal escapes (`\040`) unescaped per mount(5).
- Result on this box (verified by replaying the exact function in node
  against live `/proc/mounts`): `HOME ⌂` `/home/nexuslink` btrfs,
  `ROOT /` btrfs, `boot` vfat nvme1n1p3, `home` btrfs subvol,
  `82CC5F65CC5F5311` ntfs3 (Kingston/repo), `DATA` ntfs3 nvme1n1p2,
  `OMARCHY_202609` iso9660 sda1 USB. All 20+ pseudo mounts dropped,
  `/var/*` subvol binds dropped.
- Rail UI: `MOUNTS` group under SECTIONS, files section only —
  `ListView` capped at 264 px, 34 px rows (icon + label over elided path +
  fstype). `mountActive` = longest-prefix mount of `filesDir`, accent-marked.
  Click → `filesGoTo(path)` which pushes `navStack` (Backspace/`back()`
  returns), switches `filesDir`, resets sel/query.
- `normalizeDir` expands `~`, resolves bare names relative to `filesDir`,
  strips trailing slashes; `resolveNavPath` additionally resolves a bare
  word against mount labels — IPC `open files DATA` and
  `open files /run/media/…` both land.

## 2. Explorer parity

- `buildFilesRows` rows now carry `sizeTxt`, `mtimeTxt` (from
  `fileSize`/`fileModified` roles — Qt 6.11 has no `fileModifiedTime`),
  `data.{mtime,suffix,exec,ftype}`. Dirs-first + name sort unchanged.
- Type icons: `fileTypeOf(suffix, exec)` → `dir ▣`, `code </>`,
  `image ▩`, `video ▶`, `audio ♪`, `archive ▧`, `doc ≡`, `exec ◆`,
  generic `▤` (all glyphs inside the same geometric/mono set the file
  already uses). ~130 suffixes binned across six string-set lookups.
- Exec bit: `execProbe` = one bounded `find "$1" -maxdepth 1 -type f
  -executable` per dir change (argv-positional, `head -n 2000`,
  `execProbeRunGen` stale-guard). +x names land in `execSet`; unknown-suffix
  execs render `◆`, suffixed execs keep their type icon but stay runnable.
- Columns: `SIZE` (58 px right-aligned) + `MODIFIED` (118 px
  `yyyy-MM-dd HH:mm`) tail columns replace `meta` on file rows; header strip
  `NAME / SIZE / MODIFIED` shows over the list in section 0, aligned to the
  same margins (54 px left, 26 px right). Other sections keep the meta tail.
- Keyboard contract untouched: F1–F6, Enter/Right descend, Backspace/Left
  up (navStack → parentDir fallback), `/` filter, Esc, PgUp/PgDn, Home/End.
  Added `Ctrl+H` = `showHiddenFiles` → `filesModel.showHidden` (gtk dialog
  convention), surfaced in `contextText` + `state().hidden`.
- Breadcrumb/preview pane/bounded reads all unchanged.

## 3. Preview

- `file` rows split by `ftype`: text-ish (code/doc/file) keep the bounded
  `head -c 65536` + NUL-sniff path verbatim. `image/video/audio/archive/
  exec` rows skip the head read and run bounded `file -b` (`fileProbe`,
  `fileProbeGen` stale-guard) → structured detail block (name/path/size/
  mtime/exec) + the `file` description; `(\d+)\s*x\s*(\d+)` pulls image
  dims into `image  W × H px` and `previewInfo`.
- Runnable rows (`exec` bit or `.desktop`) get `RUN` as primary action:
  scripts (`sh/bash/zsh/fish/py/pl/rb/lua`) → `xdg-terminal-exec -- <path>`
  so output is visible; `.desktop` → `uwsm-app -- xdg-open`; other binaries
  → `uwsm-app -- <path>` (uwsm scope). `OPEN` remains as second action
  (`xdg-open`, argv-safe). All launches are argv vectors through the
  existing `execArgv`/`execShArgv` contract — no shell concatenation.

## 4. IPC (`nexuslink.nav`)

- `open(section, path)` — unchanged contract; `path` now flows through
  `resolveNavPath` (absolute / `~` / relative-to-filesDir / mount label).
- `back()`, `close()` — unchanged.
- `state()` JSON extended: `mount` (active mount path), `mounts`
  ([{label,path,device,fstype,icon}]), `hidden` (bool) added to the
  existing fields. Agents read `mounts` then `open files <path|label>`.
- `mounts()` — new method returning the mount array alone (no nav open
  required; JSON).

## Verification

    $ cd v4 && /usr/lib/qt6/bin/qmllint Navigator.qml
    EXIT=0   # only pre-existing diagnostics: 2× uncreatable PanelWindow
             # (quickshell type, same as baseline) + 4× unqualified access
             # on the pre-existing action-button delegate (unchanged code)
    $ cd <mirror>/v4 && /usr/lib/qt6/bin/qmllint Navigator.qml → EXIT 0

Logic replayed in node against live `/proc/mounts` (see §1) and against
the classifier/resolver (`png→image`, `+x→exec`, `DATA→/run/media/…/DATA`,
`~/x`, trailing-slash strip) — all green.

Mirror sync (no shell restart, per spec):
`cp Navigator.qml LANE-W4-REPORT.md →
 /home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/`

## Known limits / notes for the parent lane

- `find -executable` follows the fs; network mounts probed lazily — the
  probe runs once per dir change, bounded by `head -n 2000`.
- `file -b` is one process per preview refresh on binary-ish rows; text
  rows still take the `head` path — same bounded-read discipline as before.
- Mount label vs local dir collision on bare-word `open files X`: mount
  label wins (deterministic, documented).
- `/proc/<pid>` navigation from proc rows still works; `mountActive` just
  falls back to `/` there since procfs is filtered out of the sidebar.
