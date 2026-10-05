# LANE-B1-REPORT — Navigator FILES: descend-into-unreadable-dir bug + nav ergonomics

Scope honored: edits confined to `v4/Navigator.qml` only; deployed mirror
`~/.config/omarchy/plugins/nexuslink.hud/v4/` synced (same file lands on next
read, no shell restart). `qmllint` exit 0.

## 1. BUG — "Enter on a folder kicks out the files, shows no context"

### Root cause

**Descend into a directory the user cannot read produces an empty model with
no error path.** `FolderListModel` reports an unreadable dir as
`status=Ready, count=0` — byte-identical to a legitimately empty folder —
so `buildFilesRows()` returned `[]` and the view dropped to a bare
"no matches" with the parent listing destroyed and no visible way back.

Concretely on this box: `/boot` is vfat mounted `dmask=0077,fmask=0077`
(root-only) and `/root`, `/.snapshots` are the same class. Enter on `boot`
from `/` (or the `boot` MOUNTS row) calls `filesDescend("/boot")`, the model
lands on `file:///boot`, logs `inotify_add_watch(/boot) failed:
(Permission denied)`, and stays `Ready+count=0` forever.

### Evidence (not a guess — reproduced on the real stack)

- **Live instance state right now** — `omarchy-shell nexuslink.nav state`
  returns `{"path":"/boot","rows":0}` — the operator is literally parked in
  the described dead state.
- **Live log** `/run/user/1000/quickshell/by-id/ak7is2g5mt/log.log` (the
  running instance, pid 849610):
  `2026-09-30 01:44:06.223 WARN : inotify_add_watch(/boot) failed: (Permission denied)`
- **Replay in a real `quickshell -p` shell** (test Navigator identical
  except `visible:false`/no keyboard grab): `/` → Enter on `boot` →
  `[FLM] countChanged count=0 status=Ready folder=file:///boot` →
  `rows=0 emptyText="no matches" context="/boot · 0 items live · /boot"`.
  Same for `/root`. Readable dirs (`/home/nexuslink/Applications`, spaced
  dir `NEXUS AI CENTER` on ntfs3) descend normally — path/encoding is
  **not** the bug.

### Secondary defects found while tracing (also fixed)

- **Stale transition frame**: `filesDescend`/`filesGoTo`/`filesUp` call
  `rebuildRows()` synchronously; the model still holds the *previous*
  directory at that instant (`[descend] filesDir="/boot" modelCount=19`),
  so rows showed `/`'s entries under the `/boot` path for ~100–500 ms.
