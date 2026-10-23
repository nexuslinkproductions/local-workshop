#!/usr/bin/env python3
"""find.py - the Find feed reader: one bounded search, one JSON object.

    python3 feeds/find.py --query hud [--filter all|files|images|docs|downloads]
        [--limit 8] [--yuri-bin yuri] [--timeout 3] [--roots DIR ...]
        [--fixture PATH] [--json] [--self-check]

Two sources, both bounded:

  1. yuri, the text content index: ``yuri search <q> -n 8 --json`` (16 for the
     docs chip). An argv list, never a shell string, with a hard ``--timeout``
     (seconds); the whole process group is killed when it expires. ``yuri search
     --help`` is probed once per run (1 s). When it lists ``--kind`` / ``--recent``
     (stage 03), the Images, Docs and Downloads chips pass them the way Deck A's
     ``yuriCommand`` does.
  2. FALLBACK: remove after yuri stage 03 lands. A filename-only search with
     ``find`` over ~/Downloads, ~/Pictures, ~/Videos (or --roots): depth 3,
     case-insensitive substring on the basename, newest first, at most 200
     candidates, 200 ms budget. Hits carry ``"source": "name"``. It serves the All
     (media), Images and Downloads chips while yuri cannot.

Port of Deck A's feeds/FindFeed.qml (read only). SIGTERM or SIGINT kills the
children's process groups and exits without printing a partial object.
Contract and fields: feeds/README-find.md.
"""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402  envelope, DataProblem, tilde, read_json

SOURCE = "find"
FILTERS = ("all", "files", "images", "docs", "downloads")
YURI_TIMEOUT_DEFAULT = 3.0
PROBE_TIMEOUT = 1.0
# FALLBACK: remove after yuri stage 03 lands (the filename search constants).
NAME_BUDGET = 0.2
NAME_MAX = 200
NAME_DEPTH = 3
NAME_ROOTS = ("Downloads", "Pictures", "Videos")
CHIP_IMAGE_EXTS = frozenset("png jpg jpeg webp gif svg avif bmp heic".split())
CHIP_MEDIA_EXTS = CHIP_IMAGE_EXTS | frozenset("mp4 mkv webm mov avi m4v".split())
KIND_IMAGE_EXTS = frozenset("png jpg jpeg webp gif svg avif bmp heic tif tiff ico".split())
KIND_VIDEO_EXTS = frozenset("mp4 mkv webm mov avi m4v mpg mpeg wmv".split())
CODE_EXTS = frozenset(
    "rs py js jsx mjs cjs ts tsx qml sh bash zsh fish toml json jsonc yaml yml "
    "c h cc cpp cxx hpp go java kt kts rb lua php swift cs fs sql html htm css "
    "scss sass vue svelte nix ex exs erl hs ml clj scala zig v asm gradle cmake "
    "make mk patch diff".split())
DOC_EXTS = frozenset("txt text org rst adoc odt docx doc rtf tex epub csv tsv log".split())
KIND_ARG = {"images": "image", "docs": "doc", "downloads": "download"}
DOC_KINDS = ("md", "doc", "pdf")
YURI_KINDS = ("md", "code", "doc", "pdf", "image", "video", "download")
PASS_THROUGH = ("mime", "size", "mtime", "dims", "duration")
YURI_NOTE = {
    "missing": "yuri not found",
    "timeout": "yuri timed out",
    "unreadable": "yuri output unreadable",
}
_HOME_PREFIX = re.compile(r"^/(?:home|Users)/[^/]+(?=/|$)")
_TRACKED = set()  # Popen objects whose process group must die on SIGTERM/SIGINT


