import QtQuick
import Quickshell
import Quickshell.Io

// Today feed: the next timed calendar event that starts before the next local
// midnight, read from Google Calendar through the Hermes google-workspace skill
// (scripts/google_api.py calendar list). Read only: that call is a GET. Nothing
// here creates, edits or deletes calendar data.
//
// Source gate, one sh run with fixed arguments (no user input):
//   gws not on PATH and no Google token at $HERMES_HOME/google_token.json
//     -> prints __MISSING__, no network call is made
//   otherwise -> the list call, 25 s timeout, window now .. next local midnight
// Polls every 60 s while active (never faster), skips a run while one is in
// flight.
//
// "Next" = the first timed event whose start is at or after now. All-day
// events (date only, no T in start) are skipped.
//
// Freshness (today.status):
//   "fresh"  this run read the calendar. hasEvent says whether a timed event is
//            left today. ageS 0.
//   "stale"  this run failed, but the last good read is at most staleAfterS old.
//            ageS is that age in seconds. The last good event is kept.
//   "error"  this run failed and there is no good read within staleAfterS.
//            reason is "source missing" or "source error". No event, no number.
Item {
    id: root
    property bool active: false

    // Last good read may be this old (s) before a failed run reads as error.
    property int staleAfterS: 900
    property int pollS: 60

    readonly property string home: Quickshell.env("HOME") || "/home/nexuslink"
    readonly property string hermesHome: Quickshell.env("HERMES_HOME") || (root.home + "/.hermes")
    readonly property string listScript: root.home
        + "/.hermes/skills/productivity/google-workspace/scripts/google_api.py"

    // $0 probe, $1 hermesHome, $2 listScript. The window is now .. next local midnight.
    readonly property string probe:
        "if command -v gws >/dev/null 2>&1 || [ -f \"$1/google_token.json\" ]; then "
        + "timeout 25 python3 \"$2\" calendar list --start \"$(date -Is)\" "
        + "--end \"$(date -d \"$(date +%F) +1 day\" -Is)\" --max 25; "
        + "else echo __MISSING__; fi"

    readonly property var today: _today
    property var _today: root.errorState("not read yet")
    property int lastOkTs: 0

    visible: false
    width: 0
    height: 0

    function pad2(n) {
        return (n < 10 ? "0" : "") + n
    }

    function errorState(reason) {
        return {
            "status": "error", "reason": reason,
            "hasEvent": false, "time": "", "hour": -1, "title": "",
            "nowHour": root.localHour(new Date()), "ageS": -1
        }
    }

    function localHour(d) {
        return d.getHours() + d.getMinutes() / 60
    }

    // Failed run: stale while the last good read is recent, otherwise error.
    function failed(reason) {
        var nowS = Math.floor(Date.now() / 1000)
        var age = root.lastOkTs > 0 ? nowS - root.lastOkTs : -1
        if (age >= 0 && age <= root.staleAfterS) {
            root._today = Object.assign({}, root._today, {
                "status": "stale", "reason": "source error",
                "ageS": age, "nowHour": root.localHour(new Date())
            })
        } else {
            root._today = root.errorState(reason)
        }
    }

    // raw: stdout of the probe. JSON array from calendar list, or __MISSING__.
    function finish(raw) {
        var txt = String(raw).trim()
        if (txt === "__MISSING__") {
            root.failed("source missing")
            return
        }
        var events
        try {
            events = JSON.parse(txt)
        } catch (e) {
            root.failed("source error")
            return
        }
        if (!Array.isArray(events)) {
            root.failed("source error")
            return
        }
        var nowDate = new Date()
        var nowMs = nowDate.getTime()
        var best = null
        var bestMs = 0
        for (var i = 0; i < events.length; i++) {
            var e = events[i]
            if (!e || typeof e.start !== "string" || e.start.indexOf("T") < 0)
                continue
            var ms = Date.parse(e.start)
            if (!isFinite(ms) || ms < nowMs)
                continue
            if (best === null || ms < bestMs) {
                best = e
                bestMs = ms
            }
        }
        var nowS = Math.floor(nowMs / 1000)
        var when = best ? new Date(bestMs) : null
        root.lastOkTs = nowS
        root._today = {
            "status": "fresh", "reason": "",
            "hasEvent": best !== null,
            "time": when ? root.pad2(when.getHours()) + ":" + root.pad2(when.getMinutes()) : "",
            "hour": when ? root.localHour(when) : -1,
            "title": best ? String(best.summary || "(no title)") : "",
            "nowHour": root.localHour(nowDate),
            "ageS": 0
        }
    }

    Timer {
        interval: root.pollS * 1000
        repeat: true
        triggeredOnStart: true
        running: root.active
        onTriggered: if (!proc.running) proc.running = true   // skip overlapping runs
    }

    Process {
        id: proc
        command: ["sh", "-c", root.probe, "probe", root.hermesHome, root.listScript]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.finish(text)
        }
    }
}
