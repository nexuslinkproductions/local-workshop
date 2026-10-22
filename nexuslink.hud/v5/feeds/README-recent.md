# recent.py — F6 RECENT AND PINNED feed

One JSON object for the deck's Recent and Pinned widget: the newest downloads,
screenshots and recent files, the pinned folders, and a census by file type.
Python 3, standard library only, no network, no daemon, no watcher. The HUD
polls the script; a 10 s cache keeps two ticks from walking the tree twice.

    nexuslink.hud/v5/feeds/recent.py --json
    nexuslink.hud/v5/feeds/recent.py --config ~/NEXUS_AI_CENTER/my_paths.json --limit 4 --json
    nexuslink.hud/v5/feeds/recent.py --fixture nexuslink.hud/v5/fixtures/recent.json --json
    nexuslink.hud/v5/feeds/recent.py --self-check

Owner: F6 (`v5/f6-recent`). Contract: `cards/feeds-brief.md`. Phase 2 item 6 of
`MAIN-SCREEN-BUILD.md`.

## Config

Default `~/.config/nexuslink/hud_paths.json`, override with `--config PATH`.
Nothing writes to `~/.config`; the file is the user's.

```json
{
  "limit": 8,
  "downloads": ["~/Downloads"],
  "screenshots": ["~/Pictures/Screenshots"],
  "recent_files": ["~/Desktop", { "path": "~/Documents", "depth": 2 }],
  "pinned": [
    { "name": "HUD project", "path": "~/NEXUS_AI_CENTER/04_PROJECTS/HUD" },
    { "name": "Worktrees", "path": "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/plugins/.worktrees" },
    { "name": "Quarterly", "path": "~/Documents/Quarterly" }
  ]
}
```

| Key | Meaning |
|---|---|
| `limit` | items per list, 1 to 1000, default 8. `--limit` wins over this. |
| `downloads` | roots whose newest files fill the downloads list. |
| `screenshots` | roots whose newest files fill the screenshots list. |
| `recent_files` | roots that fill the recent-files list, merged by mtime. |
| `pinned` | folders (or files) shown as pins, in config order. No limit. |

A root is a string (`"~/Downloads"`, depth 1) or an object
`{"path": ..., "depth": N}`. `depth` counts directory levels: 1 is the root
itself (default), 2 adds one level of subdirectories, 0 means unlimited. A
relative path resolves against the directory holding the config, never the
current directory. Missing keys are allowed (that list stays empty). A config
with no usable root at all is reported as `ok: false`, not a crash.

## Output

```json
{"ok": true, "generated_at": "2026-10-22T21:12:31Z", "source": "fixture",
 "schema": "nexuslink.hud/v5/feeds/recent", "limit": 8,
 "downloads":     [{"name": "...", "path": "...", "size": 2168134, "mtime": "2026-10-22T21:12:02Z", "type": "archive"}],
 "screenshots":   [ ... same shape ... ],
 "recent_files":  [ ... same shape ... ],
 "pinned":        [{"name": "HUD project", "path": "...", "exists": true, "kind": "dir"}],
 "types":         {"image": 3, "document": 6, "archive": 2, "code": 1, "audio": 1, "video": 1, "other": 1},
 "broken": 1, "outside": 1,
 "roots":         [{"list": "downloads", "path": "~/Downloads", "depth": 1, "exists": true,
                    "files": 10, "broken": 0, "outside": 0, "reason": null}],
 "cached": false, "age_s": 0}
```

* `mtime` is UTC ISO-8601 with a `Z`, seconds resolution. Lists are newest
  first; equal mtimes sort by lowercased name, then name, so a tie is stable.
* `size` is bytes, or `null` when a fixture did not measure it.
* `path` is absolute — a path is the content here, the widget has to open it.
  `roots[].path` is display-only and keeps the `~` form.
* A file appears at most once across the three lists. The first list that
  claims it wins (downloads, then screenshots, then recent files), and later
  lists skip past it to keep their count, so a screenshot that also lives in
  Downloads is not shown twice.
* `types` counts only the items actually emitted, one key each for the seven
  buckets, zeros included. It is a census of the widget, not of the disk.
* `pinned` is not deduplicated against the file lists: a pin is a deliberate
  shortcut, not a recent item. `kind` is `"dir"`, `"file"`, or `null` when the
  path is gone. Pins are never subject to `--limit`.
* `broken` counts symlinks under the scanned roots whose target is gone.
  `outside` counts symlinks resolving outside every configured root (they are
  never followed). Both are totals; `roots[]` carries the per-root split.
* A missing, unreadable or non-directory root contributes nothing, records a
  `reason` on its `roots[]` row, and leaves `ok: true`. The rest of the feed
  is still real data.
* Entries starting with `.` are skipped, as are directories in the file lists
  (folders belong in `pinned`).

`--json` prints one compact line and nothing else. Without it the same object
is pretty-printed for a human. `source` is `live` or `fixture`.

## Type mapping

Case-insensitive, by extension. The table lives in `EXTENSIONS` at the top of
`recent.py`; two-part extensions win over the last part alone. An extension
that is not listed is `other` — nothing is guessed from a name, a size or a
magic number.

