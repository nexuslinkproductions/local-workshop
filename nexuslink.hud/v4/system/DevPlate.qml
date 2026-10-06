pragma ComponentBehavior: Bound

import QtQuick
import ".."

// DevPlate.qml — one USB device plate in the DEV-BAY map: octagon-chamfered
// hairline card (acid border while its audio endpoint is live), header strip
// (code / port / vid:pid / speed class / state tag), Michroma name, up to
// three label:value detail rows, and a corner gauge — log-scale link-speed
// arc or battery arc. One Canvas draws border + gauge; repaints on input.
Item {
    id: root

    property string code: ""          // DEV-07 / HUB-01
    property string port: ""          // 6-7 / 3-2
    property string vidpid: ""
    property string speed: ""         // FS HS SS SS+
    property string name: ""
    property var lines: []            // [{l, v, vc(optional color)}]
    property string stateTag: ""      // ONLINE / IDLE / LIVE / 4 I/O
    property bool live: false
    property string gauge: "link"     // "link" | "batt" | "none"
    property var mbps: null           // negotiated Mb/s for the link arc
    property var battPct: null        // 0-100 for the batt arc

    implicitWidth: 380
    implicitHeight: 136

    Canvas {
        id: cv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var w = width, h = height, c = 14;
            var col = root.live ? FuiTokens.acid : FuiTokens.ice;
            ctx.globalAlpha = 1;

            // octagon plate
            ctx.beginPath();
            ctx.moveTo(c, 0.5); ctx.lineTo(w - c, 0.5);
            ctx.lineTo(w - 0.5, c); ctx.lineTo(w - 0.5, h - c);
            ctx.lineTo(w - c, h - 0.5); ctx.lineTo(c, h - 0.5);
            ctx.lineTo(0.5, h - c); ctx.lineTo(0.5, c);
            ctx.closePath();
            ctx.fillStyle = "rgba(10,15,20,0.82)";
            ctx.fill();
            ctx.strokeStyle = FuiTokens.css(col);
            ctx.globalAlpha = root.live ? 0.85 : 0.5;
            ctx.lineWidth = FuiTokens.lwHair;
            ctx.stroke();
            // header accent notch
            ctx.globalAlpha = 1;
            ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(14, 0.5); ctx.lineTo(70, 0.5); ctx.stroke();
            ctx.lineWidth = FuiTokens.lwHair;

            // corner gauge — log-scale link arc or battery arc
            if (root.gauge === "none")
                return;
            var gx = w - 52, gy = h - 44, r = 30;
            function pol(rr, deg) { return FuiTokens.pol(gx, gy, rr, deg); }
            function arc(rr, a0, a1, cc, lw, op) {
                ctx.globalAlpha = op;
                ctx.strokeStyle = FuiTokens.css(cc);
                ctx.lineWidth = lw;
                ctx.beginPath();
                ctx.arc(gx, gy, rr, (a0 - 90) * Math.PI / 180, (a1 - 90) * Math.PI / 180);
                ctx.stroke();
                ctx.globalAlpha = 1; ctx.lineWidth = FuiTokens.lwHair;
            }
            // track + 20 ticks
            arc(r, -120, 120, FuiTokens.ice, 1, 0.25);
            ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
            for (var i = 0; i <= 20; i++) {
                var a = -120 + 240 * i / 20;
                var l = i % 5 === 0 ? 5 : 2;
                var t0 = pol(r + 2, a), t1 = pol(r + 2 + l, a);
                ctx.globalAlpha = 0.4;
                ctx.beginPath(); ctx.moveTo(t0.x, t0.y); ctx.lineTo(t1.x, t1.y); ctx.stroke();
            }
            ctx.globalAlpha = 1;
            ctx.textAlign = "center"; ctx.textBaseline = "alphabetic";
            if (root.gauge === "batt") {
                var bp = Number(root.battPct);
                if (isFinite(bp)) {
                    arc(r - 4, -120, -120 + 240 * bp / 100, FuiTokens.acid, 2, 1);
                    arc(r - 4, -120, -120 + 240 * 0.15, FuiTokens.warn, 1, 0.9);
                    ctx.fillStyle = FuiTokens.css(FuiTokens.white);
                    ctx.font = "13px \"" + FuiTokens.mono + "\"";
                    ctx.fillText(Math.round(bp) + "%", gx, gy + 4);
                } else {
                    ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                    ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                    ctx.fillText(FuiTokens.unknownGlyph, gx, gy + 4);
                }
                ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                ctx.fillText("BATT", gx, gy + 22);
            } else {
                var marks = [1.5, 12, 480, 5000, 10000];
                var lo = Math.log(1.5) / Math.LN10, hi = Math.log(10000) / Math.LN10;
                function pos(v) {
                    var lv = Math.log(Math.max(1.5, Math.min(10000, v))) / Math.LN10;
                    return -120 + 240 * (lv - lo) / (hi - lo);
                }
                var sp = Number(root.mbps);
                if (isFinite(sp))
                    arc(r - 4, -120, pos(sp), FuiTokens.azure, 2, 0.9);
                ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
                for (var k = 0; k < marks.length; k++) {
                    var mp = pos(marks[k]);
                    var m0 = pol(r - 8, mp), m1 = pol(r + 2, mp);
                    ctx.globalAlpha = 0.7;
                    ctx.beginPath(); ctx.moveTo(m0.x, m0.y); ctx.lineTo(m1.x, m1.y); ctx.stroke();
                }
                ctx.globalAlpha = 1;
                ctx.fillStyle = FuiTokens.css(FuiTokens.white);
                ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                var st = isFinite(sp)
                    ? (sp >= 10000 ? "10G" : sp >= 5000 ? "5G" : sp >= 480 ? "480M" : sp >= 12 ? "12M" : "1.5M")
                    : FuiTokens.unknownGlyph;
                ctx.fillText(st, gx, gy + 4);
                ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                ctx.fillText("LINK", gx, gy + 22);
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onLiveChanged() { cv.requestPaint(); }
            function onGaugeChanged() { cv.requestPaint(); }
            function onMbpsChanged() { cv.requestPaint(); }
            function onBattPctChanged() { cv.requestPaint(); }
        }
    }

    // header: code / port / vid:pid / speed ......... state tag
    Item {
        id: head
        anchors { left: parent.left; right: parent.right; top: parent.top
                  leftMargin: 18; rightMargin: 16; topMargin: 10 }
        height: 14
        Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            spacing: 8
            Repeater {
                model: [
                    { "t": root.code, "c": FuiTokens.ice },
                    { "t": root.port, "c": FuiTokens.mute },
                    { "t": root.vidpid, "c": FuiTokens.mute },
                    { "t": root.speed, "c": FuiTokens.mute }
                ]
                delegate: Text {
                    id: headCell
                    required property var modelData
                    visible: headCell.modelData.t !== ""
                    text: headCell.modelData.t
                    color: headCell.modelData.c
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.body
                }
            }
        }
        Text {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            visible: root.stateTag !== ""
            text: root.stateTag
            color: root.live ? FuiTokens.acid : FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.tag
            font.letterSpacing: FuiTokens.ls.tag
        }
    }

    Text {
        anchors { left: parent.left; leftMargin: 18; top: parent.top; topMargin: 30 }
        text: root.name
        color: FuiTokens.white
        font.family: FuiTokens.display
        font.pixelSize: 13
        font.letterSpacing: 2
        elide: Text.ElideRight
        width: root.width - 36
    }

    Column {
        anchors { left: parent.left; leftMargin: 18; top: parent.top; topMargin: 56
                  right: parent.right; rightMargin: 96 }
        spacing: 2
        Repeater {
            model: root.lines
            delegate: Row {
                id: lnRow
                required property var modelData
                spacing: 6
                Text {
                    text: lnRow.modelData.l
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.body
                }
                Text {
                    text: lnRow.modelData.v
                    color: lnRow.modelData.vc !== undefined ? lnRow.modelData.vc : FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.body
                    elide: Text.ElideRight
                }
            }
        }
    }
}
