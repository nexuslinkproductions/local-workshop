pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// DotArc.qml - battery as a dot arc. Round points on a 310 degree arc, open at
// the bottom, filled from the left end to `level`. No outlines, no caps and no
// ring line: the dots are the gauge.
//
// Card API (W3): level 0..1, accent, size, showValue, label, and the 0..1 focus
// amount (spelled focusLevel, because QQuickItem::focus is FINAL in Qt 6.12).
//
// Geometry from the approved s2 reference,
// hud-candidates/comp-r1/s2/src/build.py:101-102: 28 dots on radius 104 of a
// 216 px box, dot radius 3.6, start 115 degrees, span 310 degrees, lit dots at
// full alpha and unlit at 0.2. The bottom opening leaves the gap for the load
// bar, which is DotBar.qml in this kit.
//
// Level changes animate with one NumberAnimation over Motion.returnMillis
// (softer, slower than the expand spring). Nothing else animates.
Item {
    id: root

    property real level: 0
    property color accent: Tokens.acid
    property real size: 216
    property real focusLevel: 0
    property bool showValue: false
    property string label: ""

    implicitWidth: size
    implicitHeight: size + textBlock

    readonly property real referenceSize: 216
    readonly property int dots: 28
    readonly property real arcRadius: 104
    readonly property real dotRadius: 3.6
    readonly property real startDegrees: 115
    readonly property real spanDegrees: 310

    // One animation owns level changes. The feed writes `level`, this property
    // follows it through a single NumberAnimation.
    property real shownLevel: Math.max(0, Math.min(1, level))
    Behavior on shownLevel {
        NumberAnimation {
            duration: Motion.returnMillis
            easing.type: Easing.InOutQuad
        }
    }
    readonly property int litDots: Math.round(dots * shownLevel)

    readonly property real textBlock: !showValue
        ? 0
        : Tokens.sp1 + Tokens.sizeLabel + (label !== "" ? Tokens.sp1 + Tokens.sizeCaption : 0)
    readonly property real artDiameter: size
    readonly property string valueText: Math.round(shownLevel * 100) + " %"

    readonly property real springStiffness: Motion.expandOmega * Motion.expandOmega
    readonly property real springDamping: 2 * Motion.expandZeta * Motion.expandOmega

    Item {
        id: art
        width: root.referenceSize
        height: root.referenceSize
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        scale: root.artDiameter / root.referenceSize

        Behavior on scale {
            SpringAnimation {
                spring: root.springStiffness
                damping: root.springDamping
                mass: 1.0
            }
        }

        Repeater {
            model: root.dots

            Rectangle {
                required property int index
                readonly property real angle: (root.startDegrees
                                               + root.spanDegrees * index / (root.dots - 1))
                                              * Math.PI / 180
                readonly property real dotDiameter: root.dotRadius * 2
                readonly property bool lit: index < root.litDots

                width: dotDiameter
                height: dotDiameter
                radius: dotDiameter / 2
                x: root.referenceSize / 2 + Math.cos(angle) * root.arcRadius - dotDiameter / 2
                y: root.referenceSize / 2 + Math.sin(angle) * root.arcRadius - dotDiameter / 2
                color: root.accent
                opacity: lit ? 0.95 : 0.18 + 0.14 * root.focusLevel
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
