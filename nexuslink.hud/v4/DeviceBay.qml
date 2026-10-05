pragma ComponentBehavior: Bound

import QtQuick

// DeviceBay.qml — HDMI-A-3 workbench DEVICES pane (lane W1, WS-07). Always
// rendered: it is the top pane of the right column, beside AppGrid, with no
// tab gate. Connected peripherals as glyph-drawn cards — Canvas pictograms,
// never emoji, never text rows:
//   mouse   = oval + scroll line + button split   (G502 X PLUS)
//   keys    = deck + key grid + spacebar          (ASUS TUF K7)
//   headset = band + cups + mic boom              (Corsair HS on Slipstream)
//   dongle  = receiver stick + plug cap + LED     (Corsair Slipstream RX)
//   cam     = lens rings + mount foot             (Razer Kiyo)
//   flash   = USB plug silhouette + shell         (Kingston DataTraveler)
//   bt      = rune + radiating arcs               (MT7922 hci0)
//   usbplug = USB trident                          (any unmatched USB device)
//   mic     = capsule + grille + body              (Scarlett Mic1, MKE600)
//
// Two card classes beyond the curated seven, both driven by keys that only
// exist while the hardware does (Topology.unmatchedUsb / .audioInputs):
// a generic card per dev_usb_<vid:pid>_name no scaffold leaf claims, and the
// audio-in pair whose dev_src{i}_src Name matches a _audioMatch token. No
// key -> no card; presence is the whole datum, never a fabricated 0.
//
// Telemetry overlay per card comes from the Topology singleton (dev_* and
// legacy stats keys are already merged there by HudV4's refresh()); raw
// `stats` keys are only a last-resort fallback. An absent vital renders
// the unknown glyph — never a fabricated 0 (BRIEF-V4-BUILD §3).
// Click a card for the vitals popover; click the dimmer or the same card
// to dismiss. No timers: cards re-evaluate when Topology republishes
// `nodes`/`flowRates` (each collector batch), the glyph repaints only when
// its tint actually changes.

