pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// CommandHub.qml — DP-1 "COMMAND HUB" (lane D1).
// Visual spec: candidates/mock2/B/dp1.html. Chrome-cybercore masthead, five
// hub tiles per flank (F1..F10), the reactor dial dead-centred on the SCREEN
// (width/2, height/2 — BRIEF-V4-BUILD §2 / P2 gate), KnotField behind it at
// host opacity 0.9, and the shared UtilityDock along the bottom.
//
// Telemetry: `stats` is the parsed hud-collect frame (same map HudV3 got);
// `tokData` is the parsed tokens.json ledger. Missing keys render as "—"
// (Style.unknownGlyph), never fabricated. cpu%/net rates are frame deltas
// computed in onStatsChanged, the v3 applyFrame math. Arc easing is a short
// Behavior started by the telemetry delta — there is no idle repaint clock.
// KnotField's own scheduler already jitters effects at 30..60 s and settles
// lit; `running` follows `shown` so a hidden window costs zero paint.
// Lane B3: the dial carries an identity layer — NEXUSLINK · YURI arc text on
// the band (dialArcs pass), a YURI nameplate + host/state/uptime subtitle +
// status glyphs on the face, and the knot runs its per-screen seeded stream
// (seed = hash(screenName)) so effects never phase-align across monitors.
//
// Tile activation contract: navigator-aware sections call the injected
// Navigator scope (`navigator.openSection`) when HudV4 provides one, else
// fall back to the documented IPC `omarchy-shell nexuslink.nav open <s> ""`.
// Non-nav tiles fire real argv commands (execArgv only, no shell concat).

