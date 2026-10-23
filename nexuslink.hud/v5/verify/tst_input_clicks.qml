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

    SignalSpy {
        id: macSpy
        target: deck ? deck.macWidget : null
        signalName: "clicked"
    }
}
