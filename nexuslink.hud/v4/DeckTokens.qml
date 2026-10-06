pragma ComponentBehavior: Bound

import QtQuick
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
    readonly property var pdesc: [
        { "id": "opencode", "key": "ocg", "name": "OPENCODE GO",
          "code": "PRV-OCG", "col": FuiTokens.ice,   "dash": null },
        { "id": "claude",   "key": "cld", "name": "CLAUDE",
          "code": "PRV-CLD", "col": FuiTokens.white, "dash": null },
        { "id": "codex",    "key": "cdx", "name": "OPENAI / CODEX",
          "code": "PRV-CDX", "col": FuiTokens.azure, "dash": "double" },
        { "id": "devin",    "key": "dvn", "name": "DEVIN",
          "code": "PRV-DVN", "col": FuiTokens.dim,   "dash": [1.5, 2.5] }
    ]
    // skyline stack order incl. codex snapshot lane + haze
    readonly property var stackDef: [
        { "key": "ocg",  "col": FuiTokens.ice,   "dash": null },
        { "key": "cld",  "col": FuiTokens.white, "dash": null },
        { "key": "cdx",  "col": FuiTokens.azure, "dash": null },
        { "key": "cdxs", "col": FuiTokens.azure, "dash": "double" },
        { "key": "dvn",  "col": FuiTokens.dim,   "dash": [1.5, 2.5] },
        { "key": "hze",  "col": FuiTokens.ice,   "dash": [6, 2, 1, 2] }
    ]
    readonly property var ledgerOrder: ["claude", "codex", "devin",
                                         "opencode", "haze", "fireworks"]

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
        var v = {}, sum = 0;
        for (var i = 0; i < pdesc.length; i++) {
            var dv = dayVal(pdesc[i].id);
            v[pdesc[i].key] = dv;
            if (dv !== null && dv > 0) sum += dv;
        }
        return { "v": v, "sum": sum };
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
    // cap=0 -> all cells (for bus counts); grid shows the first 5 by severity
    function limitCells(cap) {
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
                                + "% calc"
                              : "window n/a",
                    "action": act,
                    "ord": sev === "alert" ? 0 : sev === "warn" ? 1 : sev === "ok" ? 2 : 3
                });
            }
        }
        // providers with no limit feed at all
        for (i = 0; i < pdesc.length; i++) {
            d = pdesc[i]; mt = meta(d.id);
            if (mt.limits && mt.limits.length) continue;
            cells.push({
                "code": "LIM-" + d.key.toUpperCase() + "-NF",
                "sub": "QUOTA",
                "name": d.name,
                "stag": "N/A", "sev": "na",
                "frac": null, "win": null,
                "statusLine": "NO LIMIT FEED",
                "lines": ["reset n/a", "ledger: no limit field", "usage only (week/month)"],
                "winlab": "window n/a",
                "action": null,
                "ord": 3
            });
        }
        cells.sort(function (a, b) { return a.ord - b.ord; });
        return cap > 0 ? cells.slice(0, cap) : cells;
    }

    function limitBus() {
        var cells = limitCells(0), c = { "alert": 0, "warn": 0, "na": 0, "ok": 0 };
        for (var i = 0; i < cells.length; i++)
            c[(cells[i].sev in c) ? cells[i].sev : "na"]++;
        return c;
    }

    function resetMarks() {
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
        return marks;
    }

    // ================= history (skyline + heatmap + sparks) ================
    function histIndex() {
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
        var idx = histIndex(), rows = [];
        var today = new Date(nowMs || Date.now());
        today.setHours(0, 0, 0, 0);
        var keys = { "ocg": "opencode", "cld": "claude", "cdx": "codex",
                     "dvn": "devin", "hze": "haze" };
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
        return rows;
    }
    function sparkSeries(pid, nowMs) {
        var idx = histIndex(), vals = [];
        var today = new Date(nowMs || Date.now());
        today.setHours(0, 0, 0, 0);
        for (var i = 29; i >= 0; i--) {
            var iso = isoDay(new Date(today.getTime() - i * 86400e3));
            var r = idx[pid] ? idx[pid][iso] : null;
            vals.push(r ? hval(r) : null);
        }
        return vals;
    }
    function lastHist(pid, nowMs) {
        var h = (root.tokData && root.tokData.history) ? root.tokData.history : {};
        var rows = h[pid] || [];
        return rows.length ? String(rows[rows.length - 1].d || "") : "";
    }

    // ================= heatmap =============================================
    function heatCells(nowMs) {
        var idx = histIndex();
        var today = new Date(nowMs || Date.now());
        today.setHours(0, 0, 0, 0);
        var todayIso = isoDay(today);
        var dow = (today.getDay() + 6) % 7;                    // Mon=0
        var start = new Date(today.getTime() - (dow + 25 * 7) * 86400e3);
        var keys = ["claude", "codex", "devin", "opencode", "haze", "fireworks"];
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
        var hv = heroVals(), rows = [], cum = 0;
        for (var i = 0; i < pdesc.length; i++) {
            var d = pdesc[i], dv = hv.v[d.key];
            var sh = (hv.sum > 0 && dv !== null && dv > 0) ? dv / hv.sum : null;
            if (sh !== null) cum += sh;
            rows.push({
                "prv": { "v": d.key.toUpperCase(), "c": d.col },
                "v":   { "v": dv !== null ? FuiTokens.fmtTok(dv) : FuiTokens.unknownGlyph },
                "sh":  { "v": sh !== null ? (sh * 100).toFixed(2) + "%" : FuiTokens.unknownGlyph },
                "cum": { "v": hv.sum > 0 ? (cum * 100).toFixed(1) : FuiTokens.unknownGlyph }
            });
        }
        rows.push({
            "prv": { "v": "Σ", "c": FuiTokens.white },
            "v":   { "v": hv.sum > 0 ? FuiTokens.fmtTok(hv.sum) : "0" },
            "sh":  { "v": hv.sum > 0 ? "100.00%" : FuiTokens.unknownGlyph },
            "cum": { "v": "calc" }
        });
        return rows;
    }

    function lnum(x) {
        return { "v": (x === null || x === undefined) ? "n/a" : FuiTokens.fmtTok(x) };
    }
    function ledgerRows() {
        var rows = [];
        for (var i = 0; i < ledgerOrder.length; i++) {
            var pid = ledgerOrder[i], p = provs()[pid];
            if (!p) continue;
            var w = bk(pid, "week"), mo = bk(pid, "month");
            var mt = meta(pid);
            var st = mt.status ? String(mt.status).toLowerCase() : "";
            var kind = String(p.kind || "sub") + (st ? "·" + st.slice(0, 7) : "");
            rows.push({
                "prv": { "v": String(p.label || pid).toUpperCase().slice(0, 9),
                         "c": st ? FuiTokens.faint : FuiTokens.ice },
                "kind": { "v": kind, "c": st ? FuiTokens.faint : FuiTokens.mute },
                "wi": lnum(w["in"]), "wo": lnum(w["out"]), "wc": { "v": fmtMoney(w["cost"]) },
                "mi": lnum(mo["in"]), "mo": lnum(mo["out"]), "mc": { "v": fmtMoney(mo["cost"]) }
            });
        }
        return rows;
    }

    function sessionRows() {
        var s = (root.tokData && root.tokData.sessions) ? root.tokData.sessions : [];
        var rows = [];
        for (var i = 0; i < s.length && i < 8; i++) {
            var e = s[i] || {};
            var t = String(e.title || "(untitled)");
            rows.push({
                "n":   { "v": p2(i + 1) },
                "bot": { "v": String(e.bot || "?"), "c": FuiTokens.ice },
                "ti":  { "v": t.length > 19 ? t.slice(0, 18) + "~" : t },
                "mo":  { "v": String(e.model || "").slice(0, 13) },
                "iN":  { "v": e["in"] !== undefined ? FuiTokens.fmtTok(e["in"]) : "n/a" },
                "oN":  { "v": e["out"] !== undefined ? FuiTokens.fmtTok(e["out"]) : "n/a" },
                "t":   { "v": e["last"] ? Qt.formatDateTime(new Date(e["last"] * 1000), "hh:mm") : "" }
            });
        }
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
        title: "Token Flux / Today"
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
                Tk.Tx { role: "cap"; text: "arc = share of Σ today on 0-100% bezel" }
                Tk.Tx { role: "cap"; text: "major 10% · minor 2% · micro 0.5%" }
                Tk.MiniTable {
                    width: parent.width
                    columns: [
                        { "key": "prv", "label": "PRV" },
                        { "key": "v",   "label": "24H",   "align": "r" },
                        { "key": "sh",  "label": "SHARE", "align": "r" },
                        { "key": "cum", "label": "CUM%",  "align": "r", "role": "dim" }
                    ]
                    rows: root.compRows()
                    total: true
                    rowH: 16
                }
                Tk.Tx { role: "cap"; text: "outer ring Σ: stacked end-to-end"; topPadding: 6 }
                Tk.Tx { role: "cap"; text: "green index = 0% / ring origin" }
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
                    Tk.Tx { role: "cap"; text: "avg since midnight · calc" }
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
                    Tk.Tx { role: "cap"; text: "Σ today / 24h, flat average" }
                }
            }

            Tk.PrvCard {
                anchors { left: parent.left; bottom: parent.bottom }
                width: heroArea.colW
                name: "OPENCODE GO"
                code: "PRV-OCG"
                color: FuiTokens.ice
                valueText: {
                    var v = root.dayVal("opencode");
                    return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                }
                share: {
                    var hv = root.heroVals(), v = hv.v["ocg"];
                    return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                }
                shareSuffix: "calc"
                costLine: {
                    var mo = root.bk("opencode", "month");
                    var t = "cost n/a today";
                    if (mo["cost"] !== null && mo["cost"] !== undefined)
                        t += " · month " + root.fmtMoney(mo["cost"]);
                    return t;
                }
                extraLine: {
                    var mo = root.bk("opencode", "month");
                    var s = (mo["msgs"] !== null && mo["msgs"] !== undefined)
                          ? mo["msgs"] + " msgs/mo" : "ring 1";
                    var lag = root.histLag("opencode");
                    if (lag === "no rows") s += " · no history rows";
                    else if (lag !== "") s += " · history lags (" + lag + ")";
                    return s;
                }
                warned: root.histLag("opencode") !== ""
                spark: root.sparkSeries("opencode", root.nowMs)
                sparkMax: root.sparkMaxOf("opencode")
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
                            text: "Σ " + (root.heroVals().sum / 1e6).toFixed(1) + " M · calc"
                        }
                        Tk.Tx {
                            anchors.horizontalCenter: parent.horizontalCenter
                            role: "cap"
                            text: "event lanes · cdx snap wk/mo only"
                        }
                        Tk.Tx {
                            anchors.horizontalCenter: parent.horizontalCenter
                            role: "micro"
                            text: "limit ring outer arc · reset at tip"
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
                    name: "DEVIN"; code: "PRV-DVN"
                    color: FuiTokens.dim; dash: [1.5, 2.5]
                    valueText: {
                        var v = root.dayVal("devin");
                        return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                    }
                    share: {
                        var hv = root.heroVals(), v = hv.v["dvn"];
                        return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                    }
                    shareSuffix: "calc"
                    costLine: "cost n/a · ledger kind sub"
                    extraLine: {
                        var mo = root.bk("devin", "month");
                        var s = "ring 4 · dotted";
                        var mi = mo["in"], mout = mo["out"];
                        if (mi || mout)
                            s = "month " + FuiTokens.fmtTok((mi||0)+(mout||0)) + " · no limit feed";
                        return s;
                    }
                    spark: root.sparkSeries("devin", root.nowMs)
                    sparkMax: root.sparkMaxOf("devin")
                }
                Tk.PrvCard {
                    width: parent.width
                    name: "OPENAI / CODEX"; code: "PRV-CDX"
                    color: FuiTokens.azure; dash: "double"
                    valueText: {
                        var v = root.dayVal("codex");
                        return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                    }
                    share: {
                        var hv = root.heroVals(), v = hv.v["cdx"];
                        return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                    }
                    shareSuffix: "calc"
                    costLine: "cost n/a · snapshot lane separate"
                    extraLine: {
                        var l = root.laneSplit("codex", "week");
                        var s = "";
                        if (l.hrm > 0) s = "HRM " + FuiTokens.fmtTok(l.hrm);
                        if (l.snap !== null)
                            s += (s ? " + " : "") + "CLI " + FuiTokens.fmtTok(l.snap) + " snap";
                        if (s === "") s = "ring 3 · two disjoint lanes";
                        return s + " · disjoint";
                    }
                    spark: root.sparkSeries("codex", root.nowMs)
                    sparkMax: root.sparkMaxOf("codex")
                }
                Tk.PrvCard {
                    width: parent.width
                    name: "CLAUDE"; code: "PRV-CLD"
                    color: FuiTokens.white
                    valueText: {
                        var v = root.dayVal("claude");
                        return v !== null ? FuiTokens.fmtTok(v) : FuiTokens.unknownGlyph;
                    }
                    share: {
                        var hv = root.heroVals(), v = hv.v["cld"];
                        return (hv.sum > 0 && v !== null && v > 0) ? v / hv.sum : null;
                    }
                    shareSuffix: "calc"
                    costLine: {
                        var dd = root.bk("claude", "day"), wk = root.bk("claude", "week");
                        var t = "cost n/a";
                        if (dd["cost"] !== null && dd["cost"] !== undefined)
                            t = "today " + root.fmtMoney(dd["cost"]);
                        if (wk["cost"] !== null && wk["cost"] !== undefined)
                            t += " · wk " + root.fmtMoney(wk["cost"]);
                        return t;
                    }
                    extraLine: {
                        var mt = root.meta("claude");
                        var s = root.isAuth(mt) ? "auth pending" : "nominal";
                        var n = (mt.limits || []).length;
                        return s + " · " + n + " limit feeds · ring 2";
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
            readonly property real cw2: (width - 2 * 8 - 2 * 9) / 3
            // cards need header(34)+gauge(128)+body(~96) ≈ 258; timeline gets the rest
            readonly property real ch2: Math.min(258, Math.max(150, (height - 106) / 2))
            readonly property real tlH: Math.max(56, height - (2 * ch2 + 34))

            Repeater {
                model: root.limitCells(5)
                delegate: Tk.LimitCard {
                    required property int index
                    required property var modelData
                    x: 8 + (index % 3) * (limGrid.cw2 + 9)
                    y: 4 + Math.floor(index / 3) * (limGrid.ch2 + 8)
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

            // LIM-BUS summary cell (6th slot)
            Item {
                id: busCell
                x: 8 + 2 * (limGrid.cw2 + 9)
                y: 4 + limGrid.ch2 + 8
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
                        Tk.Tx { role: "code"; text: "LIM-BUS"; font.pixelSize: FuiTokens.px.micro + 1
                                anchors.left: parent.left }
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
                    Tk.Tx { role: "lbl"; text: "LIMIT BUS"; tone: FuiTokens.white; topPadding: 4 }
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
                    Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3 }
                    Tk.Tx { role: "cap"; text: "E429 window exhausted" }
                    Tk.Tx { role: "cap"; text: "A401 auth pending (no %)" }
                    Tk.Tx { role: "cap"; text: "N/A  no limit source" }
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
                    Tk.Tx {
                        role: "cap"
                        anchors { right: parent.right }
                        text: "T0 = now · auto horizon · diamonds = resets · chips = countdown"
                    }
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

            // KEY legend — parked in the skyline's empty lower-left apron
            Row {
                id: keyRow
                anchors { left: parent.left; bottom: parent.bottom; leftMargin: 58
                          bottomMargin: 34 }
                spacing: 10
                Tk.Tx { role: "code"; text: "KEY" }
                Repeater {
                    model: root.stackDef
                    delegate: Row {
                        required property var modelData
                        spacing: 4
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
                        Tk.Tx { role: "micro"; text: String(parent.modelData.key).toUpperCase() }
                    }
                }
            }

            Tk.IsoSkyline {
                anchors { left: parent.left; right: readRail.left; top: parent.top
                          bottom: parent.bottom; rightMargin: 10 }
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
                    Tk.Tx { role: "cap"; text: "calc"; anchors { right: parent.right
                                                                 bottom: sumNum.bottom } }
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
                            { "nm": "avg / day",     "v": fm(s / 30),        "t": "calc" },
                            { "nm": "median / day",  "v": fm(med),           "t": "calc" },
                            { "nm": "avg active day","v": nz ? fm(s / nz) : "—", "t": "calc" },
                            { "nm": "active days",   "v": nz + " / 30",      "t": "calc" },
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
                        { "key": "prv", "label": "", "w": 44 },
                        { "key": "v",   "label": "", "align": "r" },
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
                                "prv": { "v": kk.toUpperCase(), "c": root.stackDef[i].col },
                                "v":   { "v": vv >= 1000 ? (vv/1000).toFixed(2)+"B"
                                            : vv.toFixed(1) + "M" },
                                "sh":  { "v": tot > 0 ? (vv / tot * 100).toFixed(1) + "%" : "—" }
                            });
                        }
                        return out;
                    }
                }
                Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3 }
                Tk.Tx { role: "cap"; text: "axis linear · stack OCG CLD CDX+SNP DVN HZE" }
                Tk.Tx { role: "cap"; text: "dashed footprint = zero / no record" }
                Tk.Tx {
                    role: "cap"; tone: FuiTokens.warn
                    visible: text !== ""
                    text: {
                        var lags = [], i;
                        var today = root.isoDay(new Date(root.nowMs || Date.now()));
                        var map = { "opencode": "OCG", "devin": "DVN", "claude": "CLD", "codex": "CDX" };
                        for (var pid in map) {
                            var lh = root.lastHist(pid);
                            if (lh && lh < today) lags.push(map[pid] + " last " + lh.slice(5));
                            if (!lh) lags.push(map[pid] + " no rows");
                        }
                        return lags.length ? "history lags: " + lags.join(" · ") : "";
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
                                           : s.sum.toFixed(1) + "M") + " calc";
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
                Tk.Tx { role: "micro"; text: "log steps · all providers + snap" }
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
                    { "key": "n",   "label": "#",     "w": 22, "role": "faint" },
                    { "key": "bot", "label": "BOT",   "w": 62 },
                    { "key": "ti",  "label": "TITLE", "flex": 1, "role": "dim" },
                    { "key": "mo",  "label": "MODEL", "w": 88, "role": "faint" },
                    { "key": "iN",  "label": "IN",    "w": 56, "align": "r" },
                    { "key": "oN",  "label": "OUT",   "w": 52, "align": "r" },
                    { "key": "t",   "label": "T",     "w": 40, "align": "r", "role": "faint" }
                ]
                rows: root.sessionRows()
            }
            Tk.Tx {
                role: "cap"; tone: FuiTokens.faint
                visible: root.sessionRows().length === 0
                width: parent.width
                text: "— awaiting ledger sessions feed —"
            }
            Tk.Tx {
                role: "micro"; tone: FuiTokens.faint
                visible: root.sessionRows().length === 0
                width: parent.width
                wrapMode: Text.Wrap
                text: "installed ledger emits no top-level sessions[] yet; schema rev. ≥ 33d7cb3 required"
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
                             + FuiTokens.fmtTok(s.tin) + " calc";
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
                    { "key": "prv",  "label": "PRV",    "w": 66 },
                    { "key": "kind", "label": "KIND",   "w": 62, "role": "faint" },
                    { "key": "wi",   "label": "WK IN",  "align": "r" },
                    { "key": "wo",   "label": "WK OUT", "align": "r" },
                    { "key": "wc",   "label": "WK $",   "align": "r", "role": "dim" },
                    { "key": "mi",   "label": "MO IN",  "align": "r" },
                    { "key": "mo",   "label": "MO OUT", "align": "r" },
                    { "key": "mc",   "label": "MO $",   "align": "r", "role": "dim" }
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
                        return "known cost Σ month " + (s !== null ? root.fmtMoney(s) : "n/a") + " calc";
                    }
                }
                Tk.Tx {
                    role: "cap"; anchors { right: parent.right }
                    text: {
                        var mo = root.bk("opencode", "month");
                        return mo["msgs"] !== undefined && mo["msgs"] !== null
                               ? "OCG " + mo["msgs"] + " msgs/mo" : "";
                    }
                }
            }
            Tk.Tx {
                role: "cap"; tone: FuiTokens.faint
                width: parent.width
                text: {
                    var mt = root.meta("haze"), ups = mt.upstreams || [];
                    var s = "haze upstreams " + (ups.length ? ups.join(" + ") : "none");
                    var f = root.meta("fireworks");
                    if (f.status) s += " · fireworks " + String(f.status).toLowerCase();
                    return s;
                }
            }
            Tk.Tx {
                role: "cap"; tone: FuiTokens.faint
                width: parent.width
                wrapMode: Text.Wrap
                text: {
                    var l = root.laneSplit("codex", "week");
                    var mo = root.bk("codex", "month");
                    var s = "cdx lanes: wk hrm " + FuiTokens.fmtTok(l.hrm);
                    if (l.snap !== null) s += " + cli snap " + FuiTokens.fmtTok(l.snap);
                    if (mo["total"]) s += " · mo snap " + FuiTokens.fmtTok(mo["total"]);
                    return s + " — disjoint, never summed";
                }
            }
        }
    }
}
