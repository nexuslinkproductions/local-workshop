pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// DeckView.qml - the whole v5 deck as one pure QtQuick scene (2560 x 1440).
//
// Pure on purpose: it imports QtQuick and the kit only, so the same file renders
// offscreen on the GPU harness from fixtures and runs live inside the Quickshell
// wrapper (DeckV5.qml), which feeds the properties below.
//
// Layout follows the s3 design with Marcel's amendments: the knot is the one round
// hero at (1280, 550); Crew and Find sit on the outer margin bands (x 16 percent and
// 84 percent); nothing but the clock comes closer than 1.5 knot radii (405 px) to the
// knot edge; the launcher arc lies on the bottom band.
//
// Time: one Timer writes `tick` at Tokens.swarmTickHzMin (24 Hz, the low end of the 24 to 30 Hz band, to protect the idle budget). Every other motion (knot,
// drift, breath, pulses) is computed from `tick` by the widgets or the shader.
Item {
    id: root
    width: Tokens.targetW
    height: Tokens.targetH

    // ---- inputs ----------------------------------------------------------
    property bool shown: true
    property bool autoTick: true
    // true when the Environment room sits under this view (full-bleed host):
    // the opaque base below steps aside so the room shows through.
    property bool underEnvironment: false
    property real tick: 0
    property date now: new Date()
    property var crew: ({})
    property var link: null
    property var localAi: null
    property var disks: []
    property var apps: []
    property string findQuery: ""
    property string findFilter: "all"
    property var findResults: []
    property bool findBusy: false
    property string findNote: ""
    // selection index inside the Find overlay (DeckV5 restarts its idle guard on it)
    readonly property alias findSelected: find.selected

    // ---- view state ------------------------------------------------------
    // "" rest, "crew" or "storage" expanded panel. Find opens through findOpen.
    property string view: ""
    property bool findOpen: false
    readonly property bool focusActive: root.view !== "" || root.findOpen

    signal findQueryEdited(string q)
    signal findFilterPicked(string f)
    signal findHitActivated(var hit)
    signal launchRequested(var app)

    // ---- layout (px, DP-2) -----------------------------------------------
    readonly property real knotCx: Tokens.knotCentreX
    readonly property real knotCy: Tokens.knotCentreY
    readonly property real leftBandX: 420
    readonly property real rightBandX: 2150
    // s10 slots reserved for P2 (not in the live tree yet, so nothing is placed):
    // agents 161.2,1084 to 507.5,1213; now_playing 80,84 to 480,160; today 2060,84
    // to 2480,200. Corners (chief/more, s10 corners_l/r) are not a live widget.

    // ---- pointer (deck coordinates) ---------------------------------------
    // One passive hover handler, no Timer. It only feeds the proximity field;
    // widgets keep their own MouseArea for clicks and hover.
    readonly property bool pointerInside: pointerOverride ? pointerForcedInside : deckPointer.hovered
    readonly property real pointerX: pointerOverride ? pointerForcedX
        : (deckPointer.hovered ? deckPointer.point.position.x : root.lastPointerX)
    readonly property real pointerY: pointerOverride ? pointerForcedY
        : (deckPointer.hovered ? deckPointer.point.position.y : root.lastPointerY)
    // Last position while inside, kept so a leave drags the field home from the
    // edge it left through instead of from nowhere.
    property real lastPointerX: -1000000
    property real lastPointerY: -1000000
    // Tests and stills: drive the field from fixed numbers.
    property bool pointerOverride: false
    property real pointerForcedX: -1000000
    property real pointerForcedY: -1000000
    property bool pointerForcedInside: false

    HoverHandler {
        id: deckPointer
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
        onPointChanged: {
            if (!root.pointerOverride && hovered) {
                root.lastPointerX = point.position.x
                root.lastPointerY = point.position.y
            }
        }
    }

    // ---- fonts -----------------------------------------------------------
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Bold.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Black.ttf") }

    // ---- the single tick -------------------------------------------------
    Timer {
        id: ticker
        property double t0: Date.now()
        interval: Math.round(1000 / Tokens.swarmTickHzMin)
        repeat: true
        running: root.shown && root.autoTick
        onTriggered: root.tick = (Date.now() - t0) / 1000
    }

    // ---- field (never dimmed) --------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: Tokens.field
        visible: !root.underEnvironment
    }

    // ---- HUD content: dims and softens while a focus view is open -------
    FocusDim {
        anchors.fill: parent
        active: root.focusActive

        // s10 wall labels (build_s10.py .wl: 700, 16 px, tracking .26em,
        // rgba(143,216,232,.40), line box 16 px at left 722 / 1718, top 546).
        // Flat on the far wall, so they sit under the knot and the widgets.
        Text {
            id: wallMacGate
            x: 722
            y: 546
            text: "MAC GATE"
            color: Tokens.ice
            opacity: 0.40
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightBold
            font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
        }

        Text {
            id: wallSector7
            x: 1718
            y: 546
            text: "SECTOR 7"
            color: Tokens.ice
            opacity: 0.40
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightBold
            font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
        }

        KnotSwarm {
            x: root.knotCx - 350
            y: root.knotCy - 350
            width: 700
            height: 700
            knotPx: Tokens.knotDiameter
            t: root.tick
            running: root.shown
        }

        // s10 clock box: line-box top 64.9, centre x 1287.1 (s10-spacing.json).
        // The numeral row is centred in the widget and sits 6.1 px below its top.
        ClockWidget {
            x: 1287.1 - 350
            y: 64.9 - 6.1
            width: 700
            height: 130
            tick: root.tick
            shown: root.shown
            now: root.now
        }

        // Positions: s10 box top-left minus the drawn content offset in the widget
        // (measured at rest, drift removed): crew (0.2, 24.6), mac (0.2, 4.1),
        // local (0.9, 4.1), storage (-0.1, 3.8). Sizes are not changed here (P2).
        CrewWidget {
            id: crewW
            x: 184.4 - 0.2
            y: 248 - 24.6
            width: 360
            height: 240
            tick: root.tick
            shown: root.shown
            phase: 0.4
            crew: root.crew
            onExpandRequested: root.view = "crew"
        }

        MacWidget {
            id: macW
            x: 169.3 - 0.2
            y: 692.9 - 4.1
            width: 360
            height: 220
            tick: root.tick
            shown: root.shown
            phase: 1.9
            link: root.link
            onExpandRequested: root.view = "mac"
        }

        LocalWidget {
            id: localW
            x: 1991.3 - 0.9
            y: 451.7 - 4.1
            width: 320
            height: 220
            tick: root.tick
            shown: root.shown
            phase: 3.1
            localAi: root.localAi
            // the Find results panel opens over this band
            opacity: root.findOpen ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        }

        StorageWidget {
            id: storageW
            x: 2001.3 + 0.1
            y: 773 - 3.8
            width: 340
            height: 200
            tick: root.tick
            shown: root.shown
            phase: 4.4
            disks: root.disks
            opacity: root.findOpen ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            onExpandRequested: root.view = "storage"
        }

        LauncherArc {
            id: launcherArc
            // Centred on the deck centre line: local centre (width/2) lands on
            // deck x 1280, so the whole group is mirror symmetric about it.
            x: 1280 - width / 2
            width: 1380
            // Ring top of the end tiles sits 12.2 px above y (drift removed): s10 launcher.t 1092.5.
            y: 1092.5 + 12.2
            tick: root.tick
            apps: root.apps
            onLaunchRequested: app => root.launchRequested(app)
        }
    }

    // ---- proximity field --------------------------------------------------
    // One invisible field, no Timer. It reads the pointer and writes proximity,
    // pushX and pushY into the four widgets; the knot is not in the list, so it
    // is never pushed. FindPill is left out because its rest pill opens the
    // search by click and it is being rewritten in parallel.
    ProximityField {
        id: proxField
        pointerX: root.pointerX
        pointerY: root.pointerY
        inside: root.pointerInside
        widgets: [crewW, macW, localW, storageW]
    }

    // Read-only handles for tests and measurement (proximity, pushX, pushY,
    // grow). The deck itself never reads them.
    readonly property Item crewWidget: crewW
    readonly property Item macWidget: macW
    readonly property Item macPanelItem: macPanel.item
    readonly property Item localWidget: localW
    readonly property Item storageWidget: storageW
    readonly property Item launcherBand: launcherArc

    // ---- Find backdrop -----------------------------------------------------
    // The result tiles are soft fills, so while Find is open the deck behind
    // them nearly disappears (s3 shows no knot or widgets behind the results).
    Rectangle {
        anchors.fill: parent
        color: Tokens.field
        opacity: root.findOpen ? 0.92 : 0
        visible: opacity > 0.002
        Behavior on opacity {
            NumberAnimation {
                duration: root.findOpen ? Motion.focusInMillis : Motion.focusOutMillis
                easing.type: root.findOpen ? Easing.OutCubic : Easing.InOutQuad
            }
        }
    }

    // ---- Find (outside the dim so its open state stays sharp) -------------
    // The overlay is deck sized (0,0, 2560 x 1440) and draws the rest pill at
    // 1960,338 and the s3 results view in deck coordinates. While closed only
    // the 380 x 68 pill takes input, so the widgets below keep their hover.
    FindPill {
        id: find
        // The rest pill is drawn at 1960,338 inside this overlay (FindPill.qml). While
        // closed, the offset puts it on the s10 find box (2000,296). Open, the overlay
        // is back at 0,0 so the results stay centred.
        x: root.findOpen ? 0 : 40
        y: root.findOpen ? 0 : -42
        Behavior on x { NumberAnimation { duration: Motion.focusInMillis; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: Motion.focusInMillis; easing.type: Easing.OutCubic } }
        width: 2560
        height: 1440
        tick: root.tick
        open: root.findOpen
        query: root.findQuery
        filter: root.findFilter
        results: root.findResults
        busy: root.findBusy
        note: root.findNote
        opacity: (root.view === "") ? 1 : Tokens.focusDim
        Behavior on opacity { NumberAnimation { duration: Motion.focusInMillis; easing.type: Easing.OutCubic } }
        onOpenRequested: root.findOpen = true
        onQueryEdited: q => root.findQueryEdited(q)
        onFilterPicked: f => root.findFilterPicked(f)
        onHitActivated: hit => root.findHitActivated(hit)
        onCloseRequested: root.findOpen = false
    }

    // ---- dismiss layer and expanded panels --------------------------------
    MouseArea {
        anchors.fill: parent
        visible: root.view !== ""
        onClicked: root.view = ""
    }

    Loader {
        id: crewPanel
        x: 1280 - 550
        y: 720 - 380
        width: 1100
        height: 760
        active: root.view === "crew" || opacity > 0.01
        opacity: root.view === "crew" ? 1 : 0
        scale: root.view === "crew" ? 1 : 0.94
        Behavior on opacity { NumberAnimation { duration: root.view === "crew" ? Motion.stageInMillis : Motion.stageOutMillis; easing.type: Easing.OutCubic } }
        Behavior on scale {
            NumberAnimation {
                duration: root.view === "crew" ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.view === "crew" ? Easing.OutBack : Easing.InOutQuad
                easing.overshoot: 1.22
            }
        }
        sourceComponent: Component {
            CrewExpanded {
                crew: root.crew
                onCloseRequested: root.view = ""
            }
        }
    }

    // MAC focus view: same in-place shell as the crew panel (scale 0.94 to 1,
    // OutBack overshoot 1.22 is about 5.5 percent, return InOutQuad without overshoot).
    Loader {
        id: macPanel
        x: 1280 - 550
        y: 720 - 380
        width: 1100
        height: 760
        active: root.view === "mac" || opacity > 0.01
        opacity: root.view === "mac" ? 1 : 0
        scale: root.view === "mac" ? 1 : 0.94
        Behavior on opacity { NumberAnimation { duration: root.view === "mac" ? Motion.stageInMillis : Motion.stageOutMillis; easing.type: Easing.OutCubic } }
        Behavior on scale {
            NumberAnimation {
                duration: root.view === "mac" ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.view === "mac" ? Easing.OutBack : Easing.InOutQuad
                easing.overshoot: 1.22
            }
        }
        sourceComponent: Component {
            MacExpanded {
                link: root.link
                tick: root.tick
                onCloseRequested: root.view = ""
            }
        }
    }

    Loader {
        id: storagePanel
        x: 1280 - 550
        y: 720 - 380
        width: 1100
        height: 760
        active: root.view === "storage" || opacity > 0.01
        opacity: root.view === "storage" ? 1 : 0
        scale: root.view === "storage" ? 1 : 0.94
        Behavior on opacity { NumberAnimation { duration: root.view === "storage" ? Motion.stageInMillis : Motion.stageOutMillis; easing.type: Easing.OutCubic } }
        Behavior on scale {
            NumberAnimation {
                duration: root.view === "storage" ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.view === "storage" ? Easing.OutBack : Easing.InOutQuad
                easing.overshoot: 1.22
            }
        }
        sourceComponent: Component {
            StorageExpanded {
                disks: root.disks
                onCloseRequested: root.view = ""
            }
        }
    }
}
