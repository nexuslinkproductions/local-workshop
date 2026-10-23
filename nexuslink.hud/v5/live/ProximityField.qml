import QtQuick
import "../kit"

// ProximityField.qml - pointer driven growth for the v5 deck. Invisible.
//
// Pure QtQuick, no Timer, no per-frame work: it recomputes only when the
// pointer moves, when it enters or leaves the deck, or when the widget list
// changes. Each widget in `widgets` must expose proximity, pushX and pushY
// (WidgetBase does) and hovered, pressed optional.
//
// proximity (0..1) for a widget with centre c and radius R = 0.5 * hypot(w, h):
//   d = distance(pointer, c)
//   t = clamp((1.2 * R - d) / ((1.2 - 0.4) * R), 0, 1)
//   proximity = t * t * (3 - 2 * t)          smoothstep, falling with distance
//
// push (px) for widget i, summed over the other widgets j:
//   unit(c_i - c_j) * pushMax * grow_j * exp(-dist_ij^2 / (2 * sigma^2))
// grow_j is max(proximity_j, hovered_j ? 1 : 0). The knot is not in the list, so
// it is never pushed.
Item {
    id: field
    visible: false
    width: 0
    height: 0

    // ---- inputs ----------------------------------------------------------
    // Pointer in deck coordinates, plus whether it is over the deck at all.
    property real pointerX: -1000000
    property real pointerY: -1000000
    property bool inside: false
    // Items that take proximity, pushX and pushY. Order does not matter.
    property var widgets: []

    // ---- tunables (Motion.qml) -------------------------------------------
    property real nearRadius: Motion.proximityNearRadius
    property real farRadius: Motion.proximityFarRadius
    property real pushMax: Motion.proximityPushMax
    property real pushSigma: Motion.proximityPushSigma

    // Scratch per refresh, sized once. Kept as properties so the JS pass does
    // not allocate a new array on every pointer move.
    property var _cx: []
    property var _cy: []
    property var _grow: []

    onPointerXChanged: field.refresh()
    onPointerYChanged: field.refresh()
    onInsideChanged: field.refresh()
    onWidgetsChanged: field.refresh()
    onNearRadiusChanged: field.refresh()
    onFarRadiusChanged: field.refresh()
    onPushMaxChanged: field.refresh()
    onPushSigmaChanged: field.refresh()
    // Initial state: every binding above may already hold its final value by the
    // time this item completes, so no change signal would ever fire.
    Component.onCompleted: field.refresh()

    // ---- the one update --------------------------------------------------
    function refresh() {
        var ws = field.widgets
        var n = ws ? ws.length : 0
        if (n <= 0)
            return

        var px = field.pointerX
        var py = field.pointerY
        var on = field.inside
        var near = field.nearRadius
        var far = field.farRadius
        var span = near - far
        var cx = field._cx
        var cy = field._cy
        var gr = field._grow
        var i
        var j

        // pass 1: geometry, proximity
        for (i = 0; i < n; ++i) {
            var w = ws[i]
            if (!w) {
                cx[i] = 0
                cy[i] = 0
                gr[i] = 0
                continue
            }
            var wi = w.width
            var hi = w.height
            var x = w.x + wi * 0.5
            var y = w.y + hi * 0.5
            // The visual centre moves with push, but proximity ignores push so
            // the field never feeds back into itself.
            cx[i] = x
            cy[i] = y
            var R = 0.5 * Math.hypot(wi, hi)
            var p = 0
            if (on && R > 0) {
                var d = Math.hypot(px - x, py - y)
                var t = (near * R - d) / (span * R)
                if (t < 0)
                    t = 0
                else if (t > 1)
                    t = 1
                p = t * t * (3 - 2 * t)
            }
            w.proximity = p
            gr[i] = w.hovered === true ? 1 : p
        }

        // pass 2: pushes from every grown neighbour
        var pmax = field.pushMax
        var sigma = field.pushSigma
        var twoSigma2 = 2 * sigma * sigma
        for (i = 0; i < n; ++i) {
            var wi2 = ws[i]
            if (!wi2)
                continue
            var sx = 0
            var sy = 0
            for (j = 0; j < n; ++j) {
                if (j === i)
                    continue
                var g = gr[j]
                if (g <= 0.0005)
                    continue
                var dx = cx[i] - cx[j]
                var dy = cy[i] - cy[j]
                var dist = Math.hypot(dx, dy)
                if (dist < 0.001)
                    continue
                var fall = Math.exp(-(dist * dist) / twoSigma2)
                var amp = pmax * g * fall / dist
                sx += dx * amp
                sy += dy * amp
            }
            wi2.pushX = sx
            wi2.pushY = sy
        }
    }
}
