pragma Singleton
// Lane T — device domain model (contract: BRIEF-V4-BUILD.md "Topology singleton").
// Static scaffold comes from recon/devices-bus.json via FileView; a verbatim
// embedded copy covers deployments where the recon/ tree is not installed.
// Vitals merge order: dev_* keys first, then legacy stats keys. Any absent
// vital stays the `unknown` sentinel — never 0, never fabricated.
// No timers/clocks: refresh(stats) is driven by the collector batch.

import QtQml
import Quickshell.Io

QtObject {
    id: topo

    // ---------------- contract surface ----------------
    // Unique sentinel object. Compare with === or isUnknown(). Never a number,
    // never "" — so views cannot accidentally render it as telemetry.
    readonly property var unknown: ({ "__nxUnknown": true })
    readonly property string unknownGlyph: "—"

    property var nodes: ({})     // id -> {id,kind,label,temp,load,power,link,state,extra}
    property var edges: []       // [{a,b,kind,bw,active,rate,unit,flow}]
    property var flows: ({})     // flowId -> bytes/s (byte-rate sources only)
    property var parts: ({})     // dynamic kind:"part" records from blk{i}p{j}_* keys
    property var nodeList: []    // `nodes` values in scaffold (tree) order
    property var flowRates: ({}) // flowId -> {a,b,rx,tx,rate,unit,active,src}

    readonly property int scaffoldCount: 78
    property int nodeCount: 0    // count of `nodes` — equals 78 once built
    property int partCount: 0
    property int edgeCount: 0
    property int statsRev: 0     // bumps every refresh(); the view binding tick
    property int schemaRev: 0    // bumps when scaffold/part membership changes
    property bool ready: false
    property string scaffoldSource: "pending"

    // ---------------- generic helpers ----------------
    function isUnknown(v) { return v === unknown || v === undefined || v === null }
    function has(s, k) { return s[k] !== undefined && s[k] !== "" }
    function num(v) { var n = Number(v); return isFinite(n) ? n : 0 }
    function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)) }

    // First present non-empty stats value among keys, else the sentinel.
    function pick(s, keys) {
        for (var i = 0; i < keys.length; i++) {
            if (has(s, keys[i]))
                return s[keys[i]];
        }
        return unknown;
    }
    function pickNum(s, keys) {
        var v = pick(s, keys);
        if (v === unknown)
            return unknown;
        var n = Number(v);
        return isFinite(n) ? n : unknown;
    }

    function byId(id) {
        var n = nodes[id];
        if (n !== undefined)
            return n;
        return parts[id];
    }
    function node(id) { return byId(id) }   // alias for view ergonomics

    function childIds(id) {
        var c = _children[id];
        return c === undefined ? [] : c;
    }

    function fmtB(bps) {
        if (isUnknown(bps))
            return unknownGlyph;
        var n = Number(bps);
        if (!isFinite(n))
            return unknownGlyph;
        if (n < 1024)
            return Math.round(n) + " B/s";
        if (n < 1048576)
            return (n / 1024).toFixed(1) + " KB/s";
        if (n < 1073741824)
            return (n / 1048576).toFixed(1) + " MB/s";
        return (n / 1073741824).toFixed(2) + " GB/s";
    }
    // Render any vital; unknown -> em-dash glyph.
    function txt(v, unit) {
        if (isUnknown(v))
            return unknownGlyph;
        return String(v) + (unit === undefined ? "" : unit);
    }
    function tempTxt(v) { return isUnknown(v) ? unknownGlyph : Math.round(Number(v)) + "°" }

    // ---------------- class/kind/edge tables ----------------
    // JSON class -> contract kind (contract kinds list only).
    readonly property var _kindOf: ({
        "machine": "fabric",
        "cpu_package": "cpu", "ccd": "ccd", "core": "core",
        "memory": "mem", "dimm": "dimm",
        "pci_root": "bridge", "pci_bridge": "bridge", "sata": "bridge",
        "gpu": "gpu", "nvme": "nvme",
        "nic": "nic", "netif": "nic",
        "xhci": "usb",
        "usb_roothub": "usb", "usb_hub": "usb", "usb_camera": "usb",
        "usb_receiver": "usb", "usb_keyboard": "usb", "usb_rgb": "usb",
        "usb_bluetooth": "usb", "usb_storage": "usb", "input": "usb",
        "audio_pci": "audio", "pw_sink": "audio", "pw_source": "audio",
        "display": "disp",
        "bluetooth": "bt",
        "smbus": "smbus",
        "data_fabric": "fabric", "crypto": "fabric"
    })

    // Edge kind for a parent->child tree link, from the child's class.
    function _edgeKind(parentCls, childCls) {
        switch (childCls) {
        case "cpu_package": case "ccd": case "core": return "cpu";
        case "memory": case "dimm": return "mem";
        case "pci_root": case "pci_bridge": case "gpu": case "nvme":
        case "nic": case "xhci": case "sata": case "audio_pci":
        case "crypto": case "smbus": case "data_fabric": return "pcie";
        case "usb_roothub": case "usb_hub": case "usb_camera":
        case "usb_receiver": case "usb_keyboard": case "usb_rgb":
        case "usb_bluetooth": case "usb_storage": return "usb";
        case "input": return "hid";
        case "pw_sink": case "pw_source": return "audio";
        case "display": return "disp";
        case "netif": return "net";
        case "bluetooth": return "bt";
        }
        return "link";
    }

    // PCI BDF per node (from recon/devices-bus.md sysfs ancestry).
    readonly property var _bdf: ({
        "pci_00_01_1": "00:01.1", "pci_01_00_0": "01:00.0",
        "pci_02_01_0": "02:01.0", "pci_02_02_0": "02:02.0",
        "gpu_arc": "03:00.0", "snd_arc": "04:00.0",
        "pci_00_01_2": "00:01.2", "nvme0": "05:00.0",
        "pci_00_02_1": "00:02.1", "pci_06_00_0": "06:00.0",
        "pci_07_0a_0": "07:0a.0", "nic_eth": "0f:00.0",
        "pci_07_0b_0": "07:0b.0", "nic_wifi": "10:00.0",
        "pci_07_0c_0": "07:0c.0", "xhci_chipset": "11:00.0",
        "pci_07_0d_0": "07:0d.0", "sata0": "12:00.0",
        "pci_00_02_2": "00:02.2", "nvme1": "13:00.0",
        "pci_00_08_1": "00:08.1", "gpu_apu": "14:00.0",
        "snd_apu_hdmi": "14:00.1", "psp": "14:00.2",
        "xhci_apu0": "14:00.3", "xhci_apu1": "14:00.4",
        "snd_apu_analog": "14:00.6",
        "pci_00_08_3": "00:08.3", "xhci_apu2": "15:00.0",
        "smbus0": "00:14.0", "datafabric": "00:18.x"
    })

    // USB vid:pid, read live from sysfs idVendor/idProduct (2026-09-28).
    readonly property var _vidPid: ({
        "usb6": "1d6b:0002", "usb7": "1d6b:0003",
        "usb_hub6": "174c:2074", "usb_hub7": "174c:3074",
        "cam_kiyo": "1532:0e03", "rcvr_corsair": "1b1c:0a42",
        "rcvr_logi": "046d:c547", "kbd_asus": "0b05:18aa",
        "msi_mystic": "0db0:0076", "bt_radio": "0e8d:0616",
        "flash_kingston": "0951:1666"
    })

    // dev_audio{i}_name substring -> pw node id.
    readonly property var _audioMatch: ({
        "pw_sink_hdmi": ["hdmi-stereo", "04_00.0"],
        "pw_sink_analog": ["14_00.6.analog-stereo", "alsa_output.pci-0000_14_00.6"],
        "pw_sink_corsair": ["usb-Corsair", "alsa_output.usb"],
        "pw_src_corsair": ["alsa_input.usb-Corsair", "mono-fallback"],
        "pw_src_kiyo": ["Razer_Kiyo", "alsa_input.usb"],
        "pw_src_analog": ["alsa_input.pci-0000_14_00.6", "14_00.6.analog"]
    })

    readonly property var _ifname: ({ "net_eth": "enp15s0", "net_wifi": "wlp16s0", "net_lo": "lo" })
    readonly property var _blkDev: ({ "nvme0": "nvme0n1", "nvme1": "nvme1n1", "flash_kingston": "sda" })

    // ---------------- embedded scaffold (verbatim recon/devices-bus.json) ----------------
    readonly property var _scaffNodes: [
        {id: "machine", parent: null, cls: "machine", name: "OmarchyLink", vital: {label: "load1", path: "/proc/loadavg", unit: "str"}},
        {id: "cpu_pkg0", parent: "machine", cls: "cpu_package", name: "AMD Ryzen 9 7900X 12-Core", vital: {label: "Tctl", path: "/sys/class/hwmon/hwmon5/temp1_input", unit: "mdegC"}},
        {id: "ccd0", parent: "cpu_pkg0", cls: "ccd", name: "CCD0 (die 0, L3 cpus 0-5,12-17)", vital: {label: "Tccd1", path: "/sys/class/hwmon/hwmon5/temp3_input", unit: "mdegC"}},
        {id: "ccd1", parent: "cpu_pkg0", cls: "ccd", name: "CCD1 (die 1, L3 cpus 6-11,18-23)", vital: {label: "Tccd2", path: "/sys/class/hwmon/hwmon5/temp4_input", unit: "mdegC"}},
        {id: "core0", parent: "ccd0", cls: "core", name: "core 0 (cpu0/cpu12)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core1", parent: "ccd0", cls: "core", name: "core 1 (cpu1/cpu13)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core2", parent: "ccd0", cls: "core", name: "core 2 (cpu2/cpu14)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core3", parent: "ccd0", cls: "core", name: "core 3 (cpu3/cpu15)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu3/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core4", parent: "ccd0", cls: "core", name: "core 4 (cpu4/cpu16)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core5", parent: "ccd0", cls: "core", name: "core 5 (cpu5/cpu17)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu5/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core6", parent: "ccd1", cls: "core", name: "core 6 (cpu6/cpu18)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core7", parent: "ccd1", cls: "core", name: "core 7 (cpu7/cpu19)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core8", parent: "ccd1", cls: "core", name: "core 8 (cpu8/cpu20)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu8/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core9", parent: "ccd1", cls: "core", name: "core 9 (cpu9/cpu21)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu9/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core10", parent: "ccd1", cls: "core", name: "core 10 (cpu10/cpu22)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu10/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "core11", parent: "ccd1", cls: "core", name: "core 11 (cpu11/cpu23)", vital: {label: "freq", path: "/sys/devices/system/cpu/cpu11/cpufreq/scaling_cur_freq", unit: "kHz"}},
        {id: "mem", parent: "machine", cls: "memory", name: "64.85 GB DDR5 (33 x 2 GiB blocks)", vital: {label: "MemAvailable", path: "/proc/meminfo", unit: "kB"}},
        {id: "dimm0", parent: "mem", cls: "dimm", name: "DIMM slot 0 (SPD5118 i2c 20-0051)", vital: {label: "temp", path: "/sys/class/hwmon/hwmon7/temp1_input", unit: "mdegC"}},
        {id: "dimm1", parent: "mem", cls: "dimm", name: "DIMM slot 1 (SPD5118 i2c 20-0053)", vital: {label: "temp", path: "/sys/class/hwmon/hwmon8/temp1_input", unit: "mdegC"}},
        {id: "pci0000_00", parent: "machine", cls: "pci_root", name: "AMD Raphael/Granite Ridge root complex", vital: {label: "present", path: "/sys/bus/pci/devices/0000:00:00.0/vendor", unit: "str"}},
        {id: "pci_00_01_1", parent: "pci0000_00", cls: "pci_bridge", name: "AMD PCIe bridge 00:01.1 (x8@16.0, max x16@32.0)", vital: {label: "link", path: "/sys/bus/pci/devices/0000:00:01.1/current_link_speed", unit: "GT/s"}},
        {id: "pci_01_00_0", parent: "pci_00_01_1", cls: "pci_bridge", name: "Intel switch upstream 01:00.0 [8086:e2ff]", vital: {label: "link", path: "/sys/bus/pci/devices/0000:01:00.0/current_link_speed", unit: "GT/s"}},
        {id: "pci_02_01_0", parent: "pci_01_00_0", cls: "pci_bridge", name: "Intel switch downstream 02:01.0", vital: {label: "link", path: "/sys/bus/pci/devices/0000:02:01.0/current_link_speed", unit: "GT/s"}},
        {id: "pci_02_02_0", parent: "pci_01_00_0", cls: "pci_bridge", name: "Intel switch downstream 02:02.0", vital: {label: "link", path: "/sys/bus/pci/devices/0000:02:02.0/current_link_speed", unit: "GT/s"}},
        {id: "gpu_arc", parent: "pci_02_01_0", cls: "gpu", name: "Intel Arc B580 [8086:e20b] card0 driver=xe", vital: {label: "pkg temp", path: "/sys/class/hwmon/hwmon2/temp2_input", unit: "mdegC"}},
        {id: "snd_arc", parent: "pci_02_02_0", cls: "audio_pci", name: "B580 HDMI/DP audio (snd_hda_intel, card 1 PCH)", vital: {label: "card present", path: "/proc/asound/cards", unit: "bool"}},
        {id: "pci_00_01_2", parent: "pci0000_00", cls: "pci_bridge", name: "AMD PCIe bridge 00:01.2 (x4@16.0)", vital: {label: "link", path: "/sys/bus/pci/devices/0000:00:01.2/current_link_speed", unit: "GT/s"}},
        {id: "nvme0", parent: "pci_00_01_2", cls: "nvme", name: "KINGSTON SNV3S2000G 2TB (nvme0n1, 05:00.0)", vital: {label: "composite temp", path: "/sys/class/hwmon/hwmon1/temp1_input", unit: "mdegC"}},
        {id: "pci_00_02_1", parent: "pci0000_00", cls: "pci_bridge", name: "AMD PCIe bridge 00:02.1 (x4@16.0)", vital: {label: "link", path: "/sys/bus/pci/devices/0000:00:02.1/current_link_speed", unit: "GT/s"}},
        {id: "pci_06_00_0", parent: "pci_00_02_1", cls: "pci_bridge", name: "AMD chipset switch 06:00.0 [1022:43f4]", vital: {label: "link", path: "/sys/bus/pci/devices/0000:06:00.0/current_link_speed", unit: "GT/s"}},
        {id: "pci_07_0a_0", parent: "pci_06_00_0", cls: "pci_bridge", name: "switch port 07:0a.0", vital: {label: "link", path: "/sys/bus/pci/devices/0000:07:0a.0/current_link_speed", unit: "GT/s"}},
        {id: "pci_07_0b_0", parent: "pci_06_00_0", cls: "pci_bridge", name: "switch port 07:0b.0", vital: {label: "link", path: "/sys/bus/pci/devices/0000:07:0b.0/current_link_speed", unit: "GT/s"}},
        {id: "pci_07_0c_0", parent: "pci_06_00_0", cls: "pci_bridge", name: "switch port 07:0c.0", vital: {label: "link", path: "/sys/bus/pci/devices/0000:07:0c.0/current_link_speed", unit: "GT/s"}},
        {id: "pci_07_0d_0", parent: "pci_06_00_0", cls: "pci_bridge", name: "switch port 07:0d.0", vital: {label: "link", path: "/sys/bus/pci/devices/0000:07:0d.0/current_link_speed", unit: "GT/s"}},
        {id: "nic_eth", parent: "pci_07_0a_0", cls: "nic", name: "Realtek RTL8125 2.5GbE 0f:00.0 (r8169)", vital: {label: "temp", path: "/sys/class/hwmon/hwmon6/temp1_input", unit: "mdegC"}},
        {id: "nic_wifi", parent: "pci_07_0b_0", cls: "nic", name: "MediaTek MT7922 Wi-Fi 6E 10:00.0 (mt7921e)", vital: {label: "phy temp", path: "/sys/class/hwmon/hwmon9/temp1_input", unit: "mdegC"}},
        {id: "xhci_chipset", parent: "pci_07_0c_0", cls: "xhci", name: "AMD 800-series USB3 xHCI 11:00.0 (usb6/usb7)", vital: {label: "temp", path: "/sys/class/hwmon/hwmon4/temp1_input", unit: "mdegC"}},
        {id: "sata0", parent: "pci_07_0d_0", cls: "sata", name: "AMD 600-series SATA 12:00.0 (ahci)", vital: {label: "link", path: "/sys/bus/pci/devices/0000:12:00.0/current_link_speed", unit: "GT/s"}},
        {id: "pci_00_02_2", parent: "pci0000_00", cls: "pci_bridge", name: "AMD PCIe bridge 00:02.2 (x4@16.0)", vital: {label: "link", path: "/sys/bus/pci/devices/0000:00:02.2/current_link_speed", unit: "GT/s"}},
        {id: "nvme1", parent: "pci_00_02_2", cls: "nvme", name: "Samsung 980 PRO 2TB (nvme1n1, 13:00.0)", vital: {label: "composite temp", path: "/sys/class/hwmon/hwmon0/temp1_input", unit: "mdegC"}},
        {id: "pci_00_08_1", parent: "pci0000_00", cls: "pci_bridge", name: "AMD APU fabric bridge 00:08.1 (x16@16.0)", vital: {label: "link", path: "/sys/bus/pci/devices/0000:00:08.1/current_link_speed", unit: "GT/s"}},
        {id: "gpu_apu", parent: "pci_00_08_1", cls: "gpu", name: "AMD Raphael iGPU [1002:164e] card1 driver=amdgpu", vital: {label: "edge temp", path: "/sys/class/hwmon/hwmon3/temp1_input", unit: "mdegC"}},
        {id: "snd_apu_hdmi", parent: "pci_00_08_1", cls: "audio_pci", name: "Radeon HD Audio 14:00.1 (card 2)", vital: {label: "card present", path: "/proc/asound/cards", unit: "bool"}},
        {id: "psp", parent: "pci_00_08_1", cls: "crypto", name: "AMD PSP/CCP 14:00.2", vital: {label: "driver bound", path: "/sys/bus/pci/devices/0000:14:00.2/driver", unit: "bool"}},
        {id: "xhci_apu0", parent: "pci_00_08_1", cls: "xhci", name: "Raphael USB3 xHCI 14:00.3 (usb1/usb2)", vital: {label: "driver bound", path: "/sys/bus/pci/devices/0000:14:00.3/driver", unit: "bool"}},
        {id: "xhci_apu1", parent: "pci_00_08_1", cls: "xhci", name: "Raphael USB3 xHCI 14:00.4 (usb3/usb4)", vital: {label: "driver bound", path: "/sys/bus/pci/devices/0000:14:00.4/driver", unit: "bool"}},
        {id: "snd_apu_analog", parent: "pci_00_08_1", cls: "audio_pci", name: "Ryzen HD Audio 14:00.6 analog (card 3)", vital: {label: "card present", path: "/proc/asound/cards", unit: "bool"}},
        {id: "pci_00_08_3", parent: "pci0000_00", cls: "pci_bridge", name: "AMD bridge 00:08.3 (x16@16.0)", vital: {label: "link", path: "/sys/bus/pci/devices/0000:00:08.3/current_link_speed", unit: "GT/s"}},
        {id: "xhci_apu2", parent: "pci_00_08_3", cls: "xhci", name: "Raphael USB2 xHCI 15:00.0 (usb5)", vital: {label: "driver bound", path: "/sys/bus/pci/devices/0000:15:00.0/driver", unit: "bool"}},
        {id: "smbus0", parent: "pci0000_00", cls: "smbus", name: "FCH SMBus 00:14.0 (i2c-20, DIMM sensors)", vital: {label: "driver bound", path: "/sys/bus/pci/devices/0000:14.0/driver", unit: "bool"}},
        {id: "datafabric", parent: "pci0000_00", cls: "data_fabric", name: "AMD Data Fabric 00:18.0-7 (k10temp on 00:18.3)", vital: {label: "Tctl", path: "/sys/class/hwmon/hwmon5/temp1_input", unit: "mdegC"}},
        {id: "usb6", parent: "xhci_chipset", cls: "usb_roothub", name: "usb6 root hub (480M)", vital: {label: "speed", path: "/sys/bus/usb/devices/usb6/speed", unit: "Mb/s"}},
        {id: "usb7", parent: "xhci_chipset", cls: "usb_roothub", name: "usb7 root hub (10G)", vital: {label: "speed", path: "/sys/bus/usb/devices/usb7/speed", unit: "Mb/s"}},
        {id: "usb_hub6", parent: "usb6", cls: "usb_hub", name: "ASM107x hub 6-6 (480M)", vital: {label: "speed", path: "/sys/bus/usb/devices/6-6/speed", unit: "Mb/s"}},
        {id: "cam_kiyo", parent: "usb_hub6", cls: "usb_camera", name: "Razer Kiyo 6-6.1 (uvcvideo + usb-audio)", vital: {label: "speed", path: "/sys/bus/usb/devices/6-6.1/speed", unit: "Mb/s"}},
        {id: "rcvr_corsair", parent: "usb_hub6", cls: "usb_receiver", name: "Corsair Slipstream receiver 6-6.2", vital: {label: "speed", path: "/sys/bus/usb/devices/6-6.2/speed", unit: "Mb/s"}},
        {id: "rcvr_logi", parent: "usb_hub6", cls: "usb_receiver", name: "Logitech USB receiver 6-6.3 (G502 X PLUS)", vital: {label: "battery", path: "/sys/class/power_supply/hidpp_battery_0/capacity", unit: "%"}},
        {id: "kbd_asus", parent: "usb_hub6", cls: "usb_keyboard", name: "ASUS TUF GAMING K7 6-6.4", vital: {label: "speed", path: "/sys/bus/usb/devices/6-6.4/speed", unit: "Mb/s"}},
        {id: "msi_mystic", parent: "usb6", cls: "usb_rgb", name: "MSI MYSTIC LIGHT 6-7", vital: {label: "speed", path: "/sys/bus/usb/devices/6-7/speed", unit: "Mb/s"}},
        {id: "bt_radio", parent: "usb6", cls: "usb_bluetooth", name: "MediaTek Wireless_Device 6-8 (btusb)", vital: {label: "hci present", path: "/sys/class/bluetooth/hci0", unit: "bool"}},
        {id: "usb_hub7", parent: "usb7", cls: "usb_hub", name: "ASM107x hub 7-6 (5G)", vital: {label: "speed", path: "/sys/bus/usb/devices/7-6/speed", unit: "Mb/s"}},
        {id: "flash_kingston", parent: "usb7", cls: "usb_storage", name: "Kingston DataTraveler 3.0 7-3 (sda)", vital: {label: "speed", path: "/sys/bus/usb/devices/7-3/speed", unit: "Mb/s"}},
        {id: "disp_dp1", parent: "gpu_arc", cls: "display", name: "DP-1 Samsung LC27G7xT 2560x1440 @0,0", vital: {label: "status", path: "/sys/class/drm/card0-DP-1/status", unit: "str"}},
        {id: "disp_dp2", parent: "gpu_arc", cls: "display", name: "DP-2 HP E24i G4 1920x1200 @2560,0", vital: {label: "status", path: "/sys/class/drm/card0-DP-2/status", unit: "str"}},
        {id: "disp_hdmi3", parent: "gpu_arc", cls: "display", name: "HDMI-A-3 HP Z24n G3 1920x1200 @-1920,0", vital: {label: "status", path: "/sys/class/drm/card0-HDMI-A-3/status", unit: "str"}},
        {id: "input_kbd", parent: "kbd_asus", cls: "input", name: "ASUS TUF GAMING K7 (event13/14)", vital: {label: "present", path: "/proc/bus/input/devices", unit: "bool"}},
        {id: "input_mouse", parent: "rcvr_logi", cls: "input", name: "Logitech G502 X PLUS (event11/mouse2)", vital: {label: "battery", path: "/sys/class/power_supply/hidpp_battery_0/capacity", unit: "%"}},
        {id: "input_corsair", parent: "rcvr_corsair", cls: "input", name: "Corsair Slipstream kbd+mouse (event6-10)", vital: {label: "present", path: "/proc/bus/input/devices", unit: "bool"}},
        {id: "pw_sink_hdmi", parent: "snd_arc", cls: "pw_sink", name: "alsa_output.pci-0000_04_00.0.hdmi-stereo (LC27G7xT)", vital: {label: "node present", path: "pw-dump", unit: "bool"}},
        {id: "pw_sink_analog", parent: "snd_apu_analog", cls: "pw_sink", name: "alsa_output.pci-0000_14_00.6.analog-stereo", vital: {label: "node present", path: "pw-dump", unit: "bool"}},
        {id: "pw_sink_corsair", parent: "rcvr_corsair", cls: "pw_sink", name: "alsa_output.usb-Corsair...analog-stereo", vital: {label: "node present", path: "pw-dump", unit: "bool"}},
        {id: "pw_src_corsair", parent: "rcvr_corsair", cls: "pw_source", name: "alsa_input.usb-Corsair...mono-fallback", vital: {label: "node present", path: "pw-dump", unit: "bool"}},
        {id: "pw_src_kiyo", parent: "cam_kiyo", cls: "pw_source", name: "alsa_input.usb-...Razer_Kiyo-02.analog-stereo", vital: {label: "node present", path: "pw-dump", unit: "bool"}},
        {id: "pw_src_analog", parent: "snd_apu_analog", cls: "pw_source", name: "alsa_input.pci-0000_14_00.6.analog-stereo", vital: {label: "node present", path: "pw-dump", unit: "bool"}},
        {id: "net_eth", parent: "nic_eth", cls: "netif", name: "enp15s0 UP 34:5a:60:dd:f5:a8", vital: {label: "operstate", path: "/sys/class/net/enp15s0/operstate", unit: "str"}},
        {id: "net_wifi", parent: "nic_wifi", cls: "netif", name: "wlp16s0 DOWN 7a:7a:fe:81:86:9d", vital: {label: "operstate", path: "/sys/class/net/wlp16s0/operstate", unit: "str"}},
        {id: "net_lo", parent: "machine", cls: "netif", name: "lo loopback", vital: {label: "operstate", path: "/sys/class/net/lo/operstate", unit: "str"}},
        {id: "bt_hci0", parent: "bt_radio", cls: "bluetooth", name: "hci0 MT7922 controller (no paired devices)", vital: {label: "present", path: "/sys/class/bluetooth/hci0", unit: "bool"}}
    ]
    // Flow links, verbatim recon/devices-bus.json "flows" (dup gpu_* links merged by id).
    readonly property var _scaffFlows: [
        {id: "net_eth", a: "net_eth", b: "machine", unit: "B/s", src: "/proc/net/dev enp15s0 rx/tx bytes delta", dir: "duplex"},
        {id: "net_wifi", a: "net_wifi", b: "machine", unit: "B/s", src: "/proc/net/dev wlp16s0 rx/tx bytes delta", dir: "duplex"},
        {id: "nvme0", a: "nvme0", b: "machine", unit: "B/s", src: "/proc/diskstats nvme0n1 sectors delta x 512", dir: "duplex"},
        {id: "nvme1", a: "nvme1", b: "machine", unit: "B/s", src: "/proc/diskstats nvme1n1 sectors delta x 512", dir: "duplex"},
        {id: "flash_kingston", a: "flash_kingston", b: "machine", unit: "B/s", src: "/proc/diskstats sda sectors delta x 512", dir: "duplex"},
        {id: "gpu_arc", a: "gpu_arc", b: "machine", unit: "MHz", src: "card0 tile0/gt0/freq0/cur_freq", dir: "duplex"},
        {id: "gpu_apu", a: "gpu_apu", b: "machine", unit: "%", src: "card1 gpu_busy_percent", dir: "duplex"},
        {id: "gpu_apu_pw", a: "gpu_apu", b: "machine", unit: "W", src: "hwmon3 power1_input (PPT)", dir: "ab"},
        {id: "disp_dp1", a: "gpu_arc", b: "disp_dp1", unit: "str", src: "card0-DP-1 status", dir: "ab"},
        {id: "disp_dp2", a: "gpu_arc", b: "disp_dp2", unit: "str", src: "card0-DP-2 status", dir: "ab"},
        {id: "disp_hdmi3", a: "gpu_arc", b: "disp_hdmi3", unit: "str", src: "card0-HDMI-A-3 status", dir: "ab"},
        {id: "cpu_pkg0", a: "cpu_pkg0", b: "machine", unit: "%", src: "/proc/stat aggregate delta", dir: "ab"},
        {id: "mem", a: "mem", b: "machine", unit: "kB/s", src: "/proc/meminfo Dirty/Writeback deltas", dir: "ab"}
    ]

    // ---------------- internal state ----------------
    property var _nodesLive: ({})     // working node dict (stable object refs)
    property var _order: []           // scaffold-order id list
    property var _children: ({})      // id -> [child ids] (scaffold only)
    property var _edgeLive: []        // working edge list
    property var _flowSrc: ({})       // flowId -> spec built from _scaffFlows
    property var _lastStats: null
    property bool _built: false
    // counters needing deltas between frames
    property var _prev: ({})
    property double _lastT: 0

    // QtObject's default `data` is list<QtObject> — Quickshell's FileView is a
    // plain QObject, so it must ride a typed property, not a child slot.
    property FileView scaffFile: FileView {
        path: String(Qt.resolvedUrl("../recon/devices-bus.json")).replace(/^file:\/\//, "")
        watchChanges: false
        printErrors: false
        onLoaded: topo._loadScaffold(text())
        onLoadFailed: topo._useEmbedded()
    }

    // Pathological case: FileView signals neither — build from embedded copy.
    property Timer scaffBootTimer: Timer {
        interval: 1500
        repeat: false
        running: true
        onTriggered: topo._useEmbedded()
    }

    function _useEmbedded() {
        if (_built)
            return;
        _build(_scaffNodes, _scaffFlows, "embedded");
    }

    function _loadScaffold(raw) {
        if (_built)
            return;
        var doc = null;
        try { doc = JSON.parse(String(raw || "")) } catch (e) { doc = null }
        if (doc === null || typeof doc !== "object" || !doc.nodes || doc.nodes.length !== scaffoldCount) {
            _useEmbedded();
            return;
        }
        var ns = [];
        for (var i = 0; i < doc.nodes.length; i++) {
            var n = doc.nodes[i];
            var v = n.vital || {};
            ns.push({
                id: String(n.id), parent: n.parent === null ? null : String(n.parent),
                cls: String(n["class"]), name: String(n.name),
                vital: { label: String(v.label || ""), path: String(v.path_or_cmd || ""), unit: String(v.unit || "") }
            });
        }
        var fs = [];
        var seen = {};
        var unitSuffix = { "uW": "pw", "W": "pw", "%": "pct", "MHz": "mhz",
                           "GT/s": "link", "kB/s": "kbps" };
        var flows = doc.flows || [];
        for (var j = 0; j < flows.length; j++) {
            var f = flows[j];
            var id = String(f.link[0]);
            if (seen[id]) {           // e.g. gpu_apu→machine twice (%, uW): disambiguate
                var sfx = unitSuffix[String(f.unit)] || String(j);
                id = id + "_" + sfx;
                while (seen[id])
                    id = id + "_" + j;
            }
            seen[id] = true;
            fs.push({ id: id, a: String(f.link[0]), b: String(f.link[1]),
                      unit: String(f.unit), src: String(f.source), dir: "duplex" });
        }
        _build(ns, fs, "recon/devices-bus.json");
    }

    // ---------------- scaffold build ----------------
    function _shortTag(n) {
        // Small display tag for dense views: bdf-ish suffix or first tokens.
        var b = _bdf[n.id];
        if (b !== undefined && b.indexOf("00:18") !== 0)
            return b;
        var m = String(n.name).match(/^([A-Za-z0-9._:\-]+)/);
        return m ? m[1] : n.id;
    }

    function _build(nodeDefs, flowDefs, source) {
        if (_built)
            return;
        _built = true;
        scaffoldSource = source;

        var nd = {}, order = [], ch = {};
        for (var i = 0; i < nodeDefs.length; i++) {
            var d = nodeDefs[i];
            var cls = d.cls;
            var kind = _kindOf[cls] !== undefined ? _kindOf[cls] : "usb";
            var extra = {
                cls: cls, parentId: d.parent,
                vitalLabel: d.vital.label, vitalPath: d.vital.path, vitalUnit: d.vital.unit,
                tag: _shortTag(d)
            };
            var bdf = _bdf[d.id];
            if (bdf !== undefined)
                extra.bdf = bdf;
            var vp = _vidPid[d.id];
            if (vp !== undefined)
                extra.vidPid = vp;
            var ifn = _ifname[d.id];
            if (ifn !== undefined)
                extra.ifname = ifn;
            var blk = _blkDev[d.id];
            if (blk !== undefined)
                extra.blk = blk;
            var am = _audioMatch[d.id];
            if (am !== undefined)
                extra.match = am;
            var lm = String(d.name).match(/x\d+@[0-9.]+/);   // e.g. "x8@16.0"
            if (lm)
                extra.linkSpec = lm[0];
            var sm = String(d.name).match(/\((\d+[MG])\)/);  // e.g. "(480M)"
            if (sm)
                extra.speedSpec = sm[1];
            // scaffold-verified presence is static truth, not telemetry:
            // fixed silicon gets "present"; hot-removable leaves get unknown
            // until a live key arrives.
            var hot = (cls === "usb_storage" || cls === "usb_camera" ||
                       cls === "usb_receiver" || cls === "usb_keyboard" ||
                       cls === "usb_rgb" || cls === "usb_hub" ||
                       cls === "pw_sink" || cls === "pw_source" ||
                       cls === "bluetooth");
            var state = hot ? unknown : "present";
            if (cls === "display")
                state = "connected";
            else if (cls === "netif" && d.id === "net_lo")
                state = "up";

            nd[d.id] = {
                id: d.id, kind: kind, label: d.name,
                temp: unknown, load: unknown, power: unknown,
                link: unknown, state: state, extra: extra
            };
            order.push(d.id);
            if (d.parent !== null) {
                if (ch[d.parent] === undefined)
                    ch[d.parent] = [];
                ch[d.parent].push(d.id);
            }
        }
        _nodesLive = nd;
        _order = order;
        _children = ch;

        // Tree edges: one per parent->child pair.
        var el = [];
        var byPair = {};
        for (var k = 0; k < nodeDefs.length; k++) {
            var c = nodeDefs[k];
            if (c.parent === null)
                continue;
            var p = nd[c.parent];
            var ek = _edgeKind(p !== undefined ? p.extra.cls : "", c.cls);
            var e = { a: c.parent, b: c.id, kind: ek, bw: unknown,
                      active: false, rate: unknown, unit: "", flow: "" };
            el.push(e);
            byPair[c.parent + "|" + c.id] = e;
        }
        // Flow overlay links: fold onto a matching tree edge when the pair
        // already exists, else append a kind:"flow" edge.
        var fsrc = {};
        for (var g = 0; g < flowDefs.length; g++) {
            var fd = flowDefs[g];
            fsrc[fd.id] = fd;
            var hit = byPair[fd.a + "|" + fd.b] || byPair[fd.b + "|" + fd.a];
            if (hit !== undefined) {
                hit.flow = fd.id;
                hit.unit = fd.unit;
            } else {
                el.push({ a: fd.a, b: fd.b, kind: "flow", bw: unknown,
                          active: false, rate: unknown, unit: fd.unit, flow: fd.id });
            }
        }
        _flowSrc = fsrc;
        _edgeLive = el;
        _publish(true);
        ready = true;
        if (_lastStats !== null)
            refresh(_lastStats);
    }

    // ---------------- vitals application ----------------
    function _pcieLink(s, id) {
        var bdf = _bdf[id];
        if (bdf === undefined)
            return unknown;
        var norms = [bdf, bdf.replace(/[:.]/g, "_"), "0000:" + bdf,
                     ("0000:" + bdf).replace(/[:.]/g, "_")];
        for (var i = 0; i < norms.length; i++) {
            var g = s["dev_pcie_" + norms[i] + "_gen"];
            var w = s["dev_pcie_" + norms[i] + "_width"];
            if (g !== undefined || w !== undefined) {
                var gs = (g === undefined || g === "") ? "?" : String(g);
                var ws = (w === undefined || w === "") ? "?" : String(w);
                if (String(ws).indexOf("x") !== 0)
                    ws = "x" + ws;
                return ws + "@" + gs;
            }
        }
        return unknown;
    }

    function _hidppBatt(s) {
        for (var i = 0; i < 8; i++) {
            var nm = s["bat" + i + "_name"];
            if (nm === undefined)
                break;
            if (/hidpp|logitech|g502/i.test(String(nm)))
                return pickNum(s, ["bat" + i + "_pct"]);
        }
        return unknown;
    }

    // Aggregate CPU % from cumulative jiffies (v3 applyFrame math).
    property var _cpuPrev: null
    function _cpuPct(s) {
        var idle = has(s, "cpu_idle") ? Number(s.cpu_idle) : NaN;
        var total = has(s, "cpu_total") ? Number(s.cpu_total) : NaN;
        var pct = unknown;
        if (_cpuPrev !== null && isFinite(idle) && isFinite(total) && total > _cpuPrev[1])
            pct = clamp(100 * (1 - (idle - _cpuPrev[0]) / (total - _cpuPrev[1])), 0, 100);
        if (isFinite(idle) && isFinite(total))
            _cpuPrev = [idle, total];
        return pct;
    }

    // Legacy net_rx/net_tx are cumulative counters -> rate via delta.
    function _counterRate(s, key, dt) {
        if (!has(s, key))
            return unknown;
        var v = Number(s[key]);
        if (!isFinite(v))
            return unknown;
        var pv = _prev[key];
        _prev[key] = v;
        if (pv === undefined || dt <= 0 || v < pv)
            return unknown;          // first frame or counter reset: honest unknown
        return Math.max(0, (v - pv) / dt);
    }

    function refresh(stats) {
        if (!_built) {               // stash until scaffold arrives
            _lastStats = stats;
            return;
        }
        var s = stats || {};
        _lastStats = s;
        var t = Date.now();
        var dt = _lastT > 0 ? (t - _lastT) / 1000 : 0;
        _lastT = t;
        var nd = _nodesLive;
        var pct = _cpuPct(s);

        // ---- machine ----
        var n = nd.machine;
        n.load = pct;
        n.extra.load1 = pick(s, ["load1"]);
        n.extra.load5 = pick(s, ["load5"]);
        n.extra.load15 = pick(s, ["load15"]);
        n.extra.uptime_s = pickNum(s, ["uptime_s"]);

        // ---- cpu package / ccds / cores ----
        n = nd.cpu_pkg0;
        n.temp = pickNum(s, ["dev_cpu_t", "dev_cpu0_t", "cpu_temp"]);
        n.load = pct;
        n.extra.mhz_avg = pickNum(s, ["cpu_mhz_avg"]);
        n.extra.mhz_max = pickNum(s, ["cpu_mhz_max"]);

        var ccdLoad = [unknown, unknown];
        var ccdCnt = [0, 0];
        var ccdSum = [0, 0];
        for (var ci = 0; ci < 12; ci++) {
            n = nd["core" + ci];
            var cp = pickNum(s, ["dev_core" + ci + "_pct"]);
            if (cp === unknown) {
                var a = pickNum(s, ["cpu_core_" + ci]);
                var b = pickNum(s, ["cpu_core_" + (ci + 12)]);
                if (a !== unknown && b !== unknown)
                    cp = (a + b) / 2;
                else if (a !== unknown)
                    cp = a;
                else
                    cp = b;
            }
            n.load = cp;
            n.extra.mhz = pickNum(s, ["dev_core" + ci + "_mhz"]);
            if (cp !== unknown) {
                var ciCcd = ci < 6 ? 0 : 1;
                ccdSum[ciCcd] += cp;
                ccdCnt[ciCcd]++;
            }
        }
        for (var di = 0; di < 2; di++) {
            n = nd["ccd" + di];
            n.temp = pickNum(s, ["dev_ccd" + di + "_t", "cpu_tccd" + (di + 1)]);
            n.load = ccdCnt[di] > 0 ? ccdSum[di] / ccdCnt[di] : unknown;
        }

        // ---- memory ----
        n = nd.mem;
        var mt = pickNum(s, ["mem_total_kb"]);
        var ma = pickNum(s, ["mem_avail_kb"]);
        n.extra.total_kb = mt;
        n.extra.avail_kb = ma;
        if (mt !== unknown && ma !== unknown && mt > 0)
            n.load = clamp(100 * (1 - ma / mt), 0, 100);
        for (var mi = 0; mi < 2; mi++) {
            n = nd["dimm" + mi];
            n.temp = pickNum(s, ["dev_dimm" + mi + "_t", "dimm" + mi + "_temp"]);
        }

        // ---- pci fabric ----
        for (var k in _bdf) {
            n = nd[k];
            if (n === undefined)
                continue;
            var lk = _pcieLink(s, k);
            if (lk !== unknown)
                n.link = lk;
        }
        nd.datafabric.temp = pickNum(s, ["dev_cpu_t", "dev_cpu0_t", "cpu_temp"]); // k10temp same die

        // ---- gpus ----
        var ga = nd.gpu_arc;
        ga.temp = pickNum(s, ["dev_gpu0_temp", "i_temp_pkg"]);
        ga.load = pickNum(s, ["dev_gpu0_pct", "i_util"]);
        ga.power = pickNum(s, ["dev_gpu0_pw", "i_pwr_w"]);
        ga.extra.mhz = pickNum(s, ["dev_gpu0_mhz", "i_freq_mhz"]);
        ga.extra.vram_used_mb = pickNum(s, ["dev_gpu0_vram", "i_vram_used"]);
        ga.extra.vram_total_mb = pickNum(s, ["dev_gpu0_vram_total", "i_vram_total"]);
        ga.extra.fan_rpm = pickNum(s, ["dev_fans0_rpm", "i_fan_rpm"]);
        ga.extra.pwr_cap_w = pickNum(s, ["i_pwr_cap_w"]);
        ga.extra.vram_ch_max = pickNum(s, ["i_vram_ch_max"]);
        ga.extra.vram_ch_avg = pickNum(s, ["i_vram_ch_avg"]);
        var gp = nd.gpu_apu;
        gp.temp = pickNum(s, ["dev_gpu1_temp", "a_temp"]);
        gp.load = pickNum(s, ["dev_gpu1_pct", "a_util"]);
        gp.power = pickNum(s, ["dev_gpu1_pw", "a_pwr_w"]);
        gp.extra.mhz = pickNum(s, ["dev_gpu1_mhz", "a_freq_mhz"]);
        gp.extra.vram_used_mb = pickNum(s, ["dev_gpu1_vram", "a_vram_used"]);
        gp.extra.vram_total_mb = pickNum(s, ["dev_gpu1_vram_total", "a_vram_total"]);

        // ---- nvme drives ----
        for (var vi = 0; vi < 2; vi++) {
            n = nd["nvme" + vi];
            n.temp = pickNum(s, ["dev_nvme" + vi + "_t", "nvme" + vi + "_temp"]);
            n.extra.temp2 = pickNum(s, ["nvme" + vi + "_temp2"]);
            n.extra.model = pick(s, ["nvme" + vi + "_model"]);
            n.extra.rd_bps = pickNum(s, ["dev_nvme" + vi + "_rd"]);
            n.extra.wr_bps = pickNum(s, ["dev_nvme" + vi + "_wr"]);
        }

        // ---- net interfaces ----
        for (var ni = 0; ni < 3; ni++) {
            var nid = ["net_eth", "net_wifi", "net_lo"][ni];
            n = nd[nid];
            var ifn = _ifname[nid];
            var up = pick(s, ["dev_nic_" + ifn + "_up", "dev_net" + ni + "_operstate"]);
            if (up !== unknown) {
                var us = String(up).toLowerCase();
                n.state = (us === "1" || us === "up" || us === "yes" || us === "true") ? "up" : "down";
            } else if (nid === "net_wifi") {
                n.state = "down";    // recon: wlp16s0 DOWN
            } else if (nid === "net_eth") {
                n.state = "up";      // recon: enp15s0 UP (sole wired iface)
            }
            n.extra.rx_bps = pickNum(s, ["dev_nic_" + ifn + "_rx"]);
            n.extra.tx_bps = pickNum(s, ["dev_nic_" + ifn + "_tx"]);
        }

        // ---- usb leaves: presence via dev_usb_<vid:pid>_name ----
        for (var uk in _vidPid) {
            n = nd[uk];
            if (n === undefined || n.extra.cls === "usb_roothub")
                continue;
            var vp = _vidPid[uk];
            if (has(s, "dev_usb_" + vp + "_name")) {
                n.state = "present";
                n.extra.devName = pick(s, ["dev_usb_" + vp + "_name"]);
            } else {
                n.state = unknown;
            }
            var batt = pickNum(s, ["dev_usb_" + vp + "_batt"]);
            if (batt !== unknown)
                n.extra.batt_pct = batt;
            var spd = pickNum(s, ["dev_usb_" + vp + "_speed"]);
            if (spd !== unknown)
                n.link = String(spd) + " Mb/s";
        }
        // G502 battery lives behind the receiver; legacy hidpp fallback.
        var hb = _hidppBatt(s);
        if (hb !== unknown) {
            nd.rcvr_logi.extra.batt_pct = hb;
            nd.input_mouse.extra.batt_pct = hb;
        }

        // ---- pipewire nodes via dev_audio{i}_{name,sink,vol} ----
        var seenAudio = {};
        for (var ai = 0; ai < 10; ai++) {
            var an = s["dev_audio" + ai + "_name"];
            if (an === undefined)
                break;
            an = String(an);
            for (var pid in _audioMatch) {
                var toks = _audioMatch[pid];
                for (var ti = 0; ti < toks.length; ti++) {
                    if (an.indexOf(toks[ti]) >= 0 && !seenAudio[pid]) {
                        seenAudio[pid] = true;
                        var pn = nd[pid];
                        pn.state = "present";
                        pn.extra.audioName = an;
                        var vol = pickNum(s, ["dev_audio" + ai + "_vol"]);
                        if (vol !== unknown)
                            pn.extra.vol_pct = vol;
                        var sk = pick(s, ["dev_audio" + ai + "_sink"]);
                        if (sk !== unknown)
                            pn.extra.sink = sk;
                    }
                }
            }
        }
        for (var pk in _audioMatch) {
            if (!seenAudio[pk])
                nd[pk].state = unknown;
        }

        // ---- bluetooth controller ----
        var bh = nd.bt_hci0;
        var bpaired = pickNum(s, ["dev_bt_paired", "dev_btctl0_paired"]);
        var bconn = pickNum(s, ["dev_bt_conn", "dev_btctl0_conn"]);
        if (bpaired !== unknown || bconn !== unknown) {
            bh.state = "up";
            bh.extra.paired = bpaired;
            bh.extra.connected = bconn;
        }

        // ---- block partitions -> kind:"part" records in `parts` ----
        var newParts = {};
        var diskIds = ["nvme0", "nvme1", "flash_kingston"];
        for (var dz = 0; dz < diskIds.length; dz++)
            nd[diskIds[dz]].extra.parts = [];   // clear stale list before rescan
        for (var bi = 0; bi < 16; bi++) {
            var bname = s["blk" + bi + "_name"];
            if (bname === undefined)
                break;
            bname = String(bname);
            var owner = "";
            for (var dj = 0; dj < diskIds.length; dj++) {
                if (nd[diskIds[dj]].extra.blk === bname)
                    owner = diskIds[dj];
            }
            if (owner === "")
                continue;
            var dn = nd[owner];
            if (dn.temp === unknown)
                dn.temp = pickNum(s, ["blk" + bi + "_temp"]);
            var plist = [];
            var pc = 0;
            for (var pj = 0; pj < 16; pj++) {
                var pname = s["blk" + bi + "p" + pj + "_name"];
                if (pname === undefined)
                    break;
                pname = String(pname);
                var prec = {
                    id: pname, kind: "part", label: pname,
                    temp: unknown, load: pickNum(s, ["blk" + bi + "p" + pj + "_pct"]),
                    power: unknown, link: unknown,
                    state: has(s, "blk" + bi + "p" + pj + "_mount") && s["blk" + bi + "p" + pj + "_mount"] !== "" ? "mounted" : "present",
                    extra: {
                        cls: "part", parentId: owner, disk: bname,
                        size_bytes: pickNum(s, ["blk" + bi + "p" + pj + "_size_bytes"]),
                        used_bytes: pickNum(s, ["blk" + bi + "p" + pj + "_used_bytes"]),
                        pct: pickNum(s, ["blk" + bi + "p" + pj + "_pct"]),
                        fstype: pick(s, ["blk" + bi + "p" + pj + "_fstype"]),
                        plabel: pick(s, ["blk" + bi + "p" + pj + "_label"]),
                        mount: pick(s, ["blk" + bi + "p" + pj + "_mount"])
                    }
                };
                newParts[pname] = prec;
                plist.push(pname);
                pc++;
            }
            dn.extra.parts = plist;
        }
        var pChanged = partCount !== _countKeys(newParts);
        if (!pChanged) {
            for (var pk2 in newParts) {
                if (parts[pk2] === undefined) { pChanged = true; break }
            }
        }
        parts = newParts;
        partCount = _countKeys(newParts);

        // ---- flows ----
        var fl = {};
        var fr = {};
        _setFlow(s, fl, fr, "net_eth", _ifname.net_eth, dt, "B/s", "nic");
        _setFlow(s, fl, fr, "net_wifi", _ifname.net_wifi, dt, "B/s", "nic");
        _setFlow(s, fl, fr, "nvme0", "nvme0", dt, "B/s", "nvme");
        _setFlow(s, fl, fr, "nvme1", "nvme1", dt, "B/s", "nvme");
        _setFlow(s, fl, fr, "flash_kingston", "sda", dt, "B/s", "blk");
        // gpu/cpu activity links (non-byte units stay out of `flows`)
        _setActivity(fr, "gpu_arc", "gpu_arc", "machine", pickNum(s, ["dev_gpu0_pct", "i_util"]), "%",
                     pickNum(s, ["dev_gpu0_mhz", "i_freq_mhz"]), "MHz");
        _setActivity(fr, "gpu_apu", "gpu_apu", "machine", pickNum(s, ["dev_gpu1_pct", "a_util"]), "%",
                     pickNum(s, ["dev_gpu1_mhz", "a_freq_mhz"]), "MHz");
        _setActivity(fr, "gpu_apu_pw", "gpu_apu", "machine", pickNum(s, ["dev_gpu1_pw", "a_pwr_w"]), "W", unknown, "");
        _setActivity(fr, "cpu_pkg0", "cpu_pkg0", "machine", pct, "%", unknown, "");
        // display link states (unit "str" — connectivity, not throughput)
        var dsp = ["disp_dp1", "disp_dp2", "disp_hdmi3"];
        for (var xi = 0; xi < 3; xi++) {
            fr[dsp[xi]] = { a: "gpu_arc", b: dsp[xi], rate: unknown, unit: "str",
                            rx: unknown, tx: unknown,
                            active: nd[dsp[xi]].state === "connected" };
        }
        // mem flow: no per-DIMM counter exists in the contract -> stays unknown
        fr.mem = { a: "mem", b: "machine", rate: unknown, unit: "kB/s",
                   rx: unknown, tx: unknown, active: false };
        flows = fl;
        flowRates = fr;

        // ---- edge state/bw update ----
        for (var ei = 0; ei < _edgeLive.length; ei++) {
            var ed = _edgeLive[ei];
            var f = ed.flow !== "" ? fr[ed.flow] : undefined;
            if (f !== undefined) {
                ed.rate = f.rate;
                ed.active = f.active === true;
                if (f.rate !== unknown && f.unit === "B/s")
                    ed.bw = fmtB(f.rate);
                else if (f.rate !== unknown)
                    ed.bw = String(Math.round(f.rate)) + " " + f.unit;
                else
                    ed.bw = unknown;
            } else {
                var na = nd[ed.a], nb2 = nd[ed.b];
                var upA = na !== undefined && (na.state === "up" || na.state === "present" || na.state === "connected" || na.state === "mounted");
                var upB = nb2 !== undefined && (nb2.state === "up" || nb2.state === "present" || nb2.state === "connected" || nb2.state === "mounted");
                ed.active = upA && upB;
                // bw stays live-or-unknown; static negotiated spec lives on
                // the child node as extra.linkSpec / extra.speedSpec.
                ed.bw = (nb2 !== undefined && nb2.link !== unknown) ? nb2.link : unknown;
            }
        }

        _publish(pChanged);
        statsRev++;
    }

    function _countKeys(o) {
        var c = 0;
        for (var k in o) c++;
        return c;
    }

    // Byte-rate flow: rx/tx (or rd/wr) -> flows[id] + flowRates entry.
    function _setFlow(s, fl, fr, fid, tag, dt, unit, kind) {
        var rx = unknown, tx = unknown;
        if (kind === "nic") {
            rx = pickNum(s, ["dev_nic_" + tag + "_rx"]);
            tx = pickNum(s, ["dev_nic_" + tag + "_tx"]);
            if (rx === unknown && fid === "net_eth")
                rx = _counterRate(s, "net_rx", dt);   // legacy aggregate fallback
            if (tx === unknown && fid === "net_eth")
                tx = _counterRate(s, "net_tx", dt);
        } else if (kind === "nvme") {
            var idx = tag === "nvme0" ? 0 : 1;
            tx = pickNum(s, ["dev_nvme" + idx + "_wr"]);   // host<-disk read is ab
            rx = pickNum(s, ["dev_nvme" + idx + "_rd"]);
            // direction: rd = a->b data-out of the drive, wr = b->a
        } else {
            rx = pickNum(s, ["dev_" + tag + "_rd"]);
            tx = pickNum(s, ["dev_" + tag + "_wr"]);
        }
        var rate = unknown;
        if (rx !== unknown || tx !== unknown)
            rate = (rx === unknown ? 0 : rx) + (tx === unknown ? 0 : tx);
        var active = rate !== unknown && rate > 0;
        if (rate !== unknown)
            fl[fid] = rate;
        fr[fid] = { a: fid, b: "machine", rate: rate, unit: unit,
                    rx: rx, tx: tx, active: active };
    }

    // Non-byte activity link (%, MHz, W): recorded in flowRates only.
    function _setActivity(fr, fid, a, b, rate, unit, altRate, altUnit) {
        var r = rate;
        var u = unit;
        if (r === unknown && altRate !== unknown) {
            r = altRate;
            u = altUnit;
        }
        fr[fid] = { a: a, b: b, rate: r, unit: u,
                    rx: unknown, tx: unknown,
                    active: r !== unknown && r > 0 };
    }

    // Reassign container props so bindings re-evaluate; node objects keep
    // identity across frames so imperative lookups stay cheap.
    function _publish(schemaChanged) {
        var nd = _nodesLive;
        var out = {};
        var list = [];
        for (var i = 0; i < _order.length; i++) {
            var id = _order[i];
            out[id] = nd[id];
            list.push(nd[id]);
        }
        nodes = out;
        nodeList = list;
        nodeCount = list.length;
        var el = [];
        for (var e2 = 0; e2 < _edgeLive.length; e2++)
            el.push(_edgeLive[e2]);
        edges = el;
        edgeCount = el.length;
        if (schemaChanged)
            schemaRev++;
    }
}

