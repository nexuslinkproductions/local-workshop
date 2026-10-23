import QtQuick
import Quickshell
import QtTest
import NexusHud.V5 1.0

// usage-e2e.qml - the Claude 5 h readout in the private DeckMain shell (UG).
// Fixtures: UG_USAGE_FIXTURES (a scratch dir made by ug_fixtures.py). The reader
// is feeds/usage.py with --gauge-dir, or a frozen snapshot read with cat.
// Phases:
//   fresh   usage.py on the fixture fresh gauge. Expect "Claude 5h 37%  resets HH:MM", opacity 1.
//   frozen  a snapshot with state fresh and source_as_of 50 min old. Expect
//           "Claude 5h --  STALE 50m", opacity 0.45, and no 37 on screen.
//   error   usage.py on the fixture error gauge. Expect "ERROR usage endpoint rate limited", no digits.
// Run: python3 tools/linux/deckmain-shell/stubs/usage_fixtures.py <dir> (the fresh fixture is
//      stamped at generation time and goes stale after 300 s, so regenerate it before every run), then
//      UG_USAGE_FIXTURES=<dir> tools/linux/deckmain-shell.sh --scenario usage-e2e --seconds 40
Item {
    id: root

    property var hud: null
    property var log: null

    readonly property string fx: String(Quickshell.env("UG_USAGE_FIXTURES") || "")
    readonly property string readerPath: decodeURIComponent(
        String(Qt.resolvedUrl("../../../../nexuslink.hud/v5/feeds/usage.py")).replace(/^file:\/\//, ""))

    property int phase: 0
    property real phaseSince: 0
    property var checks: []
    property bool finished: false

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

    function probe() {
        return hud.deckView.readoutProbe.usage
    }

    function setCmd(cmd) {
        var cmds = JSON.parse(JSON.stringify(hud.feedCmd))
        cmds.usage = cmd
        hud.feedCmd = cmds
        hud.armFeed("usage", hud.procFor("usage"))
    }

    Component.onCompleted: {
        log("usage-e2e start fx=" + fx)
        setCmd(["python3", readerPath, "--gauge-dir", fx + "/fresh", "--json"])
        phaseSince = Date.now()
    }

    Timer {
        interval: 250
        running: !root.finished
        repeat: true
        onTriggered: {
            var now = Date.now()
            var elapsed = (now - root.phaseSince) / 1000
            var p = root.probe()
            var st = hud.feedState.usage
            var stj = st === undefined ? "none" : st.state + " ageSec=" + st.ageSec + " reason=" + st.reason
            if (root.phase === 0) {
                if (!hud.procFor("usage").running && p.text.indexOf("Claude 5h 37%  resets ") !== 0)
                    hud.armFeed("usage", hud.procFor("usage"))
                if (p.text.indexOf("Claude 5h 37%  resets ") === 0) {
                    root.note("usage_fresh", p.opacity === 1 && p.label === "",
                              "text=[" + p.text + "] opacity=" + p.opacity + " state=" + stj)
                    root.phase = 1
                    root.phaseSince = now
                    root.setCmd(["cat", root.fx + "/frozen.json"])
                } else if (elapsed > 15) {
                    root.note("usage_fresh", false, "text=[" + p.text + "] state=" + stj)
                    root.finish()
                }
            } else if (root.phase === 1) {
                if (p.text.indexOf("Claude 5h --  STALE ") === 0) {
                    root.note("usage_frozen_stale", p.opacity === 0.45 && p.label.indexOf("STALE ") === 0
                              && p.text.indexOf("37") < 0,
                              "text=[" + p.text + "] opacity=" + p.opacity + " label=[" + p.label + "] state=" + stj)
                    root.phase = 2
                    root.phaseSince = now
                    root.setCmd(["python3", root.readerPath, "--gauge-dir", root.fx + "/error", "--json"])
                } else if (elapsed > 12) {
                    root.note("usage_frozen_stale", false, "text=[" + p.text + "] state=" + stj)
                    root.finish()
                }
            } else if (root.phase === 2) {
                if (p.text.indexOf("ERROR ") === 0) {
                    root.note("usage_error", p.text === "ERROR usage endpoint rate limited" && !(/[0-9]/.test(p.text))
                              && p.label === "",
                              "text=[" + p.text + "] opacity=" + p.opacity + " state=" + stj)
                    root.finish()
                } else if (elapsed > 12) {
                    root.note("usage_error", false, "text=[" + p.text + "] state=" + stj)
                    root.finish()
                }
            }
        }
    }
}
