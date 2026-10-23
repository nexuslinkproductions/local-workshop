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
    property real size: referenceSize
    property real focusLevel: 0
    property bool showValue: false
    property string label: ""

    implicitWidth: size
    implicitHeight: size + textBlock

    // s2 study scale, not a measured cap (see v5/fixtures/metrics.json).
    readonly property real budgetGb: Tokens.localBudgetGb
    // s2 build.py:109-113 draws the LOCAL sphere at radius 72; 68 keeps the
    // outermost depth dot inside the 144 px box (2 * 72).
    readonly property real referenceSize: Tokens.localOrbSize
    readonly property real referenceRadius: Tokens.localOrbRadius
    // W3 brief radius mapping: the 0.45 floor keeps a small model readable at
    // deck distance, and the remaining 0.55 carries the size.
    readonly property real radiusFloor: Tokens.orbRadiusFloor
    readonly property real radiusSpan: Tokens.orbRadiusSpan

    readonly property real fraction: Math.max(0, Math.min(1, sizeGb / budgetGb))
    readonly property real radiusFraction: radiusFloor + radiusSpan * Math.cbrt(fraction)
    readonly property real scaleToWidget: artDiameter / referenceSize
    readonly property real orbRadius: referenceRadius * radiusFraction * scaleToWidget

    // Dot count from the s2 fib sphere (build.py:66-73), scaled by radius
    // squared; 56 dots is the floor that keeps a small orb a sphere, not a bead.
    readonly property int dotDensity: Tokens.orbDotDensity
    readonly property int minDotCount: Tokens.orbMinDots
    // s2 build.py:66 tilts the fib sphere 0.5 rad on the y axis (Tokens.orbTilt,
    // hoisted by I1; W3 asked for the token).
    readonly property real fibonacciTilt: Tokens.orbTilt
    readonly property int dotCount: Math.max(minDotCount,
                                             Math.round(dotDensity * radiusFraction * radiusFraction))
    readonly property var points: root.fibonacci(dotCount, fibonacciTilt)

    readonly property real textBlock: !showValue
        ? 0
        : Tokens.sp1 + Tokens.sizeLabel + (label !== "" ? Tokens.sp1 + Tokens.sizeCaption : 0)
    readonly property real artDiameter: size
    readonly property string valueText: sizeGb.toFixed(2) + " GB"

    readonly property real focusAmount: Math.max(0, Math.min(1, focusLevel))
    // Activity clamped once, the way focusAmount clamps focusLevel.
    readonly property real activityAmount: Math.max(0, Math.min(1, activity))

    // ---- motion ------------------------------------------------------------
    // Expand in on the wave's measured curve, return out on the slower one:
    // OutBack at peak 1.04871 (4.87 percent, inside Motion.expandOvershoot's 4
    // to 6 band) over Motion.expandMillis, OutCubic over Motion.returnMillis
    // with no overshoot.
    //
    // Not a SpringAnimation, and that is the repair: on Qt 6.12 the integrator
    // clamps damping to 1 and applies the spring term without a dt factor, so
    // the analytic pair the four gauges used to hand it (spring = expandOmega^2
    // = 278.89, damping = 2 * expandZeta * omega = 23.05) is not the 5.00
    // percent / 347 ms Motion states. Measured with this component at 200 px:
    // 1.0 -> 4.40 in 60 ms and 1.9e+38 within 1.4 s on the first change of
    // either input, no late frame required; a 150 ms stalled frame is no worse.
    // Numbers, trace and the stalled-frame note: v5/docs/w3-localorb-spring.md,
    // probe: v5/tests/w3 (tools/w3-localorb-trace.py).
    readonly property real expandOvershoot: 1.15   // OutBack parameter, peak 1.04871
    readonly property real targetScale: (1 + root.activityLift * root.activityAmount)
                                        * (1 + root.focusLift * root.focusAmount)
    // The one number the sphere field is drawn at. Component.onCompleted snaps
    // it to the target so a still is deterministic; after that the two
    // animations own it, because a spring on a Behavior here would have to pick
    // one curve for both directions.
    property real fieldScale: 1.0

    Component.onCompleted: root.fieldScale = root.targetScale

    onTargetScaleChanged: {
        var up = root.targetScale > root.fieldScale
        grow.stop()
        settle.stop()
        var anim = up ? grow : settle
        anim.to = root.targetScale
        anim.restart()
    }

    NumberAnimation {
        id: grow
        target: root
        property: "fieldScale"
        duration: Motion.expandMillis
        easing.type: Easing.OutBack
        easing.overshoot: root.expandOvershoot
    }

    NumberAnimation {
        id: settle
        target: root
        property: "fieldScale"
        duration: Motion.returnMillis
        easing.type: Easing.OutCubic
    }

    // ---- design values ---------------------------------------------------
    // Hoisted to Tokens by I1 (Wave 2): every number below now reads its token,
    // so the value lives in kit/Tokens.qml. The named properties stay, so this
    // component's own code and its probes are unchanged.
    // Activity lift: the sphere grows 8 percent at full activity, and the
    // field alpha runs 0.62 to 1.0 so a busy model reads brighter.
    readonly property real activityLift: Tokens.activityLift
    readonly property real activityAlphaBase: Tokens.activityAlphaBase
    readonly property real activityAlphaGain: Tokens.activityAlphaGain
    // Focus band: the gauge lifts 4 percent on a spring (all four gauges).
    readonly property real focusLift: Tokens.focusLift
    // Activity core: one dot, 4 px at rest and 18 px at full activity, alpha
    // 0.10 to 0.95.
    readonly property real coreSizeMin: Tokens.orbCoreSize
    readonly property real coreSizeGain: Tokens.orbCoreSizeGain
    readonly property real coreAlphaMin: Tokens.orbCoreAlpha
    readonly property real coreAlphaGain: Tokens.orbCoreAlphaGain
    // Motion.curveInOut is a 4-value list, and Qt 6.12 evaluates a 4-value
    // bezierCurve as linear (probe: 220 of 1000 at 225 ms). The brief's
    // 6-value form carries the curve; [1.0, 1.0] closes the spline.
    readonly property var breathCurve: Motion.curveInOut6

    // s2 build.py:73: dot radius 1.0 + 2.5 per unit of depth, alpha 0.28 + 0.72.
    readonly property real dotRadiusBase: Tokens.orbDotRadiusBase
    readonly property real dotRadiusDepthGain: Tokens.orbDotRadiusDepthGain
    readonly property real dotAlphaBase: Tokens.orbDotAlphaBase
    readonly property real dotAlphaDepthGain: Tokens.orbDotAlphaDepthGain

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
                         "radius": (dotRadiusBase + dotRadiusDepthGain * depth) * scaleToWidget,
                         "alpha": dotAlphaBase + dotAlphaDepthGain * depth
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
                    easing.bezierCurve: root.breathCurve
                }
                NumberAnimation {
                    target: breathField
                    property: "scale"
                    from: 1.0 + Motion.breathScale
                    to: 1.0 - Motion.breathScale
                    duration: Math.round(Motion.breathPeriod * 1000 / 2)
                    easing.type: Easing.Bezier
                    easing.bezierCurve: root.breathCurve
                }
            }

            Item {
                id: radiusField
                anchors.centerIn: parent
                width: 0
                height: 0
                // One animated number (see the motion section): expand on the
                // wave's OutBack curve, return on Motion.returnMillis.
                scale: root.fieldScale
                opacity: root.activityAlphaBase + root.activityAlphaGain * root.activityAmount

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
                width: root.coreSizeMin + root.coreSizeGain * root.activityAmount
                height: width
                radius: width / 2
                color: root.accent
                opacity: root.coreAlphaMin + root.coreAlphaGain * root.activityAmount
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
