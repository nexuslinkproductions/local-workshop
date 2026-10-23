pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// PulseRing.qml - the Mac link gauge. A ring of round dots that breathes at
// the measured round trip time. Silent at rest: no text unless showValue.
//
// Card API (W3): value (ms RTT), breath, accent, size, showValue, label, and
// the 0..1 focus amount. The focus property is spelled focusLevel because
// QQuickItem::focus is FINAL in Qt 6.12 and an Item root cannot declare a real
// with that name (the qmllint diagnostic and the load error are in the PR
// body).
//
// Geometry and colour come from the approved s2 reference,
// hud-candidates/comp-r1/s2/src/build.py:95-100: three concentric dot rings at
// radius 36 / 56 / 76 of a 156 px box, dot radii 2.6 / 2.1 / 1.6, ring alpha
// 0.9 / 0.5 / 0.24, pulse scale 0.94 to 1.07 and alpha 0.55 to 1.0 (the `pl`
// keyframes), each ring offset by a third of the period. The period is the s2
// RTT mapping at build.py:27:
//   max(0.6, 3.4 - log2(max(rtt, 5) / 5) * 0.8)
// 7.5 ms gives 2.932 s, the value in v5/fixtures/link.json. A reading of
// 100 ms or more switches the dots to amber (build.py:99).
//
// Focus band: focusLevel only lifts the gauge (4 percent, spring) and the ring
// alpha. It never dims anything, so a parent dim to 0.3 still reads.
Item {
    id: root

    property real value: 0
    property bool breath: true
    property color accent: Tokens.acid
    property real size: referenceSize
    property real focusLevel: 0
    property bool showValue: false
    property string label: ""

    implicitWidth: size
    implicitHeight: size + textBlock

    // The s2 reference box: outer ring radius 76 plus a 1.6 dot = 77.6, so the
    // art spans 155.2 px. Kept as the unit the radii below are expressed in.
    readonly property real referenceSize: 156
    readonly property bool hasReading: value > 0
    // s2 build.py:99 switches the dots to amber at an RTT of 100 ms or more.
    // Requested as Tokens.rttWarnMs.
    readonly property int warnMillis: 100
    readonly property color dotColor: value >= warnMillis ? Tokens.amber : accent

    // s2 build.py:27, the RTT period mapping max(0.6, 3.4 - log2(rtt / 5) * 0.8):
    // the period floor and the period at the 5 ms floor, in seconds, then the
    // slope per octave of RTT.
    readonly property real periodFloorS: 0.6
    readonly property real periodBaseS: 3.4
    readonly property real periodSlopeOctave: 0.8
    // The formula's own RTT floor: a reading under 5 ms counts as 5 ms, so the
    // same property feeds both max() calls.
    readonly property real rttFloorMs: 5
    // s2 build.py:27. Recomputed when value changes, never per frame.
    readonly property real pulsePeriod: hasReading
        ? Math.max(periodFloorS,
                   periodBaseS - Math.log(Math.max(value, rttFloorMs) / rttFloorMs)
                                / Math.LN2 * periodSlopeOctave)
        : 0
    readonly property int pulseMillis: Math.round(pulsePeriod * 1000)

    // ---- design values ---------------------------------------------------
    // Local to this component until the integrator promotes them; each one is
    // requested as a token in the PR body (W3). The rings table below keeps
    // the s2 geometry and ring alphas keyed per ring instead of one property
    // per value.
    // Focus band: the gauge lifts 4 percent on a spring (all four gauges).
    readonly property real focusLift: 0.04
    // Ring wrapper opacity: 0.90 while reading, plus 0.10 with focus; 0.45
    // when there is no reading at all.
    readonly property real ringAlphaBase: 0.90
    readonly property real ringAlphaFocusGain: 0.10
    readonly property real ringAlphaRest: 0.45
    // s2 `pl` keyframes, build.py:152: scale 0.94 to 1.07, opacity 0.55 to 1.
    readonly property real pulseScaleMin: 0.94
    readonly property real pulseScaleMax: 1.07
    readonly property real pulseAlphaMin: 0.55
    readonly property real pulseAlphaMax: 1.0
    // s2 build.py:99: the three rings sit a third of the period apart.
    readonly property int ringPhases: 3
    // Motion.curveInOut is a 4-value list, and Qt 6.12 evaluates a 4-value
    // bezierCurve as linear (probe: 220 of 1000 at 225 ms). The brief's
    // 6-value form carries the curve; [1.0, 1.0] closes the spline.
    readonly property var pulseCurve: [Motion.curveInOut[0], Motion.curveInOut[1],
                                       Motion.curveInOut[2], Motion.curveInOut[3], 1.0, 1.0]

    // Rings: radius and dot radius in reference px, alpha from s2.
    readonly property var rings: [
        { "radius": 36, "dots": 36, "dot": 2.6, "alpha": 0.90 },
        { "radius": 56, "dots": 48, "dot": 2.1, "alpha": 0.50 },
        { "radius": 76, "dots": 60, "dot": 1.6, "alpha": 0.24 }
    ]

    // Text reserves a band under the art. showValue grows the implicit height
    // by that band and never shrinks the art, so the gauge keeps its size and
    // the integrator can place a resting gauge by size alone.
    readonly property real textBlock: !showValue
        ? 0
        : Tokens.sp1 + Tokens.sizeLabel + (label !== "" ? Tokens.sp1 + Tokens.sizeCaption : 0)
    readonly property real artDiameter: size
    readonly property string valueText: hasReading ? Math.round(value) + " ms" : ""

    // Spring from the Motion tokens at mass 1: stiffness = omega^2,
    // damping = 2 * zeta * omega. Same conversion in all four gauges.
    readonly property real springStiffness: Motion.expandOmega * Motion.expandOmega
    readonly property real springDamping: 2 * Motion.expandZeta * Motion.expandOmega
    readonly property real focusAmount: Math.max(0, Math.min(1, focusLevel))

    Item {
        id: art
        width: root.referenceSize
        height: root.referenceSize
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        scale: (root.artDiameter / root.referenceSize) * (1 + root.focusLift * root.focusAmount)

        Behavior on scale {
            SpringAnimation {
                spring: root.springStiffness
                damping: root.springDamping
                mass: 1.0
            }
        }

        Repeater {
            model: root.rings

            Item {
                id: ringWrap
                anchors.centerIn: parent
                width: 0
                height: 0

                required property int index
                required property var modelData
                property var ring: modelData
                opacity: root.hasReading
                    ? root.ringAlphaBase + root.ringAlphaFocusGain * root.focusAmount
                    : root.ringAlphaRest

                Item {
                    id: ringField
                    anchors.centerIn: parent
                    width: 0
                    height: 0
                    // The ring waits at the pulse floor (the s2 paused
                    // keyframe) until its phase comes up, so a delayed ring
                    // never snaps from its default value to the animation's
                    // start value.
                    scale: root.pulseScaleMin
                    opacity: root.pulseAlphaMin

                    Repeater {
                        model: ringWrap.ring.dots

                        Rectangle {
                            required property int index
                            readonly property real angle: index / ringWrap.ring.dots * Math.PI * 2
                            readonly property real dotDiameter: ringWrap.ring.dot * 2

                            width: dotDiameter
                            height: dotDiameter
                            radius: dotDiameter / 2
                            x: Math.cos(angle) * ringWrap.ring.radius - dotDiameter / 2
                            y: Math.sin(angle) * ringWrap.ring.radius - dotDiameter / 2
                            color: root.dotColor
                            opacity: ringWrap.ring.alpha
                            antialiasing: true
                        }
                    }

                    // One pulse per ring, phase shifted by a third of the
                    // period (s2 animation-delay -k * period / 3). The pause
                    // runs once, before the loop: inside a ParallelAnimation
                    // it delays nothing. Easing is the Motion in-out curve in
                    // the 6-value form Qt 6.12 needs.
                    SequentialAnimation {
                        running: root.breath && root.hasReading

                        PauseAnimation {
                            duration: Math.round((root.rings.length - 1 - ringWrap.index)
                                                 * root.pulseMillis / root.ringPhases)
                        }

                        ParallelAnimation {
                            loops: Animation.Infinite

                            SequentialAnimation {
                                NumberAnimation {
                                    target: ringField
                                    property: "scale"
                                    from: root.pulseScaleMin
                                    to: root.pulseScaleMax
                                    duration: Math.round(root.pulseMillis / 2)
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: root.pulseCurve
                                }
                                NumberAnimation {
                                    target: ringField
                                    property: "scale"
                                    from: root.pulseScaleMax
                                    to: root.pulseScaleMin
                                    duration: Math.round(root.pulseMillis / 2)
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: root.pulseCurve
                                }
                            }
                            SequentialAnimation {
                                NumberAnimation {
                                    target: ringField
                                    property: "opacity"
                                    from: root.pulseAlphaMin
                                    to: root.pulseAlphaMax
                                    duration: Math.round(root.pulseMillis / 2)
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: root.pulseCurve
                                }
                                NumberAnimation {
                                    target: ringField
                                    property: "opacity"
                                    from: root.pulseAlphaMax
                                    to: root.pulseAlphaMin
                                    duration: Math.round(root.pulseMillis / 2)
                                    easing.type: Easing.Bezier
                                    easing.bezierCurve: root.pulseCurve
                                }
                            }
                        }

                        onStopped: {
                            ringField.scale = root.pulseScaleMin
                            ringField.opacity = root.pulseAlphaMin
                        }
                    }
                }
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
            visible: root.valueText !== ""
            text: root.valueText
            color: Tokens.ink
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeLabel
            font.weight: Tokens.weightMedium
        }
    }
}
