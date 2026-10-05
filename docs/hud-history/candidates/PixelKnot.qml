// ============================================================================
// PixelKnot.qml — Nexus Link Productions celtic-knot element as pixel art
// ----------------------------------------------------------------------------
// GRID DERIVATION (offline, baked — no runtime deps):
//   Source : "element dark nexus.svg" (light variant identical geometry,
//            only fill #191d22 -> #b6b6b7 differs)
//   viewBox: 0 0 859.67 883.69 — 9 filled path outlines, all cubic outlines
//            using M/c/s/l/Z commands (ribbons of the knot, not strokes)
//   Shape  : pointed-oval (vesica) knot ring — two arcs meet at a top peak and
//            a bottom point; twin vertical strands down the core, diagonal
//            over/under weave, horizontal wave band crossing mid-body.
//   Raster : pure-python flatten of all 9 paths (cubics -> polylines, n=40),
//            5x5 coverage subsamples per cell over the padded path bbox,
//            even-odd fill per path, cells >= 22% coverage kept, 8-neighbour
//            orphans dropped -> 48x49 cells, 617 lit ("#" = knot ribbon).
// ----------------------------------------------------------------------------
// Self-contained QtQuick item for the Quickshell HUD background surface.
// Idle: every knot cell sits dim (~0.16 alpha). A scheduler fires one of five
// micro-animations every ~30-60s (jittered around `cycleSeconds`):
//   0 SCAN        - bright column sweeps left -> right with decaying trail
//   1 PULSE       - concentric ring of light expands from the knot centre
//   2 DRAW-IN     - cells light in greedy nearest-neighbour trace order
//                   (follows the continuous ribbon crawl), hold ~2s, fade
//   3 SPARKLE     - random cells twinkle against the idle field (~3s)
//   4 TRACE-COLOR - whole knot lit while its hue rotates
//                   accent -> magenta -> amber -> accent
// Palette matches the HUD: cyan #00e5ff / magenta #ff2bd6 / amber #ffb300.
// ============================================================================
import QtQuick

