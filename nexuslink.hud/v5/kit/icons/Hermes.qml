import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: hermes. Custom mark (not a brand): a winged staff, one vertical
// stroke with three feathers fanning up to the right, each shorter as it
// climbs. The staff sits left of centre and the fan reaches only to 19.6 so the
// mark's bounding box centres on the grid. 24 px grid, stroke 2.0, round caps
// and joins, no fill.
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

    // staff
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 7.4
        startY: 20.4
        PathLine { x: 7.4; y: 4.4 }
    }
    // feathers: lowest is the longest and the least steep, the top one is short
    // and climbs hardest, so the three read as one fan and not three ticks
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 7.4
        startY: 16.2
        PathQuad { x: 19.2; y: 15.4; controlX: 13.8; controlY: 16.4 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 7.4
        startY: 12.2
        PathQuad { x: 18.4; y: 10.4; controlX: 13.4; controlY: 12.2 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 7.4
        startY: 8.2
        PathQuad { x: 16.2; y: 6.0; controlX: 12.4; controlY: 8.0 }
    }
}
