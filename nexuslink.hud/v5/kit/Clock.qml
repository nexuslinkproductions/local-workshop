pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// Clock.qml - the deck clock: very large numerals on one fixed-advance grid.
//
// Contract (W7): Clock { time: string; showSeconds: bool }. `time` is a plain
// "HH:MM" or "HH:MM:SS" string supplied by the shell layer; the component never
// reads a clock itself, so there is no Timer and no seconds blink. A malformed
// or empty string leaves the clock in a calm resting state (dim dashes) at the
// exact width it will occupy once data arrives.
//
// Fixed advance width (the no-jitter rule): every digit gets its own cell of
// `digitEm * pixelSize` and sits horizontally centred in it; the colon gets
// `colonEm * pixelSize`. The grid comes from the s1 study
// (hud-candidates/comp-r1/s1/src/build.py:211-212: .d width .62em, .col .26em)
// and is independent of the glyph advances, so "01:11" and "18:48" are the
// same width by construction, not by luck of the font. `font.features`
// additionally asks for tabular figures where the face supports them, so each
// glyph also sits identically inside its cell.
//
// Nothing here paints below Tokens.minTypeSize (16 px); the default is
// Tokens.sizeClock (168 px) from the s1 type ramp.
Item {
    id: root

    // ---- contract --------------------------------------------------------
    property string time: ""
    property bool showSeconds: false

    // ---- type ------------------------------------------------------------
    property int pixelSize: Tokens.sizeClock
    property int weight: Tokens.weightRegular
    property color digitColor: Tokens.ink
    property color colonColor: Tokens.ink
    property real colonOpacity: 0.7

    // ---- fixed grid, em --------------------------------------------------
    // s1 build.py: .d 0.62em per digit, .col 0.26em per colon, colon raised
    // 0.06em and drawn at 0.7 opacity.
    property real digitEm: 0.62
    property real colonEm: 0.26
    property real colonRiseEm: 0.06
    property real lineHeightEm: 1.0

    // ---- parsed state ----------------------------------------------------
    readonly property bool valid: /^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$/.test(time)
    readonly property bool resting: !valid
    readonly property string shown: {
        if (!valid)
            return "--:--"                       // same cell count as HH:MM
        if (!showSeconds && time.length > 5)
            return time.substring(0, 5)
        return time
    }
    readonly property var cells: {
        var out = []
        for (var i = 0; i < shown.length; ++i) {
            var ch = shown.charAt(i)
            out.push({
                "ch": ch,
                "cw": (ch === ":" ? colonEm : digitEm) * pixelSize
            })
        }
        return out
    }
    readonly property real textWidth: {
        var w = 0
        for (var i = 0; i < cells.length; ++i)
            w += cells[i].cw
        return w
    }
    readonly property real digitWidth: digitEm * pixelSize
    readonly property real colonWidth: colonEm * pixelSize

    implicitWidth: Math.ceil(textWidth)
    implicitHeight: Math.ceil(pixelSize * lineHeightEm)
    // The clock is a readout, not a surface: only the glyphs paint.
    opacity: valid ? 1.0 : 0.45

    // Satoshi: five faces under ../fonts, all report family "Satoshi"; weight
    // selects the face (Regular is the component default; DeckSurface passes
    // Tokens.weightLight for the deck clock). Loading them here keeps the
    // component self-contained for stills and for the integrator's first mount.
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Light.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Bold.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Black.ttf") }

    Row {
        id: digits
        anchors.centerIn: parent
        width: root.textWidth
        height: root.implicitHeight

        Repeater {
            model: root.cells

            Text {
                id: cell
                required property var modelData
                width: modelData.cw
                height: root.implicitHeight
                text: modelData.ch
                textFormat: Text.PlainText
                wrapMode: Text.NoWrap
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: modelData.ch === ":" ? root.colonColor : root.digitColor
                opacity: modelData.ch === ":" ? root.colonOpacity : 1.0
                font.family: Tokens.fontFamily
                font.weight: root.weight
                font.pixelSize: root.pixelSize
                font.features: ({ "tnum": 1 })
                renderType: Text.QtRendering
                transform: Translate { y: -root.colonRiseEm * root.pixelSize * (cell.modelData.ch === ":" ? 1 : 0) }
            }
        }
    }
}
