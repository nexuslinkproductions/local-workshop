pragma ComponentBehavior: Bound
import QtQuick
import "../kit"

// StorageWidget.qml - v5 rest form for disk usage, rebuilt to the s10 mockup.
//
// A squircle dot grid: a 24 x 24 lattice on the 10 px s10 pitch, cells outside
// the superellipse |x/R|^6 + |y/R|^6 <= 1.3 dropped. The used share of the ROOT
// disk fills the grid from the bottom; the top filled row is the cyan front.
// To the right: the STORAGE label, the percent and the disk caption.
// Shape and colours: s10/src/build_s10.py storage_svg(). Box: s10-spacing.json
// storage (l 2001.3, t 773, r 2396.8, b 1007.8).
//
// Freshness (data widgets):
//   gstate "" or "fresh": bright values.
//   gstate "stale": every value in Tokens.textDim, ageText under the caption.
//   gstate "error": amber, no number, errText as the caption, unlit grid.
//   No disk row at all counts as error.
// WidgetBase has no freshness of its own, so these inputs live here.
// DeckView binds disks only; the stale and error states need the deck to bind
// gstate, ageText and errText.
WidgetBase {
    id: root

    // Array of { label, fs, mount, usedPct (0..100), sizeBytes, usedBytes, freeBytes }.
    // Tolerates undefined, null and {}.
    property var disks: []
    // "" | "fresh" | "stale" | "error"
    property string gstate: ""
    property string ageText: ""
    property string errText: "no disk data"

    expandable: true

    // ---- s10 geometry, relative to the widget origin ----------------------
    // Deck origin of this widget is (2001.4, 769.2) (DeckView), which is the
    // s10 box origin minus the drawn offset. Grid centre = box origin + 117.75
    // (24 cells x 10 px / 2, plus the dot radius). Text column: s10 x 2285.
    readonly property int gridN: 24
    readonly property real gridPitch: 10
    readonly property real gridCx: 118.15
    readonly property real gridCy: 121.55
    readonly property real textX: 283.6
    readonly property real labelY: 65.8
    readonly property real numY: 84.8
    readonly property real capY: 184.8
    readonly property real ageY: 211.8
    // Unlit cells, as in build_s10.py storage_svg().
    readonly property real unlitOpacity: 0.58

    readonly property var rows: root.rowsFrom(root.disks)
    readonly property var shownDisk: root.pickShown(root.rows)
    readonly property string dataState: (root.gstate === "error" || root.shownDisk === null)
        ? "error" : (root.gstate === "stale" ? "stale" : "fresh")
    readonly property real pct: root.shownDisk !== null ? root.shownDisk.pct : 0
    readonly property var cells: root.buildCells(root.dataState === "error" ? 0 : root.pct / 100)

    function rowsFrom(d) {
        var out = []
        if (!d || typeof d.length !== "number")
            return out
        for (var i = 0; i < d.length && out.length < 5; i++) {
            var x = d[i]
            if (!x || typeof x !== "object")
                continue
            var p = Number(x.usedPct)
            if (!isFinite(p))
                p = 0
            p = Math.max(0, Math.min(100, p))
            out.push({
                "label": x.label ? String(x.label) : (x.mount ? String(x.mount) : "DISK"),
                "pct": p,
                "isRoot": x.mount === "/" || x.label === "ROOT"
            })
        }
        return out
    }

    // The ROOT disk is the one the mockup shows. Without a root row, the
    // fullest disk stands in, with its own label.
    function pickShown(list) {
        var best = null
        for (var i = 0; i < list.length; i++) {
            if (list[i].isRoot)
                return list[i]
            if (best === null || list[i].pct > best.pct)
                best = list[i]
        }
        return best
    }

    function numText(p) {
        if (p >= 1)
            return String(Math.round(p))
        if (p > 0)
            return p.toFixed(1)
        return "0"
    }

    // Squircle lattice, sorted bottom row first (as build_s10.py), with the
    // first `lit` cells filled from the bottom. Radii are the SVG radius times 1.1.
    function buildCells(frac) {
        var n = root.gridN
        var p = root.gridPitch
        var R = n * p / 2
        var list = []
        for (var j = 0; j < n; j++) {
            for (var i = 0; i < n; i++) {
                var x = (i - (n - 1) / 2) * p
                var y = (j - (n - 1) / 2) * p
                if (Math.pow(Math.abs(x) / R, 6) + Math.pow(Math.abs(y) / R, 6) > 1.3)
                    continue
                list.push({ "x": x, "y": y })
            }
        }
        list.sort(function (a, b) {
            return (b.y - a.y) || (a.x - b.x)
        })
        var lit = Math.round(list.length * Math.max(0, Math.min(1, frac)))
        var base = list.length > 0 ? list[0].y : 0
        var front = lit > 0 ? list[lit - 1].y : base
        var out = []
        for (var k = 0; k < list.length; k++) {
            var c = list[k]
            if (k < lit) {
                var tt = base !== front ? (base - c.y) / (base - front) : 1
                out.push({
                    "x": c.x, "y": c.y, "lit": true,
                    "front": Math.abs(c.y - front) < 1,
                    "rad": (2.5 + 0.9 * tt) * 1.1,
                    "op": 0.70 + 0.30 * tt
                })
            } else {
                out.push({ "x": c.x, "y": c.y, "lit": false, "front": false, "rad": 1.8 * 1.1, "op": root.unlitOpacity })
            }
        }
        return out
    }

    // ---- the squircle dot grid ------------------------------------------
    Item {
        id: field
        x: 0
        y: 0
        width: root.width
        height: root.height

        Repeater {
            model: root.cells

            delegate: Rectangle {
                id: cell

                required property var modelData

                readonly property real rad: modelData.rad

                antialiasing: true
                x: root.gridCx + cell.modelData.x - cell.rad
                y: root.gridCy + cell.modelData.y - cell.rad
                width: 2 * cell.rad
                height: 2 * cell.rad
                radius: cell.rad
                color: cell.modelData.lit
                    ? (root.dataState === "fresh"
                        ? (cell.modelData.front ? Tokens.cyan : Tokens.white)
                        : Tokens.textDim)
                    : (root.dataState === "error" ? Tokens.amber : (root.dataState === "stale" ? Tokens.textDim : Tokens.ice))
                opacity: cell.modelData.op
            }
        }
    }

    // ---- label, percent and caption -------------------------------------
    Text {
        id: title
        x: root.textX
        y: root.labelY
        text: "STORAGE"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeCaption
        font.weight: Tokens.weightBold
        font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
    }

    Text {
        id: num
        x: root.textX
        y: root.numY
        visible: root.dataState !== "error"
        text: root.dataState === "error" ? "" : root.numText(root.pct)
        color: root.dataState === "stale" ? Tokens.textDim : Tokens.white
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeHero
        font.weight: Tokens.weightMedium
        font.letterSpacing: -0.025 * Tokens.sizeHero
    }

    Text {
        id: pctSign
        anchors.baseline: num.baseline
        anchors.left: num.right
        anchors.leftMargin: 10
        visible: num.visible
        text: "%"
        color: Tokens.textDim
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeBody
        font.weight: Tokens.weightMedium
    }

    Text {
        id: caption
        x: root.textX
        y: root.capY
        text: root.dataState === "error"
            ? root.errText
            : (root.shownDisk !== null ? root.shownDisk.label : "")
        color: root.dataState === "error"
            ? Tokens.amber
            : (root.dataState === "stale" ? Tokens.textDim : Tokens.textCaption)
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeLabel
        font.weight: Tokens.weightMedium
        font.letterSpacing: Tokens.sizeLabel * 0.02
    }

    // Stale age, beneath the caption. Shown only when the deck gives one.
    Text {
        id: age
        x: root.textX
        y: root.ageY
        visible: root.dataState === "stale" && root.ageText !== ""
        text: root.ageText
        color: Tokens.textDim
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.minTypeSize
        font.weight: Tokens.weightRegular
    }
}
