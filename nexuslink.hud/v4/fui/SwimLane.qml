pragma ComponentBehavior: Bound

import QtQuick

// SwimLane.qml — rows x time-axis swim lane (F1 crew table / M1 CRW-TL).
// Row model: { label, sub, color, events, meta }
//   label : lane handle (e.g. bot name)
//   sub   : lane/model caption (right of label)
//   color : state colour for the handle (FuiTokens.stateColor)
//   events: [[start, end|null, title], ...] epoch seconds, or objects
//           {start, end, title, live, dashed}; end null = open block
//   meta  : right-column string (sessions/tokens/state readout)
// Open block with live=true paints acid; open with dashed=true paints a
// dashed outline; sub-90 s closed events collapse to a diamond ping.
// The NOW line follows `now` — scroll the window, never rebuild lanes.
Item {
    id: root

    property var model: []
    property double windowStart: 0        // epoch seconds
    property double windowEnd: 0
    property double now: -1               // <0 -> windowEnd
    property int rowHeight: 18
    property int headerH: 16
    property int labelWidth: 150
    property int metaWidth: 0
    property bool separators: true
    property color nowColor: FuiTokens.acid

    signal eventClicked(int rowIndex, var event)

    implicitWidth: 600
    implicitHeight: headerH + model.length * rowHeight

    readonly property double t0: windowStart
    readonly property double t1: windowEnd
    readonly property double tNow: now >= 0 ? now : windowEnd
    readonly property real laneX: labelWidth
    readonly property real laneW: Math.max(0, width - labelWidth - metaWidth)
    readonly property real pps: (t1 > t0) ? laneW / (t1 - t0) : 0

    function xOf(epoch) { return laneX + (epoch - t0) * pps; }
    function ev(e) {    // normalise array or object event forms
        if (e === null || e === undefined) return null;
        if (e.length !== undefined)         // [start, end, title]
            return { "start": e[0], "end": e[1], "title": e[2] || "",
                     "live": e[1] === null || e[1] === undefined, "dashed": false };
        var en = e.end !== undefined ? e.end : null;
        return { "start": e.start, "end": en, "title": e.title || "",
                 "live": e.live === true || en === null,
                 "dashed": e.dashed === true };
    }

    // hour gridlines through the lanes + header tick marks (painted on window change)
    Canvas {
        id: grid
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            if (root.t1 <= root.t0)
                return;
            var step = 600;                            // 10-min minor ticks
            var first = Math.ceil(root.t0 / step) * step;
            ctx.lineWidth = 1;
            for (var t = first; t <= root.t1; t += step) {
                var hour = t % 3600 === 0;
                var x = root.xOf(t);
                ctx.strokeStyle = FuiTokens.css(hour ? FuiTokens.hair2 : FuiTokens.hair3);
                ctx.beginPath();
                if (hour) {
                    ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, height);   // full-height gridline
                } else {
                    ctx.moveTo(x + 0.5, root.headerH - 4); ctx.lineTo(x + 0.5, root.headerH);
                }
                ctx.stroke();
            }
        }
        Connections {
            target: root
            function onWindowStartChanged() { grid.requestPaint(); }
            function onWindowEndChanged() { grid.requestPaint(); }
            function onLaneWChanged() { grid.requestPaint(); }
            function onHeaderHChanged() { grid.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // hour labels in the header
    Repeater {
        model: {
            var out = [];
            if (root.t1 <= root.t0) return out;
            var first = Math.ceil(root.t0 / 3600) * 3600;
            for (var t = first; t <= root.t1; t += 3600) out.push(t);
            return out;
        }
        delegate: Text {
            required property var modelData
            x: root.xOf(modelData) - implicitWidth / 2
            y: 0
            height: root.headerH
            text: FuiTokens.fmtHm(modelData)
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }

    // lane rows
    Column {
        y: root.headerH
        Repeater {
            model: root.model
            delegate: Item {
                id: lane
                required property int index
                required property var modelData
                width: root.width
                height: root.rowHeight

                Text {
                    x: 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.labelWidth * 0.45
                    elide: Text.ElideRight
                    text: String(lane.modelData.label || "")
                    color: lane.modelData.color !== undefined ? lane.modelData.color : FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.tag
                    font.letterSpacing: FuiTokens.ls.tag
                }
                Text {
                    x: root.labelWidth * 0.45 + 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.labelWidth * 0.55 - 8
                    elide: Text.ElideRight
                    text: String(lane.modelData.sub || "")
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                Text {
                    visible: root.metaWidth > 0
                    x: root.width - root.metaWidth + 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.metaWidth - 6
                    elide: Text.ElideRight
                    text: String(lane.modelData.meta || "")
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                    horizontalAlignment: Text.AlignRight
                }
                Rectangle {          // lane separator
                    visible: root.separators
                    x: root.laneX
                    width: root.laneW
                    anchors.bottom: parent.bottom
                    height: 1
                    color: FuiTokens.hair3
                }

                Repeater {
                    model: lane.modelData.events || []
                    delegate: Item {
                        id: blk
                        required property var modelData
                        readonly property var e: root.ev(modelData)
                        readonly property real x0: e ? Math.max(root.laneX, root.xOf(Number(e.start))) : 0
                        readonly property real x1: e ? Math.min(root.laneX + root.laneW,
                            root.xOf(Number(e.end !== null && e.end !== undefined ? e.end : root.tNow))) : 0
                        readonly property bool ping: e && e.end !== null && (e.end - e.start) < 90
                        readonly property bool open: e && (e.end === null || e.end === undefined)
                        visible: e !== null
                        x: x0
                        width: Math.max(ping ? 0 : 3, x1 - x0)
                        anchors.verticalCenter: parent.verticalCenter
                        height: root.rowHeight - 6

                        Rectangle {    // session block
                            visible: !blk.ping
                            anchors.fill: parent
                            color: blk.e && blk.e.live && blk.open ? FuiTokens.tone(FuiTokens.acid, 0.15)
                                   : "transparent"
                            border.width: 1
                            border.color: blk.e && blk.e.live && blk.open ? FuiTokens.acid
                                        : blk.e && blk.e.dashed ? FuiTokens.tone(FuiTokens.ice, 0.6)
                                        : FuiTokens.tone(FuiTokens.ice, 0.55)
                            Rectangle { // dashed right edge for open-idle blocks
                                visible: blk.e && blk.e.dashed && blk.open
                                anchors.right: parent.right
                                width: 1; height: parent.height
                                color: FuiTokens.tone(FuiTokens.ice, 0.6)
                            }
                        }
                        Rectangle {    // roll-call diamond (<90 s)
                            visible: blk.ping
                            anchors.centerIn: parent
                            width: 5; height: 5
                            rotation: 45
                            color: "transparent"
                            border.width: 1
                            border.color: FuiTokens.ice
                        }
                        Text {         // in-block title, clipped to the block
                            visible: !blk.ping && blk.width > 34
                            anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter }
                            width: parent.width - 8
                            elide: Text.ElideRight
                            text: blk.e ? String(blk.e.title) : ""
                            color: FuiTokens.dim
                            font.family: FuiTokens.mono
                            font.pixelSize: FuiTokens.px.micro
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.eventClicked(lane.index, blk.e)
                        }
                    }
                }
            }
        }
    }

    // NOW cursor
    Rectangle {
        visible: root.tNow >= root.t0 && root.tNow <= root.t1
        x: Math.round(root.xOf(root.tNow))
        width: 1
        y: 0
        height: parent.height
        color: root.nowColor
    }
    Text {
        visible: root.tNow >= root.t0 && root.tNow <= root.t1
        x: Math.round(root.xOf(root.tNow)) + 3
        y: 0
        text: "NOW " + FuiTokens.fmtHm(root.tNow)
        color: root.nowColor
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
}
