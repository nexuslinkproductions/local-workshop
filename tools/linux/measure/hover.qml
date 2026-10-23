import QtQuick
import QtTest

// hover.qml - pointer reactivity measurement for the v5 deck (DeckView.qml).
//
// Loads the deck from DECKROOT (sed target) at 2560 x 1440, then sends real
// synthetic pointer events with TestCase.mouseMove and measures:
//   (a) hit map: 64 x 36 grid, 40 px pitch, which WidgetBase reports hovered
//   (b) latency: pointer jumped from outside to a widget centre, grow sampled
//       every few ms plus window frames, peak, overshoot, settle
//   (c) cadence: distinct grow values per 100 ms, frame interval median / p95
//       during the animation and at idle, driftX changes per second at idle
//   (d) launcher arc tile reaction
//
// Widgets are found generically: any item with numeric `grow` and boolean
// `hovered` (WidgetBase). Nothing here names a file except DeckView.qml.
Item {
    id: root
    width: 2560
    height: 1440

    // sed target: absolute path of the directory holding DeckView.qml
    readonly property string deckRoot: "DECKROOT"
    readonly property var theWin: root.Window.window

    property var wlist: []        // [{ it, name, cx, cy, x, y, w, h, holder }]
    property var hitmap: []
    property var latency: []
    property var cadence: ({})
    property var launcher: ({})
    property var proximity: []
    property var sweep: ({})
    property var returnToRest: ({})
    property var frameTs: []
    property bool recording: false
    property bool sweepRecording: false
    property var sweepFrames: []
    property var driftSamples: []

    Loader {
        id: deckLoader
        anchors.fill: parent
        source: root.deckRoot + "/DeckView.qml"
        onLoaded: root.applyFixtures()
        onStatusChanged: if (status === Loader.Error) console.log("MEASURE_ERROR loader failed")
    }

    // same fixture payload as v5/verify/deck.qml
    function applyFixtures() {
        var d = deckLoader.item
        if (!d) return
        d.autoTick = true
        d.shown = true
        d.now = new Date(2026, 9, 23, 1, 2, 0)
        d.crew = [
            { id: "a01748", parent: null, model: "model-a", tools: 33, tokens: 125381, idle_s: 32, title: "Draft beta issues", activity: "starting new turn" },
            { id: "a1d052", parent: null, model: "model-a", tools: 158, tokens: 139559, idle_s: 20, title: "Enable the new mode", activity: "receiving stream response" },
            { id: "683c2c", parent: "a1d052", model: "model-a", tools: 9, tokens: 3645, idle_s: 17, title: "Composition study s1", activity: "receiving stream response" },
            { id: "b2c3d4", parent: null, model: "model-c", tools: 12, tokens: 48210, idle_s: 3600, title: "Review HUD perf PR", activity: "" },
            { id: "c4d5e6", parent: null, model: "model-b", tools: 4, tokens: 9120, idle_s: 7200, title: "Mac fleet digest", activity: "" }
        ]
        d.link = { route: "direct", tunnel: "active",
                   rtt_ms: { median: 7.5, last: 8, min: 5, max: 92,
                             samples: [8, 7, 7, 11, 5, 92, 11, 6, 8, 7, 7, 7, 71, 8, 6, 5, 9, 9, 17, 62, 5, 8, 6, 8] },
                   mac: { load: [3.94, 4.45, 4.81], batt: 100, state: "charged", rem: "0:00", up_min: 13 } }
        d.localAi = ({ present: true, active: false, model: "embeddinggemma", sizeGb: 0.33, vramGb: 0, tokS: 0, activity: 0 })
        d.disks = [
            { label: "ROOT", fs: "btrfs", mount: "/", usedPct: 47, sizeBytes: 1.2e12, usedBytes: 5.64e11, freeBytes: 6.85e11 },
            { label: "T7", fs: "exfat", mount: "/run/media/nexuslink/T7", usedPct: 81, sizeBytes: 1.0e12, usedBytes: 8.1e11, freeBytes: 1.9e11 },
            { label: "KINGSTON", fs: "ntfs3", mount: "/run/media/nexuslink/KINGSTON", usedPct: 72, sizeBytes: 1.0e12, usedBytes: 7.2e11, freeBytes: 2.8e11 },
            { label: "DATA", fs: "ntfs3", mount: "/run/media/nexuslink/DATA", usedPct: 0.4, sizeBytes: 1.0e12, usedBytes: 4.0e9, freeBytes: 9.96e11 }
        ]
        d.apps = [
            { id: "hermes", name: "Hermes", glyph: "hermes", launches: 3, running: true, size: "tile" },
            { id: "devin", name: "Devin", glyph: "devin", launches: 8, running: false, size: "tile" },
            { id: "files", name: "Files", glyph: "files", launches: 2, running: false, size: "tile" },
            { id: "terminal", name: "Terminal", glyph: "terminal", launches: 0, running: false, size: "tile" },
            { id: "chromium", name: "Chromium", glyph: "chrome", launches: 0, running: false, size: "tile" },
            { id: "discord", name: "Discord", glyph: "discord", launches: 3, running: false, size: "tile" },
            { id: "x", name: "X", glyph: "x", launches: 0, running: false, size: "tile" },
            { id: "youtube", name: "YouTube", glyph: "youtube", launches: 0, running: false, size: "tile" },
            { id: "whatsapp", name: "WhatsApp", glyph: "whatsapp", launches: 0, running: false, size: "tile" },
            { id: "arc-raiders", name: "Arc Raiders", glyph: "arc-raiders", launches: 0, running: true, size: "feature" }
        ]
    }

    Connections {
        target: root.theWin
        ignoreUnknownSignals: true
        function onFrameSwapped() {
            var t = Date.now()
            if (root.recording) root.frameTs.push(t)
            if (root.sweepRecording) {
                var ci = root.crewIndex()
                if (ci >= 0 && root.wlist[ci].hs)
                    root.sweepFrames.push([t, root.wlist[ci].hs.scale])
            }
        }
    }

    function crewIndex() {
        for (var i = 0; i < root.wlist.length; i++)
            if (root.wlist[i].name === "CrewWidget")
                return i
        return -1
    }
    function namedIndex(n) {
        for (var i = 0; i < root.wlist.length; i++)
            if (root.wlist[i].name === n)
                return i
        return -1
    }
    function r3(v) { return Math.round(v * 1000) / 1000 }
    function r4(v) { return Math.round(v * 10000) / 10000 }

    // Topmost visible item chain at a deck point, for hit map failures.
    function ownerAt(it, px, py, out) {
        var kids = it.children
        for (var i = kids.length - 1; i >= 0; i--) {
            var c = kids[i]
            if (!c.visible)
                continue
            var p = c.mapToItem(root, 0, 0)
            if (px < p.x || py < p.y || px >= p.x + c.width || py >= p.y + c.height)
                continue
            out.push(root.typeName(c))
            return root.ownerAt(c, px, py, out)
        }
        return out
    }
    function ownerOf(px, py) {
        var out = []
        root.ownerAt(deckLoader.item, px, py, out)
        return out.join(">")
    }

    function typeName(o) {
        var s = String(o)
        var m = /^([A-Za-z_][A-Za-z0-9_]*)_QMLTYPE/.exec(s)
        return m ? m[1] : "Item"
    }

    function collect(it, out) {
        var kids = it.children
        for (var i = 0; i < kids.length; i++) {
            var c = kids[i]
            if (typeof c.grow === "number" && typeof c.hovered === "boolean" && c.hoverScale !== undefined) {
                var p = c.mapToItem(root, 0, 0)
                var holder = null
                for (var k = 0; k < c.children.length; k++)
                    if (typeof c.children[k].scale === "number") { holder = c.children[k]; break }
                out.push({ it: c, name: root.typeName(c), x: p.x, y: p.y, w: c.width, h: c.height,
                           holderScaleProp: holder !== null, hs: holder })
            }
            root.collect(c, out)
        }
    }

    function findLauncher(it) {
        if (it.hoverIndex !== undefined && it.apps !== undefined && typeof it.baseX === "function")
            return it
        for (var i = 0; i < it.children.length; i++) {
            var r = root.findLauncher(it.children[i])
            if (r) return r
        }
        return null
    }

    function median(a) {
        if (!a.length) return -1
        var b = a.slice(0); b.sort(function (x, y) { return x - y })
        return b[Math.floor(b.length / 2)]
    }
    function p95(a) {
        if (!a.length) return -1
        var b = a.slice(0); b.sort(function (x, y) { return x - y })
        return b[Math.min(b.length - 1, Math.floor(b.length * 0.95))]
    }
    function frameIntervals(from, to) {
        var d = []
        for (var i = 1; i < root.frameTs.length; i++) {
            var t = root.frameTs[i]
            if (t < from || t > to) continue
            var p = root.frameTs[i - 1]
            if (p < from) continue
            d.push(t - p)
        }
        return d
    }

    TestCase {
        name: "DeckHover"
        when: root.theWin !== null && deckLoader.status === Loader.Ready

        function initTestCase() {
            root.theWin.width = 2560
            root.theWin.height = 1440
            root.theWin.visible = true
            wait(400)
            root.wlist = []
            root.collect(deckLoader.item, root.wlist)
            console.log("MEASURE_INFO window", root.theWin.width, root.theWin.height,
                        "widgets", root.wlist.length)
            for (var i = 0; i < root.wlist.length; i++) {
                var w = root.wlist[i]
                console.log("MEASURE_INFO widget", i, w.name, Math.round(w.x), Math.round(w.y),
                            Math.round(w.w), Math.round(w.h))
            }
            verify(root.wlist.length > 0)
        }

        // ---- (a) hit map ------------------------------------------------
        function test_10_hitmap() {
            var n = root.wlist.length
            var inside = []
            var hits = []
            var fails = []
            var t00 = Date.now()
            for (var k = 0; k < n; k++) { inside.push(0); hits.push(0); fails.push([]) }
            var points = 0
            for (var j = 0; j < 36; j++) {
                for (var i = 0; i < 64; i++) {
                    var px = 20 + 40 * i
                    var py = 20 + 40 * j
                    mouseMove(root, px, py)
                    wait(1)
                    points++
                    for (var k2 = 0; k2 < n; k2++) {
                        var w = root.wlist[k2].it
                        var inRect = px >= root.wlist[k2].x && px < root.wlist[k2].x + root.wlist[k2].w &&
                                     py >= root.wlist[k2].y && py < root.wlist[k2].y + root.wlist[k2].h
                        if (inRect) inside[k2]++
                        if (w.hovered) {
                            if (inRect) hits[k2]++
                            // hovered while outside the rect: something else is capturing
                        } else if (inRect) {
                            fails[k2].push(px + "," + py)
                        }
                    }
                }
            }
            var out = []
            for (var m = 0; m < n; m++) {
                var own = []
                for (var f = 0; f < Math.min(3, fails[m].length); f++) {
                    var sp = fails[m][f].split(",")
                    own.push(root.ownerOf(parseInt(sp[0], 10), parseInt(sp[1], 10)))
                }
                out.push({ name: root.wlist[m].name,
                           rect: [Math.round(root.wlist[m].x), Math.round(root.wlist[m].y),
                                  Math.round(root.wlist[m].w), Math.round(root.wlist[m].h)],
                           interactive: root.wlist[m].it.interactive !== false,
                           gridInside: inside[m], gridHoveredInside: hits[m],
                           hoverPct: inside[m] > 0 ? Math.round(1000 * hits[m] / inside[m]) / 10 : 0,
                           failPoints: fails[m].slice(0, 12),
                           failOwners: own,
                           failCount: fails[m].length })
            }
            root.hitmap = out
            console.log("MEASURE_HIT points", points, "ms", Date.now() - t00)
            for (var q = 0; q < out.length; q++) {
                var o = out[q]
                console.log("MEASURE_HIT", o.name, "rect", o.rect.join("x"), "inside", o.gridInside,
                            "hovered", o.gridHoveredInside, "pct", o.hoverPct, "fails", o.failCount,
                            (o.failPoints.length ? "e.g. " + o.failPoints.slice(0, 3).join(" ") : ""),
                            (o.failOwners.length ? "owner " + o.failOwners.join(" | ") : ""))
            }
            verify(true)
        }

        // ---- (b) latency per widget -------------------------------------
        function test_20_latency() {
            var out = []
            for (var i = 0; i < root.wlist.length; i++) {
                var w = root.wlist[i]
                var it = w.it
                var cx = Math.round(w.x + w.w / 2)
                var cy = Math.round(w.y + w.h / 2)
                // park far away, long enough for the 444 ms return to settle
                mouseMove(root, 30, 1420)
                wait(750)
                var before = it.grow
                root.frameTs = []
                root.recording = true
                var t0 = Date.now()
                mouseMove(root, cx, cy)
                var s = []
                while (Date.now() - t0 < 900) {
                    wait(3)
                    s.push([Date.now() - t0, it.grow, w.hs ? w.hs.scale : 0])
                }
                root.recording = false
                var f = root.frameTs.slice(0)
                var mx = -1, tmx = 0, t05 = -1, t50 = -1, lastFar = -1
                var tHover = -1
                var series = []
                var buckets = {}
                for (var j = 0; j < s.length; j++) {
                    var g = s[j][1]
                    if (it.hovered && tHover < 0) tHover = s[j][0]
                    if (j < 90) series.push([s[j][0], Math.round(g * 1000) / 1000])
                    if (g > 0.05 && t05 < 0) t05 = s[j][0]
                    if (g > 0.5 && t50 < 0) t50 = s[j][0]
                    if (g > mx) { mx = g; tmx = s[j][0] }
                    if (Math.abs(g - 1) > 0.02) lastFar = s[j][0]
                    var b = Math.floor(s[j][0] / 100)
                    if (buckets[b] === undefined) buckets[b] = []
                    if (buckets[b].indexOf(Math.round(g * 1000)) < 0) buckets[b].push(Math.round(g * 1000))
                }
                var distinctPer100 = []
                for (var b2 = 0; b2 < 4; b2++)
                    distinctPer100.push(buckets[b2] === undefined ? 0 : buckets[b2].length)
                var peakSample = null
                for (var p = 0; p < s.length; p++) if (s[p][1] === mx) { peakSample = s[p]; break }
                out.push({ name: w.name,
                           center: [cx, cy],
                           growBeforeMove: Math.round(before * 1000) / 1000,
                           samples: s.length,
                           msToContainsMouse: tHover,
                           series: w.name === "CrewWidget" ? series : undefined,
                           msToGrow005: t05,
                           msToGrow05: t50,
                           peak: Math.round(mx * 1000) / 1000,
                           peakMs: tmx,
                           holderScaleAtPeak: peakSample ? Math.round(peakSample[2] * 1000) / 1000 : 0,
                           overshootPct: Math.round((mx - 1) * 1000) / 10,
                           settleMs: lastFar,
                           distinctGrowPer100ms: distinctPer100,
                           animFrames: f.length,
                           animFrameMedian: root.median(root.frameIntervals(t0, t0 + 900)),
                           animFrameP95: root.p95(root.frameIntervals(t0, t0 + 900)) })
                console.log("MEASURE_LAT", w.name, "growBefore", Math.round(before * 1000) / 1000,
                            "hoverMs", tHover, "t05", t05, "t50", t50, "peak", Math.round(mx * 1000) / 1000,
                            "peakMs", tmx, "over", Math.round((mx - 1) * 1000) / 10 + "%",
                            "settle", lastFar, "distinct/100ms", distinctPer100.join("/"),
                            "frames", f.length)
            }
            root.latency = out
            verify(true)
        }

        // ---- (c) idle cadence + drift rate ------------------------------
        function test_30_idle() {
            mouseMove(root, 30, 1420)
            wait(900)
            root.frameTs = []
            root.recording = true
            var t0 = Date.now()
            wait(1200)
            root.recording = false
            var fi = root.frameIntervals(t0, Date.now())
            var frames = root.frameTs.length
            // drift change rate on the first widget that has driftX
            var w = root.wlist[0].it
            var drifts = 0, distinctDx = {}, samples = 0
            var polls = 0
            var lastX = null, lastY = null
            var lastTick = null, tickChanges = 0
            var t1 = Date.now()
            while (Date.now() - t1 < 1000) {
                var dx = w.driftX, dy = w.driftY
                var tk = deckLoader.item.tick
                samples++
                if (lastTick !== null && tk !== lastTick) tickChanges++
                if (lastX !== null && dx !== lastX) drifts++
                if (lastX !== null && dy !== lastY) drifts++
                lastX = dx; lastY = dy; lastTick = tk
                distinctDx[Math.round(dx * 1000)] = 1
                wait(1)
                polls++
            }
            var distinctCount = 0
            for (var k in distinctDx) distinctCount++
            var idleMs = Date.now() - t1
            root.cadence = { idleFrames: frames, idleSpanMs: Date.now() - t0,
                             idleFrameMedian: root.median(fi), idleFrameP95: root.p95(fi),
                             driftChangesPerSec: drifts,
                             driftDxChangesPerSec: Math.round(1000 * drifts / idleMs),
                             driftSamples: samples,
                             distinctDriftX: distinctCount,
                             tickChangesPerSec: Math.round(1000 * tickChanges / idleMs),
                             tickHz: -1 }
            console.log("MEASURE_IDLE frames", frames, "span", Date.now() - t0,
                        "median", root.median(fi), "p95", root.p95(fi),
                        "drift changes/sec", drifts, "over ms", idleMs,
                        "distinct driftX", distinctCount, "samples", samples)
            verify(true)
        }

        // ---- (d) launcher arc -------------------------------------------
        function test_40_launcher() {
            var la = root.findLauncher(deckLoader.item)
            if (!la) {
                root.launcher = { found: false }
                console.log("MEASURE_ARC not found")
                verify(true); return
            }
            var rap = la.mapToItem(root, 0, 0)
            var idx = 2
            var tx = rap.x + la.baseX(idx)
            var ty = rap.y + la.arcY(idx)
            mouseMove(root, 30, 1420)
            wait(700)
            var t0 = Date.now()
            mouseMove(root, Math.round(tx), Math.round(ty))
            var s = []
            while (Date.now() - t0 < 600) {
                wait(3)
                s.push([Date.now() - t0, la.hoveredIndex, la.hoverIndex])
            }
            var tIdx = -1
            for (var i = 0; i < s.length; i++) if (s[i][1] >= 0) { tIdx = s[i][0]; break }
            // tile scale via the repeater delegate if reachable
            var maxScale = 0, rep = null
            for (var c = 0; c < la.children.length; c++)
                if (la.children[c].itemAt !== undefined) { rep = la.children[c]; break }
            if (rep && rep.count > idx) {
                var tile = rep.itemAt(idx)
                for (var j = 0; j < 8; j++) { wait(40); if (tile.scale > maxScale) maxScale = tile.scale }
            }
            root.launcher = { found: true, target: [Math.round(tx), Math.round(ty)],
                              msToHoveredIndex: tIdx, hoveredIndex: la.hoveredIndex,
                              baseScale1: la.baseScale(idx),
                              maxTileScale: Math.round(maxScale * 1000) / 1000 }
            console.log("MEASURE_ARC tile", idx, "at", Math.round(tx), Math.round(ty),
                        "msToHoveredIndex", tIdx, "hoveredIndex", la.hoveredIndex,
                        "maxTileScale", Math.round(maxScale * 1000) / 1000)
            verify(true)
        }

        // ---- (b2) proximity path with real pointer events -----------------
        function test_25_proximity() {
            var deck = deckLoader.item
            var ci = root.crewIndex()
            verify(ci >= 0)
            var crew = root.wlist[ci]
            var cx = crew.x + crew.w / 2
            var cy = crew.y + crew.h / 2
            var R = 0.5 * Math.hypot(crew.w, crew.h)
            var dcx = deck.knotCx !== undefined ? deck.knotCx : 1280
            var dcy = deck.knotCy !== undefined ? deck.knotCy : 720
            var vx = dcx - cx, vy = dcy - cy
            var vl = Math.hypot(vx, vy)
            var ux = vx / vl, uy = vy / vl
            var ds = [2.0, 1.4, 1.2, 1.0, 0.8, 0.6, 0.4, 0.2, 0.0]
            var rows = []
            var delivered = 0, checks = 0, maxDx = 0, maxDy = 0
            for (var k = 0; k < ds.length; k++) {
                var d = ds[k] * R
                var px = Math.round(cx + ux * d)
                var py = Math.round(cy + uy * d)
                mouseMove(root, px, py)
                wait(700)
                var t = (1.2 * R - d) / ((1.2 - 0.4) * R)
                t = Math.max(0, Math.min(1, t))
                var expect = t * t * (3 - 2 * t)
                var inArea = px >= crew.x && px < crew.x + crew.w && py >= crew.y && py < crew.y + crew.h
                var dx = Math.abs(deck.pointerX - px)
                var dy = Math.abs(deck.pointerY - py)
                checks++
                if (deck.pointerInside === true && dx <= 2 && dy <= 2) delivered++
                if (dx > maxDx) maxDx = dx
                if (dy > maxDy) maxDy = dy
                rows.push({ dR: ds[k], px: px, py: py, inMouseArea: inArea,
                            expectProximity: root.r3(expect),
                            proximity: root.r3(crew.it.proximity),
                            grow: root.r3(crew.it.grow),
                            holderScale: root.r3(crew.hs ? crew.hs.scale : 0),
                            hovered: crew.it.hovered,
                            pointerInside: deck.pointerInside === true,
                            pointerX: Math.round(deck.pointerX),
                            pointerY: Math.round(deck.pointerY) })
                console.log("MEASURE_PROX dR", ds[k], "at", px, py, "inArea", inArea,
                            "expect", root.r3(expect), "prox", root.r3(crew.it.proximity),
                            "grow", root.r3(crew.it.grow), "scale", root.r3(crew.hs ? crew.hs.scale : 0),
                            "hovered", crew.it.hovered, "inside", deck.pointerInside,
                            "pointer", Math.round(deck.pointerX) + "," + Math.round(deck.pointerY))
            }
            // MAC push while CREW is fully grown (last park was the CREW centre)
            var mi = root.namedIndex("MacWidget")
            var li = root.namedIndex("LocalWidget")
            var si = root.namedIndex("StorageWidget")
            var mac = root.wlist[mi]
            var push = { crewGrow: root.r3(crew.it.grow),
                         macPushX: root.r3(mac.it.pushX), macPushY: root.r3(mac.it.pushY),
                         macPushAnimX: root.r3(mac.it.pushAnimX), macPushAnimY: root.r3(mac.it.pushAnimY),
                         localPushX: root.r3(root.wlist[li].it.pushX),
                         localPushY: root.r3(root.wlist[li].it.pushY),
                         storagePushX: root.r3(root.wlist[si].it.pushX),
                         storagePushY: root.r3(root.wlist[si].it.pushY),
                         macGrow: root.r3(mac.it.grow) }
            console.log("MEASURE_PUSH crewGrow", push.crewGrow, "mac push", push.macPushX, push.macPushY,
                        "mac anim", push.macPushAnimX, push.macPushAnimY,
                        "macGrow", push.macGrow)
            root.proximity = { crewCentre: [Math.round(cx), Math.round(cy)], R: root.r3(R),
                               line: [root.r3(ux), root.r3(uy)], rows: rows,
                               handler: { checks: checks, delivered: delivered,
                                          maxDx: Math.round(maxDx), maxDy: Math.round(maxDy) },
                               push: push }
            console.log("MEASURE_PROX_HANDLER checks", checks, "delivered", delivered,
                        "maxDx", Math.round(maxDx), "maxDy", Math.round(maxDy))
            verify(true)
        }

        // ---- (b3) moving target: 1250 px/s across CREW in 16 ms steps ------
        function test_26_sweep() {
            var crew = root.wlist[root.crewIndex()]
            var y = Math.round(crew.y + crew.h / 2)
            var x0 = Math.round(crew.x - 60)
            var x1 = Math.round(crew.x + crew.w + 60)
            mouseMove(root, 30, 1400)
            wait(800)
            root.sweepFrames = []
            root.sweepRecording = true
            var t0 = Date.now()
            var first = -1, last = -1
            for (var x = x0; x <= x1; x += 20) {
                mouseMove(root, x, y)
                if (first < 0) first = Date.now()
                last = Date.now()
                wait(16)
            }
            wait(120)
            root.sweepRecording = false
            var f = root.sweepFrames.slice(0)
            // skip the teleport in: frames in the first 60 ms after the first move
            var jumps = [], dts = []
            for (var i = 2; i < f.length; i++) {
                var dt = f[i][0] - f[i - 1][0]
                if (f[i][0] - first < 60)
                    continue
                jumps.push(Math.abs(f[i][1] - f[i - 1][1]))
                dts.push(dt)
            }
            var mx = 0
            for (var j = 0; j < jumps.length; j++) if (jumps[j] > mx) mx = jumps[j]
            var sum = 0
            for (var k = 0; k < jumps.length; k++) sum += jumps[k]
            var spanPx = x1 - x0
            var spanMs = last - first
            var speed = spanMs > 0 ? Math.round(1000 * spanPx / spanMs) : -1
            root.sweep = { y: y, fromX: x0, toX: x1, stepPx: 20, stepMs: 16,
                           measuredSpeedPxPerSec: speed, frames: f.length,
                           sampledJumps: jumps.length,
                           maxScaleJump: root.r4(mx),
                           medianScaleJump: root.r4(root.median(jumps.map(function (v) { return Math.round(v * 10000) })) / 10000),
                           meanScaleJump: root.r4(jumps.length ? sum / jumps.length : 0),
                           frameDtMedian: root.median(dts),
                           frameDtP95: root.p95(dts) }
            console.log("MEASURE_SWEEP speed", speed, "px/s frames", f.length,
                        "maxScaleJump", root.r4(mx), "meanJump", root.r4(jumps.length ? sum / jumps.length : 0),
                        "dtMedian", root.median(dts), "dtP95", root.p95(dts))
            verify(true)
        }

        // ---- (b4) leave: everything returns to grow 0 and push 0 ----------
        function test_27_return() {
            var deck = deckLoader.item
            var n = root.wlist.length
            // real event: send the pointer far outside the window
            mouseMove(root, -300, -300)
            wait(40)
                    // qmllint disable missing-property
            var insideAfterReal = deck.pointerInside === true
            var forced = false
            var res = null
            for (var pass = 0; pass < 2; pass++) {
                if (pass === 1) {
                    if (insideAfterReal === false)
                        break
                    // TestCase could not deliver a leave; emulate it through the
                    // deck's own test hook so the return path can still be timed.
                    // qmllint disable missing-property
                    deck.pointerOverride = true
                    // qmllint disable missing-property
                    deck.pointerForcedInside = false
                    forced = true
                }
                var t0 = Date.now()
                var tAll = -1
                var maxGrowAt800 = 0, maxPushAt800 = 0
                while (Date.now() - t0 < 1000) {
                    var ok = true
                    for (var i = 0; i < n; i++) {
                        var it = root.wlist[i].it
                        if (Math.abs(it.grow) > 0.005 || Math.abs(it.pushX) > 0.01 || Math.abs(it.pushY) > 0.01)
                            ok = false
                    }
                    var el = Date.now() - t0
                    if (el <= 800 && el >= 760) {
                        for (var m = 0; m < n; m++) {
                            maxGrowAt800 = Math.max(maxGrowAt800, Math.abs(root.wlist[m].it.grow))
                            maxPushAt800 = Math.max(maxPushAt800, Math.abs(root.wlist[m].it.pushX), Math.abs(root.wlist[m].it.pushY))
                        }
                    }
                    if (ok && tAll < 0) { tAll = el; break }
                    wait(5)
                }
                var at = []
                for (var q = 0; q < n; q++) {
                    var w = root.wlist[q].it
                    at.push({ name: root.wlist[q].name, grow: root.r3(w.grow),
                              pushX: root.r3(w.pushX), pushY: root.r3(w.pushY),
                              proximity: root.r3(w.proximity) })
                }
                    // qmllint disable missing-property
                res = { msToAllZero: tAll, pointerInsideAfterLeave: deck.pointerInside === true,
                        forced: forced, at: at, maxGrowAt800: root.r3(maxGrowAt800),
                        maxPushAt800: root.r3(maxPushAt800) }
                if (pass === 1)
                    // qmllint disable missing-property
                    deck.pointerOverride = false
                if (tAll >= 0)
                    break
            }
            root.returnToRest = res || ({ msToAllZero: -1 })
            console.log("MEASURE_RETURN msToAllZero", root.returnToRest.msToAllZero,
                        "insideAfterLeave", root.returnToRest.pointerInsideAfterLeave,
                        "forced", root.returnToRest.forced,
                        "maxGrowAt800", root.returnToRest.maxGrowAt800,
                        "maxPushAt800", root.returnToRest.maxPushAt800)
            verify(true)
        }

        function test_50_emit() {
            var res = { label: root.label, deckRoot: root.deckRoot,
                        scene: [root.width, root.height],
                        platform: Qt.platform.os,
                        hitmap: root.hitmap, latency: root.latency,
                        cadence: root.cadence, launcher: root.launcher,
                        proximity: root.proximity, sweep: root.sweep,
                        returnToRest: root.returnToRest }
            console.log("MEASURE_JSON_BEGIN")
            console.log(JSON.stringify(res))
            console.log("MEASURE_JSON_END")
            verify(true)
        }
    }

    // label is injected by run-measure.sh through sed as well (LABEL marker)
    property string label: "LABEL"
}
