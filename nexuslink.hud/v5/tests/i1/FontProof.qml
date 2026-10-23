import QtQuick
import "../../stills" as Stills
import "../../kit"
import "../.." as Deck

// I1 font proof, run through the still harness itself:
//
//   nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/tests/i1/FontProof.qml \
//       /tmp/font-proof.png 2>&1 | grep FONT
//
// WHY. The deck asks every Text for family "Satoshi". If that family is not in
// the font database the request silently falls back to another face and every
// layout number measured on the render is measured against the wrong metrics.
// So this root composes the deck exactly as stills/i1-deck-rest.qml does - the
// only difference is that it also prints what the engine resolved. The FONT
// line carries Qt.fontFamilies(), and for the deck's three type sizes the
// advance in the token family next to the same string in a family that cannot
// exist (the fallback): a string whose Satoshi advance differs from its fallback
// advance is the one measurement that tells the two faces apart.
// v5/tools/deck-audit.py runs that comparison over every visible Text and fails
// non-zero on a mismatch; this probe shows the number from inside the render
// path itself.
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
    }

    property var twinComponent: Component {
        Text { visible: false; textFormat: Text.PlainText; wrapMode: Text.NoWrap }
    }

    function advance(s, px, wt, fam, ls, feats) {
        var t = twinComponent.createObject(root)
        t.font.family = fam
        t.font.pixelSize = px
        t.font.weight = wt
        t.font.letterSpacing = ls || 0
        if (feats)
            t.font.features = feats
        t.text = s
        var w = t.contentWidth
        t.destroy()
        return Math.round(w * 1000) / 1000
    }

    // The still harness renders through QQuickRenderControl and never spins the
    // event loop, so a Timer here would not fire: the report runs at completion,
    // which is after the deck's own FontLoaders have been created (FontLoader
    // loads its file synchronously at creation, so the family is in the database
    // by the time the deck's Text items are laid out).
    Component.onCompleted: {
        var tnum = { "tnum": 1 }
        var fam = Tokens.fontFamily
        var miss = "NexusNoSuchFamilyZzz"
        console.log("FONT " + JSON.stringify({
            "family": fam,
            "familiesHasSatoshi": Qt.fontFamilies().indexOf(fam) >= 0,
            "familiesCount": Qt.fontFamilies().length,
            // Clock digits: the deck's largest type, one Text per glyph with the
            // tnum feature on (kit/Clock.qml).
            "clockDigit96": root.advance("0", 96, Font.Normal, fam, 0, tnum),
            "clockDigit96Fallback": root.advance("0", 96, Font.Normal, miss, 0, tnum),
            "clockOne96": root.advance("1", 96, Font.Normal, fam, 0, tnum),
            "clockColon96": root.advance(":", 96, Font.Normal, fam, 0, tnum),
            "clockColon96Fallback": root.advance(":", 96, Font.Normal, miss, 0, tnum),
            // DeckLabel: 16 px Medium with the tracking token.
            "label16": root.advance("STORAGE", Tokens.sizeCaption, Tokens.weightMedium,
                                    fam, Tokens.trackLabel * Tokens.sizeCaption),
            "label16Fallback": root.advance("STORAGE", Tokens.sizeCaption, Tokens.weightMedium,
                                            miss, Tokens.trackLabel * Tokens.sizeCaption),
            // DeckValue: 20 px Regular.
            "value20": root.advance("412 GB", Tokens.sizeLabel, Tokens.weightRegular, fam, 0),
            "value20Fallback": root.advance("412 GB", Tokens.sizeLabel, Tokens.weightRegular,
                                            miss, 0)
        }))
    }
}
