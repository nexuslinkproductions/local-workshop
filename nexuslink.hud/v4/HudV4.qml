pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

import "ScreenRoles.js" as ScreenRoles
import "GpuCards.js" as GpuCards

// HudV4.qml — lane H integration root for the NexusHud.V4 module.
//
// One PanelWindow per Hyprland output on the wlr BACKGROUND layer with
// ExclusionMode.Auto and no keyboard focus (the chrome-cybercore HUD is a
// read-only desktop surface; the Navigator overlay owns focus when open).
//
// Role map (M1 kit — docs/m1): roles follow display identity (EDID model /
// serial via ScreenRoles.js), never the connector name — connector names can
// renumber after GPU/topology changes and must not move a role.
//   Samsung LC27G7xT  command  -> DeckCommand (crew + launch, SwimLane hero)
//   HP E24i G4        hardware -> DeckTokens  (token flux, concentric limit rings)
//   HP Z24n G3        ops      -> DeckSystem  (device topology + system ledger)
//   Nreal/XREAL       excluded -> glasses get no HUD window (see hudScreens)
//   unknown           -> command fallback so no output ever renders empty
// (the v4 screens CommandHub/BoardView/Workbench stay in the tree and in
// qmldir for reference; they are no longer instantiated)
//
// MOVABLE DECKS: the v4 screens are monolithic surfaces, so the movable unit
// is the screen deck itself — a floating slab on a free canvas per monitor.
// Default rects are centred near-full so the reactor/knot land on the screen
// centre (P2) while still leaving real travel for drag/resize (P4).
// Invariants preserved from recon/v3fix-report.md:
//   * mask = drawn regions only; everything else passes clicks through
//   * a deck's mask region never drops while a gesture is active
//   * gestureStale() self-heals a wedged gesture on the next press
//   * no scrim lives here — Navigator.qml owns its own overlay mask
//
// TELEMETRY: one persistent `collect.sh stream auto` process feeds all
// windows — key<TAB>value lines ending in `batch\tN`. The same applyFrame
// contract as candidates/HudV3.qml: deltas for cpu%/net rates, proc rows
// counted as proc{0..5}_name (never proc_n — that key does not exist), and
// Topology.refresh(stats) once per committed frame. Missing keys stay
// absent so the screens can render Style.unknownGlyph.
//
// IPC (`omarchy-shell nexuslink.hud <m>`): status panels say focus move
// resize show hide layout version selftest roleprobe framesAlive gpus reload.
// `nexuslink.nav` belongs to Navigator.qml — do not re-declare it.

