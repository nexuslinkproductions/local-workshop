import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: x. Brand mark (X, formerly Twitter), redrawn monochrome: the two
// crossing bands of the mark, corner to corner. 24 px grid, live area
// 4.4..19.6, stroke 2.0, round caps.
Shape {
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
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 4.4
        startY: 4.4
        PathLine { x: 19.6; y: 19.6 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 19.6
        startY: 4.4
        PathLine { x: 4.4; y: 19.6 }
    }
}
