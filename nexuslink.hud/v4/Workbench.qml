pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets

// Workbench.qml — HDMI-A-3 "WORKBENCH + APPS NAV" (lane D3).
// Visual spec: candidates/mock2/B/hdmi.html. Left column is the operations
// ledger (workspaces+windows with click-to-focus, agent sessions, process
// ledger, github activity, token ledger). Right column stacks two panes —
// DEVICES (DeviceBay.qml — connected peripherals + hotplug cards, lane W1)
// over APPS NAVIGATOR (AppGrid.qml — installed .desktop apps,
// type-to-filter, gtk-launch). No tab gate: both render at all times.
// A shared UtilityDock strip anchors the bottom (owned by lane D1).
// Lane W1 additions: static-lit KnotField watermark behind the panes,
// window-row app icons, tightened ledger density, and the token ledger's
// fixed-height overrun into the dock repaired (fractions now apply to the
// distributable column height; the column clips as a second line of defence).
//
// LANE-SB2 (visual quality pass) — the same screen, built on one grid:
//   * met (pad/headH/footH/innerGap/gap + the hover wash) is the only place
//     the rhythm is written down; GlassPane's own `padding` owns the pane
//     inset, so the five ledger panes and the two right-column panes all sit
//     on the same 12px column.
//   * PaneHead / PaneFoot / EmptyNote are the chassis primitives: accent tick
//     + Michroma title + quiet mono sub, a hairline + status line, and one
//     wording shape for "no data". Every ledger pane now declares what it
//     holds and what it dropped, in the same place, in the same type.
//   * Each pane is sized from a fixed row capacity and a shared stretch, so
//     the column's five heights sum to the column exactly at the shipped
//     window size and degrade evenly below it — no pane silently clips its
//     last row, and the token ledger spends the leftover room on real rows.
//   * the workspace strip is a fixed-pitch scale with a fold chip; the token
//     table's columns are responsive so no pane can push a row past its face.
//
// Data honesty (BRIEF-V4-BUILD §3): a key the collector does not emit
// renders as "—", never 0, never a fabricated value. No animation clocks —
// nothing on this screen moves on a timer. The single 1 Hz tick is the
// masthead's HH:mm:ss readout; the ledger age and burn pace divide it down
// to a minute so their bindings re-evaluate 60x less often. Every data
// repaint is driven by the stats delta delivered through HudV4.

