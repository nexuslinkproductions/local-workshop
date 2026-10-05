pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// UtilityDock.qml — shared bottom utility strip (lane D1).
// Imported by CommandHub (DP-1) and Workbench (HDMI-A-3). Seventeen glass
// cells per candidates/mock2/B/dp1.html .util/.uchip: each cell is a label,
// one live value line, an optional sub line or meter bar, and a click that
// fires a real Omarchy action.
//
// `compact: true` (Workbench/HDMI-A-3, lane G2) renders only the curated
// compactIds set — MEDIA expanded with an album-art MediaCell, then VOLUME,
// MIC, NOTIFICATIONS, WEATHER, WORKSPACES, POWER, THEME — weighted wider so
// the strip breathes, and each hidden cell's poller is gated off entirely.
//
// Data plan (recon/integrations-desktop.json): collector stats keys are used
// where they exist (weather, pkg_updates, ws/win counts, fs_root, theme_name).
// Everything else polls the item's scouted read_cmd at its scouted poll_s —
// each poll is a bounded argv vector or a fixed literal bash script (no
// interpolated/untrusted input), executed by a dormant Process. Actions are
// Quickshell.execDetached argv vectors through the same `exec "$@"` login
// wrapper Navigator.qml uses, so /usr/share/omarchy/bin resolves.
//
// No animation clocks: pollers are data fetches only; repaint happens when a
// poll lands or a stats frame arrives.

