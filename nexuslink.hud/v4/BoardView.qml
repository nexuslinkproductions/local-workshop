pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell

// BoardView.qml — DP-2 "BOARD SCHEMATIC" (lane D2, glyphs lane W3).
// A real traced wiring diagram, not card stacks: PCIe root complex ->
// bridge hierarchy -> endpoints, CPU package with CCD0/CCD1 core tiles,
// data fabric + DIMM temps (SPD5118), USB tree to leaf devices, PCI audio
// devices -> PipeWire routes, three displays. Static node identities come
// from the Topology singleton (recon/devices-bus.json scaffold); live
// vitals/flows merge dev_* + legacy stats keys through Topology.refresh(),
// which HudV4 (lane H) drives once per collector batch.
//
// Lane W3: nodes are no longer identical name-boxes — a kind->shape
// registry keys on node.extra.cls (the recon class, not the coarse
// contract kind) and paints each class as its real hardware silhouette
// with the KindGlyph canvas: CPU = pin-framed die slab, GPUs = card
// profiles (B580 dual-fan vs iGPU chip-card), DIMMs = notched sticks with
// temp stripes, NVMe = M.2 sticks, pci bridges = bare crosspoint
// diamonds (names live in the detail tray only), USB = round hub /
// dongle glyphs with silkscreen class tags, audio = jack + wave, NICs =
// RJ45/antenna ports, displays = little screens. Vitals stay beside the
// glyph as captions; edges, flow dots and both lenses are untouched.
//
// Honesty rules (BRIEF-V4-BUILD §3/§4):
//   * a vital the collector does not emit renders "—", never fabricated
//   * edge particles animate ONLY while that edge's flow is nonzero —
//     no perpetual motion; connectivity-only links just light
//   * wires repaint on Topology.statsRev / lens / geometry, never on a clock
//   * nodes with no temp get no HEAT tint (mock's data-t contract)

