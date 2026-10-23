import QtQuick
import "../kit"

// FindPill.qml - the deck search field.
//
// Rest: a slim soft-fill pill, a glyph built from dots, the word Find, five
// faint type dots. Open: the pill widens to the right (left edge never moves),
// a 26 px input appears, a row of five filter chips sits under it, and results
// arrive as typed tiles (one enlarged top hit, then up to 6 in a 2 x 3 grid).
//
// Left edge is always x 0. Root is sized to the open panel (504 x 640) so the
// results never reflow; the pill fill itself animates 380 to 504.
Item {
    id: root

    // ---- inputs ---------------------------------------------------------
    property real tick: 0
    property string query: ""
    property string filter: "all"
    property var results: []
    property bool busy: false
    property bool open: false

    // ---- outputs --------------------------------------------------------
    readonly property bool editing: input.activeFocus
    signal queryEdited(string q)
    signal filterPicked(string f)
    signal hitActivated(var hit)
    signal closeRequested()

    // ---- geometry -------------------------------------------------------
    readonly property int restW: 380
    readonly property int openW: 504
    readonly property int pillH: 68
    readonly property int panelH: 640
    readonly property real pillW: open ? openW : restW

    implicitWidth: openW
    implicitHeight: panelH

    // ---- data helpers (tolerant of undefined, null, {}) ------------------
    function hits() {
        var r = root.results;
        if (!r || typeof r.length !== "number")
            return [];
        return r;
    }
    function topHit() {
        var h = hits();
        return h.length > 0 ? h[0] : null;
    }
    function field(h, name, fallback) {
        if (!h || h[name] === undefined || h[name] === null)
            return fallback;
        return h[name];
    }
    function kindOf(h) {
        var k = field(h, "kind", "");
        if (k !== "")
            return k;
        var p = String(field(h, "path", ""));
        var dot = p.lastIndexOf(".");
        return dot >= 0 ? p.slice(dot + 1).toLowerCase() : "file";
    }
    function extOf(h) {
        var p = String(field(h, "path", ""));
        var dot = p.lastIndexOf(".");
        if (dot < 0 || dot < p.lastIndexOf("/"))
            return String(kindOf(h));
        return p.slice(dot + 1).toLowerCase();
    }
    function shortPath(h) {
        var p = String(field(h, "path", ""));
        if (p === "")
            return "";
        var parts = p.split("/");
        var clean = [];
        for (var i = 0; i < parts.length; ++i)
            if (parts[i].length > 0)
                clean.push(parts[i]);
        if (clean.length === 0)
            return p;
        var file = clean[clean.length - 1];
        var parent = clean.length > 1 ? clean[clean.length - 2] : "";
        if (file.length > 30)
            file = file.slice(0, 14) + "..." + file.slice(file.length - 12);
        return "..." + (parent !== "" ? "/" + parent + "/" : "/") + file;
    }
    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    // The muted path line, matched query part at weight 700.
    function pathMarkup(h) {
        var plain = shortPath(h);
        var safe = escapeHtml(plain);
        var q = root.query;
        if (q === "" || q === undefined || q === null)
            return safe;
        var needle = escapeHtml(q);
        var low = safe.toLowerCase();
        var at = low.indexOf(needle.toLowerCase());
        if (at < 0)
            return safe;
        return safe.slice(0, at) + "<b>" + safe.slice(at, at + needle.length) + "</b>" + safe.slice(at + needle.length);
    }
    function isImage(h) {
        return kindOf(h) === "image";
    }

    // ---- dot glyphs ------------------------------------------------------
    // Ring of 8 dots plus a 3 dot tail, reads as a magnifier without a line.
    function glyphDots() {
        var out = [];
        for (var i = 0; i < 8; ++i) {
            var a = i * Math.PI / 4 + Math.PI / 8;
            out.push({ x: 30 + 9 * Math.cos(a) - 2.5, y: 30 + 9 * Math.sin(a) - 2.5, s: 5 });
        }
        for (var t = 1; t <= 3; ++t) {
            var d = 9 + t * 6;
            out.push({ x: 30 + d * Math.cos(Math.PI / 4) - 2.5,
                       y: 30 + d * Math.sin(Math.PI / 4) - 2.5,
                       s: 5 - t * 0.6 });
        }
        return out;
    }

    // Filter chip icons: the same dot language, five different matrices.
    function chipPattern(key) {
        if (key === "all")
            return [[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2]];
        if (key === "files")
            return [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [2, 1], [0, 2], [1, 2], [2, 2], [0, 3], [1, 3], [2, 3]];
        if (key === "images")
            return [[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2], [1, 1]];
        if (key === "docs")
            return [[0, 0], [1, 0], [2, 0], [0, 1], [2, 1], [0, 2], [1, 2], [2, 2], [0, 3], [1, 3]];
        return [[1, 0], [1, 1], [1, 2], [0, 3], [1, 3], [2, 3]];
    }
    readonly property var chips: [
        { key: "all", word: "ALL" },
        { key: "files", word: "FILES" },
        { key: "images", word: "IMAGES" },
        { key: "docs", word: "DOCS" },
        { key: "downloads", word: "DOWNLOADS" }
    ]

    // ---- rest pill -------------------------------------------------------
    WidgetBase {
        id: restPill
        width: root.restW
        height: root.pillH
        visible: !root.open
        tick: root.tick
        phase: 0.6
        interactive: true

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Tokens.ice
            opacity: 0.08
        }

        Repeater {
            model: root.glyphDots()
            delegate: Rectangle {
                x: modelData.x
                y: modelData.y
                width: modelData.s
                height: modelData.s
                radius: width / 2
                color: Tokens.ice
                opacity: 0.85
            }
        }

        Text {
            x: 66
            anchors.verticalCenter: parent.verticalCenter
            text: "Find"
            color: Tokens.textLabel
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeLabel
            font.weight: 500
            renderType: Text.NativeRendering
        }

        // Five faint type dots at the right edge.
        Repeater {
            model: 5
            delegate: Rectangle {
                width: 6
                height: 6
                radius: 3
                color: Tokens.ice
                opacity: 0.3
                x: restPill.width - 34 - index * 14
                y: (restPill.height - height) / 2
            }
        }
    }

    // ---- open pill -------------------------------------------------------
    Rectangle {
        id: pillFill
        x: 0
        y: 0
        height: root.pillH
        width: root.open ? root.openW : root.restW
        radius: height / 2
        color: Tokens.ice
        opacity: root.open ? 0.08 : 0
        visible: root.open

        Behavior on width {
            NumberAnimation {
                duration: 347
                easing.type: Easing.OutBack
                easing.overshoot: 1.22
            }
        }
    }

    Item {
        id: openLayer
        x: 0
        y: 0
        width: root.openW
        height: root.panelH
        visible: root.open
        opacity: root.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Repeater {
            model: root.glyphDots()
            delegate: Rectangle {
                x: modelData.x
                y: modelData.y
                width: modelData.s
                height: modelData.s
                radius: width / 2
                color: Tokens.ice
                opacity: 0.7
            }
        }

        TextInput {
            id: input
            x: 66
            y: 0
            width: root.openW - 66 - 44
            height: root.pillH
            verticalAlignment: TextInput.AlignVCenter
            text: root.query
            color: Tokens.ink
            selectionColor: Tokens.azure
            selectedTextColor: Tokens.field
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeBody
            font.weight: 500
            focus: root.open
            activeFocusOnPress: true
            selectByMouse: true

            onTextEdited: root.queryEdited(text)

            cursorDelegate: Rectangle {
                width: 2
                height: 28
                color: Tokens.ice
                // Caret blink without a Timer: a 1.06 s sine on the deck tick.
                opacity: 0.15 + 0.85 * (0.5 + 0.5 * Math.sin(root.tick * 2 * Math.PI / 1.06))
            }

            Keys.onEscapePressed: {
                input.focus = false;
                root.closeRequested();
            }
            Keys.onReturnPressed: {
                var h = root.topHit();
                if (h)
                    root.hitActivated(h);
            }
            Keys.onEnterPressed: {
                var h = root.topHit();
                if (h)
                    root.hitActivated(h);
            }
        }

        // busy: three dots pulsing from the tick, inside the pill at the right
        Row {
            visible: root.busy
            spacing: 6
            x: root.openW - 34 - width
            y: (root.pillH - height) / 2
            Repeater {
                model: 3
                delegate: Rectangle {
                    width: 6
                    height: 6
                    radius: 3
                    color: Tokens.ice
                    y: 0
                    opacity: 0.3 + 0.7 * Math.max(0, Math.sin(root.tick * 2 * Math.PI / 1.2 - index * 0.7))
                }
            }
        }

        // ---- filter chips -------------------------------------------------
        Row {
            id: chipRow
            x: 34
            y: 76
            height: 22
            spacing: 26

            Repeater {
                model: root.chips
                delegate: Item {
                    id: chip
                    height: 22
                    width: chipContent.width
                    readonly property string chipKey: modelData.key
                    readonly property bool active: root.filter === chipKey
                    readonly property bool dimmed: chipKey === "downloads"

                    Row {
                        id: chipContent
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        Item {
                            id: chipIcon
                            width: 20
                            height: 20
                            anchors.verticalCenter: parent.verticalCenter
                            Repeater {
                                model: root.chipPattern(chip.chipKey)
                                delegate: Rectangle {
                                    width: 5
                                    height: 5
                                    radius: 2.5
                                    x: modelData[0] * 7
                                    y: modelData[1] * 5
                                    color: Tokens.ice
                                    opacity: chip.dimmed ? 0.4 : (chip.active ? 0.95 : 0.45)
                                }
                            }
                        }

                        Text {
                            visible: chip.active
                            anchors.verticalCenter: parent.verticalCenter
                            text: chip.chipKey === "downloads" ? "not indexed yet" : chip.chipKey.toUpperCase()
                            color: Tokens.ice
                            opacity: chip.dimmed ? 0.4 : 0.9
                            font.family: Tokens.fontFamily
                            font.pixelSize: 16
                            font.weight: 500
                            font.letterSpacing: Tokens.trackLabel * 16
                            renderType: Text.NativeRendering
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.filterPicked(chip.modelData.key)
                    }
                }
            }
        }

        // ---- results -------------------------------------------------------
        Item {
            id: resultLayer
            x: 0
            y: 102
            width: root.openW
            height: root.panelH - y
            visible: root.hits().length > 0

            // top hit ---------------------------------------------------------
            Item {
                id: topTile
                x: 0
                y: 0
                width: root.openW
                height: 150

                Rectangle {
                    anchors.fill: parent
                    radius: 14
                    color: Tokens.ice
                    opacity: topArea.containsMouse ? 0.16 : 0.10
                    Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                }

                Repeater {
                    model: root.isImage(root.topHit()) ? 0 : 1
                    delegate: Item {
                        x: 24
                        y: 24
                        width: 40
                        height: 46
                        Repeater {
                            model: 24
                            delegate: Rectangle {
                                width: 4
                                height: 4
                                radius: 2
                                color: Tokens.ice
                                opacity: 0.55
                                x: (index % 4) * 10
                                y: Math.floor(index / 4) * 7
                            }
                        }
                    }
                }

                // image placeholder: a soft block with a mountain of dots
                Repeater {
                    model: root.isImage(root.topHit()) ? 1 : 0
                    delegate: Item {
                        x: 24
                        y: 22
                        width: 96
                        height: 62
                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: Tokens.ice
                            opacity: 0.10
                        }
                        Repeater {
                            model: 15
                            delegate: Rectangle {
                                width: 4
                                height: 4
                                radius: 2
                                color: Tokens.ice
                                opacity: 0.6
                                x: 12 + (index % 5) * 7
                                y: 40 - Math.min(index % 5, 5 - index % 5) * 6 - Math.floor(index / 5) * 2
                            }
                        }
                    }
                }

                Text {
                    x: root.isImage(root.topHit()) ? 140 : 80
                    y: 24
                    width: root.openW - x - 100
                    text: String(root.field(root.topHit(), "title", "--"))
                    color: Tokens.ink
                    elide: Text.ElideRight
                    font.family: Tokens.fontFamily
                    font.pixelSize: Tokens.sizeBody
                    font.weight: 500
                    renderType: Text.NativeRendering
                }

                Rectangle {
                    x: root.isImage(root.topHit()) ? 140 : 80
                    y: 62
                    height: 24
                    width: badgeText.implicitWidth + 16
                    radius: 8
                    color: Tokens.ice
                    opacity: 0.10
                    Text {
                        id: badgeText
                        anchors.centerIn: parent
                        text: root.extOf(root.topHit())
                        color: Tokens.textCaption
                        font.family: Tokens.fontFamily
                        font.pixelSize: 16
                        font.weight: 500
                        renderType: Text.NativeRendering
                    }
                }

                Text {
                    x: 24
                    y: 114
                    width: root.openW - 48
                    text: root.pathMarkup(root.topHit())
                    textFormat: Text.StyledText
                    clip: true
                    color: Tokens.textDim
                    font.family: Tokens.fontFamily
                    font.pixelSize: 16
                    font.weight: 400
                    renderType: Text.NativeRendering
                }

                MouseArea {
                    id: topArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.hitActivated(root.topHit())
                }
            }

            // grid: up to 6 more hits, 2 columns, 3 rows
            Grid {
                x: 0
                y: 160
                columns: 2
                rowSpacing: 10
                columnSpacing: 12

                Repeater {
                    model: Math.min(6, Math.max(0, root.hits().length - 1))
                    delegate: Item {
                        id: tile
                        width: 246
                        height: 118
                        readonly property var hit: root.hits()[index + 1]

                        Rectangle {
                            anchors.fill: parent
                            radius: 12
                            color: Tokens.ice
                            opacity: tileArea.containsMouse ? 0.16 : 0.08
                            Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        }

                        // page glyph from dots (md, doc, code, pdf, file)
                        Item {
                            x: 16
                            y: 16
                            width: 26
                            height: 30
                            visible: !root.isImage(tile.hit)
                            Repeater {
                                model: 20
                                delegate: Rectangle {
                                    width: 3.5
                                    height: 3.5
                                    radius: 1.75
                                    color: Tokens.ice
                                    opacity: 0.5
                                    x: (index % 4) * 7
                                    y: Math.floor(index / 4) * 6
                                }
                            }
                        }

                        // image placeholder
                        Item {
                            x: 14
                            y: 14
                            width: 34
                            height: 34
                            visible: root.isImage(tile.hit)
                            Repeater {
                                model: 9
                                delegate: Rectangle {
                                    width: 3.5
                                    height: 3.5
                                    radius: 1.75
                                    color: Tokens.ice
                                    opacity: 0.55
                                    x: 5 + (index % 3) * 9
                                    y: 22 - Math.min(index % 3, 3 - index % 3) * 7
                                }
                            }
                        }

                        Text {
                            x: 54
                            y: 14
                            width: tile.width - 54 - 16 - 46
                            text: String(root.field(tile.hit, "title", "--"))
                            color: Tokens.ink
                            elide: Text.ElideRight
                            font.family: Tokens.fontFamily
                            font.pixelSize: 22
                            font.weight: 500
                            renderType: Text.NativeRendering
                        }

                        Rectangle {
                            x: 54
                            y: 44
                            height: 22
                            width: extLabel.implicitWidth + 12
                            radius: 7
                            color: Tokens.ice
                            opacity: 0.10
                            Text {
                                id: extLabel
                                anchors.centerIn: parent
                                text: root.extOf(tile.hit)
                                color: Tokens.textCaption
                                font.family: Tokens.fontFamily
                                font.pixelSize: 16
                                font.weight: 500
                                renderType: Text.NativeRendering
                            }
                        }

                        Text {
                            x: 16
                            y: 88
                            width: tile.width - 32
                            text: root.pathMarkup(tile.hit)
                            textFormat: Text.StyledText
                            clip: true
                            color: Tokens.textDim
                            font.family: Tokens.fontFamily
                            font.pixelSize: 16
                            font.weight: 400
                            renderType: Text.NativeRendering
                        }

                        MouseArea {
                            id: tileArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.hitActivated(tile.hit)
                        }
                    }
                }
            }
        }

        // ---- honest empty state --------------------------------------------
        Text {
            visible: !root.busy && root.hits().length === 0 && String(root.query).length > 0
            x: 24
            y: 112
            text: "nothing found"
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: 16
            font.weight: 400
            renderType: Text.NativeRendering
        }
    }
}
