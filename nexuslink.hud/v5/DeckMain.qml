import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris

import "../v4/ScreenRoles.js" as ScreenRoles
import "actions.js" as Actions

// DeckMain.qml - the v5 DP-2 deck's shell layer, and THE ONLY FILE UNDER v5/
// THAT IMPORTS QUICKSHELL. Hard rule (MAIN-SCREEN-BUILD.md constraint 2):
//
//   a grep for the Quickshell import line under nexuslink.hud/v5/  ->  this file only
//
// Everything the deck paints lives in DeckSurface.qml next to this file, which
// is pure QtQuick and is what tools/qml-shot.sh renders offscreen. This layer
// does the four things that need a shell and nothing else:
//
//   1. one PanelWindow on the command-role output ("DP-2"), on the background
//      layer with no keyboard focus, so the deck is a read-only surface;
//   2. the feeds: one Process per reader under v5/feeds, on a timer, with the
//      fixture file as the fallback. A missing or malformed feed leaves the last
//      good value in place; it never paints an error on the deck;
//   3. the IPC target, so `omarchy-shell nexuslink.hud.v5 <m>` can drive focus,
//      launch and rollback from a keybinding;
//   4. the rollout flag. Read here AND in v4/HudV4.qml from the same env var so
//      there is exactly one switch: NEXUSLINK_HUD_V5=1 shows the v5 deck, unset
//      or 0 keeps the v4 DeckCommand. Rollback is that one flag, no file edit.
Item {
    id: hud

    // injected by omarchy-shell
    property var shell: null
    property var manifest: null

    // ---- rollout flag ----------------------------------------------------
    // Same expression in HudV4.qml; this copy is what the deck itself reports in
    // `status()` so an operator can see which deck the shell believes it is on.
    readonly property bool v5DeckEnabled: {
        var raw = Quickshell.env("NEXUSLINK_HUD_V5")
        if (raw === null || raw === undefined)
            return false
        var v = String(raw).toLowerCase()
        return v === "1" || v === "true" || v === "on"
    }

    // ---- paths -----------------------------------------------------------
    // v5/DeckMain.qml sits at <plugin>/nexuslink.hud/v5/, so ../ resolves to the
    // plugin root and the readers and fixtures hang off it.
    readonly property string pluginRoot: decodeURIComponent(
        String(Qt.resolvedUrl("../")).replace(/^file:\/\//, ""))
    readonly property string feedsDir: pluginRoot + "v5/feeds"
    readonly property string fixturesDir: pluginRoot + "v5/fixtures"

    // ---- data in (bound into DeckSurface below) --------------------------
    property string clockText: ""
    property string dayText: ""
    property string dateText: ""
    property var sessions: []
    property var apps: []
    property var allApps: []
    property var hero: null
    property var findResults: []
    property string findQuery: ""
    property string findFilter: "all"
    property real rttMs: 0
    property real batteryLevel: 0
    property real loadLevel: 0
    property real modelGb: 0
    property real modelActivity: 0
    property var disks: []
    property string focusId: ""
    property bool assembling: false
    property real assembleProgress: 1

    // ==== MEDIA inputs (OWNER M: Quickshell Mpris) =========================
    // Selection rule as in the live medianotch plugin (read only): skip a player
    // with no metadata, prefer the first playing one, else the first one.
    readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
    function mediaHasMeta(p) { return !!(p && (p.trackTitle || p.trackArtist)) }
    readonly property var activePlayer: {
        var fallback = null
        for (var i = 0; i < mprisPlayers.length; ++i) {
            var p = mprisPlayers[i]
            if (!mediaHasMeta(p))
                continue
            if (p.isPlaying === true)
                return p
            if (fallback === null)
                fallback = p
        }
        return fallback
    }
    readonly property string mediaTitle: activePlayer !== null ? String(activePlayer.trackTitle || "") : ""
    readonly property string mediaArtist: activePlayer !== null ? String(activePlayer.trackArtist || "") : ""
    readonly property bool mediaPlaying: activePlayer !== null && activePlayer.isPlaying === true
    readonly property bool mediaAvailable: activePlayer !== null
    // NEXUSLINK_HUD_V5_DRYRUN=1/true/on: toggles are logged, never sent.
    readonly property bool mediaDryRun: {
        var raw = Quickshell.env("NEXUSLINK_HUD_V5_DRYRUN")
        if (raw === null || raw === undefined)
            return false
        var v = String(raw).toLowerCase()
        return v === "1" || v === "true" || v === "on"
    }

    // ==== QUICK ACTIONS (OWNER Q) ==========================================
    // The deck emits action ids; this layer maps them to typed commands. The
    // table and the plan live in actions.js (pure JS, tested offscreen). This
    // function only executes the plan: one Process, argv only, never a shell
    // string. An unknown id runs nothing.
    //
    // Dry run: NEXUSLINK_HUD_V5_DRYRUN=1/true/on logs the plan instead of doing
    // it (no process, no focus change, no playback toggle).
    readonly property bool quickDryRun: {
        var raw = Quickshell.env("NEXUSLINK_HUD_V5_DRYRUN")
        if (raw === null || raw === undefined)
            return false
        var v = String(raw).toLowerCase()
        return v === "1" || v === "true" || v === "on"
    }

    // Stub point: a harness replaces this with a function that records argv.
    property var quickRunner: startQuickCommand

    function startQuickCommand(argv) {
        quickProc.command = argv
        quickProc.running = true
    }

    Process {
        id: quickProc
        running: false
    }

    function runQuickAction(actionId) {
        var id = String(actionId)
        var p = Actions.plan(id, {})
        if (!p.known)
            return "unknown quick action " + id
        if (hud.quickDryRun) {
            var line = "QUICKACTION " + id + " " + JSON.stringify(p.argv)
            console.log(line)
            return line
        }
        if (p.deck === "launcher") {
            hud.focusId = "launcher"
            return "focus launcher"
        }
        if (p.deck === "media")
            return hud.toggleMedia()
        hud.quickRunner(p.argv)
        return "started " + id
    }

    // ==== MEDIA toggle (OWNER M) ===========================================
    // Toggles the player the pill shows and returns what happened, or why not.
    // Under NEXUSLINK_HUD_V5_DRYRUN the player is never called: the intent is
    // logged and returned instead.
    function toggleMedia() {
        var p = hud.activePlayer
        if (p === null)
            return "no player"
        if (!p.canTogglePlaying)
            return "player cannot toggle " + hud.mediaTitle
        if (hud.mediaDryRun) {
            console.log("MEDIA toggle " + hud.mediaTitle)
            return "MEDIA toggle " + hud.mediaTitle
        }
        p.togglePlaying()
        return "toggled " + hud.mediaTitle
    }

    // ==== FIND (OWNER Fq: process, keyboard focus mode, xdg-open) ============
    // A feed that has never answered keeps the deck in its calm rest state; a
    // feed that breaks after answering keeps its last good value (never blank,
    // never an error string on screen).
    property string lastFeedError: ""

    // Find: the FIND process, kill-previous and xdg-open (OWNER Fq).
    property bool findBusy: false
    property string findNote: ""
    property int findSeq: 0
    readonly property string homeDir: String(Quickshell.env("HOME") || "")

    // Every query edit restarts the reader: the previous process is stopped
    // first, and a late stream from it is dropped by sequence number.
    function runFind(text) {
        var raw = String(text === undefined || text === null ? "" : text)
        var q = raw.trim()
        hud.findSeq += 1
        findProc.running = false
        hud.findQuery = raw
        if (q.length === 0) {
            hud.findBusy = false
            hud.findNote = ""
            hud.findResults = []
            return
        }
        findProc.runSeq = hud.findSeq
        findProc.command = ["python3", hud.feedsDir + "/find.py", "--query", q,
                            "--filter", surface.findFilter, "--json"]
        hud.findBusy = true
        findProc.running = true
    }

    function findDone(seq, out) {
        if (seq !== hud.findSeq)
            return
        hud.findBusy = false
        var v = hud.readJson(out, null)
        if (v === null || v.ok === false) {
            hud.findNote = v === null ? "" : String(v.reason || "search failed")
            hud.findResults = []
            return
        }
        hud.findNote = String(v.note || "")
        hud.findResults = v.results || []
    }

    Process {
        id: findProc
        property int runSeq: 0
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: hud.findDone(findProc.runSeq, text)
        }
    }

    // Enter on a hit: xdg-open on the expanded path (the deck clears its focus).
    function openFindHit(path) {
        var p = String(path)
        if (p.indexOf("~/") === 0)
            p = hud.homeDir + p.slice(1)
        openProc.running = false
        openProc.command = ["xdg-open", p]
        openProc.running = true
    }

    Process {
        id: openProc
        running: false
    }

    // ---------------------------------------------------------------- clock
    // The clock is not a feed reader: it is local time, formatted. It is the one
    // thing on the deck that must not wait for a Process.
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered: hud.setClock(new Date())
    }

    function pad2(n) {
        return n < 10 ? "0" + n : String(n)
    }

    function setClock(d) {
        var days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        var months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                      "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        hud.clockText = pad2(d.getHours()) + ":" + pad2(d.getMinutes())
        hud.dayText = days[d.getDay()]
        hud.dateText = d.getDate() + " " + months[d.getMonth()]
    }

    // ---------------------------------------------------------------- feeds
    // One reader per source, exactly the ones the design amendments ask for.
    // Cadence is deliberately lazy: nothing here needs to be faster than a human
    // glance, and the Mac costs a round trip.
    function readJson(text, fallback) {
        try {
            var v = JSON.parse(String(text))
            return v === null || v === undefined ? fallback : v
        } catch (e) {
            hud.lastFeedError = "parse"
            return fallback
        }
    }

    // sessions: crew sessions from the Hermes state db (read-only in the reader).
    Process {
        id: sessionsProc
        command: ["python3", hud.feedsDir + "/sessions.py"]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var v = hud.readJson(text, null)
                if (v !== null && v.length !== undefined)
                    hud.sessions = v
            }
        }
    }

    // link: tunnel state, RTT median, Mac battery and load.
    Process {
        id: linkProc
        command: ["python3", hud.feedsDir + "/link.py"]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var v = hud.readJson(text, null)
                if (v === null || v.ok === false)
                    return
                if (v.rtt_ms !== undefined)
                    hud.rttMs = Number(v.rtt_ms.median !== undefined ? v.rtt_ms.median : v.rtt_ms)
                if (v.mac !== undefined) {
                    if (v.mac.batt !== undefined)
                        hud.batteryLevel = Math.max(0, Math.min(1, Number(v.mac.batt) / 100))
                    if (v.mac.load !== undefined && v.mac.load.length > 0)
                        hud.loadLevel = Math.max(0, Math.min(1, Number(v.mac.load[0])))
                }
            }
        }
    }

    // metrics: host load and the local AI model size/activity.
    Process {
        id: metricsProc
        command: ["python3", hud.feedsDir + "/metrics.py"]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var v = hud.readJson(text, null)
                if (v === null)
                    return
                // The `load` bar on the deck is the Mac's load (link.py); the
                // metrics reader's host load belongs to the box running the
                // shell, which is a different machine, so it is not bound here.
                if (v.local_ai !== undefined) {
                    if (v.local_ai.size_gb !== undefined)
                        hud.modelGb = Number(v.local_ai.size_gb)
                    if (v.local_ai.activity_cpu_s !== undefined)
                        hud.modelActivity = Math.max(0, Math.min(1, Number(v.local_ai.activity_cpu_s)))
                }
            }
        }
    }

    // apps: the launcher ranking (default set, all set, and the Arc hero).
    Process {
        id: appsProc
        command: ["python3", hud.feedsDir + "/apps.py"]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var v = hud.readJson(text, null)
                if (v === null)
                    return
                if (v.default !== undefined)
                    hud.apps = v.default
                if (v.all !== undefined)
                    hud.allApps = v.all
                if (v.arcRaiders !== undefined)
                    hud.hero = v.arcRaiders
            }
        }
    }

    // disks: `df` is the one live call that has no reader yet (the storage
    // actions module lists caches, not filesystems). Kept here so DeckSurface
    // stays data-free.
    Process {
        id: disksProc
        command: ["df", "-B1", "--output=source,used,size,target",
                  "-x", "tmpfs", "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay"]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var rows = String(text).split("\n")
                var out = []
                for (var i = 1; i < rows.length; ++i) {
                    var f = rows[i].trim().split(/\s+/)
                    if (f.length < 4)
                        continue
                    var used = Number(f[1])
                    var size = Number(f[2])
                    if (!(size > 0))
                        continue
                    out.push({
                        "label": f[0].replace(/^\/dev\//, ""),
                        "mount": f[3],
                        "used": used / size,
                        "usedGb": Math.round(used / 1e9),
                        "sizeGb": Math.round(size / 1e9)
                    })
                }
                if (out.length > 0)
                    hud.disks = out
            }
        }
    }

    // The feed timers. Fleet pulse asks for "cache 10 s, never faster"; the same
    // cadence is honest for the rest, and the disk list can be a minute old.
    Timer {
        interval: 10000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { sessionsProc.running = true; linkProc.running = true; metricsProc.running = true }
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { appsProc.running = true; disksProc.running = true }
    }

    // ---- fixtures --------------------------------------------------------
    // Two jobs: the fallback when a reader is missing (this Mac has no Hermes
    // state db path, a Linux host has no fixtures-only mode), and find results,
    // which are yuri's job later and are fixture data this round.

    FileView {
        id: sessionsFixture
        path: hud.fixturesDir + "/sessions.json"
        watchChanges: false
        printErrors: false
        onLoaded: if (hud.sessions.length === 0) hud.sessions = hud.readJson(text(), [])
    }

    FileView {
        id: appsFixture
        path: hud.fixturesDir + "/apps.json"
        watchChanges: false
        printErrors: false
        onLoaded: {
            var v = hud.readJson(text(), null)
            if (v === null)
                return
            if (v["default"] !== undefined && hud.apps.length === 0)
                hud.apps = v["default"]
            if (v.all !== undefined && hud.allApps.length === 0)
                hud.allApps = v.all
            if (v.arcRaiders !== undefined && hud.hero === null)
                hud.hero = v.arcRaiders
        }
    }

    FileView {
        id: metricsFixture
        path: hud.fixturesDir + "/metrics.json"
        watchChanges: false
        printErrors: false
        onLoaded: {
            var v = hud.readJson(text(), null)
            if (v === null)
                return
            if (v.local_ai !== undefined && hud.modelGb === 0)
                hud.modelGb = Number(v.local_ai.size_gb)
            if (v.host !== undefined && v.host.load1_frac !== undefined && hud.loadLevel === 0)
                hud.loadLevel = Math.max(0, Math.min(1, Number(v.host.load1_frac)))
        }
    }

    FileView {
        id: linkFixture
        path: hud.fixturesDir + "/link.json"
        watchChanges: false
        printErrors: false
        onLoaded: {
            var v = hud.readJson(text(), null)
            if (v === null || hud.rttMs > 0)
                return
            if (v.rtt_ms !== undefined)
                hud.rttMs = Number(v.rtt_ms.median !== undefined ? v.rtt_ms.median : v.rtt_ms)
            if (v.mac !== undefined && v.mac.batt !== undefined)
                hud.batteryLevel = Math.max(0, Math.min(1, Number(v.mac.batt) / 100))
        }
    }

    Component.onCompleted: {
        hud.setClock(new Date())
    }

    // ---- the window ------------------------------------------------------
    // One panel, on the command-role output only. Background layer, no keyboard
    // focus, no exclusion, transparent: the same contract as the v4 deck, so the
    // compositor treats the two identically while they are swapped by the flag.
    readonly property var deckScreen: {
        var screens = Quickshell.screens
        for (var i = 0; i < screens.length; ++i)
            if (ScreenRoles.roleForScreen(screens[i]) === "command")
                return screens[i]
        return screens.length > 0 ? screens[0] : null
    }

    PanelWindow {
        id: panel

        screen: hud.deckScreen

        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "nexuslink-hud-v5"
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.keyboardFocus: surface.wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // The four Satoshi faces live in DeckSurface.qml, not here: DeckSurface is
        // instantiated below, so the shell gets them, and a pure-QtQuick render
        // (tools/deck-shot.sh today, an offscreen gate on Linux tomorrow) gets
        // them without Quickshell. Nothing else in this file loads a font.

        DeckSurface {
            id: surface
            anchors.fill: parent

            findBusy: hud.findBusy
            findNote: hud.findNote
            findHome: hud.homeDir
            onFindQueryEdited: function (text) { hud.runFind(text) }
            onFindOpenRequested: function (path) { hud.openFindHit(path) }

            clockText: hud.clockText
            dayText: hud.dayText
            dateText: hud.dateText
            sessions: hud.sessions
            apps: hud.apps
            allApps: hud.allApps
            hero: hud.hero
            findResults: hud.findResults
            findQuery: hud.findQuery
            findFilter: hud.findFilter
            rttMs: hud.rttMs
            batteryLevel: hud.batteryLevel
            loadLevel: hud.loadLevel
            modelGb: hud.modelGb
            modelActivity: hud.modelActivity
            disks: hud.disks
            focusRequest: hud.focusId
            assembling: hud.assembling
            assembleProgress: hud.assembleProgress
            mediaTitle: hud.mediaTitle
            mediaArtist: hud.mediaArtist
            mediaPlaying: hud.mediaPlaying
            mediaAvailable: hud.mediaAvailable
            animate: true

            // The deck owns focus while a pointer or the keyboard is driving it;
            // the shell keeps its own copy so IPC stays in step.
            onFocusChanged: function (id) { hud.focusId = id }
            onLaunchRequested: function (slug) { hud.launch(slug) }
            onSessionActivated: function (sessionId) { hud.focusId = "" }
            onQuickActionRequested: function (actionId) { hud.runQuickAction(actionId) }
            onMediaToggleRequested: hud.toggleMedia()
        }
    }

    // ---- actions ---------------------------------------------------------
    // Every launch is a typed command, not a shell string built from data: the
    // slug is looked up in the ranking, and an unknown slug is refused.
    function launch(slug) {
        for (var i = 0; i < hud.apps.length; ++i)
            if (hud.apps[i].slug === slug)
                return hud.runLaunch(slug, hud.apps[i])
        return "unknown app " + slug
    }

    Process {
        id: launchProc
        running: false
    }

    function runLaunch(slug, row) {
        var cmd = row.launch !== undefined ? row.launch : hud.commandFor(slug)
        if (cmd === null || cmd === undefined || cmd.length === 0)
            return "no launch path for " + slug
        launchProc.command = cmd
        launchProc.running = true
        return "launched " + slug
    }

    // The launch table. Same entries the v4 launcher uses; a slug with no entry
    // (spotify, obsidian) is only in the all-apps view and refuses politely.
    function commandFor(slug) {
        switch (slug) {
        case "hermes": return ["hermes"]
        case "devin": return ["devin"]
        case "files": return ["nautilus"]
        case "terminal": return ["foot"]
        case "chrome": return ["chromium"]
        case "discord": return ["discord"]
        case "x": return ["xdg-open", "https://x.com"]
        case "youtube": return ["xdg-open", "https://youtube.com"]
        case "whatsapp": return ["xdg-open", "https://web.whatsapp.com"]
        case "arc-raiders": return ["heroic"]
        case "spotify": return ["spotify"]
        case "obsidian": return ["obsidian"]
        }
        return []
    }

    // ---- IPC -------------------------------------------------------------
    // `omarchy-shell nexuslink.hud.v5 <command>`. Separate target from v4's
    // nexuslink.hud, so the two decks can never answer for each other.
    IpcHandler {
        target: "nexuslink.hud.v5"

        function status(): string {
            return JSON.stringify({
                deck: "v5",
                enabled: hud.v5DeckEnabled,
                screen: hud.deckScreen !== null ? String(hud.deckScreen.name) : "",
                clock: hud.clockText,
                sessions: hud.sessions.length,
                apps: hud.apps.length,
                rtt_ms: hud.rttMs,
                batt: hud.batteryLevel,
                load: hud.loadLevel,
                model_gb: hud.modelGb,
                disks: hud.disks.length,
                focus: hud.focusId,
                feed_error: hud.lastFeedError
            })
        }
        function focus(id: string): string {
            var ok = ["crew", "find", "launcher", "mac", "storage", "local", ""]
            if (ok.indexOf(String(id)) < 0)
                return "unknown focus " + id
            hud.focusId = String(id)
            return "focus " + hud.focusId
        }
        function clearFocus(): string { hud.focusId = ""; return "focus cleared" }
        function query(text: string): string { hud.runFind(String(text)); return "query " + hud.findQuery }
        function filter(name: string): string { hud.findFilter = String(name); hud.runFind(hud.findQuery); return hud.findFilter }
        function assembly(p: string): string {
            hud.assembleProgress = Math.max(0, Math.min(1, Number(p)))
            hud.assembling = hud.assembleProgress < 1
            return "assemble " + hud.assembleProgress
        }
        function launchApp(slug: string): string { return hud.launch(String(slug)) }
    }
}
