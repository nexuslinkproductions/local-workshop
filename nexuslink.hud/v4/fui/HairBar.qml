pragma ComponentBehavior: Bound

import QtQuick
import ".."

// HairBar.qml — hairline bar with min/max whiskers (M1 ladder bars).
// Banned: spreadsheet-style filled bars. This is a 1px track + a thin value
// line + whisker ticks at observed min/max + end caps — never a fill.
Item {
    id: root

    property var value: null        // null -> no value line, reads "—"
    property real minimum: 0
    property real maximum: 100
    property var minMark: null      // observed-min whisker (value units)
    property var maxMark: null      // observed-max whisker
    property color color: FuiTokens.ice
    property bool live: false       // value line -> acid
    property string unit: ""
    property int trackH: 9          // whisker height; line sits centred

    implicitWidth: 120
    implicitHeight: trackH

    function xOf(v) {
        var f = root.maximum > root.minimum
              ? (v - root.minimum) / (root.maximum - root.minimum) : 0;
        return Math.min(1, Math.max(0, f)) * (width - 1);
    }

    // 0 -> value segment (a line, not a fill)
    Rectangle {
        visible: root.value !== null && isFinite(Number(root.value))
        x: 0
        y: Math.round(root.trackH / 2)
        width: root.xOf(Number(root.value)) + 1
        height: 2
        color: root.live ? FuiTokens.acid : root.color
    }
    // track to maximum
    Rectangle {
        x: 0
        y: Math.round(root.trackH / 2) + 1
        width: parent.width
        height: 1
        color: FuiTokens.hair3
    }
    // end caps at 0 and max
    Rectangle { x: 0; y: 1; width: 1; height: root.trackH - 2; color: FuiTokens.hair2 }
    Rectangle { x: parent.width - 1; y: 1; width: 1; height: root.trackH - 2; color: FuiTokens.hair2 }
    // observed min/max whiskers
    Rectangle {
        visible: root.minMark !== null && isFinite(Number(root.minMark))
        x: root.xOf(Number(root.minMark))
        y: 0
        width: 1
        height: root.trackH
        color: FuiTokens.dim
    }
    Rectangle {
        visible: root.maxMark !== null && isFinite(Number(root.maxMark))
        x: root.xOf(Number(root.maxMark))
        y: 0
        width: 1
        height: root.trackH
        color: FuiTokens.dim
    }
    // value tick
    Rectangle {
        visible: root.value !== null && isFinite(Number(root.value))
        x: root.xOf(Number(root.value))
        y: 0
        width: 1
        height: root.trackH
        color: root.live ? FuiTokens.acid : root.color
    }
}