- **Probe restart race**: `running=false`→`true` in one JS tick is a net
  no-op in Quickshell `Process`; the in-flight probe kept running and its
  stale reply passed the gen guard because `runGen` was pre-bumped
  (verified: `/root` got `dirReadable=true` from `/`'s probe). Same latent
  defect existed in `execProbe`.
- `emptyText` said "no matches" for a permission failure.

### Activation-path trace (the fix points)

`primaryAction()` → `r.kind==="dir"` → `filesDescend(r.data.path)` →
`filesDir = path` → `filesModel.folder: root.fileUrl(root.filesDir)` →
async load → `onCountChanged` → `filesRebuildTimer`(60 ms) →
`rebuildRows()` → `buildFilesRows()` → `ListView.model: root.rows`.

## 2. What changed in Navigator.qml

### Root-cause fix — unreadable dirs can no longer eject the operator

- **`dirProbe`** (lines ~279-303): per-dir `bash` probe — `test -r && -x`
  self-check emits `SELF_OK`; `find -maxdepth 1 -type d ! -readable`
  lists unreadable child dirs → `dirReadable` / `noReadSet`
  (`dirProbeRunGen` stale-guard). Started on `onFilesDirChanged` via
  **`dirProbeKick`** (30 ms timer — kills the false→true race noted above).
- **`buildFilesRows`** (581+): rows carry `data.readable` per dir.
- **Descend guard** — `dirEnterBlocked()`/`denyDescend()` (625-637),
  wired into `primaryAction()` (1266) and `runAction("open")` (1214):
  Enter/Right/click/"open" on an unreadable dir **refuses to descend** and
  shows `permission denied — directory is not readable` in the preview
  instead. The parent listing is never destroyed — the literal complaint.
- **Post-landing honesty**: `emptyText` (2205) now reports
  `permission denied — not readable` when `dirReadable=false`
  (covers jumps/mounts/IPC landing on unreadable dirs directly);
  `contextText` appends `· NO READ ACCESS`; `state()` IPC gains
  `readable` + `jumps` (additive — mount/mounts contract untouched).
- **`pendingLoad` + `folderMatchesDir()`** (60-66, 581, 586):
  `buildFilesRows` returns `[]` while the model is mid-transition
  (`pendingLoad` set on `onFilesDirChanged`, cleared on the model's real
  signals — `onCountChanged` match, and `onStatusChanged`
  `Ready|Null`+match so 0-entry and vanished dirs settle too). Dead stale
  frames eliminated: descend now goes straight to `loading…` then real rows.
- `execProbe` restarted through the same kick-timer pattern (237-257).

### Navigation ergonomics (files section only)

1. **BACK** — `upRow` (1805+): `‹ up to <name>` strip at the top of the
   listing, showing the *real* back target (`backTargetPath()` —
   navStack pop if it's a files entry, else `parentDir`). Click →
   `filesUp()` — same semantics as Backspace, untouched. Greyed
   ("at root") only when `canUp()` is false = `/` with an empty stack —
   mount roots mid-history stay climbable because `filesUp` falls back to
   `parentDir`, matching the Backspace contract.
   `navStack.push/pop` don't notify, so `canUp`/`upLabel`/`backTargetPath`
   take a `rowsRev` dep to re-evaluate per rebuild.
2. **FORWARD/history** — `navStack` is a pure back-stack: `goBack`/`filesUp`
   **pop and discard** — a redo stack cannot be derived, so per the spec the
   shipped forward affordance is a **visited quick list**: `recentDirs`
   (session, newest-first, deduped, cap 8) fed by `pushRecent(filesDir)` on
   every dir change; rendered in the JUMPS group (`◈`, dimmed). One click →
   `filesGoTo` (pushes current spot, so it composes with back).
3. **JUMPS rail** (1706-1780): group under MOUNTS —
   `[ -d ]`-probed pins via `jumpProbe` (`$HOME`, `~/Desktop`,
   `~/Downloads`, `~/.config`, repo root) — `~/Desktop` correctly
   dropped on this box (doesn't exist) — then the visited list.
   All clicks route through `filesGoTo`; nothing faked.

### Untouched contracts

Mount sidebar, type icons, SIZE/MODIFIED columns, F1–F6/Enter/Right/
Backspace/Left/`/`/Esc/Ctrl+H keys, `open/back/close/state/mounts` IPC,
Exclusive-focus surface model, argv-vector exec rules.

## 3. Verification (real `quickshell -p`, real Navigator.qml)

```
/ rows=19 canUp=false                    (root, empty stack → grey)
boot.readable=false home.readable=true   (dirProbe per-row)
Enter boot → dir="/" rows=19  info="/boot · not readable"   (BLOCKED, listing kept)
Enter home → dir="/home" stack=1
filesUp → "/" ; descend shows rows=0 pendingLoad=true (no stale frame)
filesGoTo("/root") → empty="permission denied — not readable" rd=false
filesUp → escapes to real back target
jumpRows = HOME, Downloads, .config, AI CENTER, var, root, etc
```

`/proc/mounts`-sourced roots, spaced ntfs3 dirs, IPC `state()` all verified.

## 4. Remaining notes for parent agent

- `state()` now also emits `readable` and `jumps` (additive; nothing
  removed). If downstream consumers validate the schema strictly, note it.
- The back row is mouse-only by design; Backspace/Left remain the keyboard
  path (unchanged).
- `recentDirs`/visited is session-scoped — nothing in the codebase
  persists `filesDir` history, and the brief said to only ship what the
  stack model supports.
