import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire

// NowPlayingFeed.qml - v5 feed for the NOW PLAYING widget. Read only.
//
// Source: Quickshell.Services.Mpris, the first ACTIVE player in Mpris.players:
//   1. the first player with isPlaying true
//   2. else the first player with track metadata (paused)
// The playerctld proxy is never picked (omarchy's media service skips it too).
// No process and no timer: Mpris pushes property changes, and the bindings
// below re-evaluate on them.
//
// Level: the PipeWire peak of the default audio sink (linear 0..1), monitored
// only while the picked player is playing. MPRIS carries no level, so this is
// the output level of the whole sink, not the player's own. -1 = unknown.
//
// nowPlaying shape:
//   status     "fresh"  a player was picked
//              "empty"  no player with track metadata; reason "nothing playing"
//              "error"  the Mpris service is not available
//   title, artist, identity   strings, "" when unknown
//   playing    bool
//   canPrevious, canNext, canToggle   bool, from the player's can* flags
//   level      0..1, or -1 when unknown
//   reason     "" when fresh
//
// Controls (previous, next, togglePlaying) act on the picked player only when
// it advertises the matching can* flag. Nothing calls them yet.
Item {
    id: root

    property bool active: false

    visible: false
    width: 0
    height: 0

    readonly property var players: Mpris.players ? Mpris.players.values : []
    readonly property bool mprisOk: !!Mpris.players
    readonly property var picked: root.pickPlayer(root.players)
    readonly property bool playingNow: root.picked !== null && root.picked.isPlaying === true

    readonly property real level: (peak.enabled && Pipewire.defaultAudioSink)
        ? Math.max(0, Math.min(1, peak.peak)) : -1
    readonly property var nowPlaying: root.build(root.mprisOk, root.picked, root.level)

    function isProxy(p) {
        var d = String(p.dbusName || "").toLowerCase()
        var e = String(p.desktopEntry || "").toLowerCase()
        return d.indexOf("playerctld") !== -1 || e === "playerctld"
    }

    // list: Mpris.players.values. Returns the picked player or null.
    function pickPlayer(list) {
        var paused = null
        for (var i = 0; i < list.length; i++) {
            var p = list[i]
            if (!p || root.isProxy(p))
                continue
            if (p.isPlaying === true)
                return p
            if (paused === null && (p.trackTitle || p.trackArtist))
                paused = p
        }
        return paused
    }

    function build(ok, p, lvl) {
        if (!ok)
            return root.shape("error", "mpris service not available", null, lvl)
        if (!p)
            return root.shape("empty", "nothing playing", null, -1)
        return root.shape("fresh", "", p, lvl)
    }

    function shape(status, reason, p, lvl) {
        return {
            "status": status,
            "reason": reason,
            "title": p ? String(p.trackTitle || "") : "",
            "artist": p ? String(p.trackArtist || "") : "",
            "identity": p ? String(p.identity || p.desktopEntry || "") : "",
            "playing": p ? p.isPlaying === true : false,
            "canPrevious": p ? p.canGoPrevious === true : false,
            "canNext": p ? p.canGoNext === true : false,
            "canToggle": p ? (p.canTogglePlaying === true || p.canPlay === true || p.canPause === true) : false,
            "level": lvl
        }
    }

    function previous() {
        if (root.picked !== null && root.picked.canGoPrevious === true)
            root.picked.previous()
    }

    function next() {
        if (root.picked !== null && root.picked.canGoNext === true)
            root.picked.next()
    }

    function togglePlaying() {
        if (root.picked !== null && root.picked.canTogglePlaying === true)
            root.picked.togglePlaying()
    }

    // Peak of the default sink, only while a player is playing and the feed is
    // active. A missing default sink leaves level at -1 (see level above).
    PwNodePeakMonitor {
        id: peak
        node: Pipewire.defaultAudioSink
        enabled: root.active && root.playingNow
    }
}
