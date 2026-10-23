import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: obsidian. Brand mark, redrawn monochrome on the same grid: the
// faceted shard as one silhouette plus the central ridge from the peak to the
// bottom point. The logo's small left fold was tried and dropped: its triangle
// collapses into the ridge below 48 px, so the mark keeps the one seam that
// survives at 24 px. The peak sits left of centre and the right shoulder
// higher, so the shard keeps the brand's lean. 24 px grid, live area
// 2.8..21.4, stroke 2.0, round caps and joins.
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

    // silhouette: peak, right shoulder, right edge, bottom point, left edge,
    // left shoulder, back to the peak
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 12.6
        startY: 3.8
        PathLine { x: 19.4; y: 8.4 }
        PathLine { x: 17.8; y: 17.2 }
        PathLine { x: 11.6; y: 20.4 }
        PathLine { x: 6.0; y: 17.0 }
        PathLine { x: 4.6; y: 9.0 }
        PathLine { x: 12.6; y: 3.8 }
    }
    // ridge: peak to bottom point
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 12.6
        startY: 3.8
        PathLine { x: 11.6; y: 20.4 }
    }
}
