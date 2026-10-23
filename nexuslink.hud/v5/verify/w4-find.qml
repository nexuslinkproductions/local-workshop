import QtQuick
import "../kit"
import "../live"

Item {
    id: scene
    width: 2240
    height: 700

    property real tick: 12.3

    FontLoader { source: Qt.resolvedUrl("../../../../nexuslink.hud/v5/fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../../../../nexuslink.hud/v5/fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../../../../nexuslink.hud/v5/fonts/Satoshi-Bold.ttf") }
    FontLoader { source: Qt.resolvedUrl("../../../../nexuslink.hud/v5/fonts/Satoshi-Black.ttf") }

    property var hits: [{"title": "02-plan \u2014 what we change, and who does it", "path": "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/OMARCHY-HUD/02-plan/CONTEXT.md", "kind": "md", "score": -20.57513182264395}, {"title": "03-build \u2014 does it work on the live desktop", "path": "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/OMARCHY-HUD/03-build/CONTEXT.md", "kind": "md", "score": -20.57376316637231}, {"title": "01-research \u2014 what is actually there today", "path": "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/OMARCHY-HUD/01-research/CONTEXT.md", "kind": "md", "score": -20.57090612653431}, {"title": "CONTEXT.md \u2014 route through the pipeline", "path": "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/OMARCHY-HUD/CONTEXT.md", "kind": "md", "score": -20.568798474874256}, {"title": "NEXUS System HUD (`nexuslink.hud`)", "path": "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/README.md", "kind": "md", "score": -18.40287217559387}, {"title": "nexuslink.hud verification harness", "path": "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/verify/README.md", "kind": "md", "score": -18.161862677676453}, {"title": "HANDOFF \u2014 Omarchy background HUD, phase 3 (frontend + Hermes integration)", "path": "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/OMARCHY-HUD/02-plan/references/HANDOFF-HUD.md", "kind": "md", "score": -17.7656004262108}]

    Rectangle { anchors.fill: parent; color: Tokens.field }

    Repeater {
        model: 4
        delegate: Rectangle {
            x: index * 560
            y: 0
            width: 560
            height: 700
            color: Tokens.field
            Rectangle { x: 0; y: 0; width: 560; height: 1; color: Tokens.ice; opacity: 0.10 }
        }
    }

    // 1 rest
    FindPill {
        x: 30; y: 30
        width: 504; height: 640
        tick: scene.tick
        open: false
        query: ""
    }

    // 2 typing hud, chips
    FindPill {
        x: 590; y: 30
        width: 504; height: 640
        tick: scene.tick
        open: true
        query: "hud"
        filter: "all"
        busy: true
    }

    // 3 results from the real yuri sample
    FindPill {
        x: 1150; y: 30
        width: 504; height: 640
        tick: scene.tick
        open: true
        query: "hud"
        filter: "all"
        results: scene.hits
    }

    // 4 nothing found
    FindPill {
        x: 1710; y: 30
        width: 504; height: 640
        tick: scene.tick
        open: true
        query: "zzqx"
        filter: "downloads"
        results: []
    }

    Timer {
        interval: 900
        running: true
        onTriggered: scene.grabToImage(function(r) {
            r.saveToFile("/home/nexuslink/.hermes/cache/scratch/hud-live/work/W4/w4-find.png");
            Qt.quit();
        })
    }
}
