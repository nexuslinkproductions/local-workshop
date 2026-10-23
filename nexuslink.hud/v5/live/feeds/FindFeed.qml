import QtQuick
import Quickshell
import Quickshell.Io

// Find feed. Two bounded data sources:
//  1) yuri, text CONTENT index: `yuri search <q> -n 8 --json`, after a 120 ms
//     typing pause, one process per query, older processes killed.
//  2) a FILENAME-ONLY name search over nameRoots with fd (fallback find).
//     yuri indexes text only, so image and Downloads hits can only come from
//     file NAMES, never from content. Those hits carry source: "name".
// Sequence numbers drop stale output from both sources.
Item {
    id: root

    // Set by DeckV5 while the deck (and the Find overlay) is shown. The feed
    // does nothing while this is false; a query typed before activation is
    // searched as soon as active becomes true.
    property bool active: false
    property string query: ""
    property string filter: "all"

    // FILENAME-ONLY search roots. Default: Downloads, Pictures and the
    // Screenshots folder under Pictures (missing roots are skipped by the
    // helper script). Tests point this at a scratch folder.
    property var nameRoots: [
        Quickshell.env("HOME") + "/Downloads",
        Quickshell.env("HOME") + "/Pictures",
        Quickshell.env("HOME") + "/Pictures/Screenshots"
    ]

    readonly property var results: _results
    readonly property bool busy: _busy
    readonly property string note: _note
    // Diagnostics for tests: how many yuri processes were started.
    readonly property int spawnCount: _spawnCount

    property var _results: []
    property bool _busy: false
    property string _note: ""
    property int _spawnCount: 0
    property int _seq: 0
    property var _yuriHits: []
    property var _nameHits: []
    property bool _yuriDone: true
    property bool _nameDone: true
    property bool _wantYuri: false
    property bool _wantName: false
    property bool _nameNoRoots: false

    visible: false
    width: 0
    height: 0

    onQueryChanged: {
        root.cancel()
        if (root.active && root.query.trim().length > 0)
            debounce.restart()
    }
    onFilterChanged: {
        root.cancel()
        if (root.active && root.query.trim().length > 0)
            debounce.restart()
    }
    onActiveChanged: {
        root.cancel()
        if (root.active && root.query.trim().length > 0)
            debounce.restart()
    }
    onNameRootsChanged: {
        root.cancel()
        if (root.active && root.query.trim().length > 0)
            debounce.restart()
    }
    Component.onCompleted: {
        if (root.active && root.query.trim().length > 0)
            debounce.restart()
    }

    function baseName(p) {
        var s = String(p)
        var i = s.lastIndexOf("/")
        return i < 0 ? s : s.substring(i + 1)
    }

    function extOf(path) {
        var p = String(path).toLowerCase()
        var name = p.substring(p.lastIndexOf("/") + 1)
        var dot = name.lastIndexOf(".")
        return dot <= 0 ? "" : name.substring(dot + 1)
    }

    // kind is one of md, code, doc, pdf, image, file.
    function kindOf(path) {
        var ext = extOf(path)
        if (ext === "md" || ext === "markdown" || ext === "mdx")
            return "md"
        if (["rs", "py", "js", "jsx", "mjs", "cjs", "ts", "tsx", "qml",
             "sh", "bash", "zsh", "fish", "toml", "json", "jsonc", "yaml",
             "yml", "c", "h", "cc", "cpp", "cxx", "hpp", "go", "java", "kt",
             "kts", "rb", "lua", "php", "swift", "cs", "fs", "sql", "html",
             "htm", "css", "scss", "sass", "vue", "svelte", "nix", "ex",
             "exs", "erl", "hs", "ml", "clj", "scala", "zig", "v", "asm",
             "gradle", "cmake", "make", "mk", "patch", "diff"].indexOf(ext) >= 0)
            return "code"
        if (["txt", "text", "org", "rst", "adoc", "odt", "docx", "doc",
             "rtf", "tex", "epub", "csv", "tsv", "log"].indexOf(ext) >= 0)
            return "doc"
        if (ext === "pdf")
            return "pdf"
        if (["png", "jpg", "jpeg", "webp", "gif", "svg", "avif", "bmp",
             "tif", "tiff", "heic", "ico"].indexOf(ext) >= 0)
            return "image"
        return "file"
    }

    function cancel() {
        _seq++
        debounce.stop()
        yuriWatchdog.stop()
        nameBudget.stop()
        yuriProc.running = false
        nameProc.running = false
        _busy = false
        _note = ""
        _results = []
        _yuriHits = []
        _nameHits = []
        _yuriDone = true
        _nameDone = true
        _wantYuri = false
        _wantName = false
        _nameNoRoots = false
    }

    function startSearch() {
        cancel()
        var q = String(query).trim()
        if (!active || q.length === 0)
            return
        var f = String(filter)
        // yuri covers all, files and docs. Images and Downloads are name-only.
        _wantYuri = (f !== "images" && f !== "downloads")
        _wantName = (f === "images" || f === "downloads" || f === "all")
        if (_wantName && nameRoots.length === 0) {
            _wantName = false
            _nameNoRoots = true
        }
        var s = _seq
        if (_wantYuri) {
            _yuriDone = false
            yuriProc.runSeq = s
            yuriProc.command = ["yuri", "search", q, "-n", "8", "--json"]
            _spawnCount++
            yuriProc.running = true
            yuriWatchdog.restart()
        }
        if (_wantName) {
            _nameDone = false
            nameProc.runSeq = s
            nameProc.command = nameCommand(q, (f === "images" || f === "all") ? "image" : "any")
            nameProc.running = true
            nameBudget.restart()
        }
        _busy = !(_yuriDone && _nameDone)
        if (!_busy)
            recompute()
    }

    // sh -c script for the filename-only search. $1 query, $2 mode, rest roots.
    // fd when present, find otherwise. Max depth 3 per root, max 8 results,
    // absolute paths only, and a Screenshots folder under any root is scanned
    // too. Prints NOROOTS when no root exists so the feed can be honest.
    readonly property string nameScript: "q=$1\n" +
        "mode=$2\n" +
        "shift 2\n" +
        "found=0\n" +
        "for r in \"$@\"; do\n" +
        "  if [ -d \"$r\" ]; then found=1; fi\n" +
        "done\n" +
        "if [ \"$found\" -eq 0 ]; then echo NOROOTS; exit 0; fi\n" +
        "hasfd=0\n" +
        "if command -v fd >/dev/null 2>&1; then hasfd=1; fi\n" +
        "scan() {\n" +
        "  rr=$1\n" +
        "  if [ \"$hasfd\" -eq 1 ]; then\n" +
        "    if [ \"$mode\" = image ]; then\n" +
        "      fd -i -F -t f -d 3 -e png -e jpg -e jpeg -e webp -e gif -e svg -e avif \"$q\" \"$rr\" 2>/dev/null\n" +
        "    else\n" +
        "      fd -i -F -t f -d 3 \"$q\" \"$rr\" 2>/dev/null\n" +
        "    fi\n" +
        "  else\n" +
        "    if [ \"$mode\" = image ]; then\n" +
        "      find \"$rr\" -maxdepth 3 -type f -iname \"*$q*\" \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.svg' -o -iname '*.avif' \\) 2>/dev/null\n" +
        "    else\n" +
        "      find \"$rr\" -maxdepth 3 -type f -iname \"*$q*\" 2>/dev/null\n" +
        "    fi\n" +
        "  fi\n" +
        "}\n" +
        "for r in \"$@\"; do\n" +
        "  [ -d \"$r\" ] || continue\n" +
        "  scan \"$r\"\n" +
        "  if [ -d \"$r/Screenshots\" ]; then scan \"$r/Screenshots\"; fi\n" +
        "done | sort -u | head -n 8\n"

    function nameCommand(q, mode) {
        var args = ["sh", "-c", nameScript, "findfeed", q, mode]
        for (var i = 0; i < nameRoots.length; i++)
            args.push(String(nameRoots[i]))
        return args
    }

    function parseYuri(raw) {
        var out = []
        var arr = null
        try { arr = JSON.parse(String(raw)) } catch (e) { arr = null }
        if (!Array.isArray(arr))
            return out
        for (var i = 0; i < arr.length && out.length < 8; i++) {
            var r = arr[i]
            if (!r || !r.path)
                continue
            var p = String(r.path)
            out.push({
                "title": r.title ? String(r.title) : baseName(p),
                "path": p,
                "kind": kindOf(p),
                "score": Number(r.score) || 0,
                "source": "yuri"
            })
        }
        return out
    }

    function parseName(raw) {
        var out = []
        var noRoots = false
        var lines = String(raw).split("\n")
        for (var i = 0; i < lines.length && out.length < 8; i++) {
            var p = lines[i].trim()
            if (p.length === 0)
                continue
            if (p === "NOROOTS") {
                noRoots = true
                continue
            }
            if (p.charAt(0) !== "/")
                continue
            out.push({
                "title": baseName(p),
                "path": p,
                "kind": kindOf(p),
                "score": 0,
                "source": "name"
            })
        }
        _nameNoRoots = noRoots
        return out
    }

    function finishYuri(raw) {
        if (yuriProc.runSeq !== _seq || _yuriDone)
            return
        yuriWatchdog.stop()
        _yuriHits = parseYuri(raw)
        _yuriDone = true
        recompute()
    }

    function finishName(raw) {
        if (nameProc.runSeq !== _seq || _nameDone)
            return
        nameBudget.stop()
        _nameHits = parseName(raw)
        _nameDone = true
        recompute()
    }

    function recompute() {
        if (!_yuriDone || !_nameDone)
            return
        var out = []
        var i
        if (_wantYuri) {
            for (i = 0; i < _yuriHits.length && out.length < 8; i++)
                out.push(_yuriHits[i])
        }
        if (_wantName) {
            // All: yuri hits first, then name hits of kind image, max 8 total.
            // Images: name hits are already image-only. Downloads: any file.
            var imagesOnly = (String(filter) === "all")
            for (i = 0; i < _nameHits.length && out.length < 8; i++) {
                if (imagesOnly && _nameHits[i].kind !== "image")
                    continue
                out.push(_nameHits[i])
            }
        }
        _results = out
        _busy = false
        if (out.length === 0 && _nameNoRoots && String(filter) !== "all") {
            _note = (String(filter) === "downloads")
                ? "No Downloads or Screenshots folder to search"
                : "No Pictures or Screenshots folder to search"
        } else {
            _note = ""
        }
    }

    Timer {
        id: debounce
        interval: 120
        repeat: false
        onTriggered: root.startSearch()
    }

    Timer {
        id: yuriWatchdog
        interval: 3000
        repeat: false
        onTriggered: {
            if (yuriProc.running)
                yuriProc.running = false
            root.finishYuri(yuriOut.text)
        }
    }

    Timer {
        id: nameBudget
        interval: 200
        repeat: false
        onTriggered: {
            if (nameProc.running)
                nameProc.running = false
            root.finishName(nameOut.text)
        }
    }

    Process {
        id: yuriProc
        property int runSeq: 0
        running: false
        stdout: StdioCollector {
            id: yuriOut
            waitForEnd: true
            onStreamFinished: root.finishYuri(text)
        }
    }

    Process {
        id: nameProc
        property int runSeq: 0
        running: false
        stdout: StdioCollector {
            id: nameOut
            waitForEnd: true
            onStreamFinished: root.finishName(text)
        }
    }
}
