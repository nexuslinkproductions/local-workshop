pragma ComponentBehavior: Bound

import QtQuick
import "system" as Sys

// DeckSystem.qml — M1 HDMI-A-3 deck: DEVICES // SYSTEM sheet.
// DEV-BAY topology hero (USB/PCIe node-link from sysfs + Topology + pactl),
// SYS-TLM gauge tier (cpu/mem/gpu/sto), AUD-RT PipeWire routing tables,
// NET-PCI link tables, LEDGER strip (theme/power/updates/toggles/workspaces).
// Layout is proportional — works on any deck size; all values live or "—".
Item {
    id: root

    // ---- deck inputs (docs/m1/CONTRACT.md — do not rename) ---------------
    property var stats: ({})
    property var tokData: ({})
    property var crew: ({})
    property string screenName: "HDMI-A-3"
    property bool shown: true
    property var navigator: null
    property string sayText: ""
    property bool sayFlash: false

    // ---- helpers ---------------------------------------------------------
    function num(v) { var n = Number(v); return isFinite(n) ? n : NaN; }
    function has(k) { return stats[k] !== undefined && stats[k] !== ""; }
    function tNum(v, dec) { var n = num(v); return isFinite(n) ? n.toFixed(dec === undefined ? 0 : dec) : FuiTokens.unknownGlyph; }
    function gbOfKb(kb) { return num(kb) / 1048576; }
    function _gbTxt(v, dec) { return isFinite(v) ? v.toFixed(dec === undefined ? 0 : dec) + " GB" : FuiTokens.unknownGlyph; }
    // df -B1 feeds raw bytes — humanize before display (T/G/M/K suffixes,
    // same convention as CommandHub.fmtBytes)
    function _fmtBytes(v) {
        var n = num(v);
        if (!isFinite(n)) return FuiTokens.unknownGlyph;
        if (n >= 1099511627776) return (n / 1099511627776).toFixed(1) + " TB";
        if (n >= 1073741824) return (n / 1073741824).toFixed(0) + " GB";
        if (n >= 1048576) return (n / 1048576).toFixed(0) + " MB";
        if (n >= 1024) return (n / 1024).toFixed(0) + " KB";
        return Math.round(n) + " B";
    }
    function _uptimeTxt(s) {
        var u = num(s);
        if (!isFinite(u)) return FuiTokens.unknownGlyph;
        var d = Math.floor(u / 86400), h = Math.floor(u % 86400 / 3600), m2 = Math.floor(u % 3600 / 60);
        return (d > 0 ? d + "d " : "") + h + "h " + ("0" + m2).slice(-2) + "m";
    }
    function _fmtNow() {
        var d = new Date();
        var hh = ("0" + d.getHours()).slice(-2), mm = ("0" + d.getMinutes()).slice(-2);
        var tz = /GMT([+-]\d{4})/.exec(d.toString());
        var tzs = tz !== null ? "UTC" + tz[1].substr(0, 3) + ":" + tz[1].substr(3) : "";
        return hh + ":" + mm + (tzs !== "" ? " " + tzs : "");
    }

    // ---- histories (90 samples ≈ 90 s at 1 Hz) ---------------------------
    property var _cpuH: []
    property var _memH: []
    property var _gpuH: []
    property var _stoH: []
    function _push(h, v) {
        var a = h.slice();
        a.push(v);
        if (a.length > 90)
            a.shift();
        return a;
    }

    // ---- deltas: cpu busy% + net rates need the previous frame ------------
    property double _pIdle: NaN
    property double _pTotal: NaN
    property double _pRx: NaN
    property double _pTx: NaN
    property real cpuBusy: NaN
    property double rxBps: NaN
    property double txBps: NaN
    property int _tick: 0            // bumps masthead SAMPLE clock per frame

    onStatsChanged: {
        _tick++;
        sp.tick();
        var idl = num(stats.cpu_idle), tot = num(stats.cpu_total);
        if (isFinite(idl) && isFinite(tot) && isFinite(_pIdle) && _pTotal > 0 && tot > _pTotal)
            cpuBusy = Math.min(100, Math.max(0, 100 * (1 - (idl - _pIdle) / (tot - _pTotal))));
        _pIdle = idl; _pTotal = tot;
        var rx = num(stats.net_rx), tx = num(stats.net_tx);
        if (isFinite(rx) && isFinite(tx) && isFinite(_pRx) && rx >= _pRx) {
            rxBps = rx - _pRx;   // frames arrive ~1 Hz -> delta ≈ B/s
            txBps = tx - _pTx;
        }
        _pRx = rx; _pTx = tx;
        _cpuH = _push(_cpuH, num(stats.cpu_temp));
        _memH = _push(_memH, memUsedGb);
        _gpuH = _push(_gpuH, gpuTemp);
        _stoH = _push(_stoH, num(stats.fs_root_pct));
    }

    Sys.SysPoll { id: sp; live: root.shown }

    // ---- derived telemetry ----------------------------------------------
    readonly property double memTotalGb: gbOfKb(stats.mem_total_kb)
    readonly property double memUsedGb: isFinite(memTotalGb) ? memTotalGb - gbOfKb(stats.mem_avail_kb) : NaN
    readonly property double memPct: isFinite(memUsedGb) && memTotalGb > 0 ? 100 * memUsedGb / memTotalGb : NaN
    readonly property double memGaugeMax: isFinite(memTotalGb) ? Math.ceil(memTotalGb / 16) * 16 : 64
    readonly property double gpuTemp: isFinite(num(stats.dev_gpu0_temp)) ? num(stats.dev_gpu0_temp) : num(stats.i_temp_pkg)
    readonly property double gpuClk: isFinite(num(stats.dev_gpu0_mhz)) ? num(stats.dev_gpu0_mhz) : num(stats.i_freq_mhz)
    readonly property double gpuVramC: isFinite(num(stats.i_temp_vram)) ? num(stats.i_temp_vram) : NaN
    readonly property var coreMhz: {
        var a = [];
        for (var i = 0; i < 12; i++) {
            var v = num(stats["dev_core" + i + "_mhz"]);
            if (isFinite(v))
                a.push(v);
        }
        return a;
    }
    readonly property var gpuLink: {
        var n = Topology.node("gpu_arc");
        if (n === undefined || n.link === Topology.unknown)
            return FuiTokens.unknownGlyph;
        var p = String(n.link).split("@");
        return p.length === 2 ? "Gen" + p[1] + " " + p[0] : String(n.link);
    }

    // ---- geometry (design 1920x1200, proportional) -----------------------
    readonly property real m: 24
    readonly property real gut: FuiTokens.gutter
    readonly property real topY: 96
    readonly property real ledgerH: 156
    readonly property real ledgerY: height - 20 - ledgerH
    readonly property real midH: ledgerY - gut - topY
    readonly property real heroH: midH * (640 / 936)
    readonly property real contentW: width - m * 2
    readonly property real devW: (contentW - gut) * (1128 / 1872)
    readonly property real rightW: contentW - gut - devW

    // ====================================================================
    Rectangle { anchors.fill: parent; color: FuiTokens.bg }
    Sys.BgSheet {}

    // ---------------------------------------------------------------- masthead
    Item {
        id: mh
        x: 40
        y: 22
        width: parent.width - 56
        height: 64
        Row {
            spacing: 18
            anchors { left: parent.left; top: parent.top; topMargin: 8 }
            Text {
                textFormat: Text.StyledText
                text: 'DEVICES <span style="color:' + FuiTokens.css(FuiTokens.acid) + '">&amp;</span> SYSTEM'
                color: FuiTokens.white
                font.family: FuiTokens.display; font.pixelSize: 22; font.letterSpacing: 6
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.screenName
                color: FuiTokens.mute
                font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.tag; font.letterSpacing: FuiTokens.ls.tag
            }
        }
        Row {
            anchors { right: parent.right; top: parent.top; topMargin: 4 }
            spacing: 28
            Repeater {
                model: [
                    { "cap": "HOST", "v": String(root.stats.host !== undefined ? root.stats.host : FuiTokens.unknownGlyph).toUpperCase(), "hero": true },
                    { "cap": "UPTIME", "v": root._uptimeTxt(root.stats.uptime_s) }
                ]
                delegate: Column {
                    id: mcol
                    required property var modelData
                    spacing: 2
                    Text {
                        text: mcol.modelData.cap
                        color: FuiTokens.mute
                        font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.cap; font.letterSpacing: FuiTokens.ls.cap
                    }
                    Text {
                        text: mcol.modelData.v
                        color: FuiTokens.white
                        font.family: mcol.modelData.hero === true ? FuiTokens.display : FuiTokens.mono
                        font.pixelSize: mcol.modelData.hero === true ? 16 : FuiTokens.px.mid
                        font.letterSpacing: mcol.modelData.hero === true ? 3 : 0
                    }
                    Text {
                        visible: mcol.modelData.sub !== undefined && mcol.modelData.sub !== ""
                        text: mcol.modelData.sub !== undefined ? mcol.modelData.sub : ""
                        color: FuiTokens.faint
                        font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- frames
    FuiFrame {
        id: devFrame
        x: root.m
        y: root.topY
        width: root.devW
        height: root.heroH
        code: "DEV-BAY"
        title: "Device bay // usb topology"
        meta: topo.metaText
        Sys.TopoMap {
            id: topo
            anchors.fill: parent
            poll: sp
            stats: root.stats
        }
    }

    FuiFrame {
        id: tlmFrame
        x: devFrame.x + devFrame.width + root.gut
        y: root.topY
        width: root.rightW
        height: root.heroH
        code: "SYS-TLM"
        title: "Telemetry"
        meta: "sensors + procfs + fsstat"
        Item {
            anchors.fill: parent
            readonly property real cw: (width - 16) / 2
            readonly property real ch: (height - 16) / 2

            // ---- CPU ----
            Sys.TCell {
                x: 0; y: 0; width: parent.cw; height: parent.ch
                code: "T-01"
                gaugeV: isFinite(root.num(root.stats.cpu_temp)) ? root.num(root.stats.cpu_temp) : null
                gaugeMin: 20; gaugeMax: 100
                gaugeMajors: [20, 40, 60, 80, 100]
                gaugeRedFrom: 95; gaugeRedTo: 100
                gaugeMarkers: {
                    var c = root.num(root.stats.dev_ccd1_t);
                    return isFinite(c) ? [{ "v": c, "t": "D1" }] : [];
                }
                gaugeColor: root.num(root.stats.cpu_temp) >= 80 ? FuiTokens.warn : FuiTokens.ice
                gaugeUnit: "C TCTL"
                gaugeTitle: "CPU temperature"
                gaugeSub: "tjmax 95"
                statRows: [
                    { "l": "cores", "v": (root.has("cpu_cores") ? root.stats.cpu_cores : "?") + "C / " + (root.has("cpu_count") ? root.stats.cpu_count : "?") + "T" },
                    { "l": "busy", "v": isFinite(root.cpuBusy) ? Math.round(root.cpuBusy) + "%" : FuiTokens.unknownGlyph, "vc": root.cpuBusy >= 90 ? FuiTokens.warn : FuiTokens.dim },
                    { "l": "clk avg", "v": root.tNum(root.stats.cpu_mhz_avg) + " MHz" }
                ]
                barsCap: "CORE MHZ 0-11"
                bars: root.coreMhz
                barsMin: {
                    var a = root.coreMhz;
                    if (a.length === 0) return 0;
                    return Math.floor(Math.min.apply(null, a) * 0.9 / 100) * 100;
                }
                barsMax: {
                    var a = root.coreMhz;
                    if (a.length === 0) return 100;
                    return Math.ceil(Math.max.apply(null, a) * 1.05 / 100) * 100;
                }
                barsColor: FuiTokens.azure
                sparkCap: "TCTL LAST 90S"
                spark: root._cpuH
                sparkColor: root.num(root.stats.cpu_temp) >= 80 ? FuiTokens.warn : FuiTokens.ice
            }

            // ---- MEM ----
            Sys.TCell {
                x: parent.cw + 16; y: 0; width: parent.cw; height: parent.ch
                code: "T-02"
                gaugeV: isFinite(root.memUsedGb) ? Math.round(root.memUsedGb * 10) / 10 : null
                gaugeMin: 0; gaugeMax: root.memGaugeMax
                gaugeMajors: {
                    var M = root.memGaugeMax;
                    return [0, Math.round(M / 4), Math.round(M / 2), Math.round(M * 3 / 4), Math.round(M)];
                }
                gaugeColor: FuiTokens.ice
                gaugeUnit: "GB USED"
                gaugeTitle: "Memory"
                gaugeSub: isFinite(root.memPct) ? Math.round(root.memPct) + "% of " + Math.round(root.memTotalGb) + " GB" : ""
                statRows: [
                    { "l": "avail", "v": root._gbTxt(root.gbOfKb(root.stats.mem_avail_kb), 1) },
                    { "l": "swap", "v": root.has("swap_total_kb")
                          ? root._gbTxt(root.gbOfKb(root.stats.swap_total_kb) - root.gbOfKb(root.stats.swap_free_kb), 1) + " / " + root._gbTxt(root.gbOfKb(root.stats.swap_total_kb), 0)
                          : FuiTokens.unknownGlyph },
                    { "l": "dimm0/1", "v": root.tNum(root.stats.dev_dimm0_t !== undefined ? root.stats.dev_dimm0_t : root.stats.dimm0_temp) + " / " + root.tNum(root.stats.dev_dimm1_t !== undefined ? root.stats.dev_dimm1_t : root.stats.dimm1_temp) + " C",
                      "vc": sp.dimmLim !== null && (root.num(root.stats.dev_dimm0_t) >= sp.dimmLim[0] || root.num(root.stats.dev_dimm1_t) >= sp.dimmLim[0]) ? FuiTokens.warn : FuiTokens.dim }
                ]
                barsCap: "DIMM TEMP C"
                bars: [root.num(root.stats.dev_dimm0_t !== undefined ? root.stats.dev_dimm0_t : root.stats.dimm0_temp),
                       root.num(root.stats.dev_dimm1_t !== undefined ? root.stats.dev_dimm1_t : root.stats.dimm1_temp)]
                barsMin: 20; barsMax: sp.dimmLim !== null ? sp.dimmLim[1] : 85
                barsHi: sp.dimmLim !== null ? sp.dimmLim[0] : null
                barsColor: FuiTokens.ice
                sparkCap: "USED GB 90S"
                spark: root._memH
            }

            // ---- GPU — every inventoried adapter, Intel first (GpuCards) ----
            Sys.GpuPair {
                x: 0; y: parent.ch + 16; width: parent.cw; height: parent.ch
                stats: root.stats
            }

            // ---- STO ----
            Sys.TCell {
                x: parent.cw + 16; y: parent.ch + 16; width: parent.cw; height: parent.ch
                code: "T-04"
                gaugeV: isFinite(root.num(root.stats.fs_root_pct)) ? root.num(root.stats.fs_root_pct) : null
                gaugeMin: 0; gaugeMax: 100
                gaugeMajors: [0, 25, 50, 75, 100]
                gaugeRedFrom: 90; gaugeRedTo: 100
                gaugeColor: root.num(root.stats.fs_root_pct) >= 90 ? FuiTokens.alert : FuiTokens.ice
                gaugeUnit: "% ROOT"
                gaugeTitle: "Storage"
                gaugeSub: root.has("fs_root_used") && root.has("fs_root_size")
                          ? root._fmtBytes(root.stats.fs_root_used) + " / " + root._fmtBytes(root.stats.fs_root_size) : ""
                statRows: [
                    { "l": "nvme0", "v": root.tNum(root.stats.dev_nvme0_t !== undefined ? root.stats.dev_nvme0_t : root.stats.nvme0_temp) + " C" },
                    { "l": "nvme1", "v": root.tNum(root.stats.dev_nvme1_t !== undefined ? root.stats.dev_nvme1_t : root.stats.nvme1_temp) + " C" },
                    { "l": "home", "v": root.has("fs_home_pct") ? root.tNum(root.stats.fs_home_pct) + "% used" : FuiTokens.unknownGlyph }
                ]
                sparkCap: "ROOT % 90S"
                spark: root._stoH
            }
        }
    }

    FuiFrame {
        id: audFrame
        x: root.m
        y: devFrame.y + devFrame.height + root.gut
        width: root.devW
        height: root.ledgerY - root.gut - y
        code: "AUD-RT"
        title: "PipeWire routing"
        meta: "pactl sinks/sources"
        Sys.AudioRoute {
            anchors.fill: parent
            poll: sp
        }
    }

    FuiFrame {
        id: netFrame
        x: tlmFrame.x
        y: audFrame.y
        width: root.rightW
        height: audFrame.height
        code: "NET-PCI"
        title: "Network // pcie links"
        meta: "ip + lspci sysfs"
        Sys.NetPci {
            anchors.fill: parent
            poll: sp
            stats: root.stats
            rxBytes: root._pRx
            txBytes: root._pTx
            rxRate: root.rxBps
            txRate: root.txBps
        }
    }

    FuiFrame {
        id: ledFrame
        x: root.m
        y: root.ledgerY
        width: root.contentW
        height: root.ledgerH
        code: "LEDGER"
        title: "System ledger"
        meta: "omarchy + hyprland"
        Sys.Ledger {
            anchors { fill: parent; margins: 6 }
            poll: sp
            stats: root.stats
            screenName: root.screenName
        }
    }

}
