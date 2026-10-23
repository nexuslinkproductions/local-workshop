pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// LauncherArc.qml - the v5 launcher band, 1180 x 120.
// Deck places it at x 700, y 1230. Tile centres in local coordinates:
//   x_i = 22 + 116 * i for i = 0..8, Arc Raiders at x = 1134 with base scale 1.3
//   y_i = 78 - 48 * ((x_i + 700 - 1280) / 560)^2      (smile, ends higher)
// Hover is a bell over the base centres: 1 + 0.9 * exp(-0.9 * ((x_i - hoverX)/116)^2).
// One full-bounds MouseArea, per-tile hit test by x distance.
Item {
    id: root

    property var apps: []
    property real tick: 0
    signal launchRequested(var app)
    // Tests only: forces the hovered tile index and freezes it there.
    property int hoverIndexOverride: -1

    width: 1180
    height: 120

    readonly property var list: apps ? apps : []
    readonly property int count: list.length
    readonly property bool hovered: area.containsMouse || hoverIndexOverride >= 0
    property int hoveredIndex: -1
    readonly property int hoverIndex: hoverIndexOverride >= 0 ? hoverIndexOverride : hoveredIndex
    // Animated centre of the bell, 160 ms OutCubic.
    property real hoverX: hoverIndex >= 0 ? baseX(hoverIndex) : -10000

    Behavior on hoverX {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    function baseX(i) {
        return i === 9 ? 1134 : 22 + 116 * i
    }
    function arcY(i) {
        var g = baseX(i) + 700
        var k = (g - 1280) / 560
        return 78 - 48 * k * k
    }
    function baseScale(i) {
        return i === 9 ? 1.3 : 1
    }
    function tileScale(i) {
        if (!hovered || hoverIndex < 0) return baseScale(i)
        var d = (baseX(i) - hoverX) / 116
        return baseScale(i) * (1 + 0.9 * Math.exp(-0.9 * d * d))
    }
    function nearestIndex(mx) {
        var best = -1
        var bd = 1e9
        for (var i = 0; i < count; i++) {
            var d = Math.abs(mx - baseX(i))
            if (d < bd) { bd = d; best = i }
        }
        return best
    }

    Repeater {
        model: root.count
        delegate: IconTile {
            required property int index
            app: root.list[index]
            launches: app && app.launches ? app.launches : 0
            x: root.baseX(index) - 32
            // idle drift 1 to 2 px, each tile phase = index * 0.6
            y: root.arcY(index) - 32 + (1.5 + 0.5 * Math.sin(root.tick * 0.8 + index * 0.6))
            scale: root.tileScale(index)
            Behavior on scale {
                NumberAnimation {
                    duration: root.hovered ? 347 : 444
                    easing.type: root.hovered ? Easing.OutBack : Easing.InOutQuad
                    easing.overshoot: 1.22
                }
            }
        }
    }

    // Name of the hovered app, under its tile, uppercase label.
    Text {
        id: hoverLabel
        visible: opacity > 0.01
        opacity: root.hovered && root.hoverIndex >= 0 && root.hoverIndex < root.count ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        text: visible || opacity > 0.01 ? String(root.list[root.hoverIndex].name).toUpperCase() : ""
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeLabel
        font.weight: 500
        font.letterSpacing: Tokens.trackLabel * Tokens.sizeLabel
        x: Math.max(4, Math.min(root.width - width - 4, root.baseX(root.hoverIndex) - width / 2))
        y: root.arcY(root.hoverIndex) + 64
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onPositionChanged: (mouse) => root.hoveredIndex = root.nearestIndex(mouse.x)
        onExited: root.hoveredIndex = -1
        onClicked: {
            if (root.hoverIndex >= 0 && root.hoverIndex < root.count)
                root.launchRequested(root.list[root.hoverIndex])
        }
    }
}
