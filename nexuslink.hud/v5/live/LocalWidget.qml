import QtQuick
import "../kit"

// LocalWidget - s10 LOCAL block. A hex lattice triangle on the left (26 rows,
// 10 px pitch, lit from the base at 30 MB per row, one acid row of every-third
// dot on the top lit row), and on the right the LOCAL label, the size with its
// GB unit, the model name and the age line. Geometry is the s10 mockup
// (build_s10.py group 'local' at centre (2120, 562), text edge 2285, baselines
// read off s10-rest.png). Item origin: DeckView places the item at the s10 box
// origin minus the drawn offset (0.9, 4.1), so the drawn box lands on
// l 1991.3, t 451.7 at rest.
//
// Freshness (data widget contract): fresh = bright number; stale (gstate
// "stale") = dim number, dim lattice and an age line; error (gstate "error")
// = amber, no number. The LocalAi feed does not publish gstate, ageText or
// errText yet; until it does, a loaded feed is always fresh and an absent file
// is idle (dim, no lit rows).
WidgetBase {
    id: root

    property var localAi: null

    readonly property var ai: root.localAi ? root.localAi : ({})
    readonly property bool present: root.ai.present === true
    readonly property bool active: root.ai.active === true
    readonly property real sizeGb: (typeof root.ai.sizeGb === "number") ? root.ai.sizeGb : 0
    readonly property real vramGb: (typeof root.ai.vramGb === "number") ? root.ai.vramGb : 0
    readonly property real shownGb: root.sizeGb > 0 ? root.sizeGb : root.vramGb
    readonly property real activity: (typeof root.ai.activity === "number")
        ? Math.max(0, Math.min(1, root.ai.activity)) : 0
    readonly property string model: (typeof root.ai.model === "string") ? root.ai.model : ""

    // freshness contract, same field names as DeckTokens gaugeOf
    readonly property string gstate: (typeof root.ai.gstate === "string") ? root.ai.gstate : ""
    readonly property bool failed: root.gstate === "error"
    readonly property bool stale: root.gstate === "stale"
    readonly property string ageText: (typeof root.ai.ageText === "string") ? root.ai.ageText : ""
    readonly property string errText: (typeof root.ai.errText === "string") ? root.ai.errText : ""

    // ---- lattice (s10 local_svg) ----------------------------------------
    readonly property int rows: 26
    readonly property real pitch: 10
    readonly property real mbPerRow: 30
    // lit rows counted from the base; s10 floor of 2 when a model is loaded
    readonly property int lit: (root.present && !root.failed)
        ? Math.max(2, Math.round(root.shownGb * 1000 / root.mbPerRow)) : 0
    // acid row pulse, only while the model is active
    readonly property real pulse: root.active
        ? 1 - Motion.breathBright * (0.5 + 0.5 * root.activity)
              * (0.5 + 0.5 * Math.sin(root.tick * 2 * Math.PI / Motion.breathPeriod))
        : 1

    readonly property var cells: root.buildCells(root.lit)

    function buildCells(lit) {
        var out = []
        var n = root.rows, p = root.pitch, rh = p * 0.866, h = (n - 1) * rh
        for (var k = 0; k < n; k++) {
            var y = -h / 2 + k * rh, cnt = k + 1, fb = n - 1 - k
            for (var i = 0; i < cnt; i++) {
                var x = (i - (cnt - 1) / 2) * p
                var on = fb < lit
                var top = fb === lit - 1
                var tt = 1 - fb / Math.max(1, lit)
                var r, op, kind
                if (on) {
                    if (top && i % 3 === 1) {
                        r = 3.4; op = 1; kind = "acid"
                    } else {
                        r = 1.9 + 1.5 * tt; op = 0.55 + 0.45 * tt
                        kind = (i % 4) ? "white" : "cyan"
                    }
                } else {
                    var edge = (i === 0 || i === cnt - 1 || k === n - 1)
                    r = edge ? 1.9 : 1.5; op = edge ? 0.8 : 0.52; kind = "ice"
                }
                out.push({ x: x, y: y, r: r, op: op, kind: kind })
            }
        }
        return out
    }

    function kindColor(kind) {
        if (kind === "acid") return Tokens.acid
        if (kind === "white") return Tokens.white
        if (kind === "cyan") return Tokens.cyan
        if (!root.present) return Tokens.textDim
        if (root.failed) return Tokens.amber
        return Tokens.ice
    }

    Item {
        id: lattice
        x: 129.6          // s10 centre x 2120 minus item origin 1990.4
        y: 114.4          // s10 centre y 562 minus item origin 447.6
        width: 1
        height: 1
        opacity: root.stale ? 0.45 : 1

        Repeater {
            model: root.cells
            Rectangle {
                readonly property real d: modelData.r * 2.2   // svg r is 1.1 x r
                x: modelData.x - d / 2
                y: modelData.y - d / 2
                width: d
                height: d
                radius: d / 2
                color: root.kindColor(modelData.kind)
                opacity: modelData.op * (modelData.kind === "acid" ? root.pulse : 1)
            }
        }
    }

    // ---- text block (s10 .tb, right side) -------------------------------
    // Each line sits on its measured baseline (s10-rest.png: LOCAL cap base
    // 521, digit base 592, model base 642); text edge x 2285 is 294.6 here.
    Text {
        id: label
        text: "LOCAL"
        x: 294.6
        y: 73.4 - label.baselineOffset
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeCaption
        font.weight: Tokens.weightBold
        font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        color: Tokens.textLabel
    }

    Text {
        id: value
        text: root.present ? (root.failed ? "error" : root.shownGb.toFixed(1)) : "idle"
        x: 294.6
        y: 144.4 - value.baselineOffset
        font.family: Tokens.fontFamily
        font.pixelSize: (root.present && !root.failed) ? Tokens.sizeHero : Tokens.sizeTitle
        font.weight: Tokens.weightMedium
        font.letterSpacing: -Tokens.trackClock * Tokens.sizeHero
        color: root.failed ? Tokens.amber
             : (root.present && !root.stale) ? Tokens.white
             : Tokens.textDim
    }

    Text {
        id: unit
        text: "GB"
        visible: root.present && !root.failed
        x: value.x + value.width + 6
        y: 144.4 - unit.baselineOffset
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeBody
        font.weight: Tokens.weightMedium
        color: Tokens.textDim
    }

    Text {
        id: modelText
        text: root.model
        visible: root.present && !root.failed && root.model !== ""
        x: 294.6
        y: 194.4 - modelText.baselineOffset
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeLabel
        font.weight: Tokens.weightMedium
        font.letterSpacing: Tokens.sizeLabel * 0.02   // s10 .cap2 .02em
        color: Tokens.textCaption
    }

    Text {
        id: errLine
        text: root.errText !== "" ? root.errText : "error"
        visible: root.failed
        x: 294.6
        y: 194.4 - errLine.baselineOffset
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeCaption
        font.weight: Tokens.weightMedium
        color: Tokens.amber
    }

    Text {
        id: ageLine
        text: root.ageText
        visible: !root.failed && root.ageText !== ""
        x: 294.6
        y: 216.4 - ageLine.baselineOffset
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeCaption
        font.weight: Tokens.weightMedium
        color: Tokens.textDim
    }
}
