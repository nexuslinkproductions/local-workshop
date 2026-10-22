import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: terminal. Custom mark: a prompt chevron and a cursor bar, no window
// frame (the deck draws no boxes). 24 px grid, live area 6..18.4, stroke 1.5
// regular / 2.0 bold, round caps and joins.
Shape {
    id: root
    property color color: Tokens.ink
    property real weight: 1.5
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
        startX: 6.0
        startY: 7.0
        PathLine { x: 11.2; y: 12 }
        PathLine { x: 6.0; y: 17.0 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 12.4
        startY: 16.8
        PathLine { x: 18.6; y: 16.8 }
    }
}
