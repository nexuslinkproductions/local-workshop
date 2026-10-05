pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// UtilityDock.qml — shared bottom utility strip (lane D1).
// Imported by CommandHub (DP-1) and Workbench (HDMI-A-3). Fifteen glass
// cells per candidates/mock2/B/dp1.html .util/.uchip: each cell is a label,
// an optional status line, and a click that fires a real Omarchy action.
// Dedupe pass (map rows 11/12/16/17/18/23/24/25): dock cells carry actions,
// not readouts. The weather and appearance cells are gone; the value/sub/
// meter lines of volume, mic, disk, updates, workspaces, power and media are
// stripped; every activate action and the mute/heat state survive.
//
// `compact: true` (Workbench/HDMI-A-3, lane G2) renders only the curated
// compactIds set: MEDIA expanded with an album-art MediaCell, then VOLUME,
// MIC, NOTIFICATIONS, WORKSPACES, POWER, weighted wider so the strip
// breathes, and each hidden cell's poller is gated off entirely.
//
// Data plan (recon/integrations-desktop.json): collector stats keys stay as
// dot-state inputs (pkg_updates, ws_count, fs_root_pct).
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
    // "full" (default) = all 15 cells, unchanged DP-1 CommandHub dock.
    // "compact" (HDMI-A-3 Workbench) = curated subset below — media cell is
    // weighted wider and carries a MediaCell album-art thumb.
    property bool compact: false
    readonly property var compactIds: DockState.compactIds

    // ---- geometry ----------------------------------------------------------
    property int cellH: 92             // mock .util inner band ≈94 px
    // mock .util gap:10 — every cell keeps 5 px of chrome on each side so the
    // gutters are all 10 px. The first cell used to take 0 on its left, which
    // made gap 0→1 half the width of every other gap in the strip.
    readonly property int chipGap: 6
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

    // Fire-and-forget action: argv through a login shell `exec "$@"` so the
    // omarchy-* scripts under /usr/share/omarchy/bin resolve — the same
    // indirection Navigator.qml uses. No shell string concatenation.
    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "dock"].concat(argv));
    }

    // ---- cell registry -----------------------------------------------------
    // Order matches the mock's left→right strip; bluetooth slots next to the
    // other radio/audio chips.
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
            id: "pick",
            label: "COLOR PICKER"
        },
        {
            id: "bg",
            label: "NEXT BACKGROUND"
        },
        {
            id: "term",
            label: "TERMINAL"
        },
        {
            id: "hermes",
            label: "HERMES"
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

    // Per-cell width weight — compact's media cell is wider than 1 unit so
    // the album thumb + label breathe; everything else is an equal share.
    function cellWeight(id) {
        return compact && id === "media" ? 1.7 : 1.0;
    }
    readonly property real totalWeight: {
        var s = 0;
        for (var i = 0; i < activeCellDefs.length; i++)
            s += cellWeight(activeCellDefs[i].id);
        return Math.max(1, s);
    }
    // Integer cell boundaries. A fractional weighted pitch smeared every chip
    // edge and every 1 px hairline across two device pixels. Accumulating the
    // exact weighted offsets and rounding each cumulative boundary keeps every
    // edge on a whole pixel and the strip exactly as wide as the pane; dumping
    // the whole remainder on the last cell left one chip visibly wider than
    // its neighbours in the compact profile.
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

    // ---- polled cell state: owned by the DockState singleton -------------
    // (one poller set for every dock instance; DP-1 and HDMI-A-3 used to each
    // run their own copy of the same 11 fetches)
    readonly property var media: DockState.media
    readonly property string mediaArtUrl: DockState.mediaArtUrl
    readonly property int notifCount: DockState.notifCount
    readonly property string notifDnd: DockState.notifDnd
    readonly property string notifNewest: DockState.notifNewest
    readonly property real volFrac: DockState.volFrac
    readonly property bool volMuted: DockState.volMuted
    readonly property real micFrac: DockState.micFrac
    readonly property bool micMuted: DockState.micMuted
    readonly property bool btSeen: DockState.btSeen
    readonly property bool btPowered: DockState.btPowered
    readonly property int btConn: DockState.btConn
    readonly property int clipCount: DockState.clipCount
    readonly property string clipNewest: DockState.clipNewest
    readonly property int capCount: DockState.capCount
    readonly property string capNewest: DockState.capNewest
    readonly property var idle: DockState.idle
    readonly property var rem: DockState.rem
    readonly property string nightEnabled: DockState.nightEnabled
    readonly property int nightTemp: DockState.nightTemp
    readonly property string powerProfile: DockState.powerProfile
    readonly property int dlCount: DockState.dlCount
    readonly property string dlNewest: DockState.dlNewest

    // ---------- cell content -------------------------------------------------
    // A 15-cell strip leaves ~155 px of usable width per chip at 12 px Kode
    // Mono (≈8.9 px/char), so every value line below is held to ≤14 characters
    // and every sub line to ≤19. Anything longer was silently elided, which
    // read as truncated data rather than as a design.
    // Dedupe (map 11/12/16/17/18/23/24/25): the stripped cells (media, vol,
    // mic, upd, ws, pwr, disk — plus the deleted weather/appearance chips)
    // fall through to the em dash below and render no datum. The mute state
    // survives as the dot/led colour via cellHot, not as text. Cells whose
    // datum lives only here (notif, bt, clip, cap, idle, rem, night, dl)
    // keep their line: Builder 3 does not enumerate them.
    function cellValue(id) {
        switch (id) {
        case "notif":
            if (notifCount < 0)
                return ung;
            return b(String(notifCount)) + " · DND " + (notifDnd === "on" ? "<font color='" + cssHex(Style.c.warn) + "'>on</font>" : "off");
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
        case "rem":
            if (rem.count === undefined)
                return ung;
            return b(String(num(rem.count))) + " active";
        case "night":
            return nightEnabled === "" ? ung : nightEnabled;
        case "dl":
            if (dlCount < 0)
                return ung;
            return dlNewest !== "" ? esc(trunc(dlNewest, 12)) : "empty";
        }
        return ung;
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



    // Glyph per cell (Font Awesome, via Style.ico). Cells are action tokens.
    function cellGlyph(id) {
        switch (id) {
        case "media":
            return media.playing === true ? Style.ico.pause : Style.ico.play;
        case "notif":
            return Style.ico.bell;
        case "vol":
            return volMuted ? Style.ico.mute : Style.ico.vol;
        case "mic":
            return Style.ico.mic;
        case "bt":
            return "\uf293";
        case "clip":
            return Style.ico.copy;
        case "cap":
            return Style.ico.shot;
        case "idle":
            return Style.ico.eye;
        case "rem":
            return Style.ico.pulse;
        case "upd":
            return Style.ico.sync;
        case "ws":
            return Style.ico.grid;
        case "night":
            return Style.ico.moon;
        case "pwr":
            return Style.ico.bolt;
        case "disk":
            return Style.ico.disk;
        case "dl":
            return Style.ico.down;
        case "pick":
            return Style.ico.pick;
        case "bg":
            return Style.ico.palette;
        case "term":
            return Style.ico.term;
        case "hermes":
            return Style.ico.robot;
        }
        return Style.ico.more;
    }

    // Right-click alternate per cell (media next, ws next workspace, ...).
    function secondary(id) {
        switch (id) {
        case "media":
            execArgv(["omarchy-shell", "-q", "media", "next"]);
            DockState.mediaPoll.refreshSoon();
            break;
        case "ws":
            execArgv(["hyprctl", "dispatch", "workspace", "e+1"]);
            break;
        case "vol":
            execArgv(["omarchy-audio-output-switch"]);
            break;
        case "bg":
            execArgv(["omarchy-theme-bg-switcher"]);
            break;
        }
    }

    // Value line is shown only for cells that are the sole home of their
    // datum (notif, bt, clip, cap, idle, rem, night, dl); the rest are pure
    // action tokens (dedupe law).
    function cellLine(id) {
        var v = cellValue(id);
        return v === ung ? "" : v;
    }

    // ---------- actions ------------------------------------------------------
    function activate(id) {
        switch (id) {
        case "media":
            execArgv(["omarchy-shell", "-q", "media", "playPause"]);
            DockState.mediaPoll.refreshSoon();
            break;
        case "notif":
            execArgv(["omarchy-shell", "-q", "notifications", "toggleDnd"]);
            DockState.notifPoll.refreshSoon();
            break;
        case "vol":
            execArgv(["omarchy-audio-output-volume", "mute-toggle"]);
            DockState.volPoll.refreshSoon();
            break;
        case "mic":
            execArgv(["omarchy-audio-input-mute"]);
            DockState.micPoll.refreshSoon();
            break;
        case "bt":
            execArgv(["omarchy-shell", "-q", "omarchy.bluetooth", "toggle"]);
            DockState.btPoll.refreshSoon();
            break;
        case "clip":
            execArgv(["omarchy-shell", "-q", "shell", "call", "omarchy.clipboard", "toggle", "{}"]);
            break;
        case "cap":
            execArgv(["omarchy-capture-screenshot"]);
            DockState.capPoll.refreshSoon(2400);
            break;
        case "idle":
            execArgv(["omarchy-toggle-idle"]);
            DockState.idlePoll.refreshSoon();
            break;
        case "rem":
            execArgv(["omarchy-shell", "-q", "shell", "call", "omarchy.reminders", "toggle", "{}"]);
            DockState.remPoll.refreshSoon();
            break;
        case "upd":
            execArgv(["omarchy-shell", "-q", "omarchy.system-update", "refresh"]);
            break;
        case "ws":
            execArgv(["qs", "ipc", "-p", "/usr/share/omarchy/shell", "-t", "expose", "call", "toggle", ""]);
            break;
        case "night":
            execArgv(["omarchy-shell", "-q", "nightlight", "toggle"]);
            DockState.nightPoll.refreshSoon();
            break;
        case "pwr":
            execArgv(["omarchy-powerprofiles-set", "autodetect", powerProfile === "performance" ? "power-saver" : "performance"]);
            DockState.pwrPoll.refreshSoon(1600);
            break;
        case "disk":
            execArgv(["omarchy-launch-nautilus"]);
            break;
        case "pick":
            execArgv(["hyprpicker", "-a"]);
            break;
        case "bg":
            execArgv(["omarchy-theme-bg-next"]);
            break;
        case "term":
            execArgv(["omarchy-launch-terminal"]);
            break;
        case "hermes":
            execArgv(["omarchy-launch-tui", "--app-id=org.nexus.hermes", "hermes"]);
            break;
        case "dl":
            // omarchy-launch-nautilus ignores args (fixed --new-window), so the
            // downloads dir goes through uwsm-app + nautilus directly.
            execArgv(["uwsm-app", "--", "nautilus", "--new-window", homeDir + "/Downloads"]);
            break;
        }
    }

    // ---------- cadence: register as a DockState consumer while visible ------
    property bool _registered: false
    function syncRegistration() {
        if (visible && !_registered) {
            _registered = true;
            DockState.anyCount++;
            if (!compact)
                DockState.fullCount++;
        } else if (!visible && _registered) {
            _registered = false;
            DockState.anyCount--;
            if (!compact)
                DockState.fullCount--;
        }
    }
    onVisibleChanged: syncRegistration()
    Component.onCompleted: syncRegistration()
    Component.onDestruction: {
        if (_registered) {
            DockState.anyCount--;
            if (!compact)
                DockState.fullCount--;
        }
    }
    // the collector frame is the primary cadence; hidden docks do nothing
    onStatsChanged: if (visible)
        DockState.tick()

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

                ActionDockCell {
                    id: chip
                    anchors.fill: parent
                    anchors.leftMargin: dock.chipGap
                    anchors.rightMargin: dock.chipGap
                    glyph: dock.cellGlyph(cellWrap.modelData.id)
                    brand: cellWrap.modelData.id === "bt"
                    label: cellWrap.modelData.label
                    value: dock.cellLine(cellWrap.modelData.id)
                    hot: dock.cellHot(cellWrap.modelData.id)
                    iconSource: dock.compact && cellWrap.modelData.id === "media" ? dock.mediaArtUrl : ""
                    onActivated: dock.activate(cellWrap.modelData.id)
                    onSecondary: dock.secondary(cellWrap.modelData.id)
                }
            }
        }
    }
}
