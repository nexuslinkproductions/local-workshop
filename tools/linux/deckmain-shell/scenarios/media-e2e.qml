import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

// media-e2e.qml - DeckMain-level proof of the media pill (worker e2e). Run it through
//   tools/linux/deckmain-shell/stubs/media-run.sh STUB-LOG   (inside dbus-run-session)
// The stub player (stubs/mpris_stub.py) owns org.mpris.MediaPlayer2.stub on the private bus.
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

    FileView {
        id: playerLog
        path: (Quickshell.env("DECKMAIN_STUB_LOG") || "") + ".player"
        watchChanges: false
        printErrors: false
    }

    Process {
        id: quitProc
        running: false
        command: ["gdbus", "call", "--session", "--dest", "org.mpris.MediaPlayer2.stub",
                  "--object-path", "/org/mpris/MediaPlayer2", "--method", "org.mpris.MediaPlayer2.Quit"]
    }

    property int idx: 0
    property int ticks: 0
    property int fails: 0
    property bool finished: false

    property var steps: [s_boot, s_pill, s_pause, s_play, s_quit, s_gone]

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

    function playerLines() {
        playerLog.reload()
        return String(playerLog.text()).split("\n")
    }

    function hasLine(lines, want) {
        for (var i = 0; i < lines.length; ++i)
            if (lines[i] === want)
                return true
        return false
    }

    function s_boot() {
        if (ticks < 25)
            return false
        check("player: available from Mpris service", hud.mediaAvailable === true, "available=" + hud.mediaAvailable)
        check("player: title", hud.mediaTitle === "Stub Song", "title=[" + hud.mediaTitle + "]")
        check("player: artist", hud.mediaArtist === "Stub Artist", "artist=[" + hud.mediaArtist + "]")
        check("player: playing at start", hud.mediaPlaying === true, "playing=" + hud.mediaPlaying)
        return true
    }

    function s_pill() {
        var t = walk(root(), function (o) { return typeof o.text === "string" && o.text.indexOf("Stub Song") >= 0 }, 0)
        check("pill: title text on screen", t !== null, "text=[" + (t !== null ? t.text : "") + "]")
        return true
    }

    function s_pause() {
        if (ticks === 0) {
            var r = hud.toggleMedia()
            check("toggle off: DeckMain returns toggled", r === "toggled Stub Song", "return=[" + r + "]")
        }
        if (ticks < 8)
            return false
        check("toggle off: mediaPlaying false", hud.mediaPlaying === false, "playing=" + hud.mediaPlaying)
        check("toggle off: player got PlayPause", hasLine(playerLines(), "CALL Pause") || hasLine(playerLines(), "CALL PlayPause"), "player log has the toggle call (MPRIS maps togglePlaying to Pause here)=" + (hasLine(playerLines(), "CALL Pause") || hasLine(playerLines(), "CALL PlayPause")))
        return true
    }

    function s_play() {
        if (ticks === 0) {
            var r = hud.toggleMedia()
            check("toggle on: DeckMain returns toggled", r === "toggled Stub Song", "return=[" + r + "]")
        }
        if (ticks < 8)
            return false
        check("toggle on: mediaPlaying true", hud.mediaPlaying === true, "playing=" + hud.mediaPlaying)
        var pl = playerLines()
        check("player log: two toggles and status changes", hasLine(pl, "STATUS Paused") && hasLine(pl, "STATUS Playing"),
              "player log=[" + pl.join(" | ") + "]")
        return true
    }

    function s_quit() {
        if (ticks === 0)
            quitProc.running = true
        if (ticks < 30)
            return false
        return true
    }

    function s_gone() {
        if (ticks < 5)
            return false
        check("no player: mediaAvailable false", hud.mediaAvailable === false, "available=" + hud.mediaAvailable)
        check("no player: title empty", hud.mediaTitle === "", "title=[" + hud.mediaTitle + "]")
        var r = hud.toggleMedia()
        check("no player: toggle returns no player", r === "no player", "return=[" + r + "]")
        return true
    }

    function finish() {
        if (finished)
            return
        finished = true
        tick.running = false
        log((fails === 0 ? "RESULT pass" : "RESULT fail") + " media-e2e fails=" + fails)
        Qt.quit()
    }

    function runStep() {
        if (finished)
            return
        stubLog.reload()
        playerLog.reload()
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
