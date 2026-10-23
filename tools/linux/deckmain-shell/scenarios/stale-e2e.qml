import QtQuick
import Quickshell
import QtTest
import NexusHud.V5 1.0

// stale-e2e.qml - the feed freshness layer in the private DeckMain shell (s2).
// link: a stub that answers on calls 1 and 3 (ttl 3 s), silent on call 2.
//   Expect live, then stale ("--", 0.45, STALE mark), then live again on call 3.
// metrics: a stub that hangs. Expect the watchdog to end it: state error, reason timeout.
// Run: tools/linux/deckmain-shell.sh --scenario stale-e2e --seconds 45
Item {
    id: root

    property var hud: null
    property var log: null

    // Stub readers live in nexuslink.hud/v5/tests/stale (worktree root, four levels up).
    readonly property string stubPath: decodeURIComponent(
        String(Qt.resolvedUrl("../../../../nexuslink.hud/v5/tests/stale/stale_reader.py")).replace(/^file:\/\//, ""))
    readonly property string countFile: String(Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/stale-link-count"

    property int phase: 0
    property real phaseSince: 0
    property bool metricsTimeoutSeen: false
    property var checks: []
    property bool finished: false

    TestEvent { id: ev }

    function note(name, ok, detail) {
        checks.push(name + "=" + (ok ? "PASS" : "FAIL"))
        log(name + " " + (ok ? "PASS" : "FAIL") + " " + detail)
    }

    function finish() {
        if (finished)
            return
        finished = true
        log("CHECKS " + checks.join(" "))
        Qt.quit()
    }

    function probe(id) {
        return hud.deckView.readoutProbe[id]
    }

    Component.onCompleted: {
        var specs = JSON.parse(JSON.stringify(hud.feedSpecs))
        specs.link.ttl = 3
        hud.feedSpecs = specs
        var cmds = JSON.parse(JSON.stringify(hud.feedCmd))
        cmds.link = [ "python3", stubPath, "once3", countFile ]
        cmds.metrics = [ "python3", stubPath, "hang" ]
        hud.feedCmd = cmds
        log("stale-e2e start stub=" + stubPath)
        hud.armFeed("link", hud.procFor("link"))
        hud.armFeed("metrics", hud.procFor("metrics"))
        phaseSince = Date.now()
    }

    Timer {
        interval: 250
        running: !root.finished
        repeat: true
        onTriggered: {
            var now = Date.now()
            var elapsed = (now - root.phaseSince) / 1000
            var m = hud.feedState.metrics
            if (m !== undefined && m.state === "error" && m.reason === "timeout" && !root.metricsTimeoutSeen) {
                root.metricsTimeoutSeen = true
                root.note("metrics_watchdog", true, "state=" + m.state + " reason=" + m.reason + " origin=" + m.origin)
            }
            var l = hud.feedState.link
            if (root.phase === 0) {
                if (l !== undefined && l.state === "live") {
                    root.note("link_live", true, "state=" + l.state + " ageSec=" + l.ageSec + " ttl=" + l.ttlSec)
                    root.phase = 1
                    root.phaseSince = now
                } else if (elapsed > 15) {
                    root.note("link_live", false, "state=" + (l ? l.state : "none"))
                    root.finish()
                }
            } else if (root.phase === 1) {
                if (l !== undefined && l.state === "stale") {
                    var p = root.probe("link")
                    root.note("link_stale_readout", p.text === "--" && p.opacity === 0.45 && p.label.indexOf("STALE ") === 0,
                              "text=" + p.text + " opacity=" + p.opacity + " label=" + p.label)
                    root.phase = 2
                    root.phaseSince = now
                } else if (elapsed > 12) {
                    root.note("link_stale", false, "state=" + (l ? l.state : "none") + " ageSec=" + (l ? l.ageSec : -1))
                    root.finish()
                }
            } else if (root.phase === 2) {
                if (l !== undefined && l.state === "live") {
                    var q = root.probe("link")
                    root.note("link_fresh_again", q.text !== "--" && q.opacity === 1 && q.label === "",
                              "text=" + q.text + " opacity=" + q.opacity + " label=[" + q.label + "]")
                    root.phase = 3
                    root.phaseSince = now
                } else if (elapsed > 30) {
                    root.note("link_fresh_again", false, "state=" + (l ? l.state : "none"))
                    root.finish()
                }
            } else if (root.phase === 3) {
                if (root.metricsTimeoutSeen || elapsed > 20) {
                    root.note("metrics_watchdog_seen", root.metricsTimeoutSeen, "metrics=" + JSON.stringify(hud.feedState.metrics))
                    root.finish()
                }
            }
        }
    }
}
