import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// find-e2e.qml - DeckMain-level proof of Find (worker e2e). Drive it with:
//   DECKMAIN_STUB_SLOW_QUERY=slowq DECKMAIN_STUB_SLOW_SECS=2 dbus-run-session -- \
//     tools/linux/deckmain-shell.sh --scenario find-e2e --seconds 60 --stub-log FILE
// Opens Find the way IPC does (hud.focusId = "find"), types "hud" with synthetic
// keys, walks the selection, presses Enter and Escape. Then a slow first query
// ("slowq") is superseded by "slowqx": the stale first result must never show.
Item {
    id: scen

    property var hud: null
    property var log: null

    TestEvent { id: ev }

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
    property var deck: null
    property var field: null
    property string expectedOpen: ""
    property int stalePolls: 0

    property var steps: [s_boot, s_open, s_type, s_results, s_down, s_right, s_left,
                         s_up, s_down2, s_enter, s_esc, s_reopen, s_clear, s_slow1,
                         s_slow2, s_stale, s_close]

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

    function isDeck(o) { return o.findSelected !== undefined && o.wantsKeyboard !== undefined }
    function isField(o) { return o.echoMode !== undefined && o.cursorPosition !== undefined }

    function stubLines(prefix) {
        stubLog.reload()
        var rows = String(stubLog.text()).split("\n")
        var out = []
        for (var i = 0; i < rows.length; ++i)
            if (rows[i].indexOf(prefix) === 0)
                out.push(rows[i])
        return out
    }

    function expandPath(p) {
        var s = String(p)
        return s.indexOf("~/") === 0 ? hud.homeDir + s.slice(1) : s
    }

    function probe() { return "probe=" + hud.keyboardFocusProbe + " focusId=[" + hud.focusId + "]" }

    function s_boot() {
        if (ticks < 15)
            return false
        deck = walk(root(), isDeck, 0)
        check("boot: DeckSurface found", deck !== null, "")
        check("rest: keyboard None", hud.keyboardFocusProbe === WlrKeyboardFocus.None, probe())
        return true
    }

    function s_open() {
        if (ticks === 0)
            hud.focusId = "find"
        if (ticks < 3)
            return false
        if (field === null)
            field = walk(root(), isField, 0)
        if (field === null && ticks < 20)
            return false
        check("open: text field found", field !== null, "")
        if (field !== null)
            field.forceActiveFocus()
        check("open: keyboard OnDemand", hud.keyboardFocusProbe === WlrKeyboardFocus.OnDemand, probe())
        check("open: field has activeFocus", field !== null && field.activeFocus === true, "")
        return true
    }

    function s_type() {
        if (ticks === 0) {
            ev.keyClick(Qt.Key_H, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_U, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_D, Qt.NoModifier, 0)
        }
        if (ticks < 3)
            return false
        check("type: field text is hud", field !== null && field.text === "hud",
              "text=[" + (field !== null ? field.text : "") + "]")
        return true
    }

    function s_results() {
        var n = hud.findResults.length
        if (ticks < 60 && !(hud.findBusy === false && n > 0))
            return false
        var calls = stubLines("yuri\tsearch\thud\t").length
        check("query: yuri called once for hud", calls === 1, "calls=" + calls + " findQuery=[" + hud.findQuery + "]")
        check("results: top hit plus tiles", n >= 1 && n <= 8,
              "count=" + n + " note=[" + hud.findNote + "] top=[" + (n > 0 ? hud.findResults[0].title : "") + "]")
        return true
    }

    function s_down() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_Down, Qt.NoModifier, 0)
        if (ticks < 2)
            return false
        check("nav: Down 0->1", deck.findSelected === 1, "sel=" + deck.findSelected)
        return true
    }

    function s_right() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_Right, Qt.NoModifier, 0)
        if (ticks < 2)
            return false
        check("nav: Right 1->2", deck.findSelected === 2, "sel=" + deck.findSelected)
        return true
    }

    function s_left() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_Left, Qt.NoModifier, 0)
        if (ticks < 2)
            return false
        check("nav: Left 2->1", deck.findSelected === 1, "sel=" + deck.findSelected)
        return true
    }

    function s_up() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_Up, Qt.NoModifier, 0)
        if (ticks < 2)
            return false
        check("nav: Up 1->0", deck.findSelected === 0, "sel=" + deck.findSelected)
        return true
    }

    function s_down2() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_Down, Qt.NoModifier, 0)
        if (ticks < 2)
            return false
        check("nav: Down 0->1 again", deck.findSelected === 1, "sel=" + deck.findSelected)
        return true
    }

    function s_enter() {
        if (ticks === 0) {
            var rows = hud.findResults
            var pick = rows.length > 1 ? rows[1] : (rows.length > 0 ? rows[0] : null)
            expectedOpen = pick !== null ? expandPath(pick.path) : ""
            ev.keyClick(Qt.Key_Return, Qt.NoModifier, 0)
        }
        if (ticks < 4)
            return false
        var xo = stubLines("xdg-open\t")
        var last = xo.length > 0 ? xo[xo.length - 1] : ""
        check("enter: xdg-open gets the selected path", last === "xdg-open\t" + expectedOpen && expectedOpen !== "",
              "expected=[" + expectedOpen + "] xdg-open lines=" + xo.length)
        return true
    }

    function s_esc() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_Escape, Qt.NoModifier, 0)
        if (ticks < 4)
            return false
        check("esc: focusId cleared", hud.focusId === "", probe())
        check("esc: keyboard None", hud.keyboardFocusProbe === WlrKeyboardFocus.None, probe())
        check("esc: wantsKeyboard false", deck.wantsKeyboard === false, "wantsKeyboard=" + deck.wantsKeyboard)
        return true
    }

    function s_reopen() {
        if (ticks === 0)
            hud.focusId = "find"
        if (ticks < 3)
            return false
        if (field === null)
            field = walk(root(), isField, 0)
        if (field === null)
            return ticks > 30
        field.forceActiveFocus()
        return true
    }

    function s_clear() {
        if (ticks === 0) {
            var n = field.text.length
            for (var i = 0; i < n + 1; ++i)
                ev.keyClick(Qt.Key_Backspace, Qt.NoModifier, 0)
        }
        if (ticks < 3)
            return false
        check("clear: field empty before slow test", field.text === "", "text=[" + field.text + "]")
        return true
    }

    function s_slow1() {
        if (ticks === 0) {
            ev.keyClick(Qt.Key_S, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_L, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_O, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_W, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_Q, Qt.NoModifier, 0)
        }
        if (ticks < 6)
            return false
        var a = stubLines("yuri\tsearch\tslowq\t").length
        check("slow1: first query slowq started (stub is slow)", a === 1, "calls=" + a + " text=[" + field.text + "]")
        return true
    }

    function s_slow2() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_X, Qt.NoModifier, 0)
        if (ticks < 1)
            return false
        return true
    }

    function s_stale() {
        var rows = hud.findResults
        for (var i = 0; i < rows.length; ++i)
            if (String(rows[i].title).indexOf("STALE") >= 0 || String(rows[i].path).indexOf("stale") >= 0)
                stalePolls += 1
        if (ticks < 40)
            return false
        check("stale: superseded result never shows", stalePolls === 0, "polls with a STALE row=" + stalePolls)
        check("slow2: findQuery is slowqx", hud.findQuery === "slowqx", "findQuery=[" + hud.findQuery + "]")
        var b = stubLines("yuri\tsearch\tslowqx\t").length
        check("slow2: second query ran once", b === 1, "calls=" + b)
        var s = hud.findResults.length
        check("slow2: results for slowqx shown", s >= 1 && hud.findBusy === false,
              "count=" + s + " busy=" + hud.findBusy + " top=[" + (s > 0 ? hud.findResults[0].title : "") + "]")
        return true
    }

    function s_close() {
        if (ticks === 0)
            ev.keyClick(Qt.Key_Escape, Qt.NoModifier, 0)
        if (ticks < 3)
            return false
        check("close: focusId cleared", hud.focusId === "", probe())
        check("close: keyboard None", hud.keyboardFocusProbe === WlrKeyboardFocus.None, probe())
        return true
    }

    function finish() {
        if (finished)
            return
        finished = true
        tick.running = false
        log((fails === 0 ? "RESULT pass" : "RESULT fail") + " find-e2e fails=" + fails)
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