| Bucket | Extensions |
|---|---|
| `image` | png jpg jpeg jpe gif webp avif heic heif bmp tif tiff svg ico icns |
| `document` | pdf doc docx xls xlsx ppt pptx odt ods odp rtf txt md markdown csv tsv epub pages numbers key log tex |
| `archive` | zip tar gz tgz bz2 tbz xz txz 7z rar dmg iso pkg deb rpm zst lz4 |
| `code` | py js mjs cjs ts tsx jsx qml sh bash zsh fish rb go rs c h cc cpp hpp java kt swift php lua sql json yaml yml toml ini cfg conf xml html htm css scss sass vue svelte |
| `audio` | mp3 wav flac m4a aac ogg oga opus aiff aif alac wma |
| `video` | mp4 mov mkv avi webm m4v mpg mpeg wmv flv |
| `other` | everything else, including no extension at all |

Two-part extensions: `tar.gz`, `tar.bz2`, `tar.xz`, `tar.zst`, `tar.lz4` are
`archive`; `d.ts` is `code`. Known judgement calls: `.json`, `.yaml`, `.toml`
and `.ini` sit in `code` (they are source), `.log` and `.csv` sit in
`document`, `.iso` and `.dmg` sit in `archive`, `.sketch`, `.app` and `.env`
are `other` because nothing in this feed can know what they are.

## Cache

`~/.local/state/nexuslink/recent.json` for live reads,
`~/.local/state/nexuslink/recent-fixture.json` for fixture reads (a fixture
must never poison a live tick). One file, written atomically: a temp file in
the same directory then `os.replace`, so a reader never sees half a payload.

* A hit under 10.0 s re-serves the stored payload with `"cached": true` and
  `"age_s"` since it was built. `generated_at` stays the original build time —
  it is when the data was true, not when it was printed.
* The key covers the mode, the limit, the schema string and the config (or
  fixture) path plus its mtime, size and inode. Edit the config and the next
  call rebuilds.
* Only `ok: true` payloads are cached; an honest absence is cheap to re-derive
  and should not stick for 10 s.
* A cache directory that cannot be written makes the feed slower, not broken:
  the write is skipped and the fresh payload is still printed.
* Two environment hooks exist for tests: `NEXUSLINK_STATE_DIR` moves the cache
  directory, `NEXUSLINK_NO_CACHE=1` turns the cache off. Nothing else reads
  the environment.

## Fixtures

`nexuslink.hud/v5/fixtures/recent.json` is the shipped snapshot: an
illustrative Mac tree (hand-written, not a copy of a live listing), anchored to
the C1 snapshot time so the ordering is checkable tomorrow. It carries the
config it was taken with and the tree the roots held:

```json
{
  "config": { "limit": 8, "downloads": ["~/Downloads"], "pinned": [ ... ] },
  "roots": {
    "~/Downloads": {
      "exists": true, "kind": "dir",
      "files": [{"name": "hud-review.mp4", "size": 18440221, "mtime": 1792703402}]
    },
    "~/Documents/Quarterly": {"exists": false, "kind": null}
  }
}
```

* A `roots` key is the `~` display form of the configured root; entries are
  the files it held. A root absent from `roots`, or `exists: false`, gives the
  same `reason` on the `roots[]` row as a live missing directory.
* `mtime` is epoch seconds; `mtime_iso` is the same value for humans and is
  the fallback when `mtime` is absent.
* `"link": "<target>"` marks a symlink, `"broken": true` marks one whose
  target was gone. Containment against the configured roots is computed on the
  strings, so fixture mode never touches the host filesystem — not even to ask
  whether a path exists.
* `--fixture DIR` scans a directory tree instead: `DIR/hud_paths.json` is the
  config and relative roots resolve inside `DIR`. Same code path as live, no
  host state. Useful for a bigger, real-shaped check on Linux.

## Exit codes

| Code | When |
|---|---|
| `0` | data, and honest absence: `{"ok": false, "reason": "...", "kind": "missing"|"malformed"}` |
| `2` | caller error (`--limit` out of range, unknown flag, a `--config`/`--fixture` file named on the command line that does not exist or is not a file) and unexpected bugs (`"kind": "programming"`) |

Missing or malformed *content* never raises and never takes the process down:
a HUD tick sees a JSON object with a reason, not a traceback.

## Self-check

    nexuslink.hud/v5/feeds/recent.py --self-check

Builds a throwaway tree under the system temp dir with known names, sizes,
mtimes and extensions, then asserts the ordering, the limit cut, the name
tiebreak, hidden-file skipping, the `depth: 2` walk, cross-list dedupe (a
symlink to an already-claimed file), every one of the seven type buckets and
their exact census, the broken-symlink count, the outside-root refusal, the
missing-root row with `ok: true`, all three pin states, the fixture-directory
and shipped-fixture paths, and the cache: a second call with the tree deleted
must serve the same lists from `recent.json`, and a call with the cache deleted
must rebuild and see the tree gone. Error paths run through the real CLI
(named missing config → 2, malformed config → 0 with `ok: false`, empty config
→ 0, missing fixture → 2, bad flag → 2, absent default config → 0). It never
reads `~/Downloads` or any real root, and it never writes to `~/.config`.
Exit 0 when every check passes, 1 with the failed labels otherwise.

Linux owns the live-data check; this file proves the fixture and temp-tree
behaviour on a Mac that must not read Marcel's real folders.
