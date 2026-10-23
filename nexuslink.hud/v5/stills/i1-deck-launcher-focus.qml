import QtQuick
import "../kit"
import ".." as Deck

// I1 still: launcher focus - the second deeper view (all apps), 2560x1440.
//
//   nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/stills/i1-deck-launcher-focus.qml <out.png>
//
// `focusId: "launcher"` expands LauncherArc into its all-apps arc (Obsidian and
// Spotify join, the Arc Raiders hero stays at the right end) and dims the rest
// of the deck through kit/Focus.
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

        animate: false
        benchPhase: 0
        stillFocusProgress: 1
        focusId: "launcher"

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
