pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// LocalOrb.qml - the local model as a dot sphere. The sphere radius carries
// the model size, the field breathes slowly all the time and activity lifts
// brightness, a centre core and 8 percent of radius. No text unless showValue.
//
// Card API (W3): sizeGb, activity 0..1, accent, size, showValue, label, and the
// 0..1 focus amount (spelled focusLevel, because QQuickItem::focus is FINAL in
// Qt 6.12).
//
// Dot language and geometry follow the approved s2 reference,
// hud-candidates/comp-r1/s2/src/build.py:67-74 (fibonacci sphere, depth drives
// dot size and alpha: radius 1.0 + 2.5k, alpha 0.28 + 0.72k at a 72 px sphere)
// and build.py:109-113 (the LOCAL widget is the same sphere at radius 72 with
// the budget ring outside it). The budget ring is DotArc.qml in this kit; the
// orb alone carries the size.
//
// Radius mapping: fraction = sizeGb / budgetGb, radius = 0.45 + 0.55 * cbrt(fraction).
// The cube root is the volume honest mapping (a sphere whose volume follows the
// bytes), and the 0.45 floor keeps a small model readable at deck distance; the
// remaining 55 percent carries the size. The s2 study's 4.0 GB budget is not a
// measured cap, so it is a local constant here and requested as
// Tokens.localBudgetGb.
//
// Dot count follows the radius so density stays at the s2 figure instead of
// turning a small orb into a solid bead. The Repeater only rebuilds when the
// rounded count changes, which is a feed write, never a frame.
Item {
    id: root

    property real sizeGb: 0
    property real activity: 0
    property color accent: Tokens.acid
    property real size: 144
    property real focusLevel: 0
    property bool showValue: false
    property string label: ""

    implicitWidth: size
    implicitHeight: size + textBlock

    // s2 study scale, not a measured cap (see v5/fixtures/metrics.json).
    readonly property real budgetGb: 4.0
    readonly property real referenceSize: 144
    readonly property real referenceRadius: 68

    readonly property real fraction: Math.max(0, Math.min(1, sizeGb / budgetGb))
    readonly property real radiusFraction: 0.45 + 0.55 * Math.cbrt(fraction)
    readonly property real scaleToWidget: artDiameter / referenceSize
    readonly property real orbRadius: referenceRadius * radiusFraction * scaleToWidget

    readonly property int dotCount: Math.max(56, Math.round(360 * radiusFraction * radiusFraction))
    readonly property var points: root.fibonacci(dotCount, 0.5)

    readonly property real textBlock: !showValue
        ? 0
        : Tokens.sp1 + Tokens.sizeLabel + (label !== "" ? Tokens.sp1 + Tokens.sizeCaption : 0)
    readonly property real artDiameter: size
    readonly property string valueText: sizeGb.toFixed(2) + " GB"

    readonly property real springStiffness: Motion.expandOmega * Motion.expandOmega
    readonly property real springDamping: 2 * Motion.expandZeta * Motion.expandOmega
    readonly property real focusAmount: Math.max(0, Math.min(1, focusLevel))

    // Unit sphere points with the s2 depth cues folded in. Positions are on the
    // unit sphere; the delegate multiplies by orbRadius.
    function fibonacci(count, tilt) {
        var out = []
        var golden = 2.399963229728653
        for (var i = 0; i < count; ++i) {
            var y = 1 - 2 * (i + 0.5) / count
            var ring = Math.sqrt(Math.max(0, 1 - y * y))
            var theta = i * golden
            var x = ring * Math.cos(theta)
            var z = ring * Math.sin(theta)
            var y2 = y * Math.cos(tilt) - z * Math.sin(tilt)
            var z2 = y * Math.sin(tilt) + z * Math.cos(tilt)
            var depth = (z2 + 1) / 2
            out.push({
                         "x": x,
                         "y": y2,
                         "radius": (1.0 + 2.5 * depth) * scaleToWidget,
                         "alpha": 0.28 + 0.72 * depth
                     })
        }
        return out
    }

    Item {
        id: art
        width: root.referenceSize
        height: root.referenceSize
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0

        // Breath: one slow cycle from Motion, amplitude Motion.breathScale,
        // ease in and out on the Motion curve. Never linear.
        Item {
            id: breathField
            anchors.centerIn: parent
            width: 0
            height: 0

            SequentialAnimation {
                running: true
                loops: Animation.Infinite
                NumberAnimation {
                    target: breathField
                    property: "scale"
                    from: 1.0 - Motion.breathScale
                    to: 1.0 + Motion.breathScale
                    duration: Math.round(Motion.breathPeriod * 1000 / 2)
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Motion.curveInOut
                }
                NumberAnimation {
                    target: breathField
                    property: "scale"
                    from: 1.0 + Motion.breathScale
                    to: 1.0 - Motion.breathScale
                    duration: Math.round(Motion.breathPeriod * 1000 / 2)
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Motion.curveInOut
                }
            }

            Item {
                id: radiusField
                anchors.centerIn: parent
                width: 0
                height: 0
                scale: (1 + 0.08 * Math.max(0, Math.min(1, root.activity))) * (1 + 0.04 * root.focusAmount)
                opacity: 0.62 + 0.38 * Math.max(0, Math.min(1, root.activity))

                Behavior on scale {
                    SpringAnimation {
                        spring: root.springStiffness
                        damping: root.springDamping
                        mass: 1.0
                    }
                }

                Repeater {
                    model: root.points

                    Rectangle {
                        required property var modelData
                        readonly property real dotDiameter: modelData.radius * 2

                        width: dotDiameter
                        height: dotDiameter
                        radius: dotDiameter / 2
                        x: modelData.x * root.orbRadius - dotDiameter / 2
                        y: modelData.y * root.orbRadius - dotDiameter / 2
                        color: root.accent
                        opacity: modelData.alpha
                        antialiasing: true
                    }
                }
            }

            // Activity core: one dot that grows and brightens with the model
            // load, the same grammar as a session core in the crew orb.
            Rectangle {
                anchors.centerIn: parent
                width: 4 + 14 * Math.max(0, Math.min(1, root.activity))
                height: width
                radius: width / 2
                color: root.accent
                opacity: 0.1 + 0.85 * Math.max(0, Math.min(1, root.activity))
                antialiasing: true
            }
        }
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.artDiameter + Tokens.sp1
        spacing: Tokens.sp1
        visible: root.showValue

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.label !== ""
            text: root.label
            color: Tokens.textLabel
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightBold
            font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.valueText
            color: Tokens.ink
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeLabel
            font.weight: Tokens.weightMedium
        }
    }
}
