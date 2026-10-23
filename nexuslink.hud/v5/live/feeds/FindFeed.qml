import QtQuick
import Quickshell
import Quickshell.Io

// Find feed: 120 ms typing pause, then `yuri search <q> -n 8 --json`.
// Stale runs are dropped by sequence number. filter "downloads" is honest about
// yuri not indexing Downloads yet (results empty plus note).
Item {
    id: root
    property bool active: false
    property string query: ""
    property string filter: "all"
    property string note: ""
    readonly property var results: _results
    readonly property bool busy: _busy
    property var _results: []
    property bool _busy: false
    property int _seq: 0
    visible: false
    width: 0
    height: 0

    onQueryChanged: {
        debounce.restart()
        root._seq++
        proc.running = false
        root._busy = false
        root.note = ""
        if (query.trim().length === 0 || filter === "downloads")
            root._results = []
    }
    onFilterChanged: {
        root._seq++
        proc.running = false
        root._busy = false
        if (filter === "downloads") {
            root._results = []
            root._busy = false
            root.note = "Downloads is not indexed yet"
            debounce.stop()
        } else {
            root.note = ""
            debounce.restart()
        }
    }

    function kindOf(path) {
        var p = String(path).toLowerCase()
        var dot = p.lastIndexOf(".")
        var ext = dot < 0 ? "" : p.substring(dot + 1)
        if (ext === "md") return "md"
        if (["rs","py","js","ts","qml","sh","toml","json","yaml","yml","c","h","cpp","go"].indexOf(ext) >= 0) return "code"
        if (["txt","odt","docx","doc","rtf"].indexOf(ext) >= 0) return "doc"
        if (ext === "pdf") return "pdf"
        if (["png","jpg","jpeg","webp","svg","gif","avif"].indexOf(ext) >= 0) return "image"
        return "file"
    }

    Timer {
        id: debounce
        interval: 120
        repeat: false
        onTriggered: {
            var q = root.query.trim()
            if (!root.active || q.length === 0 || root.filter === "downloads") {
                root._results = []
                root._busy = false
                return
            }
            root._seq++
            proc.runSeq = root._seq
            proc.running = false
            proc.running = true
            root._busy = true
        }
    }

    Process {
        id: proc
        property int runSeq: 0
        command: ["yuri", "search", root.query.trim(), "-n", "8", "--json"]
        running: false
        onRunningChanged: if (!running && root._busy && runSeq === root._seq) root._busy = false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (proc.runSeq !== root._seq)
                    return   // stale
                var arr = null
                try { arr = JSON.parse(text) } catch (e) { arr = null }
                var out = []
                if (Array.isArray(arr)) {
                    for (var i = 0; i < arr.length; i++) {
                        var r = arr[i]
                        if (!r || !r.path)
                            continue
                        out.push({
                            "title": r.title ? String(r.title) : String(r.path).split("/").pop(),
                            "path": String(r.path),
                            "kind": root.kindOf(r.path),
                            "score": Number(r.score) || 0
                        })
                    }
                }
                root._results = out
            }
        }
    }
}
