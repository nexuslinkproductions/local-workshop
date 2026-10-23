import QtQuick
import Quickshell
import Quickshell.Io

// Agents feed: running / blocked / waiting task counts from the Hermes Kanban
// board (SQLite). Read only: sqlite3 -readonly, one query per run, nothing is
// written. Polls every 30 s while active (never faster), skips a run while one
// is in flight, and is bounded by timeout(1).
//
// Source: the board database, default the vari8 board. The default board
// (~/.hermes/kanban.db) holds 0 tasks, so it is not used.
//
// Count mapping (Kanban status column values, hermes_cli/kanban_workflow.py):
//   running                              -> running
//   blocked                              -> blocked
//   todo, ready, scheduled, triage       -> waiting
//   done, review, archived               -> not counted
//
// Freshness (agents.status):
//   "fresh"  the newest task event is at most staleAfterS old
//   "stale"  the newest event is older than staleAfterS (ageS set), or the
//            board has no events at all (ageS -1)
//   "error"  the query failed, the file is missing, or the output did not
//            parse; counts are zero and must not be read as data
Item {
    id: root
    property bool active: false

    // Board database. Quickshell.env("HOME") keeps this per user.
    property string dbPath: (Quickshell.env("HOME") || "/home/nexuslink")
        + "/.hermes/kanban/boards/vari8/kanban.db"
    // Seconds since the newest task event before the board reads as stale.
    property int staleAfterS: 900
    readonly property string sql: "SELECT status, COUNT(*) FROM tasks GROUP BY status; "
        + "SELECT 'last_event', COALESCE(MAX(created_at), 0) FROM task_events;"

    readonly property var agents: _agents
    property var _agents: root.errorState("not read yet")

    visible: false
    width: 0
    height: 0

    function errorState(reason) {
        return {
            "status": "error", "reason": reason,
            "running": 0, "blocked": 0, "waiting": 0,
            "ageS": -1, "lastEventTs": 0, "checkedTs": Math.floor(Date.now() / 1000)
        }
    }

    // raw: sqlite3 list-mode output, "status|count" lines plus one
    // "last_event|<unix seconds>" line. Null when the output does not parse.
    function parse(raw) {
        var counts = { "running": 0, "blocked": 0, "waiting": 0 }
        var lastTs = null
        var lines = String(raw).split("\n")
        for (var i = 0; i < lines.length; i++) {
            var t = lines[i].trim()
            if (t.length === 0)
                continue
            var f = t.split("|")
            if (f.length !== 2)
                return null
            var n = Number(f[1])
            if (!isFinite(n) || n < 0)
                return null
            if (f[0] === "last_event") {
                lastTs = n
                continue
            }
            if (f[0] === "running")
                counts.running += n
            else if (f[0] === "blocked")
                counts.blocked += n
            else if (f[0] === "todo" || f[0] === "ready" || f[0] === "scheduled" || f[0] === "triage")
                counts.waiting += n
        }
        if (lastTs === null)
            return null
        return { "counts": counts, "lastTs": lastTs }
    }

    function finish(raw) {
        var p = root.parse(raw)
        if (!p) {
            root._agents = root.errorState("unreadable board output")
            return
        }
        var nowS = Math.floor(Date.now() / 1000)
        var age = p.lastTs > 0 ? Math.max(0, nowS - p.lastTs) : -1
        var fresh = p.lastTs > 0 && age <= root.staleAfterS
        root._agents = {
            "status": fresh ? "fresh" : "stale",
            "reason": "",
            "running": p.counts.running,
            "blocked": p.counts.blocked,
            "waiting": p.counts.waiting,
            "ageS": age,
            "lastEventTs": p.lastTs,
            "checkedTs": nowS
        }
    }

    Timer {
        interval: 30000
        repeat: true
        triggeredOnStart: true
        running: root.active
        onTriggered: if (!proc.running) proc.running = true   // skip overlapping runs
    }

    Process {
        id: proc
        command: ["timeout", "5", "sqlite3", "-readonly", "-cmd", ".timeout 3000",
                  root.dbPath, root.sql]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.finish(text)
        }
    }
}
