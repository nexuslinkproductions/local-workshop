pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// LauncherArc.qml - the v5 launcher band, 1380 x 120.
//
// SYMMETRY (round 3, Marcel: "the app icons are not spaced equally, arc
// raiders is further on the side ... two elements on the left and three on
// the right"). The band is laid out about one centre slot:
//   * the hero (the app whose size is "feature", base scale 1.3) sits at the
//     exact centre slot, deck x 1280;
//   * the first half of the other apps goes to its left, the second half to
//     its right, list order kept;
//   * equal pitch 116 px between every pair of neighbouring tile centres;
//   * N apps each side: 2N + 1 slots, so every slot has a mirror twin.
// An odd number of non hero apps leaves one out (floor(n/2) per side) and
// warns once by name; the group is never unbalanced.
//
// DECK PLACEMENT: DeckView puts this item at x = 1280 - width/2, so the local
// centre line (width/2) is deck x 1280. slotX() is local; deckX() adds the
// item's own x. Keep those two in step if the item is ever nested deeper.
//
// The smile: y_i = 78 - 48 k^2 with k = (deck x_i - 1280) / 560, so the arc is
// centred on the same line and ends higher. Hover is a bell over the slots:
// 1 + 0.9 * exp(-0.9 * ((x_i - hoverX)/116)^2), mirror symmetric because the
// slots are. One full-bounds MouseArea, per-tile hit test by x distance.
Item {
    id: root

    property var apps: []
    property real tick: 0
    signal launchRequested(var app)
    // Tests only: forces the hovered tile index and freezes it there.
    property int hoverIndexOverride: -1

    readonly property int pitch: 116
    readonly property real heroScale: 1.3
    readonly property real arcCentreX: 1280
    readonly property real arcSpan: 560

    width: 1380
    height: 120

    // ---- layout (pure functions, no state) --------------------------------
    function appList(src) {
        return src && src.length !== undefined ? src : []
    }
    // Index of the hero in the source list, -1 when no app is size "feature".
    function heroIndexOf(src) {
        var a = appList(src)
        for (var i = 0; i < a.length; i++) {
            if (a[i] && String(a[i].size) === "feature")
                return i
        }
        return -1
    }
    function othersOf(src) {
        var a = appList(src)
        var h = heroIndexOf(a)
        var out = []
        for (var i = 0; i < a.length; i++) {
            if (i !== h)
                out.push(a[i])
        }
        return out
    }
    // Display order: first half of the others, the hero, the second half.
    function layoutOrder(src) {
        var a = appList(src)
        var h = heroIndexOf(a)
        var others = othersOf(a)
        if (h < 0)
            return others
        var m = Math.floor(others.length / 2)
        var out = []
        for (var l = 0; l < m; l++)
            out.push(others[l])
        out.push(a[h])
        for (var r = m; r < 2 * m; r++)
            out.push(others[r])
        return out
    }
    // The app left out when the others count is odd, else null.
    function droppedApp(src) {
        if (heroIndexOf(src) < 0)
            return null
        var others = othersOf(src)
        if (others.length % 2 === 0)
            return null
        return others[others.length - 1]
    }

    readonly property var list: appList(apps)
    readonly property var ordered: layoutOrder(list)
    readonly property int count: ordered.length
    readonly property int centreIndex: Math.floor(ordered.length / 2)
    // The hero's slot in the laid out (display) order; equals centreIndex.
    readonly property int heroIndexInList: heroIndexOf(ordered)
    // Named app that could not be placed; logged once per apps change.
    readonly property var dropped: droppedApp(list)

    onAppsChanged: {
        var d = droppedApp(apps)
        if (d)
            console.warn("LauncherArc: odd non hero count, dropped " + String(d.name))
    }

    // Local centre x of display slot i.
    function slotX(i) {
        return width / 2 + pitch * (i - centreIndex)
    }
    // Deck x of display slot i (the item sits directly in deck coordinates).
    function deckX(i) {
        return root.x + slotX(i)
    }
    function slotScale(i) {
        return i === heroIndexInList ? heroScale : 1
    }
    function arcY(i) {
        var k = (deckX(i) - arcCentreX) / arcSpan
        return 78 - 48 * k * k
    }
    // Idle drift 1 to 2 px; phase from the distance to the centre slot so
    // mirrored tiles drift in step.
    function driftY(i) {
        return 1.5 + 0.5 * Math.sin(tick * 0.8 + Math.abs(i - centreIndex) * 0.6)
    }

    readonly property bool hovered: area.containsMouse || hoverIndexOverride >= 0
    property int hoveredIndex: -1
    readonly property int hoverIndex: hoverIndexOverride >= 0 ? hoverIndexOverride : hoveredIndex
    // Animated centre of the bell, 160 ms OutCubic.
    property real hoverX: hoverIndex >= 0 ? slotX(hoverIndex) : -10000

    Behavior on hoverX {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    function tileScale(i) {
        if (!hovered || hoverIndex < 0) return slotScale(i)
        var d = (slotX(i) - hoverX) / pitch
        return slotScale(i) * (1 + 0.9 * Math.exp(-0.9 * d * d))
    }
    function nearestIndex(mx) {
        var best = -1
        var bd = 1e9
        for (var i = 0; i < count; i++) {
            var d = Math.abs(mx - slotX(i))
            if (d < bd) { bd = d; best = i }
        }
        return best
    }
    // Test handle: the IconTile at display slot i, or null.
    function tileAt(i) {
        for (var c = 0; c < children.length; c++) {
            var it = children[c]
            if (it && it.index === i && it.app !== undefined)
                return it
        }
        return null
    }

    Repeater {
        model: root.count
        delegate: IconTile {
            required property int index
            app: root.ordered[index]
            launches: app && app.launches ? app.launches : 0
            x: root.slotX(index) - 32
            y: root.arcY(index) - 32 + root.driftY(index)
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
        text: root.hoverIndex >= 0 && root.hoverIndex < root.count ? String(root.ordered[root.hoverIndex].name).toUpperCase() : ""
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeLabel
        font.weight: 500
        font.letterSpacing: Tokens.trackLabel * Tokens.sizeLabel
        x: Math.max(4, Math.min(root.width - width - 4, root.slotX(root.hoverIndex) - width / 2))
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
                root.launchRequested(root.ordered[root.hoverIndex])
        }
    }
}
