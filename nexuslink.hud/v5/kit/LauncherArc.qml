pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// LauncherArc.qml - v5 launcher: the s2 launcher arc, amended by Marcel 2026-10-23.
//
// Contract (integrator):
//   LauncherArc {
//       apps: [ { slug, label, launchCount, kind } ]   // default set, left to right
//       hero: { slug, label, launchCount }             // optional; Arc Raiders, larger,
//                                                      // always the rightmost tile
//       allApps: [ { slug, label, launchCount } ]      // optional "all apps" list, shown
//                                                      // only while expanded is true
//       expanded: false                                // opens the arc to the full set
//       selectedIndex: -1                              // keyboard index into apps
//       hoverIndex: -1                                 // drawn-order index: apps, then
//                                                      // the expanded extras, then the hero
//       onLaunch: (slug) => ...                        // click, Enter or activate()
//   }
//   Extra helpers for the integrator: step(delta), activate(), launch(slug).
//   The keyboard walks apps only; the hero tile is pointer-only this round.
//
// Shapes and numbers: hud-candidates/comp-r1/s2/src/build.py launcher() (pitch 122,
// tile radius 47, glyph 52, ARC 1.3x, hero gap 40, smile arc rise 80, count ring,
// label under the active tile). Marcel's amendment removes October and the
// Chromium ranking, adds X / Discord / YouTube / WhatsApp and moves Obsidian and
// Spotify into the expanded list.
//
// Icons: each tile loads kit/icons/<slug>.qml by URL and resizes it to the glyph
// box. W4 owns that artwork. A missing glyph is not an error: the tile falls back
// to the slug's first letter drawn as a dot cluster in the same round-point
// language as the swarm, so the arc always renders. Arc Raiders falls back to a
// dotted arch. Interface request for W4 is in the PR body: a bare Item with
// implicitWidth/Height (24 px grid), no required properties.
//
// Motion: Motion.qml states the intent as a continuous zeta/omega pair (5.00
// percent overshoot and 347 ms for expand, no overshoot and 444 ms for return).
// Qt 6.12's SpringAnimation does not implement that pair: it integrates in fixed
// 16 ms substeps, applies the spring term without a dt factor and clamps damping
// to 1.0 (qtdeclarative/src/quick/util/qquickspringanimation.cpp,
// updateCurrentTime). The measured discrete equivalents live in the springs
// section below; tiles keep the 30 ms Motion.staggerTight stagger. Hover and
// selection use scale and dim only: no box, no outline, no glow.
//
// Kit rules: imports QtQuick only, Tokens and Motion for every shared number,
// local readonly properties for values the tokens do not carry yet (token request
// in the PR body). No file I/O, no Process, no timers, no per-frame JS geometry.

