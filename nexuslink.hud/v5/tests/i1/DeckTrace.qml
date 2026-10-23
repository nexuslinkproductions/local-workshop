import QtQuick
import "../../kit"
import "../../stills"
import "../.." as Deck

// I1 motion trace: the three numbers motion.md has to carry, sampled on the
// composed deck rather than on a component in isolation.
//
//   QT_QPA_PLATFORM=offscreen qml -I <imports> nexuslink.hud/v5/tests/i1/DeckTrace.qml
//   TRACE {"expand":[...],"drift":[...],"breath":[...]}
//
// Timeline (ms from start):
//     0 - 1200   rest: drift and breath are sampled
//  1200           focusId = "crew"  -> CrewOrb expands on the Motion spring
//  3200           focusId = ""      -> the slower return, no overshoot
//  7000 - 13000   breath keeps running so two cycles can be timed
//
// Every sample carries its own Date.now() stamp, so the parser measures real
// wall-clock time and not the nominal timer interval.
Item {
    id: probe

    // The deck lays out at 2560x1440 in its own coordinates; the probe renders it
    // at a quarter scale so the offscreen software rasteriser does not starve the
    // 8 ms sampler. Geometry and the sampled properties are unaffected.
    width: 640
    height: 360

    property var expand: []
    property var drift: []
    property var breath: []
    property double t0: 0
    property bool expanded: false
    property bool returned: false
    property int done: 0

    DeckFixtures { id: fx }

    Deck.DeckSurface {
        id: deck

        width: 2560
        height: 1440
        scale: 0.25
        transformOrigin: Item.TopLeft
        animate: true
        benchPhase: -1
        // Not painted: the trace measures properties, and an unpainted deck lets
        // the offscreen frame loop run fast enough for the 8 ms sampler to catch
        // the expand peak instead of stepping over it. Qt's animation driver
        // still ticks every frame for an invisible item.
        visible: false

        clockText: fx.clockText
        dayText: fx.dayText
        dateText: fx.dateText
        sessions: fx.sessions
        apps: fx.apps
        allApps: fx.allApps
        hero: fx.hero
        findResults: fx.findResults
        rttMs: fx.rttMs
        batteryLevel: fx.batteryLevel
        loadLevel: fx.loadLevel
        modelGb: fx.modelGb
        modelActivity: fx.modelActivity
        disks: fx.disks
    }

    // The breath under both the knot and the crew shell: one shader per swarm,
    // driven by Motion.breathPeriod. Sampling it here measures the number the
    // deck actually renders with. It has to be `visible` for SwarmSphere's own
    // 33 ms tick to run (running: visible && animate), so it is parked off the
    // probe's visible area instead of hidden.
    SwarmSphere {
        id: shell
        x: -1000
        y: -1000
        size: 224
        visible: true
        animate: true
    }

    Timer {
        interval: 8
        repeat: true
        running: true

        onTriggered: probe.sample()
    }

    function now() {
        return Date.now()
    }

    function sample() {
        if (probe.t0 === 0) {
            probe.t0 = now()
            return
        }
        var t = now() - probe.t0

        if (t < 5600) {
            probe.expand.push({ "t": t, "g": deck.crewGrowth })
            probe.drift.push({ "t": t, "dx": deck.idleDriftX, "dy": deck.idleDriftY })
        }

        // Breath runs for the whole capture; it is the same 5.8 s cycle the
        // shader uses, so 13 s carries two full periods.
        if (t < 13200)
            probe.breath.push({ "t": t, "b": shell.breath })

        if (!probe.expanded && t >= 1200) {
            probe.expanded = true
            deck.focusId = "crew"
        }
        if (!probe.returned && t >= 3200) {
            probe.returned = true
            deck.focusId = ""
        }
        if (t >= 13200) {
            probe.dump()
            Qt.exit(0)
        }
    }

    function dump() {
        console.log("TRACE " + JSON.stringify({
            "label": "deck",
            "breathPeriodToken": Motion.breathPeriod,
            "expandMillisToken": Motion.expandMillis,
            "returnMillisToken": Motion.returnMillis,
            "expand": probe.expand,
            "drift": probe.drift,
            "breath": probe.breath
        }))
    }
}
