import QtQuick

// v4 pixel-knot field: variant knot matrices + the transition engine
// ported from candidates/HudV3.qml (PixelKnot), keeping the v3fix invariants:
//   * idleGlow 0.56 canvas alpha x 0.9 host opacity = base ~50% lit
//   * every effect's terminal frame IS the lit base state (envelope -> 0)
//   * pause() settles to base (endEffect repaint), never freezes mid-effect
//   * SCATTER's land-flash fades out over the last 500 ms
//   * effect duration >= the latest cell flight (SCATTER 4900)
// Transition principles follow recon/tte-engine.md: per-cell staggered
// motion, terminal frame locked to base, one timer only while an effect
// runs, shuffle-bag scheduler, durations derived from effect timelines.
//
// Lane B3 — identity layer (variants + per-instance async):
//   * variant picks the weave matrix + colourway: 0 KNOT (acid-lime, the
//     default and DP-1's mark), 1 LINK (cyan/ice twin rings), 2 TREFOIL
//     (magenta/violet), 3 SIGIL (amber reactor iris). `accent` follows the
//     variant colourway unless a caller binds its own; all hues pull from
//     Style.c tokens plus one violet harmonic.
//   * seed feeds a per-instance LCG: cell scatter vectors, cadence jitter,
//     bag order, mirror parity and every per-run effect parameter draw from
//     it, so two screens on different seeds never phase-align. seed < 0
//     auto-draws at completion (still unique per instance); callers pass a
//     stable int (e.g. a screen-name hash) for a deterministic personality.
//   * three new effects ride the SAME cycleTimer/fxTimer pair (no new
//     clock): ORBIT (5 — a lit bead + comet tail runs the trace order),
//     CASCADE (6 — a brightness front sweeps the rows), BEAT (7 — cardiac
//     double-swell rolling outward from the core).
//   * ALTER: each run re-draws effDir/effPhase/effJit from the seeded
//     stream and mirrorFlip alternates, so no effect ever repeats
//     identically on one instance.
//
// Public hooks: variant, seed, accent, idleGlow, play(effect), pause(),
// resume(), settled. Backward compatible — `KnotField { running: false }`
// still paints variant 0's static lit base with zero timers armed.
Canvas {
    id: field

    // ---- public API ------------------------------------------------------
    property int px: 5                     // logical pixel-cell size
    property int variant: 0                // 0 KNOT · 1 LINK · 2 TREFOIL · 3 SIGIL
    property int seed: -1                  // <0 = auto-drawn; stable int = per-screen personality
    property color accent: variantAccent() // knot colour; default follows `variant`
    property int cycleSeconds: 45          // nominal cadence; jittered 30..60 s
    property bool running: true            // master gate (bind to visibility)
    property int tickHz: 20                // paint pump rate while an effect runs
    // Base alpha. Host should hold the field at ~0.9 opacity so the resting
    // knot reads ~50% lit (0.56 x 0.9 = 0.50). Every effect ends on this.
    property real idleGlow: 0.56

    signal settled                         // emitted when the base frame is repainted

    readonly property int cols: 48
    readonly property int rows: 49
    implicitWidth: cols * px
    implicitHeight: rows * px

    // fx: index 0..7, or "scatter"|"assemble"|"pulse"|"sparkle"|"hue"|
    // "orbit"|"cascade"|"beat". No argument / -1 draws the next effect from
    // the shuffle-bag.
    function play(fx) {
        if (effect >= 0)
            endEffect(); // settle to base first — never cut mid-flight
        startEffect(effectId(fx));
    }
    function effectId(fx) {
        if (typeof fx === "string") {
            switch (fx) {
            case "scatter":
                return 0;
            case "assemble":
                return 1;
            case "pulse":
                return 2;
            case "sparkle":
                return 3;
            case "hue":
                return 4;
            case "orbit":
                return 5;
            case "cascade":
                return 6;
            case "beat":
                return 7;
            }
            return -1;
        }
        if (typeof fx === "number")
            return (fx >= 0 && fx <= 7) ? Math.floor(fx) : -1;
        return -1;
    }

    // Interruption path: a pause mid-effect must not leave a scattered or
    // blank frame frozen — settle back to the lit base state first.
    function pause() {
        paused = true;
        cycleTimer.stop();
        if (effect >= 0)
            endEffect();
        else {
            fxTimer.stop();
            paintBase();
        }
    }
    function resume() {
        paused = false;
        if (!running)
            return;
        if (effect >= 0) {
            t0 = Date.now() - elapsed;
            fxTimer.restart();
        } else
            scheduleNext();
        requestPaint();
    }
    onRunningChanged: running ? resume() : pause()

    // ---- baked pixel matrices ("#" = knot cell), one per variant ----------
    // v0 KNOT: the original nexuslink weave (BRIEF-V4 silhouette).
    readonly property var knotRows: ["......................##........................", ".....................####.......................", "....................######......................", "...................########.....................", "...................###..####....................", "..................####...###....................", ".................############...................", ".................###......#####.................", "..............######.......###.##...............", "............##..###........####..##.............", "...........#....###.........###....#............", ".........##....###..........###.....##..........", "........##.....###...........###.....##.........", ".......##......###...........###......##........", "......##.......##............###.......##.......", "......#.......###.............##........#.......", ".....#........###.............###........#......", "....##........###.............###........#......", "....#.........###.............###.........#.....", "....#.........###.............###.........#.....", "...#..........###.............###..........#....", "...#...........#.############.###..........#....", "..##...........##############.###..........#....", "..#..........#########....######.###........#...", "..#........######............###.####.......#...", "..#......######.##...........###.######.....#...", "..#.....#####...###..........###...#####....#...", "..#....####.....###.........###......####...#...", "..#...####......####........###.......####..#...", "..#..####........###.......###.........####.#...", "..#.####.........####......###..........#####...", "..#.###...........####....###............###....", "..#####............###...####.............###...", "...###.............####..###..............####..", "..###...............####.##................###..", "..###................#####................#####.", ".####.................#####...............#.###.", ".####..............##########............##.###.", ".###.#...........######..######..........#...###", "###...#........#######....#########.....########", "#######...##########........####################", "##################.............###############..", "..#############.....................###.#.......", ".........##.........................##..........", "..........##.......................##...........", "............##...................##.............", ".............###...............###..............", "...............####.........####................", "...................#########...................."]

    // v1 LINK: two interlocked rings with weave gaps at the crossings —
    // generated (lane B3): twin circles r13.2 offset ±8.2, under/over erased
    // alternately, lens diamond in the middle.
    readonly property var knotRowsLink: [
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "..............#####...........#####.............",
        "..........############.....############.........",
        "........###############..################.......",
        ".......#######....####.########....#######......",
        "......#####..........#######..........#####.....",
        ".....#####...........#####.#...........#####....",
        "....####.............####..#.............####...",
        "....###.............####.####.............###...",
        "...####............####...####............####..",
        "...###.............###.....###.............###..",
        "..####.............###.....###.............####.",
        "..###.............####.....####.............###.",
        "..###.............###...#...###.............###.",
        "..###.............###..###..###.............###.",
        "..###.............###.#####.###.............###.",
        "..###.............###.#####.###.............###.",
        "..###.............###..###..###.............###.",
        "..###.............###...#...###.............###.",
        "..###.............####.....####.............###.",
        "..####.............###.....###.............####.",
        "...###.............###.....###.............###..",
        "...####............####...####............####..",
        "....###.............####.####.............###...",
        "....####.............#..####.............####...",
        ".....#####...........#.#####...........#####....",
        "......#####..........#######..........#####.....",
        ".......#######....########.####....#######......",
        "........################..###############.......",
        "..........############.....############.........",
        "..............#####...........#####.............",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................"
    ]

    // v2 TREFOIL: parametric trefoil knot ribbon — x = sin t + 2·sin 2t,
    // y = cos t − 2·cos 2t swept at dt 0.0025, stamped 1.45 px (lane B3).
    readonly property var knotRowsTrefoil: [
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "...........######...............######..........",
        "........#############.......#############.......",
        ".......################...################......",
        "......#####.......######.######.......#####.....",
        ".....####...........#########...........####....",
        ".....###..............#####..............###....",
        "....###..............#######..............###...",
        "....###.............####.####.............###...",
        "....###............####...####............###...",
        "....###............###.....###............###...",
        "....###...........####.....####...........###...",
        "....###..........####.......####..........###...",
        "....####.........###.........###.........####...",
        ".....###........####.........####........###....",
        ".....####.......###...........###.......####....",
        "......####.....####...........####.....####.....",
        ".......####....###.............###....####......",
        ".......#####...###.............###...#####......",
        "........#####.###...............###.#####.......",
        "..........#######...............#######.........",
        "...........#######.............#######..........",
        ".............##########...##########............",
        "..............#####################.............",
        "..............###.#############.###.............",
        "..............###...............###.............",
        "..............###...............###.............",
        "..............###...............###.............",
        "..............###...............###.............",
        "..............###...............###.............",
        "..............####.............####.............",
        "...............###.............###..............",
        "...............###.............###..............",
        "................###...........###...............",
        "................####.........####...............",
        ".................####.......####................",
        "..................######.######.................",
        "...................###########..................",
        ".....................#######....................",
        "................................................",
        "................................................"
    ]

    // v3 SIGIL: reactor iris — outer gated ring + mid ring with offset gates,
    // cardinal nodes, inner diamond + filled core (lane B3).
    readonly property var knotRowsSigil: [
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        ".................###.........###................",
        "...............###.............###..............",
        "..............##.................##.............",
        "............##.........###.........##...........",
        "...........##.........#####.........##..........",
        "..........##......#############......##.........",
        ".........##......##....###....##......##........",
        "........##.............................##.......",
        "........#...............................#.......",
        ".......##...............#...............##......",
        ".......#...............###...............#......",
        "......#...............##.##...............#.....",
        "......#....##........##...##........##....#.....",
        ".....##....#........##.....##........#....##....",
        "..........##.......##.......##.......##.........",
        "..........#.......##.........##.......#.........",
        "..........#......##.....#.....##......#.........",
        ".........###....##.....###.....##....###........",
        "........####...##.....#####.....##...####.......",
        "........####...##.....#####.....##...####.......",
        ".........###....##.....###.....##....###........",
        "..........#......##.....#.....##......#.........",
        "..........#.......##.........##.......#.........",
        "..........##.......##.......##.......##.........",
        ".....##....#........##.....##........#....##....",
        "......#....##........##...##........##....#.....",
        "......#...............##.##...............#.....",
        ".......#...............###...............#......",
        ".......##...............#...............##......",
        "........#...............................#.......",
        "........##.............................##.......",
        ".........##......##....###....##......##........",
        "..........##......#############......##.........",
        "...........##.........#####.........##..........",
        "............##.........###.........##...........",
        "..............##.................##.............",
        "...............###.............###..............",
        ".................###.........###................",
        "................................................",
        "................................................",
        "................................................",
        "................................................",
        "................................................"
    ]

    function variantIdx() {
        var v = Math.floor(variant) % 4;
        return v < 0 ? v + 4 : v;
    }
    function matrixFor(v) {
        switch (v) {
        case 1:
            return knotRowsLink;
        case 2:
            return knotRowsTrefoil;
        case 3:
            return knotRowsSigil;
        }
        return knotRows;
    }

    // ---- derived geometry / animation state --------------------------------
    // cells[] carries everything a cycle needs without per-frame allocs:
    //   x,y     grid coords          s    sparkle seed 0..1
    //   sx,sy   scatter vector (cells)    d1,d2  per-cell stagger delays 0..1
    //   ang     polar angle around knot centre 0..1 (hue trace ordering)
    //   rn      radius around knot centre / maxR (pulse ordering)
    property var cells: []
    property var rank: []            // cell index -> position in trace order
    property real kcx: 0             // filled-cell bbox centre (pulse origin)
    property real kcy: 0
    property real maxR: 1            // farthest cell distance from centre
    property int effect: -1          // -1 idle; 0..7 active transition cycle
    property double t0: 0            // effect start timestamp (ms)
    property double elapsed: 0       // ms into current effect
    property double effectDur: 0
    property var bag: []             // shuffle-bag of pending effect ids
    property bool paused: false
    // silhouette micro-variation: every other cycle renders mirrored —
    // the knot is near-symmetric so it stays readable while the field
    // never cycles the exact same frame twice (lane B3: parity seeded)
    property bool mirrorFlip: false

    // ---- per-instance seeded stream (lane B3) -------------------------------
    // One LCG drives every random draw the instance makes — cell scatter
    // vectors, cadence jitter, bag order, mirror parity, per-run effect
    // params — so instances on different seeds run entirely out of phase,
    // and a caller that pins `seed` gets the same personality every launch.
    property int _rs: 1
    property int runCount: 0         // effects played since completion
    property bool firstArm: true     // first cadence arm fires early (phase-in)
    property int effDir: 1           // per-run travel direction (+1/-1)
    property real effPhase: 0        // per-run head-start fraction 0..1
    property real effJit: 1          // per-run pace/shape jitter 0.85..1.15

    function autoSeed() {
        return ((Date.now() % 1000003) ^ Math.floor(Math.random() * 2147483647) ^ ((variant + 1) * 7919)) % 2147483647;
    }
    function reseed() {
        var s = seed >= 0 ? Math.floor(seed) : 1;
        _rs = (s * 1103515245 + 12345 + variantIdx() * 2654435761) % 2147483647;
        if (_rs <= 0)
            _rs = 97;
    }
    function rnd() {
        _rs = (_rs * 1103515245 + 12345) % 2147483648;
        return _rs / 2147483648;
    }

    // Variant colourways — accents ride Style.c tokens; hi/lo are the HUE
    // trace's mid-stops (the two-hue swing between accent and back).
    readonly property color cViolet: "#c86bff" // violet harmonic (no Style token)
    readonly property var variantDefs: [
        {
            "accent": Style.c.accent,
            "hi": Style.c.magenta,
            "lo": Style.c.warn
        }, // 0 KNOT — acid lime (v3 palette)
        {
            "accent": Style.c.accent2,
            "hi": Style.c.magenta,
            "lo": Style.c.accent
        }, // 1 LINK — cyan/ice
        {
            "accent": Style.c.magenta,
            "hi": cViolet,
            "lo": Style.c.accent2
        }, // 2 TREFOIL — magenta/violet
        {
            "accent": Style.c.warn,
            "hi": Style.c.accent,
            "lo": Style.c.accent2
        } // 3 SIGIL — amber
    ]
    function variantAccent() {
        return variantDefs[variantIdx()].accent;
    }
    property var hueStops: []        // built onCompleted: accent,hi,lo,accent

    Component.onCompleted: {
        if (seed < 0)
            seed = autoSeed();
        reseed();
        mirrorFlip = rnd() < 0.5; // seeded silhouette parity
        buildCells();
        requestPaint();
        if (running)
            scheduleNext();
    }
    onSeedChanged: {
        reseed();
        buildCells();
        requestPaint();
    }
    onVariantChanged: {
        reseed();
        buildCells();
        buildHueStops();
        requestPaint();
    }
    onAccentChanged: {
        buildHueStops();
        requestPaint();
    }
    onPxChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onIdleGlowChanged: if (effect < 0)
        requestPaint()

    function buildHueStops() {
        var d = variantDefs[variantIdx()];
        hueStops = [accent, d.hi, d.lo, accent]; // accent -> hi -> lo -> accent
    }

    function buildCells() {
        var mat = matrixFor(variantIdx());
        var list = [], mnx = 1e9, mxx = -1e9, mny = 1e9, mxy = -1e9;
        for (var y = 0; y < rows; y++) {
            var row = mat[y] || "";
            for (var x = 0; x < cols; x++) {
                if (row.charAt(x) === "#") {
                    var a = rnd() * Math.PI * 2;
                    var sl = 5 + rnd() * 11; // scatter distance in cells
                    list.push({
                        "x": x,
                        "y": y,
                        "s": rnd(),
                        "sx": Math.cos(a) * sl,
                        "sy": Math.sin(a) * sl,
                        "d1": rnd(),
                        "d2": rnd(),
                        "ang": 0,
                        "rn": 0
                    });
                    if (x < mnx)
                        mnx = x;
                    if (x > mxx)
                        mxx = x;
                    if (y < mny)
                        mny = y;
                    if (y > mxy)
                        mxy = y;
                }
            }
        }
        cells = list;
        kcx = (mnx + mxx) / 2;
        kcy = (mny + mxy) / 2;
        var mr = 1;
        for (var i = 0; i < list.length; i++) {
            var d = Math.sqrt((list[i].x - kcx) * (list[i].x - kcx) + (list[i].y - kcy) * (list[i].y - kcy));
            if (d > mr)
                mr = d;
        }
        maxR = mr;
        for (i = 0; i < list.length; i++) {
            list[i].ang = (Math.atan2(list[i].y - kcy, list[i].x - kcx) + Math.PI) / (Math.PI * 2);
            list[i].rn = Math.sqrt((list[i].x - kcx) * (list[i].x - kcx) + (list[i].y - kcy) * (list[i].y - kcy)) / mr;
        }
        buildTrace();
        buildHueStops();
    }

    // Greedy nearest-neighbour crawl from the topmost-centre cell — approximates
    // tracing the continuous knot ribbon. O(n^2) once per matrix build.
    function buildTrace() {
        var n = cells.length, used = [], order = [], r = new Array(n);
        for (var i = 0; i < n; i++)
            used.push(false);
        var cur = 0;
        for (i = 1; i < n; i++)
            if (cells[i].y < cells[cur].y || (cells[i].y === cells[cur].y && Math.abs(cells[i].x - kcx) < Math.abs(cells[cur].x - kcx)))
                cur = i;
        for (var k = 0; k < n; k++) {
            order.push(cur);
            used[cur] = true;
            var best = -1, bd = 1e18;
            for (var j = 0; j < n; j++) {
                if (used[j])
                    continue;
                var dx = cells[j].x - cells[cur].x, dy = cells[j].y - cells[cur].y;
                var dd = dx * dx + dy * dy;
                if (dd < bd) {
                    bd = dd;
                    best = j;
                }
            }
            cur = best;
        }
        for (k = 0; k < n; k++)
            r[order[k]] = k;
        rank = r;
    }

    // ---- scheduler -----------------------------------------------------------
    function scheduleNext() {
        var c = Math.max(30, Math.min(60, cycleSeconds));
        var iv;
        if (firstArm) {
            // phase-in: first cycle lands 6..20 s in, drawn from the seeded
            // stream — sibling screens never fire their first effect together
            firstArm = false;
            iv = 6 + rnd() * 14;
        } else {
            iv = Math.max(30, Math.min(60, c + (rnd() * 2 - 1) * 15)); // jittered 30..60 s
        }
        cycleTimer.interval = Math.round(iv * 1000);
        cycleTimer.restart();
    }
    function durFor(e) {
        // effect lifetime, ms — derived from each effect's own cell timeline
        switch (e) {
        case 0:
            return 4900; // SCATTER decompose->recompose — the latest cell's return flight ends at 2300+1300+1200=4800 ms; 4600 truncated it mid-flight (the "cuts off" defect)
        case 1:
            return 3800; // ASSEMBLE column sweep
        case 2:
            return 2200; // PULSE rings
        case 3:
            return 3400; // SPARKLE rain
        case 4:
            return 4600; // HUE trace
        case 5:
            return 5400; // ORBIT comet — one full traversal of the trace order
        case 6:
            return 3800; // CASCADE front
        case 7:
            return 3000; // BEAT double-swell
        }
        return 1000;
    }
    function startEffect(fx) {
        var id = fx;
        if (id === undefined || id < 0 || id > 7) {
            if (bag.length === 0) {
                // shuffle-bag: all 8, seeded draw
                bag = [0, 1, 2, 3, 4, 5, 6, 7];
                for (var i = bag.length - 1; i > 0; i--) {
                    var j = Math.floor(rnd() * (i + 1));
                    var t = bag[i];
                    bag[i] = bag[j];
                    bag[j] = t;
                }
            }
            id = bag.pop();
        }
        effect = id;
        effectDur = durFor(effect);
        mirrorFlip = !mirrorFlip; // alternate silhouette
        // per-run draws — the same effect never repeats identically
        effDir = rnd() < 0.5 ? -1 : 1;
        effPhase = rnd();
        effJit = 0.85 + rnd() * 0.30;
        runCount++;
        t0 = Date.now();
        elapsed = 0;
        fxTimer.restart();
        requestPaint();
    }
    function paintBase() {
        requestPaint(); // settle back to idle lit state
        field.settled();
    }
    function endEffect() {
        fxTimer.stop();
        effect = -1;
        elapsed = 0;
        paintBase();
        if (running && !paused)
            scheduleNext();
    }

    Timer {
        id: cycleTimer
        repeat: false
        onTriggered: {
            if (field.running && !field.paused)
                field.startEffect(-1);
            // paused/stopped: resume() or running:true re-arms the timer
        }
    }
    Timer {
        id: fxTimer // paint pump — effect frames only
        // rides the HUD tick rate; only RUNS while a cycle is active, so an
        // idle knot costs zero timer wakeups and zero repaints
        interval: Math.max(16, Math.round(1000 / Math.max(5, field.tickHz)))
        repeat: true
        onTriggered: {
            field.elapsed = Date.now() - field.t0;
            if (field.elapsed >= field.effectDur)
                field.endEffect();
            else if (field.effVisible())
                field.requestPaint();
        }
    }

    // An item's own `visible` does not reflect hidden ancestors — walk the
    // parent chain (2-4 hops) so hidden/off-role canvases never repaint.
    function effVisible() {
        var p = field;
        while (p !== null && p !== undefined) {
            if (p.visible === false)
                return false;
            p = p.parent;
        }
        return true;
    }

    // ---- colour helpers -------------------------------------------------------
    function lerpC(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
    }
    function hueAt(f) {
        // f in [0,1] around stop ring
        var p = f * (hueStops.length - 1), i = Math.floor(p);
        if (i >= hueStops.length - 1)
            i = hueStops.length - 2;
        if (i < 0)
            i = 0;
        return lerpC(hueStops[i], hueStops[i + 1], Math.max(0, p - i));
    }
    function wrapf(x) {
        return x - Math.floor(x); // phase wrap into [0,1)
    }
    function rgbaStr(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a.toFixed(3) + ")";
    }

    // ---- paint ------------------------------------------------------------------
    // Per-cell state is computed inline (no object allocs in the loop):
    // each cycle yields an alpha `a` plus optional fractional cell offsets
    // ox/oy in grid units and an optional colour override.
    onPaint: {
        var ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        var n = cells.length;
        if (n === 0)
            return;
        var cw = width / cols, ch = height / rows;
        var ins = Math.max(0.5, Math.min(cw, ch) * 0.07); // pixel grout
        var eff = effect;
        var pr = effectDur > 0 ? Math.min(1, elapsed / effectDur) : 0;
        var ms = elapsed;
        var mir = mirrorFlip;
        var base = idleGlow;
        var dir = effDir;

        for (var i = 0; i < n; i++) {
            var c = cells[i];
            var a = base, ox = 0, oy = 0;
            var col = accent;

            if (eff === 0) {
                // SCATTER -> RECONSTRUCT: cells fly apart along their own
                // vectors (staggered by d1) through the first ~55%, hang
                // briefly as debris, then fly home (staggered by d2) and flash
                // as they land — the knot decomposes and reassembles.
                var po = (ms - c.d1 * 1300) / 1100;
                po = po < 0 ? 0 : (po > 1 ? 1 : po);
                po = 1 - (1 - po) * (1 - po); // ease-out launch
                var pi = (ms - 2300 - c.d2 * 1300) / 1200;
                pi = pi < 0 ? 0 : (pi > 1 ? 1 : pi);
                pi = pi * pi * (3 - 2 * pi); // smoothstep return
                var f = po * (1 - pi);
                ox = c.sx * f;
                oy = c.sy * f;
                // land-flash fades out over the last 500 ms so the terminal
                // frame IS the base state instead of a bright cut to idle
                var tail0 = Math.min(1, Math.max(0, (effectDur - ms) / 500));
                a = base * (1 - 0.82 * f) + pi * (1 - f) * 0.72 * tail0;
            } else if (eff === 1) {
                // ASSEMBLE: a build front sweeps across the field (direction
                // re-drawn each run); cells rise into place behind it like a
                // loading pass, hold, then ease back to the idle silhouette.
                var front = -4 + pr * (cols + 10);
                var fx1 = dir > 0 ? c.x : (cols - 1 - c.x);
                var born = (front - fx1 + c.s * 2.5) / 3;
                born = born < 0 ? 0 : (born > 1 ? 1 : born);
                born = born * born * (3 - 2 * born);
                var held = pr < 0.80 ? 1 : Math.max(0, 1 - (pr - 0.80) / 0.20);
                oy = -(1 - born) * 3.5;
                a = (base + born * 0.72) * held + base * (1 - held);
            } else if (eff === 2) {
                // PULSE RINGS: a concentric brightness wave from the knot's
                // centre — expanding or imploding, re-drawn each run.
                var rr = Math.sqrt((c.x - kcx) * (c.x - kcx) + (c.y - kcy) * (c.y - kcy));
                var R = (dir > 0 ? pr : 1 - pr) * (maxR + 3);
                var b = Math.max(0, 1 - Math.abs(rr - R) / 3.0);
                a = base + b * 0.86;
            } else if (eff === 3) {
                // SPARKLE RAIN: random cells flare then decay, drifting a
                // drizzle of lit pixels a couple of cells downward.
                var v = Math.sin(ms * 0.004 * (2 + c.s * 6) + c.s * 40);
                var env = Math.min(1, Math.min(ms, effectDur - ms) / 400);
                var b2 = Math.max(0, (v - 0.45) / 0.55) * env;
                a = base + b2 * 0.86;
                if (b2 > 0.5)
                    oy = (b2 - 0.5) * 2.2;
            } else if (eff === 4) {
                // HUE TRACE: accent sweeps through the knot in polar order —
                // colour walks angle + depth so the trace reads as a swirl
                // around the weave rather than a flat recolour. Direction
                // alternates per run. The envelope eases the lift in and back
                // out so the effect lands on the base state instead of cutting.
                var tail4 = Math.min(1, Math.min(ms, effectDur - ms) / 500);
                a = base + 0.80 * Math.max(0, tail4);
                col = hueAt(wrapf(dir * pr + c.ang * 0.6 + c.rn * 0.25));
            } else if (eff === 5) {
                // ORBIT: a lit bead + comet tail runs the trace order — the
                // continuous ribbon crawl, so the light travels the weave
                // itself. Start phase and direction are per-run draws.
                var rf = rank[i] / n;
                var pos = wrapf(effPhase + dir * Math.min(1, pr * effJit));
                var d5 = dir > 0 ? pos - rf : rf - pos;
                d5 = wrapf(d5);           // distance behind the head along travel
                var env5 = Math.min(1, Math.min(ms, effectDur - ms) / 450);
                var tail5 = Math.max(0, 1 - d5 / (0.10 + effJit * 0.06));
                a = base + env5 * tail5 * tail5 * 0.95;
                if (d5 < 0.02 && a > base) // the bead head burns toward white
                    col = lerpC(accent, Qt.rgba(0.95, 0.98, 1, 1), 0.75 * (1 - d5 / 0.02));
            } else if (eff === 6) {
                // CASCADE: a brightness front sweeps the rows — a wave
                // falling (or rising, direction per run) through the weave,
                // carrying cells a touch along its travel.
                var span = rows + 10;
                var yf = dir > 0 ? -5 + pr * span : rows + 5 - pr * span;
                var env6 = Math.min(1, Math.min(ms, effectDur - ms) / 380);
                var bd = Math.max(0, 1 - Math.abs(c.y + c.s * 1.5 - yf) / 3.4);
                a = base + bd * 0.85 * env6;
                if (bd > 0.35)
                    oy = bd * 1.6 * dir;
            } else if (eff === 7) {
                // BEAT: cardiac double-swell — the core flares first and the
                // ring follows a beat behind (per-cell radial lag via rn).
                var pr7 = Math.min(1, Math.max(0, (pr - c.rn * 0.10) / 0.90));
                var g1 = Math.exp(-Math.pow((pr7 - 0.30) / 0.10, 2));
                var g2 = Math.exp(-Math.pow((pr7 - 0.58) / 0.075, 2)) * 0.70;
                var beat = Math.min(1, g1 + g2);
                var env7 = Math.min(1, Math.min(ms, effectDur - ms) / 300);
                a = base * (1 - 0.30 * beat * env7) + beat * env7 * 0.85;
            }

            var gx = mir ? (cols - 1 - c.x) : c.x;
            if (a > 1)
                a = 1;
            ctx.fillStyle = rgbaStr(col, a);
            ctx.fillRect((gx + ox) * cw + ins, (c.y + oy) * ch + ins, cw - 2 * ins, ch - 2 * ins);
        }
    }
}
