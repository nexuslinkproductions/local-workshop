import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: battery. System glyph: the cell, a short terminal nub and a charge
// fill at about two thirds. Corners are tight (2 units) so the body stays
// rectangular instead of pill-shaped. 24 px grid, live area 2..20.7, stroke 1.5
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

    // cell
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 4.4
        startY: 6.8
        PathLine { x: 16.8; y: 6.8 }
        PathQuad { x: 19.2; y: 9.2; controlX: 19.2; controlY: 6.8 }
        PathLine { x: 19.2; y: 14.8 }
        PathQuad { x: 16.8; y: 17.2; controlX: 19.2; controlY: 17.2 }
        PathLine { x: 4.4; y: 17.2 }
        PathQuad { x: 2.0; y: 14.8; controlX: 2.0; controlY: 17.2 }
        PathLine { x: 2.0; y: 9.2 }
        PathQuad { x: 4.4; y: 6.8; controlX: 2.0; controlY: 6.8 }
    }
    // terminal nub
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 20.7
        startY: 10.6
        PathLine { x: 20.7; y: 13.4 }
    }
    // charge fill, half
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        startX: 5.6
        startY: 9.2
        PathLine { x: 9.6; y: 9.2 }
        PathQuad { x: 10.8; y: 10.4; controlX: 10.8; controlY: 9.2 }
        PathLine { x: 10.8; y: 13.6 }
        PathQuad { x: 9.6; y: 14.8; controlX: 10.8; controlY: 14.8 }
        PathLine { x: 5.6; y: 14.8 }
        PathQuad { x: 4.4; y: 13.6; controlX: 4.4; controlY: 14.8 }
        PathLine { x: 4.4; y: 10.4 }
        PathQuad { x: 5.6; y: 9.2; controlX: 4.4; controlY: 9.2 }
    }
}
