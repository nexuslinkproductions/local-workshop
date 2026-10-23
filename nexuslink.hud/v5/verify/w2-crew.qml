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
        { "id": "a1d052", "parent": null, "model": "sonnet-5-5",
          "tokens": 139559, "idle_s": 20, "title": "Enable marcel-mode",
          "activity": "delegate_task: subagent receiving stream response" },
        { "id": "a01748", "parent": null, "model": "sonnet-5-5",
          "tokens": 125381, "idle_s": 32, "title": "Draft vari8-beta issues",
          "activity": "starting new turn" },
        { "id": "683c2c", "parent": "a1d052", "model": "sonnet-5-5",
          "tokens": 3645, "idle_s": 17,
          "title": "Composition study s1: widget-and-icon-first HUD",
          "activity": "receiving stream response" },
        { "id": "b2e810", "parent": null, "model": "deepseek-v4.1-flash",
          "tokens": 92140, "idle_s": 640,
          "title": "HUD verify WS-05", "activity": "" },
        { "id": "c4a19f", "parent": "b2e810", "model": "deepseek-v4.1-flash",
          "tokens": 18300, "idle_s": 3120, "title": "Token ring geometry",
          "activity": "" },
        { "id": "d90c33", "parent": null, "model": "opus-4-6",
          "tokens": 210400, "idle_s": 12500, "title": "Knot shader pass two",
          "activity": "" },
        { "id": "e5510b", "parent": null, "model": "sonnet-5-5",
          "tokens": 7400, "idle_s": 260, "title": "Satoshi weight audit",
          "activity": "" }
    ]

    // Real sample: trimmed copy of ~/.local/state/nexuslink/crew.json
    // (first 8 bots, 6 events each) inlined because a synchronous
    // XMLHttpRequest for file:// returns nothing under the offscreen run.
    readonly property var realCrew: ({"generated":1792712695,"bots":[{"name":"default","model":"claude-haiku-5-5","provider":"anthropic","state":"active","last_active":1792712683.9148276,"sessions_24h":130,"calls_24h":4048,"tokens_24h":498215119,"current_title":"Subagent: Independent review and test re-run of the\u2026","events":[[1792712229.2172868,1792712436.5545306,"Subagent: Find out why the seeded client is denied in the\u2026"],[1792711769.4451973,null,"Subagent: Independent review and test re-run of the\u2026"],[1792711632.2540247,1792711715.842919,"Subagent: Build an auto-login proxy so the owner can open\u2026"],[1792710881.4993587,1792712090.7568185,"Subagent: Extract Lilly's real tracker style into a\u2026"],[1792710880.4041128,1792711341.3914757,"Subagent: Implement the proper gateway fix for the stale\u2026"],[1792710449.6821053,1792711408.6748006,"Subagent: Serve the Vari8-Beta root app as it would look\u2026"]]},{"name":"atlas","model":"claude-haiku-5-5","provider":"anthropic","state":"dormant","last_active":1791644891.424624,"sessions_24h":0,"calls_24h":0,"tokens_24h":0,"current_title":"Claude handle and model identity","events":[]},{"name":"ban","model":"claude-sonnet-5-5","provider":"anthropic","state":"dormant","last_active":1792086389.74143,"sessions_24h":0,"calls_24h":0,"tokens_24h":0,"current_title":"WTM-PROLOGUE-VERIFY-BAN","events":[]},{"name":"chief","model":"minicpm-v47","provider":"custom","state":"dormant","last_active":1791916939.9067612,"sessions_24h":0,"calls_24h":0,"tokens_24h":0,"current_title":null,"events":[]},{"name":"chief-a0","model":"ornith-chief","provider":"custom","state":"dormant","last_active":1791927846.9896612,"sessions_24h":0,"calls_24h":0,"tokens_24h":0,"current_title":null,"events":[]},{"name":"chief-v3","model":"ornith-chief-v3","provider":"local-ai","state":"dormant","last_active":null,"sessions_24h":0,"calls_24h":0,"tokens_24h":0,"current_title":null,"events":[]},{"name":"gowther","model":"deepseek-v4.1-flash","provider":"opencode-go","state":"idle","last_active":1792700541.69989,"sessions_24h":3,"calls_24h":4,"tokens_24h":62222,"current_title":"Reply with exactly PONG #2","events":[[1792700541.541604,1792700543.7991958,"Reply with exactly PONG #2"],[1792694817.090532,1792694830.8787956,"PROBE-PONG-HANDOFF"],[1792694791.441667,1792694795.9877937,"Reply with exactly PONG"]]},{"name":"hermes-slack","model":"deepseek-v4.1-flash","provider":"opencode-go","state":"idle","last_active":1792648858.9527721,"sessions_24h":1,"calls_24h":6,"tokens_24h":196325,"current_title":"morning-brief \u00b7 Oct 22 08:00","events":[[1792648802.5809467,1792648858.9527721,"morning-brief \u00b7 Oct 22 08:00"]]}],"totals":{"bots":30,"active":2,"warm":0,"idle":8,"dormant":20,"sessions_24h":164,"calls_24h":4194,"tokens_24h":506218957}})

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
