import QtQuick
import "../kit"
import ".." as Deck

// I1 still: the DP-2 deck at rest, 2560x1440.
//
//   nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/stills/i1-deck-rest.qml <out.png>
//
// The surface is transparent by design - the Quickshell panel shows the desktop
// through it - so a still paints Tokens.field behind it. Values come from
// DeckFixtures.qml, which mirrors v5/fixtures.
Item {
    id: root

    width: 2560
    height: 1440

    DeckFixtures { id: fx }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    Deck.DeckSurface {
        anchors.fill: parent

        // A still is deterministic: no drift, no wander between frames.
        animate: false
        benchPhase: 0

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
