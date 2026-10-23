import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: settings. System glyph: two sliders with one bead each. A toothed
// gear outline goes muddy at 24 px and three sliders read as a hamburger menu,
// so two lines with clear beads is the legible choice at this size. 24 px grid,
// live area 3.4..20.6, stroke 2.0, round caps.
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
        startX: 3.4
        startY: 8.4
        PathLine { x: 20.6; y: 8.4 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 3.4
        startY: 15.6
        PathLine { x: 20.6; y: 15.6 }
    }
    // beads
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 13.8; centerY: 8.4; radiusX: 2.3; radiusY: 2.3; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 8.8; centerY: 15.6; radiusX: 2.3; radiusY: 2.3; startAngle: 0; sweepAngle: 360 }
    }
}
