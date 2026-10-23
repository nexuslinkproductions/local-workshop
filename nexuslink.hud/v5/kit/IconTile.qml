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
//   focusLevel   real 0..1, the dim half of focus. 0 draws the tile at full
//                strength, 1 fades the whole tile to Tokens.focusDimMax. Nothing
//                recolours on focus, so dim is one mechanism. W5 sets it on
//                every tile that is not selected while a focus is active.
//   accent       colour of the running node; defaults to Tokens.acid.
//
// Anatomy (fractions of `size`, so any tile size keeps the same proportions):
//   glyph box 0.50, centred at 0.36; ring radius 0.325 at the same centre;
//   label box 1.90 wide, its bottom edge 0.03 above the tile bottom.
// Nothing is drawn behind the tile.
Item {
    id: tile

    property string glyph: ""
    property string label: ""
    property int launchCount: 0
    property bool running: false
    property bool selected: false
    property real size: 72
    property real focusLevel: 0
    property color accent: Tokens.acid

    // Glyph box 0.50 of the tile, centred on the ring centre.
    readonly property real glyphBox: size * 0.50
    // Ring centre 0.36 of the tile: upper half, clear of the label box.
    readonly property real ringCentreY: size * 0.36
    // Ring radius 0.325 of the tile, so the ring's outer edge (0.825 to the
    // right of centre) stays inside the tile even when the tile is selected.
    readonly property real ringRadius: size * 0.325
    readonly property int ringSlots: 12
    readonly property int ringLit: Math.max(0, Math.min(launchCount, ringSlots))
    // One stroke weight for the whole glyph set: 2.0 on the 24 px grid.
    // No Tokens.iconStroke yet; requested in the W4 PR body.
    readonly property real glyphWeight: 2.0
    // Launch dot 0.036 of the tile, floored at 2 px so it still resolves small.
    readonly property real ringDot: Math.max(2, size * 0.036)
    // Dash period in stroke widths, set so exactly ringSlots nodes fit the ring;
    // the 0.001 is the dash epsilon that keeps the last node from doubling.
    readonly property real ringGap: Math.max(0.5,
        2 * Math.PI * ringRadius / ringSlots / ringDot - 0.001)
    // Running node 0.058 of the tile, floored at 3 px for the same reason.
    readonly property real runDot: Math.max(3, size * 0.058)
    // Running node centre at 0.79 / 0.62 of the tile: lower right of the ring,
    // clear of both the glyph box and the label.
    readonly property real runNodeX: 0.79
    readonly property real runNodeY: 0.62
    // Breath runs the node from full strength down to 0.45: a visible pulse,
    // not a fade to nothing.
    readonly property real breathFloor: 0.45
    // Label type 0.17 of the tile, floored at Tokens.minTypeSize.
    readonly property real labelSize: Math.max(Tokens.minTypeSize, size * 0.17)
    // Label box 1.90 of the tile wide, its bottom edge 0.03 above the tile edge.
    readonly property real labelBoxWidth: 1.90
    readonly property real labelBottomGap: 0.03
    // ProportionalHeight is a multiple of the font's natural line box: 1.0 is
    // one natural line, 20 px for the 16 px label with Satoshi loaded.
    readonly property real labelLineHeight: 1.0
    // Selected scale 1.06, the one thing selection changes.
    readonly property real selectedScale: 1.06

    readonly property real restScale: selected ? selectedScale : 1.0
    // Clamped here, so an out-of-range feed value cannot push the tile past full
    // strength or below the approved dim floor.
    readonly property real dimAmount: Math.max(0, Math.min(1, focusLevel))

    // ---- motion ----------------------------------------------------------
    // Both channels run the wave's measured curves, not a Qt spring.
    //
    // Scale is a lift: expand in on Easing.OutBack at parameter 1.15 (peak
    // 1.04871 = 4.87 percent, inside Motion.expandOvershoot's 4 to 6 band) over
    // Motion.expandMillis, return out on Easing.OutCubic over Motion.returnMillis
    // with no overshoot. Dim is a fade and takes the kit's return spec both ways:
    // no overshoot, so it can never lighten the tile past full strength or dim
    // it below Tokens.focusDimMax.
    //
    // Not a SpringAnimation, and that is the repair: on Qt 6.12 the integrator
    // clamps `damping` to [0, 1] and applies the spring term without a dt
    // factor, so the analytic pairs this tile used to hand it (spring =
    // omega^2 = 278.89 and damping = 2 * zeta * omega = 23.05 on the way out,
    // 81 and 18 on the way back) are not the Motion states, they are barely
    // damped explicit Euler springs. Measured before the repair: the scale
    // reached 1.7e+39 within 1.4 s and 2.9e+35 on a 150 ms stalled frame, and
    // the dim was already at the floor 133 ms after its trigger instead of over
    // Motion.returnMillis. Numbers, closed form and probe:
    // v5/docs/w3-gauges-spring.md and v5/tools/w3-gauge-spring-trace.py.
    //
    // Easing.overshoot is the OutBack *parameter*, not Motion.expandOvershoot
    // (0.05, the analytic zeta peak). Requested as Motion.expandBackOvershoot.
    readonly property real expandBackOvershoot: 1.15
    readonly property real targetOpacity: 1 - tile.dimAmount * (1 - Tokens.focusDimMax)
    // The two numbers the tile is drawn at. Component.onCompleted snaps them to
    // their targets so a still is deterministic; after that the animations own
    // them, because one Behavior can hold only one curve and each channel needs
    // two directions.
    property real tileOpacity: 1.0
    property real tileScale: 1.0
    // Set by Component.onCompleted, after the snap. Nothing animates before it:
    // at creation the targets go from their declared defaults to the real values,
    // and without this guard a tile created already selected or already dimmed
    // (W5 sets focusLevel on every unselected tile) would animate in from full
    // strength instead of starting where it belongs.
    property bool motionReady: false

    Component.onCompleted: {
        tile.tileOpacity = tile.targetOpacity
        tile.tileScale = tile.restScale
        tile.motionReady = true
    }

    onTargetOpacityChanged: {
        if (!tile.motionReady)
            return
        fade.stop()
        fade.to = tile.targetOpacity
        fade.restart()
    }

    onRestScaleChanged: {
        if (!tile.motionReady)
            return
        var up = tile.restScale > tile.tileScale
        grow.stop()
        settle.stop()
        var anim = up ? grow : settle
        anim.to = tile.restScale
        anim.restart()
    }

    NumberAnimation {
        id: grow
        target: tile
        property: "tileScale"
        duration: Motion.expandMillis
        easing.type: Easing.OutBack
        easing.overshoot: tile.expandBackOvershoot
    }

    NumberAnimation {
        id: settle
        target: tile
        property: "tileScale"
        duration: Motion.returnMillis
        easing.type: Easing.OutCubic
    }

    NumberAnimation {
        id: fade
        target: tile
        property: "tileOpacity"
        duration: Motion.returnMillis
        easing.type: Easing.OutCubic
    }

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    transformOrigin: Item.Center

    // dim is one mechanism: the whole tile fades, no element recolours.
    opacity: tile.tileOpacity

    // Selected is scale only: the tile grows to selectedScale and returns to
    // 1.0. No box, no outline, no plate, no colour or weight change.
    scale: tile.tileScale

    // launch-count ring: one round node per launch, clockwise from the top
    Shape {
        anchors.fill: parent
        visible: tile.ringLit > 0
        // Curve renderer keeps the dashed arc clean at every tile size. The
        // 0.001 dash epsilon and the 0.5 deg sweep trim are pattern maths, not
        // design values.
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: Tokens.ice
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
        weight: tile.glyphWeight
        size: tile.glyphBox
        color: Tokens.ink
    }

    // running node: one accent dot, slow breath, never still
    Shape {
        id: runNode
        visible: tile.running
        width: tile.runDot
        height: tile.runDot
        x: tile.size * tile.runNodeX - width / 2
        y: tile.size * tile.runNodeY - height / 2
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
        // opacity runs 1.0 to breathFloor and back: full strength, then the
        // pulse. 1.0 is the property's own ceiling, not a design value.
        SequentialAnimation on opacity {
            running: tile.running
            loops: Animation.Infinite
            NumberAnimation {
                from: 1.0
                to: tile.breathFloor
                duration: Motion.breathPeriod * 1000 * Motion.breathInhale
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: tile.breathFloor
                to: 1.0
                duration: Motion.breathPeriod * 1000 * Motion.breathExhale
                easing.type: Easing.InOutSine
            }
        }
    }

    Text {
        visible: tile.label.length > 0
        width: tile.size * tile.labelBoxWidth
        anchors.horizontalCenter: parent.horizontalCenter
        y: tile.size - height - tile.size * tile.labelBottomGap
        text: tile.label
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: Tokens.textLabel
        font.pixelSize: tile.labelSize
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.letterSpacing: tile.labelSize * Tokens.trackName
        // ProportionalHeight is a multiple of the font's own line box, so the
        // number scales with the label and never means pixels: 1.0 is one
        // natural line, 20 px at the 16 px label. FixedHeight would read it as
        // a pixel count.
        lineHeight: tile.labelLineHeight
        lineHeightMode: Text.ProportionalHeight
    }
}
