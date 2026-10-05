// NEXUS HUD v4 — lane H shell (BRIEF-V4-BUILD.md, contract §HudV4.qml).
// Chrome cybercore shell: the screens are the components; this file only
// wires them.
//
//   * One PanelWindow per Hyprland monitor (Variants over Quickshell.screens):
//     WlrLayer.Background, ExclusionMode.Auto, keyboardFocus None. Role by
//     output name — DP-1 → CommandHub, DP-2 → BoardView, HDMI-A-3 → Workbench;
//     an unknown output falls back to the command surface so nothing renders
//     empty.
//   * Stats ingest is the v3 collect.sh socket pattern verbatim: a persistent
//     `collect.sh stream auto` Process emits "key<TAB>value" lines sealed by
//     "batch\t<n>" sentinels (~1 s cadence); applyFrame parses the frame into
//     the `stats` map, keeps the procCount counting fix (collector emits
//     procN_name/procN_cpu pairs, no proc_n key), diffs cpu%/net rates for
//     IPC `status`, then drives Topology.refresh(stats) once per batch —
//     FlowBus pumps off Topology.statsRev. Static probe keys (host/kernel/
//     gpu names) ride each frame so screens can read them from `stats`.
//     Unknown/absent keys simply never enter the map — screens render the
//     unknown glyph themselves.
//   * Input mask discipline (recon/v3fix-report.md §movement): `mask:` holds
//     a Region for drawn items only — here that's the screen frame (the one
//     drawn item per window). A region NEVER drops mid-gesture: `shown`
//     doesn't change while dragging, so the pressed pointer's region stays
//     in the mask until release — that was the v3 "nothing movable" bug.
//     The shell has no scrims of its own; the Navigator overlay owns its
//     scrim region and its window only maps while open, so scrim regions
//     exist only while open by construction.
//   * Drag/resize: each screen frame is press-and-draggable via the top grab
//     pill (>8 px deadband) and edge-resizable via the bottom-right grip, on
//     a 12 px snap grid. Geometry persists as field FRACTIONS
//     {fx, fy, fw, fh} — layout survives monitor resizes — into
//     ~/.config/omarchy/nexuslink/hud-state-v4.json (new file; v3 state is
//     NOT migrated). Read: Quickshell.Io FileView; write: FileView.setText
//     behind a 500 ms debounce — v3's approach. gestureStale() self-heals a
//     wedged gesture on every fresh press.
//   * IPC `nexuslink.hud`: status/panels/say/focus/move/resize/show/hide/
//     layout/version ("v4") + nav passthrough. IPC `nexuslink.nav` lives
//     INSIDE Navigator.qml (open/back/close/state) — this shell instantiates
//     Navigator once and drives it, never re-registers the target.
//   * No perpetual timers (save debounce, stream restart, say TTL and the
//     persist watchdog are all one-shot, only armed on demand) and no
//     ShaderEffect anywhere in this file.

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

