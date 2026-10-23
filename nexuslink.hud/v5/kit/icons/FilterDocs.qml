import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: filter docs. Find filter chip, s3 design: a page with a folded
// corner and two text lines, stroke at icon weight, no outline box.
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
        startX: 6
        startY: 3.5
        PathLine { x: 13.5; y: 3.5 }
        PathLine { x: 18; y: 8 }
        PathLine { x: 18; y: 20.5 }
        PathLine { x: 6; y: 20.5 }
        PathLine { x: 6; y: 3.5 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 13.5
        startY: 3.5
        PathLine { x: 13.5; y: 8 }
        PathLine { x: 18; y: 8 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        startX: 9
        startY: 12.5
        PathLine { x: 15; y: 12.5 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        startX: 9
        startY: 16
        PathLine { x: 15; y: 16 }
    }
}
