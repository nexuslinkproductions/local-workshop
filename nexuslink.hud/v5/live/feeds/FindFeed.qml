import QtQuick
import Quickshell
import Quickshell.Io

// Find feed. Two bounded data sources:
//  1) yuri, the text CONTENT index: `timeout 3 yuri search <q> -n 8 --json`,
//     after a 120 ms typing pause, one process per query, the older one killed.
//     The `timeout 3` wrapper bounds a hung yuri, so no watchdog Timer is needed:
//     the process exit ends the stream and the stdout collector reports it.
//     When `yuri search --help` lists --kind / --recent (stage 03) those flags are
//     used for the Images, Docs and Downloads chips and the fallback below is skipped.
//  2) FALLBACK, remove after yuri stage 03 lands: a FILENAME-ONLY search with find
//     over ~/Downloads, ~/Pictures, ~/Videos (depth 3, 200 results max, newest first,
//     200 ms budget), spawned only for the All (media), Images and Downloads chips.
//     Those hits carry source: "name".
// Sequence numbers drop stale output from both sources.
Item {
    id: root

    // Set by DeckV5 while the deck (and the Find overlay) is shown. The feed
    // does nothing while this is false; a query typed before activation is
    // searched as soon as active becomes true.
    property bool active: false
    property string query: ""
    property string filter: "all"

    // FALLBACK roots (filename-only search, see header). Missing roots are
    // skipped by the helper script; Screenshots lives under Pictures, depth 2.
    // Tests point this at a scratch folder.
    property var nameRoots: [
        Quickshell.env("HOME") + "/Downloads",
        Quickshell.env("HOME") + "/Pictures",
        Quickshell.env("HOME") + "/Videos"
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

    // kind is one of md, code, doc, pdf, image, video, file.
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
        if (["mp4", "mkv", "webm", "mov", "avi", "m4v", "mpg", "mpeg", "wmv"].indexOf(ext) >= 0)
            return "video"
        return "file"
    }

    // yuri stage 03 fields win over the extension: mime first, then its own kind.
    function normKind(r, p) {
        var m = String(r.mime || "")
        if (m.indexOf("image/") === 0)
            return "image"
        if (m.indexOf("video/") === 0)
            return "video"
        var k = String(r.kind || "")
        if (["md", "code", "doc", "pdf", "image", "video"].indexOf(k) >= 0)
            return k
        return kindOf(p)
    }

    // ---- yuri capabilities (probed once, lazily, by the first search) ------
    // false until `yuri search --help` lists the flag; then the stage 03 path runs.
    property bool _capsKnown: false
    property bool _capsWaiting: false
    property bool _hasKind: false
    property bool _hasRecent: false
    property bool _yuriTimedOut: false
    property bool _nameTimedOut: false
    // CLI kind values per chip. A contract guess until stage 03 ships; fix here only.
    readonly property var kindArg: ({ "images": "image", "docs": "doc", "downloads": "download" })

    function capsDone(text) {
        var t = String(text)
        _hasKind = t.indexOf("--kind") >= 0
        _hasRecent = t.indexOf("--recent") >= 0
        _capsKnown = true
        if (_capsWaiting) {
            _capsWaiting = false
            startSearch()
        }
    }

    function cancel() {
        _seq++
        debounce.stop()
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
        _capsWaiting = false
        _yuriTimedOut = false
        _nameTimedOut = false
    }

    function yuriCommand(q, f) {
        var a = ["timeout", "3", "yuri", "search", q, "-n", f === "docs" ? "16" : "8", "--json"]
        if (_hasKind && kindArg[f] !== undefined)
            a.push("--kind", kindArg[f])
        if (_hasRecent && f === "downloads")
            a.push("--recent")
        return a
    }

    function startSearch() {
        cancel()
        var q = String(query).trim()
        if (!active || q.length === 0)
            return
        if (!_capsKnown) {
            _capsWaiting = true
            _busy = true
            capsProc.running = true
            return
        }
        var f = String(filter)
        var kindNative = _hasKind && kindArg[f] !== undefined
        // yuri covers all, files and docs (and images/downloads once it has --kind).
        _wantYuri = (kindNative || (f !== "images" && f !== "downloads"))
        // FALLBACK (remove after stage 03): filename-only media/downloads search.
        _wantName = !_hasKind && (f === "images" || f === "downloads" || f === "all")
        var roots = rootsFor(f)
        if (_wantName && roots.length === 0) {
            _wantName = false
            _nameNoRoots = true
        }
        var s = _seq
        if (_wantYuri) {
            _yuriDone = false
            yuriProc.runSeq = s
            yuriProc.command = yuriCommand(q, f)
            _spawnCount++
            yuriProc.running = true
        }
        if (_wantName) {
            _nameDone = false
            nameProc.runSeq = s
            nameProc.command = nameCommand(q, f === "images" ? imageExts : (f === "all" ? mediaExts : ""), roots)
            nameProc.running = true
            nameBudget.restart()
        }
        _busy = !(_yuriDone && _nameDone)
        if (!_busy)
            recompute()
    }

    // Downloads looks in Downloads and Videos; the other chips in every root.
    function rootsFor(f) {
        var out = []
        for (var i = 0; i < nameRoots.length; i++) {
            var r = String(nameRoots[i])
            if (f === "downloads" && /\/Pictures$/.test(r))
                continue
            out.push(r)
        }
        return out
    }

    readonly property string imageExts: "png|jpe?g|webp|gif|svg|avif|bmp|heic"
    readonly property string mediaExts: imageExts + "|mp4|mkv|webm|mov|avi|m4v"

    // FALLBACK, remove after yuri stage 03 (see header). sh -c script for the
    // filename-only search. $1 query, $2 extension regex (empty = any file), rest
    // roots. Depth 3, newest first, 200 results max, absolute paths. Prints
    // "mtime TAB size TAB path" per hit, or NOROOTS when no root exists.
    readonly property string nameScript: "q=$(printf '%s' \"$1\" | tr -d '*?[]\\\\')\n" +
        "ext=$2\n" +
        "shift 2\n" +
        "found=0\n" +
        "for r in \"$@\"; do\n" +
        "  if [ -d \"$r\" ]; then found=1; fi\n" +
        "done\n" +
        "if [ \"$found\" -eq 0 ]; then echo NOROOTS; exit 0; fi\n" +
        "for r in \"$@\"; do\n" +
        "  [ -d \"$r\" ] && find \"$r\" -maxdepth 3 -type f -iname \"*$q*\" -printf '%T@\\t%s\\t%p\\n' 2>/dev/null\n" +
        "done | sort -rn | head -n 200 | {\n" +
        "  if [ -n \"$ext\" ]; then grep -iE \"[.]($ext)\\$\"; else cat; fi\n" +
        "}\n"

    function nameCommand(q, ext, roots) {
        var args = ["sh", "-c", nameScript, "findfeed", q, ext]
        for (var i = 0; i < roots.length; i++)
            args.push(String(roots[i]))
        return args
    }

    function parseYuri(raw) {
        var out = []
        var arr = null
        try { arr = JSON.parse(String(raw)) } catch (e) { arr = null }
        if (!Array.isArray(arr))
            return out
        var f = String(filter)
        for (var i = 0; i < arr.length && out.length < 8; i++) {
            var r = arr[i]
            if (!r || !r.path)
                continue
            var p = String(r.path)
            var h = {
                "title": r.title ? String(r.title) : baseName(p),
                "path": p,
                "kind": normKind(r, p),
                "score": Number(r.score) || 0,
                "source": "yuri"
            }
            // stage 03 fields, passed through when present
            var extra = ["mime", "size", "mtime", "dims", "duration"]
            for (var j = 0; j < extra.length; j++)
                if (r[extra[j]] !== undefined && r[extra[j]] !== null)
                    h[extra[j]] = r[extra[j]]
            // Docs chip without server side --kind: keep documents only
            if (f === "docs" && !_hasKind && ["md", "doc", "pdf"].indexOf(h.kind) < 0)
                continue
            out.push(h)
        }
        return out
    }

    function parseName(raw) {
        var out = []
        var noRoots = false
        var lines = String(raw).split("\n")
        for (var i = 0; i < lines.length && out.length < 8; i++) {
            var line = lines[i]
            if (line.trim() === "NOROOTS") {
                noRoots = true
                continue
            }
            var parts = line.split("\t")
            if (parts.length < 3 || parts[2].charAt(0) !== "/")
                continue
            var p = parts.slice(2).join("\t")
            out.push({
                "title": baseName(p),
                "path": p,
                "kind": kindOf(p),
                "score": 0,
                "source": "name",
                "mtime": Math.floor(Number(parts[0]) || 0),
                "size": Number(parts[1]) || 0
            })
        }
        _nameNoRoots = noRoots
        return out
    }

    function finishYuri(raw) {
        if (yuriProc.runSeq !== _seq || _yuriDone)
            return
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
            // All: yuri hits first, then name hits of kind image or video, max 8
            // total. Images: name hits are already image-only. Downloads: any file.
            var mediaOnly = (String(filter) === "all")
            for (i = 0; i < _nameHits.length && out.length < 8; i++) {
                if (mediaOnly && _nameHits[i].kind !== "image" && _nameHits[i].kind !== "video")
                    continue
                out.push(_nameHits[i])
            }
        }
        _results = out
        _busy = false
        _note = ""
        if (out.length === 0) {
            if (_yuriTimedOut || _nameTimedOut)
                _note = "Search timed out"
            else if (_nameNoRoots && String(filter) !== "all")
                _note = (String(filter) === "downloads")
                    ? "No Downloads or Videos folder to search"
                    : "No Pictures or Downloads folder to search"
        }
    }

    Timer {
        id: debounce
        interval: 120
        repeat: false
        onTriggered: root.startSearch()
    }

    // The only search budget Timer: bounds the FALLBACK name search. One shot,
    // armed per name spawn, stopped on finish and on cancel.
    Timer {
        id: nameBudget
        interval: 200
        repeat: false
        onTriggered: {
            if (nameProc.running)
                nameProc.running = false
            root._nameTimedOut = (nameOut.text.trim().length === 0)
            root.finishName(nameOut.text)
        }
    }

    // Capability probe, once per feed life.
    Process {
        id: capsProc
        command: ["timeout", "2", "yuri", "search", "--help"]
        running: false
        stdout: StdioCollector {
            id: capsOut
            waitForEnd: true
            onStreamFinished: root.capsDone(text)
        }
    }

    Process {
        id: yuriProc
        property int runSeq: 0
        running: false
        onExited: (code, status) => {
            if (code === 124 && runSeq === root._seq) {
                root._yuriTimedOut = true
                if (root._yuriDone && root._yuriHits.length === 0)
                    root.recompute()
            }
        }
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