Item {
    id: root

    // ---- contract ---------------------------------------------------------
    property var apps: []
    property var hero: null
    property var allApps: []
    property bool expanded: false
    property int selectedIndex: -1
    property int hoverIndex: -1
    signal launch(string slug)

    implicitWidth: 1400
    implicitHeight: 312

    // ---- local metrics (s2 build.py launcher(); token request in PR) ------
    readonly property int tilePitch: 122           // s2: pitch
    readonly property int tileRadius: 47           // s2: rr = 47 * scale
    readonly property int glyphBox: 52             // s2: gpx = 52 * scale
    readonly property real heroScale: 1.3          // s2: ARC tile 1.3x
    readonly property int arcRise: 80              // s2: ends 80 px above the centre
    readonly property int heroGap: 40              // s2: ARC tile sits a little apart
    readonly property int arcBottomInset: 108      // centre row of tiles above the bottom edge
    readonly property int ringDots: 16             // s2: ring = 12; 16 reads as a ring at 1x
    readonly property real ringDotRadius: 2.4      // s2: 2.3 * sqrt(scale); 2.4 with 16 dots reads as a ring
    readonly property int labelDrop: 24            // gap under the ring before the label
    readonly property real hoverScale: 1.2
    readonly property real selectedScale: 1.12
    readonly property real dimOthers: 0.42         // hover/selection dims the rest
    readonly property real restGlyphOpacity: 0.88
    readonly property color restInk: "#d9eef5"     // s2 build.py: glyph at rest

    // ---- springs for Qt 6.12 SpringAnimation ------------------------------
    // Motion's zeta/omega describe a continuous-time system. Qt's SpringAnimation
    // is a fixed 16 ms integrator that clamps damping to [0, 1] and applies the
    // spring term without a dt factor, so feeding 2 * zeta * omega (23.05 for
    // expand) into damping pins it at 1.0 and the response diverges. These are the
    // measured equivalents on Qt 6.12.0 (probe_spring, probe_return,
    // probe_component; numbers in the PR body):
    //   expand 3.1 / 0.285    peak 1.0490 (+4.90 percent) at 274 ms, inside
    //                         2 percent at 390 ms (Motion: 5 percent, 347 ms)
    //   return 1.84 / 0.305   no overshoot, inside 2 percent at 450 to 460 ms
    //                         (Motion: 444 ms)
    // Damping stays inside Qt's clamp, and mass 1.0 is Qt's no-division path.
    readonly property real expandSpring: 3.1
    readonly property real expandDamping: 0.285
    readonly property real returnSpring: 1.84
    readonly property real returnDamping: 0.305

    // ---- drawn order ------------------------------------------------------
    // apps left to right, then the expanded-only entries, then the hero tile.
    // The hero stays rightmost in both states, so the arc grows by inserting the
    // extra apps just before it.
    readonly property var tileList: root.buildTiles()

    readonly property int maxLaunchCount: {
        var m = 1
        var list = root.tileList
        for (var i = 0; i < list.length; ++i)
            m = Math.max(m, list[i].launchCount)
        return m
    }

    readonly property bool anyActive: root.hoverIndex >= 0 || root.selectedIndex >= 0

    function isHero(item) {
        return !!item && (item.kind === "hero" || item.slug === "arc-raiders")
    }

    function hasSlug(list, slug) {
        for (var i = 0; i < list.length; ++i)
            if (list[i] && list[i].slug === slug)
                return true
        return false
    }

    function buildTiles() {
        var out = []
        var defaults = root.apps || []
        var i
        for (i = 0; i < defaults.length; ++i) {
            var a = defaults[i]
            if (!a || !a.slug || root.isHero(a))
                continue
            out.push({ slug: a.slug, label: a.label || a.slug, launchCount: a.launchCount || 0,
                       hero: false, extra: false, defaultIndex: i, running: a.running === true })
        }
        var more = root.allApps || []
        for (i = 0; i < more.length; ++i) {
            var e = more[i]
            if (!e || !e.slug || root.isHero(e) || root.hasSlug(defaults, e.slug))
                continue
            out.push({ slug: e.slug, label: e.label || e.slug, launchCount: e.launchCount || 0,
                       hero: false, extra: true, defaultIndex: -1, running: e.running === true })
        }
        var h = root.hero
        if (!h) {
            for (i = 0; i < defaults.length; ++i)
                if (root.isHero(defaults[i]))
                    h = defaults[i]
        }
        if (h && h.slug) {
            out.push({ slug: h.slug, label: h.label || h.slug, launchCount: h.launchCount || 0,
                       hero: true, extra: false, defaultIndex: -1, running: h.running === true })
        }
        return root.attachPositions(out)
    }

    // x/y per tile for the collapsed and the expanded arc, in component pixels.
    function attachPositions(list) {
        var all = root.layoutFor(list)
        var base = []
        for (var i = 0; i < list.length; ++i)
            if (!list[i].extra)
                base.push(list[i])
        var basePos = root.layoutFor(base)
        var collapsed = ({})
        for (var j = 0; j < base.length; ++j)
            collapsed[base[j].slug] = basePos[j]
        var out = []
        for (var k = 0; k < list.length; ++k) {
            var t = list[k]
            var p0 = collapsed[t.slug]
            var p1 = all[k]
            out.push({ slug: t.slug, label: t.label, launchCount: t.launchCount,
                       hero: t.hero, extra: t.extra, defaultIndex: t.defaultIndex,
                       running: t.running,
                       x0: p0 ? p0.x : p1.x, y0: p0 ? p0.y : p1.y, x1: p1.x, y1: p1.y })
        }
        return out
    }

    function layoutFor(list) {
        var n = list.length
        var widths = []
        var total = 0
        var i
        var s
        for (i = 0; i < n; ++i) {
            s = list[i].hero ? root.heroScale : 1.0
            widths.push(Math.max(root.tilePitch, 2 * root.tileRadius * s + 26))
        }
        for (i = 0; i < n; ++i)
            total += widths[i]
        if (n > 1)
            total += root.heroGap
        var span = Math.max(0, root.width - 48)   // 24 px of air at both ends
        var k = (span > 0 && total > span) ? span / total : 1
        var xs = []
        var acc = 0
        for (i = 0; i < n; ++i) {
            xs.push((acc + widths[i] / 2) * k)
            acc += widths[i]
            if (i === n - 2)
                acc += root.heroGap
        }
        var mid = n > 0 ? (xs[0] + xs[n - 1]) / 2 : 0
        var maxdx = 1
        for (i = 0; i < n; ++i) {
            xs[i] -= mid
            maxdx = Math.max(maxdx, Math.abs(xs[i]))
        }
        var out = []
        for (i = 0; i < n; ++i)
            out.push({ x: xs[i], y: -root.arcRise * Math.pow(xs[i] / maxdx, 2) })
        return out
    }

    // ---- keyboard helpers -------------------------------------------------
    // The deck owns focus; these are the hooks it calls. selectedIndex counts
    // apps only (left to right), so it matches the fixture order.
    function step(delta) {
        var n = (root.apps || []).length
        if (n <= 0)
            return
        var i = root.selectedIndex
        if (i < 0)
            i = delta > 0 ? 0 : n - 1
        else
            i = (i + delta + n) % n
        root.selectedIndex = i
    }

    function activate() {
        var list = root.apps || []
        if (root.selectedIndex >= 0 && root.selectedIndex < list.length)
            root.launch(list[root.selectedIndex].slug)
    }

    Keys.onLeftPressed: root.step(-1)
    Keys.onRightPressed: root.step(1)
    Keys.onReturnPressed: root.activate()
    Keys.onEnterPressed: root.activate()

    // ---- tiles ------------------------------------------------------------
    Repeater {
        model: root.tileList

        Item {
            id: tile

            required property var modelData
            required property int index

            readonly property int unionIndex: index
            readonly property bool heroTile: modelData.hero
            readonly property bool fromExpanded: modelData.extra
            readonly property real baseScale: heroTile ? root.heroScale : 1.0
            readonly property real ringRadius: root.tileRadius * baseScale
            readonly property bool hovered: root.hoverIndex === unionIndex && (!fromExpanded || root.expanded)
            readonly property bool selected: !fromExpanded && root.selectedIndex >= 0
                                            && modelData.defaultIndex === root.selectedIndex
            readonly property bool active: hovered || selected
            readonly property color ink: active ? Tokens.white : root.restInk
            readonly property int litDots: modelData.launchCount > 0
                                           ? Math.max(1, Math.round(modelData.launchCount
                                                                    / root.maxLaunchCount * root.ringDots))
                                           : 0

            // 0 = collapsed arc, 1 = expanded arc. Animated per tile with a stagger.
            property real open: root.expanded ? 1 : 0
            property int stepDelay: 0
            readonly property real presence: fromExpanded
                                              ? Math.max(0, Math.min(1, (open - 0.25) / 0.55))
                                              : 1

            width: 2 * ringRadius
            height: width
            x: root.width / 2 + modelData.x0 + (modelData.x1 - modelData.x0) * open - width / 2
            y: root.height - root.arcBottomInset + modelData.y0 + (modelData.y1 - modelData.y0) * open - height / 2
            scale: hovered ? root.hoverScale : (selected ? root.selectedScale : 1.0)
            opacity: presence * (root.anyActive && !active ? root.dimOthers : 1.0)
            transformOrigin: Item.Center
            z: active ? 2 : 1

            Behavior on scale {
                SpringAnimation {
                    spring: root.expandSpring
                    damping: root.expandDamping
                    mass: 1.0
                    epsilon: 0.001
                }
            }
            Behavior on opacity {
                SpringAnimation {
                    spring: root.returnSpring
                    damping: root.returnDamping
                    mass: 1.0
                    epsilon: 0.001
                }
            }

            Component.onCompleted: open = root.expanded ? 1 : 0

            Connections {
                target: root

                function onExpandedChanged() {
                    tile.stepDelay = (root.expanded ? tile.unionIndex
                                                    : (root.tileList.length - 1 - tile.unionIndex))
                                     * Motion.staggerTight
                    if (root.expanded)
                        expandAnim.restart()
                    else
                        collapseAnim.restart()
                }
            }

            SequentialAnimation {
                id: expandAnim

                PauseAnimation { duration: tile.stepDelay }
                SpringAnimation {
                    target: tile
                    property: "open"
                    to: 1
                    spring: root.expandSpring
                    damping: root.expandDamping
                    mass: 1.0
                    epsilon: 0.0005
                }
            }

            SequentialAnimation {
                id: collapseAnim

                PauseAnimation { duration: tile.stepDelay }
                SpringAnimation {
                    target: tile
                    property: "open"
                    to: 0
                    spring: root.returnSpring
                    damping: root.returnDamping
                    mass: 1.0
                    epsilon: 0.0005
                }
            }

            // launch-count ring: round dots, lit count relative to the busiest app
            Repeater {
                model: root.ringDots

                Rectangle {
                    id: ringDot

                    required property int index

                    readonly property real angle: -Math.PI / 2 + index / root.ringDots * Math.PI * 2
                    readonly property real d: 2 * root.ringDotRadius * Math.sqrt(tile.baseScale)

                    width: d
                    height: d
                    radius: d / 2
                    x: tile.width / 2 + Math.cos(angle) * tile.ringRadius - d / 2
                    y: tile.height / 2 + Math.sin(angle) * tile.ringRadius - d / 2
                    color: Tokens.cyan
                    opacity: index < tile.litDots ? (tile.active ? 1.0 : 0.9) : (tile.active ? 0.34 : 0.26)
                }
            }

            // running now: one acid dot at the bottom of the ring (s2)
            Rectangle {
                visible: tile.modelData.running === true
                width: 8
                height: 8
                radius: 4
                color: Tokens.acid
                x: tile.width / 2 - width / 2
                y: tile.height / 2 + tile.ringRadius + 7
            }

            // glyph: W4 artwork when it lands, dot cluster otherwise
            Item {
                id: glyphBoxItem

                width: root.glyphBox * tile.baseScale
                height: width
                anchors.centerIn: parent
                opacity: tile.active ? 1.0 : root.restGlyphOpacity

                Loader {
                    id: glyphLoader

                    anchors.fill: parent
                    visible: status === Loader.Ready
                    source: "icons/" + tile.modelData.slug + ".qml"
                }

                Repeater {
                    model: glyphLoader.status === Loader.Ready ? [] : tile.glyphDots()

                    Rectangle {
                        required property var modelData

                        width: modelData.d
                        height: width
                        radius: width / 2
                        color: tile.ink
                        x: modelData.x - width / 2
                        y: modelData.y - width / 2
                    }
                }
            }

            function glyphDots() {
                var box = root.glyphBox * tile.baseScale
                return tile.heroTile ? root.archDots(box) : root.letterDots(tile.modelData.slug.charAt(0), box)
            }

            // label under the active tile only (s2 shows it on the hovered tile)
            Text {
                id: nameLabel

                // Centred under the tile, then pulled back inside the component.
                // The tile scales about its centre when hovered, so the clamp is
                // solved in component coordinates with that scale applied: the
                // hero tile sits at the right edge and its label would otherwise
                // cross the 1400 px box when the tile grows.
                readonly property real labelX: {
                    var s = tile.scale > 0 ? tile.scale : 1
                    var centre = tile.x + tile.width / 2
                    var half = width * s / 2
                    var lo = 4 + half
                    var hi = root.width - 4 - half
                    var c = Math.max(lo, Math.min(hi, centre))
                    return (c - centre) / s + (tile.width - width) / 2
                }
                x: labelX
                y: tile.height / 2 + tile.ringRadius + root.labelDrop
                text: tile.modelData.label.toUpperCase()
                color: Tokens.white
                opacity: tile.active ? 1.0 : 0.0
                renderType: Text.NativeRendering
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightMedium
                font.pixelSize: Tokens.sizeCaption
                font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption

                Behavior on opacity {
                    SpringAnimation {
                        spring: root.returnSpring
                        damping: root.returnDamping
                        mass: 1.0
                        epsilon: 0.001
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                enabled: !tile.fromExpanded || root.expanded
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.launch(tile.modelData.slug)
                onEntered: root.hoverIndex = tile.unionIndex
                onExited: {
                    if (root.hoverIndex === tile.unionIndex)
                        root.hoverIndex = -1
                }
            }
        }
    }

    // ---- dot fallback artwork --------------------------------------------
    // 5x7 round-dot letterforms. W4 replaces these with real glyphs; until then
    // the arc draws the app's initial so the tile is never empty.
    readonly property var letterforms: ({
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
        "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
        "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01110"],
        "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
        "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
        "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
        "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
        "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
        "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
        "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
        "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
        "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
        "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
        "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"]
    })

    function letterDots(ch, box) {
        var rows = root.letterforms[String(ch).toUpperCase()] || root.letterforms["A"]
        var cell = box / 7
        var d = cell * 0.62
        var ox = (box - 5 * cell) / 2
        var oy = (box - 7 * cell) / 2
        var out = []
        var seed = String(ch).toUpperCase().charCodeAt(0)
        for (var r = 0; r < 7; ++r) {
            for (var c = 0; c < 5; ++c) {
                if (rows[r].charAt(c) !== "1")
                    continue
                var jx = (((r * 5 + c + seed) % 5) - 2) * cell * 0.035
                var jy = (((r * 3 + c + seed) % 4) - 1.5) * cell * 0.035
                out.push({ x: ox + (c + 0.5) * cell + jx, y: oy + (r + 0.5) * cell + jy, d: d })
            }
        }
        return out
    }

    // Arc Raiders fallback: the s2 arch, drawn as dots on the rim plus two legs.
    // The glyph's own bounds are centred in the box (0.20 to 0.82 of its height)
    // so it sits optically level with the letter tiles.
    function archDots(box) {
        var cell = box / 7
        var d = cell * 0.62
        var cx = box / 2
        var cy = box * 0.52
        var radius = box * 0.32
        var out = []
        // even sample along the rim and both legs so the glyph's bounds are exact
        var domeCount = Math.max(6, Math.round(Math.PI * radius / (1.15 * cell)))
        for (var i = 0; i <= domeCount; ++i) {
            var a = Math.PI + Math.PI * i / domeCount
            out.push({ x: cx + Math.cos(a) * radius, y: cy + Math.sin(a) * radius, d: d })
        }
        var legBottom = box * 0.82
        var legCount = Math.max(1, Math.round((legBottom - cy) / (1.15 * cell)))
        for (var k = 0; k <= legCount; ++k) {
            var yy = cy + (legBottom - cy) * k / legCount
            out.push({ x: cx - radius, y: yy, d: d })
            out.push({ x: cx + radius, y: yy, d: d })
        }
        return out
    }
}
