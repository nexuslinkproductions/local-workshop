pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// FindResults.qml - v5 Find results as typed tiles.
//
// Contract (W6 card plus the 2026-10-23 binding amendment, which wins):
//   results: [{ path: string, kind: string, score: number }]
//            kind is one of "file", "image", "doc", "download".
//   filter: string  "all" | "files" | "images" | "docs" | "downloads"
//   query: string   the live query; path matches stay at full opacity
//
// Rules: no boxes, no outlines, no counts. Tiles are grouped by kind in the
// order file, image, doc, download and separated by space alone. Tiles that
// miss the query or the filter dim into the approved 0.18 to 0.3 band
// (Tokens.focusDim 0.26); matches keep full opacity. The kind is carried by a
// dot mark, never a label: file 12 dots (square), image 16 (diamond), doc 23
// (page plus a text line), download 15 (down arrow). score lifts the mark's dot
// alpha from 0.55 to 0.90, so relevance is visible without a number.
// Everything arrives by property; no process, no file access.
Item {
    id: root

    property var results: []
    property string filter: "all"
    property string query: ""

    // ---- grid -------------------------------------------------------------
    // Tokens carry the base steps; the tile box itself is local geometry and a
    // token request goes in the PR body (tileWidth, tileHeight, resultColumns).
    readonly property int columns: 3
    readonly property int tileWidth: Tokens.sp8 + Tokens.sp5      // 288
    readonly property int tileHeight: 128
    readonly property int colGap: Tokens.sp4                      // 34
    readonly property int rowGap: Tokens.sp5                      // 55
    readonly property int markSize: 56

    readonly property var ordered: orderResults(root.results)
    readonly property int rows: Math.ceil(root.ordered.length / root.columns)

    implicitWidth: columns * tileWidth + (columns - 1) * colGap
    implicitHeight: rows > 0 ? rows * tileHeight + (rows - 1) * rowGap : 0

    // ---- local design values ----------------------------------------------
    // Design numbers that no token carries yet. Each one is a named readonly
    // property so the value has a single home, and each one is a token request
    // in the PR body (markDotFactor, markAlphaRest, markAlphaLift, subtitleGap).
    // markSize 56 above joins the same token list.
    readonly property real markDotFactor: 0.055     // dot radius as a share of markSize
    readonly property real markAlphaRest: 0.55      // dot ice alpha at score 0
    readonly property real markAlphaLift: 0.35      // extra dot alpha at score 1
    readonly property int subtitleGap: 2            // gap under the tile title

    // ---- matching ---------------------------------------------------------
    function kindForFilter(filterName) {
        switch (filterName) {
        case "files": return "file"
        case "images": return "image"
        case "docs": return "doc"
        case "downloads": return "download"
        default: return ""
        }
    }

    function isMatch(item) {
        if (!item || item.path === undefined)
            return false
        var wanted = kindForFilter(root.filter)
        if (wanted !== "" && item.kind !== wanted)
            return false
        var needle = root.query.trim().toLowerCase()
        if (needle.length === 0)
            return true
        return String(item.path).toLowerCase().indexOf(needle) >= 0
    }

    // Grouping is stable: within one kind the incoming (score) order is kept.
    function orderResults(list) {
        if (!list)
            return []
        var groups = ["file", "image", "doc", "download"]
        var out = []
        for (var g = 0; g < groups.length; g++) {
            for (var i = 0; i < list.length; i++) {
                if (list[i] && list[i].kind === groups[g])
                    out.push(list[i])
            }
        }
        for (var j = 0; j < list.length; j++) {
            if (list[j] && groups.indexOf(list[j].kind) < 0)
                out.push(list[j])
        }
        return out
    }

    function baseName(path) {
        var s = String(path === undefined ? "" : path)
        var cut = s.lastIndexOf("/")
        return cut >= 0 ? s.slice(cut + 1) : s
    }

    function parentPath(path) {
        var s = String(path === undefined ? "" : path)
        var cut = s.lastIndexOf("/")
        var dir = cut >= 0 ? s.slice(0, cut) : ""
        var parts = dir.split("/").filter(function (part) { return part.length > 0 })
        if (parts.length === 0)
            return ""
        if (parts.length === 1)
            return parts[0]
        return "\u2026/" + parts.slice(-2).join("/")
    }

    // ---- dot marks --------------------------------------------------------
    // One point set per kind. The counts are deliberately distinct so the kind
    // is readable from the dot count as well as from the silhouette.
    function markPoints(kind, half) {
        var square = [[-0.92, -1], [0.92, -1], [0.92, 1], [-0.92, 1]]
        var diamond = [[0, -1], [1, 0], [0, 1], [-1, 0]]
        var page = [[-0.78, -1], [0.45, -1], [1, -0.42], [1, 1], [-0.78, 1]]
        var points
        switch (kind) {
        case "file":
            return polygonPoints(square, 12, half)
        case "image":
            return polygonPoints(diamond, 16, half)
        case "doc":
            // Page outline plus one row of text dots inside: 23 dots.
            points = polygonPoints(page, 20, half)
            points.push({ x: half * -0.34, y: half * 0.12 })
            points.push({ x: half * 0.0, y: half * 0.12 })
            points.push({ x: half * 0.34, y: half * 0.12 })
            return points
        case "download":
            // Down arrow: stem 5, two chevron strokes 5 each: 15 dots.
            points = linePoints([0, -1], [0, 0.18], 5, half)
            points = points.concat(linePoints([-0.78, -0.16], [0, 0.66], 5, half))
            points = points.concat(linePoints([0.78, -0.16], [0, 0.66], 5, half))
            return points
        default:
            return polygonPoints(diamond, 16, half)
        }
    }

    function linePoints(a, b, count, half) {
        var points = []
        for (var i = 0; i < count; i++) {
            var f = count > 1 ? i / (count - 1) : 0
            points.push({
                x: half * (a[0] + (b[0] - a[0]) * f),
                y: half * (a[1] + (b[1] - a[1]) * f)
            })
        }
        return points
    }

    // Even spacing along a closed polygon, in the polygon's own units, then
    // scaled by `half` to pixels. Pure data at creation: no per-frame geometry.
    function polygonPoints(poly, count, half) {
        var segments = []
        var total = 0
        for (var i = 0; i < poly.length; i++) {
            var from = poly[i]
            var to = poly[(i + 1) % poly.length]
            var dx = to[0] - from[0]
            var dy = to[1] - from[1]
            var len = Math.sqrt(dx * dx + dy * dy)
            segments.push({ from: from, to: to, len: len })
            total += len
        }
        var points = []
        for (var k = 0; k < count; k++) {
            var walked = total * k / count
            var s = 0
            while (s < segments.length - 1 && walked > segments[s].len) {
                walked -= segments[s].len
                s++
            }
            var f = segments[s].len > 0 ? walked / segments[s].len : 0
            points.push({
                x: half * (segments[s].from[0] + (segments[s].to[0] - segments[s].from[0]) * f),
                y: half * (segments[s].from[1] + (segments[s].to[1] - segments[s].from[1]) * f)
            })
        }
        return points
    }

    // ---- tiles ------------------------------------------------------------
    Repeater {
        model: root.ordered

        delegate: Item {
            id: tile
            required property var modelData
            required property int index

            width: root.tileWidth
            height: root.tileHeight
            x: (index % root.columns) * (root.tileWidth + root.colGap)
            y: Math.floor(index / root.columns) * (root.tileHeight + root.rowGap)
            opacity: root.isMatch(modelData) ? 1.0 : Tokens.focusDim

            Behavior on opacity {
                NumberAnimation {
                    duration: Motion.scrimMillis
                    easing.type: Easing.OutCubic
                }
            }

            // Kind mark: dots only, distinct count per kind, no label.
            Repeater {
                model: root.markPoints(tile.modelData.kind, root.markSize / 2)

                delegate: Rectangle {
                    id: markDot
                    required property var modelData

                    readonly property real dotRadius: root.markSize * root.markDotFactor
                    // score lifts the mark from markAlphaRest to rest plus lift.
                    readonly property real markAlpha: root.markAlphaRest + root.markAlphaLift
                                                      * Math.min(1, Math.max(0, tile.modelData.score || 0))

                    x: root.markSize / 2 + modelData.x - dotRadius
                    y: root.markSize / 2 + modelData.y - dotRadius
                    width: dotRadius * 2
                    height: width
                    radius: dotRadius
                    antialiasing: true
                    color: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, markAlpha)
                }
            }

            Text {
                id: title
                x: 0
                y: root.markSize + Tokens.sp2
                width: tile.width
                text: root.baseName(tile.modelData.path)
                color: Tokens.ink
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightMedium
                font.pixelSize: Tokens.sizeBody
                elide: Text.ElideMiddle
            }

            Text {
                x: 0
                y: title.y + title.height + root.subtitleGap
                width: tile.width
                text: root.parentPath(tile.modelData.path)
                color: Tokens.textDim
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightRegular
                font.pixelSize: Tokens.sizeCaption
                elide: Text.ElideMiddle
            }
        }
    }
}
