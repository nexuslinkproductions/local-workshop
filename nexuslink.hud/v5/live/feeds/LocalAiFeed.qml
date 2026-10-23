import QtQuick
import Quickshell
import Quickshell.Io

// Local AI feed: FileView watch on chief's metrics.json (poller writes on change).
// No timer. File absent means no model loaded (present false, idle).
Item {
    id: root
    property bool active: false
    readonly property var localAi: _localAi
    property var _localAi: ({
        "present": false, "active": false, "model": "",
        "sizeGb": 0, "vramGb": 0, "tokS": 0, "activity": 0
    })
    visible: false
    width: 0
    height: 0

    function empty() {
        return { "present": false, "active": false, "model": "", "sizeGb": 0,
                 "vramGb": 0, "tokS": 0, "activity": 0 }
    }

    function load(raw) {
        if (!raw || String(raw).trim().length === 0) {
            root._localAi = root.empty()
            return
        }
        var o = null
        try { o = JSON.parse(raw) } catch (e) { o = null }
        if (!o || typeof o !== "object") {
            root._localAi = root.empty()
            return
        }
        var model = o.model ? String(o.model) : ""
        var vramMiB = Number(o.vram_used_mib)
        if (!isFinite(vramMiB) || vramMiB < 0) vramMiB = 0
        var toks = Number(o.tokens_per_s)
        if (!isFinite(toks) || toks < 0) toks = 0
        var queue = Number(o.queue)
        if (!isFinite(queue) || queue < 0) queue = 0
        var activity = queue > 0 ? 1 : Math.min(1, toks / 40)
        root._localAi = {
            "present": true,
            "active": model.length > 0,
            "model": model,
            "sizeGb": Math.round(vramMiB / 102.4) / 10,
            "vramGb": Math.round(vramMiB / 102.4) / 10,
            "tokS": Math.round(toks * 10) / 10,
            "activity": Math.round(activity * 100) / 100
        }
    }

    FileView {
        id: metrics
        path: "/run/user/1000/chief/metrics.json"
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onFileChanged: metrics.reload()
        onLoaded: root.load(metrics.text())
        onLoadFailed: root._localAi = root.empty()
    }
}
