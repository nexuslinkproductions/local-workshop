# recent.py — F6 RECENT AND PINNED feed

One JSON object for the deck's Recent and Pinned widget: the newest downloads,
screenshots and recent files, the pinned folders, and a census by file type.
Python 3, standard library only, no network, no daemon, no watcher. The HUD
polls the script; a 10 s cache keeps two live ticks from walking the tree twice.
A fixture read is never cached and never reads the host, so its output is the
same on every machine: a fixture file carries the tree as data, and `--fixture
DIR` stands in for the whole machine, where `~` is that directory and a root
outside it is refused rather than read (see Fixtures).

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
current directory (a fixture file keeps it as written; see Fixtures). Missing
keys are allowed (that list stays empty). A config with no usable root at all
is reported as `ok: false`, not a crash.

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
  In a fixture file it is absolute under the `home` that fixture declares (`~`
  expands to it), or the `~` form itself when the fixture declares no home; it
  never embeds the running user's home. `roots[].path` is display-only and
  keeps the `~` form.
* A file appears at most once across the three lists. The first list that
  claims it wins (downloads, then screenshots, then recent files), and later
  lists skip past it to keep their count, so a screenshot that also lives in
  Downloads is not shown twice.
* `types` counts only the items actually emitted, one key each for the seven
  buckets, zeros included. It is a census of the widget, not of the disk.
* `pinned` is not deduplicated against the file lists: a pin is a deliberate
  shortcut, not a recent item. `kind` is `"dir"`, `"file"`, or `null` when the
  path is gone. Pins are never subject to `--limit`. A pin row carries a
  `reason` only when one of its boolean fields was not a boolean (see Fixtures).
* `broken` counts symlinks under the scanned roots whose target is gone.
  `outside` counts symlinks resolving outside every configured root (they are
  never followed). Both are totals; `roots[]` carries the per-root split.
* A missing, unreadable or non-directory root contributes nothing, records a
  `reason` on its `roots[]` row, and leaves `ok: true`. The rest of the feed
  is still real data. A root whose `exists`, or a file row whose `broken`, was
  not a boolean also records the note there.
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

`~/.local/state/nexuslink/recent.json`, written and read by live reads only.
A `--fixture` run, file or directory, never opens it and keeps no state
directory and no digest of the fixture, so a fixture run can neither read a
live payload nor leave one behind. The file is written atomically: a temp file
in the same directory then `os.replace`, so a reader never sees half a payload.

* A hit under 10.0 s re-serves the stored payload with `"cached": true` and
  `"age_s"` since it was built. `generated_at` stays the original build time —
  it is when the data was true, not when it was printed.
* The key covers the limit, the schema string and the config path plus its
  mtime, size and inode. Edit the config and the next call rebuilds.
* Only `ok: true` payloads are cached; an honest absence is cheap to re-derive
  and should not stick for 10 s.
* A cache directory that cannot be written makes the feed slower, not broken:
  the write is skipped and the fresh payload is still printed.
* Environment hooks: `NEXUSLINK_STATE_DIR` moves the cache directory,
  `NEXUSLINK_NO_CACHE=1` turns the cache off. `HOME` is read for live reads: to
  expand `~` in the config and to shorten a live path to its `~` display form.
  It also resolves a `~` in a path named on the command line, including the
  `--fixture` path itself, only so that path can be opened. No fixture mode
  expands `~` against `HOME`: a fixture file uses its own `home` (or keeps the
  `~` form) and `--fixture DIR` uses the directory. A fixture path is printed
  exactly as it was given, so no `HOME` value reaches a fixture's output.
  Nothing else reads the environment.

## Fixtures

`nexuslink.hud/v5/fixtures/recent.json` is the shipped snapshot: an
illustrative Mac tree (hand-written, not a copy of a live listing), anchored to
the C1 snapshot time so the ordering is checkable tomorrow. It carries the
config it was taken with, the home it stands in for, and the tree the roots
held:

