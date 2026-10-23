import QtQuick
import QtTest

// tst_input_clicks.qml - pointer clicks on the composed s10 deck.
//
// Composes the scene the way HudV4 does for the command window (full bleed):
// an opaque base, the Environment slot under it, and DeckView with
// underEnvironment true. Synthetic mouse clicks land on the widget centres and
// the Find pill centre, then the deck's own state is read back.
//
// Run (offscreen, software, low priority):
//   env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic \
//     nice -n 19 ionice -c3 /usr/lib/qt6/bin/qmltestrunner -maxwarnings 0 \
//     -input nexuslink.hud/v5/verify/tst_input_clicks.qml
//
// Centres are deck coordinates (2560 x 1440). Find pill rest centre: the rest
// pill is drawn at 1960,338 (380 x 68) and FindPill's overlay sits at 40,-42.
TestCase {
    id: test
    name: "InputClicks"
    when: windowShown
    width: 2560
    height: 1440

    Window {
        id: win
        width: 2560
        height: 1440
        visible: true

        Rectangle {
            anchors.fill: parent
            color: "#06080a"
        }

        Loader {
            id: envHost
            anchors.fill: parent
            source: Qt.resolvedUrl("../live/Environment.qml")
        }

        Loader {
            id: deckLoader
            anchors.fill: parent
            source: Qt.resolvedUrl("../live/DeckView.qml")
            onLoaded: {
                item.autoTick = true
                item.shown = true
                item.underEnvironment = true
                item.crew = ({})
            }
        }
    }

    property var deck: deckLoader.item

    function centre(it) {
        return { x: it.x + it.width / 2, y: it.y + it.height / 2 }
    }

    function test_01_find_pill_click_opens() {
        wait(100)
        verify(deck !== null, "deck loaded")
        compare(deck.findOpen, false)
        // rest pill centre: 1960 + 40 + 190, 338 - 42 + 34
        mouseClick(win.contentItem, 2190, 330)
        wait(120)
        compare(deck.findOpen, true)
    }

    function test_02_crew_click_expands() {
        deck.findOpen = false
        deck.view = ""
        wait(400)
        var c = centre(deck.crewWidget)
        mouseClick(win.contentItem, c.x, c.y)
        wait(120)
        compare(deck.view, "crew")
    }

    function test_03_mac_click_reaches_widget() {
        deck.view = ""
        wait(400)
        var clicks = macSpy.count
        var c = centre(deck.macWidget)
        mouseClick(win.contentItem, c.x, c.y)
        wait(60)
        compare(macSpy.count, clicks + 1)
    }

    // Fixture link (same shape as fixtures/link.json) with a fresh timestamp.
    function freshLink(n, ageS) {
        var s = []
        for (var i = 0; i < n; i++)
            s.push(4 + (i * 7) % 40)
        s[5] = 92
        return {
            ts: Date.now() / 1000 - (ageS || 0),
            route: "direct", tunnel: "active",
            rtt_ms: { last: 5, median: 7.5, min: 4, max: 92, samples: s },
            mac: { batt: 100, state: "charged", rem: null, load: [3.94, 4.45, 4.81],
                   up_min: 13, thermal: "nominal",
                   kanban: { running: 0, ready: 1, blocked: 15 } }
        }
    }

    function test_04_mac_click_expands() {
        deck.view = ""
        deck.link = freshLink(60, 0)
        wait(400)
        var c = centre(deck.macWidget)
        mouseClick(win.contentItem, c.x, c.y)
        wait(500)
        compare(deck.view, "mac")
    }

    function test_05_mac_view_shows_fresh_link() {
        deck.view = ""
        deck.link = freshLink(60, 0)
        wait(400)
        deck.view = "mac"
        wait(500)
        var p = deck.macPanelItem
        verify(p !== null, "mac panel loaded")
        compare(p.linkState, "fresh")
        compare(p.shownSamples, 60)
        compare(p.thermalText, "nominal")
        compare(p.kanbanState, "ok")
        verify(p.wordCount < 40, "under 40 words at rest, got " + p.wordCount)
    }

    function test_06_mac_view_stale_and_error() {
        deck.view = ""
        deck.link = freshLink(60, 60)
        wait(400)
        deck.view = "mac"
        wait(500)
        compare(deck.macPanelItem.linkState, "stale")
        deck.view = ""
        deck.link = null
        wait(400)
        deck.view = "mac"
        wait(500)
        compare(deck.macPanelItem.linkState, "error")
        compare(deck.macPanelItem.heroText, "")
    }

    function test_07_mac_dismiss_click_closes() {
        deck.link = freshLink(60, 0)
        deck.view = "mac"
        wait(500)
        mouseClick(win.contentItem, 100, 1300)
        wait(120)
        compare(deck.view, "")
    }

    SignalSpy {
        id: macSpy
        target: deck ? deck.macWidget : null
        signalName: "clicked"
    }
}
