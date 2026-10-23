import QtQuick
import "../../kit"
import "../../stills" as Stills
import "../.." as Deck

// Quick-actions render scene, deck at rest with the media side set to
// "available, paused", so the first glyph shows its paused state. Same fixtures
// and still settings as stills/i1-deck-rest.qml.
//   tools/linux/deck-shot.sh nexuslink.hud/v5/tests/quick/scene-rest.qml <out.png> 2560 1440
Item {
    id: root

    width: 2560
    height: 1440

    Stills.DeckFixtures { id: fx }

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
        mediaArtist: ""
        mediaPlaying: false
        mediaAvailable: true
    }
}