Item {
    id: root

    // ---- injected by HudV4.qml (lane H) ----
    property var stats: ({})            // last applyFrame map, key -> string
    property var tokData: ({})          // parsed ~/.local/state/nexuslink/tokens.json
    property string screenName: "HDMI-A-3"

    // ---- contract module handle (lanes S/T write these in parallel) ----
    // Palette/font fallbacks mirror BRIEF-V4-BUILD §Contracts so the screen
    // still renders while Style.qml is in flight.
    readonly property var sty: (typeof Style !== "undefined") ? Style : null

    function col(key, fallback) {
        return (root.sty !== null && root.sty.c && root.sty.c[key] !== undefined) ? root.sty.c[key] : fallback;
    }
    // Font sizes ride the Style.f ramp as well (lane W1 density pass) —
    // pxMicro/pxTag/pxLabel instead of scattered hardcoded sizes.
    function fs(key, fallback) {
        return (root.sty !== null && root.sty.f && root.sty.f[key] !== undefined) ? root.sty.f[key] : fallback;
    }

    QtObject {
        id: pal
        readonly property color bg: root.col("bg", "#0b0e11")
        readonly property color edge: root.col("edge", "#2a3138")
        readonly property color accent: root.col("accent", "#c8f31d")
        readonly property color accent2: root.col("accent2", "#8fd8e8")
        readonly property color warn: root.col("warn", "#ffb300")
        readonly property color alert: root.col("alert", "#ff4a3d")
        readonly property color unknown: root.col("unknown", "#5a646c")
        readonly property color txt: root.col("txt", "#d9e2ea")
        readonly property color t55: root.col("t55", "#8b959e")
        readonly property color t40: root.col("t40", "#5f686f")
        readonly property color ink: root.col("ink", "#14171c")
        readonly property color well: root.col("well", "#0d0f13")
        readonly property string fDisp: (root.sty !== null && root.sty.f && root.sty.f.display) ? root.sty.f.display : "Michroma"
        readonly property string fMono: (root.sty !== null && root.sty.f && root.sty.f.mono) ? root.sty.f.mono : "Kode Mono"
    }

    // The one grid every pane on this screen is built on. `pad` is handed to
    // GlassPane's own `padding` so the glass bevel owns the inset and the
    // pane body never restates it; headH/footH/innerGap are the three bands
    // inside that inset. Change one number here and all five ledger panes,
    // the tab strip and the dock strip realign together.
    QtObject {
        id: met
        readonly property int pad: 12      // pane content inset (GlassPane.padding)
        readonly property int headH: 13     // pane header band (10px Michroma + 3 air)
        readonly property int footH: 13     // pane footer band (rule + 8px mono)
        readonly property int innerGap: 5    // gap between a pane's three bands
        readonly property int gap: 10       // gap between panes / layout bands
        // tracking for the display type, named so the masthead and the pane
        // chassis can never drift apart
        readonly property real lsHead: 3
        readonly property real lsMast: 4
        readonly property real lsTag: 2
        // hover wash + lit line, one value for every card in this screen
        readonly property color wash: Qt.rgba(0.56, 0.85, 0.91, 0.07)
        readonly property color litLine: pal.accent2
        readonly property color selFill: Qt.rgba(0.78, 0.95, 0.11, 0.10)
    }

    // Michroma + Kode Mono are registered globally by Theme.qml's FontLoaders
    // (installed under ~/.local/share/fonts/nexushud/) — no per-file loaders.

    // ---------------------------------------------------------- helpers
    function has(k) {
        return stats[k] !== undefined;
    }
    // NOTE: num() coerces garbage to 0 — call it ONLY behind a has() guard
    // (or on values already proven present), never on an unchecked key.
    function num(v) {
        var n = Number(v);
        return isFinite(n) ? n : 0;
    }

    // ---- unknown contract (BRIEF §3) ----------
    // Anything unknown renders Style.unknownGlyph, and absent count keys
    // stay -1 so the UI can show the glyph, never a valid-looking 0.
    readonly property string unk: (root.sty !== null && root.sty.unknownGlyph !== undefined) ? root.sty.unknownGlyph : "—"
    function cnt(v) {
        return v < 0 ? unk : String(v);
    }

    function fmtTok(n) {
        var v = Number(n);
        if (n === null || n === undefined || !isFinite(v))
            return "—";
        if (v >= 1e9)
            return (v / 1e9).toFixed(2) + "B";
        if (v >= 1e6)
            return (v / 1e6).toFixed(1) + "M";
        if (v >= 1e3)
            return (v / 1e3).toFixed(1) + "k";
        return String(Math.round(v));
    }
    function fmtCost(c) {
        if (c === null || c === undefined)
            return "";
        var v = Number(c);
        if (!isFinite(v))
            return "";
        if (v >= 10)
            return "$" + v.toFixed(1);
        if (v >= 1)
            return "$" + v.toFixed(2);
        if (v > 0)
            return "$" + v.toFixed(3);
        return "";
    }
    // One ledger window bucket -> {t, tin, tout, cost, msgs}; NaN = "not
    // reported". tokens/SCHEMA.md: `in` already folds in cache-read/write;
    // snapshot-only providers carry in/out:null with `total` as the real
    // figure — never sum `total` on top of in/out.
    function tokBucket(b) {
        var r = {
            t: NaN,
            tin: NaN,
            tout: NaN,
            cost: NaN,
            msgs: NaN
        };
        if (b === null || b === undefined || typeof b !== "object")
            return r;
        var ii = (b["in"] === null || b["in"] === undefined) ? NaN : Number(b["in"]);
        var oo = (b.out === null || b.out === undefined) ? NaN : Number(b.out);
        if (isFinite(ii))
            r.tin = ii;
        if (isFinite(oo))
            r.tout = oo;
        if (isFinite(ii) || isFinite(oo))
            r.t = (isFinite(ii) ? ii : 0) + (isFinite(oo) ? oo : 0);
        else if (b.total !== null && b.total !== undefined && isFinite(Number(b.total)))
            r.t = Number(b.total);
        var cc = (b.cost === null || b.cost === undefined) ? NaN : Number(b.cost);
        if (isFinite(cc))
            r.cost = cc;
        var mm = (b.msgs === null || b.msgs === undefined) ? NaN : Number(b.msgs);
        if (isFinite(mm))
            r.msgs = mm;
        return r;
    }
    function fmtAge(s) {
        var v = num(s);
        if (v < 60)
            return Math.round(v) + "s";
        if (v < 3600)
            return Math.round(v / 60) + "m";
        if (v < 86400)
            return Math.round(v / 3600) + "h";
        return Math.round(v / 86400) + "d";
    }

    // ----------------------------------------------------- row actions
    // Same argv-only contract as Navigator.qml/UtilityDock.qml: every launch
    // is Quickshell.execDetached through the constant `exec "$@"` login
    // wrapper — no shell string concatenation anywhere (hyprctl args are a
    // single literal Lua dispatcher expression passed as ONE argv element).
    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "wb"].concat(argv));
    }
    // hl.dsp.focus — the shell's Lua dispatcher wrapper (omarchy shell's
    // Workspaces.qml runs `hyprctl dispatch 'hl.dsp.focus({ workspace = "N" })'`;
    // the expose plugin focuses windows with the same `{ window = "..." }` spec).
    function focusWorkspace(id) {
        var n = Math.round(Number(id));
        if (!isFinite(n))
            return;
        execArgv(["hyprctl", "dispatch", 'hl.dsp.focus({ workspace = "' + n + '" })']);
    }
    function focusWindowAddr(addr) {
        var a = String(addr || "").replace(/[^0-9a-fA-Fx]/g, "");
        if (a === "")
            return;
        execArgv(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:' + a + '" })']);
    }
    function focusWindowClass(cls) {
        var c = String(cls || "").replace(/[^A-Za-z0-9_.\-]/g, "");
        if (c === "")
            return;
        execArgv(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "class:' + c + '" })']);
    }
    // Harness rows: gtk-launch the desktop id where one exists on disk
    // (/usr/share/applications/devin-desktop.desktop;
    // ~/.local/share/applications/{october,haze}.desktop — opencode has no
    // .desktop, so it falls back to focusing a matching window class, which
    // no-ops cleanly when absent).
    readonly property var agLaunch: ({
            "devin": "devin-desktop",
            "october": "october",
            "haze": "haze"
        })
    function openAgent(id) {
        var d = agLaunch[id];
        if (d !== undefined)
            execArgv(["gtk-launch", d]);
        else
            focusWindowClass(id);
    }
    // Repo rows: ghev{i}_repo is a GitHub "owner/name" — there is no local
    // path key in the stats stream. Probe the usual checkout roots for the
    // basename; hit → gtk-launch devin-desktop <dir> (%F takes the path),
    // miss → xdg-open the repo URL. The probe argv carries the basename as
    // "$1" — the script text is a fixed literal, nothing interpolated.
    property string _repoProbeUrl: ""
    function openRepo(full) {
        var r = String(full || "");
        if (!/^[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+$/.test(r))
            return;
        if (repoProbe.running)
            return;     // one probe in flight — a double-click can't rewrite its argv
        _repoProbeUrl = "https://github.com/" + r;
        repoProbe.command = ["bash", "-lc",
            'for base in "$HOME/projects" "$HOME/Projects" "$HOME/repos"; do d="$base/$1"; if [ -d "$d" ]; then printf "%s" "$d"; exit 0; fi; done',
            "wb", r.split("/")[1]];
        repoProbe.running = true;
    }
    Process {
        id: repoProbe
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var d = String(text).trim();
                if (d !== "")
                    root.execArgv(["gtk-launch", "devin-desktop", d]);
                else if (root._repoProbeUrl !== "")
                    root.execArgv(["uwsm-app", "--", "xdg-open", root._repoProbeUrl]);
            }
        }
    }
    // process ledger selection (click = select/detail; no kill actions)
    property int selProc: -1

    // ------------------------------------------------ workspaces/windows
    // -1 = key absent → unknown (the glyph renders downstream), never a
    // fabricated 0 (BRIEF §3 / verifier B7).
    readonly property int wsCount: has("ws_count") ? Math.max(0, num(stats.ws_count)) : -1
    readonly property int winCount: has("win_count") ? Math.max(0, num(stats.win_count)) : -1
    function wsList() {
        var n = Math.min(14, wsCount);
        var a = [];
        for (var i = 0; i < n; i++) {
            if (!has("ws" + i + "_id"))
                continue;   // no id → no dispatch target; skip, don't fake one
            a.push({
                id: num(stats["ws" + i + "_id"]),
                name: has("ws" + i + "_name") ? String(stats["ws" + i + "_name"]) : String(num(stats["ws" + i + "_id"])),
                mon: has("ws" + i + "_mon") ? String(stats["ws" + i + "_mon"]) : "",
                wins: has("ws" + i + "_wins") ? Math.max(0, num(stats["ws" + i + "_wins"])) : -1
            });
        }
        a.sort(function (x, y) {
            return x.id - y.id;
        });
        return a;
    }
    // win{i}_mon is a monitor INDEX ("0","1","2"), while ws{i}_mon carries the
    // output name the sort/display wants — resolve the name via the window's
    // workspace id (wsid ↔ ws{j}_id → ws{j}_mon); falls back to the raw key.
    function wsMonName(wsid) {
        var n = Math.min(14, wsCount);
        for (var i = 0; i < n; i++)
            if (has("ws" + i + "_id") && num(stats["ws" + i + "_id"]) === wsid)
                return has("ws" + i + "_mon") ? String(stats["ws" + i + "_mon"]) : "";
        return "";
    }
    // ---- window-row icons (lane W1) --------------------------------------
    // Resolve each window's app icon once per class: the class as an icon
    // theme name first (Quickshell.iconPath — most classes are icon names
    // already, e.g. "firefox"), then a bounded DesktopEntries walk over
    // desktop-id candidates (class, lower, alias, reverse-domain tail,
    // heuristicLookup where the runtime has it). "" = "no icon" -> the
    // delegate draws a glyph, never a fake image. Cached per class so the
    // per-frame winList() rebuild stays O(rows).
    property var iconCache: ({})
    readonly property var iconAlias: ({
            "devin": "devin-desktop",
            "october": "october",
            "code": "visual-studio-code",
            "code - oss": "code-oss",
            "com.visualstudio.code": "visual-studio-code",
            "google-chrome": "google-chrome",
            "org.telegram.desktop": "telegramdesktop",
            "com.discordapp.discord": "discord",
            "signal": "signal-desktop",
            "org.pulseaudio.pavucontrol": "multimedia-volume-control",
            "pavucontrol": "multimedia-volume-control",
            "org.gnome.nautilus": "org.gnome.Nautilus",
            "thunar": "org.xfce.Thunar",
            "org.wezfurlong.wezterm": "wezterm"
        })
    function iconFromEntry(id) {
        var e = null;
        try {
            e = DesktopEntries.byId(id);
            if (!e)
                e = DesktopEntries.byId(id + ".desktop");
        } catch (err) {
            e = null;
        }
        if (e && e.icon && String(e.icon) !== "") {
            var icon = String(e.icon);
            if (icon.charAt(0) === "/")
                return "file://" + icon;
            try {
                return String(Quickshell.iconPath(icon, true) || "");
            } catch (err2) {
                return "";
            }
        }
        return "";
    }
    function winIcon(cls) {
        var c = String(cls || "");
        if (c === "" || c === "?")
            return "";
        var hit = iconCache[c];
        if (hit !== undefined)
            return hit;
        var p = "";
        try {
            p = String(Quickshell.iconPath(c, true) || "");
        } catch (err) {
            p = "";
        }
        var lc = c.toLowerCase();
        if (p === "" && lc !== c) {
            try {
                p = String(Quickshell.iconPath(lc, true) || "");
            } catch (err0) {
                p = "";
            }
        }
        if (p === "") {
            var cands = [lc];
            var al = iconAlias[lc];
            if (al !== undefined && al !== "")
                cands.push(al);
            var seg = lc.split(".");
            if (seg.length > 1 && seg[seg.length - 1] !== "")
                cands.push(seg[seg.length - 1]);
            for (var i = 0; i < cands.length && p === ""; i++)
                p = iconFromEntry(cands[i]);
        }
        // heuristicLookup exists on newer Quickshell builds; guarded so an
        // older runtime still resolves through the candidate walk alone.
        if (p === "") {
            try {
                if (typeof DesktopEntries.heuristicLookup === "function") {
                    var he = DesktopEntries.heuristicLookup(c);
                    if (he && he.icon && String(he.icon) !== "")
                        p = String(Quickshell.iconPath(String(he.icon), true) || "");
                }
            } catch (err3) {
                p = "";
            }
        }
        iconCache[c] = p;
        return p;
    }
    function winList() {
        var n = Math.min(12, winCount);
        var a = [];
        for (var i = 0; i < n; i++) {
            var wsid = has("win" + i + "_wsid") ? num(stats["win" + i + "_wsid"]) : -1;
            var monName = wsid >= 0 ? wsMonName(wsid) : "";
            var cls = has("win" + i + "_class") ? String(stats["win" + i + "_class"]) : "";
            a.push({
                addr: has("win" + i + "_addr") ? String(stats["win" + i + "_addr"]) : "",
                ws: has("win" + i + "_ws") ? String(stats["win" + i + "_ws"]) : "",
                wsid: wsid,
                cls: cls,
                icon: winIcon(cls),
                title: has("win" + i + "_title") ? String(stats["win" + i + "_title"]) : "",
                mon: monName !== "" ? monName : (has("win" + i + "_mon") ? String(stats["win" + i + "_mon"]) : "")
            });
        }
        a.sort(function (x, y) {
            var xm = (x.mon === root.screenName) ? 0 : 1;
            var ym = (y.mon === root.screenName) ? 0 : 1;
            if (xm !== ym)
                return xm - ym;
            return x.wsid - y.wsid;
        });
        return a;
    }
    // Memoised row models — one evaluation per stats delta feeds the fit
    // math, the pane foot and the Repeater alike, instead of each of them
    // calling the builder independently.
    readonly property var winAll: winList()
    readonly property var wsAll: wsList()

    // ------------------------------------------------------ agent lane
    readonly property var harnessIds: ["devin", "opencode", "haze"]
    // Roll-up for the pane foot: how many harness processes are actually
    // live right now. An absent key contributes nothing, never a 0 — so a
    // collector that has not reported yet reads "no live proc", not a lie.
    readonly property int agLiveProcs: {
        var n = 0;
        for (var i = 0; i < harnessIds.length; i++) {
            var r = agRow(harnessIds[i]);
            if (r.procs > 0)
                n += r.procs;
        }
        return n;
    }
    function agRow(h) {
        return {
            id: h,
            procs: has("ag_" + h + "_procs") ? Math.max(0, num(stats["ag_" + h + "_procs"])) : -1,
            cpu: has("ag_" + h + "_cpu") ? num(stats["ag_" + h + "_cpu"]) : -1
        };
    }
    readonly property int devinAcp: has("ag_devin_acp") ? Math.max(0, num(stats.ag_devin_acp)) : -1
    readonly property int devsessCount: has("devsess_count") ? Math.min(6, Math.max(0, num(stats.devsess_count))) : -1

    // ---------------------------------------------------- process lane
    // The collector only fills a slot for a process over 0.5% of one core,
    // and only from the second frame on — so procCount is "slots filled",
    // not "processes running", and the foot reads it as N/6.
    readonly property int procSlots: 6
    readonly property int procCount: {
        var n = 0;
        while (n < procSlots && stats["proc" + n + "_name"] !== undefined)
            n++;
        return n;
    }
    // Busiest slot, for the pane foot. -1 = nothing reported, so the foot
    // says "peak —" instead of a fabricated 0%.
    readonly property int procPeak: {
        var m = -1;
        for (var i = 0; i < procCount; i++) {
            var c = procCpu(i);
            if (c > m)
                m = c;
        }
        return m;
    }
    readonly property var procAll: {
        var a = [];
        for (var i = 0; i < procCount; i++)
            a.push({
                name: procName(i),
                cpu: procCpu(i)
            });
        return a;
    }
    function procName(i) {
        return has("proc" + i + "_name") ? String(stats["proc" + i + "_name"]) : "";
    }
    function procCpu(i) {
        return has("proc" + i + "_cpu") ? num(stats["proc" + i + "_cpu"]) : -1;
    }

    // -------------------------------------------------------- repos/CI
    readonly property bool ghKnown: has("gh_ok")
    readonly property bool ghOk: num(stats.gh_ok) > 0
    readonly property int ghUnread: has("gh_unread") ? Math.max(0, num(stats.gh_unread)) : -1
    readonly property int ghEvCount: has("ghev_count") ? Math.min(6, Math.max(0, num(stats.ghev_count))) : -1
    readonly property var ghevAll: ghevList()
    // "PULLRE" is not a label — substr(0,6) on "PullRequestEvent" produced
    // it. Map GitHub's event names onto a short tag that fits the ledger's
    // type column at its natural width and still reads as a word.
    function ghTypeTag(ev) {
        var e = String(ev).replace("Event", "").toUpperCase()
        if (e === "PULLREQUEST")
            return "PULL"
        if (e === "ISSUES")
            return "ISSUE"
        if (e === "ISSUECOMMENT")
            return "ICMT"
        if (e === "PULLREQUESTREVIEW")
            return "RVW"
        if (e === "PULLREQUESTREVIEWCOMMENT")
            return "RVW-C"
        if (e === "COMMITCOMMENT")
            return "CMT"
        if (e === "FORKPULLREQUEST")
            return "FPR"
        if (e === "WATCH")
            return "WATCH"
        if (e === "FORK")
            return "FORK"
        if (e === "CREATE")
            return "NEW"
        if (e === "DELETE")
            return "DEL"
        if (e === "RELEASE")
            return "REL"
        if (e === "MEMBER")
            return "MEMB"
        if (e === "PUBLIC")
            return "PUB"
        if (e === "GOLLUM")
            return "GULM"
        if (e === "")
            return unk
        return e.substr(0, 5)
    }
    function ghevList() {
        var a = [];
        for (var i = 0; i < ghEvCount; i++)
            a.push({
                repo: has("ghev" + i + "_repo") ? String(stats["ghev" + i + "_repo"]) : unk,
                type: has("ghev" + i + "_type") ? ghTypeTag(stats["ghev" + i + "_type"]) : unk,
                age: has("ghev" + i + "_age_s") ? fmtAge(stats["ghev" + i + "_age_s"]) : unk
            });
        return a;
    }

    // ------------------------------------------------------ token ledger
    // Lane B2 rebuild — row/strip structure adapted from Haze v1.4.0's
    // usage surfaces (see LANE-B2-REPORT.md for the source cites):
    // src/team/tabs/UsageTab.tsx (summary stat strip + share-ranked
    // "who's spending" rows) and src/workspace-ui/components/settings/
    // AccountSettings.tsx (Meter: amount + thin share bar + muted subtext).
    readonly property var tokProviders: (tokData && tokData.providers && typeof tokData.providers === "object") ? tokData.providers : ({})
    // Operator blocklist — remote-CLI ledgers never render in this pane,
    // even while the ledger file still carries their keys. Matched on the
    // provider id AND the display label (prefix match), so "claude-code",
    // "Codex CLI", "openai-*" are caught the same as the bare ids.
    readonly property var tokBlocked: ["claude", "codex", "openai", "anthropic"]
    function tokBlockedId(pid, label) {
        var p = String(pid).toLowerCase();
        var l = String(label || "").toLowerCase();
        for (var i = 0; i < tokBlocked.length; i++) {
            var b = tokBlocked[i];
            if (p === b || p.indexOf(b + "-") === 0 || p.indexOf(b + "_") === 0 || l === b || l.indexOf(b) === 0)
                return true;
        }
        return false;
    }
    // One window bucket -> one line for the row's in/out column:
    // "498.1M↓ 234.9k↑ · $0.45 · 1.1k req"; a feed that reported a status
    // string instead of flow surfaces it (warn-painted downstream); a
    // snapshot rollup shows "Σ total"; an all-null bucket stays "—"
    // (BRIEF §3 honesty contract).
    function tokSplitText(d, status) {
        if (isFinite(d.tin) || isFinite(d.tout)) {
            var s = (isFinite(d.tin) ? fmtTok(d.tin) : "—") + "↓ " + (isFinite(d.tout) ? fmtTok(d.tout) : "—") + "↑";
            if (isFinite(d.cost) && d.cost > 0)
                s += " · " + fmtCost(d.cost);
            if (isFinite(d.msgs) && d.msgs > 0)
                s += " · " + fmtTok(d.msgs) + " req";
            return s;
        }
        if (status !== "")
            return status;
        if (isFinite(d.t))
            return "Σ " + fmtTok(d.t);
        return "—";
    }
    function tokRows() {
        var a = [];
        for (var pid in tokProviders) {
            var p = tokProviders[pid];
            if (p === null || p === undefined || typeof p !== "object")
                continue;
            var meta = (p.meta !== null && p.meta !== undefined && typeof p.meta === "object") ? p.meta : ({});
            var label = (meta.label !== undefined && meta.label !== null) ? String(meta.label) : ((p.label !== undefined && p.label !== null) ? String(p.label) : pid);
            if (tokBlockedId(pid, label))
                continue;
            var d = tokBucket(p.day), w = tokBucket(p.week), m = tokBucket(p.month);
            // Snapshot providers' authoritative "today" is meta.today_tokens
            // (omarchy todayTotalTokens) — the bucket only gains `total`
            // when the snapshot was nonzero, so a zero-day still reads 0,
            // not "—".
            if (!isFinite(d.t) && meta.today_tokens !== undefined && meta.today_tokens !== null) {
                var tt = Number(meta.today_tokens);
                if (isFinite(tt))
                    d.t = tt;
            }
            var kind = (meta.kind !== undefined && meta.kind !== null) ? String(meta.kind) : ((p.kind !== undefined && p.kind !== null) ? String(p.kind) : "");
            var status = (meta.status !== undefined && meta.status !== null) ? String(meta.status) : "";
            a.push({
                id: pid,
                label: label,
                kindTag: (kind !== "" && kind !== "sub") ? kind.toUpperCase() : "",
                dayT: d.t,
                dayIn: d.tin,
                dayOut: d.tout,
                dayCost: d.cost,
                split: tokSplitText(d, status),
                splitWarn: (status !== "" && !isFinite(d.tin) && !isFinite(d.tout)),
                weekT: w.t,
                monthT: m.t
            });
        }
        // "Who's spending" order (UsageTab byMember): today's spend desc,
        // unknowns sink to the bottom, label breaks the final tie.
        a.sort(function (x, y) {
            var xf = isFinite(x.dayT) ? 0 : 1, yf = isFinite(y.dayT) ? 0 : 1;
            if (xf !== yf)
                return xf - yf;
            var xd = isFinite(x.dayT) ? x.dayT : -1, yd = isFinite(y.dayT) ? y.dayT : -1;
            if (xd !== yd)
                return yd - xd;
            var xm = isFinite(x.monthT) ? x.monthT : -1, ym = isFinite(y.monthT) ? y.monthT : -1;
            if (ym !== xm)
                return ym - xm;
            return x.label < y.label ? -1 : (x.label > y.label ? 1 : 0);
        });
        return a;
    }
    // Cached so the Repeater model, the summary strip and the empty state
    // share one evaluation per tokData delta.
    readonly property var tokRowCache: tokRows()
    readonly property int tokRowCount: tokRowCache.length
    // Aggregate strip — only buckets that actually reported feed the sums;
    // a window with no data anywhere stays NaN and renders "—", never 0.
    readonly property var tokTotals: {
        var rows = tokRowCache;
        var day = NaN, tin = NaN, tout = NaN, cost = NaN, wk = NaN, mo = NaN;
        for (var i = 0; i < rows.length; i++) {
            var r = rows[i];
            if (isFinite(r.dayT))
                day = (isFinite(day) ? day : 0) + r.dayT;
            if (isFinite(r.dayIn))
                tin = (isFinite(tin) ? tin : 0) + r.dayIn;
            if (isFinite(r.dayOut))
                tout = (isFinite(tout) ? tout : 0) + r.dayOut;
            if (isFinite(r.dayCost))
                cost = (isFinite(cost) ? cost : 0) + r.dayCost;
            if (isFinite(r.weekT))
                wk = (isFinite(wk) ? wk : 0) + r.weekT;
            if (isFinite(r.monthT))
                mo = (isFinite(mo) ? mo : 0) + r.monthT;
        }
        return {
            day: day,
            dayIn: tin,
            dayOut: tout,
            cost: cost,
            week: wk,
            month: mo
        };
    }
    // Burn pace = today's total / local hours elapsed. Needs >= 15 min of
    // the day gone or the ratio is meaningless; NaN -> strip shows "—".
    readonly property double tokBurnPerHour: {
        var d = tokTotals.day;
        if (!isFinite(d) || d <= 0)
            return NaN;
        var hrs = (root.minuteNow.getHours() * 3600 + root.minuteNow.getMinutes() * 60 + root.minuteNow.getSeconds()) / 3600;
        return hrs >= 0.25 ? d / hrs : NaN;
    }
    readonly property string tokDaySplitText: {
        var t = tokTotals, p = [];
        if (isFinite(t.dayIn))
            p.push(fmtTok(t.dayIn) + "↓");
        if (isFinite(t.dayOut))
            p.push(fmtTok(t.dayOut) + "↑");
        if (isFinite(t.cost) && t.cost > 0)
            p.push(fmtCost(t.cost));
        return p.join(" · ");
    }
    readonly property string tokAgeText: {
        var u = (tokData && tokData.updated !== undefined && tokData.updated !== null) ? String(tokData.updated) : "";
        if (u === "")
            return "";
        var ms = root.minuteNow.getTime() - new Date(u).getTime();
        return (isFinite(ms) && ms >= 0) ? "ledger " + fmtAge(ms / 1000) + " ago" : "";
    }
    // Share of a window's total across the visible providers — the
    // week/month meter fill (Haze byMember: width = share, tiny sliver min).
    function tokShare(v, tot) {
        var vv = Number(v), tt = Number(tot);
        if (!isFinite(vv) || !isFinite(tt) || tt <= 0 || vv <= 0)
            return 0;
        return Math.min(1, vv / tt);
    }
    // Shared column metrics — header and delegates read the same numbers,
    // so the rules can't drift apart. tokPad is 0 because GlassPane's own
    // `padding` already supplies the pane inset: the table's PROVIDER
    // column now starts on the same x as the pane title above it instead of
    // floating 10px further right.
    readonly property int tokPad: 0
    readonly property int tokCName: 158
    readonly property int tokCDay: 74
    readonly property int tokCSplitMax: 216
    readonly property int tokCGap: 10
    // Responsive split: the IN·OUT column takes 38% of what is left after
    // the fixed columns, floored at 0 so the row can never be pushed past
    // the pane's right edge on a narrow window; the two meter columns split
    // the remainder equally.
    readonly property int tokCSplit: Math.max(0, Math.min(tokCSplitMax, Math.round((tokPanelBody.width - tokCName - tokCDay - 2 * tokCGap) * 0.38)))
    readonly property int tokCFlex: Math.max(0, Math.floor((tokPanelBody.width - tokCName - tokCDay - tokCSplit - 4 * tokCGap) / 2))
    // Fixed-height fit: rows shrink into whatever the pane's remainder
    // leaves under the strip, and the overflow note lives in the pane foot
    // (not as a fake row) so a truncated list still spends every slot on
    // real data — never painting past the face (lane-W1 contract).
    readonly property int tokHeadH: 13
    readonly property int tokRowMin: 17
    readonly property int tokRowMax: 30
    readonly property int tokRowGap: 3
    readonly property int tokRowsAvail: Math.max(0, tokListWrap.height - tokHeadH)
    readonly property int tokFitCount: Math.max(1, Math.min(tokRowCount, Math.floor((tokRowsAvail + tokRowGap) / (tokRowMin + tokRowGap))))
    readonly property int tokShown: tokRowCount > 0 ? tokFitCount : 0
    readonly property bool tokTruncated: tokRowCount > tokShown
    readonly property int tokRowH: tokShown > 0 ? Math.max(tokRowMin, Math.min(tokRowMax, Math.floor((tokRowsAvail - tokRowGap * Math.max(0, tokShown - 1)) / tokShown))) : 24
    readonly property var tokShownRows: tokRowCache.slice(0, tokShown)

    // ------------------------------------------------------------ clock
    property date now: new Date()
    // Sole wall-clock tick in this screen: 1 Hz, off while hidden. The
    // masthead clock is gone (dedupe map v2 row 14: CH owns the clock);
    // the tick survives because minuteTick below quantises it for the
    // token ledger's age/burn bindings.
    Timer {
        interval: 1000
        running: root.visible
        repeat: true
        onTriggered: root.now = new Date()
    }
    // Ledger age and burn pace read a minute-quantised stamp instead of the
    // 1 Hz clock, so those two bindings (and the token model behind them)
    // re-evaluate once a minute instead of once a second. Still no new
    // clock: it is a division of the existing tick, not a second timer.
    readonly property int minuteTick: Math.floor(root.now.getTime() / 60000)
    readonly property var minuteNow: new Date(root.minuteTick * 60000)

    // ---- pane chassis primitives ------------------------------------------
    // Header band: accent tick + Michroma title + quiet mono sub, with an
    // optional right-hand meta. This is the same three-part shape AppGrid
    // uses for its own head, so the left ledger and the right tab page read
    // as one screen instead of two dialects. One component = the five
    // hand-rolled heads can no longer drift apart in tracking or baseline.
    component PaneHead: Item {
        id: ph
        property string title: ""
        property string sub: ""
        // `meta`/`note`, not `right`/`left`: QQuickItem already finalises
        // those two names, and shadowing them makes `parent.left` resolve
        // to a string inside every child of this component.
        property string meta: ""
        property color metaTone: pal.t40
        width: parent ? parent.width : 0
        height: met.headH
        // deliberately NOT clipped: a 10px Michroma cap is ~14px tall and
        // the band is 13, so a clip would shave the odd pixel off the title.
        // Nothing can overflow horizontally — both texts elide.
        Rectangle {
            width: 14
            height: 2
            radius: 1
            color: pal.accent
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: phT
            anchors.left: parent.left
            anchors.leftMargin: 24
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, Math.max(48, ph.width * 0.46))
            font.family: pal.fDisp
            font.pixelSize: root.fs("pxLabel", 10)
            font.letterSpacing: 3
            color: pal.txt
            elide: Text.ElideRight
            text: ph.title
        }
        Text {
            anchors.left: phT.right
            anchors.leftMargin: 10
            anchors.right: phM.left
            anchors.rightMargin: ph.meta === "" ? 0 : 10
            anchors.verticalCenter: parent.verticalCenter
            visible: ph.sub !== ""
            font.family: pal.fMono
            font.pixelSize: root.fs("pxMicro", 8)
            color: pal.t40
            elide: Text.ElideRight
            text: ph.sub
        }
        Text {
            id: phM
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: ph.meta !== ""
            font.family: pal.fMono
            font.pixelSize: root.fs("pxMicro", 8)
            color: ph.metaTone
            elide: Text.ElideLeft
            text: ph.meta
        }
    }

    // Footer band: hairline + an 8px mono status line. Every ledger pane
    // gets one, so "how much did not fit / how fresh is this / what does
    // this pane hold" is always answered in the same place, and slack in a
    // pane reads as deliberate air above a status bar instead of a list
    // that was cut off.
    component PaneFoot: Item {
        id: pf
        property string note: ""
        property string meta: ""
        property color noteTone: pal.t40
        property color metaTone: pal.t40
        width: parent ? parent.width : 0
        height: met.footH
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: pal.edge
            opacity: 0.55
        }
        Text {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.topMargin: 4
            anchors.right: pfM.left
            anchors.rightMargin: pf.meta === "" ? 0 : 10
            font.family: pal.fMono
            font.pixelSize: root.fs("pxMicro", 8)
            color: pf.noteTone
            elide: Text.ElideRight
            text: pf.note
        }
        Text {
            id: pfM
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 4
            font.family: pal.fMono
            font.pixelSize: root.fs("pxMicro", 8)
            color: pf.metaTone
            elide: Text.ElideLeft
            text: pf.meta
        }
    }

    // Empty state: the unknown glyph carries the "no data" statement and the
    // words after it stay quiet, so a missing feed never reads as a zero and
    // never shouts. One component, one wording shape, five panes.
    component EmptyNote: Text {
        property string note: ""
        font.family: pal.fMono
        font.pixelSize: root.fs("pxLabel", 10)
        color: pal.unknown
        elide: Text.ElideRight
        text: root.unk + " " + note
    }

    // ---- token-ledger inline components (lane B2) -------------------------
    // Summary-strip cell — quiet label over a value (+ optional muted tail
    // on the same baseline): the Stat primitive from Haze's UsageTab
    // (`src/team/primitives.tsx`) reduced to the HUD's mono ramp. Insets are
    // symmetric (10/10) so a value never sits closer to the divider on one
    // side than to the pane edge on the other.
    component TokStatCell: Item {
        id: statCell
        property string label: ""
        property string value: "—"
        property string sub: ""
        property color tone: pal.txt
        clip: true
        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                width: parent.width
                font.family: pal.fMono
                font.pixelSize: root.fs("pxMicro", 8)
                font.letterSpacing: 2
                color: pal.t40
                elide: Text.ElideRight
                text: statCell.label
            }
            Row {
                width: parent.width
                spacing: 7
                Text {
                    id: statVal
                    font.family: pal.fMono
                    font.pixelSize: root.fs("pxLabel", 10)
                    font.weight: Font.DemiBold
                    color: statCell.tone
                    elide: Text.ElideRight
                    text: statCell.value
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: 1
                    width: Math.max(0, parent.width - statVal.implicitWidth - parent.spacing)
                    visible: statCell.sub !== ""
                    font.family: pal.fMono
                    font.pixelSize: root.fs("pxMicro", 8)
                    color: pal.t40
                    elide: Text.ElideRight
                    text: statCell.sub
                }
            }
        }
    }

    // Week/month cell — the Haze "by member" meter flipped horizontal for a
    // ledger column: thin accent share bar on a quiet track (min 3 px sliver
    // when the share is real-but-small), window total right-aligned after it.
    // The value column is a share of the cell, not a fixed 58px, so a narrow
    // pane shortens the number before it starts eating the track.
    component TokBar: Item {
        id: tokBar
        property real frac: 0
        property string value: "—"
        property color fill: pal.accent2
        clip: true
        readonly property int valW: Math.max(24, Math.min(58, Math.round(tokBar.width * 0.44)))
        Rectangle {
            id: barTrack
            anchors.left: parent.left
            anchors.right: barVal.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            height: 4
            radius: 2
            color: pal.well
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                radius: 2
                color: tokBar.fill
                width: tokBar.frac > 0 ? Math.max(3, Math.round(barTrack.width * Math.min(1, tokBar.frac))) : 0
            }
        }
        Text {
            id: barVal
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: tokBar.valW
            horizontalAlignment: Text.AlignRight
            font.family: pal.fMono
            font.pixelSize: root.fs("pxTag", 9)
            color: pal.t55
            elide: Text.ElideRight
            text: tokBar.value
        }
    }

    // ============================================================== LAYOUT

    // Flat field + knot watermark (lane W1) — the same dark cybercore field
    // CommandHub paints so the glass panes have a backdrop to frost over,
    // then the 48×49 pixel knot behind ALL panes as backdrop texture only:
    // `running: false` means the canvas draws its base frame once and never
    // schedules an effect cycle or a timer (KnotField's own contract:
    // pause() settles to the lit base frame — here we simply never run).
    // Host opacity 0.62 x idleGlow 0.56 = ~0.35 effective lit — watermark,
    // not a second reactor. `seed` is pinned: a static watermark should be
    // the same personality on every shell reload, not re-rolled at
    // construction like the animated instances on the other screens.
    Rectangle {
        anchors.fill: parent
        color: pal.bg
    }
    // Measured in the SB2 harness: the field lands 672x686 (48x49 cells at
    // px=14) and is visible — a Canvas with only `implicitWidth` set tracks
    // it for `width`, so the wrapper binding below is the whole mechanism.
    Item {
        id: knotWrap
        anchors.centerIn: parent
        width: knotMark.implicitWidth
        height: knotMark.implicitHeight
        opacity: 0.62
        KnotField {
            id: knotMark
            px: Math.max(6, Math.round(Math.min(root.width, root.height) * 0.62 / 49))
            seed: 20260101
            running: false
        }
    }

    Column {
        id: layoutRoot
        anchors.fill: parent
        anchors.margins: 14
        spacing: met.gap

        // ------------------------------------------------ masthead
        // Identity on the left, live counters and the clock on the right,
        // split by one hairline so the two groups read as two objects. The
        // resolution is measured, never asserted: the old hardcoded
        // "1920×1200" was a claim about a window that can be dragged and
        // resized anywhere.
        Rectangle {
            id: mast
            width: layoutRoot.width
            height: 52
            radius: Style.r.pane
            color: pal.ink
            border.color: pal.edge
            border.width: 1

            // holographic top rim — inset one pixel so the 1px border above
            // it still reads, and aligned to the content inset so the rim's
            // ends line up with the title and the clock
            Rectangle {
                anchors.left: mast.left
                anchors.right: mast.right
                anchors.top: mast.top
                anchors.leftMargin: met.pad + 2
                anchors.rightMargin: met.pad + 2
                anchors.topMargin: 1
                height: 2
                radius: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0.0
                        color: "transparent"
                    }
                    GradientStop {
                        position: 0.18
                        color: pal.accent2
                    }
                    GradientStop {
                        position: 0.42
                        color: "#ff7ad9"
                    }
                    GradientStop {
                        position: 0.66
                        color: pal.accent
                    }
                    GradientStop {
                        position: 0.86
                        color: "#8affd0"
                    }
                    GradientStop {
                        position: 1.0
                        color: "transparent"
                    }
                }
                opacity: 0.75
            }

            // Identity pinned left, counters + clock pinned right, the
            // elastic gap between them implicit rather than a hand-counted
            // `spacing * n` subtraction — that arithmetic was off by one
            // gap and pushed the clock 12px past the masthead's inset.
            Item {
                id: mastRow
                anchors.fill: mast
                anchors.leftMargin: met.pad + 2
                anchors.rightMargin: met.pad + 2
                anchors.topMargin: 4
                anchors.bottomMargin: 4

                Row {
                    id: mastId
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    width: Math.min(implicitWidth, Math.max(120, mastRow.width - mastStats.width - 24))

                    Text {
                        id: mastTitle
                        anchors.verticalCenter: mastId.verticalCenter
                        font.family: pal.fDisp
                        font.pixelSize: 15
                        font.letterSpacing: met.lsMast
                        color: pal.txt
                        text: "WORKBENCH<font color=\"" + pal.accent + "\">+APPS NAV</font>"
                        textFormat: Text.RichText
                    }
                    Text {
                        id: mastSub
                        anchors.verticalCenter: mastId.verticalCenter
                        // natural width with a fixed ceiling — deriving this
                        // from mastId.width instead makes a feedback loop with
                        // the Row's own implicitWidth, which settles on the
                        // 60px floor and elides the whole subtitle away
                        width: Math.min(implicitWidth, 340)
                        font.family: pal.fMono
                        font.pixelSize: root.fs("pxTag", 9)
                        font.letterSpacing: met.lsTag
                        color: pal.t55
                        elide: Text.ElideRight
                        text: root.screenName + " · " + Math.round(root.width) + "×" + Math.round(root.height) + " · OPERATIONS LEDGER"
                    }
                }

                Row {
                    id: mastStats
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Text {
                        id: mastCounts
                        anchors.verticalCenter: mastStats.verticalCenter
                        font.family: pal.fMono
                        font.pixelSize: root.fs("pxTag", 9)
                        font.letterSpacing: met.lsTag
                        color: pal.t55
                        elide: Text.ElideRight
                        // "PROC 3/6" is a slot fill count, not a process count —
                        // the collector only fills a slot above 0.5% of a core
                        text: "PROC " + root.procCount + "/" + root.procSlots
                    }
                }
            }
        }

        // ------------------------------------------------ main grid
        Row {
            id: grid
            width: layoutRoot.width
            height: layoutRoot.height - mast.height - met.gap - dockStrip.height - met.gap
            spacing: 12

            // ============================ LEFT : WORKBENCH
            Column {
                id: leftCol
                width: Math.round((grid.width - grid.spacing) * 0.55)
                height: grid.height
                spacing: met.gap
                // Second line of defence behind the height math: nothing in
                // the ledger column may paint past its bounds (the lane-W1
                // token-ledger defect was exactly that).
                clip: true

                // Distributable pane height after the four inter-pane gaps.
                // The fixed sizes below are fractions of THIS — the pre-SB2
                // code applied them to leftCol.height, so the panes summed to
                // 100% of the column PLUS 48 px of spacing and the token
                // ledger painted on behind the dock strip.
                readonly property int bodyH: Math.max(0, leftCol.height - 4 * leftCol.spacing)

                // ---- pane budget ------------------------------------------------
                // Every pane is a three-band chassis: head (PaneHead), a
                // flexible content region, foot (PaneFoot). Each pane is
                // sized from a fixed capacity — how many rows it is designed
                // to hold at its MINIMUM readable row height — so closing a
                // window never resizes a pane and nothing on screen shifts
                // under the cursor. `stretch` is the slack between the column
                // and the five natural heights; every pane takes a share of it
                // bounded by the height its own rows can actually fill, and the
                // token ledger carries the largest share because it is the one
                // pane whose content length is unknown. Below the natural total
                // the same shares squeeze proportionally, so the column
                // degrades evenly instead of clipping the ledger away.
                // GlassPane's face is inset by edgeWidth on every side BEFORE
                // `padding` applies, so a pane's content box is
                // height - 2*edge - 2*pad — not height - 2*pad. chrome is
                // that, plus the head and foot bands and the gaps between.
                readonly property int chrome: 2 * 1 + 2 * met.pad + met.headH + met.footH + 2 * met.innerGap
                readonly property int winCap: 4
                readonly property int agCap: 3
                readonly property int procCap: 4
                readonly property int repoCap: 4
                readonly property int tokCap: 4
                // a tall window may spend the slack on more table rows, up to
                // what the collector ever fills (6 slots / 6 events)
                readonly property int procRowCap: 6
                readonly property int repoRowCap: 6
                readonly property int winNat: leftCol.chrome + 18 + met.innerGap + leftCol.winCap * 40 + (leftCol.winCap - 1) * 5
                readonly property int agNat: leftCol.chrome + leftCol.agCap * 22 + (leftCol.agCap - 1) * met.innerGap
                readonly property int procNat: leftCol.chrome + leftCol.procCap * 17 + (leftCol.procCap - 1) * 4
                readonly property int repoNat: leftCol.chrome + leftCol.repoCap * 17 + (leftCol.repoCap - 1) * 4
                readonly property int tokNat: leftCol.chrome + 28 + met.innerGap + root.tokHeadH + leftCol.tokCap * 17 + (leftCol.tokCap - 1) * 3
                readonly property int winMax: leftCol.chrome + 18 + met.innerGap + leftCol.winCap * 46 + (leftCol.winCap - 1) * 5
                readonly property int agMax: leftCol.chrome + leftCol.agCap * 30 + (leftCol.agCap - 1) * met.innerGap
                readonly property int procMax: leftCol.chrome + leftCol.procRowCap * 26 + (leftCol.procRowCap - 1) * 4
                readonly property int repoMax: leftCol.chrome + leftCol.repoRowCap * 26 + (leftCol.repoRowCap - 1) * 4
                readonly property int tokMax: leftCol.chrome + 28 + met.innerGap + root.tokHeadH + leftCol.tokCap * 30 + (leftCol.tokCap - 1) * 3
                readonly property int winFloor: leftCol.chrome + 18 + met.innerGap + 40
                readonly property int agFloor: leftCol.chrome + leftCol.agCap * 20 + (leftCol.agCap - 1) * met.innerGap
                readonly property int procFloor: leftCol.chrome + 17
                readonly property int repoFloor: leftCol.chrome + 17
                readonly property int tokFloor: leftCol.chrome + 28 + met.innerGap + root.tokHeadH + 17
                readonly property int stretch: leftCol.bodyH - (leftCol.winNat + leftCol.agNat + leftCol.procNat + leftCol.repoNat + leftCol.tokNat)
                readonly property int winStretch: Math.round(leftCol.stretch * 0.22)
                readonly property int agStretch: Math.round(leftCol.stretch * 0.12)
                readonly property int procStretch: Math.round(leftCol.stretch * 0.16)
                readonly property int repoStretch: Math.round(leftCol.stretch * 0.16)
                readonly property int tokStretch: leftCol.stretch - leftCol.winStretch - leftCol.agStretch - leftCol.procStretch - leftCol.repoStretch
                // one clamp shared by all five: never under the floor, never
                // past the height the pane's own rows can fill
                function sized(nat, max, floor, share) {
                    return Math.max(floor, Math.min(max, nat + share));
                }

                // ---- WINDOWS / WORKSPACES
                GlassPane {
                    id: winPanel
                    width: leftCol.width
                    height: leftCol.sized(leftCol.winNat, leftCol.winMax, leftCol.winFloor, leftCol.winStretch)
                    padding: met.pad
                    busy: false
                    readonly property int contentH: Math.max(0, winPanel.height - 2 * winPanel.edgeWidth - 2 * winPanel.padding - met.headH - met.footH - 2 * met.innerGap)
                    readonly property int listH: Math.max(0, winPanel.contentH - 18 - met.innerGap)
                    // fit: as many rows as the content region holds at the
                    // minimum row height, then grow them into whatever is
                    // left. The overflow is declared in the foot, never
                    // clipped mid-card at the pane edge.
                    readonly property int fit: Math.max(0, Math.min(leftCol.winCap, Math.floor((winPanel.listH + 5) / (40 + 5))))
                    readonly property int rowH: winPanel.fit > 0 ? Math.max(40, Math.min(46, Math.floor((winPanel.listH - 5 * Math.max(0, winPanel.fit - 1)) / winPanel.fit))) : 0
                    readonly property var rows: root.winAll.slice(0, winPanel.fit)

                    Column {
                        id: winPanelBody
                        anchors.fill: parent
                        spacing: met.innerGap

                        PaneHead {
                            title: "WINDOWS / WORKSPACES"
                            sub: "lit = on this display · click = focus"
                            meta: root.winCount > root.winAll.length && root.winAll.length > 0 ? "top " + root.winAll.length : ""
                        }

                        Item {
                            id: winContent
                            width: parent ? parent.width : 0
                            height: winPanel.contentH
                            clip: true

                            // workspace strip — fixed-width chips so the strip
                            // reads as a scale and the fit is deterministic
                            // (the old width-by-content strip overflowed the
                            // pane whenever a workspace had a long name)
                            Row {
                                id: wsStrip
                                width: parent.width
                                height: 18
                                spacing: 5
                                readonly property int shown: Math.min(root.wsAll.length, Math.max(1, Math.floor((wsStrip.width + spacing) / (66 + spacing))))
                                readonly property bool folded: root.wsAll.length > wsStrip.shown
                                Repeater {
                                    model: root.wsAll.slice(0, wsStrip.folded ? wsStrip.shown - 1 : wsStrip.shown)
                                    delegate: Rectangle {
                                        id: wsChip
                                        required property var modelData
                                        width: Math.min(66, wsStrip.width)
                                        height: 18
                                        radius: 5
                                        clip: true
                                        color: wsChip.modelData.mon === root.screenName ? pal.ink : pal.well
                                        border.color: wsChip.modelData.mon === root.screenName ? pal.accent : (wsMa.containsMouse ? pal.accent2 : pal.edge)
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: wsChip
                                            width: wsChip.width - 12
                                            elide: Text.ElideRight
                                            horizontalAlignment: Text.AlignHCenter
                                            font.family: pal.fMono
                                            font.pixelSize: root.fs("pxTag", 9)
                                            color: wsChip.modelData.mon === root.screenName ? pal.accent : (wsMa.containsMouse ? pal.txt : pal.t55)
                                            text: wsChip.modelData.name + " ·" + root.cnt(wsChip.modelData.wins)
                                        }
                                        MouseArea {
                                            id: wsMa
                                            anchors.fill: wsChip
                                            hoverEnabled: true
                                            onClicked: root.focusWorkspace(wsChip.modelData.id)
                                        }
                                    }
                                }
                                // fold chip — the workspaces that did not fit
                                // are counted, never silently dropped
                                Rectangle {
                                    visible: wsStrip.folded
                                    width: Math.min(66, wsStrip.width)
                                    height: 18
                                    radius: 5
                                    color: "transparent"
                                    border.color: pal.edge
                                    border.width: 1
                                    Text {
                                        anchors.centerIn: parent
                                        font.family: pal.fMono
                                        font.pixelSize: root.fs("pxTag", 9)
                                        color: pal.t55
                                        text: "+" + (root.wsAll.length - wsStrip.shown + 1)
                                    }
                                }
                                EmptyNote {
                                    visible: root.wsAll.length === 0
                                    height: wsStrip.height
                                    verticalAlignment: Text.AlignVCenter
                                    note: root.wsCount < 0 ? "workspaces unknown" : "no workspaces"
                                }
                            }

                            Column {
                                id: winListCol
                                width: parent.width
                                height: winPanel.listH
                                y: wsStrip.height + met.innerGap
                                spacing: 5
                                clip: true
                                Repeater {
                                    model: winPanel.rows
                                    delegate: Rectangle {
                                        id: wcard
                                        required property var modelData
                                        width: winListCol.width
                                        height: winPanel.rowH
                                        radius: 6
                                        clip: true
                                        readonly property bool live: wcard.modelData.addr !== ""
                                        color: wma.containsMouse && wcard.live ? met.wash : pal.ink
                                        border.color: wma.containsMouse && wcard.live ? met.litLine : pal.edge
                                        border.width: 1
                                        // 2px lit rail on the leading edge — the
                                        // same affordance the tab chips use
                                        Rectangle {
                                            visible: wma.containsMouse && wcard.live
                                            anchors.left: parent.left
                                            anchors.leftMargin: 1
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 2
                                            height: parent.height - 12
                                            radius: 1
                                            color: met.litLine
                                        }
                                        Row {
                                            id: wcardRow
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 10
                                            spacing: 10
                                            // app icon well (lane W1): themed icon
                                            // resolved from win{i}_class; ▢ glyph
                                            // when the theme and the desktop
                                            // entries both miss.
                                            Rectangle {
                                                width: 24
                                                height: 24
                                                radius: 6
                                                anchors.verticalCenter: wcardRow.verticalCenter
                                                color: pal.well
                                                border.color: pal.edge
                                                border.width: 1
                                                IconImage {
                                                    anchors.centerIn: parent
                                                    implicitSize: 17
                                                    source: wcard.modelData.icon
                                                    visible: source.toString() !== ""
                                                }
                                                Text {
                                                    anchors.centerIn: parent
                                                    visible: wcard.modelData.icon === ""
                                                    text: "▢"
                                                    color: pal.t40
                                                    font.family: pal.fMono
                                                    font.pixelSize: root.fs("pxBody", 13)
                                                }
                                            }
                                            Column {
                                                anchors.verticalCenter: wcardRow.verticalCenter
                                                width: Math.max(0, wcardRow.width - 24 - 34 - 62 - 3 * wcardRow.spacing)
                                                spacing: 1
                                                Text {
                                                    width: parent.width
                                                    font.family: pal.fMono
                                                    font.pixelSize: root.fs("pxLabel", 10)
                                                    color: pal.txt
                                                    elide: Text.ElideRight
                                                    text: wcard.modelData.title !== "" ? wcard.modelData.title : root.unk
                                                }
                                                Text {
                                                    width: parent.width
                                                    font.family: pal.fMono
                                                    font.pixelSize: root.fs("pxTag", 9)
                                                    color: pal.t40
                                                    elide: Text.ElideRight
                                                    text: (wcard.modelData.cls !== "" ? wcard.modelData.cls : root.unk) + (wcard.modelData.addr !== "" ? " · " + wcard.modelData.addr.substr(0, 10) + "…" : "")
                                                }
                                            }
                                            // workspace badge
                                            Text {
                                                anchors.verticalCenter: wcardRow.verticalCenter
                                                width: 34
                                                horizontalAlignment: Text.AlignHCenter
                                                font.family: pal.fDisp
                                                font.pixelSize: root.fs("pxTile", 11)
                                                color: pal.accent
                                                elide: Text.ElideRight
                                                text: wcard.modelData.ws !== "" ? wcard.modelData.ws : root.unk
                                            }
                                            // owning display
                                            Text {
                                                anchors.verticalCenter: wcardRow.verticalCenter
                                                width: 62
                                                horizontalAlignment: Text.AlignRight
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxTag", 9)
                                                color: pal.t40
                                                elide: Text.ElideRight
                                                text: wcard.modelData.mon !== "" ? wcard.modelData.mon : root.unk
                                            }
                                        }
                                        MouseArea {
                                            id: wma
                                            anchors.fill: wcard
                                            hoverEnabled: true
                                            enabled: wcard.live
                                            onClicked: root.focusWindowAddr(wcard.modelData.addr)
                                        }
                                    }
                                }
                                EmptyNote {
                                    visible: winPanel.rows.length === 0
                                    width: winListCol.width
                                    height: visible ? implicitHeight : 0
                                    note: root.winCount < 0 ? "no window telemetry" : "no windows"
                                }
                            }
                        }

                        PaneFoot {
                            note: winPanel.fit < winPanel.rows.length || root.winCount > winPanel.rows.length ? "showing " + winPanel.rows.length + " of " + root.cnt(root.winCount) + " windows" : root.cnt(root.winCount) + " windows"
                            meta: root.wsCount < 0 ? root.unk + " ws" : root.wsAll.length + "/" + root.wsCount + " ws"
                        }
                    }
                }

                // ---- AGENT SESSIONS
                GlassPane {
                    id: agPanel
                    width: leftCol.width
                    height: leftCol.sized(leftCol.agNat, leftCol.agMax, leftCol.agFloor, leftCol.agStretch)
                    padding: met.pad
                    busy: false
                    readonly property int contentH: Math.max(0, agPanel.height - 2 * agPanel.edgeWidth - 2 * agPanel.padding - met.headH - met.footH - 2 * met.innerGap)
                    readonly property int fit: Math.max(0, Math.min(leftCol.agCap, Math.floor((agPanel.contentH + met.innerGap) / (22 + met.innerGap))))
                    readonly property int rowH: agPanel.fit > 0 ? Math.max(22, Math.min(30, Math.floor((agPanel.contentH - met.innerGap * Math.max(0, agPanel.fit - 1)) / agPanel.fit))) : 0
                    readonly property var rows: root.harnessIds.slice(0, agPanel.fit)

                    Column {
                        id: agPanelBody
                        anchors.fill: parent
                        spacing: met.innerGap

                        PaneHead {
                            title: "AGENT SESSIONS"
                            sub: "state · cpu"
                        }

                        Item {
                            id: agContent
                            width: parent ? parent.width : 0
                            height: agPanel.contentH
                            clip: true
                            Column {
                                id: agListCol
                                width: parent.width
                                height: parent.height
                                spacing: met.innerGap
                                Repeater {
                                    model: agPanel.rows
                                    delegate: Rectangle {
                                        id: agCard
                                        required property string modelData
                                        property var row: root.agRow(agCard.modelData)
                                        readonly property bool launchable: root.agLaunch[agCard.modelData] !== undefined
                                        width: agListCol.width
                                        height: agPanel.rowH
                                        radius: 6
                                        clip: true
                                        color: agMa.containsMouse ? met.wash : pal.ink
                                        border.color: agMa.containsMouse ? met.litLine : pal.edge
                                        border.width: 1
                                        Rectangle {
                                            visible: agMa.containsMouse
                                            anchors.left: parent.left
                                            anchors.leftMargin: 1
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 2
                                            height: parent.height - 10
                                            radius: 1
                                            color: met.litLine
                                        }
                                        Row {
                                            id: agCardRow
                                            anchors.fill: parent
                                            anchors.leftMargin: 10
                                            anchors.rightMargin: 10
                                            spacing: 10
                                            Text {
                                                width: 100
                                                anchors.verticalCenter: agCardRow.verticalCenter
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxLabel", 10)
                                                font.weight: Font.DemiBold
                                                color: pal.txt
                                                elide: Text.ElideRight
                                                text: agCard.modelData + (agCard.launchable ? " ↗" : "")
                                            }
                                            // state pill
                                            Rectangle {
                                                id: stPill
                                                anchors.verticalCenter: agCardRow.verticalCenter
                                                width: stTxt.implicitWidth + 14
                                                height: 15
                                                radius: 8
                                                color: pal.well
                                                border.color: pal.edge
                                                border.width: 1
                                                Text {
                                                    id: stTxt
                                                    anchors.centerIn: parent
                                                    font.family: pal.fMono
                                                    font.pixelSize: root.fs("pxMicro", 8)
                                                    font.letterSpacing: met.lsTag
                                                    color: agCard.row.procs < 0 ? pal.unknown : (agCard.row.procs > 0 ? pal.accent : pal.t55)
                                                    text: agCard.row.procs < 0 ? root.unk : (agCard.row.procs > 0 ? "LIVE ×" + agCard.row.procs : "IDLE")
                                                }
                                            }
                                            Text {
                                                width: 56
                                                anchors.verticalCenter: agCardRow.verticalCenter
                                                horizontalAlignment: Text.AlignRight
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxLabel", 10)
                                                color: pal.accent2
                                                elide: Text.ElideRight
                                                text: agCard.row.cpu < 0 ? root.unk : Math.round(agCard.row.cpu) + "%"
                                            }
                                            Text {
                                                anchors.verticalCenter: agCardRow.verticalCenter
                                                width: Math.max(0, agCardRow.width - 100 - stPill.width - 56 - 3 * agCardRow.spacing)
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxTag", 9)
                                                color: pal.t40
                                                elide: Text.ElideRight
                                                text: agCard.modelData === "devin" ? (root.devinAcp >= 0 ? root.devinAcp + " acp · " : root.unk + " acp · ") + root.cnt(root.devsessCount) + (root.devsessCount === 1 ? " lock" : " locks") : (agCard.row.procs > 0 ? agCard.row.procs + (agCard.row.procs === 1 ? " proc" : " procs") : (agCard.launchable ? "tap → launch" : "no procs"))
                                            }
                                        }
                                        MouseArea {
                                            id: agMa
                                            anchors.fill: agCard
                                            hoverEnabled: true
                                            onClicked: root.openAgent(agCard.modelData)
                                        }
                                    }
                                }
                                EmptyNote {
                                    visible: agPanel.rows.length === 0
                                    width: agListCol.width
                                    height: visible ? implicitHeight : 0
                                    note: "no harness telemetry"
                                }
                            }
                        }

                        PaneFoot {
                            note: agPanel.fit < root.harnessIds.length ? "showing " + agPanel.rows.length + " of " + root.harnessIds.length : root.harnessIds.length + " harnesses"
                            meta: root.agLiveProcs > 0 ? root.agLiveProcs + " live proc" + (root.agLiveProcs === 1 ? "" : "s") : "no live proc"
                        }
                    }
                }

                // ---- PROCESS LEDGER
                GlassPane {
                    id: procPanel
                    width: leftCol.width
                    height: leftCol.sized(leftCol.procNat, leftCol.procMax, leftCol.procFloor, leftCol.procStretch)
                    padding: met.pad
                    busy: false
                    readonly property int contentH: Math.max(0, procPanel.height - 2 * procPanel.edgeWidth - 2 * procPanel.padding - met.headH - met.footH - 2 * met.innerGap)
                    readonly property int fit: Math.max(0, Math.min(leftCol.procRowCap, Math.floor((procPanel.contentH + 4) / (17 + 4))))
                    readonly property int rowH: procPanel.fit > 0 ? Math.max(17, Math.min(26, Math.floor((procPanel.contentH - 4 * Math.max(0, procPanel.fit - 1)) / procPanel.fit))) : 0
                    readonly property var rows: root.procAll.slice(0, procPanel.fit)

                    Column {
                        id: procPanelBody
                        anchors.fill: parent
                        spacing: met.innerGap

                        PaneHead {
                            title: "PROCESS LEDGER"
                            sub: "% of one core"
                        }

                        Item {
                            id: procContent
                            width: parent ? parent.width : 0
                            height: procPanel.contentH
                            clip: true
                            Column {
                                id: procListCol
                                width: parent.width
                                height: parent.height
                                spacing: 4
                                Repeater {
                                    model: procPanel.rows
                                    delegate: Item {
                                        id: prowWrap
                                        required property var modelData
                                        required property int index
                                        width: procListCol.width
                                        height: procPanel.rowH
                                        clip: true
                                        readonly property bool sel: prowWrap.index === root.selProc
                                        // hover wash + selected edge (click =
                                        // select; no kill actions)
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 5
                                            color: pma.containsMouse ? met.wash : (prowWrap.sel ? met.selFill : "transparent")
                                        }
                                        Rectangle {
                                            visible: prowWrap.sel
                                            anchors.left: parent.left
                                            anchors.leftMargin: 1
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 2
                                            height: parent.height - 8
                                            radius: 1
                                            color: pal.accent
                                        }
                                        Row {
                                            id: prow
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 10
                                            spacing: 8
                                            Text {
                                                width: Math.max(0, prow.width - 18 - 74 - 100 - 2 * prow.spacing)
                                                anchors.verticalCenter: prow.verticalCenter
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxLabel", 10)
                                                color: pal.txt
                                                elide: Text.ElideRight
                                                text: prowWrap.modelData.name !== "" ? prowWrap.modelData.name : root.unk
                                            }
                                            Text {
                                                width: 74
                                                anchors.verticalCenter: prow.verticalCenter
                                                horizontalAlignment: Text.AlignRight
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxLabel", 10)
                                                font.weight: Font.DemiBold
                                                color: pal.accent
                                                elide: Text.ElideRight
                                                text: prowWrap.modelData.cpu < 0 ? root.unk : Math.round(prowWrap.modelData.cpu) + "%"
                                            }
                                            // 200%-of-one-core full-scale meter
                                            Rectangle {
                                                width: 100
                                                height: 4
                                                radius: 2
                                                anchors.verticalCenter: prow.verticalCenter
                                                color: pal.well
                                                Rectangle {
                                                    height: parent.height
                                                    radius: 2
                                                    width: prowWrap.modelData.cpu < 0 ? 0 : Math.min(parent.width, parent.width * Math.max(0, prowWrap.modelData.cpu) / 200)
                                                    gradient: Gradient {
                                                        orientation: Gradient.Horizontal
                                                        GradientStop {
                                                            position: 0.0
                                                            color: pal.accent2
                                                        }
                                                        GradientStop {
                                                            position: 1.0
                                                            color: pal.accent
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        MouseArea {
                                            id: pma
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: root.selProc = root.selProc === prowWrap.index ? -1 : prowWrap.index
                                        }
                                    }
                                }
                                EmptyNote {
                                    visible: root.procCount === 0
                                    width: procListCol.width
                                    height: visible ? implicitHeight : 0
                                    note: "no process over 0.5% core"
                                }
                            }
                        }

                        PaneFoot {
                            note: procPanel.fit < root.procCount ? "showing " + procPanel.rows.length + " of " + root.procSlots + " slots" : root.procCount + " of " + root.procSlots + " slots"
                            meta: root.procPeak < 0 ? "peak " + root.unk : "peak " + Math.round(root.procPeak) + "%"
                        }
                    }
                }

                // ---- GITHUB ACTIVITY
                GlassPane {
                    id: repoPanel
                    width: leftCol.width
                    height: leftCol.sized(leftCol.repoNat, leftCol.repoMax, leftCol.repoFloor, leftCol.repoStretch)
                    padding: met.pad
                    busy: false
                    readonly property int contentH: Math.max(0, repoPanel.height - 2 * repoPanel.edgeWidth - 2 * repoPanel.padding - met.headH - met.footH - 2 * met.innerGap)
                    readonly property int fit: Math.max(0, Math.min(leftCol.repoRowCap, Math.floor((repoPanel.contentH + 4) / (17 + 4))))
                    readonly property int rowH: repoPanel.fit > 0 ? Math.max(17, Math.min(26, Math.floor((repoPanel.contentH - 4 * Math.max(0, repoPanel.fit - 1)) / repoPanel.fit))) : 0
                    readonly property var rows: root.ghevAll.slice(0, repoPanel.fit)

                    Column {
                        id: repoPanelBody
                        anchors.fill: parent
                        spacing: met.innerGap

                        PaneHead {
                            title: "GITHUB ACTIVITY"
                            sub: "recent events"
                            meta: !root.ghKnown ? root.unk + " gh" : (root.ghOk ? "gh ok" : "gh unreachable")
                            metaTone: !root.ghKnown ? pal.unknown : (root.ghOk ? pal.t40 : pal.alert)
                        }

                        Item {
                            id: repoContent
                            width: parent ? parent.width : 0
                            height: repoPanel.contentH
                            clip: true
                            Column {
                                id: repoListCol
                                width: parent.width
                                height: parent.height
                                spacing: 4
                                Repeater {
                                    model: repoPanel.rows
                                    delegate: Item {
                                        id: rrowWrap
                                        required property var modelData
                                        width: repoListCol.width
                                        height: repoPanel.rowH
                                        clip: true
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 5
                                            color: rma.containsMouse ? met.wash : "transparent"
                                        }
                                        Rectangle {
                                            visible: rma.containsMouse
                                            anchors.left: parent.left
                                            anchors.leftMargin: 1
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 2
                                            height: parent.height - 8
                                            radius: 1
                                            color: met.litLine
                                        }
                                        Row {
                                            id: rrow
                                            anchors.fill: parent
                                            anchors.leftMargin: 8
                                            anchors.rightMargin: 10
                                            spacing: 8
                                            // event class, deliberately the
                                            // quietest of the three: the repo is
                                            // the subject, the age is metadata
                                            Text {
                                                width: 44
                                                anchors.verticalCenter: rrow.verticalCenter
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxMicro", 8)
                                                font.letterSpacing: met.lsTag
                                                color: pal.accent2
                                                elide: Text.ElideRight
                                                text: rrowWrap.modelData.type
                                            }
                                            Text {
                                                width: Math.max(0, rrow.width - 18 - 44 - 46 - 2 * rrow.spacing)
                                                anchors.verticalCenter: rrow.verticalCenter
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxTag", 9)
                                                color: pal.txt
                                                elide: Text.ElideRight
                                                text: rrowWrap.modelData.repo
                                            }
                                            Text {
                                                width: 46
                                                anchors.verticalCenter: rrow.verticalCenter
                                                horizontalAlignment: Text.AlignRight
                                                font.family: pal.fMono
                                                font.pixelSize: root.fs("pxMicro", 8)
                                                color: pal.t40
                                                elide: Text.ElideRight
                                                text: rrowWrap.modelData.age
                                            }
                                        }
                                        MouseArea {
                                            id: rma
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: root.openRepo(rrowWrap.modelData.repo)
                                        }
                                    }
                                }
                                EmptyNote {
                                    visible: root.ghEvCount <= 0
                                    width: repoListCol.width
                                    height: visible ? implicitHeight : 0
                                    note: root.ghEvCount < 0 ? "repo events unknown" : "no repo events"
                                }
                            }
                        }

                        PaneFoot {
                            note: repoPanel.fit < root.ghevAll.length ? "showing " + repoPanel.rows.length + " of " + root.cnt(root.ghEvCount) + " events" : root.cnt(root.ghEvCount) + " events"
                            meta: root.ghUnread < 0 ? root.unk + " unread" : (root.ghUnread > 0 ? root.ghUnread + " unread" : "0 unread")
                            // only the unread figure earns the warn tone — the
                            // row count is not a warning
                            metaTone: root.ghUnread > 0 ? pal.warn : pal.t40
                        }
                    }
                }

                // ---- TOKEN LEDGER
                // The flex pane: it takes whatever the four fixed ledgers
                // above leave behind, so the token table spends the leftover
                // room on real rows instead of a pane that runs under the dock.
                GlassPane {
                    id: tokPanel
                    width: leftCol.width
                    height: leftCol.sized(leftCol.tokNat, leftCol.tokMax, leftCol.tokFloor, leftCol.tokStretch)
                    padding: met.pad
                    busy: false
                    readonly property int contentH: Math.max(0, tokPanel.height - 2 * tokPanel.edgeWidth - 2 * tokPanel.padding - met.headH - met.footH - 2 * met.innerGap)

                    Column {
                        id: tokPanelBody
                        anchors.fill: parent
                        spacing: met.innerGap

                        // head — same chassis as the other ledger panes, plus
                        // the feed count at the right edge
                        PaneHead {
                            title: "TOKEN LEDGER"
                            sub: "local feeds · share of window"
                            meta: root.tokRowCount > 0 ? root.tokRowCount + (root.tokRowCount === 1 ? " feed" : " feeds") : root.unk + " no feed"
                        }

                        // ---- summary strip: Haze UsageTab's divided stat
                        // row, graphite-ized — today + the two window totals
                        // + burn pace, cells split by hairlines on integer
                        // boundaries so the rules stay crisp.
                        Rectangle {
                            id: tokStrip
                            width: parent ? parent.width : 0
                            height: 28
                            radius: 6
                            color: pal.well
                            border.color: pal.edge
                            border.width: 1
                            clip: true
                            readonly property int cellW: Math.floor(width / 4)

                            TokStatCell {
                                x: 0
                                width: tokStrip.cellW
                                height: tokStrip.height
                                label: "TODAY"
                                value: isFinite(root.tokTotals.day) ? root.fmtTok(root.tokTotals.day) : root.unk
                                sub: root.tokDaySplitText
                                tone: pal.accent2
                            }
                            TokStatCell {
                                x: tokStrip.cellW
                                width: tokStrip.cellW
                                height: tokStrip.height
                                label: "WEEK"
                                value: isFinite(root.tokTotals.week) ? root.fmtTok(root.tokTotals.week) : root.unk
                            }
                            TokStatCell {
                                x: tokStrip.cellW * 2
                                width: tokStrip.cellW
                                height: tokStrip.height
                                label: "MONTH"
                                value: isFinite(root.tokTotals.month) ? root.fmtTok(root.tokTotals.month) : root.unk
                            }
                            TokStatCell {
                                x: tokStrip.cellW * 3
                                width: tokStrip.width - tokStrip.cellW * 3
                                height: tokStrip.height
                                label: "BURN"
                                value: isFinite(root.tokBurnPerHour) ? "~" + root.fmtTok(root.tokBurnPerHour) + "/h" : root.unk
                            }
                            Repeater {
                                model: 3
                                delegate: Rectangle {
                                    required property int index
                                    x: tokStrip.cellW * (index + 1)
                                    y: 5
                                    width: 1
                                    height: tokStrip.height - 10
                                    color: pal.edge
                                }
                            }
                        }

                        // ---- provider rows: sized to whatever the pane's
                        // remainder leaves under the strip. Rows shrink to
                        // fit, and whatever does not fit is declared in the
                        // pane foot — never painted past the face and never
                        // spent on a fake "+N" row (wrap clip + lane-W1
                        // contract).
                        Item {
                            id: tokListWrap
                            width: parent ? parent.width : 0
                            height: Math.max(0, tokPanel.contentH - 28 - met.innerGap)
                            clip: true

                            Column {
                                id: tokListCol
                                width: parent.width
                                spacing: 0

                                // column header — same shared metrics as the
                                // row cells below so they cannot drift apart
                                Item {
                                    id: tokColHead
                                    width: parent.width
                                    height: root.tokHeadH
                                    Row {
                                        anchors.fill: parent
                                        spacing: root.tokCGap
                                        Text {
                                            width: root.tokCName
                                            height: tokColHead.height
                                            verticalAlignment: Text.AlignVCenter
                                            font.family: pal.fMono
                                            font.pixelSize: root.fs("pxMicro", 8)
                                            font.letterSpacing: met.lsTag
                                            color: pal.t40
                                            text: "PROVIDER"
                                        }
                                        Text {
                                            width: root.tokCDay
                                            height: tokColHead.height
                                            verticalAlignment: Text.AlignVCenter
                                            horizontalAlignment: Text.AlignRight
                                            font.family: pal.fMono
                                            font.pixelSize: root.fs("pxMicro", 8)
                                            font.letterSpacing: met.lsTag
                                            color: pal.t40
                                            text: "TODAY"
                                        }
                                        Text {
                                            width: root.tokCSplit
                                            height: tokColHead.height
                                            verticalAlignment: Text.AlignVCenter
                                            font.family: pal.fMono
                                            font.pixelSize: root.fs("pxMicro", 8)
                                            font.letterSpacing: met.lsTag
                                            color: pal.t40
                                            text: "IN · OUT"
                                        }
                                        Text {
                                            width: root.tokCFlex
                                            height: tokColHead.height
                                            verticalAlignment: Text.AlignVCenter
                                            font.family: pal.fMono
                                            font.pixelSize: root.fs("pxMicro", 8)
                                            font.letterSpacing: met.lsTag
                                            color: pal.t40
                                            text: "WEEK"
                                        }
                                        Text {
                                            width: root.tokCFlex
                                            height: tokColHead.height
                                            verticalAlignment: Text.AlignVCenter
                                            font.family: pal.fMono
                                            font.pixelSize: root.fs("pxMicro", 8)
                                            font.letterSpacing: met.lsTag
                                            color: pal.t40
                                            text: "MONTH"
                                        }
                                    }
                                }

                                Column {
                                    id: tokRowsCol
                                    width: parent.width
                                    spacing: root.tokRowGap
                                    Repeater {
                                        model: root.tokShownRows
                                        delegate: Item {
                                            id: trow
                                            required property var modelData
                                            width: tokRowsCol.width
                                            height: root.tokRowH
                                            clip: true

                                            // hover wash — the rows read,
                                            // they don't act; the wash is
                                            // just the ledger affordance
                                            Rectangle {
                                                anchors.fill: parent
                                                radius: 5
                                                color: trowMa.containsMouse ? met.wash : "transparent"
                                            }
                                            // Haze divide-y hairline under each row
                                            Rectangle {
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.bottom: parent.bottom
                                                height: 1
                                                color: pal.edge
                                                opacity: 0.5
                                            }

                                            Row {
                                                id: trowRow
                                                anchors.fill: parent
                                                spacing: root.tokCGap

                                                // PROVIDER — name + a small
                                                // kind tag where the feed
                                                // isn't a plain "sub"
                                                Item {
                                                    width: root.tokCName
                                                    height: trow.height
                                                    Text {
                                                        id: tname
                                                        anchors.left: parent.left
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        width: Math.min(implicitWidth, Math.max(8, parent.width - (ttag.visible ? ttag.implicitWidth + 6 : 0)))
                                                        font.family: pal.fMono
                                                        font.pixelSize: root.fs("pxLabel", 10)
                                                        font.weight: Font.DemiBold
                                                        color: pal.txt
                                                        elide: Text.ElideRight
                                                        text: trow.modelData.label
                                                    }
                                                    Text {
                                                        id: ttag
                                                        anchors.left: tname.right
                                                        anchors.leftMargin: 6
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        visible: text !== ""
                                                        font.family: pal.fMono
                                                        font.pixelSize: root.fs("pxMicro", 8)
                                                        font.letterSpacing: 1
                                                        color: pal.t40
                                                        text: trow.modelData.kindTag
                                                    }
                                                }
                                                // TODAY — the emphasized figure
                                                Text {
                                                    width: root.tokCDay
                                                    anchors.verticalCenter: trowRow.verticalCenter
                                                    horizontalAlignment: Text.AlignRight
                                                    font.family: pal.fMono
                                                    font.pixelSize: root.fs("pxLabel", 10)
                                                    font.weight: Font.DemiBold
                                                    color: isFinite(trow.modelData.dayT) ? pal.accent2 : pal.unknown
                                                    elide: Text.ElideRight
                                                    text: isFinite(trow.modelData.dayT) ? root.fmtTok(trow.modelData.dayT) : root.unk
                                                }
                                                // IN↓/OUT↑ today · cost · req —
                                                // or the feed's own status line
                                                Text {
                                                    width: root.tokCSplit
                                                    anchors.verticalCenter: trowRow.verticalCenter
                                                    font.family: pal.fMono
                                                    font.pixelSize: root.fs("pxTag", 9)
                                                    color: trow.modelData.splitWarn ? pal.warn : pal.t55
                                                    elide: Text.ElideRight
                                                    text: trow.modelData.split
                                                }
                                                TokBar {
                                                    width: root.tokCFlex
                                                    height: trow.height
                                                    frac: root.tokShare(trow.modelData.weekT, root.tokTotals.week)
                                                    value: isFinite(trow.modelData.weekT) ? root.fmtTok(trow.modelData.weekT) : root.unk
                                                    fill: pal.accent2
                                                }
                                                TokBar {
                                                    width: root.tokCFlex
                                                    height: trow.height
                                                    frac: root.tokShare(trow.modelData.monthT, root.tokTotals.month)
                                                    value: isFinite(trow.modelData.monthT) ? root.fmtTok(trow.modelData.monthT) : root.unk
                                                    fill: pal.accent
                                                }
                                            }
                                            MouseArea {
                                                id: trowMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        PaneFoot {
                            // an empty ledger file and an unreadable one look
                            // the same from here — say so rather than claim 0
                            note: root.tokRowCount === 0 ? "ledger empty or unreadable" : (root.tokTruncated ? "showing " + root.tokShown + " of " + root.tokRowCount + " feeds" : "local feeds only")
                            meta: root.tokAgeText
                        }
                    }
                }
            }

            // ======================= RIGHT : DEVICES + APPS
            // DEVICES first, always rendered: hotplug is the live signal and
            // the bay must be readable without a click (HANDOFF item 5).
            // The bay asks for the height its grid needs (DeviceBay.natHeight,
            // rows at the nominal card size); APPS takes the remainder under a
            // floor so the launcher stays usable. Both children keep the
            // self-sizing contract — GlassPane reparents them into its content
            // item, so nothing anchors to a pane id here.
            Column {
                id: rightCol
                width: grid.width - leftCol.width - grid.spacing
                height: grid.height
                spacing: met.gap

                GlassPane {
                    id: devPanel
                    width: rightCol.width
                    // when the bay asks for more than the column can give, the
                    // pane stops at the cap and the grid compresses toward
                    // DeviceBay.cardMinH before anything clips
                    height: Math.max(devPanel.floor, Math.min(devBay.natHeight, rightCol.height - devPanel.appsFloor - rightCol.spacing))
                    busy: false
                    readonly property int appsFloor: 200   // APPS pane minimum
                    readonly property int floor: 320        // DEVICES pane minimum

                    DeviceBay {
                        id: devBay
                        stats: root.stats
                    }
                }

                GlassPane {
                    id: appsPanel
                    width: rightCol.width
                    height: Math.max(0, rightCol.height - devPanel.height - rightCol.spacing)
                    busy: false

                    AppGrid {}
                }
            }
        }

        // ------------------------------------------------ utility dock
        UtilityDock {
            id: dockStrip
            width: layoutRoot.width
            stats: root.stats
            compact: true       // slim curated set + media album art (lane G2)
        }
    }
}