def emit(payload, compact):
    """One JSON object on stdout. ensure_ascii keeps the output ASCII-only."""
    if compact:
        line = json.dumps(payload, ensure_ascii=True, separators=(",", ":"))
    else:
        line = json.dumps(payload, ensure_ascii=True, indent=2)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def kill_group(proc):
    """SIGKILL the child's process group (the child was started in its own session)."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass


def run_capture(argv, timeout):
    """Run argv (a list, never a shell). Returns (stdout bytes, returncode, timed_out).

    returncode is None when the program cannot be started. On expiry the whole
    group is killed and the output written so far is returned.
    """
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return b"", None, False
    _TRACKED.add(proc)
    timed_out = False
    try:
        try:
            out, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            kill_group(proc)
            out, _ = proc.communicate()
    finally:
        kill_group(proc)
        _TRACKED.discard(proc)
    return (out or b""), proc.returncode, timed_out


def _stop(signum, _frame):
    for proc in list(_TRACKED):
        kill_group(proc)
    os._exit(128 + signum)


def install_signal_handlers():
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)


def ext_of(path):
    name = os.path.basename(str(path)).lower()
    dot = name.rfind(".")
    return "" if dot <= 0 else name[dot + 1:]


def kind_of(path):
    """Extension kind, as Deck A's kindOf."""
    ext = ext_of(path)
    if ext in ("md", "markdown", "mdx"):
        return "md"
    if ext in CODE_EXTS:
        return "code"
    if ext in DOC_EXTS:
        return "doc"
    if ext == "pdf":
        return "pdf"
    if ext in KIND_IMAGE_EXTS:
        return "image"
    if ext in KIND_VIDEO_EXTS:
        return "video"
    return "file"


def norm_kind(row, path):
    """mime first, then the kind yuri sent, then the extension (Deck A's normKind)."""
    mime = row.get("mime")
    if isinstance(mime, str):
        if mime.startswith("image/"):
            return "image"
        if mime.startswith("video/"):
            return "video"
    kind = row.get("kind")
    if isinstance(kind, str) and kind in YURI_KINDS:
        return kind
    return kind_of(path)


def short_path(path):
    """Home shortened to ~ so no absolute home path leaves the reader."""
    text = C.tilde(path) if os.path.isabs(path) else path
    return _HOME_PREFIX.sub("~", text, count=1)


def probe_yuri(yuri_bin):
    """(has_kind, has_recent) from `yuri search --help`, once per run, 1 s budget."""
    out, rc, timed_out = run_capture([yuri_bin, "search", "--help"], PROBE_TIMEOUT)
    if rc is None or timed_out:
        return False, False
    text = out.decode("utf-8", "replace")
    return ("--kind" in text), ("--recent" in text)


def search_yuri(yuri_bin, query, count, extra, timeout):
    """(state, rows). state is ok, missing, timeout or unreadable."""
    argv = [yuri_bin, "search", query, "-n", str(count), "--json"] + extra
    out, rc, timed_out = run_capture(argv, timeout)
    if rc is None:
        return "missing", []
    if timed_out:
        return "timeout", []
    try:
        rows = json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        return "unreadable", []
    if not isinstance(rows, list):
        return "unreadable", []
    return "ok", rows


def yuri_hits(rows, docs_chip, native_kind):
    hits = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        raw = row.get("path")
        if not isinstance(raw, str) or not raw.strip():
            continue
        path = raw.strip()
        kind = norm_kind(row, path)
        if docs_chip and not native_kind and kind not in DOC_KINDS:
            continue
        hit = {
            "title": C.text(row.get("title")) or os.path.basename(path),
            "path": short_path(path),
            "kind": kind,
            "score": round(C.number(row.get("score")) or 0.0, 4),
            "source": "yuri",
        }
        for key in PASS_THROUGH:
            if row.get(key) is not None:
                hit[key] = row[key]
        hits.append(hit)
    return hits


def name_roots(flt, explicit):
    """Existing roots only. Downloads chip skips Pictures, as Deck A does."""
    if explicit:
        bases = [os.path.abspath(os.path.expanduser(r)) for r in explicit]
    else:
        home = os.path.expanduser("~")
        bases = [os.path.join(home, d) for d in NAME_ROOTS]
    out = []
    for root in bases:
        if flt == "downloads" and os.path.basename(root.rstrip(os.sep)) == "Pictures":
            continue
        if os.path.isdir(root):
            out.append(root)
    return out


