import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: arc-raiders. Custom mark for the feature tile: a rise over an arc,
// the one emblem in the set that uses two shapes instead of one line. 24 px
// grid, live area 3.4..20.6, stroke 2.0, round caps and joins.
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

    // the rise
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 5.6
        startY: 16.0
        PathLine { x: 12; y: 6.2 }
        PathLine { x: 18.4; y: 16.0 }
    }
    // the arc
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 3.4
        startY: 19.6
        PathQuad { x: 20.6; y: 19.6; controlX: 12; controlY: 16.0 }
    }
}
