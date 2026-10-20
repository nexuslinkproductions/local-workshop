pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import "tokens" as Tk

// DeckTokens.qml — M1 DP-2 deck (token flux / limits), matching the approved
// M1-dp2 sheet (gen_M1_dp2.py): concentric provider limit rings around the
// today total (hero), LIM-02 limit cells + reset timeline, 30-day isometric
// skyline, 26-week heatmap, top sessions, per-provider ledger.
//
// Two-lane rule (tokens/SCHEMA.md): for claude/codex, `in`/`out`/`cost` are
// the Hermes event lane, `total` is the CLI snapshot lane. Never added
// silently — the codex block/table label the split, and the skyline stacks
// the snapshot lane as its own `cdxs` segment (azure, double-edge cue).
Item {
    id: root

    // ---- deck inputs (docs/m1/CONTRACT.md — do not rename) ---------------
    property var stats: ({})
    property var tokData: ({})
    property var crew: ({})
    property string screenName: "DP-2"
    property bool shown: true
    property var navigator: null
    property string sayText: ""
    property bool sayFlash: false

    // ---- per-minute clock (countdowns only — the allowed slow mover) -----
    property real nowMs: 0
    Timer {
        interval: 60000
        repeat: true
        running: root.shown
        onTriggered: root.nowMs = Date.now()
    }
    Component.onCompleted: root.nowMs = Date.now()
    onShownChanged: if (root.shown) root.nowMs = Date.now()
    onTokDataChanged: root.nowMs = Date.now()

    // ---- provider descriptors (ring order: outer -> inner) ---------------
    // OCG's headline lane is `opencode-go` (Hermes crew events); the local
    // opencode.db CLI lane stays `opencode` and renders as its own skyline
    // segment + ledger row — two labelled lanes, never silently summed.
    readonly property var pdesc: [
        { "id": "opencode-go", "key": "ocg", "name": "Go (Hermes)",
          "code": "PRV-OCG", "col": FuiTokens.ice,   "dash": null },
        { "id": "claude",   "key": "cld", "name": "Claude",
          "code": "PRV-CLD", "col": FuiTokens.white, "dash": null },
        { "id": "codex",    "key": "cdx", "name": "Codex",
          "code": "PRV-CDX", "col": FuiTokens.azure, "dash": "double" },
        { "id": "devin",    "key": "dvn", "name": "Devin",
          "code": "PRV-DVN", "col": FuiTokens.dim,   "dash": [1.5, 2.5] }
    ]
    // skyline stack order incl. opencode CLI lane + codex snapshot lane +
    // Mac lanes (ocgmac/dvnmac: same hue as their desktop sibling, own dash)
    // label: short readable name for legend / readout (key stays the stack id)
    readonly property var stackDef: [
        { "key": "ocg",    "label": "Go (Hermes)",    "col": FuiTokens.ice,   "dash": null },
        { "key": "ocgcli", "label": "OpenCode CLI",   "col": FuiTokens.ice,   "dash": [2, 2] },
        { "key": "ocgmac", "label": "Go (Hermes)·MAC", "col": FuiTokens.ice,  "dash": [6, 3] },
        { "key": "cld",    "label": "Claude",         "col": FuiTokens.white, "dash": null },
        { "key": "cdx",    "label": "Codex",          "col": FuiTokens.azure, "dash": null },
        { "key": "cdxs",   "label": "Codex snapshot", "col": FuiTokens.azure, "dash": "double" },
        { "key": "dvn",    "label": "Devin",          "col": FuiTokens.dim,   "dash": [1.5, 2.5] },
        { "key": "dvnmac", "label": "Devin·MAC",      "col": FuiTokens.dim,   "dash": [5, 3] }
    ]
    readonly property var ledgerOrder: ["claude", "codex", "devin", "devin@mac",
                                         "opencode-go", "opencode-go@mac",
                                         "opencode"]

    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "tk"].concat(argv));
    }

    // ================= data layer =========================================
    function provs() {
        return root.tokData && root.tokData.providers ? root.tokData.providers : {};
    }
    function bk(pid, which) {
        var p = provs()[pid];
        return (p && p[which]) ? p[which] : {};
    }
    function meta(pid) {
        var p = provs()[pid];
        return (p && p.meta) ? p.meta : {};
    }
    // day bucket value: in+out (event lane); total only when in/out are null
    // (snapshot-only day). Zero is real, null is unknown.
    function dayVal(pid) {
        var b = bk(pid, "day");
        var iN = b["in"], oN = b["out"];
        if ((iN === null || iN === undefined) && (oN === null || oN === undefined))
            return b["total"] > 0 ? b["total"] : null;
        return (iN || 0) + (oN || 0);
    }
    function laneSplit(pid, which) {
        var b = bk(pid, which);
        var hrm = (b["in"] || 0) + (b["out"] || 0);
        var snap = b["total"];
        return { "hrm": hrm,
                 "snap": (snap !== null && snap !== undefined && snap > 0) ? snap : null };
    }

    // ---- model memo --------------------------------------------------------
    // The heavy row/model builders were re-run by every binding that called
    // them (skyRows x4, histIndex inside sparkSeries/heatCells/lastHist ~x12
    // per data refresh) — plus the two non-DP-2 monitor decks each doing the
    // same work while invisible. _mm() epochs all derived models on
    // (tokData, nowMs); builders early-return [] / null while !shown so a
    // dead deck never pays for a ledger refresh it can't paint.
    //
    // _memo is assigned ONCE and only its fields are mutated — a property
    // write inside a binding's own dependency chain trips Qt's binding-loop
    // detection. Bindings still depend on tokData/nowMs (read below), so
    // every model re-derives exactly once per epoch.
    property var _memo: ({})
    function _mm() {
        var m = root._memo;
        if (m._t === root.tokData && m._n === root.nowMs)
            return m;
        var fields = ["histIdx", "skyRows", "heatCells", "heroVals",
                      "compRows", "ledgerRows", "sessionRows", "limCells",
                      "limBus", "resetMarks"];
        for (var i = 0; i < fields.length; i++)
            m[fields[i]] = null;
        m.sparks = ({});
        m._t = root.tokData;
        m._n = root.nowMs;
        return m;
    }

    function fmtMoney(x) {
        if (x === null || x === undefined || !isFinite(Number(x)))
            return "n/a";
        var v = Number(x);
        return "$" + (v >= 1000 ? (v / 1000).toFixed(2) + "k"
                    : v >= 100 ? v.toFixed(1) : v.toFixed(2));
    }
    function p2(x) { return (x < 10 ? "0" : "") + x; }
    function isoDay(d) {
        return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate());
    }
    function fmtDur(ms) {
        var s = Math.max(0, Math.round(ms / 1000));
        var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
            m = Math.floor(s % 3600 / 60);
        if (d > 0) return d + "d " + p2(h) + "h";
        if (h > 0) return h + "h " + p2(m) + "m";
        return m + "m";
    }
    function windowMs(label) {
        var s = String(label || "").toLowerCase();
        if (/5\s*(h|hour)/.test(s)) return 5 * 3600e3;
        if (/weekly|7[-\s]*day/.test(s)) return 7 * 86400e3;
        if (/month|30[-\s]*day/.test(s)) return 30 * 86400e3;
        var m = s.match(/(\d+)\s*(day|d|h|hour)/);
        if (m) return Number(m[1]) * (/day|d/.test(m[2]) ? 86400e3 : 3600e3);
        return 0;
    }
    function winAbbrev(label) {
        var s = String(label || "").toLowerCase();
        if (/5\s*(h|hour)/.test(s)) return "5H";
        if (/weekly|7[-\s]*day/.test(s)) return "WK";
        if (/month|30[-\s]*day/.test(s)) return "MO";
        return "Q";
    }
    // auth-pending: source says the limit exists but usage% is unreadable
    // (claude today: percent 0.0 + "Waiting for auth")
    function isAuth(metaObj) {
        return /auth|waiting/i.test(String(metaObj.status || ""));
    }

    // per-provider limit summary for ring + timeline
    function limitInfo(pid) {
        var mt = meta(pid), lims = mt.limits;
        if (lims && lims.length) {
            var worst = lims[0];
            for (var i = 0; i < lims.length; i++)
                if (Number(lims[i].percent) > Number(worst.percent))
                    worst = lims[i];
            var pct = Number(worst.percent);
            var ms = Date.parse(String(worst.resetsAt || ""));
            var eta = isFinite(ms) ? "T-" + fmtDur(ms - root.nowMs) : "";
            if (isAuth(mt) && !(pct > 0))
                return { "frac": null, "sev": "warn", "resetMs": isFinite(ms) ? ms : 0,
                         "eta": "auth pending", "noFeed": "auth pending" };
            var sev = pct >= 1 ? "alert" : (pct >= 0.85 ? "warn" : "ok");
            return { "frac": pct, "sev": sev, "resetMs": isFinite(ms) ? ms : 0,
                     "eta": eta, "noFeed": null };
        }
        return { "frac": null, "sev": "na", "resetMs": 0, "eta": "", "noFeed": "no feed" };
    }

    function heroVals() {
        var m = root._mm();
        if (m.heroVals)
            return m.heroVals;
        var v = {}, sum = 0;
        for (var i = 0; i < pdesc.length; i++) {
            var dv = dayVal(pdesc[i].id);
            v[pdesc[i].key] = dv;
            if (dv !== null && dv > 0) sum += dv;
        }
        m.heroVals = { "v": v, "sum": sum };
        return m.heroVals;
    }
    // "max 626M 10-04" caption for a PrvCard's 30d sparkline
    function sparkMaxOf(pid) {
        var ser = sparkSeries(pid, root.nowMs), mx = 0, imx = -1;
        for (var i = 0; i < ser.length; i++)
            if (ser[i] !== null && ser[i] > mx) { mx = ser[i]; imx = i; }
        if (imx < 0 || mx <= 0) return "";
        var d = new Date(root.nowMs || Date.now());
        d.setHours(0, 0, 0, 0);
        d = new Date(d.getTime() - (29 - imx) * 86400e3);
        return "max " + (mx >= 1000 ? (mx / 1000).toFixed(2) + "B"
                        : mx >= 10 ? mx.toFixed(1) + "M" : mx.toFixed(2) + "M")
             + " " + isoDay(d).slice(5);
    }
    function histLag(pid) {
        var lh = lastHist(pid);
        var today = isoDay(new Date(root.nowMs || Date.now()));
        if (!lh) return "no rows";
        return lh < today ? "last " + lh.slice(5) : "";
    }

    function ringModel() {
        var hv = heroVals(), m = [];
        for (var i = 0; i < pdesc.length; i++) {
            var d = pdesc[i], lim = limitInfo(d.id), dv = hv.v[d.key];
            m.push({
                "label": d.key.toUpperCase(),
                "color": d.col,
                "value": (hv.sum > 0 && dv !== null && dv > 0) ? dv / hv.sum : null,
                "limit": lim.frac,
                "state": lim.sev === "na" ? "ok" : lim.sev,
                "dash": d.dash === "double" ? [] : (d.dash || []),
                "valueText": dv !== null ? FuiTokens.fmtTok(dv) : FuiTokens.unknownGlyph,
                "reset": "",
                // HeroLeaders extras
                "resetMs": lim.resetMs,
                "resetText": lim.eta,
                "noFeedText": lim.noFeed
            });
        }
        return m;
    }

    // ================= limit cells =========================================
    // cap=0 -> all cells (for bus counts); grid shows the first 5 by severity.
    // Providers with no limits[] feed never get a card — they collapse into
    // the noFeedProviders strip row so the grid only spends cells on real feeds.
    readonly property var noFeedProviders: {
        var out = [];
        for (var i = 0; i < pdesc.length; i++) {
            var lims = meta(pdesc[i].id).limits;
            if (!(lims && lims.length))
                out.push(pdesc[i].name);
        }
        return out;
    }
    function limitCells(cap) {
        var m = root._mm();
        if (m.limCells)
            return cap > 0 ? m.limCells.slice(0, cap) : m.limCells;
        var cells = [], i, j, lim, ms, wms;
        for (i = 0; i < pdesc.length; i++) {
            var d = pdesc[i], mt = meta(d.id), lims = mt.limits;
            if (!lims || !lims.length) continue;
            for (j = 0; j < lims.length; j++) {
                lim = lims[j];
                var pct = Number(lim.percent);
                ms = Date.parse(String(lim.resetsAt || ""));
                wms = windowMs(lim.label);
                var sev, sline, tag;
                if (isAuth(mt) && !(pct > 0)) { sev = "warn"; sline = "AUTH PENDING"; tag = "A401"; }
                else if (pct >= 1) { sev = "alert"; sline = "EXHAUSTED"; tag = "E429"; }
                else if (pct >= 0.85) { sev = "warn"; sline = "NEAR LIMIT"; tag = "OK"; }
                else { sev = "ok"; sline = "NOMINAL"; tag = "OK"; }
                var nm = lim.title ? String(lim.title).toUpperCase().replace(/\s*WEEKLY\s*/i, "").trim()
                                   : d.name;
                if (nm === "") nm = d.name;
                // LIM-XXX: titled limits get a consonant abbrev (Fable->FBL)
                var ck = lim.title
                       ? String(lim.title).replace(/[^a-z]/gi, "")
                         .replace(/[aeiou]/gi, "").slice(0, 3).toUpperCase()
                       : d.key.toUpperCase();
                if (ck === "") ck = d.key.toUpperCase();
                var lns = [];
                if (isFinite(ms)) {
                    lns.push("reset " + Qt.formatDateTime(new Date(ms), "dd.MM HH:mm"));
                    lns.push("T- " + fmtDur(ms - root.nowMs));
                } else {
                    lns.push("reset n/a");
                }
                var act = null;
                if (d.id === "claude" && isAuth(mt)) {
                    lns.push("run: claude auth login");
                    act = { "label": "AUTH LOGIN",
                            "argv": ["omarchy-launch-tui", "claude", "auth", "login"] };
                } else if (pct >= 1) {
                    lns.push("usage blocked until reset");
                } else {
                    lns.push("scope: " + String(lim.label || "provider limit"));
                }
                cells.push({
                    "code": "LIM-" + ck + "-" + winAbbrev(lim.label),
                    "sub": String(lim.label || "").toUpperCase(),
                    "name": nm,
                    "stag": tag, "sev": sev,
                    "frac": (isAuth(mt) && !(pct > 0)) ? null : pct,
                    "win": (isFinite(ms) && wms > 0)
                           ? Math.min(1, Math.max(0, (wms - (ms - root.nowMs)) / wms)) : null,
                    "statusLine": sline,
                    "lines": lns,
                    "winlab": wms > 0
                              ? Math.round(wms / 3600e3) + "h window elapsed "
                                + ((isFinite(ms) ? Math.min(1, Math.max(0, (wms - (ms - root.nowMs)) / wms)) : 0) * 100).toFixed(1)
                                + "%"
                              : "window n/a",
                    "action": act,
                    "ord": sev === "alert" ? 0 : sev === "warn" ? 1 : sev === "ok" ? 2 : 3
                });
            }
        }
        cells.sort(function (a, b) { return a.ord - b.ord; });
        m.limCells = cells;
        return cap > 0 ? cells.slice(0, cap) : cells;
    }

    function limitBus() {
        var m = root._mm();
        if (m.limBus)
            return m.limBus;
        var cells = limitCells(0), c = { "alert": 0, "warn": 0, "na": 0, "ok": 0 };
        for (var i = 0; i < cells.length; i++)
            c[(cells[i].sev in c) ? cells[i].sev : "na"]++;
        c["na"] += root.noFeedProviders.length;
        m.limBus = c;
        return c;
    }

    function resetMarks() {
        var m = root._mm();
        if (m.resetMarks)
            return m.resetMarks;
        var marks = [], i, j;
        for (i = 0; i < pdesc.length; i++) {
            var d = pdesc[i], mt = meta(d.id), lims = mt.limits;
            if (lims && lims.length) {
                for (j = 0; j < lims.length; j++) {
                    var lim = lims[j], ms = Date.parse(String(lim.resetsAt || ""));
                    if (!isFinite(ms)) continue;
                    var pct = Number(lim.percent);
                    var sev = (isAuth(mt) && !(pct > 0)) ? "warn"
                            : (pct >= 1 ? "alert" : "ok");
                    marks.push({
                        "label": (lim.title ? String(lim.title).replace(/\s*Weekly\s*/i, "")
                                  : d.key).toUpperCase().slice(0, 6),
                        "color": d.col,
                        "atMs": ms,
                        "status": sev,
                        "etaText": sev === "warn" ? "auth" : "T-" + fmtDur(ms - root.nowMs),
                        "note": winAbbrev(lim.label).toLowerCase() + " lim"
                    });
                }
            } else {
                marks.push({ "label": d.key.toUpperCase(), "color": d.col,
                             "atMs": 0, "status": "na", "etaText": "NO FEED", "note": "" });
            }
        }
        m.resetMarks = marks;
        return marks;
    }

    // ================= history (skyline + heatmap + sparks) ================
    function histIndex() {
        var m = root._mm();
        if (m.histIdx)
            return m.histIdx;
        var h = (root.tokData && root.tokData.history) ? root.tokData.history : {};
        var idx = {};
        for (var pid in h) {
            idx[pid] = {};
            var rows = h[pid] || [];
            for (var i = 0; i < rows.length; i++) {
                var r = rows[i];
                if (r && r.d) idx[pid][String(r.d)] = r;
            }
        }
        m.histIdx = idx;
        return idx;
    }
    // per-day token value for a history row (schema rule: in/out, else total)
    function hval(r) {
        if (!r) return 0;
        var iN = r["in"], oN = r["out"];
        if ((iN !== null && iN !== undefined) || (oN !== null && oN !== undefined))
            return ((iN || 0) + (oN || 0)) / 1e6;
        return (r["total"] || 0) / 1e6;
    }
    // last 30 local days, oldest -> today (M tokens per stack key)
    function skyRows(nowMs) {
        if (!root.shown)
            return [];
        var m = root._mm();
        if (m.skyRows)
            return m.skyRows;
        var idx = histIndex(), rows = [];
        var today = new Date(nowMs || Date.now());
        today.setHours(0, 0, 0, 0);
        var keys = { "ocg": "opencode-go", "ocgcli": "opencode",
                     "ocgmac": "opencode-go@mac",
                     "cld": "claude", "cdx": "codex",
                     "dvn": "devin", "dvnmac": "devin@mac" };
        for (var i = 29; i >= 0; i--) {
            var d = new Date(today.getTime() - i * 86400e3);
            var iso = isoDay(d), parts = {}, total = 0;
            for (var k in keys) {
                var r = idx[keys[k]] ? idx[keys[k]][iso] : null;
                var v = hval(r);
                if (k === "cdx" && r) {
                    // snapshot lane is disjoint — stack it as its own segment
                    var iN2 = r["in"], oN2 = r["out"];
                    var hasIo = (iN2 !== null && iN2 !== undefined)
                             || (oN2 !== null && oN2 !== undefined);
                    var snap = (r["total"] || 0) / 1e6;
                    v = hasIo ? ((iN2 || 0) + (oN2 || 0)) / 1e6 : 0;
                    if (snap > 0) { parts["cdxs"] = snap; total += snap; }
                }
                if (v > 0) { parts[k] = v; total += v; }
            }
            rows.push({ "iso": iso, "label": iso.slice(5), "total": total,
                        "parts": parts, "partial": i === 0 });
        }
        // Trim the leading all-zero prefix so the chart spans the panel:
        // with ~20 dead days the bars squeezed into a right-side wedge.
        // Inner/trailing zero days keep their dashed footprints (and the
        // zero-run bracket still draws); a fully-dead month keeps all 30.
        var first = -1;
        for (var zi = 0; zi < rows.length; zi++) {
            if ((rows[zi].total || 0) > 0) { first = zi; break; }
        }
        if (first > 0)
            rows = rows.slice(first);
        m.skyRows = rows;
        return rows;
    }
    function sparkSeries(pid, nowMs) {
        var m = root._mm();
        var ser = m.sparks[pid];
        if (ser)
            return ser;
        var idx = histIndex(), vals = [];
        var today = new Date(nowMs || Date.now());
        today.setHours(0, 0, 0, 0);
        for (var i = 29; i >= 0; i--) {
            var iso = isoDay(new Date(today.getTime() - i * 86400e3));
            var r = idx[pid] ? idx[pid][iso] : null;
            vals.push(r ? hval(r) : null);
        }
        m.sparks[pid] = vals;
        return vals;
    }
    function lastHist(pid, nowMs) {
        var h = (root.tokData && root.tokData.history) ? root.tokData.history : {};
        var rows = h[pid] || [];
        return rows.length ? String(rows[rows.length - 1].d || "") : "";
    }

    // ================= heatmap =============================================
    function heatCells(nowMs) {
        if (!root.shown)
            return [];
        var m = root._mm();
        if (m.heatCells)
            return m.heatCells;
        var idx = histIndex();
        var today = new Date(nowMs || Date.now());
        today.setHours(0, 0, 0, 0);
        var todayIso = isoDay(today);
        var dow = (today.getDay() + 6) % 7;                    // Mon=0
        var start = new Date(today.getTime() - (dow + 25 * 7) * 86400e3);
        var keys = ["claude", "codex", "devin", "devin@mac", "opencode-go",
                    "opencode-go@mac", "opencode"];
        var cells = [];
        for (var w = 0; w < 26; w++)
            for (var dd = 0; dd < 7; dd++) {
                var d = new Date(start.getTime() + (w * 7 + dd) * 86400e3);
                if (d > today) { cells.push(null); continue; }
                var iso = isoDay(d), tot = 0;
                for (var k = 0; k < keys.length; k++) {
                    var r = idx[keys[k]] ? idx[keys[k]][iso] : null;
                    if (r) {
                        tot += hval(r);
                        // snapshot lane is part of the day total too
                        var iN = r["in"], oN = r["out"];
                        var hasIo = (iN !== null && iN !== undefined) || (oN !== null && oN !== undefined);
                        if (hasIo && (r["total"] || 0) > 0) tot += (r["total"] || 0) / 1e6;
                    }
                }
                cells.push({ "iso": iso, "label": iso.slice(5), "total": tot,
                             "partial": iso === todayIso });
            }
        m.heatCells = cells;
        return cells;
    }
    function heatStats(cells) {
        var act = 0, sum = 0, mx = 0, mxl = "";
        for (var i = 0; i < cells.length; i++) {
            var c = cells[i];
            if (!c) continue;
            if ((c.total || 0) > 0) { act++; sum += c.total; if (c.total > mx) { mx = c.total; mxl = c.label; } }
        }
        return { "act": act, "sum": sum, "mx": mx, "mxl": mxl, "days": cells.length };
    }

    // ================= tables ==============================================
    function compRows() {
        var m = root._mm();
        if (m.compRows)
            return m.compRows;
        var hv = heroVals(), rows = [], cum = 0;
        for (var i = 0; i < pdesc.length; i++) {
            var d = pdesc[i], dv = hv.v[d.key];
            var sh = (hv.sum > 0 && dv !== null && dv > 0) ? dv / hv.sum : null;
            if (sh !== null) cum += sh;
            rows.push({
                "prv": { "v": d.name, "c": d.col },
                "v":   { "v": dv !== null ? FuiTokens.fmtTok(dv) : FuiTokens.unknownGlyph },
                "sh":  { "v": sh !== null ? (sh * 100).toFixed(2) + "%" : FuiTokens.unknownGlyph },
                "cum": { "v": hv.sum > 0 ? (cum * 100).toFixed(1) : FuiTokens.unknownGlyph }
            });
        }
        rows.push({
            "prv": { "v": "Σ", "c": FuiTokens.white },
            "v":   { "v": hv.sum > 0 ? FuiTokens.fmtTok(hv.sum) : "0" },
            "sh":  { "v": hv.sum > 0 ? "100.00%" : FuiTokens.unknownGlyph },
            "cum": { "v": "" }
        });
        m.compRows = rows;
        return rows;
    }

    function lnum(x) {
        return { "v": (x === null || x === undefined) ? "n/a" : FuiTokens.fmtTok(x) };
    }
    function ledgerRows() {
        var m = root._mm();
        if (m.ledgerRows)
            return m.ledgerRows;
        // display aliases — readable provider names (keys/order untouched)
        var shortPrv = { "claude": "Claude", "codex": "Codex", "devin": "Devin",
                         "devin@mac": "Devin·MAC", "opencode-go": "Go (Hermes)",
                         "opencode-go@mac": "Go (Hermes)·MAC",
                         "opencode": "OpenCode CLI" };
        var rows = [];
        for (var i = 0; i < ledgerOrder.length; i++) {
            var pid = ledgerOrder[i], p = provs()[pid];
            if (!p) continue;
            var w = bk(pid, "week"), mo = bk(pid, "month");
            var mt = meta(pid);
            var st = mt.status ? String(mt.status).toLowerCase() : "";
            var kind = String(p.kind || "sub") + (st ? "·" + st.slice(0, 7) : "");
            rows.push({
                "prv": { "v": shortPrv[pid]
                              || String(p.label || pid).slice(0, 14),
                         "c": st ? FuiTokens.faint : FuiTokens.ice },
                "kind": { "v": kind, "c": st ? FuiTokens.faint : FuiTokens.mute },
                "wi": lnum(w["in"]), "wo": lnum(w["out"]), "wc": { "v": fmtMoney(w["cost"]) },
                "mi": lnum(mo["in"]), "mo": lnum(mo["out"]), "mc": { "v": fmtMoney(mo["cost"]) }
            });
        }
        m.ledgerRows = rows;
        return rows;
    }

    function sessionRows() {
        var m = root._mm();
        if (m.sessionRows)
            return m.sessionRows;
        var s = (root.tokData && root.tokData.sessions) ? root.tokData.sessions : [];
        var rows = [];
        for (var i = 0; i < s.length && i < 8; i++) {
            var e = s[i] || {};
            var t = String(e.title || "");
            if (t === "") {
                // untitled — identify by profile + start time + model
                var st = e.start
                       ? Qt.formatDateTime(new Date(e.start * 1000), "MM-dd hh:mm")
                       : "?";
                t = String(e.bot || "?") + "·" + st
                  + "·" + String(e.model || "?").slice(0, 10);
            }
            rows.push({
                "n":   { "v": p2(i + 1) },
                "bot": { "v": String(e.bot || "?"), "c": FuiTokens.ice },
                "ti":  { "v": t.length > 26 ? t.slice(0, 25) + "~" : t },
                "mo":  { "v": String(e.model || "").slice(0, 13) },
                "iN":  { "v": e["in"] !== undefined ? FuiTokens.fmtTok(e["in"]) : "n/a" },
                "oN":  { "v": e["out"] !== undefined ? FuiTokens.fmtTok(e["out"]) : "n/a" },
                "t":   { "v": e["last"] ? Qt.formatDateTime(new Date(e["last"] * 1000), "hh:mm") : "" }
            });
        }
        m.sessionRows = rows;
        return rows;
    }
    function sessionStats() {
        var s = (root.tokData && root.tokData.sessions) ? root.tokData.sessions : [];
        var bots = {}, tin = 0;
        for (var i = 0; i < s.length; i++) {
            bots[s[i].bot] = true;
            tin += (s[i]["in"] || 0) + (s[i]["out"] || 0);
        }
        var n = 0;
        for (var k in bots) n++;
        return { "n": s.length, "bots": n, "tin": tin };
    }

    function costSumMonth() {
        var s = 0, any = false;
        for (var i = 0; i < ledgerOrder.length; i++) {
            var c = bk(ledgerOrder[i], "month").cost;
            if (c !== null && c !== undefined) { s += Number(c); any = true; }
        }
        return any ? s : null;
    }

    function ledgerStamp() {
        var u = root.tokData && root.tokData.updated ? String(root.tokData.updated) : "";
        return u ? u.slice(11, 16) + " UTC" : "no ledger";
    }

    // ================= deck =================================================
    Rectangle { anchors.fill: parent; color: FuiTokens.bg }

    // faint construction schematic behind the frames (mock layer 0)
    Canvas {
        id: schematic
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
            ctx.lineWidth = 1;
            var x, L;
            for (x = FuiTokens.deckMargin; x < width - FuiTokens.deckMargin + 1; x += FuiTokens.gridMinor) {
                L = ((x - FuiTokens.deckMargin) % FuiTokens.gridMajor === 0) ? 6 : 3;
                ctx.globalAlpha = 0.22;
                ctx.beginPath(); ctx.moveTo(x, 14); ctx.lineTo(x, 14 + L); ctx.stroke();
                ctx.beginPath(); ctx.moveTo(x, height - 14); ctx.lineTo(x, height - 14 - L); ctx.stroke();
            }
            var y;
            for (y = FuiTokens.deckMargin; y < height - FuiTokens.deckMargin + 1; y += FuiTokens.gridMinor) {
                L = ((y - FuiTokens.deckMargin) % FuiTokens.gridMajor === 0) ? 6 : 3;
                ctx.globalAlpha = 0.22;
                ctx.beginPath(); ctx.moveTo(14, y); ctx.lineTo(14 + L, y); ctx.stroke();
                ctx.beginPath(); ctx.moveTo(width - 14, y); ctx.lineTo(width - 14 - L, y); ctx.stroke();
            }
            // large construction circles behind the hero
            ctx.globalAlpha = 0.05;
            var cxx = width * 0.29, cyy = height * 0.32;
            [300, 330, 420].forEach(function (r, i) {
                ctx.setLineDash(i === 1 ? [4, 6] : []);
                ctx.beginPath(); ctx.arc(cxx, cyy, r, 0, Math.PI * 2); ctx.stroke();
            });
            ctx.setLineDash([]);
            ctx.globalAlpha = 1;
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // ============================ layout ==================================
    // mock 1920x1200, margin 32: r1 h640 | r2 h472 (gap 24)
    readonly property int mg: FuiTokens.deckMargin
    readonly property int gg: 24
    readonly property real row1H: (height - 2 * mg - gg) * (640.0 / 1136)
    readonly property real row2Y: mg + row1H + gg
    readonly property real row2H: height - row2Y - mg
    readonly property real heroW: (width - 2 * mg - gg) * (1128.0 / 1856)
    readonly property real limW: width - mg * 2 - heroW - gg
    readonly property real skyW: (width - 2 * mg - gg) * (880.0 / 1856)
    readonly property real rightX: mg + skyW + gg
    readonly property real rightW: width - rightX - mg
    readonly property real heatH: row2H * (184.0 / 472)
    readonly property real bot2Y: row2Y + heatH + gg
    readonly property real bot2H: height - bot2Y - mg
    readonly property real sesW: rightW * (464.0 / 952)
    readonly property real ledX: rightX + sesW + gg
    readonly property real ledW: width - ledX - mg

    // ---------------- TKN-01 hero ----------------------------------------
    FuiFrame {
        x: root.mg; y: root.mg
        width: root.heroW; height: root.row1H
        code: "TKN-01"
        title: "Today"
        meta: "src: tokens.json · event lanes · " + root.ledgerStamp()

        Item {
            id: heroArea
            anchors.fill: parent
            readonly property real colW: Math.min(292, Math.max(220, width * 0.26))

            // left column — composition table + burn block, OCG card bottom
            Column {
                anchors { left: parent.left; top: parent.top }
                width: heroArea.colW
                spacing: 4
                Tk.Tx { role: "hdr"; text: "COMPOSITION" }
                Tk.MiniTable {
                    width: parent.width
                    columns: [
                        { "key": "prv", "label": "PROVIDER", "flex": 1 },
                        { "key": "v",   "label": "TODAY",    "align": "r", "w": 72 },
                        { "key": "sh",  "label": "SHARE",    "align": "r", "w": 56 }
                    ]
                    rows: root.compRows()
                    total: true
                    rowH: 16
                }
                Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3
                            visible: burnBlock.visible }
                Column {
                    id: burnBlock
                    width: parent.width
                    visible: root.heroVals().sum > 0
                    spacing: 2
                    Item {
                        width: parent.width; height: 14
                        Tk.Tx { role: "lbl"; text: "BURN NOW"; anchors.left: parent.left }
                        Tk.Tx {
                            role: "num"
                            anchors { right: parent.right }
                            text: {
                                var d = new Date(root.nowMs || Date.now());
                                var hrs = Math.max(0.25, d.getHours() + d.getMinutes() / 60
                                                   + d.getSeconds() / 3600);
                                var s = root.heroVals().sum;
                                return s > 0 ? (FuiTokens.fmtTok(s / hrs) + "/h")
                                             : FuiTokens.unknownGlyph;
                            }
                        }
                    }
                    Tk.Tx { role: "cap"; text: "avg since midnight" }
                    Item {
                        width: parent.width; height: 14
                        Tk.Tx { role: "lbl"; text: "24H AVG"; anchors.left: parent.left }
                        Tk.Tx {
                            role: "num"
                            anchors { right: parent.right }
                            text: {
                                var s = root.heroVals().sum;
                                return s > 0 ? FuiTokens.fmtTok(s / 24) + "/h"
                                             : FuiTokens.unknownGlyph;
                            }
                        }
                    }
                }
            }

            Tk.PrvCard {
                anchors { left: parent.left; bottom: parent.bottom }
                width: heroArea.colW
                name: "Go (Hermes)"
                code: "PRV-OCG"
                color: FuiTokens.ice
                valueText: {
                    var v = root.dayVal("opencode-go");
                    return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                }
                share: {
                    var hv = root.heroVals(), v = hv.v["ocg"];
                    return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                }
                costLine: {
                    var mo = root.bk("opencode-go", "month");
                    return (mo["cost"] !== null && mo["cost"] !== undefined)
                           ? "month " + root.fmtMoney(mo["cost"]) : "";
                }
                // real warning only: stale/missing history is the only
                // extra line worth keeping on the card
                extraLine: {
                    var lag = root.histLag("opencode-go");
                    if (lag === "no rows") return "no history rows";
                    if (lag !== "") return "history lags (" + lag + ")";
                    return "";
                }
                warned: root.histLag("opencode-go") !== ""
                spark: root.sparkSeries("opencode-go", root.nowMs)
                sparkMax: root.sparkMaxOf("opencode-go")
            }

            // centre — concentric limit rings + countdown chips
            Item {
                id: ringBox
                anchors {
                    left: parent.left; leftMargin: heroArea.colW + 12
                    right: parent.right; rightMargin: heroArea.colW + 12
                    top: parent.top; bottom: parent.bottom
                }
                ConcentricRings {
                    id: rings
                    anchors.centerIn: parent
                    width: Math.min(parent.width, parent.height)
                    height: width
                    model: root.ringModel()

                    // centre readout (default property)
                    Column {
                        anchors.centerIn: parent
                        width: Math.min(rings.rInner * 2 - 16, 300)
                        spacing: 2
                        Tk.Tx {
                            anchors.horizontalCenter: parent.horizontalCenter
                            role: "lbl"; text: "TOKENS / TODAY"; tone: FuiTokens.ice
                        }
                        Item {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: heroNum.implicitWidth + heroUnit.implicitWidth + 6
                            height: heroNum.implicitHeight
                            Tk.Tx {
                                id: heroNum
                                role: "num"
                                font.family: FuiTokens.display
                                font.pixelSize: Math.min(FuiTokens.px.hero, rings.width * 0.13)
                                text: {
                                    var s = root.heroVals().sum;
                                    if (s <= 0) return "0";
                                    var t = FuiTokens.fmtTok(s);
                                    return t.slice(0, -1);
                                }
                            }
                            Tk.Tx {
                                id: heroUnit
                                role: "num"
                                font.pixelSize: Math.min(FuiTokens.px.big, rings.width * 0.07)
                                tone: FuiTokens.ice
                                anchors { left: heroNum.right; leftMargin: 6
                                          bottom: heroNum.bottom; bottomMargin: 6 }
                                text: {
                                    var s = root.heroVals().sum;
                                    var t = FuiTokens.fmtTok(s);
                                    return s > 0 && /[BKM]$/.test(t) ? t.slice(-1) : "";
                                }
                            }
                        }
                        Tk.Tx {
                            anchors.horizontalCenter: parent.horizontalCenter
                            role: "cap"; tone: FuiTokens.dim
                            text: "Σ " + (root.heroVals().sum / 1e6).toFixed(1) + " M"
                        }
                        Tk.Tx {
                            anchors.horizontalCenter: parent.horizontalCenter
                            role: "cap"
                            text: "Codex snapshot lane counted separately"
                        }
                    }
                }
                Tk.HeroLeaders {
                    anchors.fill: rings
                    host: rings
                    model: root.ringModel()
                    nowMs: root.nowMs
                }
            }

            // right column — DVN / CDX / CLD blocks (mock order top->bottom)
            Column {
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: heroArea.colW
                spacing: 10

                Tk.PrvCard {
                    width: parent.width
                    name: "Devin"; code: "PRV-DVN"
                    color: FuiTokens.dim; dash: [1.5, 2.5]
                    valueText: {
                        var v = root.dayVal("devin");
                        return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                    }
                    share: {
                        var hv = root.heroVals(), v = hv.v["dvn"];
                        return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                    }
                    costLine: ""
                    extraLine: {
                        var mo = root.bk("devin", "month");
                        var mi = mo["in"], mout = mo["out"];
                        return (mi || mout)
                               ? "month " + FuiTokens.fmtTok((mi||0)+(mout||0))
                                 + " · no limit feed" : "";
                    }
                    spark: root.sparkSeries("devin", root.nowMs)
                    sparkMax: root.sparkMaxOf("devin")
                }
                Tk.PrvCard {
                    width: parent.width
                    name: "Codex"; code: "PRV-CDX"
                    color: FuiTokens.azure; dash: "double"
                    valueText: {
                        var v = root.dayVal("codex");
                        return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                    }
                    share: {
                        var hv = root.heroVals(), v = hv.v["cdx"];
                        return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                    }
                    costLine: ""
                    extraLine: {
                        var l = root.laneSplit("codex", "week");
                        var s = "";
                        if (l.hrm > 0) s = "events " + FuiTokens.fmtTok(l.hrm);
                        if (l.snap !== null)
                            s += (s ? " + " : "") + FuiTokens.fmtTok(l.snap)
                               + " snapshot";
                        return s;
                    }
                    spark: root.sparkSeries("codex", root.nowMs)
                    sparkMax: root.sparkMaxOf("codex")
                }
                Tk.PrvCard {
                    width: parent.width
                    name: "Claude"; code: "PRV-CLD"
                    color: FuiTokens.white
                    valueText: {
                        var v = root.dayVal("claude");
                        return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                    }
                    share: {
                        var hv = root.heroVals(), v = hv.v["cld"];
                        return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                    }
                    costLine: {
                        var dd = root.bk("claude", "day"), wk = root.bk("claude", "week");
                        var t = "";
                        if (dd["cost"] !== null && dd["cost"] !== undefined)
                            t = "today " + root.fmtMoney(dd["cost"]);
                        if (wk["cost"] !== null && wk["cost"] !== undefined)
                            t += (t !== "" ? " · " : "") + "wk " + root.fmtMoney(wk["cost"]);
                        return t;
                    }
                    // real warning only — auth state, not the feed census
                    extraLine: {
                        var mt = root.meta("claude");
                        return root.isAuth(mt) ? "auth pending" : "";
                    }
                    warned: root.isAuth(root.meta("claude"))
                    spark: root.sparkSeries("claude", root.nowMs)
                    sparkMax: root.sparkMaxOf("claude")
                }
            }
        }
    }

    // ---------------- LIM-02 limits ---------------------------------------
    FuiFrame {
        x: root.mg + root.heroW + root.gg; y: root.mg
        width: root.limW; height: root.row1H
        code: "LIM-02"
        title: "Limits / Resets"
        meta: "src: tokens.json limits[] · " + root.ledgerStamp()

        Item {
            id: limGrid
            anchors.fill: parent
            // real limit feeds only; providers with no limits[] collapse into
            // the nfStrip line so the freed cells give the real cards more room
            readonly property var cells: root.limitCells(5)
            // auth-pending cells (frac null + warn + action) drop to a compact
            // one-line strip — a full gauge card just to say "log in" wastes
            // the grid; the freed room goes to the real cards + timeline
            readonly property var compactCells: cells.filter(function (c) {
                return c.sev === "warn" && c.frac === null && c.action !== null;
            })
            readonly property var gridCells: cells.filter(function (c) {
                return !(c.sev === "warn" && c.frac === null && c.action !== null);
            })
            readonly property int nCells: gridCells.length + 1    // + LIM-BUS cell
            readonly property int cols: nCells <= 3 ? Math.max(1, nCells)
                                      : (nCells <= 4 ? 2 : 3)
            readonly property int nRows: Math.ceil(nCells / cols)
            readonly property real stripH: compactCells.length > 0
                                           ? compactCells.length * 34 + 4 : 0
            readonly property real nfH: root.noFeedProviders.length > 0 ? 22 : 0
            // cards are capped at 224; whatever is left goes to the timeline
            // (min 56) so an auth-pending day never leaves dead lanes
            readonly property real cardsWant: nRows * 224 + Math.max(0, nRows - 1) * 9
            readonly property real tlH: Math.max(56, Math.min(240,
                    height - 4 - stripH - nfH - cardsWant - 28))
            readonly property real cardsH: height - 4 - stripH - nfH - (20 + tlH) - 8
            readonly property real ch2: Math.max(140, (cardsH - (nRows - 1) * 9) / nRows)
            readonly property real cw2: (width - 16 - (cols - 1) * 9) / cols

            // compact auth-pending rows: one line + login button each
            Repeater {
                model: limGrid.compactCells
                delegate: Item {
                    id: cmp
                    required property int index
                    required property var modelData
                    x: 8
                    y: 4 + index * 34
                    width: limGrid.width - 16
                    height: 30
                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(4/255, 6/255, 8/255, 0.35)
                        border.width: 1
                        border.color: FuiTokens.tone(FuiTokens.warn, 0.4)
                    }
                    Tk.Tx {
                        role: "lbl"; text: cmp.modelData.name; tone: FuiTokens.white
                        width: Math.min(implicitWidth, 150)
                        anchors { left: parent.left; leftMargin: 8
                                  verticalCenter: parent.verticalCenter }
                    }
                    Tk.Tx {
                        role: "cap"; tone: FuiTokens.warn
                        text: cmp.modelData.statusLine + " · " + cmp.modelData.sub.toLowerCase()
                        width: Math.min(implicitWidth,
                                        cmp.width - 174 - 112)
                        anchors { left: parent.left; leftMargin: 174
                                  verticalCenter: parent.verticalCenter }
                    }
                    EngravedButton {
                        visible: cmp.modelData.action !== null
                        anchors { right: parent.right; rightMargin: 5
                                  verticalCenter: parent.verticalCenter }
                        width: 104; height: 20
                        label: cmp.modelData.action !== null
                               ? String(cmp.modelData.action.label) : ""
                        chamfer: 4
                        onActivated: root.execArgv(cmp.modelData.action.argv)
                    }
                }
            }

            Repeater {
                model: limGrid.gridCells
                delegate: Tk.LimitCard {
                    required property int index
                    required property var modelData
                    x: 8 + (index % limGrid.cols) * (limGrid.cw2 + 9)
                    y: 4 + limGrid.stripH
                       + Math.floor(index / limGrid.cols) * (limGrid.ch2 + 9)
                    width: limGrid.cw2
                    height: limGrid.ch2
                    code: modelData.code
                    sub: modelData.sub
                    name: modelData.name
                    stag: modelData.stag
                    sev: modelData.sev
                    frac: modelData.frac
                    win: modelData.win
                    statusLine: modelData.statusLine
                    lines: modelData.lines
                    winlab: modelData.winlab
                    action: modelData.action
                    onRunAction: (argv) => root.execArgv(argv)
                }
            }

            // LIM-BUS summary cell (last grid slot)
            Item {
                id: busCell
                x: 8 + ((limGrid.nCells - 1) % limGrid.cols) * (limGrid.cw2 + 9)
                y: 4 + limGrid.stripH
                   + Math.floor((limGrid.nCells - 1) / limGrid.cols)
                     * (limGrid.ch2 + 9)
                width: limGrid.cw2
                height: limGrid.ch2
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(4/255, 6/255, 8/255, 0.35)
                    border.width: 1
                    border.color: FuiTokens.hair3
                }
                Column {
                    anchors { fill: parent; margins: 8 }
                    spacing: 3
                    Item {
                        width: parent.width; height: 13
                        Tk.Tx {
                            role: "tag"
                            anchors { right: parent.right }
                            text: {
                                var b = root.limitBus();
                                return b.alert + " / " + (b.alert + b.warn + b.na + b.ok) + " EXH";
                            }
                            tone: root.limitBus().alert > 0 ? FuiTokens.alert : FuiTokens.dim
                            topPadding: 1; bottomPadding: 1; leftPadding: 4; rightPadding: 4
                            Rectangle {
                                z: -1; anchors.fill: parent
                                color: "transparent"; border.width: 1
                                border.color: root.limitBus().alert > 0
                                              ? FuiTokens.tone(FuiTokens.alert, 0.6) : FuiTokens.hair2
                            }
                        }
                    }
                    Tk.Tx { role: "lbl"; text: "Rate limits"; tone: FuiTokens.white; topPadding: 4 }
                    Tk.MiniTable {
                        width: parent.width
                        header: false
                        rowH: 15
                        columns: [
                            { "key": "led", "label": "", "w": 12 },
                            { "key": "nm",  "label": "", "role": "dim" },
                            { "key": "n",   "label": "", "align": "r" }
                        ]
                        rows: {
                            var b = root.limitBus();
                            return [
                                { "led": { "v": "●", "c": FuiTokens.alert },
                                  "nm": "EXHAUSTED", "n": b.alert },
                                { "led": { "v": "●", "c": FuiTokens.warn },
                                  "nm": "AUTH PENDING", "n": b.warn },
                                { "led": { "v": "●", "c": FuiTokens.ice },
                                  "nm": "NO FEED", "n": b.na },
                                { "led": { "v": "●", "c": FuiTokens.acid },
                                  "nm": "NOMINAL", "n": b.ok }
                            ];
                        }
                    }
                }
            }

            // collapsed providers without a limits[] feed — one compact line,
            // the freed cells went to the real cards above
            Item {
                visible: limGrid.nfH > 0
                x: 8
                y: 4 + limGrid.stripH + limGrid.nRows * (limGrid.ch2 + 9)
                width: limGrid.width - 16
                height: limGrid.nfH
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(4/255, 6/255, 8/255, 0.35)
                    border.width: 1
                    border.color: FuiTokens.hair3
                }
                Tk.Tx {
                    role: "cap"
                    anchors { left: parent.left; leftMargin: 8
                              right: parent.right; rightMargin: 8
                              verticalCenter: parent.verticalCenter }
                    text: "Limits unavailable: " + root.noFeedProviders.join(" · ")
                }
                HoverHandler { id: stripHover }   // explains the strip on hover;
                QQC.ToolTip {                     // no buttons, nothing swallowed
                    y: parent.height + 4
                    visible: stripHover.hovered
                    delay: 250
                    text: "Token usage is recorded; these providers do not supply live rate limits."
                }
            }

            // RESET TIMELINE band
            Column {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                spacing: 4
                Item {
                    width: parent.width; height: 14
                    Tk.Tx { role: "lbl"; text: "RESET TIMELINE"; tone: FuiTokens.white
                            anchors.left: parent.left }
                }
                Tk.ResetTimeline {
                    width: parent.width
                    height: limGrid.tlH
                    marks: root.resetMarks()
                    nowMs: root.nowMs
                }
            }
        }
    }

    // ---------------- HST-03 skyline --------------------------------------
    FuiFrame {
        x: root.mg; y: root.row2Y
        width: root.skyW; height: root.row2H
        code: "HST-03"
        title: "Skyline / 30 days"
        meta: {
            var r = root.skyRows(root.nowMs);
            return "src: tokens.json history · " + (r.length ? r[0].label : "—")
                 + ".." + (r.length ? r[r.length - 1].label : "—") + " · " + root.ledgerStamp();
        }

        Item {
            anchors.fill: parent

            // legend — a wrapping Flow with a reserved strip above the bars so
            // the readable provider labels can never overlay the skyline
            Flow {
                id: keyFlow
                anchors { left: parent.left; top: parent.top; leftMargin: 58
                          right: readRail.left; rightMargin: 12; topMargin: 2 }
                spacing: 6
                Repeater {
                    model: root.stackDef
                    delegate: Row {
                        required property var modelData
                        spacing: 4
                        rightPadding: 8
                        Canvas {
                            width: 20; height: 10
                            anchors.verticalCenter: parent.verticalCenter
                            property var md: parent.modelData
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.clearRect(0, 0, width, height);
                                ctx.strokeStyle = FuiTokens.css(md.col);
                                ctx.lineWidth = 1.4;
                                if (md.dash === "double") {
                                    ctx.beginPath(); ctx.moveTo(0, 3); ctx.lineTo(width, 3); ctx.stroke();
                                    ctx.beginPath(); ctx.moveTo(0, 7); ctx.lineTo(width, 7); ctx.stroke();
                                } else {
                                    ctx.setLineDash(md.dash || []);
                                    ctx.beginPath(); ctx.moveTo(0, 5); ctx.lineTo(width, 5); ctx.stroke();
                                    ctx.setLineDash([]);
                                }
                            }
                            onMdChanged: requestPaint()
                        }
                        Tk.Tx { role: "tag"; text: String(parent.modelData.label) }
                    }
                }
            }

            Tk.IsoSkyline {
                anchors { left: parent.left; right: readRail.left; top: parent.top
                          bottom: parent.bottom; rightMargin: 10; topMargin: 46 }
                rows: root.skyRows(root.nowMs)
                providers: root.stackDef
            }

            // right readout rail
            Column {
                id: readRail
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: Math.min(232, parent.width * 0.28)
                spacing: 3
                Tk.Tx { role: "hdr"; text: "30D Σ" }
                Item {
                    width: parent.width; height: sumNum.implicitHeight
                    Tk.Tx {
                        id: sumNum
                        role: "num"
                        font.pixelSize: FuiTokens.px.big + 8
                        anchors.left: parent.left
                        text: {
                            var r = root.skyRows(root.nowMs), s = 0;
                            for (var i = 0; i < r.length; i++) s += r[i].total || 0;
                            return (s / 1000).toFixed(2);
                        }
                    }
                    Tk.Tx { role: "num"; tone: FuiTokens.ice; font.pixelSize: FuiTokens.px.mid
                            text: "B"; anchors { left: sumNum.right; leftMargin: 6
                                                 bottom: sumNum.bottom; bottomMargin: 4 } }
                }
                Tk.MiniTable {
                    width: parent.width
                    header: false
                    rowH: 15
                    columns: [
                        { "key": "nm", "label": "", "role": "dim" },
                        { "key": "v",  "label": "", "align": "r" },
                        { "key": "t",  "label": "", "align": "r", "role": "faint", "w": 44 }
                    ]
                    rows: {
                        var r = root.skyRows(root.nowMs);
                        var s = 0, nz = 0, mx = 0, mxl = "", arr = [];
                        for (var i = 0; i < r.length; i++) {
                            var v = r[i].total || 0;
                            arr.push(v); s += v;
                            if (v > 0) nz++;
                            if (v > mx) { mx = v; mxl = r[i].label; }
                        }
                        var sorted = arr.slice().sort(function (a, b) { return a - b; });
                        var med = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
                        function fm(vv) {
                            return vv >= 1000 ? (vv / 1000).toFixed(2) + "B"
                                 : vv >= 10 ? vv.toFixed(1) + "M" : vv.toFixed(2) + "M";
                        }
                        return [
                            { "nm": "avg / day",     "v": fm(s / 30),        "t": "" },
                            { "nm": "median / day",  "v": fm(med),           "t": "" },
                            { "nm": "avg active day","v": nz ? fm(s / nz) : "—", "t": "" },
                            { "nm": "active days",   "v": nz + " / 30",      "t": "" },
                            { "nm": "peak day",      "v": fm(mx),            "t": mxl }
                        ];
                    }
                }
                Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3; visible: true }
                Tk.Tx { role: "lbl"; text: "PER PROVIDER" }
                Tk.MiniTable {
                    width: parent.width
                    header: false
                    rowH: 15
                    columns: [
                        { "key": "prv", "label": "", "flex": 1 },
                        { "key": "v",   "label": "", "align": "r", "w": 64 },
                        { "key": "sh",  "label": "", "align": "r", "role": "code", "w": 46 }
                    ]
                    rows: {
                        var r = root.skyRows(root.nowMs), tot = 0, pv = {};
                        var i, j;
                        for (i = 0; i < r.length; i++) {
                            tot += r[i].total || 0;
                            for (var k in r[i].parts) pv[k] = (pv[k] || 0) + r[i].parts[k];
                        }
                        var out = [];
                        for (i = 0; i < root.stackDef.length; i++) {
                            var kk = root.stackDef[i].key, vv = pv[kk] || 0;
                            if (vv <= 0) continue;
                            out.push({
                                "prv": { "v": root.stackDef[i].label, "c": root.stackDef[i].col },
                                "v":   { "v": vv >= 1000 ? (vv/1000).toFixed(2)+"B"
                                            : vv.toFixed(1) + "M" },
                                "sh":  { "v": tot > 0 ? (vv / tot * 100).toFixed(1) + "%" : "—" }
                            });
                        }
                        return out;
                    }
                }
                Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3 }
                Tk.Tx { role: "cap"; text: "dashed footprint = no record" }
                Tk.Tx {
                    role: "cap"; tone: FuiTokens.warn
                    visible: text !== ""
                    width: parent.width
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    text: {
                        var lags = [];
                        var today = root.isoDay(new Date(root.nowMs || Date.now()));
                        var map = { "opencode-go": "Go (Hermes)", "opencode": "OpenCode CLI",
                                    "devin": "Devin", "claude": "Claude", "codex": "Codex",
                                    "opencode-go@mac": "Go (Hermes)·MAC", "devin@mac": "Devin·MAC" };
                        for (var pid in map) {
                            var lh = root.lastHist(pid);
                            if (lh && lh < today) lags.push(map[pid] + " updated " + lh.slice(5));
                            else if (!lh) lags.push(map[pid] + " no rows");
                        }
                        return lags.join("\n");
                    }
                }
            }
        }
    }

    // ---------------- HST-04 heatmap --------------------------------------
    FuiFrame {
        x: root.rightX; y: root.row2Y
        width: root.rightW; height: root.heatH
        code: "HST-04"
        title: "Heatmap / 26 weeks"
        meta: "src: tokens.json history Σ incl. snap · log steps"

        Item {
            anchors.fill: parent
            Tk.DayHeatmap {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: parent.width - heatRail.width - 12
                cells: root.heatCells(root.nowMs)
                weeks: 26
            }
            Column {
                id: heatRail
                anchors { right: parent.right; top: parent.top }
                width: Math.min(190, parent.width * 0.22)
                spacing: 2
                Tk.Tx { role: "cap"; text: "SCALE / DAY Σ"; tone: FuiTokens.dim }
                Row {
                    spacing: 3
                    Repeater {
                        model: ["0", "<10M", "10M", "50M", "200M", "1B+"]
                        delegate: Item {
                            id: legCell
                            required property int index
                            required property string modelData
                            width: 30; height: 24
                            Rectangle {
                                anchors { left: parent.left; right: parent.right; top: parent.top }
                                height: 11
                                color: FuiTokens.tone(FuiTokens.ice,
                                                      [0, 0.12, 0.24, 0.40, 0.62, 0.90][legCell.index])
                                border.width: 1
                                border.color: FuiTokens.tone(FuiTokens.ice, 0.3 + 0.1 * legCell.index)
                            }
                            Tk.Tx {
                                role: "micro"; text: legCell.modelData
                                anchors { top: parent.top; topMargin: 13
                                          horizontalCenter: parent.horizontalCenter }
                            }
                        }
                    }
                }
                Tk.Tx {
                    role: "cap"; topPadding: 4
                    text: {
                        var s = root.heatStats(root.heatCells(root.nowMs));
                        return "active " + s.act + " / " + s.days + " d";
                    }
                }
                Tk.Tx {
                    role: "cap"
                    text: {
                        var s = root.heatStats(root.heatCells(root.nowMs));
                        return "26w Σ " + (s.sum >= 1000 ? (s.sum / 1000).toFixed(2) + "B"
                                           : s.sum.toFixed(1) + "M");
                    }
                }
                Tk.Tx {
                    role: "cap"
                    text: {
                        var s = root.heatStats(root.heatCells(root.nowMs));
                        return s.mx > 0 ? "max " + s.mxl + " " +
                            (s.mx >= 1000 ? (s.mx / 1000).toFixed(2) + "B" : s.mx.toFixed(1) + "M")
                            : "max —";
                    }
                }
            }
        }
    }

    // ---------------- SES-05 top sessions ---------------------------------
    FuiFrame {
        x: root.rightX; y: root.bot2Y
        width: root.sesW; height: root.bot2H
        code: "SES-05"
        title: "Top Sessions"
        meta: "src: tokens.json sessions[]"

        Column {
            anchors.fill: parent
            spacing: 4
            Tk.MiniTable {
                width: parent.width
                visible: root.sessionRows().length > 0
                grid: true
                rowH: 16
                columns: [
                    { "key": "ti",  "label": "SESSION", "flex": 1, "role": "dim" },
                    { "key": "mo",  "label": "MODEL",   "w": 88, "role": "faint" },
                    { "key": "iN",  "label": "INPUT",   "w": 70, "align": "r" }
                ]
                rows: root.sessionRows()
            }
            Tk.Tx {
                role: "cap"; tone: FuiTokens.faint
                visible: root.sessionRows().length === 0
                width: parent.width
                text: "— awaiting ledger sessions feed —"
            }
            Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3
                        visible: root.sessionRows().length > 0 }
            Item {
                width: parent.width; height: 14
                visible: root.sessionRows().length > 0
                Tk.Tx {
                    role: "cap"
                    anchors.left: parent.left
                    text: {
                        var s = root.sessionStats();
                        return "top" + root.sessionRows().length + " Σ "
                             + FuiTokens.fmtTok(s.tin);
                    }
                }
                Tk.Tx {
                    role: "cap"; anchors { right: parent.right }
                    text: {
                        var s = root.sessionStats();
                        return s.n + " sess / " + s.bots + " bots";
                    }
                }
            }
            Tk.Tx {
                role: "cap"; tone: FuiTokens.faint
                visible: root.sessionRows().length > 0
                text: "last 14 days · sorted by input tokens"
            }
        }
    }

    // ---------------- LDG-06 ledger ---------------------------------------
    FuiFrame {
        x: root.ledX; y: root.bot2Y
        width: root.ledW; height: root.bot2H
        code: "LDG-06"
        title: "Ledger"
        meta: "src: tokens.json · " + root.ledgerStamp()

        Column {
            anchors.fill: parent
            spacing: 4
            Tk.MiniTable {
                width: parent.width
                grid: true
                rowH: 16
                columns: [
                    { "key": "prv",  "label": "PROVIDER",  "w": 108 },
                    { "key": "wi",   "label": "WEEK IN",   "align": "r" },
                    { "key": "wo",   "label": "WEEK OUT",  "align": "r" },
                    { "key": "mi",   "label": "MONTH IN",  "align": "r" },
                    { "key": "mc",   "label": "MONTH $",   "align": "r", "role": "dim" }
                ]
                rows: root.ledgerRows()
            }
            Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3 }
            Item {
                width: parent.width; height: 14
                Tk.Tx {
                    role: "cap"
                    anchors.left: parent.left
                    text: {
                        var s = root.costSumMonth();
                        return "known cost Σ month " + (s !== null ? root.fmtMoney(s) : "n/a");
                    }
                }
                Tk.Tx {
                    role: "cap"; anchors { right: parent.right }
                    text: {
                        var mo = root.bk("opencode", "month");
                        return mo["msgs"] !== undefined && mo["msgs"] !== null
                               ? "OpenCode CLI " + mo["msgs"] + " msgs/mo" : "";
                    }
                }
            }
            Tk.Tx {
                role: "cap"; tone: FuiTokens.faint
                width: parent.width
                wrapMode: Text.Wrap
                text: {
                    var l = root.laneSplit("codex", "week");
                    var mo = root.bk("codex", "month");
                    var s = "Codex: " + FuiTokens.fmtTok(l.hrm) + " events";
                    if (l.snap !== null) s += " + " + FuiTokens.fmtTok(l.snap) + " snapshot";
                    if (mo["total"]) s += " · month snapshot " + FuiTokens.fmtTok(mo["total"]);
                    return s + " — separate lanes, never summed";
                }
            }
        }
    }
}
