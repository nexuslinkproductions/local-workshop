import QtQuick
import "../kit"
import ".." as Deck

// I1 still: crew focus - the first deeper view (sessions), 2560x1440.
//
//   nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/stills/i1-deck-crew-focus.qml <out.png>
//
// `focusId: "crew"` is the whole focus manager: kit/Focus dims, scrims and
// blurs everything outside crewRect, CrewOrb expands to 1.4x its rest size and
// prints one title per session, and the deck's own readouts step aside.
// stillFocusProgress pins the W7 effect at 1 so the still does not depend on a
// clock; the shell leaves it at -1 and the effect springs in.
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
        focusRequest: "crew"

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