Item {
    id: root

    // Injected by omarchy-shell (scoped PluginShellApi + manifest copy).
    property var shell: null
    property var manifest: null

    // Contract singletons (lanes S/T) — guarded the same way the sibling
    // files guard them, so this file still parses if a lane is missing.
    readonly property var _S: (typeof Style !== "undefined") ? Style : null
    readonly property var _T: (typeof Topology !== "undefined") ? Topology : null
    function _sc(key, fallback) {
        return (root._S && root._S.c && root._S.c[key] !== undefined) ? root._S.c[key] : fallback;
    }
    function ung() {
        return (root._S && root._S.unknownGlyph) ? root._S.unknownGlyph : "—";
    }

    // ---------------------------------------------------------------- paths
    // collect.sh + hud-collect live one level up (the plugin root).
    readonly property string collectScript: decodeURIComponent(String(Qt.resolvedUrl("../collect.sh")).replace(/^file:\/\//, ""))
    readonly property string stateDir: Quickshell.env("HOME") + "/.config/omarchy/nexuslink/"
    readonly property string statePath: stateDir + "hud-state-v4.json"
    readonly property string tokStatePath: Quickshell.env("HOME") + "/.local/state/nexuslink/tokens.json"

    // ---------------------------------------------------------------- state
    property var stats: ({})          // last parsed frame, key -> string
    property var probeData: ({})      // static keys from `collect.sh probe`
    property var tokData: ({})        // parsed tokens.json ledger
    property int procCount: 0         // counted procN_name pairs (cap 6)
    property int batchSeq: 0
    property double lastPollMs: 0

    // delta bookkeeping for IPC status (screens diff their own as well)
    property double prevIdle: -1
    property double prevTotal: -1
    property double prevRx: -1
    property double prevTx: -1
    property real cpuPct: -1
    property real rxRate: 0
    property real txRate: 0

    function num(v) {
        var n = Number(v);
        return isFinite(n) ? n : 0;
    }
    function clamp(v, lo, hi) {
        return Math.min(hi, Math.max(lo, v));
    }
    function has(k) {
        return stats[k] !== undefined && stats[k] !== "";
    }
    function fmtRate(bps) {
        var n = Math.max(0, num(bps));
        if (n >= 1073741824)
            return (n / 1073741824).toFixed(2) + " GB/s";
        if (n >= 1048576)
            return (n / 1048576).toFixed(1) + " MB/s";
        if (n >= 1024)
            return (n / 1024).toFixed(1) + " KB/s";
        return Math.round(n) + " B/s";
    }
    readonly property real memFrac: has("mem_total_kb") && num(stats.mem_total_kb) > 0 ? clamp(1 - num(stats.mem_avail_kb) / num(stats.mem_total_kb), 0, 1) : -1
    readonly property string cpuText: cpuPct >= 0 ? Math.round(cpuPct) + "%" : ung()
    readonly property string memText: memFrac >= 0 ? ((num(stats.mem_total_kb) - num(stats.mem_avail_kb)) / 1048576).toFixed(1) + " / " + (num(stats.mem_total_kb) / 1048576).toFixed(1) + " GB  (" + Math.round(memFrac * 100) + "%)" : ung()
    readonly property string uptimeText: {
        if (!has("uptime_s"))
            return ung();
        var s = Math.max(0, Math.floor(num(stats.uptime_s)));
        var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
        var hh = (h < 10 ? "0" : "") + h, mm = (m < 10 ? "0" : "") + m;
        return d > 0 ? d + "d " + hh + "h" : (h > 0 ? h + "h" + mm + "m" : m + "m");
    }
    readonly property bool alert: (has("cpu_temp") && num(stats.cpu_temp) > 85) || (memFrac >= 0 && memFrac > 0.9)

    // ------------------------------------------------- persistence (v3 way)
    // Per-screen fractional layout + hidden set -> hud-state-v4.json.
    // FileView read (async, load-once) + setText write behind a debounce.
    property var persistScreens: ({})
    property bool persistLoaded: false

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.loadState(text())
        onLoadFailed: root.loadState("")
    }

    Process {
        id: stateMkdirProc
        command: ["mkdir", "-p", root.stateDir]
        running: false
    }

    // Debounced writer — one write per gesture burst, not one per frame.
    Timer {
        id: saveTimer
        interval: 500
        repeat: false
        onTriggered: stateFile.setText(JSON.stringify(root.buildState(), null, 2) + "\n")
    }

    function loadState(raw) {
        if (persistLoaded)
            return;
        persistLoaded = true;
        var data = null;
        try {
            data = JSON.parse(String(raw || ""));
        } catch (e) {
            data = null;
        }
        if (data === null || typeof data !== "object")
            return;
        var sc = data.screens;
        if (sc && typeof sc === "object")
            persistScreens = sc;
    }

    function screenState(name) {
        var s = persistScreens[String(name)];
        return (s && typeof s === "object") ? s : null;
    }

    // A window delegate calls this when its layout/hidden set changes;
    // entry = { panels: {id: {fx,fy,fw,fh}}, hidden: [ids] }.
    function mergeScreenState(name, entry) {
        var m = {};
        for (var k in persistScreens)
            m[k] = persistScreens[k];
        m[String(name)] = entry;
        persistScreens = m;
        scheduleSave();
    }

    function buildState() {
        return {
            version: 4,
            layoutMode: "screens",
            screens: persistScreens
        };
    }

    function scheduleSave() {
        if (!persistLoaded)
            return;
        saveTimer.restart();
    }

    // One-shot fallback: if FileView never signals, screens hydrate empty.
    Timer {
        id: persistWatchdog
        interval: 1200
        repeat: false
        running: true
        onTriggered: {
            if (!root.persistLoaded)
                root.persistLoaded = true;
        }
    }

    Component.onCompleted: {
        stateMkdirProc.running = true;
        Qt.callLater(function () {
            stateFile.reload();
        });
    }

    // -------------------------------------------------------- stats ingest
    // Same wire protocol as v3 applyFrame: "key<TAB>value" lines buffered
    // until a "batch\t<n>" sentinel commits the frame.

    function applyProbe(text) {
        var lines = String(text || "").split("\n");
        var g = {};
        for (var i = 0; i < lines.length; i++) {
            var tab = lines[i].indexOf("\t");
            if (tab <= 0)
                continue;
            g[lines[i].substr(0, tab)] = lines[i].substr(tab + 1);
        }
        probeData = g;
    }

    function applyFrame(text) {
        var m = {};
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var tab = lines[i].indexOf("\t");
            if (tab <= 0)
                continue;
            m[lines[i].substr(0, tab)] = lines[i].substr(tab + 1);
        }
        // Static probe keys ride the frame (only when the frame lacks them)
        // so screens see host/kernel/gpu names through `stats` alone.
        for (var pk in probeData)
            if (m[pk] === undefined)
                m[pk] = probeData[pk];

        var t = Date.now();
        var dt = lastPollMs > 0 ? (t - lastPollMs) / 1000 : 0;

        var idle = num(m.cpu_idle), total = num(m.cpu_total);
        if (prevTotal >= 0 && total > prevTotal)
            cpuPct = clamp(100 * (1 - (idle - prevIdle) / (total - prevTotal)), 0, 100);
        prevIdle = idle;
        prevTotal = total;

        var rx = num(m.net_rx), tx = num(m.net_tx);
        if (prevRx >= 0 && dt > 0) {
            rxRate = Math.max(0, (rx - prevRx) / dt);
            txRate = Math.max(0, (tx - prevTx) / dt);
        }
        prevRx = rx;
        prevTx = tx;
        lastPollMs = t;

        // procCount counting fix: the collector emits procN_name/procN_cpu
        // pairs with no proc_n counter — count the consecutive prefix (cap 6).
        var pc = 0;
        while (pc < 6 && m["proc" + pc + "_name"] !== undefined)
            pc++;
        procCount = pc;

        stats = m;
        // Lane-H duty: push every batch into the device domain model.
        // FlowBus pumps itself off Topology.statsRev — nothing else needed.
        if (root._T !== null && root._T.refresh !== undefined) {
            try {
                root._T.refresh(m);
            } catch (e) {}
        }
    }

    Process {
        id: probeProc
        running: true
        command: ["bash", root.collectScript, "probe"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyProbe(text)
        }
    }

    Process {
        id: streamProc
        running: true
        command: ["bash", root.collectScript, "stream", "auto"]
        stdout: SplitParser {
            onRead: data => {
                var line = String(data);
                if (line.indexOf("batch\t") === 0) {
                    var n = parseInt(line.substring(6));
                    if (isFinite(n))
                        root.batchSeq = n;
                    root.applyFrame(root.pendingFrame);
                    root.pendingFrame = "";
                } else {
                    root.pendingFrame += line + "\n";
                }
            }
        }
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (String(text).trim() !== "")
                    console.warn("nexuslink.hud:", String(text).trim());
            }
        }
        // Not a watchdog: `running` drops to false when the process exits —
        // arm the one-shot restart only then.
        onRunningChanged: {
            if (!running)
                streamRestart.restart();
        }
    }
    property string pendingFrame: ""

    Timer {
        id: streamRestart
        interval: 3000
        repeat: false
        onTriggered: {
            if (!streamProc.running)
                streamProc.running = true;
        }
    }

    function refresh() {
        if (!probeProc.running)
            probeProc.running = true;
        if (!streamProc.running)
            streamProc.running = true;
    }

    // Token ledger (tokens/ledger.py writes tokens.json out of band). The
    // FileView watch is event-driven — no poll timer in this shell.
    FileView {
        id: tokFile
        path: root.tokStatePath
        watchChanges: true
        printErrors: false
        onLoaded: {
            try {
                var d = JSON.parse(String(text() || ""));
                root.tokData = (d && typeof d === "object") ? d : ({});
            } catch (e) {
                root.tokData = ({});
            }
        }
        onLoadFailed: root.tokData = ({})
    }

    // ---------------------------------------------------------------- IPC
    IpcHandler {
        target: "nexuslink.hud"

        function version(): string {
            return "v4";
        }
        function refresh(): string {
            root.refresh();
            return "ok";
        }
        function status(): string {
            return JSON.stringify({
                version: "v4",
                cpu: root.cpuText,
                mem: root.memText,
                rx: root.fmtRate(root.rxRate),
                tx: root.fmtRate(root.txRate),
                uptime: root.uptimeText,
                frame: root.batchSeq,
                procs: root.procCount,
                alert: root.alert,
                nav: navScope.navOpen
            });
        }
        function panels(): string {
            return root.ipcPanels();
        }
        function say(text: string): string {
            return root.ipcSay(text);
        }
        function focus(id: string): string {
            return root.ipcFocus(id);
        }
        function move(id: string, fx: real, fy: real): string {
            return root.ipcMove(id, Number(fx), Number(fy));
        }
        function resize(id: string, fw: real, fh: real): string {
            return root.ipcResize(id, Number(fw), Number(fh));
        }
        function show(id: string): string {
            return root.ipcShowHide(id, false);
        }
        function hide(id: string): string {
            return root.ipcShowHide(id, true);
        }
        function layout(name: string): string {
            return root.ipcLayout(name);
        }
        // Navigator passthrough — the real nexuslink.nav IpcHandler lives in
        // Navigator.qml (open/back/close/state); this is the hud-side alias.
        function nav(section: string, path: string): string {
            navScope.openSection(section, path || "");
            return "ok";
        }
    }

    // ------------------------------------------------- IPC routing helpers
    // Panel ids are the window roles (command/board/work); a screen name is
    // accepted as an alias so `move HDMI-A-3 ...` works too.
    function winForPanel(pid) {
        var ins = winVariants.instances;
        for (var i = 0; i < ins.length; i++) {
            var w = ins[i];
            if (w !== null && w.role === pid)
                return w;
        }
        for (i = 0; i < ins.length; i++) {
            var w2 = ins[i];
            if (w2 !== null && w2.screenName === pid)
                return w2;
        }
        return null;
    }
    function commandWindow() {
        var ins = winVariants.instances;
        for (var i = 0; i < ins.length; i++)
            if (ins[i].isCommand)
                return ins[i];
        return null;
    }
    function ipcFocus(pid) {
        var w = winForPanel(pid);
        if (w === null)
            return "no panel " + pid;
        return w.flashPanel(w.role) ? "ok" : "panel " + pid + " is hidden";
    }
    function ipcMove(pid, fx, fy) {
        var w = winForPanel(pid);
        if (w === null)
            return "no panel " + pid;
        return w.ipcMove(w.role, fx, fy) ? "ok" : "panel " + pid + " is hidden";
    }
    function ipcResize(pid, fw, fh) {
        var w = winForPanel(pid);
        if (w === null)
            return "no panel " + pid;
        return w.ipcResize(w.role, fw, fh) ? "ok" : "panel " + pid + " is hidden";
    }
    function ipcShowHide(pid, hidden) {
        var w = winForPanel(pid);
        if (w === null)
            return "no panel " + pid;
        return w.setHidden(w.role, hidden) ? "ok" : "no panel " + pid;
    }
    function ipcLayout(name) {
        var ins = winVariants.instances, applied = false;
        for (var i = 0; i < ins.length; i++)
            if (ins[i].applyPreset(name))
                applied = true;
        return applied ? "ok" : "unknown layout " + name;
    }
    function ipcPanels() {
        var out = [];
        var ins = winVariants.instances;
        for (var i = 0; i < ins.length; i++) {
            var w = ins[i];
            var e = w.layoutMap[w.role];
            out.push({
                screen: w.screenName,
                role: w.role,
                panels: [
                    {
                        id: w.role,
                        fx: e !== undefined ? e.fx : 0,
                        fy: e !== undefined ? e.fy : 0,
                        fw: e !== undefined ? e.fw : 0,
                        fh: (e !== undefined && e.fh !== undefined) ? e.fh : 0,
                        visible: w.scrShown,
                        hidden: w.isHidden(w.role)
                    }
                ]
            });
        }
        return JSON.stringify({
            screens: out
        });
    }
    function ipcSay(text) {
        var w = commandWindow();
        if (w === null)
            return "no command screen";
        w.sayMessage(String(text).substring(0, 120));
        return "ok";
    }

    // ------------------------------------------------------------ Navigator
    // One instance for the whole shell (lane N: never per-screen — duplicate
    // nexuslink.nav IpcHandler targets collide). Owns its Overlay window +
    // dismiss twins + scrim. navScreen is pinned by the first command-role
    // window that completes (DP-1 wins if several qualify).
    Navigator {
        id: navScope
        stats: root.stats
        navScreen: null
    }

    // ------------------------------------------------------------- windows
    Variants {
        id: winVariants
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData

            screen: modelData
            readonly property string screenName: String(modelData.name)
            // Role dispatch: unknown outputs fall back to the command surface.
            readonly property string role: screenName === "DP-2" ? "board" : screenName === "HDMI-A-3" ? "work" : "command"
            readonly property bool isCommand: role === "command"
            readonly property var roleIds: [role]
            readonly property bool scrShown: !isHidden(role)

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            visible: true
            color: "transparent"
            exclusionMode: ExclusionMode.Auto
            WlrLayershell.namespace: "nexuslink-hud"
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            // Only drawn items join the mask. `frame` is the screen surface.
            // The region NEVER drops mid-gesture: `shown` doesn't change while
            // dragging, and an IPC `hide` landing mid-gesture still can't pull
            // it — the pressed pointer's release must keep arriving or the
            // gesture bookkeeping wedges (v3fix "nothing movable"). Scrims
            // (the navigator overlay) carry their own masks, mapped only
            // while open — nothing scrim-shaped lives here.
            mask: Region {
                regions: [
                    Region {
                        item: (frame.shown || win.draggingId === win.role || win.sizingId === win.role) ? frame : null
                    }
                ]
            }

            // --------------------------------------- layout state (fractions)
            property var layoutMap: ({})
            property var hiddenMap: ({})
            property bool layoutReady: false

            // gesture bookkeeping — one active gesture per window
            property string draggingId: ""
            property string sizingId: ""
            property string dragPendingId: ""
            property var dragSrc: null
            property var dragItem: null
            property var sizeSrc: null
            property var sizeItem: null
            property real grabDX: 0
            property real grabDY: 0
            property real pressFX: 0
            property real pressFY: 0
            property real sizeStartW: 0
            property real sizeStartH: 0
            property var ghostRect: null

            readonly property real grid: 12

            // ---- map access (field fractions <-> px) ----
            function pxOf(id) {
                var r = layoutMap[id];
                return r ? r.fx * field.width : 0;
            }
            function pyOf(id) {
                var r = layoutMap[id];
                return r ? r.fy * field.height : 0;
            }
            function pwOf(id) {
                var r = layoutMap[id];
                return r ? Math.max(40, r.fw * field.width) : field.width;
            }
            function phOf(id) {
                var r = layoutMap[id];
                return (r && r.fh !== undefined && r.fh > 0) ? Math.max(24, r.fh * field.height) : field.height;
            }

            function itemFor(pid) {
                return pid === role ? frame : null;
            }
            function isHidden(pid) {
                return pid === role && hiddenMap[role] === true;
            }

            function ensureLayout() {
                if (layoutReady || !root.persistLoaded)
                    return;
                if (field.width < 50 || field.height < 50)
                    return;
                var st = root.screenState(screenName);
                var hm = {};
                if (st && st.hidden) {
                    for (var i = 0; i < st.hidden.length; i++)
                        if (String(st.hidden[i]) === role)
                            hm[role] = true;
                }
                hiddenMap = hm;
                var m = (st && st.panels) ? sanitizeMap(st.panels) : null;
                layoutMap = m !== null ? m : defaultRects();
                layoutReady = true;
            }

            function defaultRects() {
                // The screen surface defaults to the whole field.
                var m = {};
                m[role] = mkRect(0, 0, field.width, field.height);
                return m;
            }

            function mkRect(x, y, w, h) {
                var W = Math.max(1, field.width), H = Math.max(1, field.height);
                var ww = root.clamp(Math.max(40, w), 40, W);
                var hh = root.clamp(Math.max(24, h), 24, H);
                return {
                    fx: root.clamp(x, 0, Math.max(0, W - ww)) / W,
                    fy: root.clamp(y, 0, Math.max(0, H - hh)) / H,
                    fw: ww / W,
                    fh: hh / H
                };
            }

            function sanitizeMap(src) {
                var e = src ? src[role] : null;
                if (!e || typeof e !== "object")
                    return null;
                var fx = Number(e.fx), fy = Number(e.fy), fw = Number(e.fw), fh = Number(e.fh);
                if (!isFinite(fx) || !isFinite(fy) || !isFinite(fw))
                    return null;
                var r = {
                    fx: root.clamp(fx, 0, 1),
                    fy: root.clamp(fy, 0, 1),
                    fw: root.clamp(fw, 0.08, 1)
                };
                if (isFinite(fh) && fh > 0)
                    r.fh = root.clamp(fh, 0.05, 1);
                var out = {};
                out[role] = r;
                return out;
            }

            function snap(v) {
                return Math.round(v / grid) * grid;
            }
            function clampRect(r) {
                r.x = root.clamp(r.x, 0, Math.max(0, field.width - r.w));
                r.y = root.clamp(r.y, 0, Math.max(0, field.height - r.h));
                return r;
            }
            function rectOf(pid) {
                var e = layoutMap[pid];
                var w = e ? e.fw * field.width : field.width;
                var h = (e && e.fh !== undefined && e.fh > 0) ? e.fh * field.height : field.height;
                return {
                    x: e ? e.fx * field.width : 0,
                    y: e ? e.fy * field.height : 0,
                    w: w,
                    h: Math.max(10, h)
                };
            }

            // Single-item field: no sibling morph pass is needed (v3's
            // resolveLayout morph existed because many panels shared one
            // field). This just clamps the committed rect back in bounds.
            function resolveLayout(anchorId) {
                if (!layoutReady || field.width < 50 || field.height < 50)
                    return;
                var r = clampRect(rectOf(role));
                var m = {};
                for (var k in layoutMap)
                    m[k] = layoutMap[k];
                m[role] = {
                    fx: r.x / Math.max(1, field.width),
                    fy: r.y / Math.max(1, field.height),
                    fw: r.w / Math.max(1, field.width),
                    fh: r.h / Math.max(1, field.height)
                };
                layoutMap = m;
            }

            // ---- drag lifecycle (v3 mechanics, one item per field) ----
            // Self-heal: a press that outlives a lost release leaves wedged
            // bookkeeping ("nothing is movable"); one pointer can't press
            // twice, so a fresh press while a gesture is still booked means
            // the old gesture is dead — clear it and proceed.
            function gestureStale() {
                if (dragItem !== null || sizeItem !== null) {
                    draggingId = "";
                    dragPendingId = "";
                    sizingId = "";
                    dragItem = null;
                    dragSrc = null;
                    sizeItem = null;
                    sizeSrc = null;
                    ghostRect = null;
                }
            }
            function dragPress(src, item, pid, mx, my) {
                gestureStale();
                if (draggingId !== "" || sizingId !== "")
                    return;
                dragSrc = src;
                dragItem = item;
                dragPendingId = pid;
                var fp = src.mapToItem(field, mx, my);
                pressFX = fp.x;
                pressFY = fp.y;
                grabDX = fp.x - item.x;
                grabDY = fp.y - item.y;
            }
            function dragMove(src, item, mx, my) {
                if (item !== dragItem || src !== dragSrc)
                    return;
                var fp = src.mapToItem(field, mx, my);
                if (draggingId === "" && dragPendingId !== "") {
                    if (Math.abs(fp.x - pressFX) > 8 || Math.abs(fp.y - pressFY) > 8) {
                        draggingId = dragPendingId;
                        dragPendingId = "";
                    }
                }
                if (draggingId === "")
                    return;
                var nx = root.clamp(fp.x - grabDX, 0, Math.max(0, field.width - item.width));
                var ny = root.clamp(fp.y - grabDY, 0, Math.max(0, field.height - item.height));
                item.x = nx;
                item.y = ny;
                ghostRect = {
                    x: snap(nx),
                    y: snap(ny),
                    w: item.width,
                    h: item.height
                };
            }
            function dragRelease(item) {
                if (item !== dragItem)
                    return false;
                var did = draggingId;
                if (did !== "") {
                    commitRect(did, item.x, item.y);
                    draggingId = "";
                    resolveLayout(did);
                    persist();
                }
                dragPendingId = "";
                dragItem = null;
                dragSrc = null;
                ghostRect = null;
                return did !== "";
            }
            function dragAbort(item) {
                if (item !== dragItem)
                    return;
                draggingId = "";
                dragPendingId = "";
                dragItem = null;
                dragSrc = null;
                ghostRect = null;
            }
            function sizePress(src, item, pid, mx, my) {
                gestureStale();
                if (draggingId !== "" || sizingId !== "")
                    return;
                sizeSrc = src;
                sizeItem = item;
                sizingId = pid;
                var fp = src.mapToItem(field, mx, my);
                pressFX = fp.x;
                pressFY = fp.y;
                sizeStartW = item.width;
                sizeStartH = item.height;
            }
            function sizeMove(src, item, mx, my) {
                if (item !== sizeItem || src !== sizeSrc || sizingId === "")
                    return;
                var fp = src.mapToItem(field, mx, my);
                var nw = root.clamp(snap(sizeStartW + (fp.x - pressFX)), 160, Math.max(160, field.width - item.x));
                var nh = root.clamp(snap(sizeStartH + (fp.y - pressFY)), 80, Math.max(80, field.height - item.y));
                item.width = nw;
                item.height = nh;
            }
            function sizeRelease(item) {
                if (item !== sizeItem)
                    return;
                var pid = sizingId;
                sizingId = "";
                sizeSrc = null;
                sizeItem = null;
                commitRect(pid, item.x, item.y, item.width, item.height);
                resolveLayout(pid);
                persist();
            }
            function sizeAbort(item) {
                if (item !== sizeItem)
                    return;
                sizingId = "";
                sizeSrc = null;
                sizeItem = null;
            }

            function commitRect(pid, x, y, w, h) {
                if (pid !== role)
                    return;
                var W = Math.max(1, field.width), H = Math.max(1, field.height);
                var e = layoutMap[pid];
                var ww = (w !== undefined && w > 0) ? w : (e ? e.fw * W : W);
                var hh = (h !== undefined && h > 0) ? h : (e && e.fh !== undefined && e.fh > 0 ? e.fh * H : H);
                ww = root.clamp(ww, 160, W);
                hh = root.clamp(hh, 80, H);
                var ne = {
                    fx: root.clamp(snap(x), 0, Math.max(0, W - ww)) / W,
                    fy: root.clamp(snap(y), 0, Math.max(0, H - hh)) / H,
                    fw: ww / W,
                    fh: hh / H
                };
                var m = {};
                for (var k in layoutMap)
                    m[k] = layoutMap[k];
                m[pid] = ne;
                layoutMap = m;
            }

            function setHidden(pid, hid) {
                if (pid !== role)
                    return false;
                var m = {};
                for (var k in hiddenMap)
                    m[k] = hiddenMap[k];
                if (hid)
                    m[role] = true;
                else
                    delete m[role];
                hiddenMap = m;
                persist();
                return true;
            }
            function persist() {
                if (!layoutReady)
                    return;
                var hidden = [];
                for (var k in hiddenMap)
                    if (hiddenMap[k] === true)
                        hidden.push(k);
                root.mergeScreenState(screenName, {
                    panels: layoutMap,
                    hidden: hidden
                });
            }

            // ---- agent surface ------------------------------------------
            // IPC calls land on the same commitRect/resolveLayout/persist
            // path the pointer gestures use.
            function flashPanel(pid) {
                if (pid !== role || isHidden(pid))
                    return false;
                flashAnim.restart();
                return true;
            }
            function ipcMove(pid, fx, fy) {
                if (!layoutReady || itemFor(pid) === null || isHidden(pid))
                    return false;
                commitRect(pid, Number(fx) * field.width, Number(fy) * field.height);
                resolveLayout(pid);
                persist();
                return true;
            }
            function ipcResize(pid, fw, fh) {
                if (!layoutReady || itemFor(pid) === null || isHidden(pid))
                    return false;
                var r = rectOf(pid);
                var nw = root.clamp(snap(Number(fw) * field.width), 160, Math.max(160, field.width - r.x));
                var fhn = Number(fh);
                if (isFinite(fhn) && fhn > 0) {
                    var nh = root.clamp(snap(fhn * field.height), 80, Math.max(80, field.height - r.y));
                    commitRect(pid, r.x, r.y, nw, nh);
                } else {
                    commitRect(pid, r.x, r.y, nw, r.h);
                }
                resolveLayout(pid);
                persist();
                return true;
            }
            function applyPreset(name) {
                var n = String(name || "").toLowerCase();
                if (n !== "default" && n !== "reset")
                    return false;
                hiddenMap = {};
                layoutMap = defaultRects();
                persist();
                return true;
            }

            property string sayText: ""
            property bool sayFlash: false
            function sayMessage(t) {
                sayText = String(t || "");
                sayFlash = true;
                sayTimer.restart();
            }
            Timer {
                id: sayTimer
                interval: 3000
                repeat: false
                onTriggered: win.sayFlash = false
            }

            Component.onCompleted: {
                ensureLayout();
                // The navigator opens on the command surface's output.
                if (isCommand && (navScope.navScreen === null || screenName === "DP-1"))
                    navScope.navScreen = modelData;
            }
            onWidthChanged: ensureLayout()
            Connections {
                target: root
                function onPersistLoadedChanged() {
                    win.ensureLayout();
                }
            }

            // ------------------------------------------------------ field
            Item {
                id: field
                anchors.fill: parent

                // snapped drop preview — pure visual, never in the mask
                Rectangle {
                    visible: win.ghostRect !== null
                    x: win.ghostRect !== null ? win.ghostRect.x : 0
                    y: win.ghostRect !== null ? win.ghostRect.y : 0
                    width: win.ghostRect !== null ? win.ghostRect.w : 0
                    height: win.ghostRect !== null ? win.ghostRect.h : 0
                    color: "transparent"
                    radius: 8
                    border.width: 1
                    border.color: root._sc("accentDim", Qt.rgba(0.78, 0.95, 0.11, 0.55))
                }

                // The screen frame: the one drawn item this window masks.
                // Screen content fills it; grips ride its edges.
                Item {
                    id: frame
                    property bool shown: !win.isHidden(win.role)
                    property bool dragging: win.draggingId === win.role
                    property bool resizing: win.sizingId === win.role
                    visible: shown

                    Binding on x {
                        when: !frame.dragging
                        value: win.pxOf(win.role)
                    }
                    Binding on y {
                        when: !frame.dragging
                        value: win.pyOf(win.role)
                    }
                    Binding on width {
                        when: !frame.resizing
                        value: win.pwOf(win.role)
                    }
                    Binding on height {
                        when: !frame.resizing
                        value: win.phOf(win.role)
                    }

                    Loader {
                        id: scrLoader
                        anchors.fill: parent
                        sourceComponent: win.isCommand ? hubComp : (win.role === "board" ? boardComp : benchComp)
                    }

                    // ipc focus flash — a one-shot border pulse, not a timer
                    Rectangle {
                        id: flashBorder
                        anchors.fill: parent
                        color: "transparent"
                        radius: 10
                        border.width: 2
                        border.color: root._sc("accent", "#c8f31d")
                        opacity: 0
                        SequentialAnimation {
                            id: flashAnim
                            loops: 1
                            NumberAnimation {
                                target: flashBorder
                                property: "opacity"
                                to: 0.85
                                duration: 160
                            }
                            PauseAnimation {
                                duration: 700
                            }
                            NumberAnimation {
                                target: flashBorder
                                property: "opacity"
                                to: 0
                                duration: 420
                            }
                        }
                    }

                    // grab pill — top-centre drag handle (drawn, in-mask)
                    Rectangle {
                        id: grabPill
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        width: Math.min(160, Math.max(48, parent.width * 0.30))
                        height: 7
                        radius: 4
                        opacity: dragMa.containsMouse || frame.dragging ? 0.9 : 0.35
                        color: frame.dragging ? root._sc("accent", "#c8f31d") : root._sc("glassLine", Qt.rgba(0.75, 0.86, 0.96, 0.16))
                        MouseArea {
                            id: dragMa
                            anchors.fill: parent
                            anchors.margins: -5
                            hoverEnabled: true
                            onPressed: mouse => win.dragPress(dragMa, frame, win.role, mouse.x, mouse.y)
                            onPositionChanged: mouse => win.dragMove(dragMa, frame, mouse.x, mouse.y)
                            onReleased: win.dragRelease(frame)
                            onCanceled: win.dragAbort(frame)
                        }
                    }

                    // resize grip — bottom-right corner (drawn, in-mask)
                    Rectangle {
                        id: sizeGrip
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        width: 16
                        height: 16
                        radius: 4
                        opacity: sizeMa.containsMouse || frame.resizing ? 0.9 : 0.30
                        color: frame.resizing ? root._sc("accent", "#c8f31d") : root._sc("glassLine", Qt.rgba(0.75, 0.86, 0.96, 0.16))
                        MouseArea {
                            id: sizeMa
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            onPressed: mouse => win.sizePress(sizeMa, frame, win.role, mouse.x, mouse.y)
                            onPositionChanged: mouse => win.sizeMove(sizeMa, frame, mouse.x, mouse.y)
                            onReleased: win.sizeRelease(frame)
                            onCanceled: win.sizeAbort(frame)
                        }
                    }
                }
            }

            // ------------------------------------------------ screen bodies
            Component {
                id: hubComp
                CommandHub {
                    stats: root.stats
                    tokData: root.tokData
                    screenName: win.screenName
                    navigator: navScope
                    sayText: win.sayText
                    sayFlash: win.sayFlash
                    shown: frame.shown
                }
            }
            Component {
                id: boardComp
                BoardView {
                    stats: root.stats
                    screenName: win.screenName
                    running: frame.shown
                }
            }
            Component {
                id: benchComp
                Workbench {
                    stats: root.stats
                    tokData: root.tokData
                    screenName: win.screenName
                }
            }
        }
    }
}
