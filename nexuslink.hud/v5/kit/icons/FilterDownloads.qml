import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: filter downloads. Find filter chip, s3 design: a down arrow into a
// tray, stroke at icon weight, no outline box.
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
        startX: 12
        startY: 4
        PathLine { x: 12; y: 14.5 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 7.5
        startY: 10
        PathLine { x: 12; y: 14.5 }
        PathLine { x: 16.5; y: 10 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 3.5
        startY: 14.5
        PathLine { x: 3.5; y: 19.5 }
        PathLine { x: 20.5; y: 19.5 }
        PathLine { x: 20.5; y: 14.5 }
    }
}
