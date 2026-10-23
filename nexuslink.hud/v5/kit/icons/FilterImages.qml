import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: filter images. Find filter chip, s3 design: a picture frame with a
// mountain line and a sun dot, stroke at icon weight, no outline box.
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
        startX: 4
        startY: 5
        PathLine { x: 20; y: 5 }
        PathLine { x: 20; y: 19 }
        PathLine { x: 4; y: 19 }
        PathLine { x: 4; y: 5 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 6.5
        startY: 16
        PathLine { x: 10.5; y: 11.5 }
        PathLine { x: 13.5; y: 15 }
        PathLine { x: 15.5; y: 13 }
        PathLine { x: 17.5; y: 16 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        startX: 15.5
        startY: 8.6
        PathLine { x: 15.5; y: 8.8 }
    }
}
