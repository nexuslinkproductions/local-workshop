pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import "tokens" as Tk

// DeckTokens.qml — M1 DP-2 deck (token flux / limits), matching the approved
// M1-dp2 sheet (gen_M1_dp2.py). Redesign pass (daily/weekly):
//   TKN-01  hero — DAY/WEEK segmented toggle, period Σ, concentric rings
//           (thin arc = share of period Σ, thick arc = provider limit used,
//           bezel = 0..100%), rate block (avg since anchor + pace).
//   PRV-02  provider lanes — one row per ledger lane in the period window:
//           swatch, name, period tokens, share bar, status note. Lanes with
//           no recorded feed collapse into one honest footnote line.
//   TRD-03  trend — IsoSkyline over last 30 days (DAY) or ISO-week buckets
//           (WEEK), right rail = window Σ / avg / peak.
//   LIM-04  limits — severity-ordered LIM cells + LIM-BUS + reset timeline;
//           providers without a limits[] feed collapse into one line.
//
// Two-lane rule (tokens/SCHEMA.md): for claude/codex, `in`/`out`/`cost` are
// the Hermes event lane, `total` is the CLI snapshot lane. Never added
// silently — the codex row marks the snapshot lane as such.
//
// Period state persists via prefs.tokensWin ("day"|"week") — the host window
// stores it in hud-state-v4.json screens[screen].prefs.
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

    // ---- period selection (persisted by the host) -------------------------
    property var prefs: ({})
    property var onSetPref: function (k, v) {}
    readonly property string period:
        (prefs && prefs.tokensWin === "week") ? "week" : "day"
    function setPeriod(p) { root.onSetPref("tokensWin", p) }

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

    // ---- lane style table (one canonical colour per lane, every widget) --
    // col/dash also drive the trend stack order below; a lane's swatch, ring
    // arc, provider row and skyline segment always share the same stroke.
    readonly property var laneStyle: ({
        "claude":      { "key": "cld", "col": FuiTokens.white, "dash": null },
        "opencode-go": { "key": "ocg", "col": FuiTokens.ice,   "dash": null },
        "codex":       { "key": "cdx", "col": FuiTokens.azure, "dash": "double" },
        "devin":       { "key": "dvn", "col": FuiTokens.dim,   "dash": [1.5, 2.5] },
        "opencode":    { "key": "occ", "col": FuiTokens.ice,   "dash": [2, 2] },
        "haze":        { "key": "hze", "col": FuiTokens.ice,   "dash": [6, 2, 1, 2] },
        "fireworks":   { "key": "fwk", "col": FuiTokens.dim,   "dash": null },
        "custom":      { "key": "cst", "col": FuiTokens.warn,  "dash": [4, 2] },
        "nous":        { "key": "nus", "col": FuiTokens.dim,   "dash": [4, 2] }
    })
    readonly property var laneOrder: [
        "claude", "opencode-go", "codex", "devin", "opencode", "haze",
        "fireworks", "custom", "nous"
    ]
    function laneKey(pid) {
        var s = laneStyle[pid];
        if (s) return s.key;
        var k = String(pid).replace(/[^a-z0-9]/gi, "").toUpperCase();
        return k.slice(0, 3) || "???";
    }
    function laneCol(pid, i) {
        var s = laneStyle[pid];
        if (s) return s.col;
        // lanes beyond the style table stay in the ice family — labeled
        // rows carry the identity, the stroke just keeps them consistent
        return i % 2 === 0 ? FuiTokens.mute : FuiTokens.dim;
    }

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
    // period bucket value: in+out (event lane); total only when in/out are
    // null (snapshot-only bucket). Zero is real, null is unknown.
    function periodVal(pid) {
        var b = bk(pid, root.period);
        var iN = b["in"], oN = b["out"];
        if ((iN === null || iN === undefined) && (oN === null || oN === undefined))
            return b["total"] > 0 ? b["total"] : null;
        return (iN || 0) + (oN || 0);
    }
    // two-lane split for snapshot-carrying providers (codex/claude):
    // hrm = event lane, snap = snapshot rollup — disjoint, never summed
    function laneSplit(pid, which) {
        var b = bk(pid, which || root.period);
        var hrm = (b["in"] || 0) + (b["out"] || 0);
        var snap = b["total"];
        return { "hrm": hrm,
                 "snap": (snap !== null && snap !== undefined && snap > 0) ? snap : null };
    }

    // ---- model memo --------------------------------------------------------
    // Heavy row/model builders re-run once per (tokData, nowMs) epoch; the
    // memo object is assigned once and only its fields mutate — a property
    // write inside a binding's own dependency chain trips binding-loop
    // detection. Builders early-return [] while !shown so a dead deck never
    // pays for a ledger refresh it can't paint.
    property var _memo: ({})
    function _mm() {
        var m = root._memo;
        if (m._t === root.tokData && m._n === root.nowMs && m._p === root.period)
            return m;
        var fields = ["histIdx", "skyRows", "weekRows", "lanes", "ringMdl",
                      "limCells", "limBus", "resetMarks", "stackLanes"];
        for (var i = 0; i < fields.length; i++)
            m[fields[i]] = null;
        m._t = root.tokData;
        m._n = root.nowMs;
        m._p = root.period;
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
    // local-midnight Date of the Monday starting the ISO week containing d
    function weekStart(d) {
        var t = new Date(d.getTime());
        t.setHours(0, 0, 0, 0);
        return new Date(t.getTime() - ((t.getDay() + 6) % 7) * 86400e3);
    }
    // ISO week number ("W42") for a local Date
    function isoWeek(d) {
        var t = weekStart(d);
        var thu = new Date(t.getTime() + 3 * 86400e3);
        var jan1 = new Date(thu.getFullYear(), 0, 1);
        var wk = Math.ceil(((thu - jan1) / 86400e3 + 1) / 7);
        return "W" + (wk < 10 ? "0" : "") + wk;
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

    // ---- canonical lane list ----------------------------------------------
    // Every provider the ledger reports, in stable display order, with the
    // period value + share precomputed. Lanes with no records anywhere are
    // still listed here; the providers frame folds them into a footnote.
    function lanes() {
        var m = root._mm();
        if (m.lanes)
            return m.lanes;
        var p = provs(), ids = [], seenK = {};
        var i, j;
        for (i = 0; i < laneOrder.length; i++)
            if (p[laneOrder[i]]) { ids.push(laneOrder[i]); seenK[laneOrder[i]] = true; }
        var rest = [];
        for (var pid in p)
            if (!seenK[pid]) rest.push(pid);
        rest.sort();
        ids = ids.concat(rest);
        var out = [], sum = 0;
        for (i = 0; i < ids.length; i++) {
            var v = periodVal(ids[i]);
            if (v !== null && v > 0) sum += v;
        }
        for (i = 0; i < ids.length; i++) {
            var id = ids[i], pr = p[id] || {}, v2 = periodVal(id);
            var hasHist = root.tokData && root.tokData.history
                          && (root.tokData.history[id] || []).length > 0;
            out.push({
                "id": id, "key": laneKey(id),
                "name": String((pr.meta && pr.meta.label) || pr.label || id),
                "kind": String(pr.kind || "api"),
                "col": laneCol(id, i),
                "dash": laneStyle[id] ? laneStyle[id].dash : [1.5, 2.5],
                "v": v2,
                "share": (sum > 0 && v2 !== null && v2 > 0) ? v2 / sum : null,
                "hasFeed": hasHist || (v2 !== null && v2 > 0)
                          || (bk(id, "week")["in"] || bk(id, "week")["out"]
                              || bk(id, "week")["total"] ? true : false)
            });
        }
        m.lanes = { "list": out, "sum": sum };
        return m.lanes;
    }
    function periodSum() { return lanes().sum; }

    // period anchors for the rate block
    function periodStartMs() {
        var d = new Date(root.nowMs || Date.now());
        if (root.period === "week") return weekStart(d).getTime();
        d.setHours(0, 0, 0, 0);
        return d.getTime();
    }
    function periodSpanH() { return root.period === "week" ? 168 : 24; }
    function elapsedH() {
        return Math.max(0.05, ((root.nowMs || Date.now()) - periodStartMs()) / 3600e3);
    }
    function periodScope() {
        var d = new Date(root.nowMs || Date.now());
        if (root.period === "week")
            return "ISO " + isoWeek(d) + " · since Mon " + isoDay(weekStart(d)).slice(5);
        return "since 00:00 local · " + isoDay(d).slice(5);
    }
    function periodTitle() { return root.period === "week" ? "This week" : "Today"; }

    function ringModel() {
        var m = root._mm();
        if (m.ringMdl)
            return m.ringMdl;
        var ls = lanes().list, sum = lanes().sum;
        // top lanes by period value get a ring (max 5); the rest live in the
        // providers table only — a ring per cold lane is just noise
        var scored = [];
        for (var i = 0; i < ls.length; i++)
            if (ls[i].v !== null && ls[i].v > 0) scored.push(ls[i]);
        scored.sort(function (a, b) { return b.v - a.v; });
        var limFed = {};
        for (i = 0; i < ls.length; i++)
            if (limitInfo(ls[i].id).frac !== null) limFed[ls[i].id] = true;
        // max 4 rings: ConcentricRings stacks inside labels at 195°+i·17° —
        // a fifth label lands at 263° and clips the frame's bottom edge
        var sel = scored.slice(0, 4);
        for (i = 0; i < ls.length && sel.length < 4; i++)
            if (limFed[ls[i].id] && sel.indexOf(ls[i]) < 0)
                sel.push(ls[i]);    // fed-but-zero lanes still show their limit arc
        var mdl = [];
        for (i = 0; i < sel.length; i++) {
            var l = sel[i], lim = limitInfo(l.id);
            mdl.push({
                "label": l.key.toUpperCase(),
                "color": l.col,
                "value": (sum > 0 && l.v !== null && l.v > 0) ? l.v / sum : null,
                "limit": lim.frac,
                "state": lim.sev === "na" ? "ok" : lim.sev,
                "dash": l.dash === "double" ? [] : (l.dash || []),
                "valueText": (l.v !== null && l.v > 0)
                             ? FuiTokens.fmtTok(l.v)
                               + " · " + Math.round(l.v / sum * 100) + "%"
                             : FuiTokens.unknownGlyph,
                "reset": lim.eta
            });
        }
        m.ringMdl = mdl;
        return mdl;
    }

    // ================= limit cells =========================================
    // Providers with no limits[] feed never get a card — they collapse into
    // the noFeedProviders strip so the grid only spends cells on real feeds.
    readonly property var noFeedProviders: {
        var out = [], ls = lanes().list;
        for (var i = 0; i < ls.length; i++) {
            var lims = meta(ls[i].id).limits;
            if (!(lims && lims.length))
                out.push(ls[i].name);
        }
        return out;
    }
    function limitCells(cap) {
        var m = root._mm();
        if (m.limCells)
            return cap > 0 ? m.limCells.slice(0, cap) : m.limCells;
        var cells = [], i, j, lim, ms, wms;
        var ls = lanes().list;
        for (i = 0; i < ls.length; i++) {
            var d = ls[i], mt = meta(d.id), lims = mt.limits;
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
        var ls = lanes().list;
        for (i = 0; i < ls.length; i++) {
            var d = ls[i], mt = meta(d.id), lims = mt.limits;
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
            }
        }
        m.resetMarks = marks;
        return marks;
    }

    // ================= history (trend) =====================================
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
    // last 30 local days, oldest -> today (M tokens per lane key)
    function skyRows() {
        if (!root.shown)
            return [];
        var m = root._mm();
        if (m.skyRows)
            return m.skyRows;
        var idx = histIndex(), rows = [];
        var today = new Date(root.nowMs || Date.now());
        today.setHours(0, 0, 0, 0);
        var ls = lanes().list;
        for (var i = 29; i >= 0; i--) {
            var d = new Date(today.getTime() - i * 86400e3);
            var iso = isoDay(d), parts = {}, total = 0;
            for (var k = 0; k < ls.length; k++) {
                var r = idx[ls[k].id] ? idx[ls[k].id][iso] : null;
                var v = hval(r);
                if (v > 0) { parts[ls[k].key] = v; total += v; }
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
    // ISO-week buckets, oldest -> current (M tokens per lane key); the ledger
    // keeps 90 days of history so up to ~13 full weeks resolve
    function weekRows() {
        if (!root.shown)
            return [];
        var m = root._mm();
        if (m.weekRows)
            return m.weekRows;
        var idx = histIndex(), ls = lanes().list;
        var thisMon = weekStart(new Date(root.nowMs || Date.now()));
        var rows = [];
        for (var w = 11; w >= 0; w--) {
            var mon = new Date(thisMon.getTime() - w * 7 * 86400e3);
            var parts = {}, total = 0;
            for (var dd = 0; dd < 7; dd++) {
                var iso = isoDay(new Date(mon.getTime() + dd * 86400e3));
                for (var k = 0; k < ls.length; k++) {
                    var r = idx[ls[k].id] ? idx[ls[k].id][iso] : null;
                    var v = hval(r);
                    if (v > 0) { parts[ls[k].key] = (parts[ls[k].key] || 0) + v; total += v; }
                }
            }
            rows.push({ "iso": isoDay(mon),
                        "label": isoWeek(mon) + "·" + isoDay(mon).slice(5),
                        "total": total, "parts": parts, "partial": w === 0 });
        }
        var first = -1;
        for (var zi = 0; zi < rows.length; zi++) {
            if ((rows[zi].total || 0) > 0) { first = zi; break; }
        }
        if (first > 0)
            rows = rows.slice(first);
        m.weekRows = rows;
        return rows;
    }
    function trendRows() {
        return root.period === "week" ? weekRows() : skyRows();
    }
    function lastHist(pid) {
        var h = (root.tokData && root.tokData.history) ? root.tokData.history : {};
        var rows = h[pid] || [];
        return rows.length ? String(rows[rows.length - 1].d || "") : "";
    }
    function histLag(pid) {
        var lh = lastHist(pid);
        var today = isoDay(new Date(root.nowMs || Date.now()));
        if (!lh) return "no rows";
        return lh < today ? "last " + lh.slice(5) : "";
    }
    // lanes that appear in the trend legend/stack — only ones with any
    // history in the displayed window, ranked by window Σ (legend caps at 8)
    function stackLanes() {
        var m = root._mm();
        if (m.stackLanes)
            return m.stackLanes;
        var ls = lanes().list, rows = trendRows(), tot = {};
        for (var i = 0; i < rows.length; i++) {
            var parts = rows[i].parts || {};
            for (var k in parts) tot[k] = (tot[k] || 0) + parts[k];
        }
        var out = [];
        for (i = 0; i < ls.length; i++)
            if (tot[ls[i].key])
                out.push({ "key": ls[i].key, "label": ls[i].name,
                           "col": ls[i].col, "dash": ls[i].dash,
                           "winSum": tot[ls[i].key] });
        out.sort(function (a, b) { return b.winSum - a.winSum; });
        m.stackLanes = out;
        return out;
    }
    function legendLanes() {
        var s = stackLanes();
        if (s.length <= 8) return s;
        var out = s.slice(0, 8);
        out.push({ "key": "_more", "label": "+ " + (s.length - 8) + " lanes",
                   "col": null, "dash": [], "winSum": 0 });
        return out;
    }

    function trendStats() {
        var r = trendRows(), s = 0, nz = 0, mx = 0, mxl = "";
        for (var i = 0; i < r.length; i++) {
            var v = r[i].total || 0;
            s += v;
            if (v > 0) { nz++; if (v > mx) { mx = v; mxl = r[i].label; } }
        }
        return { "sum": s, "active": nz, "n": r.length, "mx": mx, "mxl": mxl };
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
    // 2x2 grid: TOKENS | PROVIDERS over TREND | LIMITS
    readonly property int mg: FuiTokens.deckMargin
    readonly property int gg: 24
    readonly property real row1H: (height - 2 * mg - gg) * 0.50
    readonly property real row2Y: mg + row1H + gg
    readonly property real row2H: height - row2Y - mg
    readonly property real heroW: (width - 2 * mg - gg) * 0.56
    readonly property real rightX: mg + heroW + gg
    readonly property real rightW: width - rightX - mg

    // ---------------- TKN-01 hero ----------------------------------------
    FuiFrame {
        x: root.mg; y: root.mg
        width: root.heroW; height: root.row1H
        code: "TKN-01"
        title: "Tokens / " + (root.period === "week" ? "week" : "day")
        meta: "src: tokens.json · event lanes · " + root.ledgerStamp()

        Item {
            id: heroArea
            anchors.fill: parent

            // period segmented control, top-left
            Tk.PeriodToggle {
                id: pToggle
                anchors { left: parent.left; top: parent.top; topMargin: 2 }
                value: root.period
                segments: [
                    { "v": "day",  "label": "DAY" },
                    { "v": "week", "label": "WEEK" }
                ]
                onPicked: function (v) { root.setPeriod(v) }
            }
            Tk.Tx {
                role: "cap"; tone: FuiTokens.dim
                anchors { left: pToggle.right; leftMargin: 14
                          verticalCenter: pToggle.verticalCenter }
                text: root.periodScope()
            }

            // left column — period Σ + rate block
            Column {
                id: heroLeft
                anchors { left: parent.left; top: parent.top; topMargin: 56
                          bottom: parent.bottom }
                width: Math.min(320, Math.max(250, parent.width * 0.34))
                spacing: 6

                Tk.Tx { role: "hdr"; text: "TOKENS " + (root.period === "week" ? "/ ISO WEEK" : "/ TODAY") }
                Item {
                    width: parent.width; height: heroNum.implicitHeight
                    Tk.Tx {
                        id: heroNum
                        role: "num"
                        font.family: FuiTokens.display
                        font.pixelSize: FuiTokens.px.hero
                        anchors.left: parent.left
                        text: {
                            var s = root.periodSum();
                            if (s <= 0) return "0";
                            var t = FuiTokens.fmtTok(s);
                            return t.slice(0, -1);
                        }
                    }
                    Tk.Tx {
                        role: "num"
                        font.pixelSize: FuiTokens.px.big
                        tone: FuiTokens.ice
                        anchors { left: heroNum.right; leftMargin: 6
                                  bottom: heroNum.bottom; bottomMargin: 7 }
                        text: {
                            var s = root.periodSum();
                            var t = FuiTokens.fmtTok(s);
                            return s > 0 && /[BKM]$/.test(t) ? t.slice(-1) : "";
                        }
                    }
                }
                Tk.Tx {
                    role: "cap"; tone: FuiTokens.dim
                    text: "Σ in + out · " + root.periodScope()
                }
                Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3
                            visible: root.periodSum() > 0 }
                // burn-rate block — a true average over the elapsed period,
                // not an instantaneous rate; the label says what it measures
                Column {
                    width: parent.width
                    visible: root.periodSum() > 0
                    spacing: 3
                    Item {
                        width: parent.width; height: 15
                        Tk.Tx { role: "lbl"; text: "AVG RATE"; anchors.left: parent.left }
                        Tk.Tx {
                            role: "num"
                            anchors { right: parent.right }
                            text: {
                                var s = root.periodSum();
                                return s > 0 ? (FuiTokens.fmtTok(s / root.elapsedH()) + "/h")
                                             : FuiTokens.unknownGlyph;
                            }
                        }
                    }
                    Tk.Tx {
                        role: "cap"; tone: FuiTokens.mute
                        text: "period Σ ÷ " + root.elapsedH().toFixed(1)
                              + "h elapsed (" + (root.period === "week" ? "Mon 00:00" : "00:00")
                              + " anchor)"
                    }
                    Item {
                        width: parent.width; height: 15
                        Tk.Tx { role: "lbl"; text: "PACE PROJ"; anchors.left: parent.left }
                        Tk.Tx {
                            role: "num"; tone: FuiTokens.ice
                            anchors { right: parent.right }
                            text: {
                                var s = root.periodSum();
                                return s > 0
                                    ? FuiTokens.fmtTok(s / root.elapsedH() * root.periodSpanH())
                                    : FuiTokens.unknownGlyph;
                            }
                        }
                    }
                    Tk.Tx {
                        role: "cap"; tone: FuiTokens.mute
                        text: "at current avg · full "
                              + (root.period === "week" ? "168h week" : "24h day")
                    }
                }
                Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3 }
                Tk.Tx {
                    role: "cap"; tone: FuiTokens.faint
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "ring arc: lane share of period Σ · thick arc: provider limit used · bezel 0..100%"
                }
                Tk.Tx {
                    role: "cap"; tone: FuiTokens.faint
                    visible: {
                        var l = root.laneSplit("codex");
                        return l.snap !== null;
                    }
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: {
                        var l = root.laneSplit("codex");
                        return l.snap !== null
                            ? "codex snapshot lane " + FuiTokens.fmtTok(l.snap)
                              + " held separate (never summed)" : "";
                    }
                }
            }

            // centre/right — concentric rings: thin arc = share of period Σ,
            // thick arc = limit used; per-lane labels lower-left (no chips)
            Item {
                id: ringBox
                anchors { left: heroLeft.right; leftMargin: 20
                          right: parent.right; top: parent.top; topMargin: 44
                          bottom: parent.bottom }
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
                            role: "lbl"; text: "SHARE OF Σ"; tone: FuiTokens.ice
                        }
                        Tk.Tx {
                            anchors.horizontalCenter: parent.horizontalCenter
                            role: "cap"; tone: FuiTokens.dim
                            text: root.period === "week" ? "ISO " + root.isoWeek(new Date(root.nowMs || Date.now()))
                                                         : "TODAY"
                        }
                        Tk.Tx {
                            anchors.horizontalCenter: parent.horizontalCenter
                            role: "num"; font.pixelSize: FuiTokens.px.mid
                            text: root.periodSum() > 0
                                  ? FuiTokens.fmtTok(root.periodSum())
                                  : "0"
                        }
                    }
                }
            }
        }
    }

    // ---------------- PRV-02 providers ------------------------------------
    FuiFrame {
        x: root.rightX; y: root.mg
        width: root.rightW; height: root.row1H
        code: "PRV-02"
        title: "Providers / " + (root.period === "week" ? "ISO week" : "today")
        meta: "src: tokens.json · " + root.ledgerStamp()

        Item {
            id: prvBox
            anchors.fill: parent
            readonly property var ls: root.lanes().list
            // hot lanes ranked by period Σ — non-zero first (value desc), then
            // idle feeds by last-seen date so recently-live lanes keep a row
            readonly property var hot: {
                var a = ls.filter(function (l) { return l.hasFeed; });
                a.sort(function (x, y) {
                    var vx = x.v || 0, vy = y.v || 0;
                    if ((vx > 0) !== (vy > 0)) return vy - vx;
                    if (vx > 0 && vy > 0) return vy - vx;
                    var lx = root.lastHist(x.id), ly = root.lastHist(y.id);
                    if (lx !== ly) return lx < ly ? 1 : -1;
                    return x.name < y.name ? -1 : 1;
                });
                return a;
            }
            readonly property var cold: ls.filter(function (l) { return !l.hasFeed; })
            readonly property real rowH: 30
            readonly property real headH: 20
            // footer reserve: Σ row + up to two collapse lines
            readonly property real footH: 60
            readonly property int rowCap: Math.max(3, Math.floor((height - headH - footH - 10) / (rowH + 2)))
            readonly property var shownLanes: hot.slice(0, rowCap)
            readonly property var over: hot.slice(rowCap)
            readonly property var idleOver: over.filter(function (l) {
                return !(l.v !== null && l.v > 0);
            }).map(function (l) { return l.name; })
            readonly property real overSum: over.reduce(function (a, l) {
                return a + ((l.v !== null && l.v > 0) ? l.v : 0);
            }, 0)
            readonly property int overNz: over.filter(function (l) {
                return l.v !== null && l.v > 0;
            }).length

            // column header
            Item {
                id: prvHead
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 20
                Tk.Tx { role: "code"; text: "LANE"; anchors.left: parent.left; leftPadding: 34 }
                Tk.Tx { role: "code"; text: root.period === "week" ? "WEEK" : "TODAY"
                        anchors.right: shTx.left; anchors.rightMargin: 10
                        width: 84; horizontalAlignment: Text.AlignRight }
                Tk.Tx { id: shTx; role: "code"; text: "SHARE"
                        anchors.right: parent.right; width: 60
                        horizontalAlignment: Text.AlignRight }
            }
            Rectangle { anchors { left: parent.left; right: parent.right
                                  top: prvHead.bottom }
                        height: 1; color: FuiTokens.hair2 }

            Column {
                id: prvCol
                anchors { left: parent.left; right: parent.right
                          top: prvHead.bottom; topMargin: 6 }
                spacing: 2
                Repeater {
                    model: prvBox.shownLanes
                    delegate: Item {
                        id: prow
                        required property int index
                        required property var modelData
                        width: prvCol.width
                        height: 30
                        // lane swatch (colour + dash shared with ring + skyline)
                        Canvas {
                            id: sw
                            width: 24; height: 10
                            anchors { left: parent.left; leftMargin: 4
                                      verticalCenter: parent.verticalCenter }
                            property var lane: prow.modelData
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.clearRect(0, 0, width, height);
                                ctx.strokeStyle = FuiTokens.css(lane.col);
                                ctx.lineWidth = 1.4;
                                if (lane.dash === "double") {
                                    ctx.beginPath(); ctx.moveTo(0, 3); ctx.lineTo(width, 3); ctx.stroke();
                                    ctx.beginPath(); ctx.moveTo(0, 7); ctx.lineTo(width, 7); ctx.stroke();
                                } else {
                                    ctx.setLineDash(lane.dash || []);
                                    ctx.beginPath(); ctx.moveTo(0, 5); ctx.lineTo(width, 5); ctx.stroke();
                                    ctx.setLineDash([]);
                                }
                            }
                            onLaneChanged: requestPaint()
                        }
                        Tk.Tx {  // name (module dir, no prefix needed)
                            role: "lbl"; text: prow.modelData.name; tone: FuiTokens.white
                            anchors { left: parent.left; leftMargin: 34
                                      verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitWidth, 190)
                            elide: Text.ElideRight
                        }
                        Tk.Tx {
                            role: "num"
                            anchors { right: shareBox.left; rightMargin: 10
                                      verticalCenter: parent.verticalCenter }
                            width: 84; horizontalAlignment: Text.AlignRight
                            text: prow.modelData.v !== null && prow.modelData.v > 0
                                  ? FuiTokens.fmtTok(prow.modelData.v)
                                  : (prow.modelData.v === 0 ? "0" : FuiTokens.unknownGlyph)
                        }
                        // share bar + % — one visual per lane, period-scoped
                        Item {
                            id: shareBox
                            anchors { right: shPct.left; rightMargin: 10
                                      verticalCenter: parent.verticalCenter }
                            width: Math.max(80, Math.min(190, parent.width * 0.28))
                            height: 8
                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"; border.width: 1
                                border.color: FuiTokens.hair3
                            }
                            Rectangle {
                                anchors { left: parent.left; top: parent.top
                                          bottom: parent.bottom }
                                width: prow.modelData.share !== null
                                       ? Math.max(2, parent.width * prow.modelData.share) : 0
                                color: FuiTokens.tone(prow.modelData.col, 0.55)
                                visible: prow.modelData.share !== null
                            }
                        }
                        Tk.Tx {
                            id: shPct
                            role: "num"; tone: FuiTokens.dim
                            anchors { right: parent.right; rightMargin: 2
                                      verticalCenter: parent.verticalCenter }
                            width: 60; horizontalAlignment: Text.AlignRight
                            text: prow.modelData.share !== null
                                  ? (prow.modelData.share * 100).toFixed(1) + "%"
                                  : FuiTokens.unknownGlyph
                        }
                        // honesty line under the row: idle lanes say when they
                        // last produced, auth lanes say what is missing
                        Tk.Tx {
                            role: "faint"
                            anchors { left: parent.left; leftMargin: 34
                                      bottom: parent.bottom; bottomMargin: -1 }
                            font.pixelSize: FuiTokens.px.micro
                            text: {
                                var l = prow.modelData;
                                if (root.isAuth(root.meta(l.id))) return "auth pending";
                                if (l.v !== null && l.v > 0) return "";
                                var lag = root.histLag(l.id);
                                if (lag === "no rows") return "no recorded feed";
                                if (lag !== "") return "idle · " + lag;
                                return "idle today";
                            }
                        }
                    }
                }
            }

            // overflow + cold lanes collapse to honest lines; Σ row pins total
            Item {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: sigRow.height + 8
                        + (idleTx.visible ? idleTx.implicitHeight + 4 : 0)
                        + (coldTx.visible ? coldTx.implicitHeight + 4 : 0)
                Tk.Tx {
                    id: idleTx
                    role: "cap"; tone: FuiTokens.faint
                    anchors { left: parent.left; right: parent.right
                              bottom: coldTx.visible ? coldTx.top : sigRow.top
                              bottomMargin: 4 }
                    visible: prvBox.over.length > 0
                    text: {
                        var p = prvBox, t = "";
                        if (p.overNz > 0)
                            t = "+ " + p.overNz + " lanes · Σ "
                                + FuiTokens.fmtTok(p.overSum);
                        if (p.idleOver.length > 0)
                            t += (t !== "" ? " · " : "") + "0 in window: "
                                 + p.idleOver.join(" · ");
                        return t;
                    }
                    elide: Text.ElideRight
                }
                Tk.Tx {
                    id: coldTx
                    role: "cap"; tone: FuiTokens.faint
                    anchors { left: parent.left; right: parent.right
                              bottom: sigRow.top; bottomMargin: 4 }
                    visible: prvBox.cold.length > 0
                    text: "no recorded feed: "
                          + prvBox.cold.map(function (l) { return l.name; }).join(" · ")
                    elide: Text.ElideRight
                }
                Item {
                    id: sigRow
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 20
                    Rectangle { anchors { left: parent.left; right: parent.right
                                          top: parent.top; topMargin: -4 }
                                height: 1; color: FuiTokens.hair2 }
                    Tk.Tx {
                        role: "hdr"; text: "Σ " + (root.period === "week" ? "ISO WEEK" : "TODAY")
                        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    }
                    Tk.Tx {
                        role: "num"
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        text: root.periodSum() > 0 ? FuiTokens.fmtTok(root.periodSum()) : "0"
                    }
                }
            }
        }
    }

    // ---------------- TRD-03 trend ----------------------------------------
    FuiFrame {
        x: root.mg; y: root.row2Y
        width: root.heroW; height: root.row2H
        code: "TRD-03"
        title: root.period === "week" ? "Trend / ISO weeks" : "Trend / 30 days"
        meta: {
            var r = root.trendRows();
            return "src: tokens.json history · " + (r.length ? r[0].label : "—")
                 + ".." + (r.length ? r[r.length - 1].label : "—") + " · " + root.ledgerStamp();
        }

        Item {
            anchors.fill: parent

            // legend — wrapping Flow in a reserved strip above the bars
            Flow {
                id: keyFlow
                anchors { left: parent.left; top: parent.top; leftMargin: 58
                          right: readRail.left; rightMargin: 12; topMargin: 2 }
                spacing: 6
                Repeater {
                    model: root.legendLanes()
                    delegate: Row {
                        required property var modelData
                        spacing: 4
                        rightPadding: 8
                        Canvas {
                            width: 20; height: 10
                            anchors.verticalCenter: parent.verticalCenter
                            visible: parent.modelData.col !== null
                            property var md: parent.modelData
                            onPaint: {
                                var ctx = getContext("2d");
                                ctx.clearRect(0, 0, width, height);
                                if (!md.col) return;
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
                rows: root.trendRows()
                providers: root.stackLanes()
            }

            // right readout rail — window statistics only (no duplicated
            // per-provider table; PRV-02 owns the breakdown)
            Column {
                id: readRail
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: Math.min(210, parent.width * 0.24)
                spacing: 3
                Tk.Tx { role: "hdr"; text: root.period === "week" ? "WK Σ" : "30D Σ" }
                Item {
                    width: parent.width; height: sumNum.implicitHeight
                    Tk.Tx {
                        id: sumNum
                        role: "num"
                        font.pixelSize: FuiTokens.px.big + 4
                        anchors.left: parent.left
                        text: {
                            var s = root.trendStats().sum;
                            return s >= 1000 ? (s / 1000).toFixed(2) : s.toFixed(0);
                        }
                    }
                    Tk.Tx { role: "num"; tone: FuiTokens.ice; font.pixelSize: FuiTokens.px.mid
                            text: root.trendStats().sum >= 1000 ? "B" : "M"
                            anchors { left: sumNum.right; leftMargin: 6
                                      bottom: sumNum.bottom; bottomMargin: 4 } }
                }
                Tk.MiniTable {
                    width: parent.width
                    header: false
                    rowH: 16
                    columns: [
                        { "key": "nm", "label": "", "role": "dim" },
                        { "key": "v",  "label": "", "align": "r" },
                        { "key": "t",  "label": "", "align": "r", "role": "faint", "w": 52 }
                    ]
                    rows: {
                        var s = root.trendStats();
                        var bucket = root.period === "week" ? "/ wk" : "/ day";
                        function fm(vv) {
                            return vv >= 1000 ? (vv / 1000).toFixed(2) + "B"
                                 : vv >= 10 ? vv.toFixed(1) + "M" : vv.toFixed(2) + "M";
                        }
                        return [
                            { "nm": "avg" + bucket, "v": fm(s.n ? s.sum / s.n : 0), "t": "all" },
                            { "nm": "avg" + bucket, "v": s.active ? fm(s.sum / s.active) : "—", "t": "act" },
                            { "nm": "buckets", "v": s.active + " / " + s.n, "t": "live" },
                            { "nm": "peak", "v": s.mx > 0 ? fm(s.mx) : "—", "t": s.mxl }
                        ];
                    }
                }
                Rectangle { width: parent.width; height: 1; color: FuiTokens.hair3 }
                Tk.Tx {
                    role: "cap"; tone: FuiTokens.faint
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: root.period === "week"
                          ? "buckets = ISO weeks (Mon-start) · current week partial"
                          : "buckets = local days · today partial · dashed footprint = no record"
                }
            }
        }
    }

    // ---------------- LIM-04 limits ---------------------------------------
    FuiFrame {
        x: root.rightX; y: root.row2Y
        width: root.rightW; height: root.row2H
        code: "LIM-04"
        title: "Limits / resets"
        meta: "src: tokens.json limits[] · " + root.ledgerStamp()

        Item {
            id: limGrid
            anchors.fill: parent
            readonly property var cells: root.limitCells(4)
            readonly property var compactCells: cells.filter(function (c) {
                return c.sev === "warn" && c.frac === null && c.action !== null;
            })
            readonly property var gridCells: cells.filter(function (c) {
                return !(c.sev === "warn" && c.frac === null && c.action !== null);
            })
            readonly property int nCells: Math.min(4, gridCells.length)
            readonly property int cols: 2
            readonly property int nRows: Math.ceil(nCells / cols)
            readonly property real stripH: compactCells.length > 0
                                           ? compactCells.length * 34 + 4 : 0
            readonly property real nfH: root.noFeedProviders.length > 0 ? 20 : 0
            readonly property real tlH: Math.max(46, Math.min(120, height * 0.24))
            readonly property real cardsH: height - stripH - nfH - tlH - 30
            readonly property real ch2: nRows > 0
                    ? Math.max(120, (cardsH - (nRows - 1) * 9) / nRows) : 0
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
                model: limGrid.gridCells.slice(0, 4)
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

            // collapsed providers without a limits[] feed — one honest line
            Item {
                visible: limGrid.nfH > 0
                x: 8
                y: 4 + limGrid.stripH + limGrid.nRows * (limGrid.ch2 + 9)
                width: limGrid.width - 16
                height: limGrid.nfH
                Tk.Tx {
                    role: "cap"; tone: FuiTokens.faint
                    anchors { left: parent.left; right: parent.right
                              verticalCenter: parent.verticalCenter }
                    text: "no limit feed: " + root.noFeedProviders.join(" · ")
                    elide: Text.ElideRight
                }
                HoverHandler { id: stripHover }
                QQC.ToolTip {
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
                    Tk.Tx {
                        role: "cap"; tone: FuiTokens.dim
                        anchors { right: parent.right }
                        text: {
                            var b = root.limitBus();
                            return b.alert + " exh · " + b.warn + " warn · "
                                 + b.ok + " ok · " + b.na + " no feed";
                        }
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
}