GlassPane {
    id: dock

    // ---- injected by host --------------------------------------------------
    property var stats: ({})

    // ---- profile -----------------------------------------------------------
    // "full" (default) = all 17 cells, unchanged DP-1 CommandHub dock.
    // "compact" (HDMI-A-3 Workbench) = curated subset below — media cell is
    // weighted wider and carries a MediaCell album-art thumb.
    property bool compact: false
    readonly property var compactIds: ["media", "vol", "mic", "notif",
                                       "wthr", "ws", "pwr", "theme"]

    // ---- geometry ----------------------------------------------------------
    property int cellH: 92             // mock .util inner band ≈94 px
    // mock .util gap:10 — every cell keeps 5 px of chrome on each side so the
    // gutters are all 10 px. The first cell used to take 0 on its left, which
    // made gap 0→1 half the width of every other gap in the strip.
    readonly property int chipGap: 5
    padding: 12
    radius: Style.r.pane
    holo: true

    readonly property string homeDir: Quickshell.env("HOME")
    readonly property string ung: Style.unknownGlyph

    // ---- helpers -----------------------------------------------------------
    function has(k) {
        return stats[k] !== undefined && stats[k] !== "";
    }
    function num(v) {
        var n = Number(v);
        return isFinite(n) ? n : 0;
    }
    function trunc(s, n) {
        s = String(s || "");
        return s.length > n ? s.substring(0, Math.max(1, n - 1)) + "…" : s;
    }
    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function fmtBytes(b) {
        var n = num(b);
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

    // Fire-and-forget action: argv through a login shell `exec "$@"` so the
    // omarchy-* scripts under /usr/share/omarchy/bin resolve — the same
    // indirection Navigator.qml uses. No shell string concatenation.
    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "dock"].concat(argv));
    }

    // ---- cell registry -----------------------------------------------------
    // Order matches the mock's left→right strip; bluetooth slots next to the
    // other radio/audio chips as the 17th integration.
    readonly property var cellDefs: [
        {
            id: "media",
            label: "MEDIA / MPRIS"
        },
        {
            id: "notif",
            label: "NOTIFICATIONS"
        },
        {
            id: "vol",
            label: "VOLUME"
        },
        {
            id: "mic",
            label: "MIC"
        },
        {
            id: "bt",
            label: "BLUETOOTH"
        },
        {
            id: "clip",
            label: "CLIPBOARD"
        },
        {
            id: "cap",
            label: "CAPTURE"
        },
        {
            id: "idle",
            label: "IDLE INHIBIT"
        },
        {
            id: "wthr",
            label: "WEATHER"
        },
        {
            id: "rem",
            label: "TIMERS"
        },
        {
            id: "upd",
            label: "UPDATES"
        },
        {
            id: "ws",
            label: "WORKSPACES"
        },
        {
            id: "night",
            label: "NIGHT LIGHT"
        },
        {
            id: "pwr",
            label: "POWER"
        },
        {
            id: "disk",
            label: "DISK"
        },
        {
            id: "dl",
            label: "DOWNLOADS"
        },
        {
            id: "theme",
            label: "THEME"
        }
    ]

    // Cells actually rendered: the full registry in "full" profile, or the
    // curated compactIds subset (in that order) in "compact" profile.
    // cellDefs itself stays untouched — CommandHub's strip is unaffected.
    readonly property var activeCellDefs: {
        if (!compact)
            return cellDefs;
        var out = [];
        for (var i = 0; i < compactIds.length; i++)
            for (var j = 0; j < cellDefs.length; j++)
                if (cellDefs[j].id === compactIds[i]) {
                    out.push(cellDefs[j]);
                    break;
                }
        return out;
    }

    // Whether a cell id is in the rendered set — also gates that cell's poller
    // so a slim dock doesn't spawn fetches for chips that aren't shown.
    function cellActive(id) {
        return !compact || compactIds.indexOf(id) >= 0;
    }

    // Per-cell width weight — compact's media cell is expanded so the album
    // thumb + track text breathe; everything else is an equal share.
    function cellWeight(id) {
        return compact && id === "media" ? 1.7 : 1.0;
    }
    readonly property real totalWeight: {
        var s = 0;
        for (var i = 0; i < activeCellDefs.length; i++)
            s += cellWeight(activeCellDefs[i].id);
        return Math.max(1, s);
    }
    // Integer cell boundaries. 2466 px split 17 ways is 145.06 px per cell, and
    // the fractional pitch smeared every chip edge and every 1 px hairline
    // across two device pixels. Accumulating the exact weighted offsets and
    // rounding each cumulative boundary keeps every edge on a whole pixel, the
    // strip exactly as wide as the pane, and no cell more than 1 px off its
    // neighbours — dumping the whole remainder on the last cell left the THEME
    // chip 7 px wider than POWER in the compact profile.
    readonly property var _cellEdges: {
        var n = activeCellDefs.length;
        var W = Math.round(strip.width);
        if (n === 0 || W <= 0)
            return [0, W];
        var out = [0];
        var acc = 0;
        for (var i = 0; i < n; i++) {
            var exact = W * cellWeight(activeCellDefs[i].id) / totalWeight;
            out.push(i === n - 1 ? W : Math.round(acc + exact));
            acc += exact;
        }
        return out;
    }
    function cellX(i) {
        return _cellEdges[Math.max(0, Math.min(_cellEdges.length - 1, i))];
    }
    function cellW(i) {
        var k = Math.max(0, Math.min(_cellEdges.length - 2, i));
        return _cellEdges[k + 1] - _cellEdges[k];
    }

    // ---- polled cell state --------------------------------------------------
    property var media: ({})            // omarchy-shell media status JSON
    // mpris:artUrl already rides in the mediaPoll JSON (verified live:
    // `omarchy-shell media status` emits artUrl) — no extra fetch needed.
    // MediaCell's Image re-decodes only when this string changes.
    readonly property string mediaArtUrl: (typeof media.artUrl === "string") ? String(media.artUrl) : ""
    property int notifCount: -1
    property string notifDnd: ""
    property string notifNewest: ""
    property real volFrac: -1
    property bool volMuted: false
    property real micFrac: -1
    property bool micMuted: false
    property bool btSeen: false
    property bool btPowered: false
    property int btConn: -1
    property int clipCount: -1
    property string clipNewest: ""
    property int capCount: -1
    property string capNewest: ""
    property var idle: ({})
    property var rem: ({})
    property string nightEnabled: ""    // "on" | "off" | "" (unknown)
    property int nightTemp: -1
    property string powerProfile: ""
    property int dlCount: -1
    property string dlNewest: ""

    // ---------- cell content -------------------------------------------------
    // A 17-cell strip leaves ~135 px of usable width per chip at 12 px Kode
    // Mono (≈8.9 px/char), so every value line below is held to ≤14 characters
    // and every sub line to ≤19. Anything longer was silently elided, which
    // read as truncated data rather than as a design.
    function cellValue(id) {
        switch (id) {
        case "media":
            // ASCII transport marks: Kode Mono carries no geometric triangles,
            // so U+25B6 / U+275A were pulling glyphs out of a fallback face and
            // rendering off-baseline inside an otherwise monospaced cell.
            if (media.playing === true)
                return "> " + esc(trunc(media.title || "playing", 11));
            if (media.hasPlayer === true)
                return "|| " + esc(trunc(media.title || "paused", 11));
            if (media.hasPlayer === false)
                return ung + " none";
            return ung;
        case "notif":
            if (notifCount < 0)
                return ung;
            return b(String(notifCount)) + " · DND " + (notifDnd === "on" ? "<font color='" + cssHex(Style.c.warn) + "'>on</font>" : "off");
        case "vol":
            if (volFrac < 0)
                return ung;
            return (volMuted ? "<font color='" + cssHex(Style.c.warn) + "'>MUTE</font> " : "") + b(Math.round(volFrac * 100) + "%");
        case "mic":
            if (micFrac < 0)
                return ung;
            return micMuted ? "<font color='" + cssHex(Style.c.alert) + "'>MUTED</font>" : i2("LIVE") + " " + Math.round(micFrac * 100) + "%";
        case "bt":
            if (!btSeen)
                return ung;
            return btPowered ? b(btConn >= 0 ? String(btConn) : ung) + " conn" : "off";
        case "clip":
            return clipCount >= 0 ? b(String(clipCount)) + " entries" : ung;
        case "cap":
            return capCount >= 0 ? (capNewest !== "" ? esc(trunc(capNewest, 12)) : "none yet") : ung;
        case "idle":
            if (idle.stayAwake === undefined)
                return ung;
            return idle.stayAwake === true ? b("AWAKE") : "auto";
        case "wthr":
            return wthrShort();
        case "rem":
            if (rem.count === undefined)
                return ung;
            return b(String(num(rem.count))) + " active";
        case "upd":
            return has("pkg_updates") ? b(String(num(stats.pkg_updates))) + " pending" : ung;
        case "ws":
            return has("ws_count") ? b(String(num(stats.ws_count))) + " ws · " + (has("win_count") ? num(stats.win_count) : ung) + " win" : ung;
        case "night":
            return nightEnabled === "" ? ung : nightEnabled;
        case "pwr":
            return powerProfile !== "" ? i2(powerProfile) : ung;
        case "disk":
            if (!has("fs_root_pct"))
                return ung;
            var out = Math.round(num(stats.fs_root_pct)) + "%";
            // free space needs BOTH halves — no -0/-N fabrication on a lone key.
            if (has("fs_root_size") && has("fs_root_used"))
                out += " · " + fmtBytes(num(stats.fs_root_size) - num(stats.fs_root_used));
            return out;
        case "dl":
            if (dlCount < 0)
                return ung;
            return dlNewest !== "" ? esc(trunc(dlNewest, 12)) : "empty";
        case "theme":
            return has("theme_name") ? esc(trunc(stats.theme_name, 12)) : ung;
        }
        return ung;
    }

    function cellSub(id) {
        switch (id) {
        case "media":
            return media.hasPlayer === true ? esc(trunc(media.artist || "unknown artist", 19)) : "tap → play/pause";
        case "notif":
            return notifNewest !== "" ? "new: " + trunc(notifNewest, 14) : "toggle DND";
        case "vol":
            return volMuted ? "sink muted" : "tap → mute";
        case "mic":
            return "tap → mute";
        case "bt":
            return btPowered ? "hci0 · panel" : "tap → panel";
        case "clip":
            return clipNewest !== "" ? "new: " + trunc(clipNewest, 14) : "tap → history";
        case "cap":
            return "screenshot →";
        case "idle":
            return idle.screensaver !== undefined ? "screen " + num(idle.screensaver) + "s" : "toggle idle";
        case "wthr":
            return wthrCity();
        case "rem":
            return "reminders →";
        case "upd":
            return "tap → refresh";
        case "ws":
            return wsIdLine();
        case "night":
            return nightTemp > 0 ? num(nightTemp) + "K" : "hyprsunset";
        case "pwr":
            return "tap → toggle";
        case "disk":
            return has("fs_root_target") ? trunc(String(stats.fs_root_target), 19) : "/";
        case "dl":
            return dlCount > 1 ? "+" + (dlCount - 1) + " more" : "Downloads";
        case "theme":
            return "tap → next bg";
        }
        return "";
    }

    // -1 hides the meter; 0..1 fills it.
    function cellBar(id) {
        if (id === "vol")
            return volFrac;
        if (id === "mic")
            return micFrac;
        if (id === "disk")
            return has("fs_root_pct") ? Math.min(1, num(stats.fs_root_pct) / 100) : -1;
        return -1;
    }

    function cellHot(id) {
        switch (id) {
        case "media":
            return media.playing === true;
        case "notif":
            return notifDnd === "on";
        case "vol":
            return volMuted;
        case "mic":
            return micFrac >= 0 && micMuted;
        case "bt":
            return btPowered && btConn > 0;
        case "idle":
            return idle.stayAwake === true;
        case "night":
            return nightEnabled === "on";
        case "upd":
            return has("pkg_updates") && num(stats.pkg_updates) > 0;
        }
        return false;
    }

    // Status dot tri-state: 0 unknown · 1 nominal · 2 attention · 3 active.
    // `cellHot` wins outright so the dot can never contradict the value line,
    // and every "unknown" answer is driven off the same keys cellValue reads —
    // a cell with no data gets a grey dot, never an optimistic ice one.
    function cellState(id) {
        if (cellHot(id))
            return 3;
        switch (id) {
        case "media":
            return media.hasPlayer === true ? 1 : 0;
        case "notif":
            return notifCount < 0 ? 0 : 1;
        case "vol":
            return volFrac < 0 ? 0 : 1;
        case "mic":
            return micFrac < 0 ? 0 : 1;
        case "bt":
            return !btSeen ? 0 : (btPowered ? 1 : 2);
        case "clip":
            return clipCount < 0 ? 0 : 1;
        case "cap":
            return capCount < 0 ? 0 : 1;
        case "idle":
            return idle.stayAwake === undefined ? 0 : 1;
        case "wthr":
            return has("weather") ? 1 : 0;
        case "rem":
            return rem.count === undefined ? 0 : 1;
        case "upd":
            return has("pkg_updates") ? 1 : 0;
        case "ws":
            return has("ws_count") ? 1 : 0;
        case "night":
            return nightEnabled === "" ? 0 : 1;
        case "pwr":
            return powerProfile !== "" ? 1 : 0;
        case "disk":
            return has("fs_root_pct") ? (num(stats.fs_root_pct) >= 85 ? 2 : 1) : 0;
        case "dl":
            return dlCount < 0 ? 0 : 1;
        case "theme":
            return has("theme_name") ? 1 : 0;
        }
        return 0;
    }

    function cellDotColor(id) {
        var s = cellState(id);
        if (s === 3)
            return Style.c.accent;
        if (s === 2)
            return Style.c.warn;
        return s === 1 ? Style.tone(Style.c.accent2, 0.6) : Style.c.unknown;
    }

    function wthrShort() {
        if (!has("weather"))
            return ung;
        var s = String(stats.weather);
        var t = s.match(/Temp\s+([^·]+)/);
        var w = s.match(/Wind\s+([^·]+)/);
        var out = "";
        if (t)
            out += "<b>" + esc(t[1].trim()) + "</b>";
        if (w)
            out += (out !== "" ? " " : "") + esc(w[1].trim());
        return out !== "" ? out : esc(trunc(s, 18));
    }
    function wthrCity() {
        if (!has("weather"))
            return "weather →";
        var s = String(stats.weather);
        var idx = s.indexOf("·");
        return trunc((idx > 0 ? s.substring(0, idx) : s).trim(), 19);
    }
    // Three ids plus an overflow count: the full list ran to 25 characters and
    // always elided in a 145 px cell.
    function wsIdLine() {
        var n = Math.min(8, num(stats.ws_count));
        var ids = [];
        for (var i = 0; i < n; i++)
            if (has("ws" + i + "_id"))
                ids.push(String(num(stats["ws" + i + "_id"])));
        if (ids.length === 0)
            return "exposé →";
        var head = ids.slice(0, 3).join(" · ");
        return ids.length > 3 ? head + " +" + (ids.length - 3) : head;
    }

    // ---------- actions ------------------------------------------------------
    function activate(id) {
        switch (id) {
        case "media":
            execArgv(["omarchy-shell", "-q", "media", "playPause"]);
            mediaPoll.refreshSoon();
            break;
        case "notif":
            execArgv(["omarchy-shell", "-q", "notifications", "toggleDnd"]);
            notifPoll.refreshSoon();
            break;
        case "vol":
            execArgv(["omarchy-audio-output-volume", "mute-toggle"]);
            volPoll.refreshSoon();
            break;
        case "mic":
            execArgv(["omarchy-audio-input-mute"]);
            micPoll.refreshSoon();
            break;
        case "bt":
            execArgv(["omarchy-shell", "-q", "omarchy.bluetooth", "toggle"]);
            btPoll.refreshSoon();
            break;
        case "clip":
            execArgv(["omarchy-shell", "-q", "shell", "call", "omarchy.clipboard", "toggle", "{}"]);
            break;
        case "cap":
            execArgv(["omarchy-capture-screenshot"]);
            capPoll.refreshSoon(2400);
            break;
        case "idle":
            execArgv(["omarchy-toggle-idle"]);
            idlePoll.refreshSoon();
            break;
        case "wthr":
            execArgv(["omarchy-shell", "-q", "omarchy.weather", "toggle"]);
            break;
        case "rem":
            execArgv(["omarchy-shell", "-q", "shell", "call", "omarchy.reminders", "toggle", "{}"]);
            remPoll.refreshSoon();
            break;
        case "upd":
            execArgv(["omarchy-shell", "-q", "omarchy.system-update", "refresh"]);
            break;
        case "ws":
            execArgv(["qs", "ipc", "-p", "/usr/share/omarchy/shell", "-t", "expose", "call", "toggle", ""]);
            break;
        case "night":
            execArgv(["omarchy-shell", "-q", "nightlight", "toggle"]);
            nightPoll.refreshSoon();
            break;
        case "pwr":
            execArgv(["omarchy-powerprofiles-set", "autodetect", powerProfile === "performance" ? "power-saver" : "performance"]);
            pwrPoll.refreshSoon(1600);
            break;
        case "disk":
            execArgv(["omarchy-launch-nautilus"]);
            break;
        case "dl":
            // omarchy-launch-nautilus ignores args (fixed --new-window), so the
            // downloads dir goes through uwsm-app + nautilus directly.
            execArgv(["uwsm-app", "--", "nautilus", "--new-window", homeDir + "/Downloads"]);
            break;
        case "theme":
            execArgv(["omarchy-theme-bg-next"]);
            break;
        }
    }

    // ---------- poll plumbing --------------------------------------------------
    // One bounded fetch per integration: argv vector for plain commands,
    // `sh` for fixed literal scripts (pipelines). Nothing interpolated.
    //
    // No per-cell timers (BRIEF §4 / verifier B5): DockPoll carries no Timer
    // at all. `maybeFire(nowMs)` is called once per dock cadence tick — the
    // collector's ~1 Hz stats frame, or the single gated 1 s fallback below —
    // and fires only when this poll's wall-clock `everyMs` period has elapsed
    // (or a refreshSoon() deadline arrived), so mixed tick sources can never
    // double-fire a cell.
    component DockPoll: QtObject {
        id: poller
        property var argv: []
        property string sh: ""
        property int everyMs: 0
        property bool active: true          // false → cell not in this profile; never fires
        property double _lastMs: -1         // last wall-clock fire (drives everyMs)
        property double _refreshAt: -1      // one-shot refresh deadline (post-action)
        signal finished(string out)

        function pulse() {
            if (!active || _proc.running)
                return;
            _proc.command = sh !== "" ? ["bash", "-lc", sh] : argv;
            if (_proc.command.length === 0)
                return;
            _proc.running = true;
        }
        function refreshSoon(ms) {
            // Deadline instead of a one-shot Timer: the next cadence tick
            // lands it (≤1 s while the dock is visible).
            _refreshAt = Date.now() + (ms === undefined ? 900 : ms);
            dock.tick();
        }
        function maybeFire(nowMs) {
            if (!active)
                return;
            if (_refreshAt >= 0 && nowMs >= _refreshAt) {
                _refreshAt = -1;
                _lastMs = nowMs;
                pulse();
                return;
            }
            if (everyMs > 0 && (_lastMs < 0 || nowMs - _lastMs >= everyMs)) {
                _lastMs = nowMs;
                pulse();
            }
        }

        property Process _proc: Process {
            running: false
            stdout: StdioCollector {
                waitForEnd: true
                onStreamFinished: poller.finished(text)
            }
        }
        Component.onCompleted: {
            if (active)
                pulse();
        }
    }

    DockPoll {
        id: mediaPoll
        everyMs: 2000       // recon media-mpris poll_s=2
        active: dock.cellActive("media")
        argv: ["omarchy-shell", "media", "status"]
        onFinished: function (out) {
            var d = null;
            try {
                d = JSON.parse(String(out));
            } catch (e) {
                d = null;
            }
            dock.media = (d && typeof d === "object") ? d : ({});
        }
    }
    DockPoll {
        id: notifPoll
        everyMs: 5000       // recon notifications-dnd poll_s=5
        active: dock.cellActive("notif")
        sh: 'h="$HOME/.local/state/omarchy/notifications/history"; omarchy-shell notifications isDnd 2>/dev/null; find "$h" -maxdepth 1 -type f 2>/dev/null | wc -l; f=$(ls -1t "$h" 2>/dev/null | head -1); [ -n "$f" ] && head -c 400 "$h/$f" | tr "\\n" " "; echo'
        onFinished: function (out) {
            var L = String(out).split("\n");
            dock.notifDnd = (L[0] || "").trim() === "on" ? "on" : "off";
            var n = parseInt((L[1] || "").trim(), 10);
            dock.notifCount = isFinite(n) ? n : -1;
            var s = "";
            if (L[2] !== undefined) {
                try {
                    var j = JSON.parse(L[2]);
                    s = String(j.summary || j.body || "");
                } catch (e) {
                    s = "";
                }
            }
            dock.notifNewest = s;
        }
    }
    DockPoll {
        id: volPoll
        everyMs: 3000       // recon audio-volume poll_s=3
        active: dock.cellActive("vol")
        argv: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        onFinished: function (out) {
            dock.applyWpctl(out, false);
        }
    }
    DockPoll {
        id: micPoll
        everyMs: 3000       // recon mic-mute poll_s=3
        active: dock.cellActive("mic")
        argv: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"]
        onFinished: function (out) {
            dock.applyWpctl(out, true);
        }
    }
    DockPoll {
        id: btPoll
        everyMs: 15000      // recon bluetooth poll_s=15
        active: dock.cellActive("bt")
        sh: 'bluetoothctl show 2>/dev/null | awk "/Powered:/{print \\$2}"; bluetoothctl devices Connected 2>/dev/null | wc -l'
        onFinished: function (out) {
            var L = String(out).split("\n");
            if (((L[0] || "").trim()) === "" && (L[1] || "").trim() === "")
                return;    // bluetoothctl absent/failed → stay unknown
            dock.btSeen = true;
            dock.btPowered = (L[0] || "").trim() === "yes";
            var n = parseInt((L[1] || "").trim(), 10);
            dock.btConn = isFinite(n) ? n : -1;
        }
    }
    DockPoll {
        id: capPoll
        everyMs: 30000      // recon screenshot-suite poll_s=30
        active: dock.cellActive("cap")
        sh: 'd="$HOME/Pictures/screenshots"; find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l; ls -1t "$d" 2>/dev/null | head -1'
        onFinished: function (out) {
            var L = String(out).split("\n");
            var n = parseInt((L[0] || "").trim(), 10);
            dock.capCount = isFinite(n) ? n : -1;
            dock.capNewest = (L[1] || "").trim();
        }
    }
    DockPoll {
        id: idlePoll
        everyMs: 15000      // recon idle-inhibit poll_s=15
        active: dock.cellActive("idle")
        argv: ["omarchy-shell", "idle", "status"]
        onFinished: function (out) {
            var d = null;
            try {
                d = JSON.parse(String(out));
            } catch (e) {
                d = null;
            }
            dock.idle = (d && typeof d === "object") ? d : ({});
        }
    }
    DockPoll {
        id: remPoll
        everyMs: 10000      // recon reminders-timers poll_s=10
        active: dock.cellActive("rem")
        argv: ["omarchy-reminder", "show", "-j"]
        onFinished: function (out) {
            var d = null;
            try {
                d = JSON.parse(String(out));
            } catch (e) {
                d = null;
            }
            dock.rem = (d && typeof d === "object") ? d : ({});
        }
    }
    DockPoll {
        id: nightPoll
        everyMs: 30000      // recon nightlight poll_s=30
        active: dock.cellActive("night")
        argv: ["omarchy-shell", "nightlight", "status"]
        onFinished: function (out) {
            var d = null;
            try {
                d = JSON.parse(String(out));
            } catch (e) {
                d = null;
            }
            dock.nightEnabled = (d && d.enabled === true) ? "on" : (d ? "off" : "");
            var t = (d && d.temperature !== null && d.temperature !== undefined) ? Number(d.temperature) : NaN;
            dock.nightTemp = isFinite(t) ? t : -1;
        }
    }
    DockPoll {
        id: pwrPoll
        everyMs: 30000      // recon power-profile poll_s=30
        active: dock.cellActive("pwr")
        argv: ["powerprofilesctl", "get"]
        onFinished: function (out) {
            dock.powerProfile = String(out).trim();
        }
    }
    DockPoll {
        id: dlPoll
        everyMs: 60000      // recon recent-downloads poll_s=60
        active: dock.cellActive("dl")
        sh: 'd="$HOME/Downloads"; find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l; ls -1t "$d" 2>/dev/null | head -1'
        onFinished: function (out) {
            var L = String(out).split("\n");
            var n = parseInt((L[0] || "").trim(), 10);
            dock.dlCount = isFinite(n) ? n : -1;
            dock.dlNewest = (L[1] || "").trim();
        }
    }

    // ---------- cadence ------------------------------------------------------
    // PRIMARY driver: the HUD's stats frame. HudV4 hands a fresh `stats` map
    // ~1 Hz (collector cadence, same applyFrame path as v3), so each frame
    // wakes whichever polls are due — the telemetry stream IS the clock, and
    // no repaint happens without a stats delta or a finished fetch.
    // FALLBACK: lane H's ingest is not in tree yet, so ONE coalesced 1 s
    // timer keeps the strip alive until it lands — the only wall-clock timer
    // in this file, never faster than telemetry cadence, and stopped while
    // the dock is hidden. Poll periods are wall-clock, so the two tick
    // sources can overlap without double-firing any cell.
    readonly property var _polls: [mediaPoll, notifPoll, volPoll, micPoll,
                                   btPoll, capPoll, idlePoll, remPoll,
                                   nightPoll, pwrPoll, dlPoll]

    function tick() {
        var t = Date.now();
        for (var i = 0; i < _polls.length; i++)
            _polls[i].maybeFire(t);
    }

    onStatsChanged: tick()

    Timer {
        interval: 1000
        repeat: true
        running: dock.visible
        onTriggered: dock.tick()
    }

    // Clipboard history depth — FileView watches the file, no process spawn.
    FileView {
        id: clipFile
        path: dock.homeDir + "/.local/state/omarchy/clipboard-history.json"
        watchChanges: dock.cellActive("clip")   // clip cell hidden in compact → stop watching
        printErrors: false
        onLoaded: {
            var d = null;
            try {
                d = JSON.parse(String(text()));
            } catch (e) {
                d = null;
            }
            if (d && typeof d.length === "number") {
                dock.clipCount = d.length;
                var e0 = d.length > 0 ? d[0] : null;
                var s = "";
                if (e0) {
                    if (e0.type === "image")
                        s = "image " + (e0.mime || "");
                    else if (e0.text !== undefined)
                        s = String(e0.text).replace(/\s+/g, " ").trim();
                    else if (e0.path !== undefined)
                        s = String(e0.path).split("/").pop();
                }
                dock.clipNewest = s;
            } else {
                dock.clipCount = -1;
                dock.clipNewest = "";
            }
        }
        onLoadFailed: {
            dock.clipCount = -1;
            dock.clipNewest = "";
        }
    }

    function applyWpctl(text, isMic) {
        var s = String(text);
        var m = s.match(/Volume:\s*([0-9.]+)/);
        var f = m ? Number(m[1]) : NaN;
        var muted = s.indexOf("MUTED") >= 0;
        if (isMic) {
            micFrac = isFinite(f) ? Math.min(1, f) : -1;
            micMuted = muted;
        } else {
            volFrac = isFinite(f) ? Math.min(1, f) : -1;
            volMuted = muted;
        }
    }

    // ---------- strip ----------------------------------------------------------
    // Positioned by hand rather than by a Row: the fractional weighted pitch
    // (2466/17 = 145.06) left every chip edge and every hairline on a
    // half-pixel. cellX/cellW floor every boundary to a whole pixel.
    Item {
        id: strip
        width: parent.width
        height: dock.cellH
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
            model: dock.activeCellDefs
            delegate: Item {
                id: cellWrap
                required property var modelData
                required property int index
                // weighted share: compact's media cell is wider than 1 unit
                x: dock.cellX(index)
                width: dock.cellW(index)
                height: strip.height

                // .usep hairline between chips, centred in the 10 px gutter
                Rectangle {
                    visible: cellWrap.index > 0
                    x: dock.chipGap - 1
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.topMargin: 10
                    anchors.bottomMargin: 10
                    width: 1
                    gradient: Gradient {
                        GradientStop {
                            position: 0.0
                            color: "transparent"
                        }
                        GradientStop {
                            position: 0.5
                            color: Qt.rgba(0.92, 0.96, 0.99, 0.14)
                        }
                        GradientStop {
                            position: 1.0
                            color: "transparent"
                        }
                    }
                }

                EmbossedTile {
                    id: chip
                    anchors.fill: parent
                    anchors.leftMargin: dock.chipGap
                    anchors.rightMargin: dock.chipGap
                    padding: 8
                    radius: Style.r.emboss
                    dropShadow: false
                    hot: dock.cellHot(cellWrap.modelData.id)
                    ledColor: hot ? Style.c.accent : Style.tone(Style.c.accent2, 0.55)

                    onClicked: dock.activate(cellWrap.modelData.id)

                    // compact profile: the media cell swaps the plain column for
                    // an album-art layout (MediaCell.qml). In full profile this
                    // stays invisible with an empty artUrl, so DP-1's strip and
                    // its fetch behaviour are unchanged.
                    MediaCell {
                        anchors.fill: parent
                        visible: dock.compact && cellWrap.modelData.id === "media"
                        label: cellWrap.modelData.label
                        value: dock.cellValue("media")
                        sub: dock.cellSub("media")
                        artUrl: visible ? dock.mediaArtUrl : ""
                    }

                    Column {
                        visible: !(dock.compact && cellWrap.modelData.id === "media")
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 2
                        anchors.rightMargin: 2
                        spacing: 4

                        // micro tier: status dot + tracked micro label
                        Row {
                            width: parent.width
                            spacing: 7
                            Rectangle {
                                width: 5
                                height: 5
                                radius: 3
                                anchors.verticalCenter: parent.verticalCenter
                                color: dock.cellDotColor(cellWrap.modelData.id)
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.max(0, parent.width - 12)
                                elide: Text.ElideRight
                                text: cellWrap.modelData.label
                                color: Style.c.mute
                                font.family: Style.f.mono
                                font.pixelSize: Style.f.pxTag
                                font.letterSpacing: 1.3
                            }
                        }
                        // value tier — the only dominant line in the cell
                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            textFormat: Text.RichText
                            text: dock.cellValue(cellWrap.modelData.id)
                            color: Style.c.txt
                            font.family: Style.f.mono
                            font.pixelSize: 12
                        }
                        Item {
                            width: parent.width
                            height: dock.cellBar(cellWrap.modelData.id) >= 0 ? 4 : sub.implicitHeight
                            visible: dock.cellSub(cellWrap.modelData.id) !== "" || dock.cellBar(cellWrap.modelData.id) >= 0

                            Rectangle {
                                visible: dock.cellBar(cellWrap.modelData.id) >= 0
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                height: 3
                                radius: 2
                                color: Style.c.recessTop
                            }
                            Rectangle {
                                visible: dock.cellBar(cellWrap.modelData.id) >= 0
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.round(parent.width * Math.max(0, Math.min(1, dock.cellBar(cellWrap.modelData.id))))
                                height: 3
                                radius: 2
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop {
                                        position: 0.0
                                        color: Style.c.accent2
                                    }
                                    GradientStop {
                                        position: 1.0
                                        color: Style.c.accent
                                    }
                                }
                            }
                            Text {
                                id: sub
                                visible: dock.cellBar(cellWrap.modelData.id) < 0
                                width: parent.width
                                elide: Text.ElideRight
                                // cellSub() runs text through esc(), so the rich
                                // text path is what renders those entities
                                textFormat: Text.RichText
                                text: dock.cellSub(cellWrap.modelData.id)
                                color: Style.c.faint
                                font.family: Style.f.mono
                                font.pixelSize: Style.f.pxTag
                            }
                        }
                    }
                }
            }
        }
    }
}
