pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import "../kit"

// FindPill.qml - the Find overlay, deck sized (2560 x 1440, placed at 0,0).
//
// Rest is only the 380 x 68 pill at 1960,338; nothing else in this item takes
// input while closed. Open glides that pill to 830,226 and widens it to 900,
// drops the chip row on y 346 and lays the hits out in s3 coordinates: one
// 504 x 650 page at 432,510 and six 218 x 280 tiles on column centres 1280,
// 1676, 2076 and row tops 500, 890.
//
// The view owns its keys: arrows move selection, Enter activates, Escape
// closes. DeckV5 owns the window grab and the feed is FindFeed.qml.
Item {
    id: root

    // ---- inputs ---------------------------------------------------------
    property real tick: 0
    property string query: ""
    property string filter: "all"
    property var results: []
    property bool busy: false
    property bool open: false
    property string note: ""

    // ---- outputs --------------------------------------------------------
    // Writable so scenes and the deck can place the selection.
    property int selected: 0
    // thumbnails decode off the GUI thread; a still render scene sets this false so the grab holds pixels
    property bool thumbsAsync: true
    readonly property bool editing: input.activeFocus

    signal openRequested()
    signal queryEdited(string q)
    signal filterPicked(string f)
    signal hitActivated(var hit)
    signal closeRequested()

    // ---- geometry (deck coordinates) ------------------------------------
    readonly property int restX: 1960
    readonly property int restY: 338
    readonly property int restW: 380
    readonly property int pillH: 68
    readonly property int openX: 830
    readonly property int openY: 226
    readonly property int openW: 900
    readonly property int topHitX: 432
    readonly property int topHitY: 510
    readonly property int topHitW: 504
    readonly property int topHitH: 650
    readonly property int tileW: 218
    readonly property int tileH: 280
    readonly property var colCentres: [1280, 1676, 2076]
    readonly property var rowTops: [500, 890]

    implicitWidth: 2560
    implicitHeight: 1440

    // ---- data helpers (tolerant of undefined, null, {}) ------------------
    function hits() {
        var r = root.results
        if (!r || typeof r.length !== "number")
            return []
        return r
    }
    function hitCount() {
        return Math.min(7, hits().length)
    }
    function hitAt(i) {
        var h = hits()
        return (i >= 0 && i < h.length) ? h[i] : null
    }
    function field(h, name, fallback) {
        if (!h || h[name] === undefined || h[name] === null)
            return fallback
        return h[name]
    }
    function extOf(h) {
        var p = String(field(h, "path", ""))
        var dot = p.lastIndexOf(".")
        if (dot < 0 || dot < p.lastIndexOf("/"))
            return String(field(h, "kind", "file"))
        return p.slice(dot + 1).toLowerCase()
    }
    function kindOf(h) {
        var k = String(field(h, "kind", ""))
        if (k !== "")
            return k
        return root.kindForExt(root.extOf(h))
    }
    function kindForExt(e) {
        if (e === "md" || e === "markdown")
            return "md"
        if (e === "pdf")
            return "pdf"
        if (["png", "jpg", "jpeg", "webp", "gif", "bmp", "avif", "svg"].indexOf(e) >= 0)
            return "image"
        if (["rs", "py", "js", "ts", "qml", "sh", "c", "h", "cpp", "json", "yaml", "yml", "toml", "css", "html"].indexOf(e) >= 0)
            return "code"
        if (["doc", "docx", "odt", "rtf", "txt", "org"].indexOf(e) >= 0)
            return "doc"
        return "file"
    }
    function kindColor(h) {
        var k = root.kindOf(h)
        if (k === "md")
            return Tokens.ice
        if (k === "code")
            return Tokens.azure
        if (k === "doc" || k === "pdf")
            return Tokens.cyan
        if (k === "image")
            return Tokens.cyan
        return Tokens.textDim
    }
    function shortPath(h) {
        var p = String(field(h, "path", ""))
        if (p === "")
            return ""
        var parts = p.split("/")
        var clean = []
        for (var i = 0; i < parts.length; ++i)
            if (parts[i].length > 0)
                clean.push(parts[i])
        if (clean.length === 0)
            return p
        var file = clean[clean.length - 1]
        var parent = clean.length > 1 ? clean[clean.length - 2] : ""
        if (file.length > 34)
            file = file.slice(0, 16) + "..." + file.slice(file.length - 14)
        return "..." + (parent !== "" ? "/" + parent + "/" : "/") + file
    }
    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }
    function pathMarkup(h) {
        var safe = escapeHtml(shortPath(h))
        var q = String(root.query)
        if (q === "")
            return safe
        var at = safe.toLowerCase().indexOf(q.toLowerCase())
        if (at < 0)
            return safe
        return safe.slice(0, at) + "<b><font color=\"" + Tokens.white + "\">"
                + safe.slice(at, at + q.length) + "</font></b>" + safe.slice(at + q.length)
    }
    function isImage(h) {
        return root.kindOf(h) === "image"
    }
    function titleOf(h) {
        var t = String(field(h, "title", ""))
        if (t !== "")
            return t
        var p = String(field(h, "path", ""))
        var i = p.lastIndexOf("/")
        return i >= 0 ? p.slice(i + 1) : p
    }
    function fileUrl(h) {
        var p = String(field(h, "path", ""))
        return p === "" ? "" : "file://" + p
    }
    function pageFill(sel) {
        // Soft ice page; the selected page lifts with a white 6 percent wash.
        var a = 0.09
        var b = sel ? 0.06 : 0.0
        var t = a + b
        return Qt.rgba((Tokens.ice.r * a + Tokens.white.r * b) / t,
                       (Tokens.ice.g * a + Tokens.white.g * b) / t,
                       (Tokens.ice.b * a + Tokens.white.b * b) / t, t)
    }

    // ---- selection and keys ---------------------------------------------
    function clampSelection() {
        var n = hitCount()
        if (n === 0)
            selected = 0
        else if (selected > n - 1)
            selected = n - 1
        else if (selected < 0)
            selected = 0
    }
    function moveSelection(delta) {
        if (!open)
            return
        var n = hitCount()
        if (n === 0)
            return
        selected = Math.max(0, Math.min(n - 1, selected + delta))
    }
    function moveRow(dir) {
        if (!open)
            return
        var n = hitCount()
        if (n === 0)
            return
        if (selected === 0) {
            if (dir > 0 && n > 1)
                selected = 1
            return
        }
        selected = Math.max(0, Math.min(n - 1, selected + dir * 3))
    }
    function activateSelected() {
        var h = hitAt(selected)
        if (h)
            root.hitActivated(h)
    }
    function focusInput() {
        if (!open)
            return
        input.forceActiveFocus()
        Qt.callLater(function() {
            if (root.open) {
                input.forceActiveFocus()
                input.cursorPosition = input.text.length
            }
        })
    }
    function releaseFocus() {
        input.focus = false
    }

    onOpenChanged: {
        if (open) {
            clampSelection()
            focusInput()
        } else {
            releaseFocus()
            selected = 0
        }
    }
    onResultsChanged: selected = 0
    onQueryChanged: clampSelection()
    Component.onCompleted: {
        if (open)
            focusInput()
    }

    // ---- dismiss layer (open only) --------------------------------------
    MouseArea {
        id: dismiss
        anchors.fill: parent
        visible: root.open
        enabled: root.open
        acceptedButtons: Qt.LeftButton
        onClicked: {
            root.releaseFocus()
            root.closeRequested()
        }
    }

    // ---- pill ------------------------------------------------------------
    Rectangle {
        id: pill
        z: 30
        x: root.open ? root.openX : root.restX
        y: root.open ? root.openY : root.restY
        width: root.open ? root.openW : root.restW
        height: root.pillH
        radius: height / 2
        // Alpha in the colour, not item opacity: children must stay crisp.
        color: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, root.open ? 0.10 : 0.08)

        Behavior on x {
            NumberAnimation {
                duration: root.open ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.open ? Easing.OutBack : Easing.InOutQuad
                easing.overshoot: 1.22
            }
        }
        Behavior on y {
            NumberAnimation {
                duration: root.open ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.open ? Easing.OutBack : Easing.InOutQuad
                easing.overshoot: 1.22
            }
        }
        Behavior on width {
            NumberAnimation {
                duration: root.open ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.open ? Easing.OutBack : Easing.InOutQuad
                easing.overshoot: 1.22
            }
        }
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        // The pill is the only click target when closed.
        MouseArea {
            anchors.fill: parent
            enabled: true
            hoverEnabled: true
            cursorShape: root.open ? Qt.IBeamCursor : Qt.PointingHandCursor
            onClicked: {
                if (root.open)
                    root.focusInput()
                else
                    root.openRequested()
            }
        }

        // Search glyph: a ring and a round-capped handle, solid fill only.
        Shape {
            id: searchGlyph
            x: root.open ? 36 : 26
            y: (pill.height - height) / 2
            width: 30
            height: 30
            Behavior on x { NumberAnimation { duration: Motion.expandMillis; easing.type: Easing.OutCubic } }

            ShapePath {
                fillColor: "transparent"
                strokeColor: Tokens.white
                strokeWidth: 2.8
                capStyle: ShapePath.RoundCap
                startX: 12.4
                startY: 3.4
                PathAngleArc {
                    centerX: 12.4
                    centerY: 12.4
                    radiusX: 9
                    radiusY: 9
                    startAngle: -90
                    sweepAngle: 360
                }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: Tokens.white
                strokeWidth: 2.8
                capStyle: ShapePath.RoundCap
                startX: 19.1
                startY: 19.1
                PathLine { x: 26.2; y: 26.2 }
            }
        }

        // Rest label and five faint type dots.
        Text {
            id: restWord
            x: 78
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.open
            opacity: root.open ? 0 : 0.62
            text: "Find"
            color: Tokens.white
            font.family: Tokens.fontFamily
            font.pixelSize: 28
            font.weight: 500
            renderType: Text.NativeRendering
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
        Row {
            id: restDots
            visible: !root.open
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 30
            spacing: 12
            Repeater {
                model: 5
                delegate: Rectangle {
                    required property int index
                    width: 10
                    height: 10
                    radius: 5
                    color: Tokens.ice
                    opacity: 0.62 - index * 0.08
                }
            }
        }

        // Typed query.
        TextInput {
            id: input
            z: 2
            x: root.open ? 84 : 78
            y: 0
            width: pill.width - x - (root.busy ? 78 : 44)
            height: pill.height
            visible: root.open
            enabled: root.open
            focus: root.open
            activeFocusOnPress: true
            selectByMouse: true
            verticalAlignment: TextInput.AlignVCenter
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0
            text: root.query
            color: Tokens.white
            selectionColor: Tokens.azure
            selectedTextColor: Tokens.field
            font.family: Tokens.fontFamily
            font.pixelSize: 30
            font.weight: 500
            renderType: Text.NativeRendering

            onTextEdited: root.queryEdited(text)

            cursorDelegate: Rectangle {
                width: 2
                height: 34
                color: Tokens.ice
                opacity: 0.15 + 0.85 * (0.5 + 0.5 * Math.sin(root.tick * 2 * Math.PI / 1.06))
            }

            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Left) {
                    event.accepted = true
                    root.moveSelection(-1)
                } else if (event.key === Qt.Key_Right) {
                    event.accepted = true
                    root.moveSelection(1)
                } else if (event.key === Qt.Key_Up) {
                    event.accepted = true
                    root.moveRow(-1)
                } else if (event.key === Qt.Key_Down) {
                    event.accepted = true
                    root.moveRow(1)
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    event.accepted = true
                    root.activateSelected()
                } else if (event.key === Qt.Key_Escape) {
                    event.accepted = true
                    root.releaseFocus()
                    root.closeRequested()
                }
            }
        }

        // Busy: three small pulsing dots at the right end of the pill.
        Row {
            visible: root.open && root.busy
            spacing: 7
            x: pill.width - 42 - width
            y: (pill.height - height) / 2
            Repeater {
                model: 3
                delegate: Rectangle {
                    required property int index
                    width: 7
                    height: 7
                    radius: 3.5
                    color: Tokens.ice
                    opacity: 0.25 + 0.75 * Math.max(0, Math.sin(root.tick * 2 * Math.PI / 1.2 - index * 0.8))
                }
            }
        }
    }

    Connections {
        target: root
        function onQueryChanged() {
            if (input.text !== root.query)
                input.text = root.query
        }
    }

    // ---- chips -----------------------------------------------------------
    Item {
        id: chipRow
        z: 25
        visible: root.open
        x: 1280 - width / 2
        y: 346 - height / 2
        width: rowContent.width
        height: 44

        readonly property var chips: [
            { key: "all", word: "All" },
            { key: "files", word: "Files" },
            { key: "images", word: "Images" },
            { key: "docs", word: "Docs" },
            { key: "downloads", word: "Downloads" }
        ]

        Row {
            id: rowContent
            spacing: 40
            Repeater {
                model: chipRow.chips
                delegate: Item {
                    id: chip
                    required property var modelData
                    readonly property bool active: root.filter === chip.modelData.key
                    readonly property bool hot: chipArea.containsMouse
                    width: active ? 96 : 28
                    height: 44

                    Rectangle {
                        visible: chip.active
                        anchors.fill: parent
                        radius: height / 2
                        color: Tokens.ice
                        opacity: 0.16
                    }

                    Item {
                        id: chipGlyph
                        x: chip.active ? 16 : 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: 28
                        height: 28
                        opacity: chip.active ? 0.95 : (chip.hot ? 0.92 : 0.62)

                        // All: four solid dots.
                        Grid {
                            visible: chip.active && chip.modelData.key === "all"
                            x: 2
                            y: 2
                            columns: 2
                            spacing: 4
                            Repeater {
                                model: 4
                                delegate: Rectangle {
                                    width: 9
                                    height: 9
                                    radius: 2.6
                                    color: Tokens.white
                                }
                            }
                        }
                        // Files: folder silhouette.
                        Item {
                            visible: !chip.active && chip.modelData.key === "files"
                            x: 1
                            y: 5
                            width: 26
                            height: 19
                            Rectangle {
                                x: 0
                                y: 3
                                width: 13
                                height: 7
                                radius: 2.5
                                color: Tokens.textDim
                            }
                            Rectangle {
                                y: 6
                                width: 26
                                height: 13
                                radius: 3
                                color: Tokens.textDim
                            }
                        }
                        // Images: frame bars, a sun and two hills.
                        Item {
                            visible: !chip.active && chip.modelData.key === "images"
                            anchors.fill: parent
                            Rectangle { x: 1; y: 5; width: 26; height: 3.4; radius: 1.7; color: Tokens.textDim }
                            Rectangle { x: 1; y: 21; width: 26; height: 3.4; radius: 1.7; color: Tokens.textDim }
                            Rectangle { x: 1; y: 5; width: 3.4; height: 19.4; radius: 1.7; color: Tokens.textDim }
                            Rectangle { x: 23.6; y: 5; width: 3.4; height: 19.4; radius: 1.7; color: Tokens.textDim }
                            Rectangle { x: 16.5; y: 9.5; width: 5; height: 5; radius: 2.5; color: Tokens.textDim }
                            Shape {
                                x: 3; y: 12; width: 22; height: 11
                                ShapePath {
                                    fillColor: Tokens.textDim
                                    strokeColor: "transparent"
                                    startX: 0
                                    startY: 11
                                    PathLine { x: 7; y: 2 }
                                    PathLine { x: 13; y: 8 }
                                    PathLine { x: 17; y: 4 }
                                    PathLine { x: 22; y: 11 }
                                }
                            }
                        }
                        // Docs: page with a cut top-right corner.
                        Shape {
                            visible: !chip.active && chip.modelData.key === "docs"
                            anchors.fill: parent
                            ShapePath {
                                fillColor: Tokens.textDim
                                strokeColor: "transparent"
                                startX: 6
                                startY: 2
                                PathLine { x: 18; y: 2 }
                                PathLine { x: 24; y: 8 }
                                PathLine { x: 24; y: 26 }
                                PathLine { x: 6; y: 26 }
                            }
                        }
                        // Downloads: tray with an arrow.
                        Item {
                            visible: !chip.active && chip.modelData.key === "downloads"
                            anchors.fill: parent
                            Rectangle { x: 3; y: 21; width: 22; height: 3.4; radius: 1.7; color: Tokens.textDim }
                            Rectangle { x: 3; y: 16; width: 3.4; height: 8; radius: 1.7; color: Tokens.textDim }
                            Rectangle { x: 21.6; y: 16; width: 3.4; height: 8; radius: 1.7; color: Tokens.textDim }
                            Rectangle { x: 12.6; y: 4; width: 3; height: 9; radius: 1.5; color: Tokens.textDim }
                            Shape {
                                x: 8; y: 10; width: 12; height: 8
                                ShapePath {
                                    fillColor: Tokens.textDim
                                    strokeColor: "transparent"
                                    startX: 0
                                    startY: 0
                                    PathLine { x: 12; y: 0 }
                                    PathLine { x: 6; y: 8 }
                                }
                            }
                        }
                    }

                    Text {
                        visible: chip.active && chip.modelData.key === "all"
                        anchors.verticalCenter: parent.verticalCenter
                        x: 50
                        text: "All"
                        color: Tokens.white
                        font.family: Tokens.fontFamily
                        font.pixelSize: 20
                        font.weight: 500
                        renderType: Text.NativeRendering
                    }

                    MouseArea {
                        id: chipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.selected = 0
                            root.filterPicked(chip.modelData.key)
                        }
                    }
                }
            }
        }
    }

    // ---- results ---------------------------------------------------------
    Item {
        id: resultLayer
        z: 10
        anchors.fill: parent
        visible: root.open && root.hitCount() > 0

        // Top hit: one enlarged page.
        Item {
            id: topTile
            x: root.topHitX
            y: root.topHitY
            width: root.topHitW
            height: root.topHitH

            readonly property var hit: root.hitAt(0)
            readonly property bool sel: root.selected === 0
            readonly property bool hot: topArea.containsMouse

            PageShape {
                anchors.fill: parent
                fold: 120
                corner: 40
                fillColor: root.pageFill(topTile.sel || topTile.hot)
            }

            // Image top hit: the page path is filled with the image, so the
            // rounded corners come from the path itself (no effect layer).
            Item {
                anchors.fill: parent
                anchors.margins: 16
                visible: root.isImage(topTile.hit)

                Shape {
                    id: topThumb
                    anchors.fill: parent
                    ShapePath {
                        fillColor: Qt.rgba(Tokens.ink.r, Tokens.ink.g, Tokens.ink.b, 0.35)
                        strokeColor: "transparent"
                        PathRectangle {
                            x: 0
                            y: 0
                            width: topThumb.width
                            height: topThumb.height
                            radius: 24
                        }
                        fillItem: Image {
                            width: topThumb.width
                            height: topThumb.height
                            asynchronous: root.thumbsAsync
                            source: topTile.hit ? root.fileUrl(topTile.hit) : ""
                            sourceSize: Qt.size(504, 650)
                            fillMode: Image.PreserveAspectCrop
                        }
                    }
                }
            }

            // Extension badge.
            Rectangle {
                x: 48
                y: 70
                height: 44
                width: Math.max(74, topBadge.implicitWidth + 28)
                radius: 14
                color: root.kindColor(topTile.hit)
                Text {
                    id: topBadge
                    anchors.centerIn: parent
                    text: root.extOf(topTile.hit).toLowerCase()
                    color: Tokens.field
                    font.family: Tokens.fontFamily
                    font.pixelSize: 20
                    font.weight: 700
                    font.letterSpacing: 0.4
                    renderType: Text.NativeRendering
                }
            }

            Text {
                x: 48
                y: 198
                width: parent.width - 96
                visible: !root.isImage(topTile.hit)
                text: root.titleOf(topTile.hit)
                color: Tokens.white
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
                lineHeight: 1.18
                font.family: Tokens.fontFamily
                font.pixelSize: 42
                font.weight: 500
                renderType: Text.NativeRendering
            }

            // Three muted doc bars near the bottom.
            Repeater {
                model: root.isImage(topTile.hit) ? 0 : 3
                delegate: Rectangle {
                    required property int index
                    x: 48
                    y: 500 + index * 60
                    width: [262, 202, 232][index]
                    height: 12
                    radius: 6
                    color: Tokens.ink
                    opacity: 0.16
                }
            }

            MouseArea {
                id: topArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.selected = 0
                    if (topTile.hit)
                        root.hitActivated(topTile.hit)
                }
            }
        }

        // Muted path line under the top hit.
        Text {
            x: root.topHitX
            y: 1180
            width: root.topHitW
            text: root.hitCount() > 0 ? root.pathMarkup(root.hitAt(0)) : ""
            textFormat: Text.StyledText
            clip: true
            elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignHCenter
            color: Tokens.textCaption
            font.family: Tokens.fontFamily
            font.pixelSize: 18
            font.weight: 400
            renderType: Text.NativeRendering
        }

        // Six tiles in a 3 x 2 grid.
        Repeater {
            model: Math.max(0, root.hitCount() - 1)
            delegate: Item {
                id: tile
                required property int index
                readonly property int idx: index + 1
                readonly property int col: index % 3
                readonly property int row: Math.floor(index / 3)
                readonly property var hit: root.hitAt(idx)
                readonly property bool sel: root.selected === idx
                x: root.colCentres[col] - root.tileW / 2
                y: root.rowTops[row]
                width: root.tileW
                height: root.tileH
                property real rise: 0

                PageShape {
                    id: tilePage
                    anchors.fill: parent
                    fold: 56
                    corner: 28
                    fillColor: root.pageFill(tile.sel || tileArea.containsMouse)
                    scale: tile.sel ? 1.04 : 1.0
                    transformOrigin: Item.Center
                    Behavior on scale { NumberAnimation { duration: Motion.expandMillis; easing.type: Easing.OutBack; easing.overshoot: 1.22 } }
                }

                Item {
                    anchors.fill: parent
                    scale: tile.sel ? 1.04 : 1.0
                    transformOrigin: Item.Center
                    Behavior on scale { NumberAnimation { duration: Motion.expandMillis; easing.type: Easing.OutBack; easing.overshoot: 1.22 } }

                    // Image thumbnail: the page path is filled with the image,
                    // so the corners are round without an effect layer.
                    Item {
                        anchors.fill: parent
                        anchors.margins: 8
                        visible: root.isImage(tile.hit)

                        Shape {
                            id: tileThumb
                            anchors.fill: parent
                            ShapePath {
                                fillColor: Qt.rgba(Tokens.ink.r, Tokens.ink.g, Tokens.ink.b, 0.35)
                                strokeColor: "transparent"
                                PathRectangle {
                                    x: 0
                                    y: 0
                                    width: tileThumb.width
                                    height: tileThumb.height
                                    radius: 18
                                }
                                fillItem: Image {
                                    width: tileThumb.width
                                    height: tileThumb.height
                                    asynchronous: root.thumbsAsync
                                    source: tile.hit ? root.fileUrl(tile.hit) : ""
                                    sourceSize: Qt.size(220, 280)
                                    fillMode: Image.PreserveAspectCrop
                                }
                            }
                        }
                    }

                    // Tile badge.
                    Rectangle {
                        x: 20
                        y: 28
                        height: 28
                        width: Math.max(44, tileBadge.implicitWidth + 18)
                        radius: 10
                        color: root.kindColor(tile.hit)
                        Text {
                            id: tileBadge
                            anchors.centerIn: parent
                            text: root.extOf(tile.hit).toLowerCase()
                            color: Tokens.field
                            font.family: Tokens.fontFamily
                            font.pixelSize: 16
                            font.weight: 700
                            renderType: Text.NativeRendering
                        }
                    }

                    Text {
                        x: 20
                        y: 84
                        width: parent.width - 40
                        visible: !root.isImage(tile.hit)
                        text: root.titleOf(tile.hit)
                        color: Tokens.white
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        lineHeight: 1.18
                        font.family: Tokens.fontFamily
                        font.pixelSize: 20
                        font.weight: 500
                        renderType: Text.NativeRendering
                    }

                    Repeater {
                        model: root.isImage(tile.hit) ? 0 : 3
                        delegate: Rectangle {
                            required property int index
                            x: 20
                            y: 212 + index * 16
                            width: [120, 96, 108][index]
                            height: 8
                            radius: 4
                            color: Tokens.ink
                            opacity: 0.16
                        }
                    }
                }

                MouseArea {
                    id: tileArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.selected = tile.idx
                        if (tile.hit)
                            root.hitActivated(tile.hit)
                    }
                }
            }
        }
    }

    // Path line under each tile, centred, outside the scaled page.
    Repeater {
        model: Math.max(0, root.hitCount() - 1)
        delegate: Text {
            required property int index
            readonly property int idx: index + 1
            readonly property int col: index % 3
            readonly property int row: Math.floor(index / 3)
            x: root.colCentres[col] - 139
            y: root.rowTops[row] + root.tileH + 20
            width: 278
            text: root.pathMarkup(root.hitAt(idx))
            textFormat: Text.StyledText
            clip: true
            elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignHCenter
            color: Tokens.textCaption
            font.family: Tokens.fontFamily
            font.pixelSize: 16
            font.weight: 400
            renderType: Text.NativeRendering
            visible: root.open
        }
    }

    // ---- honest empty state ---------------------------------------------
    Column {
        visible: root.open && root.hitCount() === 0 && !root.busy && root.query.length > 0
        x: 1280 - width / 2
        y: 392
        spacing: 12

        Text {
            width: 640
            horizontalAlignment: Text.AlignHCenter
            text: "No match"
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: 24
            font.weight: 400
            renderType: Text.NativeRendering
        }
        Text {
            visible: root.note.length > 0
            width: 640
            horizontalAlignment: Text.AlignHCenter
            text: root.note
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: 16
            font.weight: 400
            renderType: Text.NativeRendering
        }
    }

    // ---- page silhouette -------------------------------------------------
    component PageShape: Shape {
        id: page

        property real fold: 56
        property real corner: 28
        property color fillColor: Qt.rgba(0.561, 0.847, 0.910, 0.09)
        property color foldColor: Qt.rgba(0.561, 0.847, 0.910, 0.20)

        ShapePath {
            fillColor: page.fillColor
            strokeColor: "transparent"
            strokeWidth: 0
            startX: page.corner
            startY: 0
            PathLine { x: page.width - page.fold; y: 0 }
            PathLine { x: page.width; y: page.fold }
            PathLine { x: page.width; y: page.height - page.corner }
            PathArc {
                x: page.width - page.corner
                y: page.height
                radiusX: page.corner
                radiusY: page.corner
                direction: PathArc.Clockwise
            }
            PathLine { x: page.corner; y: page.height }
            PathArc {
                x: 0
                y: page.height - page.corner
                radiusX: page.corner
                radiusY: page.corner
                direction: PathArc.Clockwise
            }
            PathLine { x: 0; y: page.corner }
            PathArc {
                x: page.corner
                y: 0
                radiusX: page.corner
                radiusY: page.corner
                direction: PathArc.Clockwise
            }
        }
        ShapePath {
            fillColor: page.foldColor
            strokeColor: "transparent"
            startX: page.width - page.fold
            startY: 0
            PathLine { x: page.width; y: page.fold }
            PathLine { x: page.width - page.fold; y: page.fold }
            PathLine { x: page.width - page.fold; y: 0 }
        }
    }
}
