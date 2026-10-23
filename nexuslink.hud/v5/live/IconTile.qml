pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// IconTile.qml - one launcher glyph, 64 px box, no outline and no box.
// Solid ink glyph from assets/icons/<glyph>.svg, an optional acid dot when the
// app is running, and an optional ring of tiny dots for a real launch count
// (one dot per launch, capped at 12). Scale and drift are driven by LauncherArc.
Item {
    id: tile

    property var app: ({})
    property int launches: 0
    property real drift: 0

    implicitWidth: 64
    implicitHeight: 64
    width: 64
    height: 64

    readonly property bool running: app && app.running === true
    readonly property string glyph: app && app.glyph ? String(app.glyph) : ""
    readonly property int ringCount: Math.max(0, Math.min(launches, 12))

    // Launch-count ring: small ink dots, one per real launch, max 12.
    Repeater {
        model: tile.ringCount
        delegate: Rectangle {
            required property int index
            width: 3.4
            height: 3.4
            radius: 1.7
            color: Tokens.ink
            opacity: 0.62
            x: 32 + 37 * Math.cos((-90 + 360 * index / tile.ringCount) * Math.PI / 180) - width / 2
            y: 32 + 37 * Math.sin((-90 + 360 * index / tile.ringCount) * Math.PI / 180) - height / 2
        }
    }

    Image {
        id: glyphImage
        anchors.fill: parent
        source: tile.glyph.length > 0 ? Qt.resolvedUrl("assets/icons/" + tile.glyph + ".svg") : ""
        sourceSize.width: 128
        sourceSize.height: 128
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: false
        visible: status === Image.Ready
    }

    // Neutral fallback: a missing glyph (empty name, or an asset that does not
    // load) draws one soft ink dot, never a box and never a binding error.
    Rectangle {
        visible: !glyphImage.visible
        width: 18
        height: 18
        radius: 9
        color: Tokens.ink
        opacity: 0.3
        anchors.centerIn: parent
    }

    // Live marker: lit acid dot, only where the app is running.
    Rectangle {
        visible: tile.running
        width: 6.5
        height: 6.5
        radius: 3.25
        color: Tokens.acid
        x: 46
        y: 46
    }
}
