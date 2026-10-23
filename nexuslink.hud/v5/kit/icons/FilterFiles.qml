import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: filter files. Find filter chip, s3 design: a folder with a tab,
// stroke at icon weight on the 24 px grid, round caps and joins, no outline box.
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
        startX: 3.5
        startY: 18.5
        PathLine { x: 3.5; y: 6 }
        PathLine { x: 9.5; y: 6 }
        PathLine { x: 11; y: 8 }
        PathLine { x: 20.5; y: 8 }
        PathLine { x: 20.5; y: 18.5 }
        PathLine { x: 3.5; y: 18.5 }
    }
}
