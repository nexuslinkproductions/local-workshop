import QtQuick
import "../../kit"

// I1 expand trace: the deck's expand and return, sampled where the grid is fine.
//
//   QT_QPA_PLATFORM=offscreen qml -I <imports> nexuslink.hud/v5/tests/i1/CrewExpandTrace.qml
//   TRACE {...}
//
// Why not on the deck itself: `DeckSurface`'s scene starves the sampler to a
// ~100 ms grid (binding churn during the state change), and the expand peak is
// one instant about 180 ms into a 347 ms curve, so a deck-level capture misses
// it often - measured raw peaks scattered from 1.2 to 4.9 percent on the same
// curve. This probe keeps the SAME component at the SAME size with the SAME
// Motion tokens the deck gives it, in a scene small enough for the tool's best
// grid (25 ms, measured: 40 ticks/s on an empty scene), so the peak is caught
// within a few ms. The deck-level capture is still run for the slow signals
// (drift, breath) where 100 ms is plenty.
Item {
    id: probe

    width: 400
    height: 400

    property double t0: 0
    property bool expanded: false
    property bool returned: false
    property var samples: []

    CrewOrb {
        id: orb

        // The deck's own numbers: size 224 (DeckSurface.crewSize), three
        // sessions from v5/fixtures/sessions.json, animate on.
        size: 224
        x: (probe.width - size) / 2
        y: 40
        sessions: [
            { "id": "a01748", "model": "sonnet-5-5", "idle_s": 32, "title": "Draft vari8-beta issues for the crew" },
            { "id": "a1d052", "model": "sonnet-5-5", "idle_s": 20, "title": "Enable operator-mode" },
            { "id": "683c2c", "parent": "a1d052", "model": "sonnet-5-5", "idle_s": 17,
              "title": "Composition study s1: widget-and-icon-first HUD" }
        ]
        animate: true
    }

    Timer {
        interval: 4
        repeat: true
        running: true

        onTriggered: probe.sample()
    }

    function sample() {
        var now = Date.now()
        if (probe.t0 === 0) {
            probe.t0 = now
            return
        }
        var t = now - probe.t0
        if (t > 2200) {
            probe.dump()
            Qt.exit(0)
            return
        }
        probe.samples.push({ "t": t, "g": orb.growth })

        if (!probe.expanded && t >= 200) {
            probe.expanded = true
            orb.expanded = true
        }
        if (!probe.returned && t >= 1000) {
            probe.returned = true
            orb.expanded = false
        }
    }

    function dump() {
        console.log("TRACE " + JSON.stringify({
            "label": "crew-expand",
            "expandMillisToken": Motion.expandMillis,
            "returnMillisToken": Motion.returnMillis,
            "expandOvershootToken": Motion.expandOvershoot,
            "expandScale": orb.expandScale,
            "returnAtMs": 1000,
            "samples": probe.samples
        }))
    }
}
