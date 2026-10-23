# find.py: the Find feed reader

Reader for the Find overlay. One bounded search, one JSON object on stdout. Stdlib
only, no daemon, no cache, no writes to disk. It follows the contract in
`README.md` (exit 0 for data problems, exit 2 for a bug or a bad invocation).

## Run

    python3 nexuslink.hud/v5/feeds/find.py --query hud --json
    python3 nexuslink.hud/v5/feeds/find.py --query hud --filter images
    python3 nexuslink.hud/v5/feeds/find.py --query hud --fixture nexuslink.hud/v5/fixtures/find.json
    python3 nexuslink.hud/v5/feeds/find.py --self-check

| Flag | Default | Meaning |
|---|---|---|
| `--query Q` | empty | search text, trimmed. Empty answers ok with zero results and spawns nothing |
| `--filter F` | `all` | chip: `all`, `files`, `images`, `docs`, `downloads` |
| `--limit N` | 8 | max results |
| `--yuri-bin BIN` | `yuri` | yuri executable (PATH lookup when bare) |
| `--timeout S` | 3 | yuri wall clock in seconds, hard kill of its process group |
| `--roots DIR ...` | `~/Downloads ~/Pictures ~/Videos` | FALLBACK search roots (missing ones are skipped) |
| `--fixture PATH` | none | snapshot corpus, touches no source, no process |
| `--json` | off | one compact line; without it the same object, pretty printed |
| `--self-check` | | the built-in checks, one `ok`/`FAIL` line each on stderr, one JSON summary on stdout |

## Output

    {"ok": true, "source": "find", "mode": "live", "generated_at": "2026-10-23T10:33:30Z",
     "query": "hud", "filter": "all", "backend": "yuri+fallback", "note": "",
     "results": [{"title": "...", "path": "~/dir/file.md", "kind": "md",
                  "score": -20.33, "source": "yuri"}, ...]}

* `mode` is `live` or `fixture`.
* `backend`: `yuri` (yuri answered, no name search), `yuri+fallback` (yuri and the
  filename search both ran), `fallback` (filename search only), `none` (nothing ran,
  or the query was empty).
* `note` is one short phrase or empty: `yuri not found`, `yuri timed out`,
  `yuri output unreadable`, each with `, filename search only` when the fallback ran;
  `Search timed out` when there are no results and yuri or the filename search timed
  out; `No Pictures or Downloads folder to search` / `No Downloads or Videos folder
  to search` when no root exists and there are no results.
* `results[]`: `title` is yuri's title when it sends one, else the basename.
  `path` has the home prefix shortened to `~` (also `/home/<user>/` and
  `/Users/<user>/` from a snapshot). `kind` is `md`, `code`, `doc`, `pdf`, `image`,
  `video`, `file` or `download`. `score` is yuri's own score rounded to 4 places
  (bm25-like, more negative is better, so order is yuri's ranking); filename hits
  carry `0.0`. `source` is `yuri` or `name`.
* Pass-through fields `mime`, `size`, `mtime`, `dims`, `duration` appear only on
  yuri rows that send them, and only when not null. Filename hits never carry them.
* Output is ASCII only: non-ASCII text is written as `\uXXXX` escapes.
* Data problems: `{"ok": false, "reason": "...", "kind": "missing|malformed"}`,
  exit 0. This is the `--fixture` path (no file, or no JSON). A missing or broken
  yuri is not a top-level failure: it becomes the `note`.
* Exit 2 only for a bad invocation (argparse, for example `--filter bogus`) or a bug.

## Sources

### 1. yuri (text content index)

    yuri search <q> -n 8 --json          (-n 16 for the docs chip)

* argv list, never a shell string. Its own process group (`start_new_session`) is
  killed with `os.killpg` on expiry, so a hung yuri cannot outlive the call.
* `yuri search --help` is probed once per run with a 1 s budget. When it lists
  `--kind` / `--recent` (yuri stage 03), the Images, Docs and Downloads chips pass
  `--kind image|doc|download` (Downloads also `--recent`), the same as Deck A's
  `yuriCommand`. The Docs chip keeps only md/doc/pdf when `--kind` is absent.
* Today's yuri has no `--kind` / `--recent` (checked: `yuri search --help` lists only
  `--db`, `-n/--limit`, `--json`), so Images and Downloads run on the fallback.
* Missing binary, timeout, or output that is not a JSON array: the yuri part is empty
  and the note says why.

### 2. FALLBACK: remove after yuri stage 03 lands

A filename-only search with `find` (GNU find, `-printf`). It is the only part of this
reader that goes away with stage 03. Search it in code by `FALLBACK`.

* Roots: `~/Downloads`, `~/Pictures`, `~/Videos` (or `--roots`), existing ones only,
  depth 3, `-type f`, `-iname "*<q>*"` (case-insensitive substring of the basename;
  `* ? [ ] \` are stripped from the query first).
* Chips: All uses image and video extensions (media) and merges after the yuri hits;
  Images uses image extensions; Downloads uses any file from `Downloads` and
  `Videos` (Pictures is skipped for this chip, as in Deck A).
* At most 200 candidates, newest first (sorted by mtime, then path).
* 200 ms budget: `find` is killed when the budget ends, and the line it was in the
  middle of is dropped, so every hit is complete.
* Hits carry `"source": "name"` and `"kind"` from the extension.

## Kind

From `mime` first (`image/*` is image, `video/*` is video), then the kind yuri sent
(`md code doc pdf image video download`), then the extension (Deck A's `kindOf`:
md, code, doc, pdf, image, video, otherwise file).

## Lifetime and signals

DeckMain kills the previous `find.py` when a new query starts. SIGTERM or SIGINT
kills the process group of every child that is running, then exits at once (143 for
SIGTERM, 130 for SIGINT) without printing a partial object. Nothing is written to
disk.

## Self-check

    python3 nexuslink.hud/v5/feeds/find.py --self-check

It builds a temp tree under `$TMPDIR`, with a stub yuri and a stub find that are
selected by `--yuri-bin` or by `PATH`. It runs this reader as a subprocess and checks:

* normal yuri rows: values, `~` paths, basename title, no pass-through fields, pretty
  and compact output identical;
* stage 03 rows: mime/size/mtime/dims/duration passed through, kind from mime, `--kind`
  and `--recent` passed for the chips;
* yuri missing: All falls back to media, newest first, with the note;
* yuri garbage: `yuri output unreadable`, exit 0;
* yuri hanging: `--timeout 1` returns in under 1.5 s and the stub pid is gone;
* the fallback over a temp HOME (All, Images, Downloads roots, newest first);
* the 200 ms budget with a stub find that is slower than the budget;
* a 4800-file tree: capped at the limit, under 2 s;
* an empty query: zero results, no child spawned;
* SIGTERM: no output, exit 143, the stub child pid is gone;
* the fixture: mode fixture, shortened paths, no host access; missing and malformed
  fixtures are `ok: false`;
* a bad `--filter` exits 2;
* ASCII-only stdout (a non-ASCII file name is escaped).

It exits non-zero on any failure, and prints `{"ok": true, ..., "checks": N,
"failed": []}` on stdout. `run-self-checks.sh` runs it with the other readers.

## Fixture

`--fixture` reads a snapshot: a list of rows (the shape of `fixtures/find.json`) or
an object with a `results` list. Rows are a corpus: a row answers when the query text
is in its title or path and it matches the chip (`images` = image kind, `docs` =
md/doc/pdf, `downloads` = kind download or a `/Downloads/` path, otherwise all). Empty
query, zero results. Row `source` is kept when it is `yuri` or `name`.
