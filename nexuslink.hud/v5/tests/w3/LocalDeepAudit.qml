import QtQuick
import "../../kit"
import "../../stills" as Stills
import "../.." as Deck

// W3 still audit: does the deck actually compose the `local` deep view, and is
// LocalOrb in it, visible, at the documented place?
//
//   QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH=<imports> qml -I <imports> \
//       nexuslink.hud/v5/tests/w3/LocalDeepAudit.qml
//   AUDIT {...}
//
// The still (v5/stills/w3-local-deep.qml) proves the view draws; this walks the
// live item tree and prints the numbers a reviewer would otherwise have to read
// off pixels: focusId, whether the orb is visible, its size, its box in deck
// coordinates, and the scale it is drawn at (1.0000 at rest, the fixtures'
// modelActivity is 0).
Item {
    id: probe

    width: 2560
    height: 1440

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
        modelActivity: fx.modelActivity
        disks: fx.disks
    }

    Timer {
        interval: 250
        running: true
        repeat: false
        onTriggered: probe.audit()
    }

    function descendants(item, out) {
        for (var i = 0; i < item.children.length; ++i) {
            out.push(item.children[i])
            descendants(item.children[i], out)
        }
        return out
    }

    function audit() {
        var items = descendants(deck, [])
        var orb = null
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            // LocalOrb is the only item that exposes both of these.
            if (it && typeof it.fieldScale === "number" && typeof it.sizeGb === "number") {
                orb = it
                break
            }
        }
        if (orb === null) {
            console.log("AUDIT " + JSON.stringify({ "error": "no LocalOrb in the tree" }))
            Qt.exit(1)
            return
        }
        var p = orb.mapToItem(deck, 0, 0)
        console.log("AUDIT " + JSON.stringify({
            "focusId": deck.focusId,
            "focusActive": deck.focusActive,
            "focusRect": [Math.round(deck.focusRect.x), Math.round(deck.focusRect.y),
                          Math.round(deck.focusRect.width), Math.round(deck.focusRect.height)],
            "orbFound": true,
            "orbVisible": orb.visible,
            "orbSizePx": orb.size,
            "orbBox": [Math.round(p.x), Math.round(p.y),
                       Math.round(orb.width), Math.round(orb.height)],
            "orbFieldScale": orb.fieldScale,
            "orbTargetScale": orb.targetScale,
            "orbDotCount": orb.dotCount,
            "modelGb": deck.modelGb,
            "modelActivity": deck.modelActivity,
            "expandOvershoot": orb.expandOvershoot,
            "expandMillis": Motion.expandMillis,
            "returnMillis": Motion.returnMillis
        }))
        Qt.exit(0)
    }
}
