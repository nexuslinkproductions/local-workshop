pragma ComponentBehavior: Bound

import QtQuick
import ".."

// AppLadder.qml — M1 APP-RK most-used ladder: top-5 ranked rows with a
// segmented 0..N scale per app, share + cumulative share, and the
// proportional share ribbon. All counts straight from appuse.json.
Item {
    id: root

    property var apps: []
    property var uses: ({})
    property int totalUse: 0
    signal launch(var app)

    readonly property var ranked: {
        var a = apps.filter(function (x) { return (uses[x.id] || 0) > 0; });
        a.sort(function (x, y) {
            var d = (uses[y.id] || 0) - (uses[x.id] || 0);
            return d !== 0 ? d
                : String(x.name).toLowerCase() < String(y.name).toLowerCase() ? -1 : 1;
        });
        return a.slice(0, 5);
    }
    readonly property int nTracked: {
        var n = 0;
        for (var i = 0; i < apps.length; i++)
            if ((uses[apps[i].id] || 0) > 0) n++;
        return n;
    }
    readonly property int topN: ranked.length > 0 ? Number(uses[ranked[0].id]) || 0 : 0
    readonly property int scaleN: Math.max(10, topN)     // bar scale 0..scaleN
    readonly property real shareTotal: Math.max(1, totalUse)

    function share(id) { return 100 * (uses[id] || 0) / shareTotal; }
    function cum(idx) {
        var s = 0;
        for (var i = 0; i <= idx && i < ranked.length; i++)
            s += uses[ranked[i].id] || 0;
        return 100 * s / shareTotal;
    }
    function p2(n) { return (n < 10 ? "0" : "") + n; }

    // bar x/length (design 150/260 of 516)
    readonly property real bx: width * (150 / 516)
    readonly property real bl: width * (260 / 516)

    // ------------------------------------------------------------ header
    Text {
        x: 16; y: 40
        text: root.totalUse > 0 ? String(root.totalUse) : FuiTokens.unknownGlyph
        color: FuiTokens.white
        font.family: FuiTokens.display
        font.pixelSize: 52
    }
    Column {
        x: 118; y: 52
        spacing: 5
        Text {
            text: "TRACKED LAUNCHES"
            color: FuiTokens.dim
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: FuiTokens.ls.label
        }
        Text {
            text: root.nTracked + " of " + root.apps.length + " apps tracked"
                  + " · " + (root.apps.length - root.nTracked) + " untracked"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
        Text {
            visible: root.ranked.length > 0
            text: "top-1 " + (root.ranked.length > 0 ? root.share(root.ranked[0].id).toFixed(1) : "0")
                  + "% · top-" + Math.min(3, root.ranked.length) + " "
                  + root.cum(Math.min(2, root.ranked.length - 1)).toFixed(1) + "%"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }

    // launches ruler
    Ruler {
        x: root.bx; y: 150
        width: root.bl
        height: 12
        from: 0; to: root.scaleN
        minor: root.scaleN
        majorEvery: 5
        color: FuiTokens.ice
        tickMinor: 4; tickMajor: 9
    }
    Text {
        x: root.bx + root.bl + 14; y: 150
        text: "LAUNCHES"
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }

    // ------------------------------------------------------------ rows
    Column {
        y: 196
        Repeater {
            model: root.ranked
            delegate: Item {
                id: row
                required property int index
                required property var modelData
                readonly property var app: modelData
                readonly property int n: Number(root.uses[app.id]) || 0
                width: root.width
                height: 50

                Text {
                    x: 16; y: 4
                    text: "#" + root.p2(row.index + 1)
                    color: FuiTokens.ice
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.cap
                }
                Text {
                    x: 50; y: 2
                    width: root.bx - 56
                    elide: Text.ElideRight
                    text: String(row.app.name || "").toUpperCase()
                    color: FuiTokens.white
                    font.family: FuiTokens.display
                    font.pixelSize: FuiTokens.px.cap
                    font.letterSpacing: FuiTokens.ls.cap
                }
                Text {
                    x: 50; y: 20
                    width: root.bx - 56
                    elide: Text.ElideRight
                    text: String(row.app.id).replace(".desktop", "").slice(0, 14)
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                // segmented bar: scaleN segments, n lit (design rect at y-8)
                Rectangle {
                    x: root.bx; y: -8
                    width: root.bl; height: 14
                    color: "transparent"
                    border.width: 1
                    border.color: FuiTokens.tone(FuiTokens.ice, 0.18)
                }
                Row {
                    x: root.bx + 2; y: -5
                    spacing: 2
                    Repeater {
                        model: root.scaleN
                        delegate: Rectangle {
                            required property int index
                            width: Math.max(1.5, (root.bl - 4) / root.scaleN - 2)
                            height: 8
                            color: index < row.n
                                   ? FuiTokens.tone(FuiTokens.ice, 0.5)
                                   : FuiTokens.tone(FuiTokens.ice, 0.10)
                        }
                    }
                }
                Text {
                    x: root.bx + root.bl + 14; y: 2
                    text: String(row.n)
                    color: FuiTokens.white
                    font.family: FuiTokens.mono
                    font.pixelSize: 13
                }
                Text {
                    anchors { right: parent.right; rightMargin: 16 }
                    y: 4
                    text: root.share(row.app.id).toFixed(1) + "%"
                    color: FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.cap
                }
                Text {
                    anchors { right: parent.right; rightMargin: 16 }
                    y: 22
                    text: "cum " + root.cum(row.index).toFixed(1) + "%"
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.launch(row.app)
                }
            }
        }
    }

    // ------------------------------------------------------------ share ribbon
    Item {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 110
        Text {
            x: 16; y: 0
            text: "SHARE RIBBON // " + root.totalUse + " = 100%"
            color: FuiTokens.dim
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: FuiTokens.ls.cap
        }
        Row {
            x: 16; y: 12
            width: parent.width - 32
            height: 18
            Repeater {
                model: root.ranked
                delegate: Item {
                    id: seg
                    required property var modelData
                    required property int index
                    readonly property real w: Math.max(0,
                        (root.uses[seg.modelData.id] || 0) / root.shareTotal
                        * (root.width - 32))
                    width: seg.w
                    height: 18
                    clip: true
                    Rectangle {
                        x: 0; width: Math.max(0, seg.w - 2); height: 18
                        color: FuiTokens.tone(FuiTokens.ice, 0.06)
                        border.width: 1
                        border.color: FuiTokens.tone(FuiTokens.ice, 0.7)
                    }
                    Text {
                        visible: seg.w > 44
                        x: 5; y: 3
                        width: seg.w - 8
                        elide: Text.ElideRight
                        text: String(seg.modelData.name || "")
                        color: FuiTokens.dim
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                }
            }
        }
        Ruler {
            x: 16; y: 34
            width: parent.width - 32
            height: 10
            from: 0; to: 100
            minor: 20; majorEvery: 25
            labels: ["0", "25", "50", "75", "100%"]
            color: FuiTokens.ice
            tickMinor: 3; tickMajor: 6
        }
        Text {
            x: 16; anchors { bottom: parent.bottom; bottomMargin: 8 }
            text: "counts only (appuse.json v1) — no launch timestamps"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }
}
