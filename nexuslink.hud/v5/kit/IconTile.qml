import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0
import "icons" as Icons

// IconTile.qml - one launcher tile: a 24 px-grid glyph, an optional label, a
// launch-count dot ring and a running node. Contract (fixed by the W4 card):
//
//   glyph        string key understood by kit/icons/Glyph.qml
//   label        string, optional, drawn at or above Tokens.minTypeSize
//   launchCount  int, lights one dot per launch (capped at ringSlots)
//   running      bool, one accent node with a slow breath
//   selected     bool, scale only: no box, no outline, no highlight plate
//   size         real, tile edge in px
//
// Two optional properties beyond the contract, both inert by default:
//   dimmed       the "everything else goes quiet" half of selection. W5 sets it
//                on every tile that is not selected while a selection is active.
//   accent       colour of the running node; defaults to Tokens.acid.
//
// Anatomy (fractions of `size`, so any tile size keeps the same proportions):
//   glyph box 0.50, centred at 0.36; ring radius 0.325 at the same centre;
//   label baseline block at 0.90. Nothing is drawn behind the tile.
Item {
    id: tile

    property string glyph: ""
    property string label: ""
    property int launchCount: 0
    property bool running: false
    property bool selected: false
    property real size: 72
    property bool dimmed: false
    property color accent: Tokens.acid

    readonly property real glyphBox: size * 0.50
    readonly property real ringCentreY: size * 0.36
    readonly property real ringRadius: size * 0.325
    readonly property int ringSlots: 12
    readonly property int ringLit: Math.max(0, Math.min(launchCount, ringSlots))
    readonly property real ringDot: Math.max(2, size * 0.036)
    // Dash period in stroke widths, set so exactly ringSlots nodes fit the ring.
    readonly property real ringGap: Math.max(0.5,
        2 * Math.PI * ringRadius / ringSlots / ringDot - 0.001)
    readonly property real runDot: Math.max(3, size * 0.058)
    readonly property real labelSize: Math.max(Tokens.minTypeSize, size * 0.17)

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    transformOrigin: Item.Center

    opacity: dimmed ? Tokens.focusDimMax : 1.0
    Behavior on opacity {
        NumberAnimation {
            duration: Motion.focusInMillis
            easing.type: Easing.OutCubic
        }
    }

    // Selected is scale + dim only: no box, no outline, no plate. The spring is
    // the expand spec while it grows and the softer return spec on the way back,
    // both read from Motion; nothing here is linear.
    readonly property real restScale: selected ? 1.06 : 1.0
    scale: restScale
    Behavior on scale {
        SpringAnimation {
            mass: 1
            spring: (tile.selected ? Motion.expandOmega : Motion.returnOmega)
                    * (tile.selected ? Motion.expandOmega : Motion.returnOmega)
            damping: 2 * (tile.selected ? Motion.expandZeta : Motion.returnZeta)
                     * (tile.selected ? Motion.expandOmega : Motion.returnOmega)
        }
    }

    // launch-count ring: one round node per launch, clockwise from the top
    Shape {
        anchors.fill: parent
        visible: tile.ringLit > 0
        // 12 px of headroom on every side keeps the scaled ring inside the tile
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: tile.selected ? Tokens.white : Tokens.ice
            strokeWidth: tile.ringDot
            fillColor: "transparent"
            strokeStyle: ShapePath.DashLine
            dashPattern: [0.001, tile.ringGap]
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathAngleArc {
                centerX: tile.size / 2
                centerY: tile.ringCentreY
                radiusX: tile.ringRadius
                radiusY: tile.ringRadius
                startAngle: -90
                // 0.5 deg short of the slot boundary: without the epsilon the
                // dash pattern starts one more node right at the arc end, so a
                // launchCount of 3 would draw 4 nodes.
                sweepAngle: Math.max(0, tile.ringLit * 360 / tile.ringSlots - 0.5)
            }
        }
    }

    Icons.Glyph {
        anchors.horizontalCenter: parent.horizontalCenter
        y: tile.ringCentreY - height / 2
        glyph: tile.glyph
        weight: 2.0
        size: tile.glyphBox
        color: tile.selected ? Tokens.white
                            : (tile.dimmed ? Tokens.textDim : Tokens.ink)
    }

    // running node: one accent dot, slow breath, never still
    Shape {
        id: runNode
        visible: tile.running
        width: tile.runDot
        height: tile.runDot
        x: tile.size * 0.79 - width / 2
        y: tile.size * 0.62 - height / 2
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: "transparent"
            fillColor: tile.accent
            PathAngleArc {
                centerX: runNode.width / 2
                centerY: runNode.height / 2
                radiusX: runNode.width / 2
                radiusY: runNode.height / 2
                startAngle: 0
                sweepAngle: 360
            }
        }
        SequentialAnimation on opacity {
            running: tile.running
            loops: Animation.Infinite
            NumberAnimation {
                from: 1.0
                to: 0.45
                duration: Motion.breathPeriod * 1000 * Motion.breathInhale
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: 0.45
                to: 1.0
                duration: Motion.breathPeriod * 1000 * Motion.breathExhale
                easing.type: Easing.InOutSine
            }
        }
    }

    Text {
        visible: tile.label.length > 0
        width: tile.size * 1.9
        anchors.horizontalCenter: parent.horizontalCenter
        y: tile.size - height - tile.size * 0.03
        text: tile.label
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: tile.selected ? Tokens.white
                             : (tile.dimmed ? Tokens.textDim : Tokens.textLabel)
        font.pixelSize: tile.labelSize
        font.family: Tokens.fontFamily
        font.weight: tile.selected ? Tokens.weightBold : Tokens.weightMedium
        font.letterSpacing: tile.labelSize * Tokens.trackName
        // tight line box: at a 56 px tile a default 1.3 line height puts the
        // label's ink under the launch ring
        lineHeight: 1.05
        lineHeightMode: Text.FixedHeight
    }
}
