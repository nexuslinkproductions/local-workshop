import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: chrome. Brand mark (Chromium-family browser), redrawn monochrome on
// the same grid: outer ring, hub and three spokes at the sector cuts. The hub
// is a small node rather than a second full ring, which keeps the mark's ink in
// the same band as the rest of the set. 24 px grid, live area 4..20, stroke
// 2.0, round caps.
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
        PathAngleArc { centerX: 12; centerY: 12; radiusX: 8.0; radiusY: 8.0; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathAngleArc { centerX: 12; centerY: 12; radiusX: 2.4; radiusY: 2.4; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 12
        startY: 14.4
        PathLine { x: 12; y: 20.0 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 9.92
        startY: 10.8
        PathLine { x: 4.93; y: 7.92 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 14.08
        startY: 10.8
        PathLine { x: 19.07; y: 7.92 }
    }
}