def search_names(roots, query, exts):
    """FALLBACK: remove after yuri stage 03. Filename-only search, returns (hits, timed_out).

    find over the roots, depth 3, case-insensitive substring on the basename,
    newest first, at most NAME_MAX candidates, NAME_BUDGET seconds. exts is a
    frozenset of accepted extensions, or None for any file.
    """
    needle = re.sub(r"[*?\[\]\\]", "", query)
    find_bin = shutil.which("find")
    if not needle or not roots or find_bin is None:
        return [], False
    argv = [find_bin] + roots + ["-maxdepth", str(NAME_DEPTH), "-type", "f",
                                 "-iname", "*" + needle + "*",
                                 "-printf", "%T@\t%s\t%p\n"]
    out, _rc, timed_out = run_capture(argv, NAME_BUDGET)
    text = out.decode("utf-8", "replace")
    lines = text.split("\n")
    if not text.endswith("\n"):
        lines = lines[:-1]  # the line the budget cut in half
    seen = set()
    cands = []
    for line in lines:
        parts = line.split("\t", 2)
        if len(parts) != 3 or not parts[2].startswith("/") or parts[2] in seen:
            continue
        try:
            mtime = float(parts[0])
        except ValueError:
            continue
        path = parts[2]
        if exts is not None and ext_of(path) not in exts:
            continue
        seen.add(path)
        cands.append((mtime, path))
    cands.sort(key=lambda c: (-c[0], c[1]))
    hits = []
    for _mtime, path in cands[:NAME_MAX]:
        hits.append({
            "title": os.path.basename(path),
            "path": short_path(path),
            "kind": kind_of(path),
            "score": 0.0,
            "source": "name",
        })
    return hits, timed_out


def build_live(args, query):
    flt = args.filter
    has_kind, has_recent = probe_yuri(args.yuri_bin)
    native = has_kind and flt in KIND_ARG
    want_yuri = native or flt not in ("images", "downloads")
    want_name = (not has_kind) and flt in ("images", "downloads", "all")
    roots = name_roots(flt, args.roots) if want_name else []
    no_roots = want_name and not roots
    if no_roots:
        want_name = False

    yuri_state, rows = "skipped", []
    if want_yuri:
        extra = []
        if native:
            extra += ["--kind", KIND_ARG[flt]]
        if has_recent and flt == "downloads":
            extra += ["--recent"]
        count = 16 if flt == "docs" else 8
        yuri_state, rows = search_yuri(args.yuri_bin, query, count, extra, args.timeout)
    yuri_ok = want_yuri and yuri_state == "ok"

    from_yuri = yuri_hits(rows, flt == "docs", native) if yuri_ok else []
    from_name, name_timed = [], False
    if want_name:
        if flt == "downloads":
            exts = None
        elif flt == "images":
            exts = CHIP_IMAGE_EXTS
        else:
            exts = CHIP_MEDIA_EXTS
        from_name, name_timed = search_names(roots, query, exts)

    results = []
    for hit in from_yuri:
        if len(results) >= args.limit:
            break
        results.append(hit)
    for hit in from_name:
        if len(results) >= args.limit:
            break
        if flt == "all" and hit["kind"] not in ("image", "video"):
            continue
        results.append(hit)

    if yuri_ok and want_name:
        backend = "yuri+fallback"
    elif yuri_ok:
        backend = "yuri"
    elif want_name:
        backend = "fallback"
    else:
        backend = "none"

    problem = YURI_NOTE.get(yuri_state) if want_yuri else None
    note = ""
    if problem:
        note = problem + (", filename search only" if want_name else "")
    if not results:
        if yuri_state == "timeout" or name_timed:
            note = "Search timed out"
        elif no_roots and flt != "all":
            note = ("No Downloads or Videos folder to search" if flt == "downloads"
                    else "No Pictures or Downloads folder to search")
    return C.envelope(SOURCE, "live", query=query, filter=flt, backend=backend,
                      note=note, results=results)