Item {
    id: root

    // ---- injected by HudV4.qml (lane H) -------------------------------------
    property var stats: ({})
    property var tokData: ({})
    property string screenName: "DP-1"
    property var navigator: null         // Navigator scope (optional)
    property string sayText: ""
    property bool sayFlash: false
    property bool shown: true            // host binds window visibility

    // ---- helpers -------------------------------------------------------------
    function has(k) {
        return stats[k] !== undefined && stats[k] !== "";
    }
    function num(v) {
        var n = Number(v);
        return isFinite(n) ? n : 0;
    }
    function clamp(v, lo, hi) {
        return Math.min(hi, Math.max(lo, v));
    }
    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function trunc(s, n) {
        s = String(s || "");
        return s.length > n ? s.substring(0, Math.max(1, n - 1)) + "…" : s;
    }
    function cssHex(c) {
        if (typeof c === "string")
            return c;
        function h(v) {
            var s = Math.round(v * 255).toString(16);
            return s.length < 2 ? "0" + s : s;
        }
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }
    function b(s) {
        return "<font color='" + cssHex(Style.c.accent) + "'><b>" + esc(s) + "</b></font>";
    }
    function i2(s) {
        return "<font color='" + cssHex(Style.c.accent2) + "'>" + esc(s) + "</font>";
    }
    function fmtUptime(sec) {
        var s = Math.max(0, Math.floor(num(sec)));
        var d = Math.floor(s / 86400);
        var h = Math.floor((s % 86400) / 3600);
        var m = Math.floor((s % 3600) / 60);
        function p2(x) {
            return (x < 10 ? "0" : "") + x;
        }
        if (d > 0)
            return d + "d " + p2(h) + "h";
        if (h > 0)
            return h + "h" + p2(m) + "m";
        return m + "m";
    }
    // Unknown stays unknown: a negative / non-numeric rate renders "—" rather
    // than a fabricated 0 B/s, so every call site inherits the rule.
    function fmtRate(bps) {
        var n = Number(bps);
        if (!isFinite(n) || n < 0)
            return Style.unknownGlyph;
        if (n >= 1073741824)
            return (n / 1073741824).toFixed(2) + " GB/s";
        if (n >= 1048576)
            return (n / 1048576).toFixed(1) + " MB/s";
        if (n >= 1024)
            return (n / 1024).toFixed(1) + " KB/s";
        return Math.round(n) + " B/s";
    }
    function fmtKiBtoGiB(kb) {
        return (num(kb) / 1048576).toFixed(1);
    }
    function fmtBtoGiB(v) {
        return (num(v) / 1073741824).toFixed(0);
    }
    function fmtBytes(v) {
        var n = num(v);
        if (n >= 1099511627776)
            return (n / 1099511627776).toFixed(1) + "T";
        if (n >= 1073741824)
            return (n / 1073741824).toFixed(0) + "G";
        if (n >= 1048576)
            return (n / 1048576).toFixed(0) + "M";
        if (n >= 1024)
            return (n / 1024).toFixed(0) + "K";
        return Math.round(n) + "B";
    }
    function fmtTok(n) {
        var v = Number(n);
        if (n === null || n === undefined || !isFinite(v))
            return Style.unknownGlyph;
        if (v >= 1e9)
            return (v / 1e9).toFixed(2) + "B";
        if (v >= 1e6)
            return (v / 1e6).toFixed(1) + "M";
        if (v >= 1e3)
            return (v / 1e3).toFixed(1) + "k";
        return String(Math.round(v));
    }
    // Navigator reach: injected scope first, documented IPC fallback second.
    // `path` is optional — only the files section consumes it (openSection
    // sets filesDir = resolveNavPath(path) when idx === 0 && path !== "").
    function openNav(sec, path) {
        var p = (path === undefined || path === null) ? "" : String(path);
        if (navigator !== null && navigator !== undefined && navigator.openSection !== undefined) {
            navigator.openSection(sec, p);
            return;
        }
        execArgv(["omarchy-shell", "-q", "nexuslink.nav", "open", sec, p]);
    }
    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "hub"].concat(argv));
    }
    // Action spec runner shared by tile rows and the side strips:
    // {nav: "section"} routes to Navigator, {argv: [...]} execs detached.
    function runAct(a) {
        if (a === null || a === undefined)
            return;
        if (a.nav !== undefined)
            openNav(a.nav, a.path !== undefined ? a.path : "");
        else if (a.argv !== undefined)
            execArgv(a.argv);
    }
    readonly property string homeDir: Quickshell.env("HOME") || ""
    readonly property var jumpWb: ({ "argv": ["hyprctl", "dispatch", "focusmonitor", "HDMI-A-3"] })
    readonly property var jumpBoard: ({ "argv": ["hyprctl", "dispatch", "focusmonitor", "DP-2"] })

    FontLoader {
        source: "file:///home/nexuslink/.local/share/fonts/nexushud/Michroma-Regular.ttf"
    }
    FontLoader {
        source: "file:///home/nexuslink/.local/share/fonts/nexushud/KodeMono-VF.ttf"
    }

    // Topology singleton is the shared device scaffold; HudV4 owns refresh().
    // Read-only here: leaf inventory + net interface names/states.
    readonly property var topo: (typeof Topology !== "undefined") ? Topology : null
    function topoNode(id) {
        return (topo !== null && topo.ready) ? topo.node(id) : undefined;
    }

    // ------------------------------------------------ delta-derived vitals ----
    // Same math as v3 applyFrame: counters diffed across batches.
    property double prevIdle: -1
    property double prevTotal: -1
    property real cpuPct: -1
    property double prevRx: -1
    property double prevTx: -1
    property double lastBatchT: 0
    // measured wall-clock gap between the last two frames — the only honest
    // cadence read-out (— until a second frame lands).
    property double lastFrameGapMs: -1
    property real rxRate: -1
    property real txRate: -1

    // arc fractions, quantized in applyFrame. -1 = unknown → bare track.
    property real aCpu: -1
    property real aGpu: -1
    property real aMem: -1
    property real aNet: -1
    onACpuChanged: dialFill.requestPaint()
    onAGpuChanged: dialFill.requestPaint()
    onAMemChanged: dialFill.requestPaint()
    onANetChanged: dialFill.requestPaint()
    // 1 % steps: a 1 Hz frame that moves a ring by less than a pixel of arc
    // must not cost a canvas repaint
    function q(v) {
        return v < 0 ? -1 : Math.round(v * 100) / 100;
    }

    onStatsChanged: {
        var idle = num(stats.cpu_idle), total = num(stats.cpu_total);
        if (prevTotal >= 0 && total > prevTotal)
            cpuPct = clamp(100 * (1 - (idle - prevIdle) / (total - prevTotal)), 0, 100);
        prevIdle = idle;
        prevTotal = total;

        var t = Date.now();
        var dt = lastBatchT > 0 ? (t - lastBatchT) / 1000 : 0;
        lastFrameGapMs = dt > 0 ? dt * 1000 : -1;
        // Rates need BOTH counters AND a previous frame — a lone key would
        // diff against 0 and read as a real 0 B/s. Absent → -1 → "—".
        var rx = num(stats.net_rx), tx = num(stats.net_tx);
        if (prevRx >= 0 && prevTx >= 0 && dt > 0 && has("net_rx") && has("net_tx")) {
            rxRate = Math.max(0, (rx - prevRx) / dt);
            txRate = Math.max(0, (tx - prevTx) / dt);
        } else {
            rxRate = -1;
            txRate = -1;
        }
        prevRx = rx;
        prevTx = tx;
        lastBatchT = t;

        aCpu = q(cpuPct >= 0 ? clamp(cpuPct / 100, 0, 1) : -1);
        aGpu = q(gpuFrac);
        aMem = q(memFrac);
        aNet = q((rxRate >= 0 && txRate >= 0) ? clamp((rxRate + txRate) / 60000000, 0, 1) : -1);
        root.pollTick();          // stats frame = poll cadence driver
    }

    readonly property int coreCount: {
        var n = 0;
        while (stats["cpu_core_" + n] !== undefined)
            n++;
        return n > 0 ? n : (has("cpu_cores") ? num(stats.cpu_cores) : 0);
    }
    readonly property string loadText: (has("load1") && has("load5") && has("load15")) ? stats.load1 + " · " + stats.load5 + " · " + stats.load15 : Style.unknownGlyph
    readonly property string uptimeText: has("uptime_s") ? fmtUptime(stats.uptime_s) : Style.unknownGlyph
    readonly property real memFrac: {
        var t = num(stats.mem_total_kb);
        return t > 0 ? (t - num(stats.mem_avail_kb)) / t : -1;
    }
    readonly property string memGiB: memFrac >= 0 ? fmtKiBtoGiB(num(stats.mem_total_kb) - num(stats.mem_avail_kb)) : Style.unknownGlyph
    readonly property string memTotGiB: has("mem_total_kb") ? fmtKiBtoGiB(stats.mem_total_kb) : Style.unknownGlyph
    readonly property real iPwrFrac: has("i_pwr_w") && num(stats.i_pwr_cap_w) > 0 ? clamp(num(stats.i_pwr_w) / num(stats.i_pwr_cap_w), 0, 1) : -1
    readonly property real gpuFrac: iPwrFrac >= 0 ? iPwrFrac : has("i_util") ? clamp(num(stats.i_util) / 100, 0, 1) : has("gpu_util") ? clamp(num(stats.gpu_util) / 100, 0, 1) : has("a_util") ? clamp(num(stats.a_util) / 100, 0, 1) : -1
    readonly property real maxTemp: {
        var t = -1;
        var keys = ["cpu_temp", "i_temp_pkg", "i_temp_vram", "i_temp_mctrl", "i_temp_pcie", "a_temp", "gpu_temp"];
        for (var i = 0; i < keys.length; i++)
            if (has(keys[i]))
                t = Math.max(t, num(stats[keys[i]]));
        return t;
    }
    readonly property bool alert: maxTemp > 85 || (memFrac >= 0 && memFrac > 0.9)
    readonly property bool linkOk: lastBatchT > 0 && (now.getTime() - lastBatchT) < 4000

    // ---- reactor identity (lane B3) ---------------------------------------
    // The dial is the machine's own presence, not a generic CPU gauge: the
    // face carries the YURI nameplate + host/state subtitle and the band
    // wears the NEXUSLINK · YURI roll-mark (painted in dialArcs).
    readonly property string hostText: has("host") ? String(stats.host).toUpperCase() : "NEXUSLINK"
    readonly property string kernelText: has("kernel") ? String(stats.kernel).toUpperCase() : ""
    readonly property int liveSess: {
        var n = 0;
        var ns = Math.min(12, has("devsess_count") ? num(stats.devsess_count) : 0);
        for (var i = 0; i < ns; i++)
            if (num(stats["devsess" + i + "_live"]) > 0)
                n++;
        return n;
    }
    readonly property string yuriState: alert ? "ALERT" : (linkOk ? "AWAKE" : "DARK")
    readonly property color stateCol: alert ? Style.c.alert : (linkOk ? Style.c.accent : Style.c.warn)
    // stable per-screen seed for the knot's async stream (djb2)
    function seedFor(s) {
        var h = 5381;
        s = String(s === undefined || s === null ? "knot" : s);
        for (var i = 0; i < s.length; i++)
            h = ((h << 5) + h + s.charCodeAt(i)) % 2147483647;
        return h <= 0 ? 97 : h;
    }

    property date now: new Date()
    // Sole wall-clock tick in this screen (1 Hz UI clock + poll cadence,
    // gated by `shown` — nothing ticks while the window is hidden).
    Timer {
        interval: 1000
        running: root.shown
        repeat: true
        onTriggered: {
            root.now = new Date();
            root.pollTick();
        }
    }
    readonly property string clockText: Qt.formatTime(root.now, "HH:mm:ss")
    // Measured collector cadence. Never a hardcoded "1 Hz" claim — a gap that
    // has not been observed twice yet reads "—".
    readonly property string frameGapText: lastFrameGapMs >= 0 ? (lastFrameGapMs / 1000).toFixed(2) + " s" : Style.unknownGlyph

    // ---- shared audio / media / power state ---------------------------------
    // Owned by this deck's UtilityDock instance (one poller per datum). The
    // old private 3 s av batch + 30 s powerprofile probe duplicated it.
    readonly property var mediaSt: dockStrip.media
    readonly property bool volMuted: dockStrip.volMuted
    readonly property bool micMuted: dockStrip.micMuted
    readonly property bool btOn: dockStrip.btPowered
    readonly property string powerProfile: dockStrip.powerProfile

    // ---- AI center key: dir resolve + entry count, one bounded probe --------
    // Prefer the btrfs-home AI center; fall back to the Kingston mount while
    // the migration is in flight. Empty output = neither dir exists → "—".
    property string aiCenterDir: ""
    property int aiCenterCount: -1
    // Face label: "~/NEXUS_AI_CENTER" under $HOME, "…/<parent>/<leaf>" off it —
    // the Kingston path is too long to print whole and still keep the key
    // compact.
    readonly property string aiCenterShort: {
        if (aiCenterDir === "")
            return "";
        var home = Quickshell.env("HOME") || "";
        if (home !== "" && aiCenterDir.indexOf(home + "/") === 0)
            return "~/" + aiCenterDir.substring(home.length + 1);
        var parts = aiCenterDir.split("/").filter(function (p) {
            return p !== "";
        });
        return "…/" + parts.slice(Math.max(0, parts.length - 2)).join("/");
    }
    function applyAiCenter(text) {
        var lines = String(text).split("\n");
        var d = (lines.length > 0) ? lines[0].trim() : "";
        aiCenterDir = (d.charAt(0) === "/") ? d : "";
        var n = (aiCenterDir !== "" && lines.length > 1) ? Number(lines[1]) : NaN;
        aiCenterCount = isFinite(n) ? Math.round(n) : -1;
    }
    Process {
        id: aiPoll
        running: false
        command: ["bash", "-lc",
            'd="$HOME/NEXUS_AI_CENTER"; [ -d "$d" ] || d=/run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER; [ -d "$d" ] || exit 0; printf "%s\\n" "$d"; find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l']
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyAiCenter(text)
        }
    }

    // ---- fetch cadence (no standalone poll timers — BRIEF §4 / verifier B6)
    // PRIMARY driver: the ~1 Hz stats frame — onStatsChanged tail-calls
    // pollTick(). FALLBACK while lane H's ingest is out of tree: the existing
    // 1 s clock timer above makes the same call, so there is still exactly
    // ONE 1 Hz wall-clock tick in this file, nothing faster, nothing while
    // hidden. Periods stay wall-clock (30 s ai probe), so overlapping
    // tick sources can never double-fire a fetch.
    property double _aiLast: -1
    function pollTick() {
        if (!root.shown)
            return;
        var t = Date.now();
        if (t - _aiLast >= 30000) {
            _aiLast = t;
            if (!aiPoll.running)
                aiPoll.running = true;
        }
    }
    Component.onCompleted: pollTick()

    // =============================================================== geometry --
    // Mock: padding 26/34/20, mast 64, band gap 26, centre col 940 px, util 118.
    readonly property int padX: 34
    readonly property int padTop: 26
    readonly property int padBot: 20
    readonly property int mastH: 64
    readonly property int bandGap: 26
    readonly property int colGap: 16
    readonly property int dockH: dockStrip.implicitHeight
    readonly property int bandY: padTop + mastH + 18
    readonly property int bandH: Math.max(320, root.height - bandY - dockH - padBot - 18)
    readonly property real centreW: Math.min(940, root.width * 0.37)
    // The mock's .band is `1fr 940px 1fr`, drawn at 1600×900 where each 1fr is
    // ≈270 px. On the 2560 px panel that same track inflates to 750 px and every
    // fact row ends up with ~450 px of dead space between its label and its
    // value — the single loudest source of "muddy" on this screen. Cap the
    // flanks at the width the fact grid was designed for and let the slack
    // become gutter; the columns are pinned to the outer padding, so the
    // reactor + knot keep the middle and the gutters stay symmetric for free.
    readonly property int colWMax: 500
    readonly property int colW: Math.max(300, Math.min(colWMax, Math.floor((root.width - 2 * padX - centreW - 2 * bandGap) / 2)))
    // True circle; spec size ≈760 px on the 2560×1440 panel. Operator pass W2:
    // the dial renders ~22% under spec (≈595 px on DP-1) so the pixel-knot
    // reads around the disc edge — `dialSpec` keeps the unshrunk value so the
    // knot field and any spec-relative sizing still have the original number.
    readonly property real dialSpec: Math.min(Math.round(root.width * 0.30), Math.round(root.height * 0.53), bandH - 24)
    readonly property real dialSize: Math.max(300, Math.round(dialSpec * 0.78))

    // One static elliptical wash — the mock's .field radial-gradients, and the
    // reactor's contact shadow. QML's Gradient is linear only, so the falloff
    // has to be a canvas; it is painted once per geometry change and never
    // again. `core` reserves a transparent centre, which is what turns a glow
    // into a shadow. `cyFrac` moves the ellipse's centre along the item's own
    // height, so a wash can hang off the top or bottom edge.
    component EllipseWash: Canvas {
        property color tint: Style.c.accent2
        property real peak: 0.05
        property real core: 0.0
        property bool circle: true
        property real cyFrac: 0.5
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var c = getContext("2d");
            c.clearRect(0, 0, width, height);
            var rx = width * 0.5;
            var col = Math.round(tint.r * 255) + "," + Math.round(tint.g * 255) + "," + Math.round(tint.b * 255);
            c.save();
            c.translate(rx, height * cyFrac);
            if (!circle)
                c.scale(1, height / width);
            var g = c.createRadialGradient(0, 0, 0, 0, 0, rx);
            g.addColorStop(0, "rgba(" + col + ",0)");
            if (core > 0)
                g.addColorStop(core, "rgba(" + col + ",0)");
            g.addColorStop(core + (1 - core) * 0.5, "rgba(" + col + "," + peak.toFixed(3) + ")");
            g.addColorStop(1, "rgba(" + col + ",0)");
            c.fillStyle = g;
            c.beginPath();
            c.arc(0, 0, rx, 0, Math.PI * 2);
            c.fill();
            c.restore();
        }
    }

    // dark cybercore field (mock .field sits behind everything; flat fill —
    // zero repaint cost, keeps the hub legible over whatever the host draws).
    // The flat base stays; the three washes below add the mock's atmosphere.
    Rectangle {
        anchors.fill: parent
        color: Style.c.bg
    }
    // atmosphere: ice wash off the top edge, acid lift off the bottom, and a
    // soft bloom behind the reactor so the dial sits in light, not on a void.
    EllipseWash {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.round(root.height * 0.46)
        peak: 0.055
        circle: false
        cyFrac: 0.0
    }
    EllipseWash {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.round(root.height * 0.4)
        tint: Style.c.accent
        peak: 0.032
        circle: false
        cyFrac: 1.0
    }
    EllipseWash {
        x: Math.round((root.width - root.dialSize * 2.0) / 2)
        y: Math.round((root.height - root.dialSize * 2.0) / 2)
        width: Math.round(root.dialSize * 2.0)
        height: width
        peak: 0.07
    }

    // =============================================================== knot ------
    // 48×49 pixel knot behind the reactor. Host wrapper holds opacity 0.9 so
    // idleGlow 0.56 lands ≈50% lit (lane-S contract / BRIEF §1).
    Item {
        id: knotWrap
        anchors.centerIn: parent
        width: knot.implicitWidth
        height: knot.implicitHeight
        opacity: 0.9
        KnotField {
            id: knot
            // px tracks `dialSpec` (the pre-shrink dial size), not `dialSize`:
            // the knot keeps its ≈spec-sized field while the dial shrinks to
            // 78%, so a lit knot ring clears the 1.22× shadow disc and reads
            // around the disc edge instead of hiding under the shadow stack.
            // The /44 divisor (was /48) widens the field one step further.
            px: Math.max(6, Math.round(root.dialSpec / 44))
            running: root.shown
            // per-screen personality: variant 0 (acid KNOT) is DP-1's mark;
            // the seeded stream keeps this instance's effects out of phase
            // with any sibling knot (lane B3).
            seed: root.seedFor(root.screenName)
        }
    }

    // =============================================================== masthead --
    GlassPane {
        id: mast
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: root.padX
        anchors.rightMargin: root.padX
        anchors.topMargin: root.padTop
        height: root.mastH
        radius: Style.r.pane
        holo: true

        // left cluster: logo + wordmark + screen sub  (mock .mast left)
        Row {
            id: mastLeft
            anchors.left: parent.left
            anchors.leftMargin: 22
            anchors.verticalCenter: parent.verticalCenter
            spacing: 26

            // mock logo: two nested rotated squares (ice outer, acid inner)
            Item {
                width: 30
                height: 30
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: 2
                    border.color: Style.c.accent2
                    rotation: 45
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 16
                    height: 16
                    color: "transparent"
                    border.width: 2
                    border.color: Style.c.accent
                    rotation: 45
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.RichText
                text: "NEXUS<font color='" + root.cssHex(Style.c.accent) + "'>LINK</font>"
                color: Style.c.txt
                font.family: Style.f.display
                font.pixelSize: 19
                font.letterSpacing: 8
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "COMMAND HUB · " + root.screenName + " · " + Math.round(root.width) + "×" + Math.round(root.height)
                color: Style.c.mute
                font.family: Style.f.mono
                font.pixelSize: Style.f.pxLabel
                font.letterSpacing: 2.2
            }
        }
        // masthead centre — the mock leaves a 1400 px void between the clusters.
        // One hairline split by a live cadence read-out anchors the eye and
        // reports a measured fact (the frame gap) instead of decoration.
        Item {
            id: mastRule
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: mastLeft.right
            anchors.right: mastRight.left
            anchors.leftMargin: 48
            anchors.rightMargin: 48
            height: cadence.implicitHeight
            Rectangle {
                id: ruleL
                anchors.left: parent.left
                anchors.right: cadence.left
                anchors.rightMargin: 11
                anchors.verticalCenter: parent.verticalCenter
                height: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0.0
                        color: "transparent"
                    }
                    GradientStop {
                        position: 1.0
                        color: Qt.rgba(0.92, 0.96, 0.99, 0.20)
                    }
                }
            }
            Rectangle {
                id: ruleR
                anchors.left: cadence.right
                anchors.leftMargin: 11
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: 1
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0.0
                        color: Qt.rgba(0.92, 0.96, 0.99, 0.20)
                    }
                    GradientStop {
                        position: 1.0
                        color: "transparent"
                    }
                }
            }
            Row {
                id: cadence
                anchors.centerIn: parent
                spacing: 9
                Rectangle {
                    width: 12
                    height: 1
                    color: Style.tone(Style.c.accent, 0.8)
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "COLLECT " + root.frameGapText
                    color: Style.c.faint
                    font.family: Style.f.mono
                    font.pixelSize: Style.f.pxTag
                    font.letterSpacing: 2.4
                }
                Rectangle {
                    width: 12
                    height: 1
                    color: Style.tone(Style.c.accent, 0.8)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
        // right cluster: weather + clock  (mock .mast right of .sp)
        Item {
            id: mastRight
            anchors.right: parent.right
            anchors.rightMargin: 22
            anchors.verticalCenter: parent.verticalCenter
            width: (root.has("weather") ? mastWx.width + 26 : 0) + mastClock.width
            height: mastClock.implicitHeight
            // Both hang off the same bottom edge: the 22 px display face and
            // the 10 px data line then share one optical baseline instead of
            // being centre-aligned into a vertical wobble.
            Text {
                id: mastWx
                anchors.bottom: parent.bottom
                visible: root.has("weather")
                text: root.has("weather") ? String(root.stats.weather).replace(/\s*·\s*/g, " · ").replace(/Temp\s+/, "").replace(/Wind\s+/, "") : ""
                color: Style.c.mute
                font.family: Style.f.mono
                font.pixelSize: Style.f.pxLabel
            }
            Text {
                id: mastClock
                anchors.bottom: parent.bottom
                x: root.has("weather") ? mastWx.width + 26 : 0
                text: root.clockText
                color: Style.c.accent2
                font.family: Style.f.display
                font.pixelSize: Style.f.pxClock
                font.letterSpacing: 2
            }
        }
    }

    // =============================================================== tile rows --
    component FactRow: Item {
        id: frow
        property var row: ({})          // {fl,fv,frac,tone,chart,bars,weight} | {act,g,fl,fh,nav|argv} | {btns:[{g,on,brand,argv|nav}]}
        property color txtCol: Style.c.txt
        property bool hot: false        // pointer is over this row (fed by HubTile's overlay)
        property int hoverBtn: -1
        readonly property bool plain: row.act !== true && row.btns === undefined

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            // mock .body gap:4 with .fbar's -2 margin → 2 px of visible air
            spacing: 2

            Item {
                width: parent.width
                height: Math.max(fl.implicitHeight, fv.implicitHeight)
                visible: frow.row.chart !== true && frow.plain
                Text {
                    id: fl
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    // mock .fact grid `1fr auto` with a 10 px column gap
                    width: Math.max(40, parent.width - fv.implicitWidth - 10)
                    elide: Text.ElideRight
                    // esc() pre-encodes the label, so the rich-text path is the
                    // one that renders those entities as the characters intended
                    textFormat: Text.RichText
                    text: frow.row.fl !== undefined ? frow.row.fl : ""
                    color: Style.c.mute
                    font.family: Style.f.mono
                    font.pixelSize: Style.f.pxLabel
                }
                Text {
                    id: fv
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.RichText
                    text: frow.row.fv !== undefined ? String(frow.row.fv) : ""
                    color: (frow.row.fvColor !== undefined) ? frow.row.fvColor : frow.txtCol
                    font.family: Style.f.mono
                    font.pixelSize: Style.f.pxLabel
                }
            }
            Item {
                id: actItem
                visible: frow.row.act === true
                width: parent.width
                height: visible ? 26 : 0
                Rectangle {
                    anchors.fill: parent
                    radius: Style.r.key
                    color: frow.hot ? Style.c.azureWash : "transparent"
                    border.width: 1
                    border.color: frow.hot ? Style.tone(Style.c.accent2, 0.50) : "transparent"
                }
                IconWell {
                    id: actWell
                    x: 3
                    anchors.verticalCenter: parent.verticalCenter
                    size: 20
                    glyph: frow.row.g !== undefined ? frow.row.g : ""
                    brand: frow.row.brand === true
                    hovered: frow.hot
                }
                Text {
                    anchors.left: actWell.right
                    anchors.leftMargin: 9
                    anchors.right: actHint.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: frow.row.fl !== undefined ? frow.row.fl : ""
                    color: frow.hot ? Style.c.txt : Style.c.dim
                    font.family: Theme.displayFamily
                    font.pixelSize: Style.f.pxLabel
                    font.letterSpacing: Style.f.lsTag
                }
                Tag {
                    id: actHint
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                    text: frow.row.fh !== undefined ? frow.row.fh : ""
                }
            }
            Item {
                id: btnItem
                visible: frow.row.btns !== undefined
                width: parent.width
                height: visible ? 30 : 0
                Row {
                    anchors.fill: parent
                    Repeater {
                        model: frow.row.btns !== undefined ? frow.row.btns : []
                        delegate: Item {
                            id: bd
                            required property var modelData
                            required property int index
                            width: btnItem.width / Math.max(1, frow.row.btns.length)
                            height: btnItem.height
                            IconWell {
                                anchors.centerIn: parent
                                size: 26
                                glyph: bd.modelData.g
                                brand: bd.modelData.brand === true
                                active: bd.modelData.on === true
                                tint: bd.modelData.on === true ? Style.c.accent : Style.c.azure
                                hovered: frow.hot && frow.hoverBtn === bd.index
                            }
                        }
                    }
                }
            }
            MiniChart {
                visible: frow.row.chart === true
                width: parent.width
                height: Math.max(28, frow.height - 4)
                bars: frow.row.bars !== undefined ? frow.row.bars : []
            }
            Item {
                width: parent.width
                // Always 4 px tall for value rows, whether or not this row has a
                // fraction to draw: rows that reserve the slot share one label
                // baseline. Action rows carry their own height instead.
                height: frow.plain ? 4 : 0
                Rectangle {
                    anchors.fill: parent
                    radius: 2
                    visible: frow.row.frac !== undefined && frow.row.frac >= 0
                    color: Style.c.recessTop
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    radius: 2
                    visible: frow.row.frac !== undefined && frow.row.frac >= 0
                    width: Math.round(parent.width * root.clamp(frow.row.frac, 0, 1))
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop {
                            position: 0.0
                            color: frow.row.tone === 1 ? Style.c.warn : frow.row.tone === 2 ? "#3a6a7a" : Style.c.accent2
                        }
                        GradientStop {
                            position: 1.0
                            color: frow.row.tone === 1 ? Style.c.alert : frow.row.tone === 2 ? Style.c.accent2 : Style.c.accent
                        }
                    }
                }
            }
        }
    }

    // Floating launcher key for the side strips: icon well + micro label.
    // Pure affordance (no datum); hover brightens the well and label.
    component StripKey: Item {
        id: sk
        property string glyph: ""
        property string label: ""
        property var spec: ({})
        width: 64
        height: 62
        IconWell {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            size: 40
            glyph: sk.glyph
            hovered: skMa.containsMouse
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            text: sk.label
            color: skMa.containsMouse ? Style.c.txt : Style.c.mute
            font.family: Theme.monoFamily
            font.pixelSize: Style.f.pxMicro
            font.letterSpacing: Style.f.lsTag
        }
        MouseArea {
            id: skMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.runAct(sk.spec)
        }
    }

    component MiniChart: Item {
        id: chart
        property var bars: []           // [{v,label,ice,unknown}]
        function maxV() {
            var mx = 0;
            for (var i = 0; i < bars.length; i++) {
                var v = Number(bars[i].v);
                if (isFinite(v) && v > mx)
                    mx = v;
            }
            return mx;
        }
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: parent.height
            spacing: 5
            Repeater {
                model: chart.bars
                delegate: Column {
                    id: mc
                    required property var modelData
                    required property int index
                    width: (chart.width - 5 * (chart.bars.length - 1)) / Math.max(1, chart.bars.length)
                    height: chart.height
                    spacing: 3
                    readonly property real availH: Math.max(4, chart.height - cap.implicitHeight - 2 * spacing)
                    readonly property color ink: mc.modelData.unknown === true ? Style.c.unknown : (mc.modelData.ice ? Style.c.accent2 : Style.c.accent)
                    readonly property real frac: {
                        var mx = chart.maxV();
                        var vv = Number(mc.modelData.v);
                        return (mx > 0 && isFinite(vv)) ? vv / mx : 0;
                    }
                    Item {
                        width: parent.width
                        height: Math.max(0, mc.availH - bar.height)
                    }
                    // A 4-bar chart across a full tile width turned each bar
                    // into a 250 px slab. Cap the ink and centre it in its slot
                    // so the row reads as a chart, not as a stack of blocks.
                    Rectangle {
                        id: bar
                        width: Math.min(parent.width, 48)
                        anchors.horizontalCenter: parent.horizontalCenter
                        radius: 2
                        height: mc.modelData.unknown === true ? 2 : Math.max(2, Math.round(mc.availH * mc.frac))
                        color: "transparent"
                        opacity: mc.modelData.unknown === true ? 1 : (mc.modelData.ice ? 0.85 : 0.9)
                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop {
                                position: 0.0
                                color: mc.ink
                            }
                            GradientStop {
                                position: 1.0
                                color: Style.tone(mc.ink, mc.modelData.unknown === true ? 1 : 0.25)
                            }
                        }
                    }
                    Text {
                        id: cap
                        width: parent.width
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        text: mc.modelData.label
                        color: mc.modelData.unknown === true ? Style.c.unknown : Style.c.faint
                        font.family: Style.f.mono
                        font.pixelSize: Style.f.pxMicro
                    }
                }
            }
        }
    }

    component HubTile: EmbossedTile {
        id: htile
        property string tileId: ""
        property int fkey: 0
        // rowsLive re-evaluates with every stats frame; `rows` only swaps when
        // the content really changed, so Repeater delegates are not rebuilt at 1 Hz
        property var rowsLive: root.tileFacts(tileId)
        property var rows: []
        property string rowsSig: ""
        onRowsLiveChanged: {
            var sg = JSON.stringify(rowsLive);
            if (sg !== rowsSig) {
                rowsSig = sg;
                rows = rowsLive;
            }
        }
        Component.onCompleted: {
            rowsSig = JSON.stringify(rowsLive);
            rows = rowsLive;
        }
        property int hoverIdx: -1
        property int hoverBtn: -1
        hoverExternal: rowLaunchArea.containsMouse
        // mock .tile padding:12px 14px — EmbossedTile adds the 1 px face inset
        padding: 13
        keyCap: fkey > 0 ? "F" + fkey : ""
        title: root.tileTitle(tileId)
        insight: root.tileInsight(tileId)
        hot: root.tileHot(tileId)
        onClicked: root.activateTile(tileId)

        // mock .body padding: 7 px vertical, 10 px horizontal
        readonly property int insetY: 7
        readonly property int insetX: 10
        // Row slots as cumulative integer heights. An equal share made the
        // TOKENS chart (44 px) overflow its 33 px slot and poke through the
        // module rim; a `weight` on a row now buys it the height it needs.
        readonly property var slots: {
            var rs = htile.rows;
            var n = Math.max(1, rs.length);
            var H = factsCol.height;
            var sum = 0;
            for (var i = 0; i < n; i++)
                sum += (rs[i] && rs[i].weight !== undefined) ? rs[i].weight : 1;
            var out = [];
            var acc = 0;
            for (i = 0; i < n; i++) {
                var share = (rs[i] && rs[i].weight !== undefined) ? rs[i].weight : 1;
                var hh = (i === n - 1) ? Math.round(H - acc) : Math.round(H * share / sum);
                out.push({
                    "y": acc,
                    "h": hh
                });
                acc += hh;
            }
            return out;
        }

        GlassPane {
            id: factsGlass
            anchors.fill: parent
            // radius scale stays monotonic inside-out: pane 10 → tile 7 → 5
            radius: Style.r.chip
            padding: 0
            Column {
                id: factsCol
                anchors.fill: parent
                anchors.topMargin: htile.insetY
                anchors.bottomMargin: htile.insetY
                anchors.leftMargin: htile.insetX
                anchors.rightMargin: htile.insetX
                spacing: 0
                Repeater {
                    model: htile.rows
                    delegate: FactRow {
                        required property var modelData
                        required property int index
                        x: 0
                        y: (htile.slots && htile.slots[index]) ? htile.slots[index].y : 0
                        width: factsCol.width
                        height: (htile.slots && htile.slots[index]) ? htile.slots[index].h : 0
                        row: modelData
                        hot: htile.hoverIdx === index
                        hoverBtn: htile.hoverIdx === index ? htile.hoverBtn : -1
                    }
                }
            }
        }

        // Row action layer (all tiles): FactRow delegates live in
        // EmbossedTile's `content`, UNDER its trailing hoverArea, so a
        // MouseArea nested in the delegate would never see a click. This
        // overlay is parented to the tile root at z>0 instead and hit-tests
        // which fact row was clicked: rows carrying a `launch` desktop id go
        // to `gtk-launch` through the shared execArgv wrapper; every other
        // click re-emits the tile's own clicked() so tile activation behaves
        // exactly as before. Hover is tracked here too (this layer sits above
        // the tile's own hover area) and lights the row, the tile rim follows
        // through hoverExternal.
        property var rowLaunchArea: MouseArea {
            parent: htile
            z: 4
            anchors.fill: parent
            hoverEnabled: true
            // rowAt: maps a tile-space point onto a fact row (+ button column)
            function rowAt(mx, my) {
                var gp = factsGlass.mapFromItem(htile, mx, my);
                var colY = gp.y - htile.insetY;   // factsCol is inset inside factsGlass
                var sl = htile.slots;
                for (var si = 0; si < sl.length; si++)
                    if (colY >= sl[si].y && colY < sl[si].y + sl[si].h)
                        return si;
                return -1;
            }
            function btnAt(mx, row) {
                var n = (row && row.btns !== undefined) ? row.btns.length : 0;
                if (n === 0)
                    return -1;
                var gx = factsGlass.mapFromItem(htile, mx, 0).x - htile.insetX;
                return Math.max(0, Math.min(n - 1, Math.floor(gx / Math.max(1, factsCol.width / n))));
            }
            onPositionChanged: function (mouse) {
                var rs = htile.rows;
                var idx = rowAt(mouse.x, mouse.y);
                var r = (idx >= 0 && idx < rs.length) ? rs[idx] : null;
                var actionable = r !== null && (r.act === true || r.btns !== undefined || r.launch !== undefined);
                htile.hoverIdx = actionable ? idx : -1;
                htile.hoverBtn = actionable ? btnAt(mouse.x, r) : -1;
            }
            onExited: {
                htile.hoverIdx = -1;
                htile.hoverBtn = -1;
            }
            onClicked: function (mouse) {
                var rs = htile.rows;
                var idx = rowAt(mouse.x, mouse.y);
                var r = (idx >= 0 && idx < rs.length) ? rs[idx] : null;
                if (r !== null && r.btns !== undefined) {
                    var bi = btnAt(mouse.x, r);
                    root.runAct(r.btns[bi]);
                } else if (r !== null && r.act === true)
                    root.runAct(r);
                else if (r !== null && r.launch !== undefined && String(r.launch) !== "")
                    root.execArgv(["gtk-launch", String(r.launch)]);
                else
                    htile.clicked();
            }
        }
    }

    // ---- tile model -----------------------------------------------------------
    readonly property var leftTiles: ["files", "procs", "devices", "agents", "repos"]
    readonly property var rightTiles: ["network", "storage", "media", "tokens", "system"]
    readonly property var tileNames: ({
            "files": "FILES",
            "procs": "PROCESSES",
            "devices": "DEVICES",
            "agents": "AGENTS",
            "repos": "REPOS / CI",
            "network": "NETWORK",
            "storage": "STORAGE",
            "media": "MEDIA",
            "tokens": "TOKENS",
            "system": "SYSTEM"
        })
    function tileTitle(id) {
        return tileNames[id] !== undefined ? tileNames[id] : id.toUpperCase();
    }

    function activateTile(id) {
        switch (id) {
        case "files":
            openNav("files");
            break;
        case "procs":
            openNav("proc");
            break;
        case "devices":
            openNav("devices");
            break;
        case "agents":
            openNav("agents");
            break;
        case "repos":
            openNav("repos");
            break;
        case "tokens":
            openNav("usage");
            break;
        case "network":
            execArgv(["omarchy-shell", "-q", "omarchy.network", "toggle"]);
            break;
        case "storage":
            execArgv(["omarchy-launch-nautilus"]);
            break;
        case "media":
            execArgv(["omarchy-shell", "-q", "media", "playPause"]);
            break;
        case "system":
            execArgv(["omarchy-shell", "-q", "omarchy.system-update", "refresh"]);
            break;
        }
    }

    // ---- per-tile live insight (one line per the dispatch spec) -----------------
    function tileInsight(id) {
        switch (id) {
        case "files":
            {
                var mp = mountRows();
                if (mp.length === 0)
                    return has("fs_root_pct") ? b(Math.round(num(stats.fs_root_pct)) + "%") + " root" : Style.unknownGlyph;
                var hotM = mp[0];
                return b(Math.round(hotM.pct) + "%") + " " + esc(trunc(hotM.name, 14)) + " · " + mp.length + " mounts live";
            }
        case "procs":
            return i2("↗ navigator · F2");
        case "devices":
            return i2("↗ navigator · F3");
        case "agents":
            // Crew-status placeholder (D1): the roster read-out arrives with
            // the crew module; no session or harness values are read here.
            return i2("crew");
        case "repos":
            return i2("↗ navigator · F5");
        case "network":
            return i2("bar module · toggle");
        case "storage":
            return has("fs_root_pct") ? b(Math.round(num(stats.fs_root_pct)) + "%") + " root" : Style.unknownGlyph;
        case "media":
            return i2("transport · play/pause");
        case "tokens":
            return i2("↗ navigator · F9");
        case "system":
            {
                var up = has("pkg_updates") ? b(String(num(stats.pkg_updates))) + " updates pending" : "updates " + Style.unknownGlyph;
                return up + (powerProfile !== "" ? " · " + i2(powerProfile) : "");
            }
        }
        return "";
    }

    function tileHot(id) {
        switch (id) {
        case "files":
            {
                var mp = mountRows();
                return mp.length > 0 && mp[0].pct >= 70;
            }
        case "procs":
            return has("proc0_cpu") && num(stats.proc0_cpu) >= 90;
        case "devices":
            return has("bat0_pct") && num(stats.bat0_pct) <= 25 && String(stats.bat0_state) === "Discharging";
        case "agents":
            return (has("devsess_count") && num(stats.devsess_count) > 0) || (has("ag_devin_acp") && num(stats.ag_devin_acp) > 0);
        case "repos":
            {
                for (var i = 0; i < 6; i++)
                    if (has("ghev" + i + "_type") && String(stats["ghev" + i + "_type"]).toLowerCase().indexOf("fail") >= 0)
                        return true;
                return false;
            }
        case "network":
            return has("net_rx") && !linkOk;
        case "storage":
            {
                var worst = 0;
                for (var vi = 0; vi < 4; vi++)
                    if (has("nvme" + vi + "_temp"))
                        worst = Math.max(worst, num(stats["nvme" + vi + "_temp"]));
                return worst >= 70 || (has("fs_root_pct") && num(stats.fs_root_pct) >= 85);
            }
        case "media":
            return mediaSt.playing === true;
        case "tokens":
            return false;
        case "system":
            return has("pkg_updates") && num(stats.pkg_updates) > 0;
        }
        return false;
    }

    // ---- fact rows --------------------------------------------------------------
    function baseName(p) {
        var s = String(p || "");
        var i = s.lastIndexOf("/");
        return i >= 0 ? s.substring(i + 1) : s;
    }
    // Mounted-partition list from the blk{i}p{j}_* keys, root first then by
    // fill % — the live "mount pressure" table for FILES and STORAGE.
    function mountRows() {
        var rows = [];
        var nb = Math.min(8, has("blk_count") ? num(stats.blk_count) : 0);
        for (var i = 0; i < nb; i++) {
            var np = Math.min(8, num(stats["blk" + i + "p_count"]));
            for (var j = 0; j < np; j++) {
                var pre = "blk" + i + "p" + j + "_";
                var mnt = has(pre + "mount") ? String(stats[pre + "mount"]) : "";
                if (mnt === "" || !has(pre + "pct"))
                    continue;
                var label = has(pre + "label") && String(stats[pre + "label"]) !== "" ? String(stats[pre + "label"]) : String(stats[pre + "name"] || "");
                var pct = num(stats[pre + "pct"]);
                var free = num(stats[pre + "size_bytes"]) - num(stats[pre + "used_bytes"]);
                rows.push({
                    // unlabelled partitions fall back to the mount's leaf name —
                    // repeating the full path on both sides of the fact row read
                    // as a duplicated field
                    name: label !== "" ? label : root.baseName(mnt),
                    mount: mnt,
                    pct: pct,
                    free: free
                });
            }
        }
        rows.sort(function (a, b2) {
            if (a.mount === "/")
                return -1;
            if (b2.mount === "/")
                return 1;
            return b2.pct - a.pct;
        });
        return rows;
    }

    function peripheralCount() {
        var n = has("bat_count") ? num(stats.bat_count) : 0;
        var leaves = 0;
        // hot-removable USB leaves verified attached during recon (vidPid probed
        // from sysfs in lane T's scaffold) — a static-truth inventory, not a
        // fabricated live count.
        var leafCls = {
            "usb_camera": 1,
            "usb_receiver": 1,
            "usb_keyboard": 1,
            "usb_rgb": 1,
            "usb_storage": 1,
            "usb_bluetooth": 1
        };
        if (topo !== null && topo.ready) {
            var list = topo.nodeList;
            for (var i = 0; i < list.length; i++) {
                var nd = list[i];
                if (nd && nd.extra && leafCls[nd.extra.cls] === 1 && nd.extra.vidPid !== undefined)
                    leaves++; // recon-verified sysfs attachment
            }
        }
        return (topo !== null && topo.ready) ? leaves + n : (n > 0 ? n : -1);
    }

    function tokToday() {
        var prov = (tokData && tokData.providers) ? tokData.providers : null;
        if (prov === null)
            return -1;
        var sum = 0, seen = false;
        var blocked = ["claude", "codex", "openai", "anthropic"];
        for (var k in prov) {
            var p = prov[k];
            if (!p || !p.day)
                continue;
            var kl = String(k).toLowerCase(), bl = String(p.label || "").toLowerCase(), skip = false;
            for (var bi = 0; bi < blocked.length; bi++)
                if (kl === blocked[bi] || kl.indexOf(blocked[bi] + "-") === 0 || kl.indexOf(blocked[bi] + "_") === 0 || bl.indexOf(blocked[bi]) === 0) { skip = true; break; }
            if (skip)
                continue;
            var ii = Number(p.day["in"]), oo = Number(p.day.out), tt = Number(p.day.total);
            if (isFinite(ii) || isFinite(oo)) {
                sum += (isFinite(ii) ? ii : 0) + (isFinite(oo) ? oo : 0);
                seen = true;
            } else if (isFinite(tt)) {
                sum += tt;
                seen = true;
            }
        }
        return seen ? sum : -1;
    }

    function tokBars() {
        var prov = (tokData && tokData.providers) ? tokData.providers : null;
        var order = ["devin", "opencode", "haze", "fireworks"];
        var bars = [];
        for (var i = 0; i < order.length; i++) {
            var p = prov !== null ? prov[order[i]] : null;
            var v = NaN;
            if (p && p.day) {
                var ii = Number(p.day["in"]), oo = Number(p.day.out), tt = Number(p.day.total);
                v = (isFinite(ii) || isFinite(oo)) ? (isFinite(ii) ? ii : 0) + (isFinite(oo) ? oo : 0) : tt;
            }
            bars.push({
                v: isFinite(v) ? v : 0,
                label: order[i],
                ice: i % 2 === 1,
                // no ledger entry for this provider → dim baseline stub, never
                // a zero-height bar that would read as "0 tokens"
                unknown: !isFinite(v)
            });
        }
        return bars;
    }

    function tileFacts(id) {
        var rows = [];
        var i;
        switch (id) {
        case "files":
            {
                var mp = mountRows();
                for (i = 0; i < Math.min(4, mp.length); i++) {
                    var m = mp[i];
                    rows.push({
                        fl: esc(m.name) + (m.mount !== m.name ? " · " + esc(m.mount) : ""),
                        fv: "<b>" + Math.round(m.pct) + "%</b> · " + fmtBytes(m.free) + " free",
                        frac: m.pct / 100,
                        tone: m.pct >= 70 ? 1 : (i === 0 ? 0 : 2)
                    });
                }
                if (rows.length === 0 && has("fs_root_pct"))
                    rows.push({
                        fl: "/ root",
                        fv: "<b>" + Math.round(num(stats.fs_root_pct)) + "%</b> · " + fmtBtoGiB(num(stats.fs_root_size) - num(stats.fs_root_used)) + "G free",
                        frac: num(stats.fs_root_pct) / 100,
                        tone: num(stats.fs_root_pct) >= 70 ? 1 : 0
                    });
                if (rows.length === 0)
                    rows.push({
                        fl: "mounts",
                        fv: Style.unknownGlyph
                    });
                break;
            }
        case "procs":
            {
                // Action rows only (map row 4): values live in the Workbench PROCESS LEDGER.
                rows.push({ act: true, g: Style.ico.layers, fl: "PROCESS LEDGER", fh: "WB", argv: jumpWb.argv });
                rows.push({ act: true, g: Style.ico.term, fl: "BTOP", fh: "TUI", argv: ["omarchy-launch-tui", "btop"] });
                rows.push({ act: true, g: Style.ico.search, fl: "NAVIGATOR", fh: "F2", nav: "proc" });
                break;
            }
        case "devices":
            {
                rows.push({
                    btns: [
                        { g: Style.icoBrand.bt, brand: true, on: btOn, argv: ["omarchy-shell", "-q", "omarchy.bluetooth", "toggle"] },
                        { g: volMuted ? Style.ico.mute : Style.ico.vol, on: volMuted, argv: ["omarchy-audio-output-volume", "mute-toggle"] },
                        { g: Style.ico.mic, on: micMuted, argv: ["omarchy-audio-input-mute"] },
                        { g: Style.ico.display, argv: ["omarchy-audio-output-switch"] }
                    ]
                });
                rows.push({ act: true, g: Style.ico.hub, fl: "DEVICE BAY", fh: "WB", argv: jumpWb.argv });
                rows.push({ act: true, g: Style.ico.search, fl: "NAVIGATOR", fh: "F3", nav: "devices" });
                break;
            }
        case "agents":
            {
                rows.push({ act: true, g: Style.ico.robot, fl: "HERMES SESSION", fh: "TUI", argv: ["omarchy-launch-tui", "--app-id=org.nexus.hermes", "hermes"] });
                rows.push({ act: true, g: Style.ico.pulse, fl: "SESSION LEDGER", fh: "WB", argv: jumpWb.argv });
                // Launchable harnesses: row click -> gtk-launch <desktop id>
                rows.push({ fl: "devin", fv: i2("↗ launch"), launch: "devin-desktop" });
                rows.push({ fl: "october", fv: i2("↗ launch"), launch: "october" });
                break;
            }
        case "repos":
            {
                rows.push({ act: true, g: Style.ico.branch, fl: "GITHUB FEED", fh: "WB", argv: jumpWb.argv });
                rows.push({ act: true, g: Style.ico.folder, fl: "WORKTREES", fh: "DIR", argv: ["uwsm-app", "--", "nautilus", "--new-window", homeDir + "/hud-wt"] });
                rows.push({ act: true, g: Style.ico.search, fl: "REPOS NAV", fh: "F5", nav: "repos" });
                break;
            }
        case "network":
            {
                rows.push({ act: true, g: Style.ico.wifi, fl: "NETWORK BAR", fh: "TOG", argv: ["omarchy-shell", "-q", "omarchy.network", "toggle"] });
                rows.push({ act: true, g: Style.ico.chip, fl: "TOPOLOGY", fh: "DP-2", argv: jumpBoard.argv });
                break;
            }
        case "storage":
            {
                // Mount / fill % is CommandHub's own datum (D4), shown on FILES
                // and STORAGE; drive temps (map row 9) and io rates (row 10)
                // belong to BoardView and are not read here.
                var mp2 = mountRows();
                for (i = 0; i < Math.min(3, mp2.length); i++) {
                    var sm = mp2[i];
                    rows.push({
                        fl: esc(sm.name) + (sm.mount !== sm.name ? " · " + esc(sm.mount) : ""),
                        fv: "<b>" + Math.round(sm.pct) + "%</b> · " + fmtBytes(sm.free) + " free",
                        frac: sm.pct / 100,
                        tone: sm.pct >= 70 ? 1 : (i === 0 ? 0 : 2)
                    });
                }
                if (rows.length === 0 && has("fs_root_pct"))
                    rows.push({
                        fl: "/ root",
                        fv: "<b>" + Math.round(num(stats.fs_root_pct)) + "%</b> · " + fmtBtoGiB(num(stats.fs_root_size) - num(stats.fs_root_used)) + "G free",
                        frac: num(stats.fs_root_pct) / 100,
                        tone: num(stats.fs_root_pct) >= 70 ? 1 : 0
                    });
                if (rows.length === 0)
                    rows.push({
                        fl: "mounts",
                        fv: Style.unknownGlyph
                    });
                break;
            }
        case "media":
            {
                rows.push({
                    weight: 1.6,
                    btns: [
                        { g: Style.ico.prev, argv: ["omarchy-shell", "-q", "media", "previous"] },
                        { g: mediaSt.playing === true ? Style.ico.pause : Style.ico.play, on: mediaSt.playing === true, argv: ["omarchy-shell", "-q", "media", "playPause"] },
                        { g: Style.ico.next, argv: ["omarchy-shell", "-q", "media", "next"] },
                        { g: volMuted ? Style.ico.mute : Style.ico.vol, on: volMuted, argv: ["omarchy-audio-output-volume", "mute-toggle"] }
                    ]
                });
                rows.push({ act: true, g: Style.ico.display, fl: "SWITCH OUTPUT", fh: "SINK", argv: ["omarchy-audio-output-switch"] });
                break;
            }
        case "tokens":
            {
                rows.push({ act: true, g: Style.ico.layers, fl: "TOKEN LEDGER", fh: "WB", argv: jumpWb.argv });
                rows.push({ act: true, g: Style.ico.search, fl: "USAGE OVERLAY", fh: "F9", nav: "usage" });
                break;
            }
        case "system":
            {
                rows.push({
                    fl: "pkg updates",
                    fv: has("pkg_updates") ? "<b>" + num(stats.pkg_updates) + "</b> pending" : Style.unknownGlyph,
                    tone: has("pkg_updates") && num(stats.pkg_updates) > 0 ? 1 : 0
                });
                rows.push({
                    fl: "kernel",
                    fv: has("kernel") ? esc(trunc(stats.kernel, 22)) : Style.unknownGlyph
                });
                rows.push({
                    fl: "power profile",
                    fv: powerProfile !== "" ? i2(powerProfile) : Style.unknownGlyph
                });
                // theme row added per map row 23 (M3): CH is the sole home.
                rows.push({
                    fl: "theme",
                    fv: has("theme_name") ? i2(esc(trunc(stats.theme_name, 12))) : Style.unknownGlyph
                });
                rows.push({
                    weight: 1.3,
                    btns: [
                        { g: Style.ico.sync, argv: ["omarchy-shell", "-q", "omarchy.system-update", "refresh"] },
                        { g: Style.ico.bolt, on: powerProfile === "performance", argv: ["omarchy-powerprofiles-set", "autodetect", powerProfile === "performance" ? "power-saver" : "performance"] },
                        { g: Style.ico.moon, argv: ["omarchy-shell", "-q", "nightlight", "toggle"] },
                        { g: Style.ico.palette, argv: ["omarchy-theme-bg-next"] }
                    ]
                });
                break;
            }
        }
        return rows;
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

    // =============================================================== columns ---
    Column {
        id: leftCol
        x: root.padX
        y: root.bandY
        width: root.colW
        height: root.bandH
        spacing: root.colGap
        Repeater {
            model: root.leftTiles
            delegate: HubTile {
                required property var modelData
                required property int index
                tileId: modelData
                fkey: index + 1
                width: leftCol.width
                height: Math.floor((leftCol.height - (root.leftTiles.length - 1) * leftCol.spacing) / root.leftTiles.length)
            }
        }
    }
    Column {
        id: rightCol
        x: root.width - root.padX - root.colW
        y: root.bandY
        width: root.colW
        height: root.bandH
        spacing: root.colGap
        Repeater {
            model: root.rightTiles
            delegate: HubTile {
                required property var modelData
                required property int index
                tileId: modelData
                fkey: index + 6
                width: rightCol.width
                height: Math.floor((rightCol.height - (root.rightTiles.length - 1) * rightCol.spacing) / root.rightTiles.length)
            }
        }
    }

    // =============================================================== reactor ---
    // Centred on the SCREEN root (width/2, height/2) per BRIEF §2 — the band
    // column centres it on the mock's free space, anchoring here makes the
    // P2 gate's 8 px tolerance hold regardless of masthead/dock height.
    Item {
        id: reactor
        anchors.centerIn: parent
        width: Math.round(root.dialSize)
        height: Math.round(root.dialSize)

        // layered drop shadow + dark glass backing so the ~50% knot flood
        // never drowns the readout (v3fix-reapplied: 3 discs, then glass).
        // Repainted as one contact shadow: the previous pair of hard-edged
        // black discs at 1.22x / 1.10x read as one flat blob pasted on the
        // field, so a single feathered rim wash (transparent core → dark
        // plateau → transparent) grounds the dial instead. The dark glass
        // backing that protects the readout is still painted by discCanvas.
        EllipseWash {
            x: Math.round(-reactor.width * 0.15)
            y: Math.round(reactor.height * 0.03)
            width: Math.round(reactor.width * 1.3)
            height: width
            tint: "#000000"
            peak: 0.6
            core: 0.66
            cyFrac: 0.55
        }

        // static disc pass: dial body gradient, rim, glasdisc, corona, and the
        // centre legibility fade. Repaints on geometry change only.
        Canvas {
            id: discCanvas
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()
            onPaint: {
                var c = getContext("2d");
                c.clearRect(0, 0, width, height);
                var W = width, H = height;
                var cx = W / 2, cy = H / 2;
                var R = Math.min(W, H) * 0.5 - 2;
                if (R < 36)
                    return;

                // dial body — radial graphite disc (mock .dial)
                c.beginPath();
                c.arc(cx, cy, R, 0, Math.PI * 2);
                c.fillStyle = "rgba(11,14,18,0.88)";
                c.fill();
                var gB = c.createRadialGradient(cx, cy - R * 0.16, R * 0.05, cx, cy, R);
                gB.addColorStop(0, "rgba(16,20,26,0.92)");
                gB.addColorStop(0.72, "rgba(8,10,13,0.94)");
                gB.addColorStop(1, "rgba(6,8,10,0.96)");
                c.beginPath();
                c.arc(cx, cy, R, 0, Math.PI * 2);
                c.fillStyle = gB;
                c.fill();
                // 1 px glass rim + inset top light / bottom shade
                c.lineWidth = 1;
                c.strokeStyle = "rgba(190,220,245,0.10)";
                c.beginPath();
                c.arc(cx, cy, R - 0.5, 0, Math.PI * 2);
                c.stroke();
                c.lineWidth = Math.max(1.2, R * 0.006);
                c.strokeStyle = "rgba(235,245,252,0.10)";
                c.beginPath();
                c.arc(cx, cy, R - 1.5, -Math.PI * 0.82, -Math.PI * 0.18);
                c.stroke();
                c.lineWidth = Math.max(2, R * 0.05);
                c.strokeStyle = "rgba(0,0,0,0.42)";
                c.beginPath();
                c.arc(cx, cy, R - R * 0.028, Math.PI * 0.22, Math.PI * 0.78);
                c.stroke();

                // orbit corona — 72 notches, lit head sector at the bottom
                // exactly like the mock's static svg pass (no rotation clock).
                var rO = R * 0.995;
                c.lineWidth = 1.2;
                for (var i = 0; i < 72; i++) {
                    var ta = i / 72 * Math.PI * 2;
                    var maj = (i % 6 === 0);
                    var hd = ((ta - Math.PI * 0.5) % (Math.PI * 2) + Math.PI * 2) % (Math.PI * 2);
                    var head = Math.max(0, 1 - hd / (Math.PI * 0.6));
                    var al = 0.06 + (maj ? 0.05 : 0) + head * 0.30;
                    var r1 = rO - (maj ? R * 0.030 : R * 0.016);
                    c.strokeStyle = "rgba(127,216,255," + al.toFixed(3) + ")";
                    c.beginPath();
                    c.moveTo(cx + Math.cos(ta) * rO, cy + Math.sin(ta) * rO);
                    c.lineTo(cx + Math.cos(ta) * r1, cy + Math.sin(ta) * r1);
                    c.stroke();
                }

                // 0° index hairline: one bright tick across the whole telemetry
                // band so the four rings read as a single instrument with a
                // defined origin rather than four unrelated gauges.
                c.lineWidth = 1;
                c.strokeStyle = "rgba(190,220,245,0.26)";
                c.beginPath();
                c.moveTo(cx + Math.cos(-Math.PI * 0.75) * R * 0.44, cy + Math.sin(-Math.PI * 0.75) * R * 0.44);
                c.lineTo(cx + Math.cos(-Math.PI * 0.75) * R * 0.90, cy + Math.sin(-Math.PI * 0.75) * R * 0.90);
                c.stroke();

                // frosted core disc (mock .glasdisc, inset ≈15.5%)
                var gR = R * 0.71;
                c.beginPath();
                c.arc(cx, cy, gR, 0, Math.PI * 2);
                c.fillStyle = "rgba(13,16,19,0.90)";
                c.fill();
                var gG = c.createRadialGradient(cx, cy - gR * 0.24, gR * 0.06, cx, cy, gR);
                gG.addColorStop(0, "rgba(148,170,188,0.10)");
                gG.addColorStop(0.75, "rgba(10,12,15,0.55)");
                gG.addColorStop(1, "rgba(10,12,15,0.62)");
                c.beginPath();
                c.arc(cx, cy, gR, 0, Math.PI * 2);
                c.fillStyle = gG;
                c.fill();
                c.lineWidth = 1;
                c.strokeStyle = "rgba(190,220,245,0.16)";
                c.beginPath();
                c.arc(cx, cy, gR - 0.5, 0, Math.PI * 2);
                c.stroke();
                c.lineWidth = Math.max(1, gR * 0.008);
                c.strokeStyle = "rgba(235,245,252,0.22)";
                c.beginPath();
                c.arc(cx, cy, gR - 2, -Math.PI * 0.80, -Math.PI * 0.20);
                c.stroke();
                c.lineWidth = Math.max(2, gR * 0.08);
                c.strokeStyle = "rgba(0,0,0,0.45)";
                c.beginPath();
                c.arc(cx, cy, gR - gR * 0.045, Math.PI * 0.25, Math.PI * 0.75);
                c.stroke();

                // centre legibility fade under the face text (v3 fix)
                var gI = c.createRadialGradient(cx, cy, R * 0.10, cx, cy, R * 0.46);
                gI.addColorStop(0, "rgba(2,9,15,0.72)");
                gI.addColorStop(0.8, "rgba(2,9,15,0.55)");
                gI.addColorStop(1, "rgba(2,9,15,0.0)");
                c.fillStyle = gI;
                c.beginPath();
                c.arc(cx, cy, R * 0.46, 0, Math.PI * 2);
                c.fill();
            }
        }

        // static dial layer: ring tracks, tags, identity band. Painted on
        // geometry / plate-text change only (the per-glyph arc text is the
        // expensive part and used to repaint with every ring update).
        Canvas {
            id: dialArcs
            anchors.fill: parent
            readonly property string plate: root.screenName + (root.kernelText !== "" ? " · " + root.kernelText : "")
            onPlateChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            function monoFam() {
                return (typeof Theme !== "undefined" && Theme.monoChain) ? Theme.monoChain() : "monospace";
            }
            function dispFam() {
                return (typeof Theme !== "undefined" && Theme.displayFamily !== undefined) ? Theme.displayFamily + ", sans-serif" : "sans-serif";
            }
            function ink(c, a) {
                return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")";
            }
            // Per-glyph arc text on the open band between the telemetry rings
            // and the corona notches (lane B3). `segs` = [{t,col}] run-on
            // segments so a glyph can switch colour mid-string; top=true walks
            // left→right across the top with glyph tops outward, top=false
            // lays the string upright along the bottom arc.
            function arcText(c, segs, cx, cy, r, a0, top, trackPx) {
                var chars = [];
                for (var s = 0; s < segs.length; s++)
                    for (var k = 0; k < segs[s].t.length; k++)
                        chars.push({
                            "ch": segs[s].t.charAt(k),
                            "col": segs[s].col
                        });
                var n = chars.length;
                if (n === 0 || r < 20)
                    return;
                var ws = [], tw = 0;
                for (var i = 0; i < n; i++) {
                    var w = c.measureText(chars[i].ch).width;
                    ws.push(w);
                    tw += w;
                }
                tw += trackPx * Math.max(0, n - 1);
                var dir = top ? 1 : -1;
                var th = top ? a0 - tw / r / 2 : a0 + tw / r / 2;
                c.textAlign = "center";
                c.textBaseline = "middle";
                for (i = 0; i < n; i++) {
                    var g = ws[i] / r;
                    var mid = th + dir * g / 2;
                    c.save();
                    c.translate(cx + Math.cos(mid) * r, cy + Math.sin(mid) * r);
                    c.rotate(mid + (top ? Math.PI / 2 : -Math.PI / 2));
                    c.fillStyle = chars[i].col;
                    c.fillText(chars[i].ch, 0, 0);
                    c.restore();
                    th += dir * (g + trackPx / r);
                }
            }
            onPaint: {
                var c = getContext("2d");
                c.clearRect(0, 0, width, height);
                var W = width, H = height;
                var cx = W / 2, cy = H / 2;
                var R = Math.min(W, H) * 0.5 - 2;
                if (R < 36)
                    return;
                var A0 = -Math.PI * 0.75, SW = Math.PI * 1.5;
                var ringW = Math.max(3, R * 0.027);
                var radii = [R * 0.885, R * 0.75, R * 0.615, R * 0.48];
                var tags = ["CPU", "GPU", "MEM", "NET"];
                c.font = "500 " + Math.max(7, Math.round(R * 0.04)) + "px " + monoFam();
                c.textAlign = "center";
                c.textBaseline = "middle";
                for (var g = 0; g < 4; g++) {
                    var rr = radii[g];
                    c.beginPath();
                    c.strokeStyle = "rgba(96,165,250,0.12)";
                    c.lineWidth = ringW;
                    c.arc(cx, cy, rr, A0, A0 + SW);
                    c.stroke();
                    // Tag rides its own ring in the sweep gap, rotated to the
                    // tangent. Right-aligned at the sweep start they used to
                    // stack diagonally down-right and the NET tag landed on top
                    // of the face readout.
                    var tA = A0 - 0.055;
                    var tR = rr - ringW * 0.5 - Math.max(5, R * 0.020);
                    c.save();
                    c.translate(cx + Math.cos(tA) * tR, cy + Math.sin(tA) * tR);
                    c.rotate(tA + Math.PI / 2);
                    c.fillStyle = "rgba(190,220,245,0.60)";
                    c.fillText(tags[g], 0, 0);
                    c.restore();
                }
                // identity band (lane B3): the dial wears the machine's own
                // roll-mark — NEXUSLINK · YURI across the top, the screen +
                // kernel plate along the bottom. Painted on the telemetry
                // pass (refreshes with each stats frame), zero idle cost.
                var rT = R * 0.935;
                c.font = "500 " + Math.max(8, Math.round(R * 0.034)) + "px " + dispFam();
                arcText(c, [{
                            "t": "NEXUSLINK",
                            "col": "rgba(190,220,245,0.50)"
                        }, {
                            "t": " · ",
                            "col": "rgba(190,220,245,0.28)"
                        }, {
                            "t": "YURI",
                            "col": ink(Style.c.accent, 0.92)
                        }], cx, cy, rT, -Math.PI / 2, true, Math.max(1.2, R * 0.009));
                var plate = root.screenName + (root.kernelText !== "" ? " · " + root.kernelText : "");
                c.font = "500 " + Math.max(7, Math.round(R * 0.027)) + "px " + monoFam();
                arcText(c, [{
                            "t": plate,
                            "col": "rgba(143,216,232,0.42)"
                        }], cx, cy, rT, Math.PI / 2, false, Math.max(1, R * 0.007));
            }
        }

        // live ring fills + segment notches: the only dial layer that repaints
        // on data, and only when a ring moves by >= 1 % (values are quantized
        // at assignment, no Behavior frames).
        Canvas {
            id: dialFill
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Component.onCompleted: requestPaint()
            onPaint: {
                var c = getContext("2d");
                c.clearRect(0, 0, width, height);
                var W = width, H = height;
                var cx = W / 2, cy = H / 2;
                var R = Math.min(W, H) * 0.5 - 2;
                if (R < 36)
                    return;
                var A0 = -Math.PI * 0.75, SW = Math.PI * 1.5;
                var ringW = Math.max(3, R * 0.027);
                var radii = [R * 0.885, R * 0.75, R * 0.615, R * 0.48];
                var fracs = [root.aCpu, root.aGpu, root.aMem, root.aNet];
                var cols = ["#8fd8e8", "#60a5fa", "#c8f31d", "#8affd0"];
                c.lineCap = "round";
                for (var g = 0; g < 4; g++) {
                    var rr = radii[g];
                    var f = fracs[g];
                    if (f >= 0) {
                        var ae = A0 + SW * Math.min(1, f);
                        c.beginPath();
                        c.strokeStyle = cols[g];
                        c.globalAlpha = 0.14;
                        c.lineWidth = ringW * 1.5;
                        c.arc(cx, cy, rr, A0, ae);
                        c.stroke();
                        c.globalAlpha = 1;
                        c.beginPath();
                        c.strokeStyle = cols[g];
                        c.lineWidth = ringW;
                        c.arc(cx, cy, rr, A0, ae);
                        c.stroke();
                        c.fillStyle = cols[g];
                        c.beginPath();
                        c.arc(cx + Math.cos(ae) * rr, cy + Math.sin(ae) * rr, Math.max(1.4, ringW * 0.7), 0, Math.PI * 2);
                        c.fill();
                    }
                }
                // 18 segment notches punch through each ring band
                c.strokeStyle = "rgba(6,8,10,0.9)";
                c.lineWidth = Math.max(1.1, R * 0.006);
                for (g = 0; g < 4; g++) {
                    var rr2 = radii[g], half = ringW * 0.8;
                    c.beginPath();
                    for (var d = 0; d < 18; d++) {
                        var da = A0 + SW * d / 18;
                        c.moveTo(cx + Math.cos(da) * (rr2 - half), cy + Math.sin(da) * (rr2 - half));
                        c.lineTo(cx + Math.cos(da) * (rr2 + half), cy + Math.sin(da) * (rr2 + half));
                    }
                    c.stroke();
                }

            }
        }

        // dial face — restructured as the machine's own presence (lane B3):
        // persona nameplate, hero numeral, identity subtitle, status glyphs,
        // then the telemetry column. Centre/circle invariants unchanged.
        // The Column carries an explicit width (0.56 × the dial) and every line
        // elides: implicitWidth let a long hostname or a full R/W row push past
        // the frosted core disc's chord at the top and bottom of the stack.
        Column {
            id: faceCol
            anchors.centerIn: parent
            width: Math.round(reactor.width * 0.56)
            spacing: 0
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: "Y U R I"
                color: Style.c.dim
                font.family: Style.f.display
                font.pixelSize: Math.max(10, Math.round(reactor.width * 0.017))
                font.letterSpacing: Math.max(4, reactor.width * 0.010)
            }
            Item {
                width: 1
                height: Math.round(reactor.height * 0.045)   // mock .hero margin-top
            }
            Item {
                width: parent.width
                height: heroNum.implicitHeight
                // restrained bloom behind the hero numeral (mock .hero
                // text-shadow): a 2 px larger ice ghost sharing the numeral's
                // own box, so the two can never drift apart.
                Row {
                    anchors.centerIn: parent
                    spacing: 4
                    Item {
                        id: heroBox
                        width: heroNum.implicitWidth
                        height: heroNum.implicitHeight
                        Text {
                            anchors.centerIn: parent
                            text: heroNum.text
                            color: Style.tone(Style.c.accent2, 0.12)
                            font.family: Style.f.display
                            font.pixelSize: heroNum.font.pixelSize + 2
                        }
                        Text {
                            id: heroNum
                            anchors.fill: parent
                            text: root.cpuPct >= 0 ? Math.round(root.cpuPct) : Style.unknownGlyph
                            color: root.alert ? Style.c.alert : Style.c.txt
                            font.family: Style.f.display
                            font.pixelSize: Math.round(reactor.width * 0.137)
                            // mock .hero line-height:.86 — Michroma's default box
                            // is ~1.44em, which left a 100 px hole between the
                            // roll label and the numeral
                            lineHeight: 0.86
                        }
                    }
                    Text {
                        anchors.bottom: heroBox.bottom
                        anchors.bottomMargin: Math.round(reactor.width * 0.018)
                        // a unit on a value that does not exist would be a lie
                        visible: root.cpuPct >= 0
                        text: "%"
                        color: Style.c.accent2
                        font.family: Style.f.display
                        font.pixelSize: Math.round(reactor.width * 0.058)
                    }
                }
            }
            // identity subtitle: hostname · presence state · uptime — uptime
            // identity band: hostname · presence state. Uptime and the wall
            // clock stay together on their own row further down — printing
            // uptime in both places was the one duplicated fact on the face.
            // Marks are drawn from glyphs Kode Mono actually carries (U+25CA
            // lozenge, U+2022 bullet). The geometric set it lacks — U+25CF
            // disc, U+25C6 diamond, U+25B2 triangle — was silently falling back
            // to a second face mid-line, which is what made this row look
            // pasted together.
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                textFormat: Text.RichText
                text: "<font color='" + root.cssHex(root.stateCol) + "'>◊</font> <b>" + root.esc(root.hostText) + "</b> · <font color='" + root.cssHex(root.stateCol) + "'><b>" + root.yuriState + "</b></font>"
                color: Style.c.dim
                font.family: Style.f.mono
                font.pixelSize: Math.max(10, Math.round(reactor.width * 0.017))
                font.letterSpacing: 1.1
            }
            // status glyph row: link heartbeat · live devin sessions · thermal
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                textFormat: Text.RichText
                text: "<font color='" + root.cssHex(root.linkOk ? Style.c.accent2 : Style.c.alert) + "'>•</font> LINK   <font color='" + root.cssHex(root.liveSess > 0 ? Style.c.accent : Style.c.faint) + "'>•</font> " + root.liveSess + " SESS   <font color='" + root.cssHex(root.alert ? Style.c.alert : Style.c.faint) + "'>•</font> " + (root.alert ? Math.round(root.maxTemp) + "°" : "NOMINAL")
                color: Style.c.faint
                font.family: Style.f.mono
                font.pixelSize: Math.max(9, Math.round(reactor.width * 0.0145))
                font.letterSpacing: 1.2
            }
            Item {
                width: 1
                height: Math.round(reactor.height * 0.034)   // mock .rows margin-top
            }
            Column {
                width: parent.width
                spacing: Math.max(3, Math.round(reactor.height * 0.007))
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    textFormat: Text.RichText
                    text: "L <b>" + root.esc(root.loadText) + "</b>" + (root.coreCount > 0 ? " / " + root.coreCount : "")
                    color: Style.c.dim
                    font.family: Style.f.mono
                    font.pixelSize: Math.max(10, Math.round(reactor.width * 0.019))
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    textFormat: Text.RichText
                    text: "MEM <b>" + root.esc(root.memGiB) + "</b> / " + root.esc(root.memTotGiB) + "G" + (root.has("zram_ratio") ? " <font color='" + root.cssHex(Style.c.accent2) + "'>· zram " + Number(root.stats.zram_ratio) + "×</font>" : "")
                    color: Style.c.dim
                    font.family: Style.f.mono
                    font.pixelSize: Math.max(10, Math.round(reactor.width * 0.019))
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    textFormat: Text.RichText
                    text: "R <font color='" + root.cssHex(Style.c.accent2) + "'><b>" + root.esc(root.fmtRate(root.rxRate)) + "</b></font> · W <font color='" + root.cssHex(Style.c.accent2) + "'><b>" + root.esc(root.fmtRate(root.txRate)) + "</b></font>"
                    color: Style.c.dim
                    font.family: Style.f.mono
                    font.pixelSize: Math.max(10, Math.round(reactor.width * 0.019))
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: "up " + root.uptimeText
                    color: Style.c.faint
                    font.family: Style.f.mono
                    font.pixelSize: Math.max(10, Math.round(reactor.width * 0.019))
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    visible: root.alert
                    text: "ALERT " + Math.round(root.maxTemp) + "°"
                    color: Style.c.alert
                    font.family: Style.f.mono
                    font.pixelSize: Math.max(10, Math.round(reactor.width * 0.019))
                }
            }
            Item {
                width: 1
                height: Math.round(reactor.height * 0.018)   // mock .say margin-top
            }
            // say() chip — agent voice flash on the lower face
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.sayFlash && root.sayText !== ""
                width: Math.min(faceCol.width, sayT.implicitWidth + Math.round(reactor.width * 0.04))
                height: sayT.implicitHeight + Math.round(reactor.width * 0.012)
                radius: height / 2
                color: Qt.rgba(0.01, 0.03, 0.05, 0.82)
                border.width: 1
                border.color: Style.tone(Style.c.accent, 0.55)
                Text {
                    id: sayT
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 8)
                    elide: Text.ElideRight
                    text: root.sayText
                    color: Style.c.accent
                    font.family: Style.f.mono
                    font.pixelSize: Math.max(10, Math.round(reactor.width * 0.016))
                }
            }
        }
    }

    // ai center key — a compact nav affordance parked under the dial, not a
    // grid tile (the flanks are full). Same EmbossedTile chrome as the hub
    // tiles; click opens Navigator's files section at the AI center dir
    // (openNav's path arg → openSection("files", dir)).
    // ---- side strips: launchers (left) and quick system actions (right) ----
    // Fill the void between the tile flanks and the dial with affordances
    // only; hidden when the gutter is too narrow to hold them.
    readonly property bool stripRoom: (root.width - root.dialSize) / 2 - (root.padX + root.colW) >= 120
    Column {
        id: leftStrip
        visible: root.stripRoom
        x: root.padX + root.colW + 28
        anchors.verticalCenter: reactor.verticalCenter
        spacing: 14
        StripKey { glyph: Style.ico.robot; label: "HERMES"; spec: ({ "argv": ["omarchy-launch-tui", "--app-id=org.nexus.hermes", "hermes"] }) }
        StripKey { glyph: Style.ico.term; label: "TERM"; spec: ({ "argv": ["omarchy-launch-terminal"] }) }
        StripKey { glyph: Style.ico.folder; label: "AI CENTER"; spec: ({ "argv": ["uwsm-app", "--", "nautilus", "--new-window", root.aiCenterDir !== "" ? root.aiCenterDir : root.homeDir + "/NEXUS_AI_CENTER"] }) }
        StripKey { glyph: Style.ico.search; label: "NAV"; spec: ({ "nav": "files" }) }
    }
    Column {
        id: rightStrip
        visible: root.stripRoom
        x: root.width - root.padX - root.colW - 28 - width
        anchors.verticalCenter: reactor.verticalCenter
        spacing: 14
        StripKey { glyph: Style.ico.shot; label: "SHOT"; spec: ({ "argv": ["omarchy-capture-screenshot"] }) }
        StripKey { glyph: Style.ico.pick; label: "PICK"; spec: ({ "argv": ["hyprpicker", "-a"] }) }
        StripKey { glyph: Style.ico.palette; label: "BG"; spec: ({ "argv": ["omarchy-theme-bg-next"] }) }
        StripKey { glyph: Style.ico.menu; label: "MENU"; spec: ({ "argv": ["omarchy-menu"] }) }
    }

    EmbossedTile {
        id: aiKey
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: reactor.bottom
        anchors.topMargin: 16
        padding: 10
        title: "AI CENTER"
        keyCap: "NAV"
        insight: root.aiCenterCount >= 0
                 ? root.b(String(root.aiCenterCount)) + " entries · " + root.i2(root.esc(root.aiCenterShort))
                 : Style.unknownGlyph
        onClicked: root.openNav("files", root.aiCenterDir !== "" ? root.aiCenterDir : "~/NEXUS_AI_CENTER")
    }

    // chassis tag — bottom of the mock's .corebox. Same slot under the reactor
    // and the same type treatment; the text now carries this panel's own
    // structural identity instead of narrating the renderer's own styling
    // (a caption reading "FROSTED CORE DISC" is a design note, not telemetry).
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: dockStrip.top
        anchors.bottomMargin: 8
        text: root.screenName + " · " + Math.round(root.width) + "×" + Math.round(root.height) + " · " + (root.leftTiles.length + root.rightTiles.length) + " TILES · " + dockStrip.activeCellDefs.length + " CHANNELS"
        color: Style.c.faint
        font.family: Style.f.mono
        font.pixelSize: Style.f.pxTag
        font.letterSpacing: 2.9
    }

    // =============================================================== dock ------
    UtilityDock {
        id: dockStrip
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.padX
        anchors.rightMargin: root.padX
        anchors.bottomMargin: root.padBot
        stats: root.stats
    }

    // static scanline sheet over the whole field (mock .scan) — painted once.
    ScanOverlay {
        anchors.fill: parent
        pitch: 3
    }
}