Item {
    id: root

    // ---- injected by HudV4.qml (lane H) -----------------------------------
    property var stats: ({})            // last applyFrame map, key -> string
    property string screenName: "DP-2"
    property bool running: true         // gate edge particles when screen hidden
    property string lens: "link"        // "link" | "heat"
    property var hoverId: null          // transient hover focus (node id)
    property var pinId: null            // click-pinned selection (node id)
    readonly property var focusId: hoverId !== null ? hoverId : pinId

    // ---- lane B4: DP-2 multi-view — 0 = BOARD schematic, 1 = OPS feed -----
    // `boardActive` gates wire-dot animations + link repaints while the board
    // tab is hidden behind OpsView (same trick `running` plays for the deck).
    // `viewDefs` is the segmented-control model — N pages: extend the list and
    // add a `visible: viewTab === n` page item to `wrap` to add a third view.
    property int viewTab: 0
    property var viewDefs: [
        {
            t: "BOARD"
        },
        {
            t: "OPS"
        }
    ]
    readonly property int viewCount: viewDefs.length
    readonly property bool boardActive: running && viewTab === 0

    // discovery latch — a page index marked the first time it is shown; the
    // inactive-tab hint pulse runs only while a page remains unseen, so the
    // affordance stops forever once the operator has visited every view.
    property var _seenPages: ({})
    function pageSeen(i) {
        return _seenPages[i] === true;
    }
    function markPage(i) {
        var s = _seenPages;
        s[i] = true;
        _seenPages = s;                  // re-assign so bindings re-evaluate
    }
    // wrap-around stepper — ‹ › keys and the tab-bar wheel share this path.
    function stepPage(d) {
        var n = viewCount;
        viewTab = ((viewTab + d) % n + n) % n;
    }
    onViewTabChanged: markPage(viewTab)
    // a shrunk viewDefs can't leave viewTab pointing at a page that no
    // longer exists — clamp into range
    onViewCountChanged: viewTab = Math.max(0, Math.min(viewTab, viewCount - 1))

    // ---- board virtual space: mock svg viewBox 1872x1004, stretched -------
    readonly property real vw: 1872
    readonly property real vh: 1004
    function sx(v) {
        return v * board.width / vw;
    }
    function sy(v) {
        return v * board.height / vh;
    }

    // ---- palette/font shortcuts (Style singleton, lane S) -----------------
    readonly property color cInk: Style.c.ink
    readonly property color cInk2: Style.c.ink2
    readonly property color cRecess: Style.c.recess
    readonly property color cRecessTop: Style.c.recessTop
    readonly property color cEdge: Style.c.edge
    readonly property color cTxt: Style.c.txt
    readonly property color cDim: Style.c.dim
    readonly property color cMute: Style.c.mute
    readonly property color cFaint: Style.c.faint
    readonly property color cAcc: Style.c.accent
    readonly property color cIce: Style.c.accent2
    readonly property color cWarn: Style.c.warn
    readonly property color cAlert: Style.c.alert
    readonly property color cUnk: Style.c.unknown
    readonly property string fDisp: Style.f.display
    readonly property string fMono: Style.f.mono
    readonly property string dash: "—"

    // ---------- generic value helpers (unknown sentinel -> "—") -----------
    function isU(v) {
        return Topology.isUnknown(v);
    }
    function tS(v) {
        return isU(v) ? dash : Math.round(Number(v)) + "°";
    }
    function pS(v) {
        return isU(v) ? dash : Math.round(Number(v)) + "%";
    }
    function wS(v) {
        return isU(v) ? dash : Math.round(Number(v)) + " W";
    }
    function mS(v) {
        return isU(v) ? dash : String(Math.round(Number(v)));
    }
    function sn(k) {                     // stats key -> number | unknown
        var v = stats[k];
        if (v === undefined || v === "")
            return Topology.unknown;
        var n = Number(v);
        return isFinite(n) ? n : Topology.unknown;
    }
    function ss(k) {                     // stats key -> string | "—"
        var v = stats[k];
        return (v === undefined || v === "") ? dash : String(v);
    }
    function stOf(n) {                   // node.state -> text
        if (!n || isU(n.state))
            return dash;
        return String(n.state);
    }
    function linkOf(n) {                 // live link, else static spec, else —
        if (!n)
            return dash;
        if (!isU(n.link))
            return String(n.link);
        if (n.extra && n.extra.linkSpec !== undefined)
            return String(n.extra.linkSpec);
        return dash;
    }
    function volOf(pid) {                // pipewire volume % | "—"
        var p = Topology.node(pid);
        if (!p || !p.extra || isU(p.extra.vol_pct))
            return dash;
        return Math.round(Number(p.extra.vol_pct)) + "%";
    }
    function liveOf(pid) {               // pipewire presence -> LIVE label
        var p = Topology.node(pid);
        if (!p || isU(p.state))
            return dash;
        return p.state === "present" ? "LIVE" : String(p.state);
    }
    // Largest recorded partition on a block device ("nvme0n1p3 · NTFS 71%").
    function partOf(ownerId) {
        var best = null;
        var ps = Topology.parts;
        for (var k in ps) {
            var p = ps[k];
            if (!p || !p.extra || p.extra.parentId !== ownerId)
                continue;
            if (best === null) {
                best = p;
                continue;
            }
            var bs = isU(best.extra.size_bytes) ? 0 : Number(best.extra.size_bytes);
            var cs = isU(p.extra.size_bytes) ? 0 : Number(p.extra.size_bytes);
            if (cs > bs)
                best = p;
        }
        if (best === null)
            return dash + " partitions";
        var x = best.extra;
        var lab = (!isU(x.plabel) && x.plabel !== "") ? String(x.plabel) : (!isU(x.fstype) ? String(x.fstype) : String(best.id));
        var pct = isU(x.pct) ? dash : Math.round(Number(x.pct)) + "%";
        return String(best.id) + " · " + lab + " " + pct;
    }
    function kbToG(kb) {
        if (isU(kb))
            return dash;
        return (Number(kb) / 1048576).toFixed(1) + "G";
    }
    // RichText colours — acid values go amber under the heat lens
    // (mock `.heat .node .nv b{color:var(--amber)}`).
    function vB(v) {
        return '<b><font color="' + (lens === "heat" ? "#ffb300" : "#c8f31d") + '">' + v + '</font></b>';
    }
    function vI(v) {
        return '<font color="#8fd8e8">' + v + '</font>';
    }
    function vW(v) {
        return '<font color="#ffb300">' + v + '</font>';
    }

    // =========================== node specs ==============================
    // Static layout traced from candidates/mock2/B/dp2.html. `ids[0]` is the
    // primary Topology node; further ids are children folded into the same
    // box (input devices, netifs, pipewire leaves on audio cards).
    readonly property var nodeSpecs: [
        {
            ids: ["datafabric"],
            x: 24,
            y: 330,
            w: 180,
            role: "norm",
            nn: "DATA FABRIC"
        },
        {
            ids: ["mem"],
            x: 24,
            y: 436,
            w: 180,
            role: "norm",
            nn: "DDR5 · 64.85 GB"
        },
        {
            ids: ["dimm0"],
            x: 24,
            y: 540,
            w: 180,
            role: "leaf",
            nn: "DIMM 0"
        },
        {
            ids: ["dimm1"],
            x: 24,
            y: 612,
            w: 180,
            role: "leaf",
            nn: "DIMM 1"
        },
        {
            ids: ["smbus0"],
            x: 24,
            y: 730,
            w: 180,
            role: "leaf",
            nn: "FCH SMBus"
        },
        {
            ids: ["psp"],
            x: 24,
            y: 800,
            w: 180,
            role: "leaf",
            nn: "AMD PSP / CCP"
        },
        {
            ids: ["bt_hci0"],
            x: 24,
            y: 870,
            w: 180,
            role: "leaf",
            nn: "BT · hci0 MT7922"
        },
        {
            ids: ["pci0000_00"],
            x: 300,
            y: 240,
            w: 210,
            role: "norm",
            nn: "PCIe ROOT"
        },
        {
            ids: ["pci_00_01_1"],
            x: 596,
            y: 60,
            w: 150,
            role: "bridge",
            nn: "BR 00:01.1"
        },
        {
            ids: ["pci_00_01_2"],
            x: 596,
            y: 210,
            w: 150,
            role: "bridge",
            nn: "BR 00:01.2"
        },
        {
            ids: ["pci_00_02_1"],
            x: 596,
            y: 330,
            w: 150,
            role: "bridge",
            nn: "BR 00:02.1"
        },
        {
            ids: ["pci_00_02_2"],
            x: 596,
            y: 560,
            w: 150,
            role: "bridge",
            nn: "BR 00:02.2"
        },
        {
            ids: ["pci_00_08_1"],
            x: 596,
            y: 680,
            w: 150,
            role: "bridge",
            nn: "BR 00:08.1"
        },
        {
            ids: ["pci_00_08_3"],
            x: 596,
            y: 930,
            w: 150,
            role: "bridge",
            nn: "BR 00:08.3"
        },
        {
            ids: ["pci_01_00_0"],
            x: 830,
            y: 30,
            w: 160,
            role: "bridge",
            nn: "INTEL SW UP 01:00.0"
        },
        {
            ids: ["pci_02_01_0"],
            x: 830,
            y: 96,
            w: 160,
            role: "bridge",
            nn: "SW DN 02:01.0"
        },
        {
            ids: ["pci_02_02_0"],
            x: 830,
            y: 138,
            w: 160,
            role: "bridge",
            nn: "SW DN 02:02.0"
        },
        {
            ids: ["gpu_arc"],
            x: 1076,
            y: 24,
            w: 300,
            role: "norm",
            nn: "INTEL ARC B580 · xe"
        },
        {
            ids: ["nvme0"],
            x: 830,
            y: 190,
            w: 280,
            role: "norm",
            nn: "KINGSTON SNV3S2000G 2TB"
        },
        {
            ids: ["pci_06_00_0"],
            x: 830,
            y: 310,
            w: 170,
            role: "bridge",
            nn: "CHIPSET SW 06:00.0"
        },
        {
            ids: ["nvme1"],
            x: 830,
            y: 540,
            w: 280,
            role: "norm",
            nn: "SAMSUNG 980 PRO 2TB"
        },
        {
            ids: ["gpu_apu"],
            x: 830,
            y: 660,
            w: 280,
            role: "norm",
            nn: "AMD RAPHAEL iGPU · amdgpu"
        },
        {
            ids: ["xhci_apu0"],
            x: 830,
            y: 790,
            w: 170,
            role: "leaf",
            nn: "xHCI 14:00.3"
        },
        {
            ids: ["xhci_apu1"],
            x: 830,
            y: 858,
            w: 170,
            role: "leaf",
            nn: "xHCI 14:00.4"
        },
        {
            ids: ["xhci_apu2"],
            x: 830,
            y: 930,
            w: 170,
            role: "leaf",
            nn: "xHCI 15:00.0"
        },
        {
            ids: ["pci_07_0a_0"],
            x: 1080,
            y: 290,
            w: 130,
            role: "bridge",
            nn: "PORT 07:0a.0"
        },
        {
            ids: ["pci_07_0b_0"],
            x: 1080,
            y: 360,
            w: 130,
            role: "bridge",
            nn: "PORT 07:0b.0"
        },
        {
            ids: ["pci_07_0c_0"],
            x: 1080,
            y: 430,
            w: 130,
            role: "bridge",
            nn: "PORT 07:0c.0"
        },
        {
            ids: ["pci_07_0d_0"],
            x: 1080,
            y: 500,
            w: 130,
            role: "bridge",
            nn: "PORT 07:0d.0"
        },
        {
            ids: ["snd_apu_hdmi"],
            x: 1190,
            y: 640,
            w: 230,
            role: "leaf",
            nn: "RADEON HD AUDIO 14:00.1"
        },
        {
            ids: ["snd_apu_analog", "pw_sink_analog", "pw_src_analog"],
            x: 1190,
            y: 712,
            w: 230,
            role: "norm",
            nn: "RYZEN HD AUDIO 14:00.6"
        },
        {
            ids: ["pw_sink_corsair"],
            x: 1190,
            y: 790,
            w: 230,
            role: "leaf",
            nn: "PW SINK · Corsair"
        },
        {
            ids: ["pw_src_corsair"],
            x: 1190,
            y: 856,
            w: 230,
            role: "leaf",
            nn: "PW SRC · Corsair mono"
        },
        {
            ids: ["pw_src_kiyo"],
            x: 1190,
            y: 922,
            w: 230,
            role: "leaf",
            nn: "PW SRC · Razer Kiyo"
        },
        {
            ids: ["nic_eth", "net_eth"],
            x: 1290,
            y: 280,
            w: 250,
            role: "norm",
            nn: "RTL8125 2.5GbE · r8169"
        },
        {
            ids: ["nic_wifi", "net_wifi"],
            x: 1290,
            y: 368,
            w: 250,
            role: "norm",
            nn: "MT7922 WI-FI 6E · mt7921e"
        },
        {
            ids: ["sata0"],
            x: 1290,
            y: 490,
            w: 250,
            role: "leaf",
            nn: "SATA · ahci 12:00.0"
        },
        {
            ids: ["xhci_chipset"],
            x: 1290,
            y: 560,
            w: 250,
            role: "norm",
            nn: "xHCI 11:00.0 · 800-SERIES"
        },
        {
            ids: ["disp_dp1"],
            x: 1462,
            y: 16,
            w: 240,
            role: "disp",
            nn: "DP-1 · LC27G7xT"
        },
        {
            ids: ["disp_dp2"],
            x: 1462,
            y: 84,
            w: 240,
            role: "disp",
            nn: "DP-2 · HP E24i G4"
        },
        {
            ids: ["disp_hdmi3"],
            x: 1462,
            y: 152,
            w: 240,
            role: "disp",
            nn: "HDMI-A-3 · Z24n G3"
        },
        {
            ids: ["snd_arc", "pw_sink_hdmi"],
            x: 1462,
            y: 230,
            w: 240,
            role: "leaf",
            nn: "B580 HDMI/DP AUDIO"
        },
        {
            ids: ["usb7"],
            x: 1460,
            y: 770,
            w: 130,
            role: "bridge",
            nn: "usb7 ROOT"
        },
        {
            ids: ["usb_hub7"],
            x: 1460,
            y: 838,
            w: 120,
            role: "bridge",
            nn: "ASM107x 7-6"
        },
        {
            ids: ["flash_kingston"],
            x: 1460,
            y: 906,
            w: 180,
            role: "leaf",
            nn: "DataTraveler 3.0 · 7-3"
        },
        {
            ids: ["usb6"],
            x: 1580,
            y: 540,
            w: 130,
            role: "bridge",
            nn: "usb6 ROOT"
        },
        {
            ids: ["msi_mystic"],
            x: 1580,
            y: 640,
            w: 130,
            role: "leaf",
            nn: "MYSTIC LIGHT 6-7"
        },
        {
            ids: ["bt_radio"],
            x: 1580,
            y: 706,
            w: 130,
            role: "leaf",
            nn: "MT7922 BT 6-8"
        },
        {
            ids: ["usb_hub6"],
            x: 1730,
            y: 470,
            w: 120,
            role: "bridge",
            nn: "ASM107x 6-6"
        },
        {
            ids: ["cam_kiyo"],
            x: 1730,
            y: 560,
            w: 130,
            role: "leaf",
            nn: "Razer Kiyo 6-6.1"
        },
        {
            ids: ["rcvr_corsair", "input_corsair"],
            x: 1730,
            y: 626,
            w: 130,
            role: "leaf",
            nn: "Slipstream 6-6.2"
        },
        {
            ids: ["rcvr_logi", "input_mouse"],
            x: 1730,
            y: 692,
            w: 130,
            role: "leaf",
            nn: "G502 rcvr 6-6.3"
        },
        {
            ids: ["kbd_asus", "input_kbd"],
            x: 1730,
            y: 758,
            w: 130,
            role: "leaf",
            nn: "ASUS K7 6-6.4"
        }
    ]

    // =========================== wire specs ==============================
    // a/b are primary node ids; as/bs = attach side (l/r/t/b); watch = node
    // whose subtree aggregates the wire's flow; up = machine-side end
    // ("a" everywhere except the cpu->fabric link). Wires route BEHIND node
    // boxes, like the mock's under-layer svg.
    readonly property var wires: [
        {
            a: "cpu_pkg0",
            b: "datafabric",
            as: "b",
            bs: "t",
            watch: "cpu_pkg0",
            up: "b"
        },
        {
            a: "datafabric",
            b: "mem",
            as: "b",
            bs: "t",
            watch: "mem"
        },
        {
            a: "mem",
            b: "dimm0",
            as: "b",
            bs: "t",
            watch: "dimm0"
        },
        {
            a: "mem",
            b: "dimm1",
            as: "b",
            bs: "t",
            watch: "dimm1"
        },
        {
            a: "pci0000_00",
            b: "pci_00_01_1",
            as: "r",
            bs: "l",
            watch: "pci_00_01_1"
        },
        {
            a: "pci0000_00",
            b: "pci_00_01_2",
            as: "r",
            bs: "l",
            watch: "pci_00_01_2"
        },
        {
            a: "pci0000_00",
            b: "pci_00_02_1",
            as: "r",
            bs: "l",
            watch: "pci_00_02_1"
        },
        {
            a: "pci0000_00",
            b: "pci_00_02_2",
            as: "r",
            bs: "l",
            watch: "pci_00_02_2"
        },
        {
            a: "pci0000_00",
            b: "pci_00_08_1",
            as: "r",
            bs: "l",
            watch: "pci_00_08_1"
        },
        {
            a: "pci0000_00",
            b: "pci_00_08_3",
            as: "r",
            bs: "l",
            watch: "pci_00_08_3"
        },
        {
            a: "pci0000_00",
            b: "smbus0",
            as: "l",
            bs: "r",
            watch: "smbus0"
        },
        {
            a: "pci_00_01_1",
            b: "pci_01_00_0",
            as: "r",
            bs: "l",
            watch: "pci_01_00_0"
        },
        {
            a: "pci_01_00_0",
            b: "pci_02_01_0",
            as: "b",
            bs: "t",
            watch: "pci_02_01_0"
        },
        {
            a: "pci_01_00_0",
            b: "pci_02_02_0",
            as: "b",
            bs: "t",
            watch: "pci_02_02_0"
        },
        {
            a: "pci_02_01_0",
            b: "gpu_arc",
            as: "r",
            bs: "l",
            watch: "gpu_arc"
        },
        {
            a: "pci_02_02_0",
            b: "snd_arc",
            as: "r",
            bs: "l",
            watch: "snd_arc"
        },
        {
            a: "gpu_arc",
            b: "disp_dp1",
            as: "r",
            bs: "l",
            watch: "disp_dp1"
        },
        {
            a: "gpu_arc",
            b: "disp_dp2",
            as: "r",
            bs: "l",
            watch: "disp_dp2"
        },
        {
            a: "gpu_arc",
            b: "disp_hdmi3",
            as: "r",
            bs: "l",
            watch: "disp_hdmi3"
        },
        {
            a: "pci_00_01_2",
            b: "nvme0",
            as: "r",
            bs: "l",
            watch: "nvme0"
        },
        {
            a: "pci_00_02_1",
            b: "pci_06_00_0",
            as: "r",
            bs: "l",
            watch: "pci_06_00_0"
        },
        {
            a: "pci_00_02_2",
            b: "nvme1",
            as: "r",
            bs: "l",
            watch: "nvme1"
        },
        {
            a: "pci_00_08_1",
            b: "gpu_apu",
            as: "r",
            bs: "l",
            watch: "gpu_apu"
        },
        {
            a: "pci_00_08_1",
            b: "xhci_apu0",
            as: "r",
            bs: "l",
            watch: "xhci_apu0"
        },
        {
            a: "pci_00_08_1",
            b: "xhci_apu1",
            as: "r",
            bs: "l",
            watch: "xhci_apu1"
        },
        {
            a: "pci_00_08_1",
            b: "psp",
            as: "l",
            bs: "r",
            watch: "psp"
        },
        {
            a: "pci_00_08_3",
            b: "xhci_apu2",
            as: "r",
            bs: "l",
            watch: "xhci_apu2"
        },
        {
            a: "pci_06_00_0",
            b: "pci_07_0a_0",
            as: "r",
            bs: "l",
            watch: "pci_07_0a_0"
        },
        {
            a: "pci_06_00_0",
            b: "pci_07_0b_0",
            as: "r",
            bs: "l",
            watch: "pci_07_0b_0"
        },
        {
            a: "pci_06_00_0",
            b: "pci_07_0c_0",
            as: "r",
            bs: "l",
            watch: "pci_07_0c_0"
        },
        {
            a: "pci_06_00_0",
            b: "pci_07_0d_0",
            as: "r",
            bs: "l",
            watch: "pci_07_0d_0"
        },
        {
            a: "pci_07_0a_0",
            b: "nic_eth",
            as: "r",
            bs: "l",
            watch: "nic_eth"
        },
        {
            a: "pci_07_0b_0",
            b: "nic_wifi",
            as: "r",
            bs: "l",
            watch: "nic_wifi"
        },
        {
            a: "pci_07_0c_0",
            b: "xhci_chipset",
            as: "r",
            bs: "l",
            watch: "xhci_chipset"
        },
        {
            a: "pci_07_0d_0",
            b: "sata0",
            as: "r",
            bs: "l",
            watch: "sata0"
        },
        {
            a: "gpu_apu",
            b: "snd_apu_hdmi",
            as: "r",
            bs: "l",
            watch: "snd_apu_hdmi"
        },
        {
            a: "gpu_apu",
            b: "snd_apu_analog",
            as: "r",
            bs: "l",
            watch: "snd_apu_analog"
        },
        {
            a: "xhci_chipset",
            b: "usb6",
            as: "r",
            bs: "l",
            watch: "usb6"
        },
        {
            a: "xhci_chipset",
            b: "usb7",
            as: "b",
            bs: "t",
            watch: "usb7"
        },
        {
            a: "usb6",
            b: "usb_hub6",
            as: "r",
            bs: "l",
            watch: "usb_hub6"
        },
        {
            a: "usb6",
            b: "msi_mystic",
            as: "b",
            bs: "t",
            watch: "msi_mystic"
        },
        {
            a: "usb6",
            b: "bt_radio",
            as: "b",
            bs: "t",
            watch: "bt_radio"
        },
        {
            a: "usb_hub6",
            b: "cam_kiyo",
            as: "b",
            bs: "t",
            watch: "cam_kiyo"
        },
        {
            a: "usb_hub6",
            b: "rcvr_corsair",
            as: "b",
            bs: "t",
            watch: "rcvr_corsair"
        },
        {
            a: "usb_hub6",
            b: "rcvr_logi",
            as: "b",
            bs: "t",
            watch: "rcvr_logi"
        },
        {
            a: "usb_hub6",
            b: "kbd_asus",
            as: "b",
            bs: "t",
            watch: "kbd_asus"
        },
        {
            a: "usb7",
            b: "usb_hub7",
            as: "b",
            bs: "t",
            watch: "usb_hub7"
        },
        {
            a: "usb7",
            b: "flash_kingston",
            as: "b",
            bs: "t",
            watch: "flash_kingston"
        },
        {
            a: "rcvr_corsair",
            b: "pw_sink_corsair",
            as: "l",
            bs: "r",
            watch: "pw_sink_corsair"
        },
        {
            a: "rcvr_corsair",
            b: "pw_src_corsair",
            as: "l",
            bs: "r",
            watch: "pw_src_corsair"
        },
        {
            a: "cam_kiyo",
            b: "pw_src_kiyo",
            as: "l",
            bs: "r",
            watch: "pw_src_kiyo"
        },
        {
            a: "bt_radio",
            b: "bt_hci0",
            as: "l",
            bs: "r",
            watch: "bt_hci0"
        }
    ]

    // =================== node geometry registry ==========================
    // Delegates register their real item so wires attach to measured boxes.
    property var _boxes: ({})
    property int boxesRev: 0
    property var _desc: ({})            // nodeId -> [self + descendants]

    function registerBox(id, item) {
        _boxes[id] = item;
        boxesRev++;
    }
    function boxRect(id) {
        var it = _boxes[id];
        if (it === undefined || it === null)
            return null;
        return {
            x: it.x,
            y: it.y,
            w: it.width,
            h: it.height,
            cx: it.x + it.width / 2,
            cy: it.y + it.height / 2
        };
    }
    function attachPt(r, side) {
        if (side === "l")
            return {
                x: r.x,
                y: r.cy
            };
        if (side === "r")
            return {
                x: r.x + r.w,
                y: r.cy
            };
        if (side === "t")
            return {
                x: r.cx,
                y: r.y
            };
        return {
            x: r.cx,
            y: r.y + r.h
        };
    }
    function wireEnds(w) {
        boxesRev;                                    // binding dep
        var A = boxRect(w.a);
        var B = boxRect(w.b);
        if (!A || !B)
            return null;
        var p0 = attachPt(A, w.as);
        var p1 = attachPt(B, w.bs);
        return {
            x0: p0.x,
            y0: p0.y,
            x1: p1.x,
            y1: p1.y
        };
    }
    // Cubic point at t in [0,1] for the mock's M/C bezier (mx = mid x).
    function bezP(g, t) {
        var mx = (g.x0 + g.x1) / 2;
        var u = 1 - t;
        return {
            x: u * u * u * g.x0 + 3 * u * u * t * mx + 3 * u * t * t * mx + t * t * t * g.x1,
            y: u * u * u * g.y0 + 3 * u * u * t * g.y0 + 3 * u * t * t * g.y1 + t * t * t * g.y1
        };
    }

    function rebuildDesc() {
        var m = {};
        var list = Topology.nodeList || [];
        for (var i = 0; i < list.length; i++) {
            var acc = [];
            collectDesc(list[i].id, acc, {});
            m[list[i].id] = acc;
        }
        _desc = m;
    }
    function collectDesc(id, acc, seen) {
        if (seen[id])
            return;
        seen[id] = true;
        acc.push(id);
        var c = Topology.childIds(id);
        for (var i = 0; i < c.length; i++)
            collectDesc(c[i], acc, seen);
    }

    // ---------------- kind -> shape registry (lane W3) -------------------
    // Registry keys are recon classes (node.extra.cls), finer-grained than
    // contract kinds: usb_camera vs usb_receiver vs usb_hub all matter.
    // clsByNid is a static fallback so geometry is stable before
    // Topology.ready (and for ids Topology somehow lacks).
    readonly property var clsByNid: ({
            "datafabric": "data_fabric", "mem": "memory",
            "dimm0": "dimm", "dimm1": "dimm",
            "smbus0": "smbus", "psp": "crypto", "bt_hci0": "bluetooth",
            "pci0000_00": "pci_root",
            "pci_00_01_1": "pci_bridge", "pci_00_01_2": "pci_bridge",
            "pci_00_02_1": "pci_bridge", "pci_00_02_2": "pci_bridge",
            "pci_00_08_1": "pci_bridge", "pci_00_08_3": "pci_bridge",
            "pci_01_00_0": "pci_bridge", "pci_02_01_0": "pci_bridge",
            "pci_02_02_0": "pci_bridge", "pci_06_00_0": "pci_bridge",
            "pci_07_0a_0": "pci_bridge", "pci_07_0b_0": "pci_bridge",
            "pci_07_0c_0": "pci_bridge", "pci_07_0d_0": "pci_bridge",
            "gpu_arc": "gpu", "gpu_apu": "gpu",
            "nvme0": "nvme", "nvme1": "nvme",
            "xhci_apu0": "xhci", "xhci_apu1": "xhci", "xhci_apu2": "xhci",
            "xhci_chipset": "xhci", "sata0": "sata",
            "snd_apu_hdmi": "audio_pci", "snd_apu_analog": "audio_pci",
            "snd_arc": "audio_pci",
            "pw_sink_corsair": "pw_sink",
            "pw_src_corsair": "pw_source", "pw_src_kiyo": "pw_source",
            "nic_eth": "nic", "nic_wifi": "nic",
            "disp_dp1": "display", "disp_dp2": "display",
            "disp_hdmi3": "display",
            "usb6": "usb_roothub", "usb7": "usb_roothub",
            "usb_hub6": "usb_hub", "usb_hub7": "usb_hub",
            "flash_kingston": "usb_storage", "msi_mystic": "usb_rgb",
            "bt_radio": "usb_bluetooth", "cam_kiyo": "usb_camera",
            "rcvr_corsair": "usb_receiver", "rcvr_logi": "usb_receiver",
            "kbd_asus": "usb_keyboard"
        })
    function clsOf(nid, node) {
        if (node && node.extra && node.extra.cls !== undefined)
            return String(node.extra.cls);
        var c = clsByNid[nid];
        return c !== undefined ? c : "chip";
    }
    // Glyph footprint [w,h] in board px (crisp fixed size, like the fixed
    // caption fonts — positions scale via sx/sy, silhouettes stay sharp).
    // Per-node overrides beat per-class sizes (B580 card vs iGPU chip).
    readonly property var _glyphNid: ({
            "gpu_arc": [80, 30],
            "gpu_apu": [40, 18]
        })
    readonly property var _glyphCls: ({
            "data_fabric": [40, 30], "memory": [42, 30], "dimm": [18, 34],
            "smbus": [22, 20], "crypto": [20, 24], "bluetooth": [20, 24],
            "pci_root": [34, 26], "pci_bridge": [22, 22], "gpu": [44, 20],
            "nvme": [46, 15], "xhci": [22, 20], "sata": [20, 14],
            "audio_pci": [26, 20], "pw_sink": [20, 18], "pw_source": [20, 18],
            "nic": [26, 20], "display": [30, 22],
            "usb_roothub": [22, 22], "usb_hub": [22, 22],
            "usb_camera": [24, 15], "usb_receiver": [14, 22],
            "usb_keyboard": [30, 12], "usb_rgb": [14, 22],
            "usb_bluetooth": [14, 22], "usb_storage": [15, 24],
            "chip": [18, 18]
        })
    function glyphSize(nid, cls) {
        var s = _glyphNid[nid];
        if (s === undefined)
            s = _glyphCls[cls];
        if (s === undefined)
            s = _glyphCls["chip"];
        return {
            w: s[0],
            h: s[1]
        };
    }
    // Silkscreen class tag printed under a glyph ("" = no tag). USB
    // endpoints get their device class; bridges print nothing (tray only).
    readonly property var _clsTag: ({
            "data_fabric": "DF", "memory": "DDR5", "dimm": "SPD",
            "smbus": "I2C", "crypto": "CCP", "bluetooth": "HCI",
            "pci_root": "RC", "gpu": "GPU", "nvme": "M.2", "xhci": "xHC",
            "sata": "ATA", "audio_pci": "HDA", "pw_sink": "OUT",
            "pw_source": "IN", "nic": "NIC", "display": "EDID",
            "usb_roothub": "RHC", "usb_hub": "HUB", "usb_camera": "UVC",
            "usb_receiver": "HID", "usb_keyboard": "KBD", "usb_rgb": "RGB",
            "usb_bluetooth": "BT", "usb_storage": "MSC"
        })
    function classTag(cls) {
        var t = _clsTag[cls];
        return t !== undefined ? t : "";
    }
    // Cool-ice -> warn -> alert ramp for temp stripes/bars inside glyphs.
    function tempStroke(v) {
        var k = Math.max(0, Math.min(1, (Number(v) - 30) / 45));
        return "rgba(" + Math.round(143 + 112 * k) + "," + Math.round(216 - 140 * k) + "," + Math.round(232 - 180 * k) + ",0.9)";
    }

    // ----------------------- per-wire flow state --------------------------
    // Aggregates every throughput/activity flow whose source or sink sits in
    // the watched subtree. Byte flows carry direction (rx toward machine,
    // tx toward leaf); %/MHz/W activity collapses to one inbound dot.
    function wireFlow(w) {
        var fr = Topology.flowRates;                 // binding dep
        var nd = Topology.nodes;                     // binding dep (lit check)
        var watch = w.watch !== undefined ? w.watch : w.b;
        var ids = _desc[watch];
        if (ids === undefined)
            ids = [watch];
        var rx = 0, tx = 0, hasRx = false, hasTx = false, act = false;
        for (var fid in fr) {
            var f = fr[fid];
            if (!f || f.unit === "str")
                continue;                            // connectivity, not throughput
            if (ids.indexOf(f.a) < 0 && ids.indexOf(f.b) < 0)
                continue;
            var r = Number(f.rate);
            var on = f.active === true && isFinite(r) && r > 0;
            if (!on)
                continue;
            act = true;
            if (f.unit === "B/s") {
                if (isFinite(Number(f.rx))) {
                    rx += Number(f.rx);
                    hasRx = true;
                }
                if (isFinite(Number(f.tx))) {
                    tx += Number(f.tx);
                    hasTx = true;
                }
            }
        }
        var byteAct = (hasRx && rx > 0) || (hasTx && tx > 0);
        var lit = false;
        for (var i = 0; i < ids.length; i++) {
            var n = nd[ids[i]];
            if (!n || isU(n.state))
                continue;
            var s = String(n.state);
            if (s === "up" || s === "present" || s === "connected" || s === "mounted") {
                lit = true;
                break;
            }
        }
        return {
            on: act,
            hot: act,
            lit: lit || act,
            inOn: (hasRx && rx > 0) || (act && !byteAct),
            outOn: hasTx && tx > 0,
            actOnly: act && !byteAct,
            inDur: (act && !byteAct) ? 3000 : flowDur(rx),
            outDur: flowDur(tx)
        };
    }
    // bytes/s -> traversal ms (log-scaled: 1B ~5.6s, 1MB ~2s, >=100MB 1.4s)
    function flowDur(r) {
        var lr = Math.log(Math.max(1, r)) / Math.LN10;
        return Math.max(1400, Math.min(5600, 5600 - 600 * lr));
    }

    // ------------------------- per-node vitals ----------------------------
    function vitalFor(id) {
        var n = Topology.node(id);
        var x = (n && n.extra) ? n.extra : {};
        switch (id) {
        case "datafabric":
            return {
                nv: "00:18.0-7 · k10temp " + vB(tS(n ? n.temp : Topology.unknown)),
                ns: "PSI io " + ss("psi_io_some") + " · mem " + ss("psi_mem_some")
            };
        case "mem":
            return {
                nv: "avail " + vB(kbToG(x.avail_kb)),
                ns: "2× SPD5118 on i2c-20"
            };
        case "dimm0":
            return {
                nv: vB(tS(n ? n.temp : Topology.unknown)) + " · 20-0051",
                ns: "SPD5118 temp"
            };
        case "dimm1":
            return {
                nv: vB(tS(n ? n.temp : Topology.unknown)) + " · 20-0053",
                ns: "SPD5118 temp"
            };
        case "smbus0":
            return {
                nv: "00:14.0 · i2c-20",
                ns: stOf(n)
            };
        case "psp":
            return {
                nv: "14:00.2 · " + stOf(n),
                ns: "crypto"
            };
        case "bt_hci0":
            return {
                nv: "hci0 · " + (x.paired !== undefined && !isU(x.paired) ? vI(String(x.paired) + " paired") : stOf(n)),
                ns: (x.connected !== undefined && !isU(x.connected)) ? String(x.connected) + " conn" : ""
            };
        case "pci0000_00":
            return {
                nv: "Raphael/Granite Ridge",
                ns: "0000:00 · 6 bridges populated"
            };
        case "pci_00_01_1":
            return {
                nv: linkOf(n) + " · max x16@32",
                ns: "upstream → intel switch"
            };
        case "pci_00_02_1":
            return {
                nv: linkOf(n),
                ns: "→ chipset switch"
            };
        case "pci_00_01_2":
        case "pci_00_02_2":
        case "pci_00_08_1":
        case "pci_00_08_3":
            return {
                nv: linkOf(n),
                ns: ""
            };
        case "pci_01_00_0":
            return {
                nv: "8086:e2ff" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "pci_02_01_0":
            return {
                nv: "→ gpu" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "pci_02_02_0":
            return {
                nv: "→ hdmi audio" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "gpu_arc":
            return {
                nv: "pkg " + vB(tS(n ? n.temp : Topology.unknown)) + " · VRAM " + vI(tS(sn("i_temp_vram"))) + " · " + vB(wS(n ? n.power : Topology.unknown)) + " / " + (isU(sn("i_pwr_cap_w")) ? dash : Math.round(sn("i_pwr_cap_w")) + " W"),
                ns: "03:00.0 · fan " + (isU(x.fan_rpm) ? dash : Math.round(Number(x.fan_rpm))) + " rpm · " + mS(x.mhz) + " MHz · " + linkOf(n)
            };
        case "snd_arc":
            return {
                nv: "card 1 · sink LC27G7xT " + vI(volOf("pw_sink_hdmi")),
                ns: "04:00.0 · " + stOf(n)
            };
        case "nvme0":
        case "nvme1":
            return {
                nv: id + " · " + (x.bdf !== undefined ? String(x.bdf) : dash) + " · " + vB(tS(n ? n.temp : Topology.unknown)) + " / " + tS(x.temp2),
                ns: partOf(id) + " · rd " + (isU(x.rd_bps) ? dash : Topology.fmtB(x.rd_bps)) + " · wr " + (isU(x.wr_bps) ? dash : Topology.fmtB(x.wr_bps))
            };
        case "pci_06_00_0":
            return {
                nv: "1022:43f4" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "pci_07_0a_0":
            return {
                nv: "→ nic" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "pci_07_0b_0":
            return {
                nv: "→ wifi" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "pci_07_0c_0":
            return {
                nv: "→ xhci" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "pci_07_0d_0":
            return {
                nv: "→ sata" + (linkOf(n) !== dash ? " · " + linkOf(n) : ""),
                ns: ""
            };
        case "nic_eth":
            {
                var ne = Topology.node("net_eth");
                var st = ne ? stOf(ne) : dash;
                return {
                    nv: "enp15s0 " + (st === "up" ? vB("UP") : vI(st)) + " · 34:5a:60:dd:f5:a8",
                    ns: ""
                };
            }
        case "nic_wifi":
            {
                var nw = Topology.node("net_wifi");
                return {
                    nv: "wlp16s0 " + vI(nw ? stOf(nw) : dash) + " · no link",
                    ns: "10:00.0 · phy " + tS(n ? n.temp : Topology.unknown)
                };
            }
        case "sata0":
            return {
                nv: "600-series · " + (linkOf(n) !== dash ? linkOf(n) : stOf(n)),
                ns: ""
            };
        case "gpu_apu":
            return {
                nv: vB(pS(n ? n.load : Topology.unknown)) + " util · " + mS(x.mhz) + " MHz · " + vB(wS(n ? n.power : Topology.unknown)) + " PPT",
                ns: "14:00.0 · VRAM " + (isU(x.vram_used_mb) ? dash : Math.round(Number(x.vram_used_mb))) + " / " + (isU(x.vram_total_mb) ? dash : Math.round(Number(x.vram_total_mb))) + " MB"
            };
        case "snd_apu_hdmi":
            return {
                nv: "card 2 · " + vI("no sink routed"),
                ns: stOf(n)
            };
        case "snd_apu_analog":
            return {
                nv: "card 3 · analog sink " + vB(volOf("pw_sink_analog")),
                ns: "src analog-stereo " + liveOf("pw_src_analog")
            };
        case "xhci_chipset":
            return {
                nv: "usb6 480M · usb7 10G",
                ns: "via port 07:0c.0 · " + tS(n ? n.temp : Topology.unknown)
            };
        case "xhci_apu0":
            return {
                nv: "usb1/usb2 · no devices",
                ns: stOf(n)
            };
        case "xhci_apu1":
            return {
                nv: "usb3/usb4 · no devices",
                ns: stOf(n)
            };
        case "xhci_apu2":
            return {
                nv: "usb5 · no devices",
                ns: stOf(n)
            };
        case "usb6":
        case "usb7":
            return {
                nv: (x.speedSpec !== undefined ? String(x.speedSpec) : linkOf(n)) + " · " + stOf(n),
                ns: x.vidPid !== undefined ? String(x.vidPid) : ""
            };
        case "usb_hub6":
        case "usb_hub7":
            return {
                nv: "hub · " + (x.speedSpec !== undefined ? String(x.speedSpec) : linkOf(n)),
                ns: (x.vidPid !== undefined ? String(x.vidPid) + " · " : "") + stOf(n)
            };
        case "cam_kiyo":
            return {
                nv: "uvcvideo + mic · " + stOf(n),
                ns: "1532:0e03"
            };
        case "rcvr_corsair":
            return {
                nv: "sink " + vB(volOf("pw_sink_corsair")) + " · mic " + vI(liveOf("pw_src_corsair")),
                ns: "1b1c:0a42 · " + stOf(n)
            };
        case "rcvr_logi":
            return {
                nv: "",
                ns: "046d:c547 · " + stOf(n)
            };
        case "kbd_asus":
            return {
                nv: "kbd · " + stOf(Topology.node("input_kbd") || n),
                ns: "0b05:18aa · event13/14"
            };
        case "msi_mystic":
            return {
                nv: "rgb controller",
                ns: "0db0:0076 · " + stOf(n)
            };
        case "bt_radio":
            return {
                nv: "btusb · hci0",
                ns: "0e8d:0616 · " + stOf(n)
            };
        case "flash_kingston":
            return {
                nv: "sda · " + partOf(id),
                ns: "0951:1666 · " + stOf(n)
            };
        case "pw_sink_corsair":
            return {
                nv: vB(volOf(id)) + " · analog-stereo",
                ns: stOf(n)
            };
        case "pw_src_corsair":
            return {
                nv: vI(liveOf(id)) + " " + volOf(id),
                ns: "mono-fallback"
            };
        case "pw_src_kiyo":
            return {
                nv: "analog-stereo · " + liveOf(id),
                ns: stOf(n)
            };
        case "disp_dp1":
            return {
                nv: "2560×1440 @0,0 · " + stOf(n),
                ns: "card0-DP-1"
            };
        case "disp_dp2":
            return {
                nv: "1920×1200 @2560,0 · " + stOf(n),
                ns: "card0-DP-2"
            };
        case "disp_hdmi3":
            return {
                nv: "1920×1200 @-1920,0 · " + stOf(n),
                ns: "card0-HDMI-A-3"
            };
        }
        return {
            nv: linkOf(n),
            ns: stOf(n)
        };
    }

    // ---------------------- detail tray model -----------------------------
    function uplinkOf(id) {
        var el = Topology.edges;                     // binding dep
        for (var i = 0; i < el.length; i++) {
            if (el[i].b === id) {
                var e = el[i];
                var bw = isU(e.bw) ? dash : String(e.bw);
                return String(e.a) + " · " + bw;
            }
        }
        return dash;
    }
    function fmtV(v) {
        if (isU(v))
            return dash;
        if (typeof v === "number")
            return Math.abs(v) >= 100 ? String(Math.round(v)) : String(Math.round(v * 10) / 10);
        if (typeof v === "object" && v.length !== undefined)
            return "[" + v.length + "]";
        return String(v);
    }
    function trayData() {
        var fid = focusId;
        if (fid === null || fid === undefined)
            return null;
        var n = Topology.node(fid);
        if (!n)
            return null;
        var x = n.extra || {};
        var pairs = [];
        pairs.push(["KIND", n.kind]);
        if (x.cls !== undefined)
            pairs.push(["CLASS", String(x.cls)]);
        if (x.bdf !== undefined)
            pairs.push(["BDF", String(x.bdf)]);
        if (x.vidPid !== undefined)
            pairs.push(["VID:PID", String(x.vidPid)]);
        if (x.ifname !== undefined)
            pairs.push(["IFACE", String(x.ifname)]);
        if (x.blk !== undefined)
            pairs.push(["BLOCK", String(x.blk)]);
        pairs.push(["TEMP", tS(n.temp)]);
        pairs.push(["LOAD", pS(n.load)]);
        pairs.push(["POWER", wS(n.power)]);
        pairs.push(["LINK", linkOf(n)]);
        var skip = {
            cls: 1,
            parentId: 1,
            tag: 1,
            match: 1,
            parts: 1,
            bdf: 1,
            vidPid: 1,
            ifname: 1,
            blk: 1,
            vitalLabel: 1
        };
        var xtra = [];
        for (var k in x) {
            if (skip[k])
                continue;
            xtra.push([String(k).toUpperCase(), fmtV(x[k])]);
            if (xtra.length >= 10)
                break;
        }
        // folded sibling ids on the same box
        var subs = [];
        for (var s = 0; s < nodeSpecs.length; s++) {
            var sp = nodeSpecs[s];
            if (sp.ids.indexOf(fid) >= 0) {
                for (var j = 1; j < sp.ids.length; j++) {
                    var sn2 = Topology.node(sp.ids[j]);
                    if (sn2)
                        subs.push(sp.ids[j] + " · " + stOf(sn2));
                }
                break;
            }
        }
        var kids = Topology.childIds(fid);
        return {
            title: String(n.label),
            id: String(n.id),
            kind: String(n.kind),
            state: stOf(n),
            stateUp: !isU(n.state) && (n.state === "up" || n.state === "present" || n.state === "connected" || n.state === "mounted"),
            vitalSrc: (x.vitalLabel !== undefined ? String(x.vitalLabel) : "?") + " ← " + (x.vitalPath !== undefined ? String(x.vitalPath) : "?"),
            uplink: uplinkOf(fid),
            pairs: pairs,
            xtra: xtra,
            subs: subs,
            children: kids.length
        };
    }
    readonly property var trayM: trayData()

    // ------------------------- shelf summary -------------------------------
    function bridgeSpecs() {
        var ids = ["pci_00_01_1", "pci_00_01_2", "pci_00_02_1", "pci_00_02_2", "pci_00_08_1", "pci_00_08_3"];
        var out = [];
        for (var i = 0; i < ids.length; i++) {
            var n = Topology.node(ids[i]);
            var bdf = (n && n.extra && n.extra.bdf !== undefined) ? String(n.extra.bdf) : "?";
            out.push(bdf + " " + (n ? linkOf(n) : dash));
        }
        return out.join(" · ");
    }
    function usbLiveCount() {
        var nd = Topology.nodes;
        var c = 0;
        for (var k in nd) {
            var n = nd[k];
            if (n && n.extra && n.extra.cls && String(n.extra.cls).indexOf("usb_") === 0 && n.state === "present")
                c++;
        }
        return c;
    }
    readonly property int totalNodes: Topology.nodeCount + Topology.partCount

    // ============================ LAYOUT ==================================
    Column {
        id: wrap
        anchors.fill: parent
        anchors.leftMargin: 24
        anchors.rightMargin: 24
        anchors.topMargin: 20
        anchors.bottomMargin: 16
        spacing: 12

        // ---------------------------- masthead -----------------------------
        Rectangle {
            id: mast
            width: wrap.width
            height: 56
            radius: Style.r.pane
            color: root.cInk
            border.color: root.cEdge
            border.width: 1

            // holographic top rim (painted once)
            Canvas {
                anchors.left: mast.left
                anchors.right: mast.right
                anchors.top: mast.top
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                height: 2
                opacity: 0.75
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    if (width <= 0)
                        return;
                    var g = ctx.createLinearGradient(0, 0, width, 0);
                    var stops = ["transparent", "#8fd8e8", "#ff7ad9", "#c8f31d", "#8affd0", "transparent"];
                    for (var i = 0; i < stops.length; i++)
                        g.addColorStop(i / (stops.length - 1), stops[i]);
                    ctx.fillStyle = g;
                    ctx.fillRect(0, 0, width, height);
                }
                onWidthChanged: requestPaint()
            }

            Row {
                id: mastRow
                anchors.fill: mast
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 22

                Text {
                    id: mastTitle
                    anchors.verticalCenter: mastRow.verticalCenter
                    font.family: root.fDisp
                    font.pixelSize: 15
                    font.letterSpacing: 5.1
                    color: root.cTxt
                    text: "BOARD<font color=\"" + root.cAcc + "\">SCHEMATIC</font>"
                    textFormat: Text.RichText
                }
                Text {
                    id: mastSub
                    anchors.verticalCenter: mastRow.verticalCenter
                    font.family: root.fMono
                    font.pixelSize: 9
                    font.letterSpacing: 1.9
                    color: root.cMute
                    text: root.screenName + " · 1920×1200 · " + (Topology.ready ? root.totalNodes + " NODES" : root.dash + " NODES") + " · REAL INVENTORY"
                }
                Item {
                    width: Math.max(1, mastRow.width - mastTitle.width - mastSub.width - (legendRow.visible ? legendRow.width + mastRow.spacing : 0) - hotTxt.implicitWidth - lensRow.width - 4 * mastRow.spacing - 40)
                    height: 1
                }
                Row {
                    id: legendRow
                    anchors.verticalCenter: mastRow.verticalCenter
                    spacing: 6
                    visible: root.lens === "heat"
                    Rectangle {
                        width: 44
                        height: 4
                        radius: 2
                        anchors.verticalCenter: legendRow.verticalCenter
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop {
                                position: 0.0
                                color: "#1a6a7a"
                            }
                            GradientStop {
                                position: 0.5
                                color: root.cWarn
                            }
                            GradientStop {
                                position: 1.0
                                color: root.cAlert
                            }
                        }
                    }
                    Text {
                        anchors.verticalCenter: legendRow.verticalCenter
                        font.family: root.fMono
                        font.pixelSize: 9
                        color: root.cMute
                        text: "COOL → HOT"
                    }
                }
                Row {
                    id: hotTxt
                    anchors.verticalCenter: mastRow.verticalCenter
                    spacing: 8
                    // ratio of live links to known links; the count stays in the label
                    readonly property int total: {
                        var e = FlowBus.epoch;
                        return Object.keys(FlowBus.rates).length;
                    }
                    RingGauge {
                        anchors.verticalCenter: parent.verticalCenter
                        size: 26
                        strokeWidth: 3
                        value: hotTxt.total > 0 ? FlowBus.hotCount / hotTxt.total : -1
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        font.family: root.fMono
                        font.pixelSize: 9
                        color: root.cMute
                        text: FlowBus.hotCount + " HOT LINKS"
                    }
                }
                // LENS toggle — two embossed keys, pressed one goes acid
                Row {
                    id: lensRow
                    anchors.verticalCenter: mastRow.verticalCenter
                    spacing: 8
                    enabled: root.viewTab === 0        // board-only control
                    opacity: root.viewTab === 0 ? 1 : 0.35
                    Behavior on opacity {
                        NumberAnimation {
                            duration: Style.dur.snap
                        }
                    }
                    Text {
                        anchors.verticalCenter: lensRow.verticalCenter
                        font.family: root.fMono
                        font.pixelSize: 9
                        font.letterSpacing: 1.6
                        color: root.cMute
                        text: "LENS"
                    }
                    ActionToggle {
                        anchors.verticalCenter: lensRow.verticalCenter
                        label: "HEAT"
                        tone: "acid"
                        on: root.lens === "heat"
                        onToggled: root.lens = root.lens === "heat" ? "link" : "heat"
                    }
                }
            }
        }

        // ---------------------------- tab bar ------------------------------
        // lane B4: DP-2 hosts multiple views — this schematic + the OPS feed.
        // Segmented page control (same embossed-key idiom as the masthead LENS
        // keys): recessed track, indexed keys, ‹ › steppers, wheel paging.
        // N-view ready — extend root.viewDefs and add a `visible: viewTab === n`
        // page item to `wrap`; keys, steppers and the n/N caption follow.
        Rectangle {
            id: tabBar
            width: wrap.width
            height: 40
            radius: Style.r.pane
            color: root.cInk
            border.color: root.cEdge
            border.width: 1

            // wheel over the bar pages views — the "continuous page" feel
            WheelHandler {
                onWheel: function (e) {
                    var d = e.angleDelta.y !== 0 ? e.angleDelta.y : e.angleDelta.x;
                    if (d !== 0) {
                        root.stepPage(d > 0 ? -1 : 1);
                        e.accepted = true;
                    }
                }
            }

            // WORKFLOWS: one-tap launchers centred in the otherwise empty
            // middle of the page bar (the schematic grid itself is full, so the
            // corner overlay used for this collided with the CPU package node)
            Row {
                id: wfStrip
                anchors.centerIn: tabBar
                spacing: 8
                visible: tabBar.width > 900
                Text {
                    anchors.verticalCenter: wfStrip.verticalCenter
                    font.family: root.fMono
                    font.pixelSize: 8
                    font.letterSpacing: Style.f.lsEngraved
                    color: root.cMute
                    text: "WORKFLOWS"
                }
                Repeater {
                    model: [
                        { g: Style.ico.folder, a: ["uwsm-app", "--", "nautilus", "--new-window", Quickshell.env("HOME") + "/NEXUS_AI_CENTER"] },
                        { g: Style.ico.robot, a: ["omarchy-launch-tui", "--app-id=org.nexus.hermes", "hermes"] },
                        { g: Style.ico.layers, a: ["hyprctl", "dispatch", "focusmonitor", "HDMI-A-3"] },
                        { g: Style.ico.hub, a: ["hyprctl", "dispatch", "focusmonitor", "DP-1"] },
                        { g: Style.ico.shot, a: ["omarchy-capture-screenshot"] },
                        { g: Style.ico.pick, a: ["hyprpicker", "-a"] }
                    ]
                    delegate: Item {
                        id: wfKey
                        required property var modelData
                        width: 26
                        height: 26
                        IconWell {
                            anchors.fill: parent
                            size: 26
                            glyph: wfKey.modelData.g
                            hovered: wfMa.containsMouse
                        }
                        MouseArea {
                            id: wfMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "board"].concat(wfKey.modelData.a))
                        }
                    }
                }
            }

            Row {
                id: tabRow
                anchors.left: tabBar.left
                anchors.leftMargin: 14
                anchors.verticalCenter: tabBar.verticalCenter
                spacing: 12

                Text {
                    anchors.verticalCenter: tabRow.verticalCenter
                    font.family: root.fMono
                    font.pixelSize: 8
                    font.letterSpacing: Style.f.lsEngraved
                    color: root.cMute
                    text: "PAGE"
                }

                // recessed track — the keys sit in one machined slot so the
                // strip reads as a single control, not floating labels
                Rectangle {
                    id: segTrack
                    anchors.verticalCenter: tabRow.verticalCenter
                    width: segRow.width + 8
                    height: 28
                    radius: Style.r.emboss
                    border.width: 1
                    border.color: Qt.rgba(0, 0, 0, 0.55)
                    gradient: Gradient {
                        GradientStop {
                            position: 0.0
                            color: root.cRecessTop
                        }
                        GradientStop {
                            position: 1.0
                            color: root.cRecess
                        }
                    }

                    Row {
                        id: segRow
                        anchors.centerIn: segTrack
                        spacing: 4
                        Repeater {
                            model: root.viewDefs
                            delegate: Rectangle {
                                id: tkey
                                required property var modelData
                                required property int index
                                readonly property bool on: root.viewTab === tkey.index
                                readonly property bool hov: tkMa.containsMouse
                                // unseen pages keep a breathing hint until visited
                                readonly property bool unseen: !tkey.on && !root.pageSeen(tkey.index)
                                width: tkRow.implicitWidth + 24
                                height: 22
                                radius: Style.r.chip
                                border.width: 1
                                border.color: tkey.on ? Style.tone(root.cAcc, 0.55) : (tkey.hov ? Style.tone(root.cIce, 0.35) : Qt.rgba(0, 0, 0, 0.5))
                                gradient: Gradient {
                                    GradientStop {
                                        position: 0.0
                                        color: tkey.on ? "#121804" : (tkey.hov ? root.cInk2 : "transparent")
                                    }
                                    GradientStop {
                                        position: 1.0
                                        color: tkey.on ? "#1a2008" : (tkey.hov ? root.cInk : "transparent")
                                    }
                                }
                                // acid top strip on the seated key
                                Rectangle {
                                    anchors.left: tkey.left
                                    anchors.right: tkey.right
                                    anchors.top: tkey.top
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    height: 2
                                    radius: 1
                                    visible: tkey.on
                                    color: root.cAcc
                                    opacity: 0.85
                                }
                                Row {
                                    id: tkRow
                                    anchors.centerIn: tkey
                                    spacing: 7
                                    Text {
                                        anchors.verticalCenter: tkRow.verticalCenter
                                        font.family: root.fMono
                                        font.pixelSize: 8
                                        color: tkey.on ? root.cAcc : root.cFaint
                                        text: "0" + (tkey.index + 1)
                                    }
                                    Text {
                                        anchors.verticalCenter: tkRow.verticalCenter
                                        font.family: root.fDisp
                                        font.pixelSize: 10
                                        font.letterSpacing: 2.1
                                        color: tkey.on ? root.cAcc : (tkey.hov ? root.cTxt : root.cDim)
                                        text: tkey.modelData.t
                                    }
                                    // breathing discovery dot — stops forever
                                    // once this page has been visited once
                                    Rectangle {
                                        id: hintDot
                                        anchors.verticalCenter: tkRow.verticalCenter
                                        width: 5
                                        height: 5
                                        radius: 3
                                        color: root.cAcc
                                        visible: hintPulse.running
                                        SequentialAnimation on opacity {
                                            id: hintPulse
                                            loops: 6          // a discovery hint, not a permanent 60 fps animation
                                            running: root.running && tkey.unseen
                                            NumberAnimation {
                                                to: 0.25
                                                duration: 1400
                                                easing.type: Easing.InOutSine
                                            }
                                            NumberAnimation {
                                                to: 0.95
                                                duration: 1400
                                                easing.type: Easing.InOutSine
                                            }
                                        }
                                    }
                                }
                                MouseArea {
                                    id: tkMa
                                    anchors.fill: tkey
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.viewTab = tkey.index
                                }
                            }
                        }
                    }
                }

                // hairline divider between the control and the hint text —
                // both fold away on narrow decks so keys never collide with
                // the right-side steppers
                Rectangle {
                    anchors.verticalCenter: tabRow.verticalCenter
                    width: 1
                    height: 18
                    color: root.cEdge
                    visible: tabBar.width > 700
                }
                Text {
                    anchors.verticalCenter: tabRow.verticalCenter
                    font.family: root.fMono
                    font.pixelSize: 8
                    color: root.cFaint
                    visible: tabBar.width > 700
                    text: "click · wheel · ‹ ›"
                }
            }

            Row {
                id: tabRight
                anchors.right: tabBar.right
                anchors.rightMargin: 14
                anchors.verticalCenter: tabBar.verticalCenter
                spacing: 6
                Repeater {
                    model: [
                        {
                            t: "‹",
                            d: -1
                        },
                        {
                            t: "›",
                            d: 1
                        }
                    ]
                    delegate: Rectangle {
                        id: stepKey
                        required property var modelData
                        readonly property bool hov: stepMa.containsMouse
                        width: 26
                        height: 22
                        radius: Style.r.chip
                        border.width: 1
                        border.color: stepKey.hov ? Style.tone(root.cIce, 0.4) : Qt.rgba(0, 0, 0, 0.5)
                        color: stepKey.hov ? root.cInk2 : root.cRecess
                        Text {
                            anchors.centerIn: stepKey
                            anchors.verticalCenterOffset: -1
                            font.family: root.fMono
                            font.pixelSize: 11
                            color: stepKey.hov ? root.cTxt : root.cDim
                            text: stepKey.modelData.t
                        }
                        MouseArea {
                            id: stepMa
                            anchors.fill: stepKey
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.stepPage(stepKey.modelData.d)
                        }
                    }
                }
                Text {
                    anchors.verticalCenter: tabRight.verticalCenter
                    font.family: root.fMono
                    font.pixelSize: 9
                    font.letterSpacing: 1.6
                    color: root.cDim
                    text: " " + (root.viewTab + 1) + "/" + root.viewCount + " "
                }
                Rectangle {
                    anchors.verticalCenter: tabRight.verticalCenter
                    width: 1
                    height: 14
                    color: root.cEdge
                    visible: tabBar.width > 560
                }
                Text {
                    anchors.verticalCenter: tabRight.verticalCenter
                    font.family: root.fMono
                    font.pixelSize: 8
                    font.letterSpacing: 1.6
                    color: root.cFaint
                    visible: tabBar.width > 560
                    text: "REV " + Topology.statsRev
                }
            }
        }

        // ------------------------------ board ------------------------------
        Item {
            id: board
            width: wrap.width
            height: wrap.height - mast.height - tabBar.height - shelf.height - 3 * wrap.spacing
            clip: true
            visible: root.viewTab === 0

            // click empty board -> unpin
            MouseArea {
                anchors.fill: board
                onClicked: root.pinId = null
            }

            // wiring under-layer: one canvas, repainted on statsRev/lens/geo
            Canvas {
                id: links
                anchors.fill: board
                renderStrategy: Canvas.Cooperative
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.lineCap = "round";
                    for (var i = 0; i < root.wires.length; i++) {
                        var w = root.wires[i];
                        var g = root.wireEnds(w);
                        if (!g)
                            continue;
                        var fl = root.wireFlow(w);
                        var heat = root.lens === "heat";
                        var near = (root.hoverId === w.b || root.hoverId === w.a || root.pinId === w.b || root.pinId === w.a);
                        if (fl.hot)
                            ctx.strokeStyle = heat ? "rgba(255,179,0,0.30)" : "rgba(200,243,29,0.45)";
                        else if (fl.lit)
                            ctx.strokeStyle = heat ? "rgba(143,216,232,0.14)" : "rgba(143,216,232,0.30)";
                        else
                            ctx.strokeStyle = heat ? "rgba(143,216,232,0.10)" : "rgba(143,216,232,0.14)";
                        ctx.lineWidth = near ? 3 : 1.6;
                        var mx = (g.x0 + g.x1) / 2;
                        ctx.beginPath();
                        ctx.moveTo(g.x0, g.y0);
                        ctx.bezierCurveTo(mx, g.y0, mx, g.y1, g.x1, g.y1);
                        ctx.stroke();
                    }
                }
                Connections {
                    target: Topology
                    function onStatsRevChanged() {
                        if (root.boardActive)
                            links.requestPaint();
                    }
                    function onSchemaRevChanged() {
                        root.rebuildDesc();
                        if (root.boardActive)
                            links.requestPaint();
                    }
                    function onReadyChanged() {
                        if (Topology.ready)
                            root.rebuildDesc();
                    }
                }
                Connections {
                    target: root
                    function onLensChanged() {
                        links.requestPaint();
                    }
                    function onHoverIdChanged() {
                        links.requestPaint();
                    }
                    function onPinIdChanged() {
                        links.requestPaint();
                    }
                    function onBoxesRevChanged() {
                        links.requestPaint();
                    }
                    function onViewTabChanged() {
                        links.requestPaint();   // repaint missed frames on tab back
                    }
                }
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
            }

            // flow particles — bounded count, only while a flow is nonzero
            Repeater {
                model: root.wires
                delegate: WireDots {}
            }

            // CPU package (special composite node)
            PkgNode {
                spec: ({
                        ids: ["cpu_pkg0"],
                        x: 24,
                        y: 24,
                        w: 560,
                        role: "pkg",
                        nn: "AMD RYZEN 9 7900X · 12C/24T"
                    })
            }

            // generic node boxes
            Repeater {
                model: root.nodeSpecs
                delegate: BoardNode {}
            }

            // ---------------------- detail tray -----------------------------
            GlassPane {
                id: tray
                anchors.left: board.left
                anchors.right: board.right
                anchors.bottom: board.bottom
                anchors.margins: 10
                height: 108
                padding: 12
                holo: true
                visible: root.focusId !== null && root.trayM !== null
                opacity: 0
                NumberAnimation on opacity {
                    running: tray.visible
                    from: 0
                    to: 1
                    duration: Style.dur.snap
                    easing.type: Style.easing.standard
                }

                Row {
                    id: trayRow
                    anchors.fill: parent
                    spacing: 18
                    visible: root.trayM !== null

                    Column {
                        id: trayHead
                        width: 300
                        spacing: 3
                        anchors.top: trayRow.top
                        anchors.bottom: trayRow.bottom
                        Text {
                            width: trayHead.width
                            font.family: root.fDisp
                            font.pixelSize: 11
                            font.letterSpacing: 1.4
                            color: root.cTxt
                            elide: Text.ElideRight
                            text: root.trayM !== null ? root.trayM.title : ""
                        }
                        Row {
                            spacing: 8
                            Tag {
                                text: root.trayM !== null ? root.trayM.kind : ""
                                active: true
                            }
                            Rectangle {
                                width: stChip.implicitWidth + 14
                                height: 15
                                radius: 7
                                color: root.cRecess
                                border.color: root.trayM !== null && root.trayM.stateUp ? root.cAcc : root.cEdge
                                border.width: 1
                                Text {
                                    id: stChip
                                    anchors.centerIn: parent
                                    font.family: root.fMono
                                    font.pixelSize: 8
                                    font.letterSpacing: 1
                                    color: root.trayM !== null && root.trayM.stateUp ? root.cAcc : root.cUnk
                                    text: root.trayM !== null ? root.trayM.state : ""
                                }
                            }
                        }
                        Text {
                            width: trayHead.width
                            font.family: root.fMono
                            font.pixelSize: 8
                            color: root.cFaint
                            elide: Text.ElideRight
                            text: root.trayM !== null ? root.trayM.id + " · " + root.trayM.children + " children · uplink " + root.trayM.uplink : ""
                        }
                        Text {
                            width: trayHead.width
                            font.family: root.fMono
                            font.pixelSize: 8
                            color: root.cFaint
                            elide: Text.ElideRight
                            text: root.trayM !== null ? root.trayM.vitalSrc : ""
                        }
                    }

                    // vitals grid
                    Flow {
                        width: trayRow.width - trayHead.width - traySide.width - 2 * trayRow.spacing
                        anchors.top: trayRow.top
                        anchors.bottom: trayRow.bottom
                        spacing: 4
                        Repeater {
                            model: root.trayM !== null ? root.trayM.pairs.concat(root.trayM.xtra) : []
                            delegate: Text {
                                required property var modelData
                                width: Math.min(300, implicitWidth + 10)
                                font.family: root.fMono
                                font.pixelSize: 9
                                elide: Text.ElideRight
                                color: root.cDim
                                text: '<font color="#5a646c">' + modelData[0] + '</font> <font color="#8fd8e8">' + String(modelData[1]).replace(/</g, "&lt;") + '</font>'
                                textFormat: Text.RichText
                            }
                        }
                    }

                    Column {
                        id: traySide
                        width: 250
                        spacing: 3
                        anchors.top: trayRow.top
                        Text {
                            width: traySide.width
                            font.family: root.fMono
                            font.pixelSize: 8
                            color: root.cMute
                            text: root.trayM !== null && root.trayM.subs.length > 0 ? "ON THIS BOX" : ""
                        }
                        Repeater {
                            model: root.trayM !== null ? root.trayM.subs : []
                            delegate: Text {
                                required property var modelData
                                width: traySide.width
                                font.family: root.fMono
                                font.pixelSize: 8
                                color: root.cDim
                                elide: Text.ElideRight
                                text: modelData
                            }
                        }
                        Text {
                            width: traySide.width
                            font.family: root.fMono
                            font.pixelSize: 8
                            color: root.cFaint
                            visible: root.trayM !== null && root.trayM.subs.length === 0
                            text: "click node to pin · click board to clear"
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.pinId = null;
                        root.hoverId = null;
                    }
                }
            }
        }

        // ------------------------------ shelf -------------------------------
        Rectangle {
            id: shelf
            width: wrap.width
            height: 84
            radius: Style.r.pane
            color: root.cInk
            border.color: root.cEdge
            border.width: 1
            visible: root.viewTab === 0

            Row {
                anchors.fill: shelf
                anchors.margins: 12
                spacing: 14
                Repeater {
                    model: [
                        {
                            k: "ROOT BRIDGES",
                            v: root.bridgeSpecs()
                        },
                        {
                            k: "INTEL SWITCH",
                            v: "01:00.0 " + root.stOf(Topology.node("pci_01_00_0")) + " · 02:01.0 → B580 · 02:02.0 → hdmi audio"
                        },
                        {
                            k: "CHIPSET SWITCH",
                            v: "06:00.0 → 07:0a/0b/0c/0d → NICs · xHCI · SATA"
                        },
                        {
                            k: "FLOWS",
                            v: "usb " + root.usbLiveCount() + " devices live"
                        }
                    ]
                    delegate: Rectangle {
                        id: sl
                        required property var modelData
                        width: (shelf.width - 24 - 3 * 14) / 4
                        height: shelf.height - 24
                        radius: Style.r.emboss
                        border.width: 1
                        border.color: Qt.rgba(0, 0, 0, 0.5)
                        gradient: Gradient {
                            GradientStop {
                                position: 0.0
                                color: root.cRecessTop
                            }
                            GradientStop {
                                position: 1.0
                                color: root.cRecess
                            }
                        }
                        Column {
                            anchors.fill: sl
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.topMargin: 8
                            spacing: 4
                            Text {
                                font.family: root.fMono
                                font.pixelSize: 8
                                font.letterSpacing: 1.7
                                color: root.cMute
                                text: sl.modelData.k
                            }
                            Text {
                                width: parent.width
                                font.family: root.fMono
                                font.pixelSize: 10
                                color: root.cTxt
                                elide: Text.ElideRight
                                text: sl.modelData.v
                            }
                        }
                        // flows panel carries the particle pause switch
                        ActionToggle {
                            visible: sl.modelData.k === "FLOWS"
                            anchors.right: sl.right
                            anchors.rightMargin: 12
                            anchors.bottom: sl.bottom
                            anchors.bottomMargin: 8
                            label: "PAUSE"
                            tone: "ice"
                            on: root.flowsPaused
                            onToggled: root.flowsPaused = !root.flowsPaused
                        }
                    }
                }
            }
        }

        // ---------------------------- ops tab --------------------------------
        // lane B4: second view — live system feed. Same injected `stats` map;
        // `active` tells it when it owns the screen so its journal Process and
        // staleness watchdog only run while visible.
        OpsView {
            id: opsPage
            width: wrap.width
            height: wrap.height - mast.height - tabBar.height - 2 * wrap.spacing
            visible: root.viewTab === 1
            stats: root.stats
            screenName: root.screenName
            running: root.running
            active: root.running && root.viewTab === 1
        }
    }

    // scanlines over everything, painted once (mock .scan)
    ScanOverlay {
        anchors.fill: root
        lineAlpha: 0.09
    }

    // =========================== components ===============================
    // Generic board node: a kind-shaped KindGlyph silhouette plus a caption
    // column (name + vitals) beside it. pci_bridge nodes are `bare` — just
    // a crosspoint diamond, name shown in the detail tray only. The item's
    // rect still feeds wireEnds(), so wires attach to the glyph's zone.
    component BoardNode: Item {
        id: bn
        required property var modelData
        readonly property var spec: modelData
        readonly property string nid: spec.ids[0]
        readonly property var node: Topology.ready ? Topology.node(nid) : null
        readonly property string cls: root.clsOf(nid, node)
        readonly property var vit: root.vitalFor(nid)
        readonly property real heatK: {
            if (!node || root.isU(node.temp))
                return -1;
            var v = Number(node.temp);
            if (!isFinite(v))
                return -1;
            return Math.max(0, Math.min(1, (v - 40) / 50));
        }
        readonly property bool pinned: root.pinId === nid
        readonly property bool hovered: ma.containsMouse
        // folded siblings count too (nic_eth lights via net_eth's state)
        readonly property bool live: {
            Topology.statsRev;                          // re-eval per batch
            for (var i = 0; i < spec.ids.length; i++) {
                var n = Topology.node(spec.ids[i]);
                if (!n || root.isU(n.state))
                    continue;
                var s = String(n.state);
                if (s === "up" || s === "present" || s === "connected" || s === "mounted")
                    return true;
            }
            return false;
        }
        readonly property bool bare: cls === "pci_bridge"
        readonly property var gsz: root.glyphSize(nid, cls)
        readonly property string tag: root.classTag(cls)
        readonly property real padV: 5
        readonly property real padH: 7
        readonly property bool small: spec.role === "leaf" || spec.role === "bridge"

        x: root.sx(spec.x)
        y: root.sy(spec.y)
        width: bare ? gsz.w + 10 : root.sx(spec.w)
        height: bare ? gsz.h + 10 : Math.max(gsz.h + (tag !== "" ? 9 : 0) + 2 * padV, body.implicitHeight + 2 * padV)

        Component.onCompleted: root.registerBox(nid, bn)

        // heat lens: amber->red halo hugging the glyph, not a face plate
        Rectangle {
            x: glyph.x - 5
            y: glyph.y - 5
            width: glyph.width + 10
            height: glyph.height + 10
            radius: 10
            visible: root.lens === "heat" && bn.heatK >= 0
            color: Qt.rgba(1, (180 - 120 * bn.heatK) / 255, 0, 0.22 * bn.heatK)
        }

        KindGlyph {
            id: glyph
            x: bn.bare ? (bn.width - width) / 2 : bn.padH
            y: bn.bare ? (bn.height - height) / 2 : bn.padV
            width: bn.gsz.w
            height: bn.gsz.h
            cls: bn.cls
            nid: bn.nid
            node: bn.node
            live: bn.live
            focused: bn.hovered
            pinned: bn.pinned
            heatK: bn.heatK
            heatLens: root.lens === "heat"
        }
        // silkscreen class tag centred under the glyph
        Text {
            visible: bn.tag !== "" && !bn.bare
            x: bn.padH - 6
            anchors.top: glyph.bottom
            width: bn.gsz.w + 12
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fMono
            font.pixelSize: 7
            font.letterSpacing: 1.2
            color: root.cFaint
            text: bn.tag
        }

        // caption beside the shape: name, vital line, sub line
        Column {
            id: body
            visible: !bn.bare
            x: bn.padH + bn.gsz.w + 6
            y: bn.padV
            width: Math.max(16, bn.width - x - 2)
            spacing: bn.small ? 2 : 3
            Text {
                width: body.width
                font.family: root.fDisp
                font.pixelSize: 9
                font.letterSpacing: 1.3
                color: bn.cls === "display" ? root.cIce : root.cTxt
                elide: Text.ElideRight
                text: bn.spec.nn
            }
            Text {
                width: body.width
                font.family: root.fMono
                font.pixelSize: bn.small ? 9 : 10
                color: root.cDim
                elide: Text.ElideRight
                textFormat: Text.RichText
                text: bn.vit.nv
            }
            Text {
                width: body.width
                visible: text !== ""
                font.family: root.fMono
                font.pixelSize: 8
                color: root.cFaint
                elide: Text.ElideRight
                text: bn.vit.ns
            }
        }

        MouseArea {
            id: ma
            anchors.fill: bn
            hoverEnabled: true
            onEntered: root.hoverId = bn.nid
            onExited: if (root.hoverId === bn.nid)
                root.hoverId = null
            onClicked: root.pinId = (root.pinId === bn.nid ? null : bn.nid)
        }
    }

    // CPU package: title, vital line, CCD0/CCD1 recesses with core tiles.
    component PkgNode: Item {
        id: pkg
        required property var spec
        readonly property string nid: spec.ids[0]
        readonly property var node: Topology.ready ? Topology.node(nid) : null
        readonly property real heatK: {
            if (!node || root.isU(node.temp))
                return -1;
            var v = Number(node.temp);
            if (!isFinite(v))
                return -1;
            return Math.max(0, Math.min(1, (v - 40) / 50));
        }
        readonly property bool pinned: root.pinId === nid
        readonly property bool hovered: pma.containsMouse

        x: root.sx(spec.x)
        y: root.sy(spec.y)
        width: root.sx(spec.w)
        height: pbody.implicitHeight + 24

        Component.onCompleted: root.registerBox(nid, pkg)

        Rectangle {
            anchors.fill: pkg
            anchors.margins: -2
            radius: 9
            visible: root.lens === "heat" && pkg.heatK >= 0
            color: Qt.rgba(1, (180 - 120 * pkg.heatK) / 255, 0, 0.22 * pkg.heatK)
        }
        Rectangle {
            anchors.fill: pkg
            radius: Style.r.emboss
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(0, 0, 0, 0.55)
        }
        Rectangle {
            id: pface
            anchors.fill: pkg
            anchors.margins: 1
            radius: Style.r.emboss - 1
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: root.cInk2
                }
                GradientStop {
                    position: 1.0
                    color: root.cInk
                }
            }
            Rectangle {
                anchors.fill: pface
                radius: pface.radius
                visible: root.lens === "heat" && pkg.heatK >= 0
                color: Qt.rgba((22 + 46 * pkg.heatK) / 255, (26 - 6 * pkg.heatK) / 255, (32 - 18 * pkg.heatK) / 255, 1)
            }
            Rectangle {
                anchors.left: pface.left
                anchors.right: pface.right
                anchors.top: pface.top
                anchors.leftMargin: pface.radius
                anchors.rightMargin: pface.radius
                height: 1
                color: Qt.rgba(0.92, 0.96, 0.99, 0.20)
            }
        }
        // socket slab detailing (lane W3): substrate inset line, LGA pin
        // ticks on all four edges, notched alignment corner — painted once
        // per resize, the CCD recesses/core grid below stay live
        Canvas {
            id: pinframe
            anchors.fill: pkg
            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                if (width < 40 || height < 40)
                    return;
                ctx.lineWidth = 1;
                ctx.lineCap = "butt";
                ctx.strokeStyle = "rgba(143,216,232,0.16)";
                ctx.strokeRect(5.5, 5.5, width - 11, height - 11);
                ctx.strokeStyle = "rgba(202,168,90,0.45)";
                var px, py;
                for (px = 12; px < width - 10; px += 9) {
                    ctx.beginPath();
                    ctx.moveTo(px, 1.5);
                    ctx.lineTo(px, 4.5);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.moveTo(px, height - 4.5);
                    ctx.lineTo(px, height - 1.5);
                    ctx.stroke();
                }
                for (py = 12; py < height - 10; py += 9) {
                    ctx.beginPath();
                    ctx.moveTo(1.5, py);
                    ctx.lineTo(4.5, py);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.moveTo(width - 4.5, py);
                    ctx.lineTo(width - 1.5, py);
                    ctx.stroke();
                }
                // notched corner: dark chamfer + gold alignment triangle
                ctx.fillStyle = "#0b0e11";
                ctx.beginPath();
                ctx.moveTo(0, 0);
                ctx.lineTo(17, 0);
                ctx.lineTo(0, 17);
                ctx.closePath();
                ctx.fill();
                ctx.strokeStyle = "rgba(202,168,90,0.9)";
                ctx.beginPath();
                ctx.moveTo(4, 10);
                ctx.lineTo(10, 4);
                ctx.stroke();
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
        }
        Rectangle {
            anchors.fill: pkg
            radius: Style.r.emboss
            color: "transparent"
            border.width: 1
            border.color: pkg.pinned ? root.cAcc : root.cIce
            opacity: pkg.pinned ? 0.85 : (pkg.hovered ? 0.35 : 0)
            Behavior on opacity {
                NumberAnimation {
                    duration: Style.dur.snap
                    easing.type: Style.easing.standard
                }
            }
        }
        // package-level hover/click sits below the CCD tiles' own areas
        MouseArea {
            id: pma
            anchors.fill: pkg
            hoverEnabled: true
            onEntered: root.hoverId = "cpu_pkg0"
            onExited: if (root.hoverId === "cpu_pkg0")
                root.hoverId = null
            onClicked: root.pinId = (root.pinId === "cpu_pkg0" ? null : "cpu_pkg0")
        }

        Column {
            id: pbody
            x: 14
            y: 12
            width: pkg.width - 28
            spacing: 3
            Text {
                width: pbody.width
                font.family: root.fDisp
                font.pixelSize: 11
                font.letterSpacing: 2.2
                color: root.cTxt
                elide: Text.ElideRight
                text: pkg.spec.nn
            }
            Text {
                width: pbody.width
                font.family: root.fMono
                font.pixelSize: 11
                color: root.cDim
                elide: Text.ElideRight
                textFormat: Text.RichText
                text: "Tctl " + root.vB(root.tS(pkg.node ? pkg.node.temp : Topology.unknown)) + " · " + (root.isU(root.sn("cpu_mhz_avg")) ? root.dash : Math.round(Number(root.sn("cpu_mhz_avg")))) + " MHz avg" + " · load1 " + root.ss("load1") + " · PSI cpu " + root.ss("psi_cpu_some")
            }
            Row {
                id: ccdrow
                width: pbody.width
                spacing: 10
                Repeater {
                    model: 2
                    delegate: Rectangle {
                        id: ccd
                        required property int index
                        readonly property var ccdNode: Topology.ready ? Topology.node("ccd" + ccd.index) : null
                        width: (ccdrow.width - ccdrow.spacing) / 2
                        height: ccdCol.implicitHeight + 14
                        radius: Style.r.emboss
                        border.width: 1
                        border.color: Qt.rgba(0, 0, 0, 0.5)
                        gradient: Gradient {
                            GradientStop {
                                position: 0.0
                                color: root.cRecessTop
                            }
                            GradientStop {
                                position: 1.0
                                color: root.cRecess
                            }
                        }
                        // ccd-level area sits below the core tiles' own areas
                        MouseArea {
                            anchors.fill: ccd
                            hoverEnabled: true
                            onEntered: root.hoverId = "ccd" + ccd.index
                            onExited: if (root.hoverId === "ccd" + ccd.index)
                                root.hoverId = null
                            onClicked: root.pinId = (root.pinId === "ccd" + ccd.index ? null : "ccd" + ccd.index)
                        }
                        Column {
                            id: ccdCol
                            x: 9
                            y: 7
                            width: ccd.width - 18
                            spacing: 6
                            Text {
                                width: ccdCol.width
                                font.family: root.fMono
                                font.pixelSize: 8
                                font.letterSpacing: 1.0
                                color: root.cMute
                                elide: Text.ElideRight
                                textFormat: Text.RichText
                                text: "CCD" + ccd.index + " · Tccd" + (ccd.index + 1) + " " + root.vW(root.tS(ccd.ccdNode ? ccd.ccdNode.temp : Topology.unknown)) + " · cpu" + (ccd.index === 0 ? "0-5 / 12-17" : "6-11 / 18-23")
                            }
                            Grid {
                                width: ccdCol.width
                                columns: 6
                                columnSpacing: 8
                                rowSpacing: 6
                                Repeater {
                                    model: 6
                                    delegate: CoreTile {
                                        coreIdx: ccd.index * 6 + index
                                        width: (ccdCol.width - 5 * 8) / 6
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // One core tile: two per-thread % bars + caption + core MHz.
    component CoreTile: Item {
        id: tile
        required property int index
        required property int coreIdx
        readonly property real coreLoadPct: {
            var v = root.sn("cpu_core_" + tile.coreIdx);
            if (!root.isU(v))
                return v;
            var n = Topology.node("core" + tile.coreIdx);
            return (n && !root.isU(n.load)) ? Number(n.load) : -1;
        }
        readonly property real sibLoadPct: {
            var v = root.sn("cpu_core_" + (tile.coreIdx + 12));
            return root.isU(v) ? -1 : v;
        }
        readonly property var coreNode: Topology.ready ? Topology.node("core" + tile.coreIdx) : null
        height: thRow.height + cl.implicitHeight + mhzT.implicitHeight + 5

        Row {
            id: thRow
            width: tile.width
            height: 22
            spacing: 2
            Repeater {
                model: 2
                delegate: Rectangle {
                    id: bar
                    required property int index
                    readonly property real pct: index === 0 ? tile.coreLoadPct : tile.sibLoadPct
                    width: (thRow.width - 2) / 2
                    height: 22
                    radius: 1
                    gradient: Gradient {
                        GradientStop {
                            position: 0.0
                            color: "#232830"
                        }
                        GradientStop {
                            position: 1.0
                            color: "#14171c"
                        }
                    }
                    Rectangle {
                        anchors.left: bar.left
                        anchors.right: bar.right
                        anchors.bottom: bar.bottom
                        height: bar.pct < 0 ? 0 : Math.max(1, bar.height * Math.min(100, bar.pct) / 100)
                        radius: 1
                        gradient: Gradient {
                            GradientStop {
                                position: 0.0
                                color: root.cAcc
                            }
                            GradientStop {
                                position: 1.0
                                color: root.cIce
                            }
                        }
                    }
                    Text {
                        anchors.centerIn: bar
                        visible: bar.pct < 0
                        font.family: root.fMono
                        font.pixelSize: 7
                        color: root.cUnk
                        text: "?"
                    }
                }
            }
        }
        Text {
            id: cl
            y: thRow.height + 2
            width: tile.width
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fMono
            font.pixelSize: 7
            font.letterSpacing: 0.3
            color: root.cFaint
            text: "c" + tile.coreIdx + "·" + (tile.coreIdx + 12)
        }
        Text {
            id: mhzT
            y: thRow.height + 2 + cl.implicitHeight + 1
            width: tile.width
            horizontalAlignment: Text.AlignHCenter
            font.family: root.fMono
            font.pixelSize: 7
            color: root.cIce
            text: tile.coreNode && !root.isU(tile.coreNode.extra.mhz) ? String(Math.round(Number(tile.coreNode.extra.mhz))) : root.dash
        }
        MouseArea {
            anchors.fill: tile
            hoverEnabled: true
            onEntered: root.hoverId = "core" + tile.coreIdx
            onExited: if (root.hoverId === "core" + tile.coreIdx)
                root.hoverId = null
            onClicked: root.pinId = (root.pinId === "core" + tile.coreIdx ? null : "core" + tile.coreIdx)
        }
    }

    // kind -> silhouette painter. One small Canvas per node; repaints only
    // when a painted input changes (stats batch / lens / focus), never on a
    // clock. All geometry is parametric in the glyph's w×h box.
    component KindGlyph: Canvas {
        id: kg
        property string cls: "chip"
        property string nid: ""
        property var node: null
        property bool live: false
        property bool focused: false
        property bool pinned: false
        property real heatK: -1
        property bool heatLens: false

        antialiasing: true

        onClsChanged: requestPaint()
        onNidChanged: requestPaint()
        onNodeChanged: requestPaint()
        onLiveChanged: requestPaint()
        onFocusedChanged: requestPaint()
        onPinnedChanged: requestPaint()
        onHeatKChanged: requestPaint()
        onHeatLensChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: Topology
            function onStatsRevChanged() {
                kg.requestPaint();
            }
        }

        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var w = width, h = height, cx = w / 2, cy = h / 2;
            var hot = heatLens && heatK >= 0;
            var hk = Math.max(0, heatK);
            var ice = hot ? "rgba(255," + Math.round(179 - 105 * hk) + "," + Math.round(61 * hk) + ",0.85)" : "rgba(143,216,232,0.62)";
            var dim = "rgba(143,216,232,0.28)";
            var acc = hot ? "rgba(255," + Math.round(160 - 60 * hk) + ",0,0.9)" : "rgba(200,243,29,0.8)";
            var fill = "rgba(20,23,28,0.92)";
            var recess = "rgba(9,11,14,0.95)";
            var gold = hot ? "rgba(255,170,40,0.85)" : "rgba(202,168,90,0.80)";
            var t = (node && !root.isU(node.temp)) ? Number(node.temp) : -1;
            ctx.lineWidth = 1;
            ctx.lineJoin = "round";
            ctx.lineCap = "round";

            function rr(x, y, rw, rh, r) {
                ctx.beginPath();
                ctx.moveTo(x + r, y);
                ctx.arcTo(x + rw, y, x + rw, y + rh, r);
                ctx.arcTo(x + rw, y + rh, x, y + rh, r);
                ctx.arcTo(x, y + rh, x, y, r);
                ctx.arcTo(x, y, x + rw, y, r);
                ctx.closePath();
            }
            function circ(x, y, r) {
                ctx.beginPath();
                ctx.arc(x, y, r, 0, 6.2832);
            }
            function seg(x1, y1, x2, y2) {
                ctx.beginPath();
                ctx.moveTo(x1, y1);
                ctx.lineTo(x2, y2);
                ctx.stroke();
            }

            switch (cls) {
            case "data_fabric":
                {   // fabric mesh: cross-hatched slab + lit switch points
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(1.5, 3.5, w - 3, h - 7, 2);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    for (var vx = 8; vx < w - 4; vx += 8)
                        seg(vx, 4.5, vx, h - 4.5);
                    for (var vy = 9.5; vy < h - 5; vy += 7)
                        seg(2.5, vy, w - 2.5, vy);
                    if (live) {
                        ctx.fillStyle = acc;
                        circ(cx - 4, cy - 3.5, 1.6);
                        ctx.fill();
                        circ(cx + 5, cy + 4, 1.6);
                        ctx.fill();
                    }
                    break;
                }
            case "memory":
                {   // DIMM bank: two sticks, chip flecks, shared pin row
                    for (var s = 0; s < 2; s++) {
                        var mx = 3 + s * 19;
                        ctx.strokeStyle = ice;
                        ctx.fillStyle = fill;
                        rr(mx, 1, 13, h - 8, 1.5);
                        ctx.fill();
                        ctx.stroke();
                        ctx.fillStyle = "rgba(143,216,232,0.10)";
                        for (var cf = 0; cf < 4; cf++)
                            ctx.fillRect(mx + 2 + cf * 3, 6, 2, h - 18);
                        ctx.strokeStyle = gold;
                        for (var mp = mx + 1.5; mp < mx + 12; mp += 2.2)
                            seg(mp, h - 6.5, mp, h - 3);
                    }
                    break;
                }
            case "dimm":
                {   // tall stick: body, rank chips, notched contact edge,
                    // temperature stripe on the right flank
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(3, 0.5, w - 6, h - 5, 1.5);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = "rgba(143,216,232,0.10)";
                    for (var r2 = 0; r2 < 4; r2++)
                        ctx.fillRect(5, 3 + r2 * 6, w - 10, 4);
                    ctx.strokeStyle = gold;
                    var notchX = 3 + (w - 6) * 0.62;       // DDR5 off-centre key
                    for (var px = 4; px < w - 4; px += 2) {
                        if (px > notchX && px < notchX + 3)
                            continue;
                        seg(px, h - 5, px, h - 1.5);
                    }
                    if (t >= 0) {
                        ctx.strokeStyle = root.tempStroke(t);
                        ctx.lineWidth = 2;
                        seg(w - 4.5, 4, w - 4.5, h - 8);
                        ctx.lineWidth = 1;
                    }
                    break;
                }
            case "pci_root":
                {   // root complex: fat diamond + inner ring + fan-out prongs
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    ctx.beginPath();
                    ctx.moveTo(cx, 1);
                    ctx.lineTo(w - 6, cy - 2);
                    ctx.lineTo(cx, h - 9);
                    ctx.lineTo(6, cy - 2);
                    ctx.closePath();
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    ctx.beginPath();
                    ctx.moveTo(cx, 5);
                    ctx.lineTo(w - 11, cy - 2);
                    ctx.lineTo(cx, h - 13);
                    ctx.lineTo(11, cy - 2);
                    ctx.closePath();
                    ctx.stroke();
                    ctx.strokeStyle = live ? acc : dim;
                    seg(cx - 7, h - 7, cx - 7, h - 1);
                    seg(cx, h - 7, cx, h - 1);
                    seg(cx + 7, h - 7, cx + 7, h - 1);
                    ctx.fillStyle = live ? acc : dim;
                    circ(cx, cy - 2, 2);
                    ctx.fill();
                    break;
                }
            case "pci_bridge":
                {   // bare crosspoint diamond — label lives in the tray
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    ctx.beginPath();
                    ctx.moveTo(cx, 1.5);
                    ctx.lineTo(w - 1.5, cy);
                    ctx.lineTo(cx, h - 1.5);
                    ctx.lineTo(1.5, cy);
                    ctx.closePath();
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    seg(cx - 4, cy - 4, cx + 4, cy + 4);
                    seg(cx - 4, cy + 4, cx + 4, cy - 4);
                    if (live) {
                        ctx.fillStyle = acc;
                        circ(cx, cy, 1.8);
                        ctx.fill();
                    }
                    break;
                }
            case "gpu":
                {   // card profile: slot bracket, shroud, PCIe fingers,
                    // fan rings where RPM exists (B580=2, iGPU=die square)
                    var hasFan = nid === "gpu_arc" || (node && node.extra && !root.isU(node.extra.fan_rpm));
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = "rgba(40,46,54,0.9)";
                    ctx.fillRect(0.5, 1, 3, h - 2);
                    ctx.strokeRect(0.5, 1, 3, h - 2);
                    ctx.fillStyle = recess;
                    ctx.fillRect(1.5, 4, 1, 2);
                    ctx.fillRect(1.5, h - 7, 1, 2);
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(5, 3.5, w - 7, h - 9, 2);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = gold;
                    var fend = 7 + (w - 12) * 0.55;
                    for (var fx = 9; fx < Math.min(w - 4, fend); fx += 2.4)
                        seg(fx, h - 5.5, fx, h - 2.5);
                    var by = 3.5 + (h - 9) / 2;            // shroud centreline
                    if (hasFan) {
                        var fans = w >= 60 ? 2 : 1;
                        var fr = Math.min(6.4, (h - 10) / 2);
                        for (var fi = 0; fi < fans; fi++) {
                            var fx0 = fans === 2 ? w * 0.34 + fi * w * 0.36 : cx + 2;
                            ctx.strokeStyle = dim;
                            circ(fx0, by, fr);
                            ctx.stroke();
                            ctx.strokeStyle = ice;
                            circ(fx0, by, 1.4);
                            ctx.stroke();
                            for (var b3 = 0; b3 < 3; b3++) {
                                var an = b3 * 2.094 + 0.5;
                                seg(fx0, by, fx0 + (fr - 1.5) * Math.cos(an), by + (fr - 1.5) * Math.sin(an));
                            }
                        }
                        if (w >= 60) {                     // power plug nub
                            ctx.fillStyle = fill;
                            ctx.strokeStyle = ice;
                            ctx.fillRect(w - 11, 0.5, 8, 3);
                            ctx.strokeRect(w - 11, 0.5, 8, 3);
                        }
                    } else {                               // iGPU: bare die
                        ctx.strokeStyle = ice;
                        ctx.fillStyle = recess;
                        rr(cx - 3, by - 3.5, 9, 7, 1);
                        ctx.fill();
                        ctx.stroke();
                        ctx.fillStyle = dim;
                        circ(8, 6, 1);
                        ctx.fill();
                        circ(w - 3, 6, 1);
                        ctx.fill();
                        circ(8, h - 5, 1);
                        ctx.fill();
                        circ(w - 3, h - 5, 1);
                        ctx.fill();
                    }
                    break;
                }
            case "nvme":
                {   // M.2 stick: keyed gold fingers, controller + NAND
                    // blocks, mount hole, temp bar under the body
                    ctx.strokeStyle = gold;
                    for (var nx = 1; nx < 9; nx += 2) {
                        if (nx >= 4 && nx < 6)
                            continue;                    // M-key notch
                        seg(nx, 3, nx, h - 4);
                    }
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(9, 2, w - 13, h - 5, 1.5);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = recess;
                    ctx.strokeStyle = dim;
                    rr(12, 4.5, 6, h - 10, 1);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillRect(21, 4.5, 9, h - 10);
                    ctx.strokeRect(21, 4.5, 9, h - 10);
                    circ(w - 4.5, 2 + (h - 5) / 2, 1.8);
                    ctx.stroke();
                    if (t >= 0) {
                        ctx.strokeStyle = root.tempStroke(t);
                        ctx.lineWidth = 1.6;
                        seg(10, h - 1.5, w - 3, h - 1.5);
                        ctx.lineWidth = 1;
                    }
                    break;
                }
            case "xhci":
                {   // host controller: chip + pin stubs over a USB-A port
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(3, 1, w - 6, 11, 1.5);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    for (var xp = 6; xp < w - 5; xp += 4)
                        seg(xp, 0, xp, 1);
                    ctx.strokeStyle = live ? acc : ice;
                    ctx.fillStyle = recess;
                    rr(2, 14, w - 4, h - 15, 1);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    seg(4, 14 + (h - 15) / 2, w - 6, 14 + (h - 15) / 2);
                    break;
                }
            case "sata":
                {   // flat L connector with contact ticks
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    ctx.beginPath();
                    ctx.moveTo(1.5, 2.5);
                    ctx.lineTo(7.5, 2.5);
                    ctx.lineTo(7.5, h - 6.5);
                    ctx.lineTo(w - 1.5, h - 6.5);
                    ctx.lineTo(w - 1.5, h - 1.5);
                    ctx.lineTo(1.5, h - 1.5);
                    ctx.closePath();
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = gold;
                    for (var sx2 = 10; sx2 < w - 3; sx2 += 2.4)
                        seg(sx2, h - 5, sx2, h - 3);
                    break;
                }
            case "audio_pci":
                {   // jack ring + bore, waves radiating right when routed
                    var jx = 9, jy = cy, jr = Math.min(7.5, h / 2 - 1.5);
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    circ(jx, jy, jr);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = recess;
                    circ(jx, jy, jr * 0.42);
                    ctx.fill();
                    ctx.strokeStyle = live ? acc : dim;
                    ctx.beginPath();
                    ctx.arc(jx, jy, jr + 3.5, -0.9, 0.9);
                    ctx.stroke();
                    ctx.beginPath();
                    ctx.arc(jx, jy, jr + 6.5, -0.7, 0.7);
                    ctx.stroke();
                    break;
                }
            case "pw_sink":
            case "pw_source":
                {   // PipeWire endpoint: port disc + waves; sources send
                    // waves leftwards, sinks rightwards
                    var src = cls === "pw_source";
                    var pr = Math.min(6.5, h / 2 - 3);
                    var pxc = src ? w - 8 : 8;
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    circ(pxc, cy, pr);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = live ? acc : dim;
                    circ(pxc, cy, 1.6);
                    ctx.fill();
                    ctx.strokeStyle = live ? acc : dim;
                    for (var wv = 0; wv < 2; wv++) {
                        ctx.beginPath();
                        if (src)
                            ctx.arc(pxc, cy, pr + 3 + wv * 3, Math.PI - 0.8, Math.PI + 0.8);
                        else
                            ctx.arc(pxc, cy, pr + 3 + wv * 3, -0.8, 0.8);
                        ctx.stroke();
                    }
                    break;
                }
            case "nic":
                {
                    if (nid === "nic_wifi") {              // radio NIC: stub
                        ctx.strokeStyle = ice;             // antenna + arcs
                        ctx.fillStyle = fill;
                        rr(2, h - 9, w - 4, 7, 1.5);
                        ctx.fill();
                        ctx.stroke();
                        seg(cx, h - 9, cx, 6);
                        ctx.strokeStyle = live ? acc : dim;
                        ctx.beginPath();
                        ctx.arc(cx, 7, 4, -2.4, -0.75);
                        ctx.stroke();
                        ctx.beginPath();
                        ctx.arc(cx, 7, 7.5, -2.4, -0.75);
                        ctx.stroke();
                        ctx.fillStyle = live ? acc : dim;
                        circ(cx, 6, 1.4);
                        ctx.fill();
                    } else {                               // RJ45 port
                        ctx.strokeStyle = ice;
                        ctx.fillStyle = fill;
                        ctx.beginPath();
                        ctx.moveTo(2, 4);
                        ctx.lineTo(w - 2, 4);
                        ctx.lineTo(w - 2, h - 2);
                        ctx.lineTo(2, h - 2);
                        ctx.closePath();
                        ctx.fill();
                        ctx.stroke();
                        ctx.strokeStyle = dim;             // clip recess
                        seg(cx - 3, 4, cx - 3, 6.5);
                        seg(cx + 3, 4, cx + 3, 6.5);
                        seg(cx - 3, 6.5, cx + 3, 6.5);
                        ctx.strokeStyle = gold;            // contacts
                        for (var np = 5; np <= w - 6; np += 3.2)
                            seg(np, 4.5, np, 8);
                        ctx.fillStyle = live ? acc : "rgba(90,100,108,0.8)";
                        circ(5.5, h - 5, 1.5);
                        ctx.fill();
                        ctx.fillStyle = "rgba(143,216,232," + (live ? "0.7)" : "0.25)");
                        circ(w - 5.5, h - 5, 1.5);
                        ctx.fill();
                    }
                    break;
                }
            case "display":
                {   // little screen: lit panel + stand
                    ctx.strokeStyle = ice;
                    var g2 = ctx.createLinearGradient(0, 1, 0, h - 7);
                    g2.addColorStop(0, live ? "rgba(143,216,232,0.22)" : "rgba(143,216,232,0.10)");
                    g2.addColorStop(1, "rgba(20,23,28,0.9)");
                    ctx.fillStyle = g2;
                    rr(1, 1, w - 2, h - 8, 1.5);
                    ctx.fill();
                    ctx.stroke();
                    if (live) {
                        ctx.strokeStyle = "rgba(200,243,29,0.55)";
                        seg(3, 2.8, w - 3, 2.8);
                    }
                    ctx.strokeStyle = ice;
                    seg(cx, h - 7, cx, h - 3.5);
                    seg(cx - 5, h - 2.5, cx + 5, h - 2.5);
                    break;
                }
            case "usb_roothub":
                {   // root hub: spoked ring + core square
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    circ(cx, cy, 7);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    seg(cx - 11, cy, cx - 7, cy);
                    seg(cx + 7, cy, cx + 11, cy);
                    seg(cx, cy - 11, cx, cy - 7);
                    seg(cx, cy + 7, cx, cy + 11);
                    ctx.strokeStyle = live ? acc : ice;
                    ctx.strokeRect(cx - 2, cy - 2, 4, 4);
                    break;
                }
            case "usb_hub":
                {   // hub: ring + uplink stub + three downstream ports
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    circ(cx, cy - 1, 6.5);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    seg(cx, 0.5, cx, cy - 7.5);
                    ctx.fillStyle = live ? acc : dim;
                    circ(cx - 5, cy + 6.5, 1.6);
                    ctx.fill();
                    circ(cx, cy + 7.5, 1.6);
                    ctx.fill();
                    circ(cx + 5, cy + 6.5, 1.6);
                    ctx.fill();
                    break;
                }
            case "usb_storage":
                {   // flash stick: metal plug + body + activity dot
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = "rgba(202,168,90,0.5)";
                    rr(3.5, 0.5, w - 7, 6, 1);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    seg(6, 2.5, w - 6, 2.5);
                    seg(6, 4.5, w - 6, 4.5);
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(1.5, 7, w - 3, h - 8, 2);
                    ctx.fill();
                    ctx.stroke();
                    if (live) {
                        ctx.fillStyle = acc;
                        circ(cx, h - 4, 1.5);
                        ctx.fill();
                    }
                    break;
                }
            case "usb_receiver":
            case "usb_rgb":
            case "usb_bluetooth":
                {   // nano dongles: plug tip + body + per-class inset
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = "rgba(202,168,90,0.5)";
                    rr(4, 0.5, w - 8, 4, 0.8);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(1.5, 5, w - 3, h - 6, 3);
                    ctx.fill();
                    ctx.stroke();
                    if (cls === "usb_receiver") {
                        ctx.strokeStyle = dim;
                        seg(cx, h - 6, cx, h - 11);
                        ctx.fillStyle = live ? acc : dim;
                        circ(cx, h - 6, 1.6);
                        ctx.fill();
                    } else if (cls === "usb_rgb") {
                        var cols = ["#c8f31d", "#ff7ad9", "#8fd8e8"];
                        for (var ri = 0; ri < 3; ri++) {
                            ctx.fillStyle = cols[ri];
                            ctx.fillRect(3.5 + ri * 3, cy, 2, 4);
                        }
                    } else {
                        ctx.strokeStyle = live ? acc : ice;
                        seg(cx, cy - 6, cx, cy + 6);       // bind-rune stem
                        seg(cx, cy - 6, cx + 4, cy - 2.5);
                        seg(cx + 4, cy - 2.5, cx, cy + 0.5);
                        seg(cx, cy + 0.5, cx + 4, cy + 3);
                        seg(cx + 4, cy + 3, cx, cy + 6);
                    }
                    break;
                }
            case "usb_camera":
                {   // webcam dongle: plug + body + lens
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = "rgba(202,168,90,0.5)";
                    rr(0.5, cy - 2.5, 4, 5, 1);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(5, 1.5, w - 6, h - 3, 3);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = recess;
                    ctx.strokeStyle = live ? acc : dim;
                    circ(w - 8, cy, 3.2);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = live ? acc : dim;
                    circ(w - 8, cy, 1);
                    ctx.fill();
                    break;
                }
            case "usb_keyboard":
                {   // low-profile slab with key grid
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(1, 2, w - 2, h - 4, 1.5);
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = dim;
                    for (var kr = 0; kr < 2; kr++)
                        for (var kc = 0; kc < 8; kc++)
                            ctx.fillRect(4 + kc * 3, 4 + kr * 3.4, 2, 2);
                    break;
                }
            case "smbus":
                {   // i2c chip: pins left, SDA/SCL lines out right
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(3, 2, 14, h - 4, 1.5);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    for (var sp = 4; sp < h - 3; sp += 4)
                        seg(0.5, sp, 3, sp);
                    ctx.strokeStyle = live ? acc : ice;
                    seg(17, 6, w - 1, 6);
                    seg(17, h - 6, w - 1, h - 6);
                    ctx.fillStyle = live ? acc : dim;
                    circ(w - 2, 6, 1.2);
                    ctx.fill();
                    circ(w - 2, h - 6, 1.2);
                    ctx.fill();
                    break;
                }
            case "crypto":
                {   // PSP/CCP: shield plate + keyhole
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    ctx.beginPath();
                    ctx.moveTo(3, 4);
                    ctx.lineTo(w - 3, 4);
                    ctx.lineTo(w - 3, h - 8);
                    ctx.lineTo(cx, h - 2);
                    ctx.lineTo(3, h - 8);
                    ctx.closePath();
                    ctx.fill();
                    ctx.stroke();
                    ctx.fillStyle = recess;
                    ctx.strokeStyle = dim;
                    circ(cx, cy - 1, 2.6);
                    ctx.fill();
                    ctx.stroke();
                    seg(cx, cy + 1, cx, cy + 4.5);
                    break;
                }
            case "bluetooth":
                {   // hci controller: bind-rune + presence arc
                    ctx.strokeStyle = live ? acc : ice;
                    seg(cx, 3, cx, h - 3);
                    seg(cx, 3, cx + 5, 7.5);
                    seg(cx + 5, 7.5, cx, 12);
                    seg(cx, 12, cx + 5, 16.5);
                    seg(cx + 5, 16.5, cx, h - 3);
                    ctx.strokeStyle = dim;
                    ctx.beginPath();
                    ctx.arc(cx + 1, cy, 8.5, -0.9, 0.9);
                    ctx.stroke();
                    break;
                }
            default:
                {   // generic chip: stubbed square + live die dot
                    ctx.strokeStyle = ice;
                    ctx.fillStyle = fill;
                    rr(2, 2, w - 4, h - 4, 1.5);
                    ctx.fill();
                    ctx.stroke();
                    ctx.strokeStyle = dim;
                    for (var cp = 4; cp < w - 3; cp += 4) {
                        seg(cp, 0, cp, 2);
                        seg(cp, h - 2, cp, h);
                    }
                    for (var cp2 = 4; cp2 < h - 3; cp2 += 4) {
                        seg(0, cp2, 2, cp2);
                        seg(w - 2, cp2, w, cp2);
                    }
                    if (live) {
                        ctx.fillStyle = acc;
                        circ(cx, cy, 1.6);
                        ctx.fill();
                    }
                    break;
                }
            }

            // hover/pin rim: diamond-aware, matches the old rim intent
            if (focused || pinned) {
                ctx.strokeStyle = pinned ? "rgba(200,243,29,0.85)" : "rgba(143,216,232,0.40)";
                ctx.lineWidth = 1;
                if (cls === "pci_bridge" || cls === "pci_root") {
                    ctx.beginPath();
                    ctx.moveTo(cx, 0.5);
                    ctx.lineTo(w - 0.5, cy);
                    ctx.lineTo(cx, h - 0.5);
                    ctx.lineTo(0.5, cy);
                    ctx.closePath();
                    ctx.stroke();
                } else {
                    ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
                }
            }
        }
    }

    // Per-wire particle layer. Dots exist only while a direction is flowing:
    // rx moves toward the machine-side end, tx toward the leaf end, and
    // unitless activity (%, MHz, W) collapses to a single inbound dot.
    component WireDots: Item {
        id: wd
        required property var modelData
        readonly property var spec: modelData
        readonly property var geo: root.wireEnds(spec)
        readonly property var fl: root.wireFlow(spec)
        // phase from the shared coarse flow clock (root.flowMs): the old pair of
        // Animation.Infinite per wire ran every wire at the display rate
        readonly property real _tIn: (root.flowMs / Math.max(600, wd.fl.inDur)) % 1
        readonly property real _tOut: (root.flowMs / Math.max(600, wd.fl.outDur)) % 1
        visible: fl.on && geo !== null && root.boardActive

        // inbound (leaf -> machine): t runs toward the `up` end
        Repeater {
            model: wd.fl.inOn ? (wd.fl.actOnly ? 1 : 2) : 0
            delegate: Rectangle {
                id: dotIn
                required property int index
                readonly property int count: wd.fl.actOnly ? 1 : 2
                width: 6
                height: 6
                radius: 3
                color: root.lens === "heat" ? root.cWarn : root.cAcc
                readonly property real tt: (wd._tIn + index * (1.0 / count)) % 1
                readonly property point pt: {
                    var g = wd.geo;
                    if (!g)
                        return Qt.point(-20, -20);
                    var p = root.bezP(g, wd.spec.up === "b" ? tt : 1 - tt);
                    return Qt.point(p.x - 3, p.y - 3);
                }
                x: pt.x
                y: pt.y
            }
        }
        // outbound (machine -> leaf): tx bytes only
        Repeater {
            model: wd.fl.outOn ? 2 : 0
            delegate: Rectangle {
                id: dotOut
                required property int index
                width: 5
                height: 5
                radius: 2.5
                color: root.lens === "heat" ? root.cWarn : root.cAcc
                readonly property real tt: (wd._tOut + index * 0.5) % 1
                readonly property point pt: {
                    var g = wd.geo;
                    if (!g)
                        return Qt.point(-20, -20);
                    var p = root.bezP(g, wd.spec.up === "b" ? 1 - tt : tt);
                    return Qt.point(p.x - 2.5, p.y - 2.5);
                }
                x: pt.x
                y: pt.y
            }
        }
    }

    // Shared particle clock: one ~11 fps counter for every wire instead of two
    // 60 fps animations per active wire. Stops entirely off the board tab.
    property double flowMs: 0
    property bool flowsPaused: false
    Timer {
        interval: 90
        repeat: true
        running: root.boardActive && !root.flowsPaused
        onTriggered: root.flowMs += 90
    }

    Component.onCompleted: {
        markPage(viewTab);
        rebuildDesc();
    }
}
