pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// SysPoll.qml — the system deck's poller hub. Same discipline as
// DockState.qml: no per-cell timers; the deck calls tick() once per stats
// frame (~1 Hz) and each poll fires only when its wall-clock period elapsed.
// Everything is additionally gated on `live` (deck visibility) so a hidden
// deck costs zero spawns.
//
// The collector already emits dev_audio*/dev_src* names+vols but not
// PipeWire state/format/rate or the USB port path — those come from pactl
// and /sys here, matching the design sheet's documented sources.
QtObject {
    id: poll

    property bool live: true          // gate: deck `shown`

    // pactl: sinks / sources (monitors excluded, counted separately)
    property var sinks: []            // [{id,state,name,desc,fmt,ch,rate,bus,busPath,vol}]
    property var sources: []          // same shape, monitor taps excluded
    property int monitorCount: 0
    property string defSink: ""
    property string defSource: ""

    // /sys/bus/usb ground truth
    property var usbDevs: ({})        // devpath "6-6.2" -> {vidpid,speed,prod,mfr}
    property var usbBuses: ({})       // busnum 6 -> {speed,bdf}
    property var ctlTemp: null        // prom21 xhci die temp (C) or null
    property var dimmLim: null        // [high,crit] °C from spd5118 or null

    // network + ledger
    property var ifAddrs: ({})        // ifname -> "192.168.0.112/24"
    property string powerProfile: ""
    property var night: null          // {enabled,temp} | null = unreadable
    property string dnd: ""           // "on"|"off"|"" unknown
    property string omarchyVer: ""

    // hyprctl monitors: name -> focused workspace id; focused = monitor name
    property var monActive: ({})
    property string monFocused: ""
    property var monGeom: ({})        // name -> "1920x1200 @ -1920,0"

    signal updated()

    // ------------------------------------------------------------------
    // parsers
    // pactl list block -> row record
    function _pwBlock(blk, isSrc) {
        var rows = [];
        var parts = blk.split(/\n(?=\S)/);   // blocks start at col 0
        for (var i = 0; i < parts.length; i++) {
            var b = parts[i];
            var mHead = /^(Sink|Source)\s*#(\d+)/.exec(b);
            if (mHead === null)
                continue;
            var rec = { "id": mHead[2], "state": "", "name": "", "desc": "",
                        "fmt": "", "ch": "", "rate": "", "bus": "",
                        "busPath": "", "vol": "", "monitor": false };
            var m;
            if ((m = /^\s*State:\s*(\S+)/m.exec(b))) rec.state = m[1];
            if ((m = /^\s*Name:\s*(\S+)/m.exec(b))) rec.name = m[1];
            if ((m = /^\s*Description:\s*(.+)$/m.exec(b))) rec.desc = m[1].trim();
            if ((m = /Sample Specification:\s*(\S+)\s+(\d+)ch\s+(\d+)Hz/.exec(b))) {
                rec.fmt = m[1]; rec.ch = m[2]; rec.rate = m[3];
            }
            if ((m = /^\s*device\.bus = "([^"]*)"/m.exec(b))) rec.bus = m[1];
            if ((m = /^\s*device\.bus_path = "([^"]*)"/m.exec(b))) rec.busPath = m[1];
            if ((m = /^\s*device\.name = "([^"]*)"/m.exec(b))) rec.card = m[1];
            if ((m = /Volume:.*?\/\s*(\d+)%\s*\//m.exec(b))) rec.vol = m[1];
            if (isSrc && ((/Monitor of Sink:/.test(b) && !/Monitor of Sink:\s*n\/a/.test(b))
                          || /\.monitor$/.test(rec.name)))
                rec.monitor = true;
            rows.push(rec);
        }
        return rows;
    }

    // bus_path -> "usb <devpath>" | "pci <bdf>" | "virtual"
    function busLabel(busPath, bus) {
        var bp = String(busPath || "");
        var um = /-usb-\d+:(\d+(?:\.\d+)*):/.exec(bp);
        if (um !== null) {
            var chain = um[1];
            for (var bus in usbBuses) {
                var dp = bus + "-" + chain;
                if (usbDevs[dp] !== undefined)
                    return "usb " + dp;
            }
            // fall back: the chain's first segment is the root port on some bus
            for (var bus2 in usbBuses) {
                var dp2 = bus2 + "-" + chain;
                if (String(usbBuses[bus2].bdf) !== "" && bp.indexOf(String(usbBuses[bus2].bdf)) >= 0)
                    return "usb " + dp2;
            }
            return "usb";
        }
        var pm = /^pci-0000:([0-9a-fA-F:.]+)/.exec(bp);
        if (pm !== null)
            return "pci " + pm[1];
        return bus === "pipewire" || bp === "" ? "virtual" : String(bus || "virtual");
    }

    // ------------------------------------------------------------------
    component Poll: QtObject {
        id: p
        property var argv: []
        property string sh: ""
        property int everyMs: 0
        property double lastMs: -1
        signal finished(string out)

        function pulse() {
            if (!poll.live || proc.running)
                return;
            proc.command = sh !== "" ? ["bash", "-c", sh] : argv;
            if (proc.command.length === 0)
                return;
            proc.running = true;
        }
        function maybeFire(nowMs) {
            if (everyMs > 0 && (lastMs < 0 || nowMs - lastMs >= everyMs)) {
                lastMs = nowMs;
                pulse();
            }
        }
        property Process proc: Process {
            running: false
            stdout: StdioCollector {
                waitForEnd: true
                onStreamFinished: p.finished(text)
            }
        }
    }

    // ------------------------------------------------------------------
    // PipeWire sinks+sources+defaults — state/format/rate/bus_path live here.
    readonly property Poll pactlPoll: Poll {
        everyMs: 4000
        sh: 'pactl list sinks 2>/dev/null; echo "==SOURCES=="; pactl list sources 2>/dev/null; echo "==DEF=="; pactl get-default-sink 2>/dev/null; pactl get-default-source 2>/dev/null'
        onFinished: function (out) {
            var t = String(out);
            var si = t.indexOf("==SOURCES==");
            var di = t.indexOf("==DEF==");
            if (si < 0 || di < 0)
                return;
            var sk = poll._pwBlock(t.slice(0, si), false);
            var sr = poll._pwBlock(t.slice(si + 11, di), true);
            var defs = t.slice(di + 7).split("\n").map(function (s) { return s.trim(); }).filter(function (s) { return s !== ""; });
            var mons = 0, keep = [];
            for (var i = 0; i < sr.length; i++) {
                if (sr[i].monitor)
                    mons++;
                else
                    keep.push(sr[i]);
            }
            poll.sinks = sk;
            poll.sources = keep;
            poll.monitorCount = mons;
            poll.defSink = defs[0] !== undefined ? defs[0] : "";
            poll.defSource = defs[1] !== undefined ? defs[1] : "";
            poll.updated();
        }
    }

    // USB port map — devpath/vid:pid/speed/product + roothub bus->pci bdf.
    // dev_usb_*_name only proves presence; the port path lives in sysfs.
    readonly property Poll usbPoll: Poll {
        everyMs: 5000
        sh: 'for d in /sys/bus/usb/devices/*; do n="${d##*/}"; case "$n" in *:*) continue;; esac; '
            + 'v=$(cat "$d/idVendor" 2>/dev/null); [ -z "$v" ] && continue; '
            + 'b=""; case "$n" in usb*) b=$(basename "$(dirname "$(readlink -f "$d")")" | sed s/^0000://);; esac; '
            + 'printf "%s\\t%s:%s\\t%s\\t%s\\t%s\\t%s\\n" "$n" "$v" "$(cat $d/idProduct 2>/dev/null)" '
            + '"$(cat $d/speed 2>/dev/null)" "$(cat $d/manufacturer 2>/dev/null)" "$(cat $d/product 2>/dev/null)" "$b"; done; '
            + 'for h in /sys/class/hwmon/hwmon*; do n=$(cat "$h/name" 2>/dev/null); '
            + 'case "$n" in prom21*) printf "ctl_temp\\t%s\\n" "$(( $(cat $h/temp1_input 2>/dev/null) / 1000 ))";; '
            + 'spd5118*) printf "dimm_lim\\t%s\\t%s\\n" "$(( $(cat $h/temp1_max 2>/dev/null) / 1000 ))" "$(( $(cat $h/temp1_crit 2>/dev/null) / 1000 ))";; esac; done'
        onFinished: function (out) {
            var devs = {}, buses = {}, ct = null, dl = null;
            var L = String(out).split("\n");
            for (var i = 0; i < L.length; i++) {
                var c = L[i].split("\t");
                if (c.length < 3 || c[0] === "")
                    continue;
                if (c[0] === "ctl_temp") {
                    var t = Number(c[1]);
                    if (isFinite(t) && t > 0)
                        ct = t;
                } else if (c[0] === "dimm_lim") {
                    var hi = Number(c[1]), cr = Number(c[2]);
                    if (isFinite(hi) && hi > 0 && isFinite(cr))
                        dl = [hi, cr];
                } else if (c[0].substr(0, 3) === "usb") {
                    buses[c[0].substr(3)] = { "speed": c[2], "bdf": c.length > 5 ? c[5] : "" };
                } else {
                    devs[c[0]] = { "vidpid": c[1], "speed": c[2], "mfr": c[3], "prod": c[4] };
                }
            }
            poll.usbDevs = devs;
            poll.usbBuses = buses;
            poll.ctlTemp = ct;
            poll.dimmLim = dl;
            poll.updated();
        }
    }

    // interface IPv4 addresses
    readonly property Poll netPoll: Poll {
        everyMs: 30000
        sh: 'ip -o -4 addr show 2>/dev/null | awk "{print \\$2, \\$4}"'
        onFinished: function (out) {
            var addrs = {};
            var L = String(out).split("\n");
            for (var i = 0; i < L.length; i++) {
                var c = L[i].trim().split(/\s+/);
                if (c.length >= 2 && c[0] !== "lo")
                    addrs[c[0]] = c[1];
            }
            poll.ifAddrs = addrs;
            poll.updated();
        }
    }

    // ledger: power profile / night light / dnd / omarchy version
    readonly property Poll ledPoll: Poll {
        everyMs: 30000
        sh: 'printf "profile\\t"; powerprofilesctl get 2>/dev/null; echo; '
            + 'printf "night\\t"; omarchy-shell nightlight status 2>/dev/null; echo; '
            + 'printf "dnd\\t"; omarchy-shell notifications isDnd 2>/dev/null; echo; '
            + 'printf "version\\t"; omarchy-version 2>/dev/null; echo'
        onFinished: function (out) {
            var L = String(out).split("\n");
            for (var i = 0; i < L.length; i++) {
                var m = /^(\w+)\t(.*)$/.exec(L[i]);
                if (m === null)
                    continue;
                var v = m[2].trim();
                if (m[1] === "profile" && v !== "")
                    poll.powerProfile = v;
                else if (m[1] === "night") {
                    var d = null;
                    try { d = JSON.parse(v); } catch (e) { d = null; }
                    poll.night = d;
                } else if (m[1] === "dnd" && v !== "")
                    poll.dnd = v;
                else if (m[1] === "version" && v !== "")
                    poll.omarchyVer = v;
            }
            poll.updated();
        }
    }

    // focused workspace per monitor (for the ws-strip live mark)
    readonly property Poll monPoll: Poll {
        everyMs: 4000
        argv: ["hyprctl", "-j", "monitors"]
        onFinished: function (out) {
            var arr = null;
            try { arr = JSON.parse(String(out)); } catch (e) { arr = null; }
            if (!arr || typeof arr.length !== "number")
                return;
            var act = {}, foc = "", geom = {};
            for (var i = 0; i < arr.length; i++) {
                var mo = arr[i];
                if (!mo || mo.name === undefined)
                    continue;
                if (mo.activeWorkspace && mo.activeWorkspace.id !== undefined)
                    act[String(mo.name)] = Number(mo.activeWorkspace.id);
                if (mo.focused === true)
                    foc = String(mo.name);
                geom[String(mo.name)] = mo.width + "x" + mo.height + " @ " + mo.x + "," + mo.y;
            }
            poll.monActive = act;
            poll.monFocused = foc;
            poll.monGeom = geom;
            poll.updated();
        }
    }

    readonly property var polls: [pactlPoll, usbPoll, netPoll, ledPoll, monPoll]

    function tick() {
        var t = Date.now();
        for (var i = 0; i < polls.length; i++)
            polls[i].maybeFire(t);
    }

    onLiveChanged: {
        if (live) {
            for (var i = 0; i < polls.length; i++)
                polls[i].lastMs = -1;
            tick();
        }
    }
}
