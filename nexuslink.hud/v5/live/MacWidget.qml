pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import "../kit"

// MacWidget - the s10 MAC block (build_s10.py mac_svg, group 'mac').
// A 124 degree fan of dots opens toward the knot: seven ping rings from 38 to
// 134 px, dots getting smaller and fainter outward. A 17 dot battery arc at
// 156 px, the laptop glyph at the fan origin, the MAC label and the latency
// number with ms to its left, and a 12 dot load bar under the fan. No frame,
// no glow.
//
// Local origin is the widget top-left. DeckView places this widget at deck
// (169.1, 688.8), so the fan origin sits at local (175.9, 151.2), the s10 deck
// point (345, 840). The drawn box starts at local (0.2, 4.1) and runs to
// local (336.5, 337), taller than the 220 px placed height; the parent owns
// that size.
//
// Freshness: fresh = bright number; stale = dim number with an age text;
// error = amber, no number. A link snapshot older than staleAfterS (two 12 s
// link polls) is stale. A snapshot without ts counts as fresh.
WidgetBase {
    id: root

    property var link: null
    // click opens the MAC focus view (DeckView onExpandRequested), like CREW
    expandable: true

    // ---- data bindings (feed shape unchanged) ----------------------------
    readonly property var rtt: (root.link && root.link.rtt_ms) ? root.link.rtt_ms : null
    readonly property var mac: (root.link && root.link.mac) ? root.link.mac : null
    readonly property bool tunnelUp: root.link !== null && root.link !== undefined
        && root.link.tunnel === "active"
    readonly property bool hasRtt: root.rtt !== null && typeof root.rtt.last === "number"

    // ---- freshness -------------------------------------------------------
    readonly property real staleAfterS: 24
    // Re-read on every deck tick; the age text only moves with whole seconds.
    readonly property real nowS: { root.tick; return Date.now() / 1000 }
    readonly property real ageS: (root.link && typeof root.link.ts === "number")
        ? root.nowS - root.link.ts : -1
    readonly property string gstate: (!root.tunnelUp || !root.hasRtt) ? "error"
        : (root.ageS > root.staleAfterS ? "stale" : "fresh")
    readonly property string errText: !root.link ? "error: no link feed"
        : (!root.tunnelUp ? "error: tunnel down" : "error: no ping")
    readonly property string ageText: {
        if (root.gstate !== "stale")
            return ""
        var s = Math.round(root.ageS)
        return s < 120 ? "stale " + s + " s" : "stale " + Math.round(s / 60) + " min"
    }
    readonly property bool showValue: root.gstate !== "error"
    readonly property string valueText: root.showValue ? String(Math.round(root.rtt.last)) : ""
    readonly property real fanAlpha: root.gstate === "stale" ? 0.45
        : (root.gstate === "error" ? 0.5 : 1.0)
    readonly property color arcColor: (root.gstate === "error" || (root.rtt && root.rtt.last >= 100))
        ? Tokens.amber : Tokens.ice
    readonly property color numColor: root.gstate === "stale" ? Tokens.textDim : Tokens.white
    readonly property color noteColor: root.gstate === "error" ? Tokens.amber : Tokens.textDim

    // Battery: 17 dots on the outer arc, lit share = batt percent.
    readonly property int battLit: (root.mac && typeof root.mac.batt === "number")
        ? Math.round(17 * Math.max(0, Math.min(100, root.mac.batt)) / 100) : 0
    // Load: 12 dots, lit share = 1 minute load over 12.
    readonly property int loadLit: (root.mac && root.mac.load && root.mac.load.length > 0)
        ? Math.max(1, Math.round(12 * Math.min(1, root.mac.load[0] / 12))) : 0

    // ---- layout (local px, from the s10 build) ---------------------------
    readonly property real fanX: 175.9
    readonly property real fanY: 151.2
    readonly property real textRight: 80.9
    readonly property real labelY: 98
    readonly property real valueY: 115
    readonly property real battR: 4.62     // s10 dr 4.2 x 1.1
    readonly property real loadLitR: 3.74  // s10 dr 3.4 x 1.1
    readonly property real loadDimR: 2.64  // s10 dr 2.4 x 1.1

    function arcPoints(n, rad, a0, span) {
        var out = []
        for (var i = 0; i < n; i++) {
            var a = (a0 + span * i / (n - 1)) * Math.PI / 180
            out.push({ x: root.fanX + rad * Math.cos(a), y: root.fanY + rad * Math.sin(a) })
        }
        return out
    }

    // Seven ping rings, 124 degrees, one dot per 8 px of arc length.
    readonly property var pingDots: {
        var out = []
        for (var k = 0; k < 7; k++) {
            var rad = 38 + 16 * k
            var pts = root.arcPoints(Math.round(rad * 124 * Math.PI / 180 / 8), rad, -62, 124)
            for (var i = 0; i < pts.length; i++)
                out.push({ x: pts[i].x, y: pts[i].y, r: (3.4 - 0.24 * k) * 1.1, op: 1 - 0.12 * k })
        }
        return out
    }
    readonly property var battDots: root.arcPoints(17, 156, -66, 132)
    readonly property var loadDots: {
        var out = []
        for (var i = 0; i < 12; i++)
            out.push({ x: root.fanX + 86 + (i - 5.5) * 10, y: root.fanY + 182 })
        return out
    }

    // ---- fan -------------------------------------------------------------
    Repeater {
        model: root.pingDots
        delegate: Rectangle {
            required property var modelData
            readonly property real rr: modelData.r
            x: modelData.x - rr
            y: modelData.y - rr
            width: 2 * rr
            height: width
            radius: rr
            color: root.arcColor
            opacity: modelData.op * root.fanAlpha
        }
    }

    Repeater {
        model: root.battDots
        delegate: Rectangle {
            required property var modelData
            required property int index
            x: modelData.x - root.battR
            y: modelData.y - root.battR
            width: 2 * root.battR
            height: width
            radius: root.battR
            color: Tokens.white
            opacity: index < root.battLit ? 1.0 : 0.2
        }
    }

    // Laptop glyph: icons.py 'mac' (24 unit box) drawn at 44 px, centred on the fan origin.
    Shape {
        x: root.fanX - 22
        y: root.fanY - 22
        width: 24
        height: 24
        scale: 44 / 24
        transformOrigin: Item.TopLeft
        ShapePath {
            fillColor: Tokens.white
            strokeColor: "transparent"
            strokeWidth: 0
            PathSvg {
                path: "M6.2 4.6h11.6A2.2 2.2 0 0 1 20 6.8V15H4V6.8a2.2 2.2 0 0 1 2.2-2.2z M2 16.8h20v.8a1.9 1.9 0 0 1-1.9 1.9H3.9A1.9 1.9 0 0 1 2 17.6z"
            }
        }
    }

    // ---- load bar (under the fan) ----------------------------------------
    Repeater {
        model: root.loadDots
        delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool lit: index < root.loadLit
            readonly property real rr: lit ? root.loadLitR : root.loadDimR
            x: modelData.x - rr
            y: modelData.y - rr
            width: 2 * rr
            height: width
            radius: rr
            color: lit ? Tokens.cyan : Tokens.ice
            opacity: lit ? 1.0 : 0.24
        }
    }

    // ---- text: MAC label, latency number and unit, right aligned ---------
    Text {
        id: labelT
        x: 0
        y: root.labelY
        width: root.textRight
        horizontalAlignment: Text.AlignRight
        text: "MAC"
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeCaption
        font.weight: Tokens.weightBold
        font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        color: Tokens.textLabel
    }

    Text {
        id: valueT
        visible: root.showValue
        text: root.valueText
        y: root.valueY
        x: root.textRight - unitT.implicitWidth - 6 - implicitWidth
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeHero
        font.weight: Tokens.weightMedium
        color: root.numColor
    }

    FontMetrics {
        id: fmValue
        font: valueT.font
    }

    FontMetrics {
        id: fmUnit
        font: unitT.font
    }

    Text {
        id: unitT
        visible: root.showValue
        text: "ms"
        x: root.textRight - implicitWidth
        y: valueT.y + fmValue.ascent - fmUnit.ascent
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeBody
        font.weight: Tokens.weightMedium
        color: Tokens.textDim
    }

    // Error reason (no number) or the stale age, right aligned under the label.
    Text {
        id: noteT
        visible: root.gstate !== "fresh"
        text: root.gstate === "error" ? root.errText : root.ageText
        x: root.textRight - implicitWidth
        y: root.gstate === "error" ? root.valueY + 26 : root.valueY + 72
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeCaption
        font.weight: Tokens.weightMedium
        color: root.noteColor
    }
}