Item {
    id: root

    // ---- injected by Workbench.qml ----
    property var stats: ({})

    // GlassPane reparents consumer children into its inner `content` item;
    // size to whatever parent actually hosts us (same contract as AppGrid).
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    // ---- contract module handle (same guard as Workbench.qml) ----
    readonly property var sty: (typeof Style !== "undefined") ? Style : null
    function col(key, fallback) {
        return (root.sty !== null && root.sty.c && root.sty.c[key] !== undefined) ? root.sty.c[key] : fallback;
    }
    function fs(key, fallback) {
        return (root.sty !== null && root.sty.f && root.sty.f[key] !== undefined) ? root.sty.f[key] : fallback;
    }
    QtObject {
        id: pal
        readonly property color edge: root.col("edge", "#2a3138")
        readonly property color accent: root.col("accent", "#c8f31d")
        readonly property color accent2: root.col("accent2", "#8fd8e8")
        readonly property color warn: root.col("warn", "#ffb300")
        readonly property color unknown: root.col("unknown", "#5a646c")
        readonly property color txt: root.col("txt", "#d9e2ea")
        readonly property color t55: root.col("dim", "#8b959e")
        readonly property color t40: root.col("faint", "#5f686f")
        readonly property color ink: root.col("ink", "#14171c")
        readonly property color well: root.col("recess", "#0d0f13")
        readonly property string fDisp: (root.sty !== null && root.sty.f && root.sty.f.display) ? root.sty.f.display : "Michroma"
        readonly property string fMono: (root.sty !== null && root.sty.f && root.sty.f.mono) ? root.sty.f.mono : "Kode Mono"
    }

    readonly property string unk: (root.sty !== null && root.sty.unknownGlyph !== undefined) ? root.sty.unknownGlyph : "—"

    // ============================================================ helpers
    // Topology is a registered module singleton; before its scaffold lands
    // node() just yields undefined and every vital stays unknown — honest.
    function isU(v) {
        return Topology.isUnknown(v);
    }
    function node(id) {
        return Topology.node(id);
    }
    function extra(n, k) {
        if (!n || !n.extra)
            return Topology.unknown;
        var v = n.extra[k];
        return (v === undefined || v === null) ? Topology.unknown : v;
    }
    // live link -> static negotiated spec -> unknown
    function linkOf(n) {
        if (!n)
            return unk;
        if (!isU(n.link))
            return String(n.link);
        var sp = extra(n, "speedSpec");
        if (!isU(sp))
            return String(sp);
        return unk;
    }
    // last-resort read straight off the stats frame (key -> number | sentinel)
    function snum(k) {
        var v = stats[k];
        if (v === undefined || v === "")
            return Topology.unknown;
        var n = Number(v);
        return isFinite(n) ? n : Topology.unknown;
    }
    function firstKnown() {
        for (var i = 0; i < arguments.length; i++) {
            if (!isU(arguments[i]))
                return arguments[i];
        }
        return Topology.unknown;
    }
    function mbps(link) {
        return String(link).replace(" Mb/s", "M");
    }
    // Join telemetry parts with the HUD's " · " separator. Each part is a
    // [text, known] pair: a part with no reading behind it is dropped rather
    // than printed as a dash, and a card with nothing to say at all says one
    // thing — a single unknown glyph. Without this the headset card read
    // "VOL — · —" and the radio card "×— PAIRED · ×— LINK": four dashes
    // pretending to be data. The popover still carries the full unknown map.
    function joinParts(parts) {
        var out = [];
        for (var i = 0; i < parts.length; i++) {
            if (parts[i][1])
                out.push(parts[i][0]);
        }
        return out.length > 0 ? out.join(" · ") : unk;
    }

    // ======================================================== device model
    // nodeIds[0] is the display node; the rest fold extra vitals into the
    // same card/popover (input devices, receivers, pipewire leaves).
    readonly property var devs: [
        {
            "id": "g502",
            "kind": "mouse",
            "label": "G502 X PLUS",
            "sub": "logitech lightspeed",
            "nodeIds": ["input_mouse", "rcvr_logi"]
        },
        {
            "id": "k7",
            "kind": "keys",
            "label": "TUF GAMING K7",
            "sub": "asus optical-mech",
            "nodeIds": ["kbd_asus", "input_kbd"]
        },
        {
            "id": "hs",
            "kind": "headset",
            "label": "CORSAIR HEADSET",
            "sub": "slipstream audio",
            "nodeIds": ["pw_sink_corsair", "pw_src_corsair"]
        },
        {
            "id": "rcvr",
            "kind": "dongle",
            "label": "SLIPSTREAM RX",
            "sub": "corsair receiver",
            "nodeIds": ["rcvr_corsair"]
        },
        {
            "id": "kiyo",
            "kind": "cam",
            "label": "RAZER KIYO",
            "sub": "uvc + mic",
            "nodeIds": ["cam_kiyo", "pw_src_kiyo"]
        },
        {
            "id": "flash",
            "kind": "flash",
            "label": "DATATRAVELER 3.0",
            "sub": "kingston sda",
            "nodeIds": ["flash_kingston"]
        },
        {
            "id": "bt",
            "kind": "bt",
            "label": "BT RADIO",
            "sub": "mt7922 · hci0",
            "nodeIds": ["bt_hci0", "bt_radio"]
        }
    ]

    // ---- key-backed cards: unmatched USB + the audio-in pair ---------------
    // Assembled from Topology's published lists; a record exists exactly
    // while its key exists. `live` marks key-backed presence (no node
    // folding), `gen` carries the source record, `rows` feeds the popover.
    readonly property var hotDevs: buildHotDevs(Topology.unmatchedUsb, Topology.audioInputs)
    // _audioMatch id -> the card that input earns. Only inputs a token
    // claimed get a card; the rest of the source list stays raw data.
    readonly property var audioMeta: ({
        "pw_src_scarlett": { label: "SCARLETT MIC1", sub: "focusrite 2i2 · input 1" },
        "pw_src_mke600": { label: "MKE600 VOICE", sub: "sennheiser · voice chain" }
    })
    function buildHotDevs(un, ai) {
        var out = [];
        for (var i = 0; i < un.length; i++) {
            var e = un[i];
            var rows = [{ k: "usb", v: e.name }, { k: "vid:pid", v: e.vidpid }];
            if (!isU(e.batt))
                rows.push({ k: "battery", v: Math.round(Number(e.batt)) + "%" });
            rows.push({ k: "key", v: "dev_usb_" + e.vidpid + "_name" });
            out.push({
                id: "usb_" + e.vidpid, kind: "usbplug", label: e.name,
                sub: e.vidpid + " · usb", nodeIds: [], live: true, gen: e, rows: rows
            });
        }
        for (var j = 0; j < ai.length; j++) {
            var a = ai[j];
            var meta = audioMeta[a.match];
            if (meta === undefined)
                continue;
            var arows = [{ k: "node", v: a.src }];
            if (a.name !== "")
                arows.push({ k: "desc", v: a.name });
            if (!isU(a.vol))
                arows.push({ k: "vol", v: Math.round(Number(a.vol)) + "%" });
            out.push({
                id: "in_" + a.match, kind: "mic", label: meta.label,
                sub: meta.sub, nodeIds: [], live: true, gen: a, rows: arows
            });
        }
        return out;
    }
    // The single model the grid renders: curated seven, then whatever the
    // bus and the PipeWire source list currently claim.
    readonly property var cards: root.devs.concat(hotDevs)

    function devById(id) {
        var cs = root.cards;
        for (var i = 0; i < cs.length; i++)
            if (cs[i].id === id)
                return cs[i];
        return null;
    }

    // "up" = any folded node reports a live state; "unknown" = collector has
    // not enumerated it (hot-removable leaves start there); "down" = nodes
    // answered but nothing is live. Key-backed cards (`live`) carry no nodes:
    // the key's existence is the presence datum, so they are always "up".
    function devState(d) {
        if (!Topology.ready)
            return "unknown";       // scaffold not built yet — honest unknown
        if (d.live === true)
            return "up";
        var sawLive = false, sawUnk = false, sawNode = false;
        for (var i = 0; i < d.nodeIds.length; i++) {
            var n = node(d.nodeIds[i]);
            if (!n) {
                // not enumerated at all — that is an unknown, not a device
                // that answered "nothing is live"
                sawUnk = true;
                continue;
            }
            sawNode = true;
            var st = n.state;
            if (isU(st)) {
                sawUnk = true;
                continue;
            }
            var s = String(st);
            if (s === "present" || s === "up" || s === "connected" || s === "mounted")
                sawLive = true;
        }
        if (sawLive)
            return "up";
        if (!sawNode || sawUnk)
            return "unknown";
        return "down";
    }
    function stateColor(st) {
        return st === "up" ? pal.accent : (st === "down" ? pal.warn : pal.unknown);
    }

    // ---- per-card one-line telemetry overlay ------------------------------
    function tele(d) {
        // key-backed cards read straight off their record: battery only
        // when the _batt key exists, volume only from the source's _vol
        if (d.kind === "usbplug") {
            var ub = d.gen.batt;
            return joinParts([["USB", true], ["BAT " + Math.round(Number(ub)) + "%", !isU(ub)]]);
        }
        if (d.kind === "mic") {
            var uv = d.gen.vol;
            return joinParts([["VOL " + Math.round(Number(uv)) + "%", !isU(uv)]]);
        }
        switch (d.id) {
        case "g502": {
            var b = firstKnown(extra(node("input_mouse"), "batt_pct"),
                               extra(node("rcvr_logi"), "batt_pct"),
                               snum("dev_usb_046d:c547_batt"));
            var rl = node("rcvr_logi");
            var lk = (rl && !isU(rl.link)) ? mbps(rl.link) : "";
            return joinParts([["BAT " + Math.round(Number(b)) + "%", !isU(b)], [lk, lk !== ""]]);
        }
        case "k7": {
            var kn = node("kbd_asus");
            var kl = kn ? linkOf(kn) : unk;
            return kl === unk ? unk : joinParts([[mbps(kl), true], ["HID", true]]);
        }
        case "hs": {
            var snk = node("pw_sink_corsair");
            var v = extra(snk, "vol_pct");
            var mic = node("pw_src_corsair");
            // only a live mic is a reading; "absent"/"unknown" belongs in the
            // popover, not smeared across the card as a state name
            var ms = (mic && mic.state === "present") ? "MIC LIVE" : "";
            return joinParts([["VOL " + Math.round(Number(v)) + "%", !isU(v)], [ms, ms !== ""]]);
        }
        case "rcvr": {
            var rc = node("rcvr_corsair");
            var l2 = rc ? linkOf(rc) : unk;
            return l2 === unk ? unk : joinParts([[mbps(l2), true], ["2.4G", true]]);
        }
        case "kiyo": {
            var cm = node("cam_kiyo");
            var l3 = cm ? linkOf(cm) : unk;
            return l3 === unk ? unk : joinParts([[mbps(l3), true], ["UVC", true]]);
        }
        case "flash": {
            var fr = Topology.flowRates["flash_kingston"];
            var rt = (fr && !isU(fr.rate)) ? Topology.fmtB(fr.rate) : "";
            var fk = node("flash_kingston");
            var fkl = fk ? linkOf(fk) : unk;
            var base = rt !== "" ? rt : (fkl === unk ? "" : mbps(fkl));
            var pt = partLine("flash_kingston");
            return joinParts([[base, base !== ""], [pt, pt !== ""]]);
        }
        case "bt": {
            var bh = node("bt_hci0");
            var pr = firstKnown(extra(bh, "paired"), snum("dev_bt_paired"));
            var cn = firstKnown(extra(bh, "connected"), snum("dev_bt_conn"));
            return joinParts([["×" + Math.round(Number(pr)) + " PAIRED", !isU(pr)], ["×" + Math.round(Number(cn)) + " LINK", !isU(cn)]]);
        }
        }
        return unk;
    }
    // Largest recorded partition on the stick -> "sda1 71%" | ""
    function partLine(ownerId) {
        var best = null;
        var ps = Topology.parts;
        for (var k in ps) {
            var p = ps[k];
            if (!p || !p.extra || p.extra.parentId !== ownerId)
                continue;
            if (best === null || Number(isU(p.extra.size_bytes) ? 0 : p.extra.size_bytes) > Number(isU(best.extra.size_bytes) ? 0 : best.extra.size_bytes))
                best = p;
        }
        if (best === null)
            return "";
        var pc = isU(best.extra.pct) ? "" : " " + Math.round(Number(best.extra.pct)) + "%";
        return String(best.id) + pc;
    }

    // ======================================================== glyph painter
    // All pictograms are stroked/filled paths on the card Canvas — `ink` is
    // the state tint, `dim` the detail pass.
    function drawGlyph(ctx, kind, w, h, ink, dim) {
        if (w <= 0 || h <= 0)
            return;
        ctx.clearRect(0, 0, w, h);
        ctx.save();
        ctx.strokeStyle = ink;
        ctx.fillStyle = ink;
        ctx.lineWidth = 2;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        var cx = w / 2, cy = h / 2;
        var u = Math.min(w, h);

        function rr(x, y, rw, rh, r) {
            ctx.beginPath();
            ctx.moveTo(x + r, y);
            ctx.arcTo(x + rw, y, x + rw, y + rh, r);
            ctx.arcTo(x + rw, y + rh, x, y + rh, r);
            ctx.arcTo(x, y + rh, x, y, r);
            ctx.arcTo(x, y, x + rw, y, r);
            ctx.closePath();
        }

        switch (kind) {
        case "mouse": {
            // oval body (arc under a scale so the ellipse is exact)
            var rx = u * 0.24, ry = u * 0.36;
            ctx.save();
            ctx.translate(cx, cy);
            ctx.scale(1, ry / rx);
            ctx.beginPath();
            ctx.arc(0, 0, rx, 0, Math.PI * 2);
            ctx.stroke();
            ctx.restore();
            // scroll wheel line
            ctx.beginPath();
            ctx.moveTo(cx, cy - ry * 0.72);
            ctx.lineTo(cx, cy - ry * 0.20);
            ctx.stroke();
            // button split
            ctx.strokeStyle = dim;
            ctx.beginPath();
            ctx.moveTo(cx - rx * 0.92, cy - ry * 0.10);
            ctx.lineTo(cx + rx * 0.92, cy - ry * 0.10);
            ctx.stroke();
            break;
        }
        case "keys": {
            // deck + 2x4 key grid + spacebar
            var bw = u * 0.92, bh = u * 0.58;
            var bx = cx - bw / 2, by = cy - bh / 2;
            rr(bx, by, bw, bh, 4);
            ctx.stroke();
            var kg = 3, kw = (bw - 12 - 3 * kg) / 4, kh = (bh - 12 - 2 * kg) / 3;
            ctx.fillStyle = dim;
            for (var r = 0; r < 2; r++)
                for (var c = 0; c < 4; c++)
                    ctx.fillRect(bx + 6 + c * (kw + kg), by + 6 + r * (kh + kg), kw, kh);
            ctx.fillRect(bx + 6 + (kw + kg), by + 6 + 2 * (kh + kg), kw * 2 + kg, kh);
            break;
        }
        case "headset": {
            // headband arc + inner pad + ear cups + mic boom
            var hr = u * 0.30, cyb = cy + u * 0.06;
            ctx.lineWidth = 2.5;
            ctx.beginPath();
            ctx.arc(cx, cyb, hr, Math.PI, Math.PI * 2);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.lineWidth = 1.5;
            ctx.beginPath();
            ctx.arc(cx, cyb, hr - 4, Math.PI + 0.35, Math.PI * 2 - 0.35);
            ctx.stroke();
            ctx.strokeStyle = ink;
            ctx.lineWidth = 2;
            var cw2 = u * 0.15, ch2 = u * 0.26;
            rr(cx - hr - cw2 / 2, cyb - 2, cw2, ch2, 4);
            ctx.stroke();
            rr(cx + hr - cw2 / 2, cyb - 2, cw2, ch2, 4);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.beginPath();
            ctx.moveTo(cx + hr + cw2 * 0.35, cyb + ch2 * 0.72);
            ctx.lineTo(cx + hr - u * 0.10, cyb + ch2 * 1.02);
            ctx.stroke();
            ctx.fillStyle = ink;
            ctx.beginPath();
            ctx.arc(cx + hr - u * 0.10, cyb + ch2 * 1.02, 2.2, 0, Math.PI * 2);
            ctx.fill();
            break;
        }
        case "dongle": {
            // receiver stick: plug cap on top, body below, LED + radio ticks
            var dw = u * 0.24, dh = u * 0.52, capH = u * 0.15;
            var dy = cy - dh / 2;
            rr(cx - dw / 2 - 2, dy, dw + 4, capH, 2);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.lineWidth = 1.5;
            ctx.beginPath();
            ctx.moveTo(cx - dw * 0.25, dy + 3);
            ctx.lineTo(cx - dw * 0.25, dy + capH - 3);
            ctx.moveTo(cx + dw * 0.25, dy + 3);
            ctx.lineTo(cx + dw * 0.25, dy + capH - 3);
            ctx.stroke();
            ctx.strokeStyle = ink;
            ctx.lineWidth = 2;
            rr(cx - dw / 2, dy + capH, dw, dh - capH, 5);
            ctx.stroke();
            ctx.beginPath();
            ctx.arc(cx, dy + dh * 0.62, 2.4, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = dim;
            ctx.beginPath();
            ctx.arc(cx, dy + dh * 0.40, dw * 0.95, -Math.PI * 0.42, -Math.PI * 0.08);
            ctx.stroke();
            ctx.beginPath();
            ctx.arc(cx, dy + dh * 0.40, dw * 1.35, -Math.PI * 0.42, -Math.PI * 0.08);
            ctx.stroke();
            break;
        }
        case "cam": {
            // concentric lens rings + pupil + mount foot
            var ro = u * 0.28, cyc = cy - u * 0.05;
            ctx.lineWidth = 2.5;
            ctx.beginPath();
            ctx.arc(cx, cyc, ro, 0, Math.PI * 2);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.lineWidth = 1.5;
            ctx.beginPath();
            ctx.arc(cx, cyc, ro * 0.58, 0, Math.PI * 2);
            ctx.stroke();
            ctx.fillStyle = ink;
            ctx.beginPath();
            ctx.arc(cx, cyc, ro * 0.18, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = ink;
            ctx.lineWidth = 2;
            rr(cx - u * 0.16, cyc + ro + 3, u * 0.32, u * 0.09, 3);
            ctx.stroke();
            break;
        }
        case "flash": {
            // USB plug silhouette: contact tongue left, body shell right
            var fh = u * 0.44, fbw = u * 0.62, tw = u * 0.20, th = u * 0.26;
            var fx = cx - (tw + fbw) / 2 + 2, fy = cy - fh / 2;
            rr(fx, cy - th / 2, tw, th, 2);
            ctx.stroke();
            ctx.fillStyle = dim;
            ctx.fillRect(fx + 3, cy - th * 0.26, tw * 0.32, th * 0.18);
            ctx.fillRect(fx + 3, cy + th * 0.08, tw * 0.32, th * 0.18);
            rr(fx + tw - 2, fy, fbw, fh, 6);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.beginPath();
            ctx.moveTo(fx + tw + fbw * 0.74, fy + 4);
            ctx.lineTo(fx + tw + fbw * 0.74, fy + fh - 4);
            ctx.stroke();
            break;
        }
        case "bt": {
            // bind rune: stem + right-pointing star, then radiating arcs
            var r2 = u * 0.30;
            var y0 = cy - r2, y1 = cy + r2, ym = cy;
            var x1 = cx + r2 * 0.78;
            ctx.beginPath();
            ctx.moveTo(cx, y0);
            ctx.lineTo(cx, y1);
            ctx.moveTo(cx, y0);
            ctx.lineTo(x1, ym);
            ctx.lineTo(cx, y1);
            ctx.moveTo(cx, ym);
            ctx.lineTo(x1, y0);
            ctx.moveTo(cx, ym);
            ctx.lineTo(x1, y1);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.lineWidth = 1.5;
            ctx.beginPath();
            ctx.arc(cx - r2 * 0.1, ym, r2 * 1.35, -0.55, 0.55);
            ctx.stroke();
            ctx.beginPath();
            ctx.arc(cx - r2 * 0.1, ym, r2 * 1.72, -0.55, 0.55);
            ctx.stroke();
            break;
        }
        case "usbplug": {
            // USB trident: plug circle, two pronged forks, arrow at the
            // host end — the family mark for a device with no silhouette
            var pT = cy - u * 0.30, pB = cy + u * 0.32;
            var fY = pT + u * 0.15;
            ctx.beginPath();
            ctx.moveTo(cx, pT + u * 0.06);
            ctx.lineTo(cx, pB - u * 0.03);
            ctx.stroke();
            ctx.beginPath();
            ctx.arc(cx, pT, u * 0.06, 0, Math.PI * 2);
            ctx.stroke();
            ctx.beginPath();
            ctx.moveTo(cx, cy - u * 0.03);
            ctx.lineTo(cx - u * 0.20, fY);
            ctx.stroke();
            ctx.beginPath();
            ctx.moveTo(cx, cy + u * 0.05);
            ctx.lineTo(cx + u * 0.20, fY + u * 0.11);
            ctx.stroke();
            // prong ends: square left, circle right (the two shapes the
            // charge lines carry)
            ctx.fillRect(cx - u * 0.245, fY - u * 0.045, u * 0.09, u * 0.09);
            ctx.beginPath();
            ctx.arc(cx + u * 0.20, fY + u * 0.165, u * 0.045, 0, Math.PI * 2);
            ctx.fill();
            // host arrow
            ctx.beginPath();
            ctx.moveTo(cx - u * 0.075, pB - u * 0.11);
            ctx.lineTo(cx + u * 0.075, pB - u * 0.11);
            ctx.lineTo(cx, pB + u * 0.02);
            ctx.closePath();
            ctx.fill();
            break;
        }
        case "mic": {
            // capture input: capsule with grille ribs, tapered body,
            // stand stub
            var mR = u * 0.16, mcy = cy - u * 0.17;
            var baseY = cy + u * 0.30;
            ctx.beginPath();
            ctx.arc(cx, mcy, mR, 0, Math.PI * 2);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.lineWidth = 1.2;
            for (var gr = -1; gr <= 1; gr++) {
                ctx.beginPath();
                ctx.moveTo(cx + gr * mR * 0.42, mcy - mR * 0.64);
                ctx.lineTo(cx + gr * mR * 0.42, mcy + mR * 0.64);
                ctx.stroke();
            }
            ctx.strokeStyle = ink;
            ctx.lineWidth = 2;
            ctx.beginPath();
            ctx.moveTo(cx - mR * 0.62, mcy + mR * 0.78);
            ctx.lineTo(cx - mR * 0.30, baseY);
            ctx.lineTo(cx + mR * 0.30, baseY);
            ctx.lineTo(cx + mR * 0.62, mcy + mR * 0.78);
            ctx.stroke();
            ctx.strokeStyle = dim;
            ctx.beginPath();
            ctx.moveTo(cx, baseY);
            ctx.lineTo(cx, baseY + u * 0.10);
            ctx.stroke();
            break;
        }
        }
        ctx.restore();
    }

    // ============================================================ popover
    property string selDev: ""
    // Rebuilt on selection change and once per Topology refresh while open —
    // statsRev is the binding tick; node objects stay live across frames.
    readonly property var popRows: selDev === "" ? [] : buildPopRows(Topology.statsRev)
    function buildPopRows(dep) {
        var out = [];
        var d = devById(selDev);
        if (d === null)
            return out;
        if (d.rows !== undefined) {     // key-backed cards carry their own table
            out.push({ k: d.sub, v: d.label, head: true });
            for (var ri = 0; ri < d.rows.length; ri++)
                out.push(d.rows[ri]);
            return out;
        }
        for (var i = 0; i < d.nodeIds.length; i++) {
            var id = d.nodeIds[i];
            var n = node(id);
            if (!n) {
                out.push({ k: id, v: unk, head: true });
                continue;
            }
            out.push({ k: id, v: String(n.label), head: true });
            out.push({ k: "state", v: isU(n.state) ? unk : String(n.state) });
            if (!isU(n.link))
                out.push({ k: "link", v: String(n.link) });
            if (!isU(n.temp))
                out.push({ k: "temp", v: Topology.tempTxt(n.temp) });
            var x = n.extra || {};
            if (x.vidPid !== undefined)
                out.push({ k: "vid:pid", v: String(x.vidPid) });
            if (x.batt_pct !== undefined && !isU(x.batt_pct))
                out.push({ k: "battery", v: Math.round(Number(x.batt_pct)) + "%" });
            if (x.vol_pct !== undefined && !isU(x.vol_pct))
                out.push({ k: "vol", v: Math.round(Number(x.vol_pct)) + "%" });
            if (x.paired !== undefined && !isU(x.paired))
                out.push({ k: "paired", v: String(x.paired) });
            if (x.connected !== undefined && !isU(x.connected))
                out.push({ k: "conn", v: String(x.connected) });
            if (x.speedSpec !== undefined)
                out.push({ k: "port", v: String(x.speedSpec) });
            if (x.devName !== undefined && !isU(x.devName))
                out.push({ k: "usb", v: String(x.devName) });
            if (x.audioName !== undefined && !isU(x.audioName))
                out.push({ k: "pw", v: String(x.audioName) });
            if (x.vitalLabel !== undefined && x.vitalLabel !== "")
                out.push({ k: "vital", v: String(x.vitalLabel) });
            if (x.vitalPath !== undefined && x.vitalPath !== "")
                out.push({ k: "src", v: String(x.vitalPath) });
        }
        // mounted partitions of removable media fold into the drive card
        if (d.id === "flash") {
            var ps = Topology.parts, shown = 0;
            for (var pid in ps) {
                var p = ps[pid];
                if (!p || !p.extra || p.extra.parentId !== "flash_kingston" || shown >= 4)
                    continue;
                var xp = p.extra;
                out.push({ k: String(p.id), v: (isU(xp.mount) ? "unmounted" : String(xp.mount)) + (isU(xp.pct) ? "" : " · " + Math.round(Number(xp.pct)) + "%"), head: shown === 0 });
                shown++;
            }
        }
        return out;
    }

    // ============================================================== layout
    // Card geometry, one place: the grid is a fixed two-up flow whose row
    // count comes from the whole model — curated seven plus every key-backed
    // card — and every card derives its bands from these numbers so the
    // pictogram, the telemetry chip and the head always share one vertical
    // rhythm. natHeight is what the host pane sizes to; when the host must
    // go smaller, cardH compresses toward cardMinH before anything clips.
    // No head/foot band wraps the grid: the bay is the pane's identity.
    readonly property int colW: 12          // card content inset
    readonly property int headH: 22         // label + sub block
    readonly property int chipH: 18         // telemetry pill
    readonly property int rowGap: 10        // gap between card rows
    readonly property int gridRows: Math.max(1, Math.ceil(root.cards.length / 2))
    readonly property int cardNomH: 132     // nominal card height
    readonly property int cardMinH: 118     // compress floor before the bands collide
    // 2 + 2*colW = body margins + the GlassPane edge per side
    readonly property int natHeight: 2 * root.colW + 2 + root.gridRows * root.cardNomH + (root.gridRows - 1) * root.rowGap
    readonly property int cardH: Math.max(root.cardMinH, Math.floor((root.height - 2 * root.colW - (root.gridRows - 1) * root.rowGap) / root.gridRows))

    Item {
        id: body
        anchors.fill: parent
        anchors.margins: 12

        Flow {
            id: cardFlow
            width: parent.width
            spacing: root.rowGap

            Repeater {
                model: root.cards
                delegate: Rectangle {
                    id: card
                    required property int index
                    required property var modelData
                    readonly property var dev: card.modelData
                    readonly property bool sel: root.selDev === card.dev.id
                    // an odd tail card spans the row so the grid has no hole
                    width: (card.index === root.cards.length - 1 && root.cards.length % 2 === 1) ? cardFlow.width : Math.floor((cardFlow.width - cardFlow.spacing) / 2)
                    height: root.cardH
                    radius: Style.r.emboss
                    clip: true
                    color: cardMa.containsMouse ? Qt.rgba(0.56, 0.85, 0.91, 0.07) : pal.ink
                    border.color: card.sel ? pal.accent : (cardMa.containsMouse ? pal.accent2 : pal.edge)
                    border.width: 1

                    readonly property string dstate: root.devState(card.dev)
                    readonly property color glyphInk: dstate === "up" ? pal.accent2 : (dstate === "down" ? pal.t55 : pal.unknown)
                    // the detail pass is a dim of the SAME ink, so a grey
                    // "unknown" glyph still has readable internal detail
                    // instead of vanishing into the card
                    readonly property color glyphDim: Style.tone(card.glyphInk, 0.42)
                    onGlyphInkChanged: glyphCv.requestPaint()

                    // pictogram band: square-ish box, 1.4:1 so the widest
                    // glyph (the keyboard deck at 0.92u) still clears the
                    // canvas — the old 0.62-of-width cap let the drawn
                    // extent drift well inside an oversized box
                    readonly property int glyphTop: root.colW + root.headH + 7
                    readonly property int glyphBox: Math.max(40, card.height - card.glyphTop - root.chipH - 18)
                    readonly property int glyphW: Math.min(card.width - 56, card.glyphBox * 7 / 5)

                    // ---- head: label + sub on the left, dot + state word
                    // on the right. Two short columns, one baseline pair,
                    // no third line of decoration.
                    Item {
                        id: cardHead
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: root.colW
                        anchors.rightMargin: root.colW
                        anchors.topMargin: 9
                        height: root.headH
                        Text {
                            id: devLabel
                            anchors.left: parent.left
                            anchors.right: devState.left
                            anchors.rightMargin: 10
                            font.family: pal.fDisp
                            font.pixelSize: root.fs("pxTag", 9)
                            font.letterSpacing: 2
                            // the card's identity leads; the state word beside
                            // it is a different hue, so both can be bright
                            // without fighting for the same attention
                            color: pal.txt
                            elide: Text.ElideRight
                            text: card.dev.label
                        }
                        Text {
                            id: devSub
                            anchors.left: parent.left
                            anchors.right: devState.left
                            anchors.rightMargin: 10
                            anchors.top: devLabel.bottom
                            font.family: pal.fMono
                            font.pixelSize: root.fs("pxMicro", 8)
                            color: pal.t40
                            elide: Text.ElideRight
                            text: card.dev.sub
                        }
                        // state dot in a static ring (no pulse, no clock) plus
                        // the state as a word — the dot alone was the only
                        // signal, and a 6px dot is a weak one
                        Item {
                            id: devState
                            anchors.right: parent.right
                            anchors.top: parent.top
                            width: 52
                            height: parent.height
                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: 2
                                width: 13
                                height: 13
                                radius: 7
                                color: "transparent"
                                border.width: 1
                                border.color: Style.tone(root.stateColor(card.dstate), 0.3)
                            }
                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: 5.5
                                width: 6
                                height: 6
                                radius: 3
                                color: root.stateColor(card.dstate)
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: parent.top
                                anchors.topMargin: 16
                                font.family: pal.fMono
                                font.pixelSize: root.fs("pxMicro", 8)
                                font.letterSpacing: 1
                                color: root.stateColor(card.dstate)
                                text: card.dstate.toUpperCase()
                            }
                        }
                    }
                    // hairline that closes the head band
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: root.colW + root.headH + 3
                        anchors.leftMargin: root.colW
                        anchors.rightMargin: root.colW
                        height: 1
                        color: pal.edge
                        opacity: 0.7
                    }

                    Canvas {
                        id: glyphCv
                        x: Math.round((card.width - width) / 2)
                        y: card.glyphTop
                        width: card.glyphW
                        height: card.glyphBox
                        onPaint: root.drawGlyph(getContext("2d"), card.dev.kind, width, height, card.glyphInk, card.glyphDim)
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                    }

                    // live telemetry chip — the card's only text besides the
                    // head; unknown vitals render the dash glyph
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 10
                        width: Math.min(parent.width - 2 * root.colW, teleTxt.implicitWidth + 18)
                        height: root.chipH
                        radius: 9
                        color: pal.well
                        border.color: pal.edge
                        border.width: 1
                        Text {
                            id: teleTxt
                            anchors.centerIn: parent
                            width: parent.width - 16
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            font.family: pal.fMono
                            font.pixelSize: root.fs("pxTag", 9)
                            // tint by state, so a device the collector has
                            // answered for but reports down never paints in
                            // the same cyan as a live one
                            color: card.dstate === "up" ? pal.accent2 : root.stateColor(card.dstate)
                            text: root.tele(card.dev)
                        }
                    }

                    MouseArea {
                        id: cardMa
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.selDev = (root.selDev === card.dev.id ? "" : card.dev.id)
                    }
                }
            }
        }
    }

    // ---- detail popover ---------------------------------------------------
    Rectangle {
        id: dimmer
        anchors.fill: parent
        visible: root.selDev !== ""
        color: Qt.rgba(0.03, 0.04, 0.06, 0.72)
        MouseArea {
            anchors.fill: parent
            onClicked: root.selDev = ""
        }

        // The popover wears the same chassis as the ledger panes: accent
        // tick + title, a sub line, a hairline, the key/value table, then a
        // pinned foot carrying the state and the dismiss hint. The state
        // moved out of the sub line and into the foot so the foot states
        // something new instead of repeating the line above it.
        Rectangle {
            id: pop
            anchors.centerIn: parent
            width: Math.min(380, dimmer.width - 48)
            height: Math.min(dimmer.height - 32, popCol.implicitHeight + 24)
            radius: 10
            color: pal.ink
            border.color: pal.accent
            border.width: 1
            clip: true
            readonly property int keyW: 100
            // swallow clicks so the dimmer doesn't dismiss on content taps
            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: popCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 6

                Item {
                    width: popCol.width
                    height: 13
                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Rectangle {
                            width: 14
                            height: 2
                            radius: 1
                            color: pal.accent
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            font.family: pal.fDisp
                            font.pixelSize: root.fs("pxLabel", 10)
                            font.letterSpacing: 3
                            color: pal.txt
                            text: {
                                var d = root.devById(root.selDev);
                                return d === null ? "" : d.label;
                            }
                        }
                    }
                }
                Text {
                    width: popCol.width
                    font.family: pal.fMono
                    font.pixelSize: root.fs("pxMicro", 8)
                    color: pal.t40
                    elide: Text.ElideRight
                    text: {
                        var d = root.devById(root.selDev);
                        return d === null ? "" : d.sub;
                    }
                }
                Rectangle {
                    width: popCol.width
                    height: 1
                    color: pal.edge
                    opacity: 0.7
                }
                Flickable {
                    width: popCol.width
                    height: Math.min(280, popRowsCol.implicitHeight)
                    contentHeight: popRowsCol.implicitHeight
                    clip: true
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: popRowsCol
                        width: parent.width
                        spacing: 1
                        Repeater {
                            model: root.popRows
                            delegate: Item {
                                id: popRow
                                required property var modelData
                                width: popRowsCol.width
                                height: popRow.modelData.head ? 16 : 13
                                Text {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: pop.keyW
                                    font.family: pal.fMono
                                    font.pixelSize: root.fs("pxTag", 9)
                                    font.letterSpacing: popRow.modelData.head ? 1 : 0
                                    color: popRow.modelData.head ? pal.accent2 : pal.t40
                                    elide: Text.ElideRight
                                    text: popRow.modelData.k
                                }
                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: pop.keyW + 6
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    font.family: pal.fMono
                                    font.pixelSize: root.fs("pxTag", 9)
                                    color: popRow.modelData.head ? pal.t55 : pal.txt
                                    elide: Text.ElideRight
                                    text: popRow.modelData.v
                                }
                            }
                        }
                    }
                }
                // foot: state word in its own colour + the dismiss hint,
                // split across the row so neither has to elide the other
                Item {
                    width: popCol.width
                    height: 13
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: 1
                        color: pal.edge
                        opacity: 0.7
                    }
                    Text {
                        id: popState
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.topMargin: 4
                        font.family: pal.fMono
                        font.pixelSize: root.fs("pxMicro", 8)
                        font.letterSpacing: 1
                        color: {
                            var d = root.devById(root.selDev);
                            return d === null ? pal.t40 : root.stateColor(root.devState(d));
                        }
                        text: {
                            var d = root.devById(root.selDev);
                            return d === null ? "" : root.devState(d).toUpperCase();
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: 4
                        font.family: pal.fMono
                        font.pixelSize: root.fs("pxMicro", 8)
                        color: pal.t40
                        text: "click outside to close"
                    }
                }
            }
        }
    }
}
