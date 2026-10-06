pragma ComponentBehavior: Bound

import QtQuick
import ".."

// AppIndex.qml — M1 APP-IX alphabetical/category index: one row per .desktop
// category (count-desc, uncategorised last), 14-notch fill gauge, two example
// app names. Counts and names straight from the scanned catalogue.
Item {
    id: root

    property var apps: []
    property var uses: ({})
    property int pinnedCount: 16
    signal launch(var app)

    // [{name, n, eg}] — design: ROWS sorted by (none last, -count)
    readonly property var cats: {
        var map = {}, order = [];
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i];
            var c = a.cats && a.cats.length > 0 ? String(a.cats[0]) : "";
            var key = c === "" ? "(none)" : c;
            if (!map[key]) {
                map[key] = { "name": key, "n": 0, "names": [] };
                order.push(key);
            }
            map[key].n++;
            map[key].names.push(String(a.name || ""));
        }
        order.sort(function (a, b) {
            if (a === "(none)") return 1;
            if (b === "(none)") return -1;
            return map[b].n - map[a].n;
        });
        return order.map(function (k) {
            var r = map[k];
            r.names.sort(function (x, y) { return x.toLowerCase() < y.toLowerCase() ? -1 : 1; });
            r.eg = r.names.slice(0, 2).join(", ");
            return r;
        });
    }
    readonly property int nTracked: {
        var n = 0;
        for (var i = 0; i < apps.length; i++)
            if ((uses[apps[i].id] || 0) > 0) n++;
        return n;
    }
    function p2(n) { return (n < 10 ? "0" : "") + n; }

    // ---------------------------------------------------------- table head
    Row {
        x: 16; y: 40
        spacing: 0
        Repeater {
            model: [["CODE", 0.14], ["CATEGORY", 0.30], ["N", 0.08],
                    ["0 ··· 14", 0.26], ["E.G.", 0.22]]
            delegate: Text {
                required property var modelData
                width: (root.width - 32) * modelData[1]
                text: modelData[0]
                color: FuiTokens.mute
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.micro
                font.letterSpacing: 1
            }
        }
    }
    Rectangle {
        x: 16; y: 60; width: root.width - 32; height: 1
        color: FuiTokens.hair2
    }

    // ---------------------------------------------------------- rows
    Flickable {
        x: 0; y: 64
        width: root.width
        height: root.height - 64 - 74
        contentHeight: catCol.height
        clip: true
        interactive: contentHeight > height
        Column {
            id: catCol
            x: 16
            width: root.width - 32
            Repeater {
                model: root.cats
                delegate: Item {
                    id: catRow
                    required property int index
                    required property var modelData
                    width: catCol.width
                    height: 26
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0
                        Text {
                            width: catCol.width * 0.14
                            text: "CAT-" + root.p2(catRow.index + 1)
                            color: FuiTokens.tone(FuiTokens.azure, 0.75)
                            font.family: FuiTokens.mono
                            font.pixelSize: FuiTokens.px.micro
                        }
                        Text {
                            width: catCol.width * 0.30
                            elide: Text.ElideRight
                            text: catRow.modelData.name === "(none)"
                                  ? "UNCATEGORISED" : catRow.modelData.name.toUpperCase()
                            color: FuiTokens.white
                            font.family: FuiTokens.display
                            font.pixelSize: FuiTokens.px.micro
                            font.letterSpacing: 1
                        }
                        Text {
                            width: catCol.width * 0.08
                            horizontalAlignment: Text.AlignRight
                            text: catRow.modelData.n
                            color: FuiTokens.white
                            font.family: FuiTokens.mono
                            font.pixelSize: FuiTokens.px.micro
                        }
                        Row {                      // 14-notch gauge
                            width: catCol.width * 0.26
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Repeater {
                                model: 14
                                delegate: Rectangle {
                                    required property int index
                                    width: 3; height: 9
                                    color: index < Math.min(14, catRow.modelData.n)
                                           ? FuiTokens.ice
                                           : FuiTokens.tone(FuiTokens.ice, 0.15)
                                }
                            }
                        }
                        Text {
                            width: catCol.width * 0.22
                            elide: Text.ElideRight
                            text: catRow.modelData.eg.length > 18
                                  ? catRow.modelData.eg.slice(0, 17) + "~"
                                  : catRow.modelData.eg
                            color: FuiTokens.mute
                            font.family: FuiTokens.mono
                            font.pixelSize: FuiTokens.px.micro
                        }
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 1
                        color: FuiTokens.hair3
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------- captions
    Column {
        x: 16
        anchors { bottom: parent.bottom; bottomMargin: 14 }
        spacing: 4
        Text {
            text: root.apps.length + " visible .desktop entries scanned"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
        Text {
            text: "pinned " + root.pinnedCount + " · tracked " + root.nTracked
                  + " · pinned untracked " + Math.max(0, root.pinnedCount - Math.min(root.pinnedCount, root.nTracked))
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }
}
