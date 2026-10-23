import QtQuick
import "../.." as Deck
import "../../kit"
import "../../stills" as Stills

// W3 gauge deck audit: which gauges the composed deck is actually drawing in a
// deep view, at what size, and at what resting scale.
//
//   QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH=<imports> \
//       qml -I <imports> tests/w3/GaugeDeepAudit.qml -- --focus=mac
//
// tools/w3-gauge-deck-audit.py runs mac, storage and launcher and judges the
// result. This is the item-tree counterpart to the still: the still proves the
// deck pixels did not move, this proves the components are really in the tree
// (visible, at the deck's size, art scale snapped to its resting target) rather
// than an empty box that happens to render the same colour as the field.
//
// Prints one `AUDIT {...}` line with, per gauge: the QML type, size, the
// animated child's scale, opacity, the visible dot count and the painted box.
Item {
    id: probe

    width: 2560
    height: 1440

    readonly property var argv: Qt.application.arguments
    // Not `focus`: QQuickItem::focus is FINAL in Qt 6.12 (the same reason the
    // gauges spell their focus input focusLevel).
    readonly property string focusName: {
        for (var i = 0; i < probe.argv.length; i++)
            if (probe.argv[i].indexOf("--focus=") === 0)
                return probe.argv[i].substring(8)
        return "mac"
    }

    Stills.DeckFixtures { id: fx }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    Deck.DeckSurface {
        id: deck

        anchors.fill: parent
        animate: false
        benchPhase: 0
        stillFocusProgress: 1
        focusRequest: probe.focusName

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

    // Depth-first walk, because a deep view's gauges sit inside Column/Repeater
    // wrappers. `objectName` is empty everywhere in the kit, so the type name
    // from toString() is the classifier.
    function walk(item, into) {
        if (!item)
            return
        var name = String(item)
        var type = name.indexOf("_QMLTYPE") > 0 ? name.substring(0, name.indexOf("_QMLTYPE"))
                                                : name.substring(0, name.indexOf("("))
        if (type === "PulseRing" || type === "DotArc" || type === "DotBar" || type === "IconTile")
            into.push(item)
        var kids = item.children
        for (var i = 0; i < kids.length; i++)
            probe.walk(kids[i], into)
    }

    function dotCount(item) {
        // The visible rectangles a gauge paints: antialiased dots are Rectangle
        // delegates; the label Text and the wrappers are not.
        var n = 0
        var kids = item.children
        for (var i = 0; i < kids.length; i++) {
            var k = kids[i]
            var t = String(k)
            if (t.indexOf("QQuickRectangle") === 0 && k.visible)
                n++
            n += probe.dotCount(k)
        }
        return n
    }

    function report() {
        var items = []
        probe.walk(deck, items)
        var out = []
        var live = 0
        for (var i = 0; i < items.length; i++) {
            var g = items[i]
            var type = String(g)
            type = type.substring(0, type.indexOf("_QMLTYPE"))
            var art = g.children.length > 0 ? g.children[0] : null
            var entry = {
                "type": type,
                "visible": g.visible,
                "width": Math.round(g.width * 100) / 100,
                "height": Math.round(g.height * 100) / 100,
                "size": g.size !== undefined ? Math.round(g.size * 100) / 100 : 0,
                "referenceSize": g.referenceSize !== undefined
                                 ? Math.round(g.referenceSize * 100) / 100 : 0,
                "x": Math.round(g.mapToItem(deck, 0, 0).x * 100) / 100,
                "y": Math.round(g.mapToItem(deck, 0, 0).y * 100) / 100,
                "rootScale": Math.round(g.scale * 1000000) / 1000000,
                "opacity": Math.round(g.opacity * 1000000) / 1000000,
                // The value the component says it should be drawn at once the
                // motion settles (targetScale on the three gauges, restScale on
                // the tile). At rest these two must be equal: focusLevel is 0.
                "targetScale": g.targetScale !== undefined
                               ? Math.round(g.targetScale * 1000000) / 1000000
                               : (g.restScale !== undefined
                                  ? Math.round(g.restScale * 1000000) / 1000000 : 0),
                "targetOpacity": g.targetOpacity !== undefined
                                 ? Math.round(g.targetOpacity * 1000000) / 1000000 : -1,
                "dots": probe.dotCount(g)
            }
            // The three gauges animate children[0]; IconTile animates its own
            // scale. Report whichever is the drawn number.
            entry.artScale = art && type !== "IconTile"
                             ? Math.round(art.scale * 1000000) / 1000000 : entry.rootScale
            if (g.visible) {
                live++
                out.push(entry)
            }
        }
        console.log("AUDIT " + JSON.stringify({
            "focus": probe.focusName,
            "focusId": deck.focusId,
            "focusRect": [deck.focusRect.x, deck.focusRect.y,
                          deck.focusRect.width, deck.focusRect.height],
            "gaugesInTree": items.length,
            "gaugesVisible": live,
            "visible": out
        }))
        Qt.exit(0)
    }

    Timer {
        interval: 120
        running: true
        onTriggered: probe.report()
    }
}
