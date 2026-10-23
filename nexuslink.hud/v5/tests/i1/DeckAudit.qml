import QtQuick

// I1 text audit probe. Loads one deck root, waits for layout, then walks the
// live item tree and prints every visible Text as JSON on stdout:
//
//   QT_QPA_PLATFORM=offscreen qml -I <imports> nexuslink.hud/v5/tests/i1/audit-rest.qml
//   AUDIT {"label":"rest","texts":[{"t":"00:18","px":96,"wt":400,"x":1148,...}]}
//
// v5/tools/deck-audit.py runs this, counts words, finds the smallest type size
// and checks every pair of text boxes for overlap. The probe is test
// scaffolding, not part of the kit: it never runs in the shell.
Item {
    id: probe

    width: 2560
    height: 1440

    property string sourceQml: ""
    property string label: "deck"
    property int settleMs: 900

    Loader {
        id: loader

        anchors.fill: parent
        source: probe.sourceQml
    }

    Timer {
        interval: probe.settleMs
        running: true
        repeat: false

        onTriggered: {
            probe.dump()
            Qt.exit(0)
        }
    }

    // An item paints only if nothing above it is invisible or fully transparent.
    function effectiveOpacity(item) {
        var op = 1
        var it = item
        while (it) {
            if (it.visible === false)
                return 0
            if (typeof it.opacity === "number")
                op *= it.opacity
            it = it.parent
        }
        return op
    }

    // Font proof. The deck asks every Text for family "Satoshi"; if that family
    // is not in the font database the request silently falls back and every
    // measured advance belongs to another face. So for each painted Text the
    // probe measures the same string three ways in the same engine: what the
    // live item actually advanced (contentWidth), a twin with family "Satoshi",
    // and a twin with a family that cannot exist (the fallback face). A live
    // item that matches the Satoshi twin and not the fallback twin is painted
    // in Satoshi. Nothing here is guessed from the source.
    property var twinComponent: Component {
        Text { visible: false; textFormat: Text.PlainText; wrapMode: Text.NoWrap }
    }

    function advanceWidth(s, px, wt, fam, ls, feats) {
        var t = twinComponent.createObject(probe)
        t.font.family = fam
        t.font.pixelSize = px
        t.font.weight = wt
        t.font.letterSpacing = ls
        if (feats)
            t.font.features = feats
        t.text = s
        var w = t.contentWidth
        t.destroy()
        return Math.round(w * 1000) / 1000
    }

    function collect(item, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            var txt = c.text
            if (typeof txt === "string" && txt.length > 0) {
                var op = probe.effectiveOpacity(c)
                if (op > 0.01) {
                    var p = c.mapToItem(null, 0, 0)
                    var advS = probe.advanceWidth(txt, c.font.pixelSize, c.font.weight,
                                                  "Satoshi", c.font.letterSpacing,
                                                  c.font.features)
                    var advF = probe.advanceWidth(txt, c.font.pixelSize, c.font.weight,
                                                  "NexusNoSuchFamilyZzz", c.font.letterSpacing,
                                                  c.font.features)
                    out.push({
                        "t": txt,
                        "px": c.font.pixelSize,
                        "wt": c.font.weight,
                        "x": Math.round(p.x * 10) / 10,
                        "y": Math.round(p.y * 10) / 10,
                        "w": Math.round(c.width * 10) / 10,
                        "h": Math.round(c.height * 10) / 10,
                        "op": Math.round(op * 1000) / 1000,
                        "adv": Math.round(c.contentWidth * 1000) / 1000,
                        "advSatoshi": advS,
                        "advFallback": advF,
                        // A text that does not fit its box reports the elided
                        // advance, which is smaller than both twins: it cannot
                        // tell the two faces apart and the checker skips it.
                        "advConstrained": c.contentWidth + 0.01 < Math.min(advS, advF)
                    })
                }
            }
            probe.collect(c, out)
        }
    }

    function dump() {
        if (!loader.item) {
            console.log("AUDIT " + JSON.stringify({ "label": probe.label, "error": "root did not load" }))
            return
        }
        var out = []
        probe.collect(loader.item, out)
        console.log("AUDIT " + JSON.stringify({
            "label": probe.label,
            "fontFamily": "Satoshi",
            "fontFamiliesHasSatoshi": Qt.fontFamilies().indexOf("Satoshi") >= 0,
            "fontFamiliesCount": Qt.fontFamilies().length,
            "texts": out
        }))
    }
}
