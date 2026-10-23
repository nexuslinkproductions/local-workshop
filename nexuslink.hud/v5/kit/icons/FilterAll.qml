import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: filter all. Find filter chip, s3 design: a 2 x 2 grid of dots on
// the 24 px grid (live area 6..18), solid, no outline.
Item {
    id: root
    property color color: Tokens.ink
    property real weight: 2.0
    property real size: 24

    implicitWidth: 24
    implicitHeight: 24
    width: 24
    height: 24
    scale: size / 24
    transformOrigin: Item.Center

    Rectangle { x: 5; y: 5; width: 6; height: 6; radius: 1.6; color: root.color }
    Rectangle { x: 13; y: 5; width: 6; height: 6; radius: 1.6; color: root.color }
    Rectangle { x: 5; y: 13; width: 6; height: 6; radius: 1.6; color: root.color }
    Rectangle { x: 13; y: 13; width: 6; height: 6; radius: 1.6; color: root.color }
}