def chip_match(flt, kind, path):
    if flt == "images":
        return kind == "image"
    if flt == "docs":
        return kind in DOC_KINDS
    if flt == "downloads":
        return kind == "download" or "/Downloads/" in path
    return True


def build_fixture(args, query):
    """Snapshot corpus: rows matching the query text and chip, no host access."""
    data = C.read_json(args.fixture, "fixture")
    rows = data if isinstance(data, list) else (data.get("results") if isinstance(data, dict) else None)
    if not isinstance(rows, list):
        raise C.Malformed("fixture has no results list")
    needle = query.lower()
    results = []
    if needle:
        for row in rows:
            if not isinstance(row, dict):
                continue
            raw = row.get("path")
            if not isinstance(raw, str) or not raw.strip():
                continue
            path = raw.strip()
            kind = norm_kind(row, path)
            title = C.text(row.get("title")) or os.path.basename(path)
            if needle not in title.lower() and needle not in path.lower():
                continue
            if not chip_match(args.filter, kind, path):
                continue
            source = row.get("source") if row.get("source") in ("yuri", "name") else "yuri"
            hit = {
                "title": title,
                "path": short_path(path),
                "kind": kind,
                "score": round(C.number(row.get("score")) or 0.0, 4),
                "source": source,
            }
            for key in PASS_THROUGH:
                if row.get(key) is not None:
                    hit[key] = row[key]
            results.append(hit)
            if len(results) >= args.limit:
                break
    sources = {hit["source"] for hit in results}
    if "yuri" in sources and "name" in sources:
        backend = "yuri+fallback"
    elif "yuri" in sources:
        backend = "yuri"
    elif "name" in sources:
        backend = "fallback"
    else:
        backend = "none"
    return C.envelope(SOURCE, "fixture", query=query, filter=args.filter, backend=backend,
                      note="", results=results)


