import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: youtube. Brand mark, redrawn monochrome: the wide rounded tile with
// a solid play mark big enough to survive 24 px. 24 px grid, live area 3.6..20.4,
// stroke 1.5 regular / 2.0 bold, round caps and joins.
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
        startX: 6.8
        startY: 6.6
        PathLine { x: 17.2; y: 6.6 }
        PathQuad { x: 20.4; y: 9.8; controlX: 20.4; controlY: 6.6 }
        PathLine { x: 20.4; y: 14.2 }
        PathQuad { x: 17.2; y: 17.4; controlX: 20.4; controlY: 17.4 }
        PathLine { x: 6.8; y: 17.4 }
        PathQuad { x: 3.6; y: 14.2; controlX: 3.6; controlY: 17.4 }
        PathLine { x: 3.6; y: 9.8 }
        PathQuad { x: 6.8; y: 6.6; controlX: 3.6; controlY: 6.6 }
    }
    // play mark
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        startX: 9.6
        startY: 8.9
        PathLine { x: 15.8; y: 12 }
        PathLine { x: 9.6; y: 15.1 }
        PathLine { x: 9.6; y: 8.9 }
    }
}
