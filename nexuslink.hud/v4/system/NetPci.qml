pragma ComponentBehavior: Bound

import QtQuick
import ".."

// NetPci.qml — NET-PCI frame content: interface table (IF STATE ADDR HW)
// with since-boot counters + live rate, and the PCIe link table
// (BDF DEVICE GEN WIDTH x1-x16 segment strip). All live-fed: nic state from
// dev_nic_*_up, addresses from `ip`, gen/width from dev_pcie_* via Topology.
Item {
    id: root

    property var poll: null
    property var stats: ({})
    property double rxBytes: NaN       // net_rx cumulative (bytes)
    property double txBytes: NaN
    property double rxRate: NaN        // B/s deltas computed in the deck
    property double txRate: NaN

    function _fmtB(n) {
        if (!isFinite(n) || n < 0)
            return FuiTokens.unknownGlyph;
        if (n < 1024) return Math.round(n) + " B";
        if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
        if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB";
        return (n / 1073741824).toFixed(2) + " GB";
    }
    function _fmtRate(n) {
        if (!isFinite(n) || n < 0)
            return FuiTokens.unknownGlyph;
        return _fmtB(n) + "/s";
    }

    // iface rows: every dev_nic_<if>_up key + scaffold nic nodes' ifnames
    readonly property var ifRows: {
        var seen = {}, out = [];
        var s = root.stats;
        for (var k in s) {
            var m = /^dev_nic_(.+)_up$/.exec(k);
            if (m === null)
                continue;
            seen[m[1]] = s[k];
        }
        var nl = Topology.nodeList;
        for (var i = 0; i < nl.length; i++) {
            var n = nl[i];
            if (n.extra === undefined || n.extra.ifname === undefined)
                continue;
            if (String(n.extra.ifname) === "lo")
                continue;
            if (seen[n.extra.ifname] === undefined)
                seen[n.extra.ifname] = undefined;   // known iface, no live key
        }
        var names = Object.keys(seen).sort();
        for (var j = 0; j < names.length; j++) {
            var ifn = names[j];
            var up = seen[ifn];
            var st = up !== undefined
                ? (String(up) === "1" || String(up).toLowerCase() === "up" ? "UP" : "DOWN")
                : FuiTokens.unknownGlyph;
            var addr = root.poll !== null && root.poll.ifAddrs[ifn] !== undefined ? root.poll.ifAddrs[ifn] : "";
            var hw = "";
            if (ifn === "enp15s0") hw = "RTL8125 2.5G";
            else if (ifn === "wlp16s0") hw = "MT7922 ax";
            else if (/^docker|^br-/.test(ifn)) hw = "bridge";
            else if (/^veth/.test(ifn)) hw = "veth";
            else if (/^wlan|^wlp/.test(ifn)) hw = "wifi";
            out.push({ "if": ifn, "st": st, "addr": addr !== "" ? addr : (st === "DOWN" ? "no carrier" : FuiTokens.unknownGlyph),
                       "hw": hw });
        }
        return out;
    }

    // PCIe link rows: curated order, gen/width via Topology node.link
    readonly property var pcieRows: {
        var ids = ["pci_01_00_0", "gpu_arc", "nvme0", "nvme1", "gpu_apu", "nic_eth", "nic_wifi", "xhci_chipset"];
        var names = {
            "pci_01_00_0": "B580 upstream", "gpu_arc": "Arc B580",
            "gpu_apu": "Raphael iGPU", "nic_eth": "RTL8125 eth",
            "nic_wifi": "MT7922 wifi", "xhci_chipset": "800 xHCI"
        };
        var out = [];
        for (var i = 0; i < ids.length; i++) {
            var n = Topology.node(ids[i]);
            if (n === undefined || n.extra === undefined || n.extra.bdf === undefined)
                continue;
            var nm = names[ids[i]];
            if (nm === undefined) {
                var mod = ids[i] === "nvme0" ? root.stats.nvme0_model : root.stats.nvme1_model;
                nm = (mod !== undefined ? String(mod) : String(n.label)) + " " + ids[i];
            }
            var gen = "", wd = null;
            if (n.link !== Topology.unknown) {
                var p = String(n.link).split("@");   // "x8@4"
                if (p.length === 2) {
                    gen = "G" + p[1];
                    var wn = Number(String(p[0]).replace("x", ""));
                    wd = isFinite(wn) ? wn : null;
                }
            }
            out.push({ "bdf": String(n.extra.bdf), "nm": nm, "gen": gen, "wd": wd });
        }
        return out;
    }

    // ---- IF table (left) -----------------------------------------------
    Item {
        id: netCol
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.round(parent.width * 0.45)
        Item {
            id: nh; height: 18
            anchors { left: parent.left; right: parent.right; top: parent.top }
            Repeater {
                model: [["IF", 0, 64], ["STATE", 64, 48], ["ADDR", 112, 138], ["HW", 250, 0]]
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
            anchors { left: parent.left; right: parent.right; top: nh.bottom }
            Repeater {
                model: root.ifRows
                delegate: Item {
                    id: ifRow
                    required property var modelData
                    width: netCol.width
                    height: 19
                    Text { x: 0; width: 64; anchors.verticalCenter: parent.verticalCenter; text: ifRow.modelData["if"]; color: FuiTokens.white; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body; elide: Text.ElideRight }
                    Text { x: 64; width: 48; anchors.verticalCenter: parent.verticalCenter; text: ifRow.modelData.st; color: ifRow.modelData.st === "UP" ? FuiTokens.acid : FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body }
                    Text { x: 112; width: 138; anchors.verticalCenter: parent.verticalCenter; text: ifRow.modelData.addr; color: FuiTokens.dim; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body; elide: Text.ElideRight }
                    Text { x: 250; anchors.verticalCenter: parent.verticalCenter; text: ifRow.modelData.hw; color: FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body; elide: Text.ElideRight }
                    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: FuiTokens.hair3 }
                }
            }
        }
        Column {
            anchors { left: parent.left; bottom: parent.bottom }
            spacing: 4
            Text {
                color: FuiTokens.dim; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                text: "since boot  rx " + root._fmtB(root.rxBytes) + "  tx " + root._fmtB(root.txBytes)
            }
            Text {
                color: FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                text: "rate " + root._fmtRate(root.rxRate) + " rx · " + root._fmtRate(root.txRate) + " tx"
            }
        }
    }

    // ---- PCIe table (right) --------------------------------------------
    Item {
        id: pcieCol
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
        width: Math.round(parent.width * 0.52)
        Item {
            id: ph; height: 18
            anchors { left: parent.left; right: parent.right; top: parent.top }
            Repeater {
                model: [["BDF", 0, 56], ["DEVICE", 56, 150], ["GEN", 206, 30], ["WIDTH x1-x16", 236, 0]]
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
            anchors { left: parent.left; right: parent.right; top: ph.bottom }
            Repeater {
                model: root.pcieRows
                delegate: Item {
                    id: pcieRow
                    required property var modelData
                    width: pcieCol.width
                    height: 20
                    Text { x: 0; width: 56; anchors.verticalCenter: parent.verticalCenter; text: pcieRow.modelData.bdf; color: FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body }
                    Text { x: 56; width: 150; anchors.verticalCenter: parent.verticalCenter; text: pcieRow.modelData.nm; color: FuiTokens.white; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body; elide: Text.ElideRight }
                    Text { x: 206; width: 30; anchors.verticalCenter: parent.verticalCenter; text: pcieRow.modelData.gen !== "" ? pcieRow.modelData.gen : FuiTokens.unknownGlyph; color: FuiTokens.dim; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body }
                    Canvas {
                        x: 236; width: 120; height: 12
                        anchors.verticalCenter: parent.verticalCenter
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, width, height);
                            var wd = pcieRow.modelData.wd;
                            for (var k = 0; k < 16; k++) {
                                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.azure, 0.45));
                                ctx.lineWidth = FuiTokens.lwHair;
                                ctx.strokeRect(k * 7.5 + 0.5, 2, 6, 8);
                                if (wd !== null && k < wd) {
                                    ctx.fillStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.azure, 0.8));
                                    ctx.fillRect(k * 7.5 + 0.5, 2, 6, 8);
                                }
                            }
                        }
                    }
                    Text {
                        anchors { left: parent.left; leftMargin: 362; verticalCenter: parent.verticalCenter }
                        text: pcieRow.modelData.wd !== null ? "x" + pcieRow.modelData.wd : FuiTokens.unknownGlyph
                        color: FuiTokens.dim; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                    }
                    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: FuiTokens.hair3 }
                }
            }
        }
    }
}
