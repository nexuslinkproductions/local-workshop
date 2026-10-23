import QtQuick
import NexusHud.V5 1.0
import "../.." as Deck
import "../../stills" as Fx

// tests/media/scene-media-pill.qml - render B: the deck at rest plus a playing
// media pill. Same fixtures as stills/i1-deck-rest.qml, plus the media inputs.
//   tools/linux/deck-shot.sh nexuslink.hud/v5/tests/media/scene-media-pill.qml <out.png> 2560 1440
Item {
    id: root

    width: 2560
    height: 1440

    Fx.DeckFixtures { id: fx }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    Deck.DeckSurface {
        anchors.fill: parent

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

        mediaTitle: "Champagne Supernova"
        mediaPlaying: true
        mediaAvailable: true
    }
}
