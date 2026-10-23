import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

// quick-e2e.qml - DeckMain-level proof of the five quick actions (worker e2e).
// Run under a private bus so the visualizer cannot reach a real player:
//   dbus-run-session -- tools/linux/deckmain-shell.sh --scenario quick-e2e --stub-log FILE
// Each action is pressed through its MouseArea (clicked signal, the same signal the
// deck wires to DeckMain.runQuickAction). Process actions must show their argv in the stub log.
Item {
    id: scen

    property var hud: null
    property var log: null

    FileView {
        id: stubLog
        path: Quickshell.env("DECKMAIN_STUB_LOG") || ""
        watchChanges: false
        printErrors: false
    }

    property int idx: 0
    property int ticks: 0
    property int fails: 0
    property bool finished: false
    property var root0: null

    property var steps: [s_boot, s_apps, s_scan, s_text, s_power, s_visualizer, s_unknown, s_table]

    function check(name, ok, detail) {
        if (!ok)
            fails += 1
        log((ok ? "PASS " : "FAIL ") + name + " " + detail)
        return ok
    }

    function root() {
        var w = hud.testPanel
        return (w.contentItem !== undefined && w.contentItem !== null) ? w.contentItem : w
    }

    function walk(obj, pred, depth) {
        if (obj === null || obj === undefined || depth > 40)
            return null
        if (pred(obj))
            return obj
        var kids = obj.children
        if (kids !== undefined && kids !== null) {
            for (var i = 0; i < kids.length; ++i) {
                var hit = walk(kids[i], pred, depth + 1)
                if (hit !== null)
                    return hit
            }
        }
        return null
    }

    function target(id) {
        return walk(root(), function (o) { return o.objectName === "quick-" + id }, 0)
    }

    function stubLines(prefix) {
        stubLog.reload()
        var rows = String(stubLog.text()).split("\n")
        var out = []
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].indexOf(prefix) === 0)
                out.push(rows[i])
        return out
    }

    function press(id) {
        var t = target(id)
        if (t === null)
            return false
        t.clicked(null)
        return true
    }

    function s_boot() {
        if (ticks < 15)
            return false
        root0 = walk(root(), function (o) { return o.objectName === "quick-visualizer" }, 0)
        check("boot: five quick targets present",
              target("visualizer") !== null && target("apps") !== null && target("screen-scan") !== null
              && target("text-scan") !== null && target("power") !== null, "")
        return true
    }

    function s_apps() {
        if (ticks === 0)
            press("apps")
        if (ticks < 2)
            return false
        check("apps: focus launcher", hud.focusId === "launcher", "focusId=[" + hud.focusId + "]")
        hud.focusId = ""
        return true
    }

    function s_scan() {
        if (ticks === 0)
            press("screen-scan")
        if (ticks < 4)
            return false
        var rows = stubLines("omarchy-capture-screenshot")
        check("screen-scan: argv in stub log", rows.length === 1 && rows[0] === "omarchy-capture-screenshot",
              "lines=" + rows.length)
        return true
    }

    function s_text() {
        if (ticks === 0)
            press("text-scan")
        if (ticks < 4)
            return false
        var rows = stubLines("omarchy-capture-text")
        check("text-scan: argv in stub log", rows.length === 1 && rows[0] === "omarchy-capture-text",
              "lines=" + rows.length)
        return true
    }

    function s_power() {
        if (ticks === 0)
            press("power")
        if (ticks < 4)
            return false
        var rows = stubLines("omarchy-menu")
        check("power: argv in stub log", rows.length === 1 && rows[0] === "omarchy-menu\tsystem",
              "lines=" + rows.length + " last=[" + (rows.length ? rows[rows.length - 1] : "") + "]")
        return true
    }

    function s_visualizer() {
        if (ticks === 0)
            press("visualizer")
        if (ticks < 3)
            return false
        var r = hud.runQuickAction("visualizer")
        check("visualizer: no player means no playback call", r === "no player" && hud.mediaAvailable === false,
              "return=[" + r + "] mediaAvailable=" + hud.mediaAvailable)
        check("visualizer: no playerctl call", stubLines("playerctl").length === 0,
              "playerctl lines=" + stubLines("playerctl").length)
        return true
    }

    function s_unknown() {
        var before = stubLines("omarchy-").length
        var r = hud.runQuickAction("bogus-id")
        check("unknown id runs nothing", r === "unknown quick action bogus-id" && stubLines("omarchy-").length === before,
              "return=[" + r + "]")
        return true
    }

    function s_table() {
        var rows = stubLines("omarchy-")
        var want = ["omarchy-capture-screenshot", "omarchy-capture-text", "omarchy-menu\tsystem"]
        var ok = rows.length === want.length
        for (var i = 0; ok && i < want.length; ++i)
            ok = rows[i] === want[i]
        check("stub log holds exactly the three process argv lines", ok,
              "omarchy lines=" + rows.length + " [" + rows.join(" | ") + "]")
        return true
    }

    function finish() {
        if (finished)
            return
        finished = true
        tick.running = false
        log((fails === 0 ? "RESULT pass" : "RESULT fail") + " quick-e2e fails=" + fails)
        Qt.quit()
    }

    function runStep() {
        if (finished)
            return
        // FileView.reload() is asynchronous: refresh every tick so stubLines sees new rows.
        stubLog.reload()
        if (idx >= steps.length) {
            finish()
            return
        }
        var done = steps[idx]()
        ticks += 1
        if (done) {
            idx += 1
            ticks = 0
        }
    }

    Timer {
        id: tick
        interval: 100
        running: true
        repeat: true
        onTriggered: scen.runStep()
    }
}
