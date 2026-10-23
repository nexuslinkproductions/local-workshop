import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: volume. System glyph: the cone and two waves, evenly spaced off the
// cone mouth. 24 px grid, live area 3.6..20.2, stroke 2.0, round caps and
// joins.
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
        startX: 3.6
        startY: 9.6
        PathLine { x: 7.4; y: 9.6 }
        PathLine { x: 11.6; y: 5.6 }
        PathLine { x: 11.6; y: 18.4 }
        PathLine { x: 7.4; y: 14.4 }
        PathLine { x: 3.6; y: 14.4 }
        PathLine { x: 3.6; y: 9.6 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 13.8
        startY: 9.8
        PathQuad { x: 13.8; y: 14.2; controlX: 15.4; controlY: 12 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 16.8
        startY: 7.4
        PathQuad { x: 16.8; y: 16.6; controlX: 20.2; controlY: 12 }
    }
}
