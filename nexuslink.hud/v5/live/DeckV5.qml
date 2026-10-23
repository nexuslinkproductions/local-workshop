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

    // ---- same input contract as DeckCommand --------------------------------
    property var stats: ({})
    property var tokData: ({})
    property var crew: ({})
    property string screenName: ""
    property bool shown: true
    // the host PanelWindow (HudV4 passes it); falls back to the attached window
    property var window: null
    readonly property var hostWindow: root.window ? root.window : QsWindow.window

    // ---- scale to fit ------------------------------------------------------
    readonly property real fit: Math.min(root.width / 2560, root.height / 1440)

    Component.onCompleted: console.log("v5 deck loaded, host " + root.width + "x" + root.height + ", scale " + root.fit.toFixed(3))

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
        now: clock.date
        crew: root.crew
        link: linkFeed.link
        localAi: localFeed.localAi
        disks: storageFeed.disks
        apps: root.apps
        findResults: findFeed.results
        findBusy: findFeed.busy

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
        }
    }

    // Typing needs a keyboard grab: the host surface has no keyboard focus.
    // Armed while the Find panel is open, released when it closes or the grab clears.
    HyprlandFocusGrab {
        windows: root.hostWindow ? [root.hostWindow] : []
        active: deckView.findOpen && root.shown && !!root.hostWindow
        onCleared: deckView.findOpen = false
    }
}
