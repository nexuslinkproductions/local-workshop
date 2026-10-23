import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../kit"
import "feeds"

// DeckV5.qml - Quickshell wrapper around the pure DeckView.
//
// HudV4 loads this file only when ~/.config/nexuslink/hud-v5 exists. It takes the
// same inputs as the other decks (stats, tokData, crew, shown) plus the host window,
// runs the feeds only while the deck is shown, and adapts the signals of the view to
// the plugin's launcher, the yuri search feed and the keyboard grab for the Find field.
//
// The deck is laid out for 2560 x 1440 and scales to fit the slab it lives in.
Item {
    id: root

    // opaque base: the deck scales to fit, so on a non 16:9 host the letterbox
    // bands must still show the field (v5 kit Tokens.field) and never the
    // wallpaper behind the full-bleed window. First child, so it is behind all.
    Rectangle {
        anchors.fill: parent
        color: Tokens.field
        visible: !root.underEnvironment
    }

    // ---- same input contract as DeckCommand --------------------------------
    property var stats: ({})
    property var tokData: ({})
    property var crew: ({})
    property string screenName: ""
    property bool shown: true
    // HudV4 sets this while the Environment room is live under the deck; the
    // base below then steps aside so the room shows through.
    property bool underEnvironment: false
    // the host PanelWindow (HudV4 passes it); falls back to the attached window
    property var window: null
    readonly property var hostWindow: root.window ? root.window : QsWindow.window

    // ---- scale to fit ------------------------------------------------------
    readonly property real fit: Math.min(root.width / 2560, root.height / 1440)

    Component.onCompleted: {
        console.log("v5 deck loaded, host " + root.width + "x" + root.height + ", scale " + root.fit.toFixed(3)
                    + ", origin " + deckView.x + "," + deckView.y)
        root.syncHostKeys()
    }

    // ---- clock: minute precision, one wake per minute ----------------------
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // ---- feeds (poll only while shown) -------------------------------------
    LinkFeed { id: linkFeed; active: root.shown }
    StorageFeed { id: storageFeed; active: root.shown }
    LocalAiFeed { id: localFeed; active: root.shown }
    FindFeed {
        id: findFeed
        // the deck is shown whenever this wrapper is alive; without this the
        // feed returns early on every keystroke and nothing is ever searched
        active: root.shown
        query: deckView.findQuery
        filter: deckView.findFilter
    }
    AppLauncher {
        id: launcher
        dryRun: false
    }

    // ---- launcher model (assets/apps.json, read once) ----------------------
    property var apps: []
    FileView {
        id: appsFile
        path: Qt.resolvedUrl("assets/apps.json").toString().replace(/^file:\/\//, "")
        blockLoading: true
        watchChanges: false
        printErrors: false
        onLoaded: {
            try {
                var j = JSON.parse(appsFile.text())
                root.apps = j.apps ? j.apps : []
            } catch (e) {
                console.log("v5 deck: apps.json parse failed: " + e)
            }
        }
    }

    // ---- the deck ----------------------------------------------------------
    DeckView {
        id: deckView
        width: 2560
        height: 1440
        scale: root.fit
        transformOrigin: Item.TopLeft
        x: Math.round((root.width - 2560 * root.fit) / 2)
        y: Math.round((root.height - 1440 * root.fit) / 2)

        shown: root.shown
        underEnvironment: root.underEnvironment
        now: clock.date
        crew: root.crew
        link: linkFeed.link
        localAi: localFeed.localAi
        disks: storageFeed.disks
        apps: root.apps
        findResults: findFeed.results
        findBusy: findFeed.busy
        findNote: findFeed.note

        onFindQueryEdited: q => {
            deckView.findQuery = q
        }
        onFindFilterPicked: f => {
            deckView.findFilter = f
        }
        onLaunchRequested: app => launcher.launch(app)
        onFindHitActivated: hit => {
            if (hit && hit.path)
                Quickshell.execDetached(["xdg-open", String(hit.path)])
            // the opened app takes the screen, so Find closes and gives the keyboard back
            deckView.findOpen = false
        }
    }

    // ---- Find open state (IPC entry points, HudV4 forwards here) ----------
    // findOpen lives on the view; these are the only writers besides the view's
    // own rest pill and Escape handling. Never assign the grab directly.
    readonly property bool findOpen: deckView.findOpen
    readonly property bool grabActive: grab.active

    function openFind() {
        if (!root.shown)
            return false
        deckView.findOpen = true
        return true
    }
    function closeFind() {
        deckView.findOpen = false
        return true
    }

    onFindOpenChanged: {
        console.log("v5 find: open=" + root.findOpen + " grab=" + root.grabActive)
        // a new search starts empty; the pill text follows deckView.findQuery
        if (!root.findOpen)
            deckView.findQuery = ""
        root.syncHostKeys()
    }

    // The deck hides (output off, shell state change) while Find is open: close it
    // so the surface gives the keyboard back instead of keeping Exclusive mode.
    onShownChanged: {
        if (!root.shown)
            deckView.findOpen = false
        root.syncHostKeys()
    }

    // ---- inactivity guard ------------------------------------------------
    // Find holds the keyboard (focus grab plus the surface keyboard mode), so a
    // forgotten overlay would eat every key. One timer, armed only while Find
    // is open and restarted by every sign of life (open, query edit, filter,
    // selection move), closes Find after 30 s without input.
    readonly property int findIdleMillis: 30000
    Timer {
        id: findIdle
        interval: root.findIdleMillis
        repeat: false
        // No onRunningChanged restart here: restart() toggles running, which re-fired
        // the handler until the stack overflowed (RangeError). The binding already
        // starts the timer on open; the Connections below restart it on activity.
        running: root.findOpen && root.shown
        onTriggered: {
            console.log("v5 find: inactivity guard closed Find after " + interval + " ms")
            deckView.findOpen = false
        }
    }
    Connections {
        target: deckView
        function onFindQueryChanged() { findIdle.restart() }
        function onFindFilterChanged() { findIdle.restart() }
        function onFindSelectedChanged() { findIdle.restart() }
    }

    // Typing needs the keyboard: the host surface is WlrKeyboardFocus.None.
    // Two independent asks, both derived from deckView.findOpen so they cannot
    // drift apart: (1) the hyprland focus grab (AppGrid/AppDial idiom) and
    // (2) the layer-shell keyboard mode, mirrored onto the host window.
    HyprlandFocusGrab {
        id: grab
        windows: root.hostWindow ? [root.hostWindow] : []
        // bound, never assigned imperatively: flip deckView.findOpen instead
        active: deckView.findOpen && root.shown && !!root.hostWindow
        // the compositor dropped the grab (click outside, another grab won):
        // the pill must not stay open claiming a keyboard it no longer has
        onCleared: {
            console.log("v5 find: grab cleared")
            deckView.findOpen = false
        }
    }

    // Mirror the open state onto the host surface's layer-shell keyboard mode.
    // HudV4 declares findKeysWanted on the PanelWindow; a plain window (test
    // harness, floating copy) simply has no such property.
    function syncHostKeys() {
        var w = root.hostWindow
        if (w && w.findKeysWanted !== undefined)
            w.findKeysWanted = root.findOpen && root.shown
    }
    onHostWindowChanged: root.syncHostKeys()
}
