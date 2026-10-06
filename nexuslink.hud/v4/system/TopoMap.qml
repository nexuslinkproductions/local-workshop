pragma ComponentBehavior: Bound

import QtQuick
import ".."

// TopoMap.qml — the DEV-BAY hero: USB/PCIe device topology as a node-link
// map. Left column = xHCI controller cards, middle = devices hanging off
// root-hub ports (+ hub cards), right = hub fan-out + stray devices, joined
// by azure spine lines with port labels.
//
// Ground truth: SysPoll.usbDevs (sysfs devpath/vid:pid/speed) + the Topology
// scaffold for curated names/vitals + pactl rows for attached PipeWire
// endpoints. A device appears/vanishes with its sysfs devpath — hotplug is
// live at the usb poll cadence.
Item {
    id: root

    property var poll: null          // SysPoll instance
    property var stats: ({})         // collector frame (bt links, batt state)

    readonly property var model: _plates
    readonly property var ctrls: _ctrls
    property var _plates: []
    property var _ctrls: []
    property var _links: []          // spine segments for the canvas
    property string metaText: ""
    property string _sig: ""

    // ---------------- live data helpers -------------------------------
    function _vpNodes() {
        var m = {};
        var nl = Topology.nodeList;
        for (var i = 0; i < nl.length; i++) {
            var vp = nl[i].extra !== undefined ? nl[i].extra.vidPid : undefined;
            if (vp !== undefined)
                m[vp] = nl[i];
        }
        return m;
    }

    // pactl rows whose bus_path resolves to this devpath
    function pwRows(dp) {
        var out = [];
        var all = (poll !== null ? poll.sinks.concat(poll.sources) : []);
        for (var i = 0; i < all.length; i++) {
            if (poll.busLabel(all[i].busPath, all[i].bus) === "usb " + dp)
                out.push(all[i]);
        }
        return out;
    }

    function _cleanName(raw) {
        var s = String(raw || "");
        s = s.replace(/\s+\d+-\d[\d.]*/g, "");      // drop port paths
        var paren = /\(+([^()]*)\)+/.exec(s);
        var base = s.replace(/\(.*\)/, "").trim();
        var name = base;
        // "Logitech USB receiver (G502 X PLUS)" -> "Logitech G502 X PLUS"
        if (paren !== null && /^Logitech/i.test(base))
            name = base.split(" ")[0] + " " + paren[1].trim();
        return name.toUpperCase();
    }

    function _speedClass(sp) {
        var n = Number(sp);
        if (!isFinite(n)) return "";
        if (n >= 10000) return "SS+";
        if (n >= 5000) return "SS";
        if (n >= 480) return "HS";
        if (n >= 12) return "FS";
        return "LS";
    }

    function _devCode(dp, hub) {
        var flat = String(dp).replace(/[-.]/g, "");
        return (hub ? "HUB-" : "DEV-") + flat;
    }

    // label:value detail lines per device class — all live-fed, "—" where
    // the source is absent.
    function _lines(dp, rec, node, rows, childNames, nChild) {
        var cls = node !== null && node.extra !== undefined ? String(node.extra.cls) : "";
        var out = [];
        function L(l, v, vc) { out.push({ "l": l, "v": v, "vc": vc }); }
        var up = String(root.stats.dev_nic_wlp16s0_up || "");
        switch (cls) {
        case "usb_camera": {
            L("uvc", "webcam + stereo mic");
            var mic = null;
            for (var i = 0; i < rows.length; i++)
                if (rows[i].bus !== undefined && rows[i].name !== undefined && rows[i].name.indexOf("alsa_input") === 0)
                    mic = rows[i];
            if (mic !== null)
                L("mic", mic.fmt + " " + mic.ch + "ch " + Math.round(Number(mic.rate) / 1000) + "k  " + mic.state,
                  mic.state === "RUNNING" ? FuiTokens.acid : undefined);
            else
                L("mic", FuiTokens.unknownGlyph);
            L("stream", rows.some(function (r) { return r.state === "RUNNING"; }) ? "live" : "none");
            break;
        }
        case "usb_receiver": {
            var sink = null, src = null;
            for (var j = 0; j < rows.length; j++) {
                if (rows[j].name.indexOf("alsa_output") === 0)
                    sink = rows[j];
                else if (rows[j].name.indexOf("alsa_input") === 0)
                    src = rows[j];
            }
            var batt = node !== null && node.extra !== undefined ? node.extra.batt_pct : undefined;
            if (sink !== null || src !== null) {
                var def = poll !== null && sink !== null && sink.name === poll.defSink;
                L("headset", (def ? "DEFAULT SINK" : "audio") + "  " + (sink !== null ? sink.state : FuiTokens.unknownGlyph),
                  sink !== null && sink.state === "RUNNING" ? FuiTokens.acid : undefined);
                if (sink !== null)
                    L("out", sink.fmt + " " + sink.ch + "ch " + Math.round(Number(sink.rate) / 1000) + "k");
                if (src !== null)
                    L("mic", src.name.substr(src.name.lastIndexOf(".") + 1) + " " + src.state);
            } else if (batt !== undefined && batt !== null && isFinite(Number(batt))) {
                L("via", "LIGHTSPEED receiver");
                var bs = String(root.stats.bat0_state || "").toLowerCase();
                L("battery", Math.round(Number(batt)) + "%" + (bs !== "" ? "  " + bs.toUpperCase() : ""));
                L("low zone", "0-15%");
            } else {
                L("class", "wireless receiver");
            }
            break;
        }
        case "usb_keyboard":
            L("class", "HID keyboard, wired");
            L("battery", "bus powered");
            break;
        case "usb_rgb":
            L("class", "HID lighting controller");
            L("drv", "usbhid");
            break;
        case "usb_bluetooth": {
            var nb = root.stats.dev_bt_conn;
            L("bluetooth", (nb !== undefined ? String(nb) : FuiTokens.unknownGlyph) + " connected links");
            var wl = Topology.node("nic_wifi");
            var wst = wl !== undefined && wl.state !== Topology.unknown ? String(wl.state).toUpperCase() : up;
            var lp = wl !== undefined && wl.link !== Topology.unknown ? String(wl.link).split("@") : [];
            L("wlan", "wlp16s0 " + (wst !== "" ? wst : FuiTokens.unknownGlyph) + "  pci 10:00.0");
            L("802.11ax", "combo" + (lp.length === 2 ? "  Gen" + lp[1] + " " + lp[0] : ""));
            break;
        }
        case "usb_hub": {
            var sp = _speedClass(rec.speed);
            L(sp === "" ? "hub" : sp, String(rec.speed) + "M  " + nChild + " downstream");
            // sibling hub on the other bus (HS/SS companion pair)
            L("ports", dp + ".1-" + dp + "." + Math.max(1, nChild));
            if (childNames.length > 0)
                L("fan-out", childNames.join(", "));
            break;
        }
        case "usb_storage": {
            L("class", "usb storage");
            var blk = node !== null && node.extra !== undefined ? node.extra.blk : undefined;
            if (blk !== undefined)
                L("dev", String(blk));
            var pl = node !== null && node.extra !== undefined ? node.extra.parts : undefined;
            if (pl !== undefined && pl.length > 0)
                L("parts", String(pl.length));
            break;
        }
        default: {
            // no scaffold leaf — audio card inference first, else generic
            if (rows.length > 0) {
                var io = [], run = 0, rate = "";
                for (var k = 0; k < rows.length; k++) {
                    var m = /HiFi__(\w+)__(sink|source)/.exec(rows[k].name);
                    if (m !== null)
                        io.push(m[1] + " " + (m[2] === "sink" ? "out" : "in"));
                    if (rows[k].state === "RUNNING")
                        run++;
                    if (rate === "" && rows[k].rate !== "")
                        rate = Math.round(Number(rows[k].rate) / 1000) + " kHz";
                }
                var sn = null;
                for (var k2 = 0; k2 < rows.length; k2++) {
                    var sm = /_([A-Z0-9]{6,})-\d\d\./.exec(rows[k2].name);
                    if (sm !== null) { sn = sm[1]; break; }
                }
                if (sn !== null)
                    L("sn", sn);
                if (io.length > 0)
                    L("io", io.join(", "));
                L("state", run + "/" + rows.length + " RUNNING" + (rate !== "" ? "  " + rate : ""),
                  run > 0 ? FuiTokens.acid : undefined);
            } else {
                L("class", "usb device");
                if (rec.mfr !== "")
                    L("mfr", rec.mfr);
            }
            break;
        }
        }
        return out.slice(0, 3);
    }

    function _stateTag(dp, rec, node, rows, nChild) {
        var cls = node !== null && node.extra !== undefined ? String(node.extra.cls) : "";
        if (cls === "usb_bluetooth")
            return (root.stats.dev_bt_conn !== undefined ? String(root.stats.dev_bt_conn) : FuiTokens.unknownGlyph) + " LINKS";
        if (cls === "usb_hub")
            return nChild + " DN";
        var sink = null;
        for (var i = 0; i < rows.length; i++)
            if (rows[i].name.indexOf("alsa_output") === 0)
                sink = rows[i];
        if (sink !== null && poll !== null && sink.name === poll.defSink && sink.state === "RUNNING")
            return "LIVE";
        var batt = node !== null && node.extra !== undefined ? node.extra.batt_pct : undefined;
        if (batt !== undefined && batt !== null && isFinite(Number(batt)))
            return Math.round(Number(batt)) + "%";
        if (rows.length > 0) {
            var ni = 0, no = 0;
            for (var r = 0; r < rows.length; r++) {
                if (rows[r].name.indexOf("alsa_input") === 0) ni++;
                else if (rows[r].name.indexOf("alsa_output") === 0) no++;
            }
            if (ni + no > 0)
                return ni + "IN/" + no + "OUT";
        }
        return "ONLINE";
    }

    function _isLive(dp, rows) {
        for (var i = 0; i < rows.length; i++)
            if (poll !== null && rows[i].name === poll.defSink && rows[i].state === "RUNNING")
                return true;
        return false;
    }

    // natural devpath order: ["6-6.10"] > ["6-6.2"]
    function _cmpDp(a, b) {
        var pa = a.split("-")[1].split("."), pb = b.split("-")[1].split(".");
        var na = Number(a.split("-")[0]), nb = Number(b.split("-")[0]);
        if (na !== nb)
            return na - nb;
        for (var i = 0; i < Math.max(pa.length, pb.length); i++) {
            var x = i < pa.length ? Number(pa[i]) : -1;
            var y = i < pb.length ? Number(pb[i]) : -1;
            if (x !== y)
                return x - y;
        }
        return 0;
    }

    // ---------------- model build -------------------------------------
    function rebuild() {
        if (poll === null)
            return;
        var devs = poll.usbDevs;
        var vpMap = _vpNodes();
        var buses = poll.usbBuses;

        // controllers: xhci scaffold nodes owning roothub buses
        var ctrls = [], ctrlOfBus = {};
        var nl = Topology.nodeList;
        for (var i = 0; i < nl.length; i++) {
            var nd = nl[i];
            if (nd.extra === undefined || nd.extra.cls !== "xhci")
                continue;
            var c = { "id": nd.id, "node": nd, "buses": [], "devs": [], "code": "", "bdf": nd.extra.bdf || "" };
            var ch = Topology.childIds(nd.id);
            for (var ci = 0; ci < ch.length; ci++) {
                var cn = Topology.node(ch[ci]);
                if (cn !== undefined && cn.extra !== undefined && cn.extra.cls === "usb_roothub") {
                    var bnum = cn.id.substr(3);
                    c.buses.push(bnum);
                    ctrlOfBus[bnum] = c;
                }
            }
            ctrls.push(c);
        }
        // any bus with devices but no scaffold ctrl -> pseudo card
        for (var dp in devs) {
            var bn = dp.split("-")[0];
            if (ctrlOfBus[bn] === undefined) {
                var pc = { "id": "xhci_" + bn, "node": null, "buses": [bn], "devs": [], "code": "", "bdf": buses[bn] !== undefined ? buses[bn].bdf : "" };
                ctrlOfBus[bn] = pc;
                ctrls.push(pc);
            }
            ctrlOfBus[bn].devs.push(dp);
        }
        ctrls = ctrls.filter(function (c) { return c.devs.length > 0; });
        ctrls.sort(function (a, b) { return b.devs.length - a.devs.length; });
        for (var k = 0; k < ctrls.length; k++)
            ctrls[k].code = "XHC-" + String.fromCharCode(65 + k);

        // classify devpaths: hub = any other path starts with dp + "."
        var dps = Object.keys(devs).sort(_cmpDp);
        var isHub = {};
        for (var d1 = 0; d1 < dps.length; d1++)
            for (var d2 = 0; d2 < dps.length; d2++)
                if (dps[d2].indexOf(dps[d1] + ".") === 0) { isHub[dps[d1]] = true; break; }

        // col1 (root attach, non-hub first then hubs per ctrl) + col2 (hub
        // children, then strays without a port)
        var c1 = [], c2 = [], claimed = {};
        for (var g = 0; g < ctrls.length; g++) {
            var nonhub = ctrls[g].devs.filter(function (d) { return isHub[d] !== true && d.indexOf(".") < 0; }).sort(_cmpDp);
            var hubs = ctrls[g].devs.filter(function (d) { return isHub[d] === true; }).sort(_cmpDp);
            for (var h1 = 0; h1 < nonhub.length; h1++) { c1.push({ "dp": nonhub[h1], "ctrl": g }); claimed[nonhub[h1]] = true; }
            for (var h2 = 0; h2 < hubs.length; h2++) { c1.push({ "dp": hubs[h2], "ctrl": g, "hub": true }); claimed[hubs[h2]] = true; }
        }
        for (var d3 = 0; d3 < dps.length; d3++) {
            if (claimed[dps[d3]] === true)
                continue;
            if (dps[d3].indexOf(".") >= 0)
                c2.push({ "dp": dps[d3], "hubChild": true });
            else
                c2.push({ "dp": dps[d3] });   // stray root port on unmapped ctrl
        }
        // unmatchedUsb entries with no sysfs devpath (collector saw them,
        // sysfs map didn't) — the honest tail of the map.
        var un = Topology.unmatchedUsb;
        for (var u = 0; u < un.length; u++) {
            var found = false;
            for (var dd = 0; dd < dps.length; dd++)
                if (devs[dps[dd]].vidpid === un[u].vidpid) { found = true; break; }
            if (!found)
                c2.push({ "dp": "", "un": un[u] });
        }

        // ---- assemble logical plates ----------------------------------
        var plates = [], sigParts = [];
        function mkPlate(spec, col) {
            var dp = spec.dp;
            if (dp === "") {
                return { "col": col, "ctrl": -1, "dp": "", "code": "DEV-??", "port": FuiTokens.unknownGlyph,
                         "vidpid": spec.un.vidpid, "speed": "", "name": String(spec.un.name).toUpperCase(),
                         "lines": [{ "l": "class", "v": "usb device (no sysfs port)" }],
                         "state": "ONLINE", "live": false,
                         "gauge": spec.un.batt !== undefined && isFinite(Number(spec.un.batt)) ? "batt" : "none",
                         "mbps": null, "batt": spec.un.batt !== undefined && isFinite(Number(spec.un.batt)) ? Number(spec.un.batt) : null };
            }
            var rec = devs[dp];
            var node = vpMap[rec.vidpid] !== undefined ? vpMap[rec.vidpid] : null;
            var rows = pwRows(dp);
            var hub = isHub[dp] === true;
            var kids = dps.filter(function (d) { return d.indexOf(dp + ".") === 0; });
            var knames = [];
            for (var kk = 0; kk < kids.length; kk++) {
                var kn = vpMap[devs[kids[kk]].vidpid];
                knames.push(kn !== undefined ? _cleanName(kn.label).split(" ")[0].toLowerCase()
                                           : String(devs[kids[kk]].prod).split(" ")[0].toLowerCase());
            }
            var nm;
            if (node !== null)
                nm = _cleanName(node.label);
            else
                nm = (rec.mfr !== "" && rec.prod.toUpperCase().indexOf(rec.mfr.toUpperCase()) < 0
                      ? rec.mfr + " " + rec.prod : rec.prod) || rec.vidpid;
            nm = String(nm).toUpperCase();
            var batt = node !== null && node.extra !== undefined ? node.extra.batt_pct : undefined;
            return { "col": col, "ctrl": spec.ctrl !== undefined ? spec.ctrl : -1, "dp": dp,
                     "code": _devCode(dp, hub), "port": dp, "vidpid": rec.vidpid,
                     "speed": _speedClass(rec.speed), "name": nm,
                     "lines": _lines(dp, rec, node, rows, knames, kids.length),
                     "state": _stateTag(dp, rec, node, rows, kids.length),
                     "live": _isLive(dp, rows),
                     "gauge": batt !== undefined && isFinite(Number(batt)) ? "batt" : "link",
                     "mbps": rec.speed !== "" ? Number(rec.speed) : null,
                     "batt": batt !== undefined && isFinite(Number(batt)) ? Number(batt) : null };
        }
        for (var p1 = 0; p1 < c1.length; p1++)
            plates.push(mkPlate(c1[p1], 0));
        for (var p2 = 0; p2 < c2.length; p2++)
            plates.push(mkPlate(c2[p2], 1));

        var sig = "";
        for (var s = 0; s < plates.length; s++)
            sig += plates[s].dp + plates[s].code + plates[s].state + plates[s].batt + plates[s].live
                   + JSON.stringify(plates[s].lines) + ";";
        for (var s2 = 0; s2 < ctrls.length; s2++)
            sig += ctrls[s2].code + ctrls[s2].devs.length + ";";
        if (sig !== _sig) {
            _sig = sig;
            _logPlates = plates;
            _logCtrls = ctrls;
        }
        layout();
    }
    property var _logPlates: []
    property var _logCtrls: []

    // ---------------- layout ------------------------------------------
    function layout() {
        var plates = _logPlates, ctrls = _logCtrls;
        var w = width, h = height;
        var col0w = Math.min(232, Math.round(w * 0.205));
        var spineX = col0w + 30;
        var c1x = spineX + 28;
        var c1w = Math.round(w * 0.335);
        var hspX = c1x + c1w + 24;
        var c2x = hspX + 24;
        var c2w = w - c2x - 2;

        var n1 = 0, n2 = 0;
        for (var i = 0; i < plates.length; i++)
            if (plates[i].col === 0) n1++; else n2++;
        var rows = Math.max(1, n1, n2);
        var rowH = Math.min(136, (h - (rows - 1) * 14) / rows);
        var pitch = rowH + 14;
        function mid(r) { return r * pitch + rowH / 2; }

        var out = [], r1 = 0, r2 = 0, links = [];
        for (var q = 0; q < plates.length; q++) {
            var p = plates[q];
            if (p.col === 0) {
                p.x = c1x; p.y = r1 * pitch; p.w = c1w; p.h = rowH; p.row = r1++;
            } else {
                p.x = c2x; p.y = r2 * pitch; p.w = c2w; p.h = rowH; p.row = r2++;
            }
            out.push(p);
        }

        // controller cards: first gets the tall card, the rest bottom-stack
        var cards = [];
        var busMap = poll !== null ? poll.usbBuses : {};
        // port -> plate lookup so cards can print real per-port occupancy
        var plateByDp = {};
        for (var pi = 0; pi < out.length; pi++)
            if (out[pi].dp !== "")
                plateByDp[out[pi].dp] = out[pi];
        for (var c = 0; c < ctrls.length; c++) {
            var cr = ctrls[c];
            var big = c === 0 && cr.devs.length >= 3;
            var node = cr.node;
            var nm = node !== null ? String(node.label).replace(/\s*\(.*\)\s*$/, "") : "USB CONTROLLER " + cr.buses.join("/");
            var lines = [];
            var busTxt = [];
            for (var b = 0; b < cr.buses.length; b++) {
                var bb = busMap[cr.buses[b]];
                busTxt.push(cr.buses[b] + " " + (bb !== undefined && bb.speed !== "" ? _speedClass(bb.speed) + " " + bb.speed + "M" : ""));
            }
            lines.push({ "l": "bus", "v": busTxt.join(" | ") });
            var link = node !== null ? node.link : Topology.unknown;
            if (link !== Topology.unknown) {
                var parts = String(link).split("@");      // "x1@4" -> Gen4 x1
                lines.push({ "l": "pcie", "v": "Gen" + parts[1] + " " + parts[0] });
            }
            var ports = cr.devs.filter(function (d) { return d.indexOf(".") < 0; }).sort(_cmpDp);
            if (big) {
                // real per-port detail: dp -> device name (or hub fan-out)
                for (var pp = 0; pp < ports.length && pp < 8; pp++) {
                    var pl = plateByDp[ports[pp]];
                    lines.push({ "l": "port " + ports[pp],
                                 "v": pl !== undefined ? pl.name.toLowerCase() : "hub" });
                }
                if (ports.length > 8)
                    lines.push({ "l": "ports", "v": "+ " + (ports.length - 8) + " more" });
            }
            lines.push({ "l": "devices", "v": String(cr.devs.length) });
            // content-fit height: header ~86 + per-line 17 + temp strip 58
            var hasTemp = c === 0 && poll !== null && poll.ctlTemp !== null;
            var ch2 = Math.min(big ? 330 : 150,
                               Math.max(104, 90 + lines.length * 17 + (hasTemp ? 58 : 0)));
            var cy = c === 0 ? 0 : Math.max(0, h - ch2 - (c - 1) * (136 + 16));
            cards.push({ "code": cr.code, "pci": String(cr.bdf), "name": nm.toUpperCase(),
                         "lines": lines, "x": 4, "y": cy, "w": col0w - 8, "h": ch2,
                         "temp": hasTemp ? poll.ctlTemp : null,
                         "ctrlIdx": c });

            // spine: vertical line at spineX over this ctrl's col1 rows +
            // stub + port label per device
            var rows0 = [], rows1 = [];
            for (var q2 = 0; q2 < out.length; q2++) {
                var pl = out[q2];
                if (pl.col !== 0 || pl.ctrl !== c)
                    continue;
                rows0.push(pl.row);
            }
            if (rows0.length > 0) {
                var mn = Math.min.apply(null, rows0), mx = Math.max.apply(null, rows0);
                links.push({ "x0": spineX, "y0": mid(mn), "x1": spineX, "y1": mid(mx), "v": true });
                for (var q3 = 0; q3 < out.length; q3++) {
                    var pl2 = out[q3];
                    if (pl2.col !== 0 || pl2.ctrl !== c)
                        continue;
                    var yy = mid(pl2.row);
                    links.push({ "x0": col0w - 8 + 6, "y0": yy, "x1": pl2.x, "y1": yy, "dot": true, "dotX": spineX,
                                 "label": pl2.dp, "lx": (col0w + pl2.x) / 2 + 4, "ly": yy - 5 });
                }
            }
        }

        // hub fan-out: hub card right edge -> hspX vline -> child stubs
        var hubRows = {};
        for (var q4 = 0; q4 < out.length; q4++) {
            var hp = out[q4];
            if (hp.col !== 0)
                continue;
            for (var q5 = 0; q5 < out.length; q5++) {
                var cp = out[q5];
                if (cp.col === 1 && cp.dp !== "" && cp.dp.indexOf(hp.dp + ".") === 0) {
                    if (hubRows[hp.dp] === undefined)
                        hubRows[hp.dp] = { "row": hp.row, "kids": [] };
                    hubRows[hp.dp].kids.push(cp);
                }
            }
        }
        for (var hd in hubRows) {
            var hb = hubRows[hd];
            var hy = mid(hb.row);
            links.push({ "x0": c1x + c1w, "y0": hy, "x1": hspX, "y1": hy });
            var kms = hb.kids.map(function (p) { return p.row; });
            var kmin = Math.min.apply(null, kms), kmax = Math.max.apply(null, kms);
            if (kmin !== kmax || hb.kids.length > 0)
                links.push({ "x0": hspX, "y0": mid(kmin), "x1": hspX, "y1": mid(kmax), "v": true });
            for (var q6 = 0; q6 < hb.kids.length; q6++) {
                var kid = hb.kids[q6];
                var ky = mid(kid.row);
                links.push({ "x0": hspX, "y0": ky, "x1": kid.x, "y1": ky, "dot": true, "dotX": hspX,
                             "label": kid.dp, "lx": hspX + 10, "ly": ky - 5 });
            }
        }
        // strays in col2 with no parent hub: dashed stub from c1 gutter
        for (var q7 = 0; q7 < out.length; q7++) {
            var st = out[q7];
            if (st.col === 1 && (st.dp === "" || !Object.keys(hubRows).some(function (h) { return st.dp.indexOf(h + ".") === 0; }))) {
                var sy = mid(st.row);
                links.push({ "x0": c1x + c1w + 6, "y0": sy, "x1": st.x, "y1": sy, "dash": true,
                             "label": st.dp !== "" ? st.dp : "??", "lx": (c1x + c1w + st.x) / 2, "ly": sy - 5 });
            }
        }

        _plates = out;
        _ctrls = cards;
        _links = links;
        spine.requestPaint();

        var ndev = out.length;
        metaText = ndev + " usb device" + (ndev === 1 ? "" : "s") + ", " + cards.length + " xhci";
    }

    Component.onCompleted: rebuild()
    onWidthChanged: layout()
    onHeightChanged: layout()

    Connections {
        target: root.poll
        ignoreUnknownSignals: true
        function onUpdated() { root.rebuild(); }
    }
    Connections {
        target: Topology
        function onStatsRevChanged() { root.rebuild(); }
        function onSchemaRevChanged() { root.rebuild(); }
    }

    // ---------------- painting ----------------------------------------
    Canvas {
        id: spine
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var az = FuiTokens.css(FuiTokens.azure);
            ctx.strokeStyle = az;
            ctx.lineWidth = FuiTokens.lwHair;
            var L = root._links;
            for (var i = 0; i < L.length; i++) {
                var s = L[i];
                ctx.globalAlpha = 0.7;
                ctx.setLineDash(s.dash === true ? [3, 3] : []);
                ctx.beginPath();
                ctx.moveTo(s.x0, s.y0); ctx.lineTo(s.x1, s.y1);
                ctx.stroke();
                ctx.setLineDash([]);
                if (s.dot === true) {
                    ctx.fillStyle = az;
                    ctx.beginPath(); ctx.arc(s.dotX, s.y0, 2.5, 0, Math.PI * 2); ctx.fill();
                }
                if (s.label !== undefined && s.label !== "") {
                    ctx.fillStyle = az;
                    ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                    ctx.textAlign = "center";
                    ctx.fillText(String(s.label), s.lx, s.ly);
                }
            }
            ctx.globalAlpha = 1;
        }
    }

    Repeater {
        model: root._ctrls
        delegate: CtrlCard {
            required property var modelData
            x: modelData.x; y: modelData.y
            width: modelData.w; height: modelData.h
            code: modelData.code
            pci: modelData.pci
            name: modelData.name
            lines: modelData.lines
            temp: modelData.temp
        }
    }

    Repeater {
        model: root._plates
        delegate: DevPlate {
            required property var modelData
            x: modelData.x; y: modelData.y
            width: modelData.w; height: modelData.h
            code: modelData.code
            port: modelData.port
            vidpid: modelData.vidpid
            speed: modelData.speed
            name: modelData.name
            lines: modelData.lines
            stateTag: modelData.state
            live: modelData.live
            gauge: modelData.gauge
            mbps: modelData.mbps
            battPct: modelData.batt
        }
    }

    Text {
        visible: root._plates.length === 0
        anchors.centerIn: parent
        text: "awaiting usb scan"
        color: FuiTokens.faint
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.body
    }
}