Item {
    id: hud

    // injected by omarchy-shell (PluginShellApi + manifest copy)
    property var shell: null
    property var manifest: null

    // ------------------------------------------------------------------ paths
    readonly property string collectScript:
        decodeURIComponent(String(Qt.resolvedUrl("../collect.sh")).replace(/^file:\/\//, ""))
    readonly property string tokStatePath:
        Quickshell.env("HOME") + "/.local/state/nexuslink/tokens.json"
    readonly property string crewStatePath:
        Quickshell.env("HOME") + "/.local/state/nexuslink/crew.json"
    // v4 state is deliberately a different file — no v3 layout migrates.
    readonly property string stateDir:
        Quickshell.env("HOME") + "/.config/omarchy/nexuslink/"
    readonly property string statePath: stateDir + "hud-state-v4.json"

    readonly property double startMs: Date.now()

    // ----------------------------------------------------- v5 deck flag
    // The v5 live-preview deck loads only when this file exists. The file is
    // read once at startup (blockLoading, no watch). Rollback is deleting the
    // file and restarting the shell; without the file nothing below changes.
    FileView {
        id: v5FlagFile
        path: Quickshell.env("HOME") + "/.config/nexuslink/hud-v5"
        blockLoading: true
        watchChanges: false
        printErrors: false
    }
    readonly property bool v5Enabled: v5FlagFile.loaded

    // ------------------------------------------------------------------ state
    property var stats: ({})
    property var probeMap: ({})        // static keys merged into every frame
    property int procCount: 0
    property int batchSeq: 0
    property double lastBatchMs: 0
    property string lastFrameRaw: ""
    property bool selftestArmed: false // knotProbe samples only after the first selftest call

    property real cpuPct: -1
    property real rxRate: 0
    property real txRate: 0
    property real prevIdle: -1
    property real prevTotal: -1
    property real prevRx: -1
    property real prevTx: -1
    property double lastPollMs: 0
    property double topoMs: 0
    readonly property double lastFrameMs: lastPollMs

    property string hostName: ""
    property string kernelName: ""
    property string gpuKind: "none"
    property string gpuName: ""

    property var tokData: ({})
    property bool tokLoaded: false
    property var crew: ({})

    property var persistScreens: ({})
    property bool persistLoaded: false

    property string sayText: ""
    property bool sayFlash: false

    property var navScreenObj: null

    // Outputs that get a HUD window: every connected screen minus glasses
    // (XREAL/Nreal). Re-evaluates on Quickshell.screensChanged.
    readonly property var hudScreens: {
        var all = Quickshell.screens
        var list = []
        for (var i = 0; i < all.length; i++)
            if (ScreenRoles.hasHudWindow(all[i])) list.push(all[i])
        return list
    }

    // ------------------------------------------------------------- helpers
    function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)) }
    function num(v) {
        var n = Number(v)
        return isFinite(n) ? n : 0
    }
    function has(k) { return stats[k] !== undefined && stats[k] !== "" }
    function hasPrefix(p) {
        for (var k in stats) if (k.indexOf(p) === 0) return true
        return false
    }
    function statsAgeMs() {
        return lastBatchMs > 0 ? Math.max(0, Date.now() - lastBatchMs) : -1
    }
    readonly property bool linkOk: lastBatchMs > 0 && (Date.now() - lastBatchMs) < 4000

    function fmtRate(bps) {
        var n = Math.max(0, num(bps))
        if (n >= 1073741824) return (n / 1073741824).toFixed(2) + " GB/s"
        if (n >= 1048576)    return (n / 1048576).toFixed(1) + " MB/s"
        if (n >= 1024)       return (n / 1024).toFixed(1) + " KB/s"
        return Math.round(n) + " B/s"
    }
    function fmtKiBtoGiB(kb) { return (num(kb) / 1048576).toFixed(1) }
    function fmtUptime(sec) {
        var s = Math.max(0, Math.floor(num(sec)))
        var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600)
        var m = Math.floor((s % 3600) / 60)
        function p2(x) { return (x < 10 ? "0" : "") + x }
        if (d > 0) return d + "d " + p2(h) + "h"
        if (h > 0) return h + "h" + p2(m) + "m"
        return m + "m"
    }
    readonly property string cpuText: cpuPct >= 0 ? Math.round(cpuPct) + "%" : Style.unknownGlyph
    readonly property real cpuFrac: cpuPct >= 0 ? cpuPct / 100 : -1
    readonly property real memFrac: {
        var t = num(stats.mem_total_kb)
        return t > 0 ? (t - num(stats.mem_avail_kb)) / t : -1
    }
    readonly property string memText: memFrac >= 0
        ? fmtKiBtoGiB(num(stats.mem_total_kb) - num(stats.mem_avail_kb))
          + " / " + fmtKiBtoGiB(stats.mem_total_kb) + " GB ("
          + Math.round(memFrac * 100) + "%)"
        : Style.unknownGlyph

    readonly property int tokProviderCount: {
        var p = tokData && tokData.providers
        if (!p || typeof p !== "object") return 0
        var n = 0
        for (var k in p) n++
        return n
    }

    // ------------------------------------------------- persistence (v4 file)
    FileView {
        id: stateFile
        path: hud.statePath
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: hud.loadState(text())
        onLoadFailed: hud.loadState("")
    }
    Process {
        id: stateMkdirProc
        command: ["mkdir", "-p", hud.stateDir]
        running: false
    }
    Timer {
        id: saveTimer
        interval: 500
        repeat: false
        onTriggered: stateFile.setText(JSON.stringify(hud.buildState(), null, 2) + "\n")
    }
    Timer {
        id: persistWatchdog
        interval: 1200
        repeat: false
        running: true
        onTriggered: if (!hud.persistLoaded) hud.persistLoaded = true
    }
    Component.onCompleted: {
        stateMkdirProc.running = true
        Qt.callLater(function() { stateFile.reload() })
    }

    function loadState(raw) {
        if (persistLoaded) return
        persistLoaded = true
        var data = null
        try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
        if (data === null || typeof data !== "object") return
        // only the v4 deck-map format is accepted — anything else starts clean
        if (data.version !== 4) return
        var sc = data.screens
        if (sc && typeof sc === "object") persistScreens = sc
    }
    function screenState(name) {
        var s = persistScreens[String(name)]
        return (s && typeof s === "object") ? s : null
    }
    function mergeScreenState(name, entry) {
        var m = {}
        for (var k in persistScreens) m[k] = persistScreens[k]
        m[String(name)] = entry
        persistScreens = m
        scheduleSave()
    }
    function buildState() {
        return { version: 4, layout: "deck", screens: persistScreens }
    }
    function scheduleSave() {
        if (!persistLoaded) return
        saveTimer.restart()
    }

    // ------------------------------------------------------------- telemetry
    function applyFrame(text) {
        var m = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var tab = lines[i].indexOf("\t")
            if (tab <= 0) continue
            m[lines[i].substr(0, tab)] = lines[i].substr(tab + 1)
        }
        // fold the static probe keys in so screens see stats.kernel & friends
        for (var pk in probeMap) m[pk] = probeMap[pk]

        var t = Date.now()
        var dt = lastPollMs > 0 ? (t - lastPollMs) / 1000 : 0

        var idle = num(m.cpu_idle), total = num(m.cpu_total)
        if (prevTotal >= 0 && total > prevTotal)
            cpuPct = clamp(100 * (1 - (idle - prevIdle) / (total - prevTotal)), 0, 100)
        prevIdle = idle
        prevTotal = total

        var rx = num(m.net_rx), tx = num(m.net_tx)
        if (prevRx >= 0 && dt > 0) {
            rxRate = Math.max(0, (rx - prevRx) / dt)
            txRate = Math.max(0, (tx - prevTx) / dt)
        }
        prevRx = rx
        prevTx = tx
        lastPollMs = t

        // proc_n does not exist — count the emitted proc{0..5}_name prefix
        var pc = 0
        while (pc < 6 && m["proc" + pc + "_name"] !== undefined) pc++
        procCount = pc

        stats = m
        lastFrameRaw = String(text || "")
        // The board only needs a fresh topology every ~2 s; refresh costs far
        // more than every other frame consumer together and its rates are
        // dt-based, so a skipped frame just widens dt.
        if (!Topology.ready || lastFrameMs - topoMs >= 1900) {
            topoMs = lastFrameMs
            try { Topology.refresh(stats) } catch (e) {}
        }
    }

    function applyProbe(text) {
        var lines = String(text || "").split("\n")
        var pm = {}
        for (var i = 0; i < lines.length; i++) {
            var tab = lines[i].indexOf("\t")
            if (tab <= 0) continue
            var k = lines[i].substr(0, tab)
            var v = lines[i].substr(tab + 1)
            pm[k] = v
            if (k === "host") hostName = v
            else if (k === "kernel") kernelName = v
            else if (k === "gpu_kind") gpuKind = v
            else if (k === "gpu_name") gpuName = v
        }
        probeMap = pm
        // merge into the live map immediately — no need to wait a frame
        var m2 = {}
        for (var k2 in stats) m2[k2] = stats[k2]
        for (var k3 in pm) m2[k3] = pm[k3]
        stats = m2
    }

    Process {
        id: probeProc
        running: true
        command: ["bash", hud.collectScript, "probe"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: hud.applyProbe(text)
        }
    }

    // Persistent stats stream — the Rust collector's `stream` mode when the
    // binary is installed, else collect.sh's own bash poll loop. Either way:
    // key<TAB>value batches terminated by a `batch` sentinel.
    Process {
        id: streamProc
        running: true
        command: ["bash", hud.collectScript, "stream", "auto"]
        // One read per frame instead of one per line (~440 JS callbacks/s):
        // the frame is cut on the "batch\t" sentinel, so read k carries
        // "<seq of frame k-1>\n" followed by the lines of frame k.
        stdout: SplitParser {
            splitMarker: "batch\t"
            onRead: data => {
                var body = String(data)
                var hm = /^(\d+)\n/.exec(body)
                if (hm !== null) {
                    hud.batchSeq = parseInt(hm[1]) + 1
                    body = body.substring(hm[0].length)
                }
                if (body.length === 0)
                    return
                hud.applyFrame(body)
                hud.lastBatchMs = Date.now()
            }
        }
    }

    // ------------------------------------------------------- token ledger
    // ledger.py and crew.py run from systemd user timers (tokens/systemd),
    // not from this process; both files are re-read when they change.
    FileView {
        id: tokFile
        path: hud.tokStatePath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onFileChanged: tokFile.reload()
        onLoaded: hud.loadTokens(text())
        onLoadFailed: hud.loadTokens("")
    }
    FileView {
        id: crewFile
        path: hud.crewStatePath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onFileChanged: crewFile.reload()
        onLoaded: hud.loadCrew(text())
        onLoadFailed: hud.loadCrew("")
    }
    // Self-heal: a missed inotify event must not leave the decks stale.
    // Re-reads only, no Process, so the fork saving stays.
    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: { tokFile.reload(); crewFile.reload() }
    }
    function loadTokens(raw) {
        var data = null
        try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
        if (data === null || typeof data !== "object") data = ({})
        tokData = data
        tokLoaded = true
    }
    function loadCrew(raw) {
        var data = null
        try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
        if (data === null || typeof data !== "object") data = ({})
        crew = data
    }

    // say() TTL — the reactor face draws the payload while sayFlash is hot
    Timer {
        id: sayTimer
        interval: 3000
        repeat: false
        onTriggered: hud.sayFlash = false
    }

    // ------------------------------------------------------- integrations
    // Which data sources are actually live in the current frame. ok means the
    // key family showed up in the stream or the ledger — never fabricated.
    function integrationsLive() {
        var s = stats
        var list = []
        function add(id, ok) { list.push({ id: id, ok: ok === true }) }
        add("collector",    lastBatchMs > 0 && (Date.now() - lastBatchMs) < 4000)
        add("cpu",          s.cpu_total !== undefined)
        add("memory",       s.mem_total_kb !== undefined)
        add("network",      s.net_rx !== undefined)
        add("disk",         s.disk_read_bps !== undefined || s.disk_rd_sectors !== undefined)
        add("filesystem",   s.fs_root_pct !== undefined)
        add("top-procs",    procCount > 0)
        add("load",         s.load1 !== undefined)
        add("psi",          s.psi_cpu_some !== undefined)
        add("sensors",      s.cpu_temp !== undefined || s.nvme_count !== undefined
                            || s.dimm_count !== undefined || s.cpu_tccd1 !== undefined)
        add("gpu-arc",      s.i_util !== undefined || s.dev_gpu0_pct !== undefined)
        add("gpu-apu",      s.a_util !== undefined || s.dev_gpu1_pct !== undefined)
        add("battery",      s.bat_count !== undefined && num(s.bat_count) > 0)
        add("audio",        hasPrefix("dev_audio") || hasPrefix("aud_"))
        add("bluetooth",    hasPrefix("dev_bt") || hasPrefix("bt_"))
        add("usb",          hasPrefix("dev_usb"))
        add("dock",         hasPrefix("dev_dock"))
        add("nic",          hasPrefix("dev_nic"))
        add("hyprland",     s.ws_count !== undefined || s.win_count !== undefined)
        add("tmux",         s.tmux_n !== undefined)
        add("github",       s.gh_ok === "1")
        add("weather",      s.weather !== undefined && s.weather !== "")
        add("packages",     s.pkg_updates !== undefined)
        add("theme",        s.theme_name !== undefined)
        add("agents",       s.agents_procs !== undefined || s.ag_devin_acp !== undefined)
        add("agent-usage",  s.aguse_count !== undefined)
        add("devin",        s.devsess_count !== undefined)
        add("media-mounts", s.media_count !== undefined)
        add("tokens",       tokProviderCount > 0)
        add("crew",         crew.bots !== undefined && crew.bots.length > 0)
        add("topology",     Topology.ready === true)
        return list
    }

    // --------------------------------------------------------- IPC routing
    function winForPanel(pid) {
        var ins = winVariants.instances
        var aliases = { "command": "hub", "hardware": "board", "ops": "bench" }
        var want = String(pid)
        var alias = aliases[want.toLowerCase()]
        for (var i = 0; i < ins.length; i++) {
            var w = ins[i]
            if (w !== null && w.roleIds !== undefined
                    && (w.roleIds.indexOf(want) >= 0
                        || (alias !== undefined && w.roleIds.indexOf(alias) >= 0)
                        || String(w.screenName).toLowerCase() === want.toLowerCase()))
                return w
        }
        return null
    }
    function commandWindow() {
        var ins = winVariants.instances
        for (var i = 0; i < ins.length; i++) if (ins[i].isCommand) return ins[i]
        return null
    }
    function ipcFocus(pid) {
        var w = winForPanel(pid)
        if (w === null) return "no panel " + pid
        return w.flashPanel(w.roleIds[0]) ? "ok" : "panel " + pid + " is hidden"
    }
    function ipcMove(pid, fx, fy) {
        var w = winForPanel(pid)
        if (w === null) return "no panel " + pid
        return w.ipcMove(w.roleIds[0], Number(fx), Number(fy)) ? "ok" : "panel " + pid + " is hidden"
    }
    function ipcResize(pid, fw) {
        var w = winForPanel(pid)
        if (w === null) return "no panel " + pid
        return w.ipcResize(w.roleIds[0], Number(fw)) ? "ok" : "panel " + pid + " is hidden"
    }
    function ipcShowHide(pid, hidden) {
        var w = winForPanel(pid)
        if (w === null) return "no panel " + pid
        return w.setHidden(w.roleIds[0], hidden) ? "ok" : "no panel " + pid
    }
    function ipcLayout(name) {
        var ins = winVariants.instances, applied = false
        for (var i = 0; i < ins.length; i++)
            if (ins[i].applyPreset(name)) applied = true
        return applied ? "ok" : "unknown layout " + name
    }
    function ipcPanels() {
        var out = []
        var ins = winVariants.instances
        for (var i = 0; i < ins.length; i++) {
            var w = ins[i]
            var ps = []
            for (var j = 0; j < w.roleIds.length; j++) {
                var pid = w.roleIds[j]
                var e = w.layoutMap[pid]
                var it = w.itemFor(pid)
                ps.push({
                    id: pid,
                    fx: e !== undefined ? e.fx : 0,
                    fy: e !== undefined ? e.fy : 0,
                    fw: e !== undefined ? e.fw : 0,
                    fh: (e !== undefined && e.fh !== undefined) ? e.fh : 0,
                    visible: it !== null && it !== undefined && it.visible === true,
                    hidden: w.isHidden(pid),
                    collapsed: false
                })
            }
            out.push({ screen: w.screenName, role: w.role, panels: ps })
        }
        return JSON.stringify({ screens: out })
    }
    function ipcSay(text) {
        hud.sayText = String(text === undefined || text === null ? "" : text).substring(0, 120)
        hud.sayFlash = true
        sayTimer.restart()
        return "ok"
    }

    // ---------------------------------------------------------- selftest
    // Introspection the verification harness (verify/hudcheck.py) consumes:
    // per-screen px geometry + movable flags (P2/P3/P4), procRows (P1),
    // knotLit (P5), topologyNodes (P6), integrationsLive (P7), monitorCount.
    function selftestData() {
        var ins = winVariants.instances
        var screens = []
        var live = integrationsLive()
        var age = statsAgeMs()
        var navOpen = nav.navOpen
        var navName = navScreenObj !== null ? String(navScreenObj.name) : ""
        for (var i = 0; i < ins.length; i++) {
            var w = ins[i]
            var entry = w.selftestEntry()
            entry.statsAge = age
            entry.navOpen = navOpen && navName === w.screenName
            entry.procRows = procCount
            entry.topologyNodes = Topology.nodeCount
            entry.integrationsLive = live
            screens.push(entry)
        }
        return {
            ok: linkOk,
            version: "v4",
            pid: Quickshell.processId,
            uptime_s: Math.max(0, (Date.now() - startMs) / 1000),
            statsAge_ms: age,
            batchSeq: batchSeq,
            navOpen: navOpen,
            navScreen: navName,
            monitorCount: ins.length,
            tokProviders: tokProviderCount,
            screens: screens
        }
    }

    function resolveNavScreen() {
        var ins = winVariants.instances
        for (var i = 0; i < ins.length; i++)
            if (ins[i].isCommand) { navScreenObj = ins[i].screen; return }
        if (ins.length > 0 && navScreenObj === null)
            navScreenObj = ins[0].screen
    }
    // the command window's live DeckV5, or null when v5 is off / not loaded.
    // Root level on purpose: the IPC handler below must not live in the
    // per-screen Variants delegate (duplicate IPC targets collide).
    function commandDeck() {
        var ins = winVariants.instances
        for (var i = 0; i < ins.length; i++)
            if (ins[i].isCommand)
                return ins[i].v5Deck
        return null
    }
    Connections {
        target: winVariants
        function onInstancesChanged() { hud.resolveNavScreen() }
    }
    Timer {
        // screens can enumerate a tick after the root completes — retry once
        interval: 400
        repeat: false
        running: true
        onTriggered: hud.resolveNavScreen()
    }

    // The modal Navigator overlay — exactly once at root. It owns its own
    // nexuslink.nav IPC target, its overlay window, and its open state;
    // HudV4 only feeds it stats and a deterministic default screen (the
    // command-role monitor — resolveNavScreen prefers isCommand).
    Navigator {
        id: nav
        stats: hud.stats
        navScreen: hud.navScreenObj
    }

    // ------------------------------------------------------------- windows
    Variants {
        id: winVariants
        // glasses never reach this model — no deck, no invisible polling
        // window on the wearable output
        model: hud.hudScreens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData

            readonly property string screenName: String(modelData.name)
            // role from EDID identity (ScreenRoles.js); connector names are
            // deliberately ignored and unknown identity falls back to command
            readonly property string role: ScreenRoles.roleForScreen(modelData)
            readonly property bool isCommand:  role === "command"
            readonly property bool isHardware: role === "hardware"
            readonly property string deckId: isCommand ? "hub" : isHardware ? "board" : "bench"
            readonly property var roleIds: [deckId]
            // the command window's DeckV5 instance, or null (root IPC entry)
            readonly property var v5Deck: (isCommand && hud.v5Enabled && deckLoader.item)
                                           ? deckLoader.item.deckItem : null

            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Auto
            WlrLayershell.namespace: "nexuslink-hud"
            WlrLayershell.layer: WlrLayer.Background
            // Keyboard: None by default. The v5 Find pill needs the keyboard
            // while it is open, and a layer surface can only ask for that
            // through its own keyboard mode, so DeckV5 mirrors its open state
            // onto findKeysWanted (the property below) and this binding is the
            // single place the surface asks for keys.
            property bool findKeysWanted: false
            WlrLayershell.keyboardFocus: win.findKeysWanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            // Only the drawn deck (and the drop ghost while a drag is live)
            // accepts pointer input — every other pixel of this screen-sized
            // surface passes through to the desktop. The deck's region must
            // not drop mid-gesture: `masked` includes the gesture flags, so
            // a hide arriving mid-drag cannot strand the compositor grab
            // (the v3 "nothing is movable" failure).
            mask: Region {
                regions: [
                    Region { item: deck.masked ? deck : null },
                    Region { item: win.draggingId !== "" ? dropGhost : null }
                ]
            }

            // ------------------------------ layout state (fractions of field)
            property var layoutMap: ({})
            property var hiddenMap: ({})
            property bool layoutReady: false
            property bool delegatesReady: false
            property bool animateLayout: false

            property string draggingId: ""
            property string dragPendingId: ""
            property string sizingId: ""
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
            property string flashId: ""

            // knot-lit probe state — populated on the command window only
            property var knotNode: null
            property int knotPrevEffect: -2
            property real knotCur: -1
            property real knotMin: -1       // lowest SETTLED brightness seen
            property real knotMinAll: -1    // absolute floor incl. mid-flight
            property int knotCycles: 0

            readonly property real grid: 12   // px snap pitch

            function snap(v) { return Math.round(v / grid) * grid }
            function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)) }
            function defaultRects() {
                // centred near-full slab: reactor/knot sit on the screen
                // centre by construction while the margin ring stays
                // click-through and leaves honest travel for move
                var m = {}
                m[deckId] = { fx: 0.025, fy: 0.03, fw: 0.95, fh: 0.94 }
                return m
            }
            function isHidden(pid) { return hiddenMap[pid] === true }
            function itemFor(pid) { return pid === deckId ? deck : null }
            function rectOf(pid) {
                var e = layoutMap[pid]
                var w = e ? e.fw * field.width : deck.width
                var h = (e && e.fh !== undefined && e.fh > 0) ? e.fh * field.height
                                                            : deck.height
                return { x: e ? e.fx * field.width : 0,
                         y: e ? e.fy * field.height : 0,
                         w: w, h: h }
            }
            function pxOfX(pid) { var e = layoutMap[pid]; return e ? e.fx * field.width : 0 }
            function pxOfY(pid) { var e = layoutMap[pid]; return e ? e.fy * field.height : 0 }
            function pwOf(pid)  { var e = layoutMap[pid]; return e ? e.fw * field.width : field.width }
            function phOf(pid)  { var e = layoutMap[pid]; return (e && e.fh !== undefined && e.fh > 0) ? e.fh * field.height : field.height }

            function ensureLayout() {
                if (layoutReady || !delegatesReady || !hud.persistLoaded) return
                if (field.width < 50 || field.height < 50) return
                var m = defaultRects()
                var st = hud.screenState(screenName)
                if (st && st.panels && typeof st.panels === "object") {
                    var pe = st.panels[deckId]
                    if (pe && isFinite(pe.fx) && isFinite(pe.fy) && isFinite(pe.fw)) {
                        var fw = clamp(Number(pe.fw), 0.05, 1)
                        var fh = (pe.fh !== undefined && isFinite(pe.fh) && pe.fh > 0)
                               ? clamp(Number(pe.fh), 0.05, 1) : 0.94
                        var e = { fw: fw, fh: fh,
                                  fx: clamp(Number(pe.fx), 0, Math.max(0, 1 - fw)),
                                  fy: clamp(Number(pe.fy), 0, Math.max(0, 1 - fh)) }
                        m[deckId] = e
                    }
                }
                var hid = {}
                if (st && st.hidden !== undefined && st.hidden.length !== undefined) {
                    for (var i = 0; i < st.hidden.length; i++)
                        hid[String(st.hidden[i])] = true
                }
                layoutMap = m
                hiddenMap = hid
                layoutReady = true
                animGate.restart()
            }

            function commitRect(pid, x, y, w, h) {
                var W = Math.max(1, field.width), H = Math.max(1, field.height)
                var e = layoutMap[pid]
                var ww = (w !== undefined && w > 0) ? w : (e ? e.fw * W : deck.width)
                var hh = (h !== undefined && h > 0) ? h
                       : (e && e.fh !== undefined && e.fh > 0 ? e.fh * H : deck.height)
                ww = clamp(ww, Math.min(deck.minW, W), W)
                hh = clamp(hh, Math.min(deck.minH, H), H)
                var ne = {
                    fx: clamp(snap(x), 0, Math.max(0, W - ww)) / W,
                    fy: clamp(snap(y), 0, Math.max(0, H - hh)) / H,
                    fw: ww / W,
                    fh: hh / H
                }
                var m = {}
                for (var k in layoutMap) m[k] = layoutMap[k]
                m[pid] = ne
                layoutMap = m
            }
            function persist() {
                if (!layoutReady) return
                var hidden = []
                for (var k in hiddenMap) if (hiddenMap[k] === true) hidden.push(k)
                hud.mergeScreenState(screenName, { panels: layoutMap, hidden: hidden })
            }

            // ---- drag lifecycle (v3 invariants) ----
            function gestureStale() {
                // a live press while a gesture is still booked means the old
                // release never arrived — one pointer can't press twice, so
                // the wedged state is dead weight; drop it and proceed
                if (dragItem !== null || sizeItem !== null) {
                    draggingId = ""; dragPendingId = ""; sizingId = ""
                    dragItem = null; dragSrc = null
                    sizeItem = null; sizeSrc = null
                }
            }
            function dragPress(src, item, pid, mx, my) {
                gestureStale()
                if (draggingId !== "" || sizingId !== "") return
                dragSrc = src; dragItem = item; dragPendingId = pid
                var fp = src.mapToItem(field, mx, my)
                pressFX = fp.x; pressFY = fp.y
                grabDX = fp.x - item.x; grabDY = fp.y - item.y
            }
            function dragMove(src, item, mx, my) {
                if (item !== dragItem || src !== dragSrc) return
                var fp = src.mapToItem(field, mx, my)
                if (draggingId === "" && dragPendingId !== "") {
                    if (Math.abs(fp.x - pressFX) > 8 || Math.abs(fp.y - pressFY) > 8) {
                        draggingId = dragPendingId   // >8 px press-and-drag = move
                        dragPendingId = ""
                    }
                }
                if (draggingId === "") return
                item.x = clamp(fp.x - grabDX, 0, Math.max(0, field.width - item.width))
                item.y = clamp(fp.y - grabDY, 0, Math.max(0, field.height - item.height))
            }
            function dragRelease(item) {
                if (item !== dragItem) return false
                var did = draggingId
                if (did !== "") {
                    commitRect(did, item.x, item.y)
                    draggingId = ""
                    persist()
                }
                dragPendingId = ""; dragItem = null; dragSrc = null
                return did !== ""
            }
            function dragAbort(item) {
                if (item !== dragItem) return
                draggingId = ""; dragPendingId = ""
                dragItem = null; dragSrc = null
                // bindings re-engage -> the deck eases back to its committed rect
            }

            // ---- bottom-right edge-resize lifecycle ----
            function sizePress(src, item, pid, mx, my) {
                gestureStale()
                if (draggingId !== "" || sizingId !== "") return
                sizeSrc = src; sizeItem = item; sizingId = pid
                var fp = src.mapToItem(field, mx, my)
                pressFX = fp.x; pressFY = fp.y
                sizeStartW = item.width; sizeStartH = item.height
            }
            function sizeMove(src, item, mx, my) {
                if (item !== sizeItem || src !== sizeSrc || sizingId === "") return
                var fp = src.mapToItem(field, mx, my)
                item.width = clamp(snap(sizeStartW + (fp.x - pressFX)),
                                   item.minW, Math.max(item.minW, field.width - item.x))
                item.height = clamp(snap(sizeStartH + (fp.y - pressFY)),
                                    item.minH, Math.max(item.minH, field.height - item.y))
            }
            function sizeRelease(item) {
                if (item !== sizeItem) return
                var pid = sizingId
                sizingId = ""; sizeSrc = null; sizeItem = null
                commitRect(pid, item.x, item.y, item.width, item.height)
                persist()
            }
            function sizeAbort(item) {
                if (item !== sizeItem) return
                sizingId = ""; sizeSrc = null; sizeItem = null
            }

            // ---- agent surface (same plumbing as pointer gestures) ----
            function flashPanel(pid) {
                if (itemFor(pid) === null || isHidden(pid)) return false
                flashId = pid
                flashTimer.restart()
                return true
            }
            function setHidden(pid, hid) {
                if (itemFor(pid) === null) return false
                var m = {}
                for (var k in hiddenMap) m[k] = hiddenMap[k]
                if (hid) m[pid] = true; else delete m[pid]
                hiddenMap = m
                persist()
                return true
            }
            function applyPreset(name) {
                var n = String(name || "").toLowerCase()
                if (n === "reset") n = "default"
                var e = null
                if (n === "default")     e = { fx: 0.025, fy: 0.03,  fw: 0.95, fh: 0.94 }
                else if (n === "focus")  e = { fx: 0.01,  fy: 0.015, fw: 0.98, fh: 0.97 }
                else if (n === "sparse") e = { fx: 0.07,  fy: 0.08,  fw: 0.86, fh: 0.84 }
                else return false
                var hm = {}
                for (var k in hiddenMap) hm[k] = hiddenMap[k]
                delete hm[deckId]
                hiddenMap = hm
                var m = {}
                for (var k2 in layoutMap) m[k2] = layoutMap[k2]
                m[deckId] = e
                layoutMap = m
                persist()
                return true
            }
            function ipcMove(pid, fx, fy) {
                if (itemFor(pid) === null || isHidden(pid)) return false
                commitRect(pid, Number(fx) * field.width, Number(fy) * field.height)
                persist()
                return true
            }
            function ipcResize(pid, fw) {
                var it = itemFor(pid)
                if (it === null || isHidden(pid)) return false
                var r = rectOf(pid)
                var nw = clamp(snap(Number(fw) * field.width),
                               it.minW, Math.max(it.minW, field.width - r.x))
                commitRect(pid, r.x, r.y, nw, r.h)
                persist()
                return true
            }

            // ---- knot-lit probe (command window only) ----
            // Verification probe over KnotField's PUBLIC state (cells/effect/
            // elapsed/effectDur/idleGlow/kcx/kcy/maxR). It re-evaluates the
            // published per-cell alpha envelopes so knotLit is a measured
            // brightness, not a guess. Runs only while an effect is in flight
            // plus a slow resting tick — a few hundred scalars, no repaints.
            function findKnot(it) {
                if (it === null || it === undefined) return null
                var ch = it.children
                if (ch === undefined) return null
                for (var i = 0; i < ch.length; i++) {
                    var c = ch[i]
                    if (c !== null && c !== undefined
                            && c.cells !== undefined && c.effect !== undefined
                            && c.effectDur !== undefined && c.idleGlow !== undefined)
                        return c
                    var hit = findKnot(c)
                    if (hit !== null) return hit
                }
                return null
            }
            function knotMeanAlpha(k) {
                var cells = k.cells
                var n = cells !== undefined ? cells.length : 0
                if (n === 0) return -1
                var base = k.idleGlow
                var eff = k.effect
                var ms = k.elapsed
                var dur = k.effectDur
                var pr = dur > 0 ? Math.min(1, ms / dur) : 0
                if (eff < 0) return base
                var sum = 0
                for (var i = 0; i < n; i++) {
                    var c = cells[i]
                    var a = base
                    if (eff === 0) {
                        var po = (ms - c.d1 * 1300) / 1100
                        po = po < 0 ? 0 : (po > 1 ? 1 : po)
                        po = 1 - (1 - po) * (1 - po)
                        var pi = (ms - 2300 - c.d2 * 1300) / 1200
                        pi = pi < 0 ? 0 : (pi > 1 ? 1 : pi)
                        pi = pi * pi * (3 - 2 * pi)
                        var f = po * (1 - pi)
                        var tail0 = Math.min(1, Math.max(0, (dur - ms) / 500))
                        a = base * (1 - 0.82 * f) + pi * (1 - f) * 0.72 * tail0
                    } else if (eff === 1) {
                        var front = -4 + pr * (k.cols + 10)
                        var born = (front - c.x + c.s * 2.5) / 3
                        born = born < 0 ? 0 : (born > 1 ? 1 : born)
                        born = born * born * (3 - 2 * born)
                        var held = pr < 0.80 ? 1 : Math.max(0, 1 - (pr - 0.80) / 0.20)
                        a = (base + born * 0.72) * held + base * (1 - held)
                    } else if (eff === 2) {
                        var rr = Math.sqrt((c.x - k.kcx) * (c.x - k.kcx)
                                         + (c.y - k.kcy) * (c.y - k.kcy))
                        var R = pr * (k.maxR + 3)
                        var b = Math.max(0, 1 - Math.abs(rr - R) / 3.0)
                        a = base + b * 0.86
                    } else if (eff === 3) {
                        var v = Math.sin(ms * 0.004 * (2 + c.s * 6) + c.s * 40)
                        var env = Math.min(1, Math.min(ms, dur - ms) / 400)
                        var b2 = Math.max(0, (v - 0.45) / 0.55) * env
                        a = base + b2 * 0.86
                    } else if (eff === 4) {
                        var tail4 = Math.min(1, Math.min(ms, dur - ms) / 500)
                        a = base + 0.80 * Math.max(0, tail4)
                    }
                    sum += a > 1 ? 1 : a
                }
                return sum / n
            }
            function knotSample() {
                if (!isCommand) return
                if (knotNode === null) {
                    knotNode = findKnot(deck)
                    if (knotNode !== null)
                        knotPrevEffect = knotNode.effect
                    else
                        return
                }
                var k = knotNode
                var eff = k.effect
                if (knotPrevEffect >= 0 && eff < 0)
                    knotCycles++            // a transition cycle settled to base
                knotPrevEffect = eff
                var mean = knotMeanAlpha(k)
                if (mean < 0) return
                var host = (k.parent !== null && k.parent !== undefined
                            && k.parent.opacity !== undefined) ? k.parent.opacity : 1
                knotCur = mean * host       // rendered fraction of accent
                if (knotMinAll < 0 || knotCur < knotMinAll) knotMinAll = knotCur
                if (eff < 0 && (knotMin < 0 || knotCur < knotMin))
                    knotMin = knotCur       // the settled floor — v3fix metric
            }

            Timer {
                id: knotProbe
                running: hud.selftestArmed && win.isCommand && !win.isHidden(win.deckId)
                // dense only while a transition cycle is actually in flight
                interval: (win.knotNode !== null && win.knotNode !== undefined
                           && win.knotNode.effect >= 0) ? 250 : 1500
                repeat: true
                onTriggered: win.knotSample()
            }

            // selftest entry for this screen — pixel geometry, not fractions
            function selftestEntry() {
                var r = rectOf(deckId)
                var ps = [{
                    id: deckId,
                    x: deck.x, y: deck.y, w: deck.width, h: deck.height,
                    movable: deck.shown === true,
                    hidden: isHidden(deckId)
                }]
                var entry = {
                    screen: screenName,
                    role: role,
                    w: field.width,
                    h: field.height,
                    panels: ps
                }
                if (isCommand) {
                    var cx = deck.x + deck.width / 2
                    var cy = deck.y + deck.height / 2
                    var kc = [cx, cy]
                    if (knotNode !== null && knotNode !== undefined) {
                        var p = knotNode.mapToItem(field, knotNode.width / 2,
                                                   knotNode.height / 2)
                        kc = [p.x, p.y]     // measured canvas centre
                    }
                    entry.reactorCenter = [cx, cy]  // reactor is centreIn deck
                    entry.knotCenter = kc
                    if (hud.selftestArmed && knotCur < 0) knotSample()  // first call measures, not seeds
                    entry.knotLit = {
                        // seeded at the contracted resting level (0.56 x 0.9
                        // host = 0.504 of accent) until the first real sample
                        min: knotMin >= 0 ? knotMin : 0.504,
                        cur: knotCur >= 0 ? knotCur : 0.504,
                        minAll: knotMinAll >= 0 ? knotMinAll : -1,
                        cycles: knotCycles
                    }
                }
                return entry
            }

            Timer {
                id: flashTimer
                interval: 1400
                repeat: false
                onTriggered: win.flashId = ""
            }
            Timer {
                id: animGate
                interval: 450
                repeat: false
                onTriggered: win.animateLayout = true
            }
            Timer {
                // hydrate once the persisted blob has landed (or the root
                // watchdog has declared the state file absent/corrupt)
                id: initRetry
                interval: 140
                repeat: true
                running: !win.layoutReady   // ensureLayout() is a no-op once ready
                onTriggered: win.ensureLayout()
            }
            Connections {
                target: hud
                function onPersistLoadedChanged() { win.ensureLayout() }
            }
            Component.onCompleted: {
                win.delegatesReady = true
                win.ensureLayout()
            }

            // ------------------------------------------------------------ field
            Item {
                id: field
                anchors.fill: parent

                // snapped drop preview while a move gesture is live
                Rectangle {
                    id: dropGhost
                    visible: win.draggingId !== ""
                    x: win.snap(deck.x)
                    y: win.snap(deck.y)
                    width: deck.width
                    height: deck.height
                    color: "transparent"
                    border.width: 1
                    border.color: Style.c.accent
                    radius: Style.r.pane
                    opacity: 0.55
                }

                // ------------------------------------------------------- deck
                Item {
                    id: deck
                    readonly property bool dragging: win.draggingId === win.deckId
                    readonly property bool resizing: win.sizingId === win.deckId
                    readonly property bool shown: !win.isHidden(win.deckId)
                    // mask membership for the WHOLE gesture, hide mid-drag included
                    readonly property bool masked: shown || dragging || resizing
                    readonly property real minW: Math.min(420, field.width * 0.3)
                    readonly property real minH: Math.min(280, field.height * 0.3)

                    visible: shown
                    clip: true
                    opacity: dragging ? 0.94 : 1.0
                    z: (dragging || resizing) ? 60 : 0

                    Binding on x { when: win.layoutReady && !deck.dragging
                                   value: win.pxOfX(win.deckId) }
                    Binding on y { when: win.layoutReady && !deck.dragging
                                   value: win.pxOfY(win.deckId) }
                    Binding on width { when: win.layoutReady && !deck.resizing
                                       value: win.pwOf(win.deckId) }
                    Binding on height { when: win.layoutReady && !deck.resizing
                                        value: win.phOf(win.deckId) }
                    Behavior on x { enabled: win.animateLayout && !deck.dragging
                                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    Behavior on y { enabled: win.animateLayout && !deck.dragging
                                    NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    Behavior on width { enabled: win.animateLayout && !deck.resizing
                                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    Behavior on height { enabled: win.animateLayout && !deck.resizing
                                         NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                    // drag pad — lowest child, so a press anywhere the screen
                    // content does not claim starts a move gesture (>8 px)
                    MouseArea {
                        id: dragPad
                        anchors.fill: parent
                        onPressed: m => win.dragPress(dragPad, deck, win.deckId, m.x, m.y)
                        onPositionChanged: m => win.dragMove(dragPad, deck, m.x, m.y)
                        onReleased: () => win.dragRelease(deck)
                        onCanceled: () => win.dragAbort(deck)
                    }

                    // ------- role screen (exactly one is instantiated per window)
                    // M1 kit: the three decks share one input contract —
                    // stats/tokData/crew/screenName/shown (+navigator/say on command).
                    // The Loader gates CREATION on role, not just visibility:
                    // each window builds only its own deck tree.
                    Loader {
                        id: deckLoader
                        anchors.fill: parent
                        sourceComponent: win.isCommand ? (hud.v5Enabled ? v5Screen : commandScreen)
                                       : win.isHardware ? tokensScreen
                                       : systemScreen
                    }
                    // v5 live-preview deck: parsed only when the flag file exists,
                    // because the Loader below is created only through this Component.
                    Component {
                        id: v5Screen
                        Item {
                            anchors.fill: parent
                            // the loaded DeckV5, for the root IPC handler
                            // (ids inside a Component are not visible outside it)
                            readonly property alias deckItem: v5Loader.item
                            Loader {
                                id: v5Loader
                                anchors.fill: parent
                                source: Qt.resolvedUrl("../v5/live/DeckV5.qml")
                            }
                            Binding { target: v5Loader.item; property: "stats"; value: hud.stats; when: v5Loader.item !== null }
                            Binding { target: v5Loader.item; property: "tokData"; value: hud.tokData; when: v5Loader.item !== null }
                            Binding { target: v5Loader.item; property: "crew"; value: hud.crew; when: v5Loader.item !== null }
                            Binding { target: v5Loader.item; property: "shown"; value: deck.shown; when: v5Loader.item !== null }
                            Binding { target: v5Loader.item; property: "window"; value: win; when: v5Loader.item !== null }
                        }
                    }
                    Component {
                        id: commandScreen
                        DeckCommand {
                            anchors.fill: parent
                            stats: hud.stats
                            tokData: hud.tokData
                            crew: hud.crew
                            screenName: win.screenName
                            navigator: nav
                            sayText: hud.sayText
                            sayFlash: hud.sayFlash
                            shown: deck.shown
                        }
                    }
                    Component {
                        id: tokensScreen
                        DeckTokens {
                            anchors.fill: parent
                            stats: hud.stats
                            tokData: hud.tokData
                            crew: hud.crew
                            screenName: win.screenName
                            shown: deck.shown
                        }
                    }
                    Component {
                        id: systemScreen
                        DeckSystem {
                            anchors.fill: parent
                            stats: hud.stats
                            tokData: hud.tokData
                            crew: hud.crew
                            screenName: win.screenName
                            shown: deck.shown
                        }
                    }

                    // machined slab edge — the deck's chrome frame
                    Rectangle {
                        anchors.fill: parent
                        visible: !(win.isCommand && hud.v5Enabled)
                        color: "transparent"
                        border.width: 1
                        border.color: win.flashId === win.deckId
                                      ? Style.c.accent : Style.c.edge
                        radius: Style.r.pane
                    }
                    // focus flash — a brief accent pulse on ipc focus
                    Rectangle {
                        anchors.fill: parent
                        visible: !(win.isCommand && hud.v5Enabled)
                        color: "transparent"
                        border.width: 2
                        border.color: Style.c.accent
                        radius: Style.r.pane
                        opacity: win.flashId === win.deckId ? 0.85 : 0
                        Behavior on opacity { NumberAnimation { duration: 260 } }
                    }

                    // resize grip — the drawn corner bracket on the slab's
                    // bottom-right padding; inside the deck so it is already
                    // inside the mask region for the whole gesture
                    Item {
                        id: grip
                        visible: !(win.isCommand && hud.v5Enabled)
                        width: 26
                        height: 26
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        Rectangle {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            width: 18
                            height: 18
                            color: "transparent"
                            border.width: 0
                            Rectangle {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                width: 18
                                height: 2
                                color: gripMa.containsMouse ? Style.c.accent : Style.c.edge
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                width: 2
                                height: 18
                                color: gripMa.containsMouse ? Style.c.accent : Style.c.edge
                            }
                        }
                        MouseArea {
                            id: gripMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onPressed: m => win.sizePress(gripMa, deck, win.deckId, m.x, m.y)
                            onPositionChanged: m => win.sizeMove(gripMa, deck, m.x, m.y)
                            onReleased: () => win.sizeRelease(deck)
                            onCanceled: () => win.sizeAbort(deck)
                        }
                    }
                }
            }
        }
    }

    // --------------------------------------------------------------- IPC
    IpcHandler {
        target: "nexuslink.hud"

        function version(): string { return "v4" }
        // ---- Find (v5 deck). findOpen is the single source of truth in the
        // deck; openFind/closeFind also drive the keyboard grab and the
        // layer-shell keyboard mode, so IPC can never desync the two.
        function find(): string {
            var d = hud.commandDeck()
            if (!d) return "no v5 deck"
            return d.openFind() ? "ok" : "deck not shown"
        }
        function close(): string {
            var d = hud.commandDeck()
            if (!d) return "no v5 deck"
            d.closeFind()
            return "ok"
        }
        function toggle(): string {
            var d = hud.commandDeck()
            if (!d) return "no v5 deck"
            if (d.findOpen) d.closeFind()
            else d.openFind()
            return "ok"
        }
        function status(): string {
            return JSON.stringify({
                version: "v4",
                cpu: hud.cpuText,
                cpuFrac: hud.cpuFrac,
                mem: hud.memText,
                memFrac: hud.memFrac,
                gpu: hud.gpuKind,
                rx: hud.fmtRate(hud.rxRate),
                tx: hud.fmtRate(hud.txRate),
                frame: hud.batchSeq,
                statsAge_ms: hud.statsAgeMs(),
                uptime: hud.fmtUptime(hud.stats.uptime_s),
                procs: hud.procCount,
                tokProviders: hud.tokProviderCount,
                navOpen: nav.navOpen,
                findOpen: hud.commandDeck() ? hud.commandDeck().findOpen : false,
                monitors: winVariants.instances.length
            })
        }
        function panels(): string { return hud.ipcPanels() }
        function say(text: string): string { return hud.ipcSay(text) }
        function focus(id: string): string { return hud.ipcFocus(id) }
        function move(id: string, fx: real, fy: real): string {
            return hud.ipcMove(id, fx, fy)
        }
        function resize(id: string, fw: real): string { return hud.ipcResize(id, fw) }
        function show(id: string): string { return hud.ipcShowHide(id, false) }
        function hide(id: string): string { return hud.ipcShowHide(id, true) }
        function layout(name: string): string { return hud.ipcLayout(name) }
        function selftest(): string { hud.selftestArmed = true; return JSON.stringify(hud.selftestData()) }
        function roleprobe(): string {
            var out = []
            var ins = winVariants.instances
            for (var i = 0; i < ins.length; i++) {
                var md = ins[i].screen
                out.push({ name: String(md.name),
                           ident: ScreenRoles.identityOf(md),
                           role: ScreenRoles.roleForScreen(md) })
            }
            return JSON.stringify(out)
        }
        // raw ingest frame path — the last committed TSV batch verbatim
        function framesAlive(): string { return hud.lastFrameRaw }
        // grounded GPU attribution: inventory cards + live dev_gpuN_*
        // readings exactly as the DeckSystem graphics cell sees them
        function gpus(): string { return JSON.stringify(GpuCards.cards(hud.stats)) }
        function reload(): string {
            if (!streamProc.running) streamProc.running = true
            if (!probeProc.running) probeProc.running = true
            return "ok"
        }
    }
}
