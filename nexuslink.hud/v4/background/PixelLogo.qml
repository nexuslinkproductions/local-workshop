pragma ComponentBehavior: Bound

import QtQuick
import ".."

// PixelLogo.qml — Nexus Link celtic-knot mark resampled to 64x64 pixel art
// for the command-deck background. The silhouette comes from the original
// 48x49 matrix (candidates/PixelKnot.qml — "element dark nexus.svg" raster);
// every target cell stores a 4x4-subsample coverage fraction, so the knot
// keeps its shape with soft anti-aliased edges instead of a hard binary cut.
// Cells, seeds, base colours, edge flags and the ribbon trace order are all
// baked once at completion — paint frames only do arithmetic.
//
// Layers per cell: beveled main rect + light top/left and dark bottom/right
// slivers on silhouette-edge cells (higher detail than the flat 48px mark).
//
// Idle (~4 fps): standing multicolor diagonal gradient (cyan -> ice -> azure)
// at watermark alpha, slow sheen band tinted toward amber, gentle breathing.
// Active (~30 fps): one of four effects every 25-40 s, shuffle-bag order so
// an effect never immediately repeats, each lasting 4-7 s:
//   0 RIBBON   cells light along the traced knot order, hold, release
//   1 CHROMA   colour ring travels across the knot, ends back at base
//   2 SCATTER  seeded off-grid flight and reassemble
//   3 TILT     small pseudo-perspective shear + squash
// Every displacement/colour envelope is zero at both ends of an effect, and
// the settled idle frame is painted BEFORE the fx timer stops — pausing or
// hiding snaps straight to that idle frame and resumes on a fresh cadence.
Canvas {
    id: root

    clip: true

    // ---- public API ----------------------------------------------------------
    property bool shown: true          // deck visibility gate
    property bool running: true        // master gate (harness may clear it)
    property int  seed: 7331           // deterministic personality
    property real baseAlpha: 0.34      // standing watermark alpha (25-45%)

    readonly property int cols: 64
    readonly property int rows: 64
    readonly property int cellCount: cells.length
    readonly property int effectId: effect
    readonly property bool settled: effect < 0

    // ---- original 48x49 knot matrix (verbatim from candidates/PixelKnot.qml) -
    readonly property var srcRows: [
        "......................##........................",
        ".....................####.......................",
        "....................######......................",
        "...................########.....................",
        "...................###..####....................",
        "..................####...###....................",
        ".................############...................",
        ".................###......#####.................",
        "..............######.......###.##...............",
        "............##..###........####..##.............",
        "...........#....###.........###....#............",
        ".........##....###..........###.....##..........",
        "........##.....###...........###.....##.........",
        ".......##......###...........###......##........",
        "......##.......##............###.......##.......",
        "......#.......###.............##........#.......",
        ".....#........###.............###........#......",
        "....##........###.............###........#......",
        "....#.........###.............###.........#.....",
        "....#.........###.............###.........#.....",
        "...#..........###.............###..........#....",
        "...#...........#.############.###..........#....",
        "..##...........##############.###..........#....",
        "..#..........#########....######.###........#...",
        "..#........######............###.####.......#...",
        "..#......######.##...........###.######.....#...",
        "..#.....#####...###..........###...#####....#...",
        "..#....####.....###.........###......####...#...",
        "..#...####......####........###.......####..#...",
        "..#..####........###.......###.........####.#...",
        "..#.####.........####......###..........#####...",
        "..#.###...........####....###............###....",
        "..#####............###...####.............###...",
        "...###.............####..###..............####..",
        "..###...............####.##................###..",
        "..###................#####................#####.",
        ".####.................#####...............#.###.",
        ".####..............##########............##.###.",
        ".###.#...........######..######..........#...###",
        "###...#........#######....#########.....########",
        "#######...##########........####################",
        "##################.............###############..",
        "..#############.....................###.#.......",
        ".........##.........................##..........",
        "..........##.......................##...........",
        "............##...................##.............",
        ".............###...............###..............",
        "...............####.........####................",
        "...................#########...................."
    ]
    readonly property int srcCols: 48
    readonly property int srcRowCount: 49

    // ---- palette: HUD ice/azure + restrained original cyan/magenta/amber -----
    readonly property color cCyan:    "#00e5ff"
    readonly property color cIce:     FuiTokens.ice
    readonly property color cAzure:   FuiTokens.azure
    readonly property color cMagenta: "#ff2bd6"
    readonly property color cAmber:   FuiTokens.warn

    // ---- baked state -----------------------------------------------------------
    property var    cells: []          // {x,y,cov,seed,dx,dy,rank,edge,ci}
    property var    pal: []            // 128-entry idle gradient CSS LUT
    property var    bevL: []           // light bevel variant per palette index
    property var    bevD: []           // dark bevel variant per palette index
    property var    spec: []           // 128-entry chroma-ring CSS LUT
    property string sheenCss: ""       // baked amber sheen overlay colour
    property string brightCss: ""      // baked ribbon-highlight overlay colour
    property int    nEdge: 0
    property real   covMin: 0
    property real   covMax: 0
    property int    maxRank: -1
    property int    effect: -1         // -1 idle; 0..3 active
    property double t0: 0
    property double elapsed: 0
    property double effectDur: 0
    property var    bag: []
    property int    lastEffect: -1
    property double idleClock: 0       // ms; sheen/breath phase source
    property int    rngState: 0

    // deterministic RNG (LCG) — cells/seed/jitter cached once
    function rng() {
        rngState = (rngState * 1664525 + 1013904223) >>> 0
        return rngState / 4294967296
    }

    Component.onCompleted: {
        rngState = (seed >>> 0) || 1
        buildLuts()
        buildCells()
        requestPaint()
        if (gate()) { idleTimer.start(); scheduleNext() }
    }
    onShownChanged:   gateChanged()
    onRunningChanged: gateChanged()
    onVisibleChanged: gateChanged()
    onWidthChanged:   requestPaint()
    onHeightChanged:  requestPaint()

    function gate() { return shown && running && visible }

    function gateChanged() {
        if (gate()) {
            idleTimer.start()
            scheduleNext()                       // fresh cadence, not a
        } else {                                 // mid-effect resume
            fxTimer.stop(); cycleTimer.stop(); idleTimer.stop()
            effect = -1; elapsed = 0             // snap to the settled logo
            requestPaint()
        }
    }
    function pause()  { running = false }
    function resume() { running = true  }

    // ---- build ----------------------------------------------------------------
    function srcLit(sx, sy) {
        var row = srcRows[sy] || ""
        return sx >= 0 && sx < srcCols && row.charAt(sx) === "#"
    }

    function buildCells() {
        var cov = [], i, tx, ty
        for (ty = 0; ty < rows; ty++) {
            for (tx = 0; tx < cols; tx++) {
                var lit = 0
                for (var sy = 0; sy < 4; sy++)
                    for (var sx = 0; sx < 4; sx++)
                        if (srcLit(Math.floor((tx + (sx + 0.5) / 4) * srcCols / cols),
                                   Math.floor((ty + (sy + 0.5) / 4) * srcRowCount / rows)))
                            lit++
                cov.push(lit / 16)
            }
        }
        var list = [], mn = 1, mx = 0
        var mnx = cols, mxx = -1, mny = rows, mxy = -1
        for (ty = 0; ty < rows; ty++) {
            for (tx = 0; tx < cols; tx++) {
                var c = cov[ty * cols + tx]
                if (c < 0.12) continue
                var edge = false
                for (var dy = -1; dy <= 1 && !edge; dy++)
                    for (var dx = -1; dx <= 1; dx++) {
                        var nx = tx + dx, ny = ty + dy
                        var nc = (nx < 0 || ny < 0 || nx >= cols || ny >= rows)
                               ? 0 : cov[ny * cols + nx]
                        if (nc < 0.12) { edge = true; break }
                    }
                // scatter flight direction — seeded, deterministic
                var ang = rng() * Math.PI * 2
                var mag = 1.2 + rng() * 1.4          // 1.2..2.6 cells
                // base gradient index: diagonal cyan -> ice -> azure LUT slot
                var d = (tx + ty) / (cols + rows - 2)
                if (c < mn) mn = c
                if (c > mx) mx = c
                if (tx < mnx) mnx = tx; if (tx > mxx) mxx = tx
                if (ty < mny) mny = ty; if (ty > mxy) mxy = ty
                list.push({
                    x: tx, y: ty, cov: c, seed: rng(),
                    dx: Math.cos(ang) * mag, dy: Math.sin(ang) * mag,
                    edge: edge, rank: -1,
                    ci: Math.min(127, Math.floor(d * 127 + 0.5))
                })
                if (edge) nEdge++
            }
        }
        cells = list
        covMin = mn; covMax = mx
        bboxX0 = mnx; bboxY0 = mny; bboxX1 = mxx; bboxY1 = mxy
        buildTrace()
    }
    property int bboxX0: -1
    property int bboxY0: -1
    property int bboxX1: -1
    property int bboxY1: -1

    // greedy nearest-neighbour crawl — approximates tracing the knot ribbon
    function buildTrace() {
        var n = cells.length, used = [], order = []
        for (var i = 0; i < n; i++) used.push(false)
        var cur = 0
        // start at the topmost cell (the knot peak)
        for (i = 1; i < n; i++)
            if (cells[i].y < cells[cur].y) cur = i
        for (var k = 0; k < n; k++) {
            order.push(cur); used[cur] = true
            var best = -1, bd = 1e18
            for (var j = 0; j < n; j++) {
                if (used[j]) continue
                var ddx = cells[j].x - cells[cur].x, ddy = cells[j].y - cells[cur].y
                var dd = ddx * ddx + ddy * ddy
                if (dd < bd) { bd = dd; best = j }
            }
            cur = best
        }
        for (k = 0; k < n; k++) cells[order[k]].rank = k
        maxRank = n - 1
    }
    function lerpC(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t,
                       a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, 1)
    }
    function grad3(a, b, c, t) {
        return t < 0.5 ? lerpC(a, b, t * 2) : lerpC(b, c, t * 2 - 1)
    }
    function css(c) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255)
                     + "," + Math.round(c.b * 255) + ",1)"
    }
    // hue ring for the chroma wave — restrained accent cycle
    function ring(f) {
        var stops = ringStops, p = (f - Math.floor(f)) * (stops.length - 1)
        var i = Math.floor(p)
        if (i >= stops.length - 1) i = stops.length - 2
        return lerpC(stops[i], stops[i + 1], p - i)
    }
    readonly property var ringStops: [cCyan, cIce, cAzure, cMagenta, cAmber, cCyan]

    // all CSS strings paint ever needs are baked here once — frames pick LUT
    // indices and drive per-cell alpha through ctx.globalAlpha only
    function buildLuts() {
        var p = [], l = [], d = [], s = []
        var white = Qt.rgba(1, 1, 1, 1), dark = Qt.rgba(0, 0, 0, 1)
        for (var i = 0; i < 128; i++) {
            var t = i / 127
            var c = grad3(cCyan, cIce, cAzure, t)
            p.push(css(c))
            l.push(css(lerpC(c, white, 0.5)))
            d.push(css(lerpC(c, dark, 0.65)))
            s.push(css(ring(t)))
        }
        pal = p; bevL = l; bevD = d; spec = s
        sheenCss = css(cAmber)
        brightCss = "rgba(240,250,255,1)"
    }

    // envelope: 0 at both ends of every effect (displacement + colour alike)
    function env(pr) {
        return Math.sin(Math.PI * Math.min(1, Math.max(0, pr)))
    }

    // ---- scheduler -------------------------------------------------------------
    function scheduleNext() {
        cycleTimer.interval = Math.round(25000 + rng() * 15000)   // 25..40 s
        cycleTimer.restart()
    }
    function durFor(e) {                            // 4..7 s per effect
        switch (e) {
            case 0: return 7000                      // ribbon trace + hold + fade
            case 1: return 5000                      // chroma wave
            case 2: return 6000                      // scatter/reassemble
            case 3: return 4500                      // tilt
        }
        return 4000
    }
    function play(e) {                              // public trigger (tests)
        startEffect(e === undefined ? -1 : e)
    }
    function startEffect(e) {
        if (!gate()) return
        if (e === undefined || e < 0 || e > 3) e = drawFromBag()
        effect = e
        lastEffect = e
        effectDur = durFor(e)
        t0 = Date.now(); elapsed = 0
        idleTimer.stop()                            // one paint pump at a time;
        fxTimer.restart()                           // fx keeps idleClock moving
        requestPaint()
    }
    function drawFromBag() {
        if (bag.length === 0) refillBag()
        return bag.pop()
    }
    function refillBag() {
        bag = [0, 1, 2, 3]
        for (var i = bag.length - 1; i > 0; i--) {
            var j = Math.floor(rng() * (i + 1))
            var t = bag[i]; bag[i] = bag[j]; bag[j] = t
        }
        // no immediate repeat across bag boundaries (entries are unique,
        // so swapping the repeat with slot 0 always fixes it)
        if (bag.length > 1 && bag[bag.length - 1] === lastEffect) {
            var tt = bag[bag.length - 1]
            bag[bag.length - 1] = bag[0]; bag[0] = tt
        }
    }
    function endEffect() {
        effect = -1; elapsed = 0
        requestPaint()                    // settled idle frame paints first
        fxTimer.stop()                    // ...THEN the timer stops
        if (gate()) { idleTimer.start(); scheduleNext() }
    }

    Timer {
        id: cycleTimer
        repeat: false
        onTriggered: if (root.gate()) root.startEffect(-1)
    }
    Timer {
        id: fxTimer                        // ~30 Hz while an effect runs
        interval: 33; repeat: true
        onTriggered: {
            root.idleClock += interval
            root.elapsed = Date.now() - root.t0
            if (root.elapsed >= root.effectDur) root.endEffect()
            else root.requestPaint()
        }
    }
    Timer {
        id: idleTimer                      // 4 fps idle sheen/breath pump
        interval: 250; repeat: true
        onTriggered: {
            root.idleClock += interval
            root.requestPaint()
        }
    }

    // ---- paint -------------------------------------------------------------------
    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        var n = cells.length
        if (n === 0) return

        var m = Math.min(width, height)
        var sc = m * 0.90                              // 5% margin for scatter
        var cw = sc / cols, ch = sc / rows
        var ox = (width - sc) / 2, oy = (height - sc) / 2
        var pr = effectDur > 0 ? Math.min(1, elapsed / effectDur) : 0
        var g = env(pr)
        var breath = 1 + 0.09 * Math.sin(idleClock * Math.PI * 2 / 6000)
        var sheenPos = (idleClock % 24000) / 24000 * 1.6 - 0.3   // slow sweep
        var isChroma = (effect === 1)

        // TILT: global pseudo-perspective shear around the canvas centre
        if (effect === 3) {
            var cxp = width / 2, cyp = height / 2
            var tilt = 0.10 * g
            ctx.translate(cxp, cyp)
            ctx.transform(1 - 0.05 * g, tilt * 0.6, tilt, 1, 0, 0)
            ctx.translate(-cxp, -cyp)
        }

        for (var i = 0; i < n; i++) {
            var c = cells[i]
            var a = baseAlpha * (0.55 + 0.45 * c.cov) * breath
            if (c.edge) a *= 1.18                       // brighter edge highlight

            // sheen band drifts along the diagonal — alpha lift + amber overlay
            var sp = (c.x + c.y) / (cols + rows - 2) * 1.6 - 0.3
            var sh = 1 - Math.abs(sp - sheenPos * 1.0) / 0.16
            if (sh > 0) a += sh * 0.08

            var offX = 0, offY = 0, boost = 0, specI = 0
            var ci = c.ci                              // idle gradient LUT slot
            if (effect === 0) {                        // RIBBON trace
                var ph = pr / 0.55                     // draw completes at 55%
                if (ph < 1) boost = Math.max(0, Math.min(1, (ph * n - c.rank) / 4))
                else        boost = 1
                if (pr > 0.75) boost *= (1 - pr) / 0.25   // release to idle
                a += boost * 0.45
            } else if (effect === 1) {                 // CHROMA wave
                var rf = sp * 0.8 + pr * 1.4
                rf -= Math.floor(rf)
                specI = Math.min(127, Math.floor(rf * 127 + 0.5))
                var wf = sp - pr * 1.4
                wf -= Math.floor(wf)
                var wb = Math.max(0, 1 - Math.abs(wf - 0.5) * 5)
                a += wb * 0.35 * g
            } else if (effect === 2) {                 // SCATTER/reassemble
                offX = c.dx * g
                offY = c.dy * g
                a *= 1 - 0.30 * g
            }

            var px = ox + (c.x + offX) * cw
            var py = oy + (c.y + offY) * ch
            var ins = Math.max(0.5, Math.min(cw, ch) * 0.06)
            var w = cw - 2 * ins, h = ch - 2 * ins
            if (a > 0.5) a = 0.5                        // stay a watermark
            // chroma splits the same alpha between base + spectrum LUT so the
            // colour blend rides the envelope to zero at both ends
            var km = isChroma ? 0.85 * g : 0
            ctx.globalAlpha = a * (1 - km)
            ctx.fillStyle = pal[ci]
            ctx.fillRect(px + ins, py + ins, w, h)
            if (isChroma && km > 0.02) {
                ctx.globalAlpha = a * km
                ctx.fillStyle = spec[specI]
                ctx.fillRect(px + ins, py + ins, w, h)
            }
            ctx.globalAlpha = a
            if (c.edge) {                              // bevel slivers
                var lw = Math.max(1, Math.min(cw, ch) * 0.16)
                ctx.fillStyle = bevL[ci]
                ctx.fillRect(px + ins, py + ins, w, lw)                // top
                ctx.fillRect(px + ins, py + ins, lw, h)                // left
                ctx.fillStyle = bevD[ci]
                ctx.fillRect(px + ins, py + ins + h - lw, w, lw)       // bottom
                ctx.fillRect(px + ins + w - lw, py + ins, lw, h)       // right
            }
            if (sh > 0.06) {                           // amber sheen overlay
                ctx.globalAlpha = sh * 0.45
                ctx.fillStyle = sheenCss
                ctx.fillRect(px + ins, py + ins, w, h)
            }
            if (boost > 0.05) {                        // ribbon highlight
                ctx.globalAlpha = boost * 0.35
                ctx.fillStyle = brightCss
                ctx.fillRect(px + ins, py + ins, w, h)
            }
        }
        ctx.globalAlpha = 1
        ctx.setTransform(1, 0, 0, 1, 0, 0)             // drop any tilt
    }

    // ---- invariants for the harness selftest ------------------------------------
    function selftest() {
        var ranks = true
        for (var i = 0; i < cells.length; i++)
            if (cells[i].rank < 0 || cells[i].rank > maxRank) { ranks = false; break }
        return {
            "cols": cols, "rows": rows,
            "src": srcCols + "x" + srcRowCount,
            "cells": cells.length, "edgeCells": nEdge,
            "covMin": covMin, "covMax": covMax,
            "bbox": [bboxX0, bboxY0, bboxX1, bboxY1],
            "silhouette": bboxY0 <= 4 && bboxY1 >= rows - 8
                       && bboxX0 <= 10 && bboxX1 >= cols - 10,
            "ranksComplete": ranks && maxRank === cells.length - 1,
            "env0": env(0), "env1": Math.abs(env(1)) < 1e-9 ? 0 : env(1),
            "durations": [durFor(0), durFor(1), durFor(2), durFor(3)],
            "durInRange": durFor(0) >= 4000 && durFor(0) <= 7000
                       && durFor(1) >= 4000 && durFor(1) <= 7000
                       && durFor(2) >= 4000 && durFor(2) <= 7000
                       && durFor(3) >= 4000 && durFor(3) <= 7000,
            "settled": settled,
            "gate": gate()
        }
    }
}
