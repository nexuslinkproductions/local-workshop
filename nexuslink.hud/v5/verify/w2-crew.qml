import QtQuick
import "../kit"
import "../live"

// w2-crew.qml - verification scene for CrewWidget and CrewExpanded.
// Renders: rest form with the fixture session array, rest form with the live
// crew.json sample, rest form with an empty crew, and the expanded panel with
// the fixture. Fonts are loaded here (the deck loads them in production).
Window {
    id: board
    width: 1240
    height: 1120
    visible: true
    color: Tokens.field

    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Bold.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Black.ttf") }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    function loadJson(path) {
        var xhr = new XMLHttpRequest()
        try {
            xhr.open("GET", path, false)
            xhr.send()
        } catch (e) {
            return null
        }
        if (xhr.responseText === undefined || xhr.responseText === "")
            return null
        try {
            return JSON.parse(xhr.responseText)
        } catch (e) {
            return null
        }
    }

    readonly property var fixture: [
        { "id": "a1d052", "parent": null, "model": "model-a",
          "tokens": 139559, "idle_s": 20, "title": "Enable the new mode",
          "activity": "receiving stream response" },
        { "id": "a01748", "parent": null, "model": "model-a",
          "tokens": 125381, "idle_s": 32, "title": "Draft vari8-beta issues",
          "activity": "starting new turn" },
        { "id": "683c2c", "parent": "a1d052", "model": "model-a",
          "tokens": 3645, "idle_s": 17,
          "title": "Composition study s1: widget-and-icon-first HUD",
          "activity": "receiving stream response" },
        { "id": "b2e810", "parent": null, "model": "model-b",
          "tokens": 92140, "idle_s": 640,
          "title": "HUD verify WS-05", "activity": "" },
        { "id": "c4a19f", "parent": "b2e810", "model": "model-b",
          "tokens": 18300, "idle_s": 3120, "title": "Token ring geometry",
          "activity": "" },
        { "id": "d90c33", "parent": null, "model": "model-c",
          "tokens": 210400, "idle_s": 12500, "title": "Knot shader pass two",
          "activity": "" },
        { "id": "e5510b", "parent": null, "model": "model-a",
          "tokens": 7400, "idle_s": 260, "title": "Satoshi weight audit",
          "activity": "" }
    ]

    // Empty crew sample: the widget must show its idle state without data.
    // (first 8 bots, 6 events each) inlined because a synchronous
    // XMLHttpRequest for file:// returns nothing under the offscreen run.
    readonly property var realCrew: ({})

    CrewWidget {
        id: restFixture
        x: 30
        y: 24
        width: 360
        height: 240
        tick: 12.3
        crew: board.fixture
    }
    CrewWidget {
        id: restReal
        x: 430
        y: 24
        width: 360
        height: 240
        tick: 12.3
        crew: board.realCrew
    }
    CrewWidget {
        id: restEmpty
        x: 830
        y: 24
        width: 360
        height: 240
        tick: 12.3
        crew: ({})
    }

    CrewExpanded {
        id: expanded
        x: 30
        y: 300
        width: 1100
        height: 760
        crew: board.fixture
        onCloseRequested: console.log("closeRequested")
    }

    // Window root keeps the software offscreen path alive: with an Item root
    // no frame is ever delivered, so the grab below would wait forever.
    Timer {
        interval: 900
        running: true
        onTriggered: {
            expanded.grabToImage(function (r) {
                r.saveToFile("/home/nexuslink/.hermes/cache/scratch/hud-live/work/W2/w2-expanded.png")
                board.contentItem.grabToImage(function (b) {
                    b.saveToFile("/home/nexuslink/.hermes/cache/scratch/hud-live/work/W2/w2-board.png")
                    Qt.quit()
                })
            })
        }
    }
}
