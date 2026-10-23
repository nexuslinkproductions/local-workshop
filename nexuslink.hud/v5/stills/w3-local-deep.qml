import QtQuick
import "../kit"
import ".." as Deck

// W3 still: the deck's `local` deep view, 2560x1440 - the one place the deck
// composes LocalOrb, so this is where the sphere-field motion was repaired.
//
//   nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/stills/w3-local-deep.qml <out.png>
//
// `focusRequest: "local"` is the whole focus manager: kit/Focus dims and blurs
// everything outside localRect, the LOCAL level stack steps aside for the deep
// view, and DeckSurface.localDeep appears at the LOCAL band with the W3 orb at
// 200 px beside the level stack. stillFocusProgress pins the W7 effect at 1 so
// the still does not depend on a clock.
//
// modelActivity is the fixtures' 0.0, so the orb is traced here at rest (scale
// 1.0000); the animation itself is measured by tools/w3-localorb-trace.py, which
// reads the same component's fieldScale at 200 px.
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
}
