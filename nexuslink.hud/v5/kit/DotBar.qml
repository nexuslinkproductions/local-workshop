pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// DotBar.qml - CPU load as a dot bar. Round points in one row, filled to
// `level`; the lit dots are bigger and brighter than the rest, so the bar reads
// at a glance without a track or a box.
//
// Card API (W3): level 0..1, segments (int), accent, size, showValue, label,
// and the 0..1 focus amount (spelled focusLevel, because QQuickItem::focus is
// FINAL in Qt 6.12).
//
// Geometry from the approved s2 reference,
// hud-candidates/comp-r1/s2/src/build.py:103-104: 12 dots on an 11 px pitch
// across 132 px, lit radius 2.9 and unlit 2.2, lit at full alpha and unlit at
// 0.16. Sizes here are derived from `size / segments`, so a bar of another
// length keeps the s2 ratio (dot diameter 0.53 of the pitch when lit, 0.40 when
// not).
//
// Level changes animate with one NumberAnimation over Motion.returnMillis.
// Nothing else animates.
Item {
    id: root

    property real level: 0
    property int segments: referenceSegments
    property color accent: Tokens.acid
    property real size: referenceSize
    property real focusLevel: 0
    property bool showValue: false
    property string label: ""

    // s2 build.py:103-104: 12 dots on an 11 px pitch, 132 px across.
    readonly property int referenceSegments: Tokens.dotBarSegments
    readonly property real referenceSize: Tokens.dotBarSize
    readonly property int pitchCount: Math.max(1, segments)
    readonly property real pitch: size / pitchCount
    // s2 build.py:105 draws radii 2.9 and 2.2 on the 11 px pitch, so the dot
    // diameters are 0.53 and 0.40 of the pitch.
    readonly property real litDiameterShare: Tokens.dotLitShare
    readonly property real dimDiameterShare: Tokens.dotDimShare
    // The bar box runs 10 percent taller than the lit dot: headroom over the
    // row, so the dots sit inside a box and not on a line.
    readonly property real barHeightHeadroom: Tokens.barHeightHeadroom
    readonly property real litDiameter: pitch * litDiameterShare
    readonly property real dimDiameter: pitch * dimDiameterShare
    readonly property real barHeight: litDiameter * barHeightHeadroom

    // ---- design values ---------------------------------------------------
    // Hoisted to Tokens by I1 (Wave 2): every number below now reads its token,
    // so the value lives in kit/Tokens.qml. The named properties stay, so this
    // component's own code and its probes are unchanged.
    // Focus band: the gauge lifts 4 percent on a spring (all four gauges).
    readonly property real focusLift: Tokens.focusLift
    // s2 build.py:104 draws lit dots at full alpha and unlit at 0.16; focus
    // lifts the unlit ones so a dimmed gauge still reads.
    readonly property real litAlpha: Tokens.dotLitBar
    readonly property real unlitAlpha: Tokens.dotDimBar
    readonly property real unlitFocusGain: Tokens.dotDimFocusGain

    readonly property real textBlock: !showValue
        ? 0
        : Tokens.sp1 + Tokens.sizeLabel + (label !== "" ? Tokens.sp1 + Tokens.sizeCaption : 0)

    implicitWidth: size
    implicitHeight: barHeight + textBlock

    property real shownLevel: Math.max(0, Math.min(1, level))
    Behavior on shownLevel {
        NumberAnimation {
            duration: Motion.returnMillis
            easing.type: Easing.InOutQuad
        }
    }
    readonly property int litDots: Math.round(pitchCount * shownLevel)

    readonly property string valueText: Math.round(shownLevel * 100) + " %"
    readonly property real focusAmount: Math.max(0, Math.min(1, focusLevel))

    // ---- motion ----------------------------------------------------------
    // The focus lift runs the wave's measured curve, not a Qt spring: expand in
    // on Easing.OutBack at parameter 1.15 (peak 1.04871 = 4.87 percent, inside
    // Motion.expandOvershoot's 4 to 6 band) over Motion.expandMillis, return out
    // on Easing.OutCubic over Motion.returnMillis with no overshoot.
    //
    // Not a SpringAnimation, and that is the repair: on Qt 6.12 the integrator
    // clamps `damping` to [0, 1] and applies the spring term without a dt
    // factor, so the analytic pair this bar used to hand it inline (spring =
    // Motion.expandOmega^2 = 278.89, damping = 2 * Motion.expandZeta *
    // Motion.expandOmega = 23.05) is not the 5.00 percent / 347 ms Motion
    // states, it is a barely damped explicit Euler spring that diverges on the
    // first change of focusLevel. Measured before the repair: 1.0 to 1.13e+39
    // within 1.4 s and 1.6e+34 on a 150 ms stalled frame. Numbers, closed form
    // and probe: v5/docs/w3-gauges-spring.md and
    // v5/tools/w3-gauge-spring-trace.py.
    //
    // Easing.overshoot is the OutBack *parameter*, not Motion.expandOvershoot
    // (0.05, the analytic zeta peak). Requested as Motion.expandBackOvershoot.
    readonly property real expandBackOvershoot: 1.15
    readonly property real targetScale: 1 + root.focusLift * root.focusAmount
    // The one number the bar is drawn at. Component.onCompleted snaps it to the
    // target so a still is deterministic; after that the two animations own it,
    // because one Behavior can hold only one curve and this needs two (a lift up
    // and a slower settle down).
    property real barScale: 1.0
    // Set by Component.onCompleted, after the snap. Nothing animates before it:
    // at creation targetScale goes from its declared default to the real value,
    // and without this guard a bar created with a non-zero focusLevel would run
    // a settle from 1.0 down to its resting scale on the first frames.
    property bool motionReady: false

    Component.onCompleted: {
        root.barScale = root.targetScale
        root.motionReady = true
    }

    onTargetScaleChanged: {
        if (!root.motionReady)
            return
        var up = root.targetScale > root.barScale
        grow.stop()
        settle.stop()
        var anim = up ? grow : settle
        anim.to = root.targetScale
        anim.restart()
    }

    NumberAnimation {
        id: grow
        target: root
        property: "barScale"
        duration: Motion.expandMillis
        easing.type: Easing.OutBack
        easing.overshoot: root.expandBackOvershoot
    }

    NumberAnimation {
        id: settle
        target: root
        property: "barScale"
        duration: Motion.returnMillis
        easing.type: Easing.OutCubic
    }

    Item {
        id: bar
        width: root.size
        height: root.barHeight
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        scale: root.barScale
        transformOrigin: Item.Center

        Repeater {
            model: root.pitchCount

            Rectangle {
                required property int index
                readonly property bool lit: index < root.litDots
                readonly property real dotDiameter: lit ? root.litDiameter : root.dimDiameter

                width: dotDiameter
                height: dotDiameter
                radius: dotDiameter / 2
                x: (index + 0.5) * root.pitch - dotDiameter / 2
                y: (root.barHeight - dotDiameter) / 2
                color: root.accent
                opacity: lit ? root.litAlpha : root.unlitAlpha + root.unlitFocusGain * root.focusAmount
                antialiasing: true
            }
        }
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.barHeight + Tokens.sp1
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
