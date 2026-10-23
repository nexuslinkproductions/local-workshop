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

    function collect(item, out) {
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var c = kids[i]
            var txt = c.text
            if (typeof txt === "string" && txt.length > 0) {
                var op = probe.effectiveOpacity(c)
                if (op > 0.01) {
                    var p = c.mapToItem(null, 0, 0)
                    out.push({
                        "t": txt,
                        "px": c.font.pixelSize,
                        "wt": c.font.weight,
                        "x": Math.round(p.x * 10) / 10,
                        "y": Math.round(p.y * 10) / 10,
                        "w": Math.round(c.width * 10) / 10,
                        "h": Math.round(c.height * 10) / 10,
                        "op": Math.round(op * 1000) / 1000
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
        console.log("AUDIT " + JSON.stringify({ "label": probe.label, "texts": out }))
    }
}
