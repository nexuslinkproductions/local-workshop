import QtQuick
import "../../kit"
import "../../stills" as Stills
import "../.." as Deck

// W3 in-deck trace: the composed deck's `local` deep view, with modelActivity
// driven 0 -> 1, sampled at the deck scene's own (coarse) grid.
//
//   QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH=<imports> qml -I <imports> \
//       nexuslink.hud/v5/tests/w3/LocalDeepTrace.qml
//   DECKTRACE {...}
//
// ComponentTraces (tests/w3/LocalOrbTrace.qml) is the precision measurement; this
// one exists to show the deck itself, where a sampler only gets a ~100 ms grid,
// stays bounded and lands on the lifted scale. Ran once by hand for
// v5/docs/w3-localorb-spring.md; it is not part of tools/w3-localorb-trace.py.
Item {
    id: probe

    width: 2560
    height: 1440

    property double t0: 0
    property bool lifted: false
    property var samples: []

    Stills.DeckFixtures { id: fx }

    Deck.DeckSurface {
        id: deck

        anchors.fill: parent
        animate: false
        benchPhase: 0
        stillFocusProgress: 1
        focusRequest: "local"

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
        modelActivity: probe.lifted ? 1 : 0
        disks: fx.disks
    }

    Timer {
        interval: 4
        repeat: true
        running: true
        onTriggered: probe.sample()
    }

    function descendants(item, out) {
        for (var i = 0; i < item.children.length; ++i) {
            out.push(item.children[i])
            descendants(item.children[i], out)
        }
        return out
    }

    function orb() {
        var items = descendants(deck, [])
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (it && typeof it.fieldScale === "number" && typeof it.sizeGb === "number")
                return it
        }
        return null
    }

    function sample() {
        var now = Date.now()
        if (probe.t0 === 0) {
            probe.t0 = now
            return
        }
        var t = now - probe.t0
        var o = probe.orb()
        if (o === null) {
            console.log("DECKTRACE " + JSON.stringify({ "error": "no LocalOrb" }))
            Qt.exit(1)
            return
        }
        probe.samples.push({ "t": t, "v": o.fieldScale })
        if (!probe.lifted && t >= 400)
            probe.lifted = true
        if (t > 2400) {
            var vs = probe.samples.map(function (s) { return s.v })
            console.log("DECKTRACE " + JSON.stringify({
                "focusId": deck.focusId,
                "liftAtMs": 400,
                "sizePx": o.size,
                "samples": probe.samples,
                "min": Math.min.apply(null, vs),
                "max": Math.max.apply(null, vs),
                "last": vs[vs.length - 1]
            }))
            Qt.exit(0)
        }
    }
}
