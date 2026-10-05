pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// DockState: the single owner of every UtilityDock poller and its state.
// Docks register as consumers (anyCount / fullCount) only while visible, and
// pollers whose cells nobody shows stay dormant, so a hidden deck costs zero
// spawns. Before this, each dock instance ran its own copy of the same
// fetches (media / vol / mic polled twice).
QtObject {
    id: dock

    readonly property string homeDir: Quickshell.env("HOME")
    // cells every dock profile shows; the rest poll only for a visible full dock
    readonly property var compactIds: ["media", "vol", "mic", "notif", "ws", "pwr", "upd", "cap", "pick", "bg", "term"]
    property int anyCount: 0
    property int fullCount: 0
    function want(id) {
        return anyCount > 0 && (fullCount > 0 || compactIds.indexOf(id) >= 0);
    }

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

    readonly property DockPoll mediaPoll: DockPoll {
        id: mediaPoll
        everyMs: 4000       // recon media-mpris poll_s=2
        active: dock.want("media")
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
    readonly property DockPoll notifPoll: DockPoll {
        id: notifPoll
        everyMs: 10000       // recon notifications-dnd poll_s=5
        active: dock.want("notif")
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
    readonly property DockPoll volPoll: DockPoll {
        id: volPoll
        everyMs: 6000       // recon audio-volume poll_s=3
        active: dock.want("vol")
        argv: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
        onFinished: function (out) {
            dock.applyWpctl(out, false);
        }
    }
    readonly property DockPoll micPoll: DockPoll {
        id: micPoll
        everyMs: 6000       // recon mic-mute poll_s=3
        active: dock.want("mic")
        argv: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"]
        onFinished: function (out) {
            dock.applyWpctl(out, true);
        }
    }
    readonly property DockPoll btPoll: DockPoll {
        id: btPoll
        everyMs: 30000      // recon bluetooth poll_s=15
        active: dock.want("bt")
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
    readonly property DockPoll capPoll: DockPoll {
        id: capPoll
        everyMs: 30000      // recon screenshot-suite poll_s=30
        active: dock.want("cap")
        sh: 'd="$HOME/Pictures/screenshots"; find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l; ls -1t "$d" 2>/dev/null | head -1'
        onFinished: function (out) {
            var L = String(out).split("\n");
            var n = parseInt((L[0] || "").trim(), 10);
            dock.capCount = isFinite(n) ? n : -1;
            dock.capNewest = (L[1] || "").trim();
        }
    }
    readonly property DockPoll idlePoll: DockPoll {
        id: idlePoll
        everyMs: 30000      // recon idle-inhibit poll_s=15
        active: dock.want("idle")
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
    readonly property DockPoll remPoll: DockPoll {
        id: remPoll
        everyMs: 30000      // recon reminders-timers poll_s=10
        active: dock.want("rem")
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
    readonly property DockPoll nightPoll: DockPoll {
        id: nightPoll
        everyMs: 30000      // recon nightlight poll_s=30
        active: dock.want("night")
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
    readonly property DockPoll pwrPoll: DockPoll {
        id: pwrPoll
        everyMs: 30000      // recon power-profile poll_s=30
        active: dock.want("pwr")
        argv: ["powerprofilesctl", "get"]
        onFinished: function (out) {
            dock.powerProfile = String(out).trim();
        }
    }
    readonly property DockPoll dlPoll: DockPoll {
        id: dlPoll
        everyMs: 60000      // recon recent-downloads poll_s=60
        active: dock.want("dl")
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

    readonly property Timer fallbackTick: Timer {
        interval: 1000
        repeat: true
        running: dock.anyCount > 0
        onTriggered: dock.tick()
    }

    // Clipboard history depth — FileView watches the file, no process spawn.
    readonly property FileView clipFileView: FileView {
        id: clipFile
        path: dock.homeDir + "/.local/state/omarchy/clipboard-history.json"
        watchChanges: dock.want("clip")   // clip cell hidden in compact → stop watching
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

}
