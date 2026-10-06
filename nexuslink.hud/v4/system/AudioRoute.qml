pragma ComponentBehavior: Bound

import QtQuick
import ".."

// AudioRoute.qml — AUD-RT frame content: live PipeWire sink/source tables
// (pactl via SysPoll) + the default-route flow strip. Columns: ID, node,
// bus/port, fmt, ch, rate, state, DEF diamond.
Item {
    id: root

    property var poll: null

    function _kRate(r) {
        var n = Number(r);
        return isFinite(n) && n > 0 ? String(Math.round(n / 1000)) + "k" : FuiTokens.unknownGlyph;
    }

    // pactl node name -> sheet name (topology-aware where the bdf resolves)
    function shortName(rec) {
        var n = String(rec.name || "");
        var m;
        if ((m = /HiFi__(\w+)__(sink|source)/.exec(n)))
            return "SCARLETT " + m[1].toUpperCase();
        if (n === "mke600_voice")
            return "MKE600_VOICE";
        if (/usb-Corsair.*alsa_input|alsa_input\.usb-Corsair/.test(n))
            return "CORSAIR MIC";
        if (/usb-Corsair/.test(n))
            return "CORSAIR SLIPSTREAM";
        if (/Razer_Kiyo/.test(n))
            return "KIYO MIC";
        if (/pci-0000_04_00\.0.*hdmi|hdmi-stereo/.test(n))
            return "B580 HDMI";
        if (/pci-0000_14_00\.6/.test(n))
            return n.indexOf("alsa_input") === 0 ? "ONBOARD ANALOG IN" : "ONBOARD ANALOG";
        var d = String(rec.desc || n);
        d = d.replace(/\s+(analog|digital|stereo|mono|duplex|fallback|output|input)\b/ig, "").trim();
        return d === "" ? n.toUpperCase().slice(0, 22) : d.toUpperCase().slice(0, 22);
    }

    function _rows(list) {
        var out = [];
        for (var i = 0; i < list.length; i++) {
            var r = list[i];
            out.push({
                "id": r.id, "nm": shortName(r),
                "bus": poll !== null ? poll.busLabel(r.busPath, r.bus) : (r.bus || "—"),
                "fmt": r.fmt, "ch": r.ch, "rate": _kRate(r.rate),
                "state": r.state, "def": false, "name": r.name
            });
        }
        return out;
    }
    readonly property var sinkRows: _rows(poll !== null ? poll.sinks : [])
    readonly property var srcRows: _rows(poll !== null ? poll.sources : [])

    // ---- column geometry: ID 46 | NAME 150 | BUS 82 | FMT 48 | CH 30 | RATE 44 | STATE 76 | DEF rest
    component Tbl: Item {
        id: tblItem
        property var rows: []
        property string defName: ""
        implicitHeight: headRow.height + rows.length * 19
        // header
        Item {
            id: headRow
            height: 18
            anchors { left: parent.left; right: parent.right; top: parent.top }
            Repeater {
                model: [["ID", 0, 46], ["NODE", 46, 150], ["BUS", 196, 82], ["FMT", 278, 48], ["CH", 326, 30], ["RATE", 356, 44], ["STATE", 400, 76]]
                delegate: Text {
                    required property var modelData
                    x: modelData[1]
                    text: modelData[0]
                    color: FuiTokens.mute
                    font.family: FuiTokens.display
                    font.pixelSize: FuiTokens.px.cap
                    font.letterSpacing: 1.5
                }
            }
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: FuiTokens.hair2 }
        }
        Column {
            anchors { left: parent.left; right: parent.right; top: headRow.bottom }
            Repeater {
                model: tblItem.rows
                delegate: Item {
                    id: rowItem
                    required property var modelData
                    width: tblItem.width
                    height: 19
                    Repeater {
                        model: [
                            { "x": 0, "w": 46, "t": rowItem.modelData.id, "c": FuiTokens.mute },
                            { "x": 46, "w": 150, "t": rowItem.modelData.nm, "c": FuiTokens.white },
                            { "x": 196, "w": 82, "t": rowItem.modelData.bus, "c": FuiTokens.dim },
                            { "x": 278, "w": 48, "t": rowItem.modelData.fmt, "c": FuiTokens.dim },
                            { "x": 326, "w": 30, "t": rowItem.modelData.ch, "c": FuiTokens.dim },
                            { "x": 356, "w": 44, "t": rowItem.modelData.rate, "c": FuiTokens.dim },
                            { "x": 400, "w": 76, "t": rowItem.modelData.state,
                              "c": rowItem.modelData.state === "RUNNING" ? FuiTokens.acid : FuiTokens.mute }
                        ]
                        delegate: Text {
                            id: cell
                            required property var modelData
                            x: cell.modelData.x; width: cell.modelData.w
                            height: 19
                            verticalAlignment: Text.AlignVCenter
                            text: cell.modelData.t !== "" ? cell.modelData.t : FuiTokens.unknownGlyph
                            color: cell.modelData.c
                            font.family: FuiTokens.mono
                            font.pixelSize: FuiTokens.px.body
                            elide: Text.ElideRight
                        }
                    }
                    Text {
                        visible: rowItem.modelData.name === tblItem.defName
                        anchors { left: parent.left; leftMargin: 478; verticalCenter: parent.verticalCenter }
                        text: "◆"
                        color: FuiTokens.ice
                        font.pixelSize: 9
                    }
                    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: FuiTokens.hair3 }
                }
            }
        }
    }

    // sinks
    Item {
        id: leftCol
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.round(parent.width * 0.49)
        Text {
            id: sinkHead
            text: "SINKS  " + root.sinkRows.length
            color: FuiTokens.dim
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.cap
            font.letterSpacing: 1.5
        }
        Tbl {
            anchors { left: parent.left; right: parent.right; top: sinkHead.bottom; topMargin: 6 }
            rows: root.sinkRows
            defName: root.poll !== null ? root.poll.defSink : ""
        }
    }
    Item {
        id: rightCol
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
        width: Math.round(parent.width * 0.49)
        Text {
            id: srcHead
            text: "SOURCES  " + root.srcRows.length + " + " + (root.poll !== null ? root.poll.monitorCount : 0) + " MONITOR TAPS"
            color: FuiTokens.dim
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.cap
            font.letterSpacing: 1.5
        }
        Tbl {
            anchors { left: parent.left; right: parent.right; top: srcHead.bottom; topMargin: 6 }
            rows: root.srcRows
            defName: root.poll !== null ? root.poll.defSource : ""
        }
    }

    // FLOW strip — default path through pipewire
    Item {
        anchors { left: parent.left; bottom: parent.bottom }
        width: leftCol.width
        height: 56
        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: -8 } height: 1; color: FuiTokens.hair2 }
        Column {
            anchors.fill: parent
            spacing: 4
            Row {
                spacing: 8
                Text { text: "FLOW"; color: FuiTokens.dim; font.family: FuiTokens.display; font.pixelSize: FuiTokens.px.cap; font.letterSpacing: 1.5 }
                Text {
                    color: FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                    text: "apps ▸ pipewire ▸"
                }
                Text {
                    id: flSink
                    color: FuiTokens.acid; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                    text: {
                        if (root.poll === null || root.poll.defSink === "")
                            return FuiTokens.unknownGlyph;
                        for (var i = 0; i < root.sinkRows.length; i++)
                            if (root.sinkRows[i].name === root.poll.defSink)
                                return root.sinkRows[i].nm + " " + root.sinkRows[i].fmt + " " + root.sinkRows[i].rate;
                        return root.poll.defSink;
                    }
                }
            }
            Text {
                color: FuiTokens.dim; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                text: {
                    if (root.poll === null || root.poll.defSource === "")
                        return "source " + FuiTokens.unknownGlyph;
                    var nm = root.poll.defSource;
                    for (var i = 0; i < root.srcRows.length; i++)
                        if (root.srcRows[i].name === nm)
                            nm = root.srcRows[i].nm;
                    return nm + " ▸ apps";
                }
            }
            Text {
                color: FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                text: {
                    if (root.poll === null)
                        return "";
                    var sus = 0, run = 0;
                    var all = root.sinkRows.concat(root.srcRows);
                    for (var i = 0; i < all.length; i++) {
                        if (all[i].state === "RUNNING") run++;
                        else if (all[i].state === "SUSPENDED") sus++;
                    }
                    if (run + sus === 0)
                        return "awaiting pactl";
                    return sus + " endpoints suspended, " + run + " running + " + root.poll.monitorCount + " monitor taps";
                }
            }
        }
    }
}