Canvas {
  id: root

  // ---- public API ----------------------------------------------------------
  property int   px: 6                 // logical pixel-cell size
  property color accent: "#00e5ff"     // knot colour (HUD cyan default)
  property int   cycleSeconds: 45      // nominal cadence; jittered to 30..60s
  property bool  running: true         // master gate (HUD tick may clear it)

  readonly property int cols: 48
  readonly property int rows: 49
  implicitWidth:  cols * px
  implicitHeight: rows * px
  width:  implicitWidth                // may be overridden; paint is size-safe
  height: implicitHeight

  function pause()  { paused = true;  cycleTimer.stop(); fxTimer.stop() }
  function resume() {
    paused = false
    if (!running) return
    if (effect >= 0) { t0 = Date.now() - elapsed; fxTimer.restart() }
    else scheduleNext()
    requestPaint()
  }
  onRunningChanged: if (running) resume(); else pause()

  // ---- baked pixel matrix ("#" = knot cell) ---------------------------------
  readonly property var knotRows: [
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

  // ---- derived geometry / animation state -----------------------------------
  property var    cells: []          // [{x,y,s}] grid coords + sparkle seed
  property var    rank: []           // cell index -> position in trace order
  property real   kcx: 0             // filled-cell bbox centre (pulse origin)
  property real   kcy: 0
  property real   maxR: 1            // farthest cell distance from centre
  property int    effect: -1         // -1 idle; 0..4 active micro-animation
  property double t0: 0              // effect start timestamp (ms)
  property double elapsed: 0         // ms into current effect
  property double effectDur: 0
  property var    bag: []            // shuffle-bag of pending effect ids
  property bool   paused: false

  readonly property real  idleA:    0.16       // idle cell alpha (~15-20%)
  readonly property color cMagenta: "#ff2bd6"  // HUD palette anchors
  readonly property color cAmber:   "#ffb300"
  property var hueStops: []          // built onCompleted: accent,magenta,amber

  Component.onCompleted: {
    buildCells()
    requestPaint()
    if (running) scheduleNext()
  }
  onAccentChanged: { buildHueStops(); requestPaint() }
  onPxChanged:     requestPaint()
  onWidthChanged:  requestPaint()
  onHeightChanged: requestPaint()

  function buildHueStops() {
    hueStops = [accent, cMagenta, cAmber, accent] // cyan->magenta->amber->cyan
  }

  function buildCells() {
    var list = [], mnx = 1e9, mxx = -1e9, mny = 1e9, mxy = -1e9
    for (var y = 0; y < rows; y++) {
      var row = knotRows[y] || ""
      for (var x = 0; x < cols; x++) {
        if (row.charAt(x) === "#") {
          list.push({ x: x, y: y, s: Math.random() })
          if (x < mnx) mnx = x; if (x > mxx) mxx = x
          if (y < mny) mny = y; if (y > mxy) mxy = y
        }
      }
    }
    cells = list
    kcx = (mnx + mxx) / 2; kcy = (mny + mxy) / 2
    var mr = 1
    for (var i = 0; i < list.length; i++) {
      var d = Math.sqrt((list[i].x - kcx) * (list[i].x - kcx)
                      + (list[i].y - kcy) * (list[i].y - kcy))
      if (d > mr) mr = d
    }
    maxR = mr
    buildTrace()
    buildHueStops()
  }

  // Greedy nearest-neighbour crawl from the topmost-centre cell — approximates
  // tracing the continuous knot ribbon. O(n^2) once at load (617 cells).
  function buildTrace() {
    var n = cells.length, used = [], order = [], r = new Array(n)
    for (var i = 0; i < n; i++) used.push(false)
    var cur = 0
    for (i = 1; i < n; i++)
      if (cells[i].y < cells[cur].y
       || (cells[i].y === cells[cur].y && Math.abs(cells[i].x - kcx) < Math.abs(cells[cur].x - kcx)))
        cur = i
    for (var k = 0; k < n; k++) {
      order.push(cur); used[cur] = true
      var best = -1, bd = 1e18
      for (var j = 0; j < n; j++) {
        if (used[j]) continue
        var dx = cells[j].x - cells[cur].x, dy = cells[j].y - cells[cur].y
        var dd = dx * dx + dy * dy
        if (dd < bd) { bd = dd; best = j }
      }
      cur = best
    }
    for (k = 0; k < n; k++) r[order[k]] = k
    rank = r
  }

  // ---- scheduler -------------------------------------------------------------
  function scheduleNext() {
    var c = Math.max(30, Math.min(60, cycleSeconds))
    var iv = Math.max(30, Math.min(60, c + (Math.random() * 2 - 1) * 15))
    cycleTimer.interval = Math.round(iv * 1000)   // jittered 30..60 s
    cycleTimer.restart()
  }
  function durFor(e) {                            // effect lifetime, ms
    switch (e) {
      case 0: return 1700                          // scan sweep
      case 1: return 2000                          // pulse ring
      case 2: return 5200                          // draw 2.4s + hold 2s + fade .8s
      case 3: return 3200                          // sparkle
      case 4: return 4400                          // hue rotation
    }
    return 1000
  }
  function startEffect() {
    if (bag.length === 0) {                        // shuffle-bag: all 5, random order
      bag = [0, 1, 2, 3, 4]
      for (var i = bag.length - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1))
        var t = bag[i]; bag[i] = bag[j]; bag[j] = t
      }
    }
    effect = bag.pop()
    effectDur = durFor(effect)
    t0 = Date.now(); elapsed = 0
    fxTimer.restart()
    requestPaint()
  }
  function endEffect() {
    fxTimer.stop(); effect = -1; elapsed = 0
    requestPaint()                                 // settle back to idle dim
    if (running && !paused) scheduleNext()
  }

  Timer {
    id: cycleTimer
    repeat: false
    onTriggered: {
      if (root.running && !root.paused) root.startEffect()
      // paused/stopped: resume() or running:true re-arms the timer
    }
  }
  Timer {
    id: fxTimer                                    // ~30 Hz paint pump
    interval: 33; repeat: true
    onTriggered: {
      root.elapsed = Date.now() - root.t0
      if (root.elapsed >= root.effectDur) root.endEffect()
      else root.requestPaint()
    }
  }

  // ---- colour helpers ---------------------------------------------------------
  function lerpC(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t,
                   a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, 1)
  }
  function hueAt(f) {                              // f in [0,1] around stop ring
    var p = f * (hueStops.length - 1), i = Math.floor(p)
    if (i >= hueStops.length - 1) i = hueStops.length - 2
    return lerpC(hueStops[i], hueStops[i + 1], p - i)
  }
  function rgbaStr(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255)
                 + "," + Math.round(c.b * 255) + "," + a.toFixed(3) + ")"
  }

  // ---- per-cell boost functions ------------------------------------------------
  function boost(i, pr) {                          // pr = effect progress 0..1
    var c = cells[i]
    switch (effect) {
      case 0: {                                    // SCAN: column + short trail
        var pos = -3 + pr * (cols + 6), d = c.x - pos
        var b = Math.max(0, 1 - Math.abs(d) / 2.4)
        if (d < 0) b = Math.max(b, 0.45 * Math.max(0, 1 + d / 9))
        return b
      }
      case 1: {                                    // PULSE: expanding ring
        var dx = c.x - kcx, dy = c.y - kcy
        var R = pr * (maxR + 3), rr = Math.sqrt(dx * dx + dy * dy)
        return Math.max(0, 1 - Math.abs(rr - R) / 3.0)
      }
      case 2: {                                    // DRAW-IN: trace, hold, fade
        var ph = elapsed
        if (ph < 2400) {
          var lit = ph / 2400 * cells.length
          return Math.max(0, Math.min(1, (lit - rank[i]) / 5))
        }
        if (ph < 4400) return 1
        return Math.max(0, 1 - (ph - 4400) / 800)
      }
      case 3: {                                    // SPARKLE: per-cell twinkle
        var v = Math.sin(elapsed * 0.004 * (2 + c.s * 6) + c.s * 40)
        var env = Math.min(1, Math.min(elapsed, effectDur - elapsed) / 400)
        return Math.max(0, (v - 0.45) / 0.55) * env
      }
      case 4: return 0.8                           // TRACE-COLOR: flat bright
    }
    return 0
  }

  // ---- paint --------------------------------------------------------------------
  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    var n = cells.length
    if (n === 0) return

    var cw = width / cols, ch = height / rows
    var ins = Math.max(0.5, Math.min(cw, ch) * 0.07) // pixel grout
    var pr = effectDur > 0 ? Math.min(1, elapsed / effectDur) : 0
    var isHue = (effect === 4)
    var hueF = pr                                  // one full ring over duration

    for (var i = 0; i < n; i++) {
      var b = boost(i, pr)
      var a = idleA + b * 0.84
      if (a > 1) a = 1
      var col = accent
      if (isHue)                                   // slight spatial hue drift
        col = hueAt((hueF + cells[i].x * 0.012 + cells[i].y * 0.008) % 1)
      ctx.fillStyle = rgbaStr(col, a)
      var c = cells[i]
      ctx.fillRect(c.x * cw + ins, c.y * ch + ins, cw - 2 * ins, ch - 2 * ins)
    }
  }
}