def positive_int(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("not an integer: %r" % value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def positive_float(value):
    try:
        number = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("not a number: %r" % value)
    if not number > 0:
        raise argparse.ArgumentTypeError("must be above 0")
    return number


def build_parser():
    parser = argparse.ArgumentParser(
        description="Find feed: bounded yuri search with a filename fallback. One JSON object.")
    parser.add_argument("--query", default="", help="search text; empty answers zero results")
    parser.add_argument("--filter", default="all", choices=FILTERS, help="chip (default all)")
    parser.add_argument("--limit", type=positive_int, default=8, help="max results (default 8)")
    parser.add_argument("--yuri-bin", default="yuri", help="yuri executable (default: PATH)")
    parser.add_argument("--timeout", type=positive_float, default=YURI_TIMEOUT_DEFAULT,
                        help="yuri wall clock in seconds (default 3)")
    parser.add_argument("--roots", nargs="+", metavar="DIR",
                        help="filename fallback roots (default ~/Downloads ~/Pictures ~/Videos)")
    parser.add_argument("--fixture", metavar="PATH", help="read a snapshot, touch no source")
    parser.add_argument("--json", action="store_true", help="one compact JSON line")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.self_check:
        return self_check()
    install_signal_handlers()
    query = (args.query or "").strip()
    mode = "fixture" if args.fixture else "live"
    try:
        if args.fixture:
            payload = build_fixture(args, query)
        elif not query:
            payload = C.envelope(SOURCE, "live", query=query, filter=args.filter,
                                 backend="none", note="", results=[])
        else:
            payload = build_live(args, query)
    except C.DataProblem as exc:
        payload = C.failure(SOURCE, mode, exc)
    except Exception as exc:  # noqa: BLE001  a bug is reported and exits 2
        emit({"ok": False, "source": SOURCE, "mode": mode, "generated_at": C.iso_now(),
              "reason": "programming error: %s: %s" % (type(exc).__name__, exc),
              "kind": "programming"}, args.json)
        return C.EXIT_PROGRAMMING
    emit(payload, args.json)
    return C.EXIT_OK


# ---------------------------------------------------------------- self-check

YURI_STUB = """#!/bin/sh
# self-check stub for yuri. STUB_MODE picks the behaviour, STUB_HELP the --help text.
if [ -n "${STUB_PIDFILE:-}" ]; then echo $$ > "$STUB_PIDFILE"; fi
if [ "$1" != "search" ]; then echo "stub: unknown command" >&2; exit 2; fi
if [ "$2" = "--help" ]; then
  echo "Usage: yuri search [OPTIONS] <QUERY>"
  echo "  -n, --limit <N>  Max hits [default: 10]"
  echo "      --json       JSON output"
  if [ "${STUB_HELP:-plain}" = "stage03" ]; then
    echo "      --kind <KIND>  Filter by kind"
    echo "      --recent       Newest first"
  fi
  exit 0
fi
kind=none; recent=0; prev=""
for a in "$@"; do
  if [ "$prev" = "--kind" ]; then kind="$a"; fi
  if [ "$a" = "--recent" ]; then recent=1; fi
  prev="$a"
done
case "${STUB_MODE:-rows}" in
  rows)
    printf '[{"kind":"md","line":5,"path":"%s/notes/hud-plan.md","score":-20.5,"title":"hud plan - what we change"},{"kind":"doc","path":"%s/Downloads/hud-notes.pdf","score":-3.25,"title":""}]\\n' "$HOME" "$HOME" ;;
  stage03)
    printf '[{"kind":"file","mime":"image/png","size":2048,"mtime":1700000000,"dims":[640,480],"path":"%s/Pictures/hud-shot.png","score":-9.0,"title":"hud shot"},{"kind":"file","mime":"video/mp4","size":10485760,"mtime":1700000100,"duration":12.5,"path":"%s/Videos/hud-clip.mp4","score":-8.0,"title":"hud clip"},{"kind":"download","path":"%s/Downloads/hud-notes.pdf","score":-1.0,"title":"args kind=%s recent=%s"}]\\n' "$HOME" "$HOME" "$HOME" "$kind" "$recent" ;;
  garbage) echo "yuri: index locked, retry later"; echo "<<not json>>" ;;
  hang) sleep 30 ;;
  *) echo "[]" ;;
esac
"""

SLOW_FIND_STUB = """#!/bin/sh
# self-check stub: one hit, then the find is slower than the 200 ms budget.
printf '1700000000.0\\t10\\t/slow/hud-slow.png\\n'
sleep 5
"""


def _write_exec(path, body):
    with open(path, "w", encoding="ascii") as handle:
        handle.write(body)
    os.chmod(path, 0o755)


def _pid_gone(pid, wait=2.0):
    end = time.monotonic() + wait
    while True:
        try:
            with open("/proc/%d/stat" % pid) as handle:
                state = handle.read().rsplit(")", 1)[1].split()[0]
        except (OSError, IndexError):
            return True
        if state in ("Z", "X"):
            return True
        if time.monotonic() > end:
            return False
        time.sleep(0.05)


def _run(extra, env=None, timeout=30):
    full_env = dict(os.environ)
    full_env.update(env or {})
    started = time.monotonic()
    proc = subprocess.run([sys.executable, os.path.abspath(__file__)] + extra,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=full_env, timeout=timeout)
    return proc.returncode, proc.stdout, time.monotonic() - started


def _json(raw):
    try:
        return json.loads(raw.decode("ascii"))
    except (ValueError, UnicodeDecodeError):
        return None


def self_check():
    failures = []
    count = [0]

    def check(name, ok, detail=""):
        count[0] += 1
        if ok:
            sys.stderr.write("ok    %s\n" % name)
        else:
            failures.append(name)
            sys.stderr.write("FAIL  %s %s\n" % (name, detail))

    root = tempfile.mkdtemp(prefix="find-self-", dir=os.environ.get("TMPDIR") or None)
    try:
        home = os.path.join(root, "home")
        bindir = os.path.join(root, "bin")
        slowbin = os.path.join(root, "slowbin")
        for d in (bindir, slowbin, os.path.join(home, "Downloads"),
                  os.path.join(home, "Pictures"), os.path.join(home, "Videos"),
                  os.path.join(home, "notes")):
            os.makedirs(d)
        stub = os.path.join(bindir, "yuri")
        _write_exec(stub, YURI_STUB)
        _write_exec(os.path.join(slowbin, "find"), SLOW_FIND_STUB)
        missing = os.path.join(root, "nope", "yuri")
        pidfile = os.path.join(root, "stub.pid")
        now = time.time()
        for rel, age in {
            "Downloads/hud-notes.pdf": 300, "Downloads/hud-invoice.txt": 200,
            "Downloads/unrelated.zip": 100, "Pictures/hud-shot.png": 100,
            "Pictures/screenshot-hud-final.jpg": 10, "Pictures/hud-caf\u00e9.png": 500,
            "Videos/hud-clip.mp4": 50, "Videos/readme.txt": 40, "notes/hud-plan.md": 5,
        }.items():
            path = os.path.join(home, rel)
            open(path, "w").close()
            os.utime(path, (now - age, now - age))
        home_env = {"HOME": home}

        def titles(payload):
            return [hit.get("title") for hit in (payload or {}).get("results", [])]

        # 1 normal yuri rows: passthrough absent, home shortened, pretty == compact
        code, out, _ = _run(["--query", "hud", "--filter", "files", "--yuri-bin", stub, "--json"],
                            dict(home_env, STUB_MODE="rows"))
        data = _json(out)
        check("yuri rows: exit 0 and ok", code == 0 and data and data.get("ok") is True, str(code))
        check("yuri rows: backend yuri, two hits",
              data and data.get("backend") == "yuri" and len(data.get("results", [])) == 2)
        if data and data.get("results"):
            first = data["results"][0]
            check("yuri rows: title, path ~, kind md, source yuri",
                  first.get("title") == "hud plan - what we change"
                  and first.get("path") == "~/notes/hud-plan.md"
                  and first.get("kind") == "md" and first.get("source") == "yuri", str(first))
            check("yuri rows: no stage 03 fields without yuri sending them",
                  not any(k in first for k in PASS_THROUGH))
            check("yuri rows: empty title falls back to basename",
                  data["results"][1].get("title") == "hud-notes.pdf")
        pretty_code, pretty_out, _ = _run(["--query", "hud", "--filter", "files",
                                           "--yuri-bin", stub], dict(home_env, STUB_MODE="rows"))
        check("pretty output is the same object, several lines",
              pretty_code == 0 and _json(pretty_out) == data and pretty_out.count(b"\n") > 2)

        # 2 stage 03 rows: passthrough of mime/size/mtime/dims/duration, kind from mime
        code, out, _ = _run(["--query", "hud", "--filter", "files", "--yuri-bin", stub, "--json"],
                            dict(home_env, STUB_MODE="stage03", STUB_HELP="stage03"))
        data = _json(out)
        res = (data or {}).get("results", [])
        check("stage03 rows: passthrough and mime kind",
              len(res) == 3 and res[0].get("kind") == "image" and res[0].get("mime") == "image/png"
              and res[0].get("size") == 2048 and res[0].get("mtime") == 1700000000
              and res[0].get("dims") == [640, 480] and res[1].get("kind") == "video"
              and res[1].get("duration") == 12.5, str(res)[:300])
        code, out, _ = _run(["--query", "hud", "--filter", "images", "--yuri-bin", stub, "--json"],
                            dict(home_env, STUB_MODE="stage03", STUB_HELP="stage03"))
        data = _json(out)
        check("stage03 images chip passes --kind image, no name fallback",
              data and data.get("backend") == "yuri"
              and "args kind=image recent=0" in titles(data), str(data)[:300])
        code, out, _ = _run(["--query", "hud", "--filter", "downloads", "--yuri-bin", stub, "--json"],
                            dict(home_env, STUB_MODE="stage03", STUB_HELP="stage03"))
        data = _json(out)
        check("stage03 downloads chip passes --kind download --recent",
              data and "args kind=download recent=1" in titles(data), str(data)[:300])

        # 3 yuri missing: All falls back to media names only, newest first
        code, out, _ = _run(["--query", "hud", "--filter", "all", "--yuri-bin", missing, "--json"],
                            dict(home_env))
        data = _json(out)
        expect = ["screenshot-hud-final.jpg", "hud-clip.mp4", "hud-shot.png", "hud-caf\u00e9.png"]
        check("yuri missing: fallback media, newest first",
              data and titles(data) == expect and data.get("backend") == "fallback"
              and all(h.get("source") == "name" for h in data.get("results", []))
              and data.get("note") == "yuri not found, filename search only", str(titles(data)))
        check("ASCII only output (non-ASCII file name escaped)",
              all(b < 128 for b in out) and "caf\\u00e9" in out.decode("ascii"))

        # 4 images chip without stage 03 is name only; Downloads chip skips Pictures
        code, out, _ = _run(["--query", "hud", "--filter", "images", "--yuri-bin", missing, "--json"],
                            dict(home_env))
        data = _json(out)
        check("images chip: fallback only, image kinds",
              data and titles(data) == ["screenshot-hud-final.jpg", "hud-shot.png", "hud-caf\u00e9.png"]
              and data.get("backend") == "fallback", str(titles(data)))
        code, out, _ = _run(["--query", "hud", "--filter", "downloads", "--yuri-bin", missing, "--json"],
                            dict(home_env))
        data = _json(out)
        check("downloads chip: Downloads and Videos only, newest first",
              data and titles(data) == ["hud-clip.mp4", "hud-invoice.txt", "hud-notes.pdf"]
              and data.get("backend") == "fallback", str(titles(data)))

        # 5 All with yuri rows: yuri first, then name media, merged to the limit
        code, out, _ = _run(["--query", "hud", "--filter", "all", "--yuri-bin", stub, "--json"],
                            dict(home_env, STUB_MODE="rows"))
        data = _json(out)
        sources = [h.get("source") for h in (data or {}).get("results", [])]
        check("All merges yuri first then name media",
              data and data.get("backend") == "yuri+fallback" and sources[:2] == ["yuri", "yuri"]
              and sources[2:] == ["name"] * (len(sources) - 2) and len(sources) == 6, str(sources))

        # 6 yuri prints garbage
        code, out, _ = _run(["--query", "hud", "--filter", "files", "--yuri-bin", stub, "--json"],
                            dict(home_env, STUB_MODE="garbage"))
        data = _json(out)
        check("yuri garbage: ok, no crash, note",
              code == 0 and data and data.get("ok") is True and data.get("results") == []
              and data.get("note") == "yuri output unreadable" and data.get("backend") == "none", str(data))

        # 7 yuri hangs past the timeout: return within timeout + 0.5 s, stub gone
        if os.path.exists(pidfile):
            os.unlink(pidfile)
        code, out, elapsed = _run(["--query", "hud", "--filter", "files", "--yuri-bin", stub,
                                   "--timeout", "1", "--json"],
                                  dict(home_env, STUB_MODE="hang", STUB_PIDFILE=pidfile))
        data = _json(out)
        check("yuri hang: returns within timeout + 0.5 s",
              elapsed < 1.5 and code == 0 and data and data.get("note") == "Search timed out",
              "elapsed=%.2f" % elapsed)
        if os.path.exists(pidfile):
            with open(pidfile) as handle:
                check("yuri hang: stub child is gone", _pid_gone(int(handle.read().strip())))

        # 8 budget: a slow find is cut at 200 ms and its finished line is kept
        code, out, elapsed = _run(["--query", "hud", "--filter", "images", "--yuri-bin", missing,
                                   "--roots", os.path.join(home, "Pictures"), "--json"],
                                  dict(home_env, PATH=slowbin + os.pathsep + os.environ.get("PATH", "")))
        data = _json(out)
        check("name budget: slow find cut at 200 ms, partial line kept",
              elapsed < 1.5 and data and titles(data) == ["hud-slow.png"], "elapsed=%.2f" % elapsed)

        # 9 large tree: 4800 files, result capped at the limit, quick
        big = os.path.join(root, "big")
        for d in range(40):
            sub = os.path.join(big, "d%02d" % d)
            os.makedirs(sub)
            for f in range(120):
                open(os.path.join(sub, "hud-%04d.png" % (d * 120 + f)), "w").close()
        code, out, elapsed = _run(["--query", "hud", "--filter", "images", "--yuri-bin", missing,
                                   "--roots", big, "--json"], dict(home_env))
        data = _json(out)
        check("large tree: capped at limit, under 2 s",
              code == 0 and data and len(data.get("results", [])) == 8 and elapsed < 2.0,
              "elapsed=%.2f" % elapsed)

        # 10 empty query spawns nothing
        if os.path.exists(pidfile):
            os.unlink(pidfile)
        code, out, _ = _run(["--query", "", "--yuri-bin", stub, "--json"],
                            dict(home_env, STUB_PIDFILE=pidfile))
        data = _json(out)
        check("empty query: ok, zero results, nothing spawned",
              code == 0 and data and data.get("ok") is True and data.get("results") == []
              and data.get("backend") == "none" and not os.path.exists(pidfile))

        # 11 SIGTERM kills the stub child's group and prints nothing
        if os.path.exists(pidfile):
            os.unlink(pidfile)
        proc = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--query", "hud",
                                 "--filter", "files", "--yuri-bin", stub, "--timeout", "20"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, HOME=home, STUB_MODE="hang", STUB_PIDFILE=pidfile))
        for _ in range(100):
            if os.path.exists(pidfile):
                break
            time.sleep(0.05)
        proc.send_signal(signal.SIGTERM)
        try:
            out, _err = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _err = proc.communicate()
        check("SIGTERM: exits, prints no partial object", out == b"" and proc.returncode != 0,
              "rc=%s" % proc.returncode)
        if os.path.exists(pidfile):
            with open(pidfile) as handle:
                check("SIGTERM: yuri child pid is gone", _pid_gone(int(handle.read().strip())))
        else:
            check("SIGTERM: yuri child pid is gone", False, "stub never started")

        # 12 fixture: snapshot corpus, no host access, paths shortened
        fixture = os.path.join(root, "fixture.json")
        with open(fixture, "w") as handle:
            json.dump([
                {"path": "/home/operator/Documents/HUD/deck-charter.md", "kind": "doc", "score": 0.91},
                {"path": "/home/operator/Pictures/deck/s2-rest.png", "kind": "image", "score": 0.88},
                {"path": "/home/operator/Downloads/screenshot-hud-final.png", "kind": "download", "score": 0.84},
            ], handle)
        if os.path.exists(pidfile):
            os.unlink(pidfile)
        code, out, _ = _run(["--fixture", fixture, "--query", "hud", "--json", "--yuri-bin", stub],
                            dict(home_env, STUB_PIDFILE=pidfile))
        data = _json(out)
        check("fixture: mode fixture, shortened paths, no host access",
              code == 0 and data and data.get("mode") == "fixture" and len(data.get("results", [])) == 2
              and b"/home/operator" not in out and not os.path.exists(pidfile), str(data)[:200])
        code, out, _ = _run(["--fixture", os.path.join(root, "absent.json"), "--query", "hud", "--json"])
        data = _json(out)
        check("fixture missing: ok false, kind missing, exit 0",
              code == 0 and data and data.get("ok") is False and data.get("kind") == "missing")
        bad = os.path.join(root, "bad.json")
        with open(bad, "w") as handle:
            handle.write("not json")
        code, out, _ = _run(["--fixture", bad, "--query", "hud", "--json"])
        data = _json(out)
        check("fixture malformed: ok false, kind malformed, exit 0",
              code == 0 and data and data.get("ok") is False and data.get("kind") == "malformed")

        # 13 bad invocation is exit 2
        code, out, _ = _run(["--filter", "bogus", "--json"])
        check("bad --filter: exit 2, nothing on stdout", code == 2 and out == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    summary = {"ok": not failures, "source": SOURCE, "mode": "self-check",
               "checks": count[0], "failed": failures}
    emit(summary, True)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
