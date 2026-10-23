pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// FindResults.qml - v5 Find results, s3 layout, in absolute deck coordinates.
//
// One enlarged top hit (432, 510, 504 x 650) plus up to six tiles in 3 columns x
// 2 rows (218 x 280; column centres 1280 / 1676 / 2076, row tops 500 / 890).
// Fewer than seven hits fill row-major. Image hits show their thumbnail when the
// file exists. Zero hits with a query and not busy: one line "No match".
//
// Inputs
//   results: [{title?, path, kind, score, source?}] (feed) or the fixture shape
//            [{path, kind, score}]; title defaults to the basename of path.
//   query:   live query, bold in the path line
//   active:  visible only while Find is open
//   busy:    no "No match" while a search runs
//   homeDir: expands a leading ~/ for image thumbnails
// Selection (index into the shown hits): 0 top hit, 1 2 3 top row, 4 5 6 bottom row.
//   moveSelection(dx): Left/Right by 1, clamped.
//   moveRow(dy): Down/Up by 3; from the top hit Down goes to 1 and Up stays.
//   activateSelected(): emits hitActivated(path) with the path as the feed gave it.
Item {
    id: root

    property var results: []
    property string query: ""
    property bool active: false
    property bool busy: false
    property string homeDir: ""
    property int selected: 0

    signal hitActivated(string path)

    // ---- geometry (deck space) ---------------------------------------------
    readonly property int maxHits: 7                     // top hit plus six tiles
    readonly property int topX: 432
    readonly property int topY: 510
    readonly property int topW: 504
    readonly property int topH: 650
    readonly property int tileW: 218                     // s3 tile width, no token
    readonly property int tileH: 280
    readonly property var colCentres: [1280, 1676, 2076]
    readonly property var rowTops: [500, 890]
    readonly property int pathGap: 20
    readonly property int noMatchY: 420
    readonly property real washAlpha: 0.06               // white wash on the selected hit
    readonly property real bulletAlpha: 0.28             // muted bars
    readonly property real foldAlpha: 0.22               // folded corner flap

    readonly property var shown: sliceHits(root.results)
    readonly property int count: shown.length

    // Only what a tile shows; the feed order is kept (score order from the feed).
    function sliceHits(list) {
        var out = []
        if (!list)
            return out
        for (var i = 0; i < list.length && out.length < root.maxHits; i++) {
            if (list[i] && list[i].path !== undefined)
                out.push(list[i])
        }
        return out
    }

    onShownChanged: root.selected = 0
    onActiveChanged: if (!root.active) root.selected = 0

    // ---- selection ------------------------------------------------------------
    function moveSelection(dx) {
        if (root.count === 0)
            return
        root.selected = Math.max(0, Math.min(root.count - 1, root.selected + dx))
    }

    function moveRow(dy) {
        if (root.count === 0)
            return
        if (root.selected === 0) {
            if (dy > 0 && root.count > 1)
                root.selected = 1
            return
        }
        root.selected = Math.max(0, Math.min(root.count - 1, root.selected + dy * 3))
    }

    function activateSelected() {
        if (root.count === 0)
            return
        root.hitActivated(String(root.shown[root.selected].path))
    }

    // ---- text helpers --------------------------------------------------------
    function baseName(path) {
        var s = String(path === undefined ? "" : path)
        var cut = s.lastIndexOf("/")
        return cut >= 0 ? s.slice(cut + 1) : s
    }

    function titleOf(hit) {
        if (hit.title !== undefined && String(hit.title).length > 0)
            return String(hit.title)
        return root.baseName(hit.path)
    }

    function extOf(hit) {
        var name = root.baseName(hit.path)
        var dot = name.lastIndexOf(".")
        return (dot > 0 && dot < name.length - 1) ? name.slice(dot + 1).toLowerCase() : ""
    }

    function badgeText(hit) {
        var e = root.extOf(hit)
        if (e.length > 0 && e.length <= 5)
            return e
        return String(hit.kind || "file")
    }

    function badgeColor(hit) {
        switch (String(hit.kind || "file")) {
        case "md": return Tokens.ice
        case "code": return Tokens.azure
        case "doc": return Tokens.cyan
        case "pdf": return Tokens.white
        case "image": return Tokens.cyan
        case "download": return Tokens.ice
        default: return Tokens.textDim
        }
    }

    // "~/a/b/c.md" -> ".../b/c.md" (the parent and the file).
    function shortPath(path) {
        var parts = String(path).split("/").filter(function (p) { return p.length > 0 })
        if (parts.length <= 2)
            return parts.join("/")
        return "..." + "/" + parts.slice(-2).join("/")
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // The first match of the query is bold; everything else stays plain.
    function matchMarkup(text) {
        var s = String(text)
        var q = root.query.trim()
        var at = q.length > 0 ? s.toLowerCase().indexOf(q.toLowerCase()) : -1
        if (at < 0)
            return root.escapeHtml(s)
        return root.escapeHtml(s.slice(0, at))
             + "<b>" + root.escapeHtml(s.slice(at, at + q.length)) + "</b>"
             + root.escapeHtml(s.slice(at + q.length))
    }

    function fileUrl(path) {
        var p = String(path)
        if (p.indexOf("~/") === 0)
            p = root.homeDir + p.slice(1)
        return p.indexOf("/") === 0 ? "file://" + p : ""
    }

    // ---- page shape ------------------------------------------------------------
    // Doc page with rounded corners and a folded top-right corner (flap f).
    function pagePath(w, h, r, f) {
        return "M " + r + " 0 H " + (w - f) + " L " + w + " " + f
             + " V " + (h - r) + " Q " + w + " " + h + " " + (w - r) + " " + h
             + " H " + r + " Q 0 " + h + " 0 " + (h - r)
             + " V " + r + " Q 0 0 " + r + " 0 Z"
    }

    function flapPath(w, f) {
        return "M " + (w - f) + " 0 V " + f + " H " + w + " Z"
    }

    // White wash over a colour: a = 0.06 is "white 6 percent".
    function washed(c, a) {
        return Qt.rgba(c.r * (1 - a) + a, c.g * (1 - a) + a, c.b * (1 - a) + a, c.a)
    }

    // ---- hits --------------------------------------------------------------------
    Repeater {
        model: root.shown

        delegate: Item {
            id: hit

            required property var modelData
            required property int index

            readonly property bool big: hit.index === 0
            readonly property bool sel: root.selected === hit.index
            readonly property int slot: hit.index - 1
            readonly property int slotCol: hit.slot % 3
            readonly property int slotRow: Math.floor(hit.slot / 3)
            readonly property bool isImage: String(hit.modelData.kind || "") === "image"
            readonly property real cardW: hit.big ? root.topW : root.tileW
            readonly property real cardH: hit.big ? root.topH : root.tileH
            readonly property real pageR: hit.big ? 40 : 28
            readonly property real pageF: hit.big ? 120 : 56
            readonly property color pageBase: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b,
                                                      Tokens.capsuleFillAlpha)
            readonly property color pageFill: hit.sel ? root.washed(hit.pageBase, root.washAlpha)
                                                      : hit.pageBase

            width: hit.cardW
            height: hit.cardH
            x: hit.big ? root.topX : root.colCentres[hit.slotCol] - root.tileW / 2
            y: hit.big ? root.topY : root.rowTops[hit.slotRow]
            visible: root.active
            transformOrigin: Item.Center
            scale: hit.sel ? 1.04 : 1.0

            Behavior on scale {
                NumberAnimation { duration: Motion.textOutMillis; easing.type: Easing.OutCubic }
            }

            // Page (doc kinds): the rounded page with its folded corner.
            Shape {
                anchors.fill: parent
                visible: !hit.isImage

                ShapePath {
                    fillColor: hit.pageFill
                    strokeColor: "transparent"
                    PathSvg { path: root.pagePath(hit.cardW, hit.cardH, hit.pageR, hit.pageF) }
                }

                ShapePath {
                    fillColor: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, root.foldAlpha)
                    strokeColor: "transparent"
                    PathSvg { path: root.flapPath(hit.cardW, hit.pageF) }
                }
            }

            // Image kind: a rounded thumbnail, dark placeholder until the file loads.
            Rectangle {
                anchors.fill: parent
                visible: hit.isImage
                radius: 20
                antialiasing: true
                color: Tokens.field
                clip: true

                Image {
                    anchors.fill: parent
                    asynchronous: true
                    sourceSize: Qt.size(220, 280)
                    fillMode: Image.PreserveAspectCrop
                    source: hit.isImage ? root.fileUrl(hit.modelData.path) : ""
                }
            }

            // Extension badge, top left.
            Rectangle {
                id: badge

                x: hit.big ? 48 : 24
                y: hit.big ? 48 : 24
                width: hit.big ? 74 : 44
                height: hit.big ? 44 : 28
                radius: height / 2
                antialiasing: true
                color: root.badgeColor(hit.modelData)

                Text {
                    anchors.centerIn: parent
                    text: root.badgeText(hit.modelData)
                    color: Tokens.field
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightBold
                    font.pixelSize: hit.big ? 20 : 16
                }
            }

            // Title, three lines at most, elided.
            Text {
                visible: !hit.isImage
                x: hit.big ? 48 : 24
                y: hit.big ? 180 : 84
                width: hit.big ? hit.cardW - 96 : hit.cardW - 48
                text: root.titleOf(hit.modelData)
                color: Tokens.ink
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightMedium
                font.pixelSize: hit.big ? 42 : 20
            }

            // Three muted bars: the doc line motif.
            Repeater {
                model: hit.isImage ? [] : [0, 1, 2]

                delegate: Rectangle {
                    id: bar

                    required property int index

                    readonly property real full: hit.big ? hit.cardW - 96 : hit.cardW - 48
                    x: hit.big ? 48 : 24
                    y: hit.big ? hit.cardH - 136 + bar.index * 34 : hit.cardH - 58 + bar.index * 14
                    width: Math.round(bar.full * (hit.big ? [0.88, 0.68, 0.78][bar.index]
                                                          : [0.88, 0.64, 0.76][bar.index]))
                    height: hit.big ? 12 : 8
                    radius: height / 2
                    antialiasing: true
                    color: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, root.bulletAlpha)
                }
            }

            // Path line under the hit, the matching part bold.
            Text {
                x: 0
                y: hit.cardH + root.pathGap
                width: hit.cardW
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.StyledText
                text: root.matchMarkup(root.shortPath(hit.modelData.path))
                color: Tokens.textCaption
                elide: Text.ElideMiddle
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightRegular
                font.pixelSize: hit.big ? 18 : 16
            }
        }
    }

    // ---- no match ----------------------------------------------------------------
    Text {
        visible: root.active && !root.busy && root.count === 0 && root.query.trim().length > 0
        x: Math.round(Tokens.centreX - width / 2)
        y: root.noMatchY
        text: "No match"
        color: Tokens.textDim
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: 24
    }
}
