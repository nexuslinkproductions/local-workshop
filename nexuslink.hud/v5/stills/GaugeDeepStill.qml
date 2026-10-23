import QtQuick
import "../kit"
import ".." as Deck

// W3 gauge still: the composed deck at 2560x1440 with one deep view open.
//
//   nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/stills/w3-gauge-deep-mac.qml <out.png>
//
// The three thin entry files next to this one set `focusId`:
//   w3-gauge-deep-mac.qml       PulseRing (RTT ring) + DotArc (battery arc)
//   w3-gauge-deep-storage.qml   DotBar (one per disk) + DotArc (capacity)
//   w3-gauge-deep-launcher.qml  the launcher deep view
//
// `focusRequest` is the whole focus manager: kit/Focus dims and blurs everything
// outside focusRect, the widget's own expanded state follows, and the deep view
// overlay appears. stillFocusProgress pins the W7 effect at 1 so the still does
// not depend on a clock.
//
// The deck composes these gauges at focusLevel 0, so this still is the at-rest
// regression check: the four gauges' motion was repaired, their resting
// appearance must not move. The pixel comparison against the same render on the
// base commit is tools/w3-still-diff.py.
Item {
    id: root

    width: 2560
    height: 1440

    // "mac" | "storage" | "launcher"
    property string focusId: "mac"

    DeckFixtures { id: fx }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    Deck.DeckSurface {
        anchors.fill: parent

        animate: false
        benchPhase: 0
        stillFocusProgress: 1
        focusRequest: root.focusId

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
}
