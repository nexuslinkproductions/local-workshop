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
    property int segments: 12
    property color accent: Tokens.acid
    property real size: 132
    property real focusLevel: 0
    property bool showValue: false
    property string label: ""

    readonly property int pitchCount: Math.max(1, segments)
    readonly property real pitch: size / pitchCount
    readonly property real litDiameter: pitch * 0.53
    readonly property real dimDiameter: pitch * 0.40
    readonly property real barHeight: litDiameter * 1.1

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

    Item {
        id: bar
        width: root.size
        height: root.barHeight
        anchors.horizontalCenter: parent.horizontalCenter
        y: 0
        scale: 1 + 0.04 * root.focusAmount
        transformOrigin: Item.Center

        Behavior on scale {
            SpringAnimation {
                spring: Motion.expandOmega * Motion.expandOmega
                damping: 2 * Motion.expandZeta * Motion.expandOmega
                mass: 1.0
            }
        }

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
                opacity: lit ? 1.0 : 0.16 + 0.14 * root.focusAmount
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