```json
{
  "home": "/Users/marcel",
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

* `home` is the `~` the fixture stands in for, deliberately not the running
  user's. Every `~` in its config expands to that value, so `path` stays
  absolute and the output is byte-identical on any machine. A fixture without
  `home` keeps the `~` form instead (also machine-independent). Either way no
  host `HOME` value reaches a fixture file's output, and the fixture path
  itself is printed exactly as it was given. `home` must be an absolute path;
  any other value is `ok: false`, `kind: malformed`.
* A relative root in a fixture file is kept as written: there is no host
  directory to resolve it against. `--fixture DIR` still resolves relatives
  inside `DIR`.
* A `roots` key is the display form of the configured root (the `~` form for a
  home path); entries are the files it held. A root absent from `roots` gives
  `"root not present in fixture"` on its `roots[]` row, and `exists: false`
  gives the row's own `reason` or `"no such directory"` when it has none. A
  live missing root gives `"no such directory: <path>"` instead (and a live
  path that is not a directory gives `"not a directory: <path>"`).
* A file row's `name` is one bare file name. A row whose name is `.`, `..` or
  holds a path separator is skipped, so no fixture row can point outside its
  root.
* `mtime` is epoch seconds; `mtime_iso` is the same value for humans and is
  the fallback when `mtime` is absent.
* `"link": "<target>"` marks a symlink, `"broken": true` marks one whose
  target was gone. Containment against the configured roots is computed on the
  strings, so a fixture file never asks the host filesystem whether a path
  exists, and never reads a cache, a digest or a directory listing.
* Boolean fields are read strictly, never by truthiness. `true` or the string
  `"true"` is true; `false`, the string `"false"`, `""`, `0` and `"0"` are
  false; `null`, a list, an object or any other string is not a boolean at all,
  so the field counts as absent and the row's `reason` names it, for example
  `exists for ~/Downloads is not a boolean (null), treated as absent`. This
  covers `exists` on a root or a pin and `broken` on a file row, so a `"false"`
  string can never make a file look broken or a missing root look present.
* `--fixture DIR` is fixture mode as well, with the directory standing in for
  the whole machine: `DIR/hud_paths.json` is the config, `~` resolves to `DIR`,
  a relative root resolves inside `DIR`, and a root that resolves outside `DIR`
  is reported as `"root is outside the fixture directory"` and never read. A
  symlink whose target leaves `DIR` is counted as `outside` without a stat, so
  no host path is touched. The walk is the live one, so `roots[].path` prints in
  its `~` form relative to `DIR` and item paths are absolute inside `DIR`. No
  cache file and no state directory are used. Useful for a bigger, real-shaped
  check: copy a tree into a directory, point the feed at it, get that tree.

## Exit codes

| Code | When |
|---|---|
| `0` | data, and honest absence: `{"ok": false, "reason": "...", "kind": "missing"|"malformed"}` |
| `2` | caller error (`--limit` out of range, unknown flag, an empty `--config` or `--fixture` value, a `--config` or `--fixture` path named on the command line that does not exist, a `--config` path that is not a file, a `--fixture` directory with no `hud_paths.json`) and unexpected bugs (`"kind": "programming"`) |

Missing or malformed *content* never raises and never takes the process down:
a HUD tick sees a JSON object with a reason, not a traceback. Non-UTF-8 bytes,
JSON nested beyond the reader's limit, non-finite numbers (`NaN`, `Infinity`,
`1e400`) and a string holding a lone surrogate (`"\ud800"`: legal JSON that
UTF-8 cannot carry) are all `kind: malformed`, exit 0, one JSON line.

## Self-check

    nexuslink.hud/v5/feeds/recent.py --self-check

Builds a throwaway tree under the system temp dir with known names, sizes,
mtimes and extensions, then asserts the ordering, the limit cut, the name
tiebreak, hidden-file skipping, the `depth: 2` walk, cross-list dedupe (a
symlink to an already-claimed file), every one of the seven type buckets and
their exact census, the broken-symlink count, the outside-root refusal, the
missing-root row with `ok: true`, all three pin states, the fixture-directory
and shipped-fixture paths, and the cache: a second live call with the tree
deleted must serve the same lists from `recent.json`, and a call with the cache
deleted must rebuild and see the tree gone. Fixture purity has its own checks:
the shipped fixture run twice in a row stays `cached: false`, `age_s: 0` and
creates no state directory; the same fixture under two different `HOME` values
gives identical output apart from `generated_at`; and a fixture holding `null`,
`5`, `true`, `1.5` or `[]` answers `ok: false`, `kind: malformed`, exit 0.
Malformed content has its own group: a non-UTF-8 fixture, a 200k-deep array, a
`NaN`, `Infinity` or `1e400` size, and a config with `limit: 1e400` or
`depth: 1e400` all answer exit 0, `ok: false`, `kind: malformed`; a lone
surrogate in a name, a `home`, a root key or a reason answers the same way, with
an ASCII reason and no traceback; an empty `--fixture` or `--config` value exits
2 with `kind: caller`; and a fixture row named `../escape.png`, `.`, `..` or
`sub/nested.png` is skipped, so only the bare `kept.png` row survives under its
root. Strict booleans have their own group too: `exists` and `broken` are proven
for `true`, `"true"`, `false`, `"false"`, `""`, `0` and `"0"`, and `null`, `[]`,
`{}` and `"no"` are proven to count as absent with the field named in the
reason. Fixture-directory purity is proven on a directory holding its own tree:
`~` resolves to the directory, a root outside it is refused, the output is
identical under two `HOME` values, a host mtime change leaves it unchanged, and
no state directory appears.
Error paths run through the real CLI (named missing config → 2, malformed
config → 0 with `ok: false`, empty config → 0, missing fixture → 2, bad flag →
2, absent default config → 0). It never reads `~/Downloads` or any real root,
and it never writes to `~/.config`. Exit 0 when every check passes, 1 with the
failed labels otherwise.

Linux owns the live-data check; this file proves the fixture and temp-tree
behaviour on a Mac that must not read Marcel's real folders.
