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
//   clock     100 px Light numerals, centred at x 1280, y 96
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
// * "CLOCK TOO BIG ... about 96 px numerals" was amended twice: first to 135,
//   then Marcel called 135 too big and asked for about 100 px thin numerals.
//   Tokens.sizeClock (168) is the s1 ramp size; the deck clock reads
//   Tokens.sizeClockDeck (100) at Tokens.weightLight, so the token carries the
//   deck value instead of a literal in this file.
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
    property bool findBusy: false
    property string findNote: ""
    property string findHome: ""
    // Find: typed text leaves as findQueryEdited (debounced 120 ms; also once per
    // filter chip). Enter on a hit emits findOpenRequested with the feed path.
    signal findQueryEdited(string text)
    signal findOpenRequested(string path)
    readonly property bool wantsKeyboard: focusId === "find"
    readonly property int findSelected: findResults.selected
    property real rttMs: 0
    property real batteryLevel: 0
    property real loadLevel: 0
    property real modelGb: 0
    property real modelActivity: 0
    property var disks: []
    // Feed freshness (s2, SHARED3 rule c). feedStale[id] true means the readout
    // must not show a number (it shows "--" and dims). feedAge[id] is "3m" or
    // "45s" while the feed is stale, and "" otherwise.
    property var feedStale: ({})
    property var feedAge: ({})
    function isStale(id) { return feedStale[id] === true }
    function staleText(id) { return String(feedAge[id] || "") }

    // Readout probe (s2, for the stale scenario and tests): what each feed
    // readout shows now. text is the numeral, label the STALE mark ("" if none).
    readonly property var readoutProbe: ({
        "sessions": { "text": crewValue.text, "opacity": crewGroup.opacity, "label": staleText("sessions") !== "" ? "STALE " + staleText("sessions") : "" },
        "metrics": { "text": localValue.text, "opacity": localGroup.opacity, "label": staleText("metrics") !== "" ? "STALE " + staleText("metrics") : "" },
        "link": { "text": macValue.text, "opacity": macGroup.opacity, "label": staleText("link") !== "" ? "STALE " + staleText("link") : "" },
        "disks": { "text": storageValue.text, "opacity": storageGroup.opacity, "label": staleText("disks") !== "" ? "STALE " + staleText("disks") : "" }
    })
    property bool assembling: false
    property real assembleProgress: 1

    // ---- bottom chrome inputs and outputs (lead pre-wired, owners Q and M) ---
    // Media comes from DeckMain (Quickshell Mpris). The quick actions and the
    // pill only emit; DeckMain maps the ids to commands.
    property string mediaTitle: ""
    property string mediaArtist: ""
    property bool mediaPlaying: false
    property bool mediaAvailable: false
    signal quickActionRequested(string actionId)
    signal mediaToggleRequested()

    // Stills and probes set animate:false so a render is deterministic; the
    // shell leaves it true.
    property bool animate: true
    // Shell hook: the panel is 2560x1440 on the DP-2 and 1:1; anything else is
    // drawn at its own size, which is a still, not the deck.
    //
    // Two properties, because both sides write focus: `focusRequest` is what the
    // shell binds (IPC, keybinding, session activation) and `focusId` is the
    // deck's own state, set by a click or a key. Binding one property and also
    // assigning it locally would drop the shell's binding on the first click, so
    // the shell writes the request and listens to `deckFocusChanged` for the rest.
    property string focusRequest: ""
    property string focusId: ""
    signal deckFocusChanged(string id)

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
    // Find is a full-deck overlay in absolute coordinates (s3-find-results.png):
    // the rest pill at 1960, 338; the open pill at 830, 226, 900 wide.
    // Clock: 100 px Light numerals (Tokens.sizeClockDeck), not the 168 px ramp.
    readonly property int clockSize: Tokens.sizeClockDeck
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
    // Crisp area while Find is open: the pill, the filter row and the hits.
    readonly property rect findRect: Qt.rect(420, 210, 1780, 1010)
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

    function toggleFocus(target) {
        focusId = (focusId === target) ? "" : target
        deckFocusChanged(focusId)
    }

    function clearFocus() {
        if (focusId === "")
            return
        focusId = ""
        deckFocusChanged("")
    }

    onFocusRequestChanged: {
        if (focusRequest !== focusId)
            focusId = focusRequest
    }

    Component.onCompleted: {
        if (focusRequest !== "" && focusRequest !== focusId)
            focusId = focusRequest
    }

    // Find owns its input: opening focuses the field; closing releases it and
    // hands the keys back to the deck catcher.
    onFocusIdChanged: {
        if (focusId === "find") {
            findField.focusInput()
        } else {
            findField.releaseFocus()
            keyCatcher.forceActiveFocus()
        }
    }

    // Fonts. The four Satoshi faces, from Tokens.fontFiles. This is the only
    // place the deck loads them: DeckMain.qml is the Quickshell layer and owns
    // no FontLoader, because every render that is not the live shell (the still
    // harness today, an offscreen gate on Linux tomorrow) composes DeckSurface
    // directly and would otherwise fall back to another face - and then every
    // number measured on that render is measured against the wrong metrics.
    // DeckSurface lives at v5/ and the token paths are relative to it, so
    // Qt.resolvedUrl lands on v5/fonts/Satoshi-*.ttf. A kit component loaded
    // through the module import path resolves ../fonts instead, so the tools
    // that build that path (deck-shot.sh, deck-audit.py, deck-trace.py) mirror
    // v5/fonts to <imports>/NexusHud/fonts. tests/i1/DeckAudit.qml fails the
    // audit if a painted Text carries the fallback advance rather than Satoshi's.
    FontLoader { source: Qt.resolvedUrl(Tokens.fontFiles["300"]) }
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
        // W1's Knot.qml, the 540 px triquetra on the s2 trace, centred on
        // Tokens.knotCentreX/Y (1280, 550) as the layout asks. Its default accent
        // is Tokens.ice; s2's mark is azure-to-ice, and the repair round moved the
        // dot field back to s2, so the deck leaves the accent at the component's
        // own default rather than tinting it from here.
        Knot {
            id: knot

            x: Tokens.knotCentreX - width / 2
            y: Tokens.knotCentreY - height / 2
            size: Tokens.knotDiameter
            focusLevel: 0
            assembling: deck.assembling
            assembleProgress: deck.assembleProgress
            animate: deck.animate
        }

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
                opacity: deck.isStale("sessions") ? 0.45 : 1

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
                    sessions: deck.isStale("sessions") ? [] : deck.sessions
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
                        id: crewValue
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.isStale("sessions") ? "--" : (deck.sessions.length > 0 ? String(deck.sessions.length) : "")
                    }
                    StaleMark {
                        id: staleCrew
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: String(deck.feedAge.sessions || "") !== ""
                        label: "STALE " + String(deck.feedAge.sessions || "")
                    }
                }
            }

            // ------------------------------------------------- local AI (right)
            // The amendment's form for LOCAL AI is "a vertical level stack", not
            // a circle: this is DotBar rotated a quarter turn, so the lit dots
            // fill from the bottom like a level.
            Item {
                id: localGroup
                opacity: deck.isStale("metrics") ? 0.45 : 1

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
                        id: localValue
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.isStale("metrics") ? "--" : (deck.modelGb > 0 ? deck.modelGb.toFixed(1) + " GB" : "")
                    }
                    StaleMark {
                        id: staleLocal
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: String(deck.feedAge.metrics || "") !== ""
                        label: "STALE " + String(deck.feedAge.metrics || "")
                    }
                }
            }

            // ------------------------------------------------------------ mac
            // Amendment: "MAC as a dot-matrix or segmented bar field". Two
            // stacked dot-bars: the tunnel RTT on top, the Mac's load under it.
            Item {
                id: macGroup
                opacity: deck.isStale("link") ? 0.45 : 1

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
                        id: macValue
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.isStale("link") ? "--" : (deck.rttMs > 0 ? Math.round(deck.rttMs) + " ms" : "")
                    }
                    StaleMark {
                        id: staleMac
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: String(deck.feedAge.link || "") !== ""
                        label: "STALE " + String(deck.feedAge.link || "")
                    }
                }
            }

            // -------------------------------------------------------- storage
            // Amendment: "STORAGE as stacked dot-bars or a squared cell grid".
            // One bar per disk; the cell grid is what two rows read as.
            Item {
                id: storageGroup
                opacity: deck.isStale("disks") ? 0.45 : 1

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
                        id: storageValue
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: deck.isStale("disks") ? "--" : (deck.disks.length > 0 ? deck.disks[0].usedGb + " GB" : "")
                    }
                    StaleMark {
                        id: staleStorage
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: String(deck.feedAge.disks || "") !== ""
                        label: "STALE " + String(deck.feedAge.disks || "")
                    }
                }
            }
        }

        // ------------------------------------------------------- launcher, find
        // The right-hand chrome drifts too, on its own phase and the *minimum*
        // amplitude: "nothing on the deck is ever fully still". The 100 px clock
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

                opacity: deck.isStale("apps") ? 0.45 : 1
                onLaunch: function (launcherSlug) { deck.launchRequested(launcherSlug) }
            }

            // apps feed stale: the tiles dim and the mark shows (SHARED3 rule c).
            StaleMark {
                x: deck.launcherX
                y: deck.launcherY - Tokens.sp4
                visible: deck.staleText("apps") !== ""
                label: "STALE " + deck.staleText("apps")
            }

            // Find: full deck size, absolute coordinates. FindField owns the pill,
            // the filter words and the typed text; FindResults owns the hits.
            FindField {
                id: findField

                anchors.fill: parent
                active: deck.focusId === "find"
                query: deck.findQuery
                filter: deck.findFilter
                busy: deck.findBusy
                note: deck.findNote
                placeholder: "Find"

                onOpenRequested: deck.toggleFocus("find")
                onQueryEdited: function (text) { deck.findQueryEdited(text) }
                onFilterRequested: function (requestedFilter) {
                    deck.findFilter = requestedFilter
                    deck.findQueryEdited(findField.typedText)
                }
                onNavigateRequested: function (dx, dy) {
                    if (dy === 0)
                        findResults.moveSelection(dx)
                    else
                        findResults.moveRow(dy)
                }
                onActivateRequested: findResults.activateSelected()
                onCloseRequested: {
                    findField.clearText()
                    deck.clearFocus()
                    deck.findQueryEdited("")
                }
            }

            FindResults {
                id: findResults

                anchors.fill: parent
                results: deck.findResults
                query: deck.findQuery
                active: deck.focusId === "find"
                busy: deck.findBusy
                homeDir: deck.findHome

                onHitActivated: function (path) {
                    deck.findOpenRequested(path)
                    deck.clearFocus()
                }
            }

            // ---- bottom chrome (lead pre-wired; bodies are owned by Q and M) ----
            // OWNER Q: QuickActions fills the deck and places its five icons itself.
            QuickActions {
                id: quickActions

                anchors.fill: parent
                mediaPlaying: deck.mediaPlaying
                mediaAvailable: deck.mediaAvailable

                onActionRequested: function (actionId) { deck.quickActionRequested(actionId) }
            }

            // OWNER M: MediaPill. Position is the e-rest.png value (250, 1284);
            // M may move it into Tokens and patch these two lines.
            MediaPill {
                id: mediaPill

                x: 250
                y: 1284
                title: deck.mediaTitle
                artist: deck.mediaArtist
                playing: deck.mediaPlaying
                available: deck.mediaAvailable

                onToggleRequested: deck.mediaToggleRequested()
            }
        }

        // ---------------------------------------------------------------- clock
        Clock {
            id: clock

            x: Tokens.centreX - width / 2
            y: deck.clockY
            time: deck.clockText
            pixelSize: deck.clockSize
            weight: Tokens.weightLight
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
            opacity: deck.isStale("link") ? 0.45 : 1
            x: deck.marginX - 300
            y: deck.lowerY + Tokens.sp5
            width: 600
            height: 300

            PulseRing {
                id: macRing

                x: 0
                y: 0
                size: 156
                value: deck.isStale("link") ? 0 : deck.rttMs
                accent: Tokens.ice
                focusLevel: 0
            }

            DotArc {
                id: macBattery

                x: 156 + Tokens.sp5
                y: 6
                size: 144
                level: deck.isStale("link") ? 0 : deck.batteryLevel
                accent: Tokens.acid
                focusLevel: 0
            }

            DeckLabel {
                anchors.left: macRing.left
                anchors.top: macRing.bottom
                anchors.topMargin: Tokens.sp2
                width: macRing.width
                text: deck.isStale("link") ? "RTT --" : "RTT " + Math.round(deck.rttMs) + " ms"
            }

            DeckLabel {
                anchors.left: macBattery.left
                anchors.top: macBattery.bottom
                anchors.topMargin: Tokens.sp2
                width: macBattery.width
                text: deck.isStale("link") ? "BAT --" : "BAT " + Math.round(deck.batteryLevel * 100) + " %"
            }

            StaleMark {
                x: 0
                y: 260
                visible: deck.staleText("link") !== ""
                label: "STALE " + deck.staleText("link")
            }
        }

        // STORAGE: the disks. One dot-bar per disk with its name and used
        // percentage, plus the capacity arc for the busiest one.
        Item {
            id: storageDeep

            visible: deck.focusId === "storage"
            opacity: deck.isStale("disks") ? 0.45 : 1
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

                        width: parent.width
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
                level: deck.isStale("disks") ? 0 : (deck.disks.length > 0 ? deck.disks[0].used : 0)
                accent: Tokens.azure
                focusLevel: 0
            }

            StaleMark {
                x: 200
                y: diskColumn.implicitHeight + Tokens.sp4
                visible: deck.staleText("disks") !== ""
                label: "STALE " + deck.staleText("disks")
            }
        }

        // LOCAL AI: the model as the W3 sphere next to the level stack that
        // stands in for it at rest, with the size and the activity that drive it.
        Item {
            id: localDeep

            visible: deck.focusId === "local"
            opacity: deck.isStale("metrics") ? 0.45 : 1
            x: deck.rightX - 330
            y: deck.bandY - 160
            width: 660
            height: 320

            LocalOrb {
                id: modelOrb

                x: 0
                y: 0
                size: 200
                sizeGb: deck.isStale("metrics") ? 0 : deck.modelGb
                activity: deck.isStale("metrics") ? 0 : deck.modelActivity
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
                level: deck.isStale("metrics") ? 0 : Math.max(0, Math.min(1, deck.modelGb / Tokens.localBudgetGb))
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
                text: deck.isStale("metrics") ? "MODEL -- GB" : "MODEL " + deck.modelGb.toFixed(1) + " GB"
            }

            StaleMark {
                x: 200 + Tokens.sp6 + 80
                y: 0
                visible: deck.staleText("metrics") !== ""
                label: "STALE " + deck.staleText("metrics")
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
        onClicked: deck.clearFocus()
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
                deck.clearFocus()
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
