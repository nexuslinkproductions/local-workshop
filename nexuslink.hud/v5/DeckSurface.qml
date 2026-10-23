import QtQuick
import NexusHud.V5 1.0

// DeckSurface.qml - the v5 DP-2 "Command" deck, composed. Pure QtQuick.
//
// WHY THIS FILE EXISTS NEXT TO DeckMain.qml
// The kit is pure QtQuick and the deck has to be proved by an offscreen render
// on this Mac (MAIN-SCREEN-BUILD.md acceptance 1). DeckMain.qml is the
// Quickshell layer - PanelWindow, IPC, FileView, Process - and Quickshell is not
// installed here, so a file that imports it cannot be loaded by tools/qml-shot.sh
// at all. The composition therefore lives here, driven only by properties, and
// DeckMain binds feeds into it. The Quickshell import rule for this tree (the
// only importer is DeckMain.qml) is checked with a plain grep in docs/integration.md.
//
// LAYOUT (fixed 2560x1440 surface, Tokens guides, never scaled by hand)
//   knot      540 at (Tokens.knotCentreX 1280, Tokens.goldenY1 550)
//   crew      centre (Tokens.thirdX1/2 = 426.5, goldenY1) - left margin band
//   local AI  centre (2560 - 426.5 = 2133.5, goldenY1)    - right margin band
//   mac       centre (426.5, Tokens.goldenY2 890)         - lower golden band
//   storage   centre (2133.5, goldenY2)                   - lower golden band
//   launcher  1400x312 at (1064, 996), tiles on the row y 1200, bottom right
//   find      pill box 560 wide, right-aligned to the safe margin (1904, 180)
//   clock     96 px numerals, centred at x 1280, y 96
//
// AMENDMENTS THIS LAYOUT OBEYS (MAIN-SCREEN-BUILD.md, binding, they win over s2)
// * "the knot is the one round hero ... at most one more round element on
//   screen". At rest this deck has exactly two round elements: the knot and the
//   crew swarm (a swarm is what W2 shipped; the amendment allows crew "as a
//   non-spherical cloud or a lattice" and W2 is a shell plus per-session dot
//   fields, not a sphere). Everything else is linear: MAC is a segmented dot
//   field, STORAGE is stacked dot-bars, LOCAL AI is a vertical level stack. s2's
//   LocalOrb, PulseRing and DotArc still exist and are registered; they live in
//   the deep views, where only one of them is crisp at a time.
// * "move Crew and Find further out toward the screen margins (outer thirds,
//   around x 14 to 20 percent and 80 to 86 percent of width)". Crew sits at
//   16.7 percent and LOCAL/FIND at 83.4 percent (thirdX1 / 2), leaving 471 px
//   between the crew orb's edge and the knot's edge and 1.5 knot radii (405 px)
//   clear around the knot centre.
// * "CLOCK TOO BIG ... about 96 px numerals" - Tokens.sizeClock is 168, so the
//   deck passes 96 to Clock.pixelSize instead of the token.
//
// FOCUS (PS5-menu style: every widget expands into its deeper view)
// One string, `focusId`, is the whole focus manager: "" is rest, otherwise one
// of crew / find / launcher / mac / storage / local. It is set by a click, by
// the keyboard, or by DeckMain over IPC, and it drives three things at once:
// the kit/Focus wrapper (dim 0.26 in the 0.18 to 0.3 band, scrim 0.35, 10 px
// blur, all from Tokens, only over HUD pixels), the widget's own expanded state
// (`CrewOrb.expanded`, `LauncherArc.expanded`, `FindField.active`, and the deep
// view overlay below), and `focusRect`, the crisp area Focus crops out.
//
// WORDS AT REST: 16 (clock, FRI, 23 OCT, Find, CREW 5, LOCAL 0.3 GB,
// MAC 8 ms, STORAGE 412 GB). Every word is at least 16 px. Measured by
// v5/tools/deck-audit.py over the live item tree, not counted by hand.
Item {
    id: deck

    readonly property int targetW: Tokens.targetW
    readonly property int targetH: Tokens.targetH

    implicitWidth: targetW
    implicitHeight: targetH

    // ---- data in (bound by DeckMain, filled by the stills) ----------------
    // Nothing here reads a file: the shell layer owns every feed and every
    // timer that touches one. A missing or malformed value leaves the deck in
    // its calm rest state (empty model, zero level), never an error on screen.
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
    property bool assembling: false
    property real assembleProgress: 1

    // Stills and probes set animate:false so a render is deterministic; the
    // shell leaves it true.
    property bool animate: true
    // Shell hook: the panel is 2560x1440 on the DP-2 and 1:1; anything else is
    // drawn at its own size, which is a still, not the deck.
    property string focusId: ""

    // Bench hook for nexuslink.hud/v5/spike/timing/swarm-bench.cpp, which cycles
    // this property every frame so the frame time is not measured on a cached
    // scene graph. -1 means "not benched": idle drift runs on its own clock.
    property real benchPhase: -1

    // Still hook, straight onto kit/Focus.previewProgress: >= 0 pins the focus
    // effect at that progress so an offscreen still shows the dimmed, blurred
    // state without a clock. The shell leaves it at -1 and Focus animates.
    property real stillFocusProgress: -1

    signal launchRequested(string slug)
    signal sessionActivated(string id)

    // ---- evidence hooks (read by v5/tools/deck-trace.py) ------------------
    // The motion evidence has to be measured on the composed deck, not on a
    // component in isolation, so the two values the trace needs are published
    // here: the crew orb's growth during an expand/return, and the idle drift
    // the deck actually applies. They are read-only and cost nothing.
    readonly property real crewGrowth: crewOrb.growth
    readonly property real idleDriftX: driftBand.dx
    readonly property real idleDriftY: driftBand.dy

    // ---- layout constants ------------------------------------------------
    // Margin band centres: halfway from the edge to the first thirds line, i.e.
    // 853 / 2 = 426.5 (16.7 percent of 2560) and its mirror 2133.5 (83.4).
    readonly property real marginX: Tokens.thirdX1 / 2
    readonly property real rightX: targetW - marginX
    readonly property real bandY: Tokens.goldenY1
    readonly property real lowerY: Tokens.goldenY2
    // Crew orb footprint. 224 is the W2 rest size; the focused orb is 1.4x that,
    // which the component owns (CrewOrb.expandScale).
    readonly property real crewSize: 224
    readonly property real crewExpand: crewSize * 1.4
    // Widget widths on the lower band: one Fibonacci step, so the dot pitch and
    // the gap between the two clusters stay in the same family as everything
    // else on the deck.
    readonly property real barWidth: Tokens.sp8
    readonly property real barHeight: barWidth / Tokens.dotBarSegments * Tokens.dotLitShare
                                                * Tokens.barHeightHeadroom
    // Launcher box: 1400x312 is LauncherArc's own implicit size (tilePitch 122
    // over 10 tiles). Placed against the right safe margin, so the tile row
    // lands bottom-right and the Arc Raiders hero ends at the right end.
    readonly property real launcherW: 1400
    readonly property real launcherH: 312
    readonly property real launcherX: targetW - Tokens.safeMargin - launcherW
    readonly property real launcherY: 988
    readonly property real tileRowY: launcherY + launcherH - 108   // arcBottomInset
    // Find pill: FindField's implicit box is the active width (560); the capsule
    // rests centred inside it at 380. The box is centred on the right margin
    // column (rightX 2133.5), so the pill, LOCAL and STORAGE share one vertical
    // alignment instead of three different right edges. (Centring a 560 box on
    // 2133.5 puts its edge at 2413.5, still inside the 96 px safe margin.)
    readonly property real findBoxW: Tokens.findFieldActiveWidth
    readonly property real findX: rightX - findBoxW / 2
    readonly property real findY: 180
    // Clock: 96 px numerals per the amendment, not Tokens.sizeClock (168).
    readonly property int clockSize: 96
    readonly property real clockY: Tokens.safeMargin

    // ---- focus rects ------------------------------------------------------
    // One rect per focus target, in deck coordinates, sized to what the focused
    // widget actually paints (no slack: Focus draws everything inside the rect
    // crisp and everything outside it dimmed, blurred and scrimmed, so slack
    // would ghost the neighbours back to full brightness).
    readonly property int crewRows: Math.min(sessions.length, 8)   // CrewOrb.maxSessions
    readonly property rect crewRect: Qt.rect(
        marginX - crewExpand / 2,
        bandY - crewExpand / 2,
        crewExpand,
        crewExpand + Tokens.sp2 + crewRows * 26)                   // rowHeight 26
    readonly property rect findRect: Qt.rect(
        findX, findY, findBoxW,
        Tokens.findFieldHeight + Tokens.sp3 + findResultsHeight)
    readonly property int findRows: Math.ceil(deck.findResults.length / 3)   // 3 columns
    readonly property real findResultsHeight: findRows > 0
        ? Tokens.sp3 + findRows * 128 + (findRows - 1) * Tokens.sp5 : 0
    readonly property rect launcherRect: Qt.rect(launcherX, launcherY - Tokens.sp7,
                                                 launcherW, launcherH + Tokens.sp7)
    readonly property rect macRect: Qt.rect(marginX - 300, lowerY + Tokens.sp5,
                                            600, 340)
    readonly property rect storageRect: Qt.rect(rightX - 330, lowerY - 250,
                                               660, 240)
    readonly property rect localRect: Qt.rect(rightX - 330, bandY - 160,
                                             660, 340)

    readonly property bool focusActive: focusId !== ""
    readonly property rect focusRect: {
        if (focusId === "crew")
            return crewRect
        if (focusId === "find")
            return findRect
        if (focusId === "launcher")
            return launcherRect
        if (focusId === "mac")
            return macRect
        if (focusId === "storage")
            return storageRect
        if (focusId === "local")
            return localRect
        return Qt.rect(0, 0, 0, 0)
    }

    function toggleFocus(id) {
        focusId = (focusId === id) ? "" : id
    }

    // Fonts: the four Satoshi faces, from Tokens.fontFiles. DeckSurface is at
    // v5/ and the paths in the token are relative to it, so Qt.resolvedUrl lands
    // on v5/fonts/Satoshi-*.ttf. DeckMain loads the same four for the shell
    // instance; a duplicate registration of the same file is harmless, and this
    // one is what makes an offscreen still Satoshi without Quickshell.
    FontLoader { source: Qt.resolvedUrl(Tokens.fontFiles["400"]) }
    FontLoader { source: Qt.resolvedUrl(Tokens.fontFiles["500"]) }
    FontLoader { source: Qt.resolvedUrl(Tokens.fontFiles["700"]) }
    FontLoader { source: Qt.resolvedUrl(Tokens.fontFiles["900"]) }

    // Small typographic pair. The deck owns its readouts (the gauges keep
    // showValue false) so every word on the surface is one size, one weight and
    // one place: a 16 px Medium label in textLabel, a 20 px Regular value in ink.
    component DeckLabel: Text {
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
        color: Tokens.textLabel
        horizontalAlignment: Text.AlignHCenter
    }

    component DeckValue: Text {
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: Tokens.sizeLabel
        color: Tokens.ink
        horizontalAlignment: Text.AlignHCenter
    }

    // ---- the focus environment -------------------------------------------
    // Everything the deck paints goes under `hudContent`, which Focus adopts and
    // captures. Focus does the dimming and blurring over HUD pixels only, so the
    // desktop behind the panel is never touched.
    Focus {
        id: focusLayer

        anchors.fill: parent
        active: deck.focusActive
        targetRect: deck.focusRect
        previewProgress: deck.stillFocusProgress
        content: hudContent
    }

    Item {
        id: hudContent

        anchors.fill: parent

        // ---------------------------------------------------------------- knot
        // W1's kit/Knot.qml is not on v5/main-deck yet (PR #51 is in a repair
        // round after the verifier's REPAIR verdict), so the slot is a plain
        // 540x540 Item sitting exactly on the guide. The layout, the word count,
        // the overlap audit and the render path are all real with it; only the
        // mark itself is missing, and a placeholder is NOT shippable. Swap in the
        // block below the moment `git fetch origin` shows kit/Knot.qml.
        Item {
            id: knot

            x: Tokens.knotCentreX - width / 2
            y: Tokens.knotCentreY - height / 2
            width: Tokens.knotDiameter
            height: Tokens.knotDiameter
        }

        // The real knot, one copy-paste away (I1 final form):
        //
        //   Knot {
        //       id: knot
        //       x: Tokens.knotCentreX - width / 2
        //       y: Tokens.knotCentreY - height / 2
        //       size: Tokens.knotDiameter
        //       accent: Tokens.azure          // s2 azure, per the W1 repair
        //       focusLevel: 0
        //       assembling: deck.assembling
        //       assembleProgress: deck.assembleProgress
        //       animate: deck.animate
        //   }

        // Everything that is not the knot drifts on the W7 helper: two sine
        // terms at an irrational ratio, amplitude and period from Motion, so the
        // deck is never fully still. The knot's own wander lives in its shader.
        IdleDrift {
            id: driftBand

            target: bandGroup
            amplitude: Motion.driftAmpMax
            period: Motion.driftPeriodMax
            previewTime: deck.benchPhase >= 0 ? deck.benchPhase : -1
            enabled: deck.animate
        }

        Item {
            id: bandGroup

            anchors.fill: parent

            // ------------------------------------------------------------ crew
            Item {
                id: crewGroup

                x: deck.marginX - deck.crewSize / 2
                y: deck.bandY - deck.crewSize / 2
                width: deck.crewSize
                height: deck.crewSize

                // Foot area: a click on the orb's empty space opens the sessions
                // view. The orb's own rows take their clicks first.
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: deck.toggleFocus("crew")
                }

                CrewOrb {
                    id: crewOrb

                    anchors.fill: parent
                    size: deck.crewSize
                    focusLevel: 0
                    expanded: deck.focusId === "crew"
                    sessions: deck.sessions
                    animate: deck.animate

                    onSessionActivated: function (sessionId) { deck.sessionActivated(sessionId) }
                }

                Column {
                    visible: deck.focusId !== "crew"
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height + Tokens.sp2
                    spacing: 0

                    DeckLabel { anchors.horizontalCenter: parent.horizontalCenter; text: "CREW" }
                    DeckValue {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.sessions.length > 0 ? String(deck.sessions.length) : ""
                    }
                }
            }

            // ------------------------------------------------- local AI (right)
            // The amendment's form for LOCAL AI is "a vertical level stack", not
            // a circle: this is DotBar rotated a quarter turn, so the lit dots
            // fill from the bottom like a level.
            Item {
                id: localGroup

                x: deck.rightX - deck.barWidth / 2
                y: deck.bandY - deck.barWidth / 2
                width: deck.barWidth
                height: deck.barWidth

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: deck.toggleFocus("local")
                }

                DotBar {
                    id: localStack

                    // A quarter turn makes the row a column: DotBar draws its lit
                    // dots from the left, so -90 puts them at the bottom.
                    size: deck.barWidth
                    segments: Tokens.dotBarSegments
                    level: Math.max(0, Math.min(1, deck.modelGb / Tokens.localBudgetGb))
                    accent: Tokens.acid
                    focusLevel: 0
                    anchors.centerIn: parent
                    rotation: -90
                }

                Column {
                    visible: deck.focusId !== "local"
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height + Tokens.sp3
                    spacing: 0

                    DeckLabel { anchors.horizontalCenter: parent.horizontalCenter; text: "LOCAL" }
                    DeckValue {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.modelGb > 0 ? deck.modelGb.toFixed(1) + " GB" : ""
                    }
                }
            }

            // ------------------------------------------------------------ mac
            // Amendment: "MAC as a dot-matrix or segmented bar field". Two
            // stacked dot-bars: the tunnel RTT on top, the Mac's load under it.
            Item {
                id: macGroup

                x: deck.marginX - deck.barWidth / 2
                y: deck.lowerY - deck.barHeight - Tokens.sp2
                width: deck.barWidth
                height: deck.barHeight * 2 + Tokens.sp2

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: deck.toggleFocus("mac")
                }

                DotBar {
                    id: macRtt

                    y: 0
                    size: deck.barWidth
                    segments: Tokens.dotBarSegments
                    // 0 to 120 ms across the bar; amber at or above the s2 warn
                    // line, which is what PulseRing's own threshold rule uses.
                    level: Math.max(0, Math.min(1, deck.rttMs / (Tokens.rttWarnMs * 1.2)))
                    accent: deck.rttMs >= Tokens.rttWarnMs ? Tokens.amber : Tokens.ice
                    focusLevel: 0
                }

                DotBar {
                    id: macLoad

                    y: deck.barHeight + Tokens.sp2
                    size: deck.barWidth
                    segments: Tokens.dotBarSegments
                    level: Math.max(0, Math.min(1, deck.loadLevel))
                    accent: Tokens.ice
                    focusLevel: 0
                }

                Column {
                    visible: deck.focusId !== "mac"
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height + Tokens.sp2
                    spacing: 0

                    DeckLabel { anchors.horizontalCenter: parent.horizontalCenter; text: "MAC" }
                    DeckValue {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.rttMs > 0 ? Math.round(deck.rttMs) + " ms" : ""
                    }
                }
            }

            // -------------------------------------------------------- storage
            // Amendment: "STORAGE as stacked dot-bars or a squared cell grid".
            // One bar per disk; the cell grid is what two rows read as.
            Item {
                id: storageGroup

                x: deck.rightX - deck.barWidth / 2
                y: deck.lowerY - deck.barHeight - Tokens.sp2
                width: deck.barWidth
                height: deck.barHeight * 2 + Tokens.sp2

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: deck.toggleFocus("storage")
                }

                DotBar {
                    id: diskA

                    y: 0
                    size: deck.barWidth
                    segments: Tokens.dotBarSegments
                    level: deck.disks.length > 0 ? deck.disks[0].used : 0
                    accent: Tokens.azure
                    focusLevel: 0
                }

                DotBar {
                    id: diskB

                    y: deck.barHeight + Tokens.sp2
                    size: deck.barWidth
                    segments: Tokens.dotBarSegments
                    level: deck.disks.length > 1 ? deck.disks[1].used : 0
                    accent: Tokens.azure
                    focusLevel: 0
                }

                Column {
                    visible: deck.focusId !== "storage"
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height + Tokens.sp2
                    spacing: 0

                    DeckLabel { anchors.horizontalCenter: parent.horizontalCenter; text: "STORAGE" }
                    DeckValue {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.disks.length > 0 ? deck.disks[0].usedGb + " GB" : ""
                    }
                }
            }
        }

        // ------------------------------------------------------- launcher, find
        // The right-hand chrome drifts too, on its own phase and the *minimum*
        // amplitude: "nothing on the deck is ever fully still". The 96 px clock
        // is the one exception - a wobble on type that large reads as broken
        // typography, not as life.
        Item {
            id: chromeGroup

            anchors.fill: parent

            IdleDrift {
                target: chromeGroup
                amplitude: Motion.driftAmpMin
                period: Motion.driftPeriodMin * Tokens.phi
                phaseOffset: 0.37
                previewTime: deck.benchPhase >= 0 ? deck.benchPhase : -1
                enabled: deck.animate
            }

            LauncherArc {
                id: launcher

                x: deck.launcherX
                y: deck.launcherY
                width: deck.launcherW
                height: deck.launcherH
                apps: deck.apps
                allApps: deck.allApps
                hero: deck.hero
                expanded: deck.focusId === "launcher"

                onLaunch: deck.launchRequested(slug)
            }

            FindField {
                id: findField

                x: deck.findX
                y: deck.findY
                width: deck.findBoxW
                active: deck.focusId === "find"
                query: deck.findQuery
                filter: deck.findFilter
                placeholder: "Find"

                onFilterRequested: deck.findFilter = requested
            }

            FindResults {
                id: findResults

                x: deck.findX + (deck.findBoxW - width) / 2
                y: deck.findY + deck.findFieldHeight + Tokens.sp3
                results: deck.findResults
                filter: deck.findFilter
                query: deck.findQuery
                visible: deck.focusId === "find"
            }
        }

        // ---------------------------------------------------------------- clock
        Clock {
            id: clock

            x: Tokens.centreX - width / 2
            y: deck.clockY
            time: deck.clockText
            pixelSize: deck.clockSize
            weight: Tokens.weightRegular
        }

        DeckLabel {
            id: dayLabel

            visible: text !== ""
            anchors.right: clock.left
            anchors.rightMargin: Tokens.sp4
            anchors.verticalCenter: clock.verticalCenter
            text: deck.dayText
        }

        DeckLabel {
            id: dateLabel

            visible: text !== ""
            anchors.left: clock.right
            anchors.leftMargin: Tokens.sp4
            anchors.verticalCenter: clock.verticalCenter
            text: deck.dateText
        }

        // ---- deep views -----------------------------------------------------
        // Each one is the focused widget's next level, drawn where the widget is.
        // They only exist while that widget has focus, so nothing here is part of
        // the rest layout or the rest word count.

        // MAC: the link explorer's first level - the RTT ring, the battery arc
        // and the load bar, which are the three gauges s2 drew as one ring.
        Item {
            id: macDeep

            visible: deck.focusId === "mac"
            x: deck.marginX - 300
            y: deck.lowerY + Tokens.sp5
            width: 600
            height: 300

            PulseRing {
                id: macRing

                x: 0
                y: 0
                size: 156
                value: deck.rttMs
                accent: Tokens.ice
                focusLevel: 0
            }

            DotArc {
                id: macBattery

                x: 156 + Tokens.sp5
                y: 6
                size: 144
                level: deck.batteryLevel
                accent: Tokens.acid
                focusLevel: 0
            }

            DeckLabel {
                anchors.left: macRing.left
                anchors.top: macRing.bottom
                anchors.topMargin: Tokens.sp2
                width: macRing.width
                text: "RTT " + Math.round(deck.rttMs) + " ms"
            }

            DeckLabel {
                anchors.left: macBattery.left
                anchors.top: macBattery.bottom
                anchors.topMargin: Tokens.sp2
                width: macBattery.width
                text: "BAT " + Math.round(deck.batteryLevel * 100) + " %"
            }
        }

        // STORAGE: the disks. One dot-bar per disk with its name and used
        // percentage, plus the capacity arc for the busiest one.
        Item {
            id: storageDeep

            visible: deck.focusId === "storage"
            x: deck.rightX - 330
            y: deck.lowerY - 250
            width: 660
            height: 230

            Column {
                id: diskColumn

                y: 0
                width: parent.width
                spacing: Tokens.sp2

                Repeater {
                    model: deck.disks

                    Item {
                        id: diskRow

                        required property var modelData
                        required property int index

                        width: diskColumn.width
                        height: Tokens.sp4

                        DeckLabel {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: diskRow.modelData.label
                            horizontalAlignment: Text.AlignLeft
                        }

                        DotBar {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: 360
                            size: 360
                            segments: Tokens.dotBarSegments
                            level: diskRow.modelData.used
                            accent: Tokens.azure
                            focusLevel: 0
                        }
                    }
                }
            }

            DotArc {
                id: storageArc

                x: 0
                y: diskColumn.implicitHeight + Tokens.sp4
                size: 160
                level: deck.disks.length > 0 ? deck.disks[0].used : 0
                accent: Tokens.azure
                focusLevel: 0
            }
        }

        // LOCAL AI: the model as the W3 sphere next to the level stack that
        // stands in for it at rest, with the size and the activity that drive it.
        Item {
            id: localDeep

            visible: deck.focusId === "local"
            x: deck.rightX - 330
            y: deck.bandY - 160
            width: 660
            height: 320

            LocalOrb {
                id: modelOrb

                x: 0
                y: 0
                size: 200
                sizeGb: deck.modelGb
                activity: deck.modelActivity
                accent: Tokens.acid
                focusLevel: 0
            }

            DotBar {
                id: modelStack

                x: 200 + Tokens.sp6
                y: 0
                width: 60
                height: 320
                size: 320
                segments: Tokens.dotBarSegments
                level: Math.max(0, Math.min(1, deck.modelGb / Tokens.localBudgetGb))
                accent: Tokens.acid
                focusLevel: 0
                anchors.verticalCenter: modelOrb.verticalCenter
                rotation: -90
            }

            DeckLabel {
                anchors.left: modelOrb.left
                anchors.top: modelOrb.bottom
                anchors.topMargin: Tokens.sp2
                width: modelOrb.width
                text: "MODEL " + deck.modelGb.toFixed(1) + " GB"
            }
        }
    }

    // ---- input ------------------------------------------------------------
    // The deck owns the focus. A click on a widget's own area toggles it (the
    // widget's inner MouseAreas win where they exist), a click on empty space
    // returns to rest, and the keyboard walks the same six targets so the Linux
    // shell can drive it without a pointer.
    MouseArea {
        id: background

        anchors.fill: parent
        z: -1
        onClicked: deck.focusId = ""
    }

    Item {
        id: keyCatcher

        // Zero-size and click-through: a Keys handler needs active focus, not
        // an area. Sizing it would swallow every pointer event under it.
        width: 0
        height: 0
        focus: true

        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
                deck.focusId = ""
                event.accepted = true
            } else if (event.key === Qt.Key_C) {
                deck.toggleFocus("crew")
                event.accepted = true
            } else if (event.key === Qt.Key_F) {
                deck.toggleFocus("find")
                event.accepted = true
            } else if (event.key === Qt.Key_L) {
                deck.toggleFocus("launcher")
                event.accepted = true
            } else if (event.key === Qt.Key_M) {
                deck.toggleFocus("mac")
                event.accepted = true
            } else if (event.key === Qt.Key_S) {
                deck.toggleFocus("storage")
                event.accepted = true
            } else if (event.key === Qt.Key_A) {
                deck.toggleFocus("local")
                event.accepted = true
            }
        }
    }
}
