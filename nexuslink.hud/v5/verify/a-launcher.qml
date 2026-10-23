import QtQuick
import "../kit"
import "../live"

// a-launcher.qml - offscreen check scene for the launcher arc.
// Top: rest. Bottom: forced hover on tile 4 (the Chromium slot).
// Apps mirror the 11 entries of assets/apps.json in the same order (5 + hero +
// 5, OBS Studio last left of the hero), inlined here because this scene renders
// without file IO. tst_launcher_symmetry.qml reads the real file.
Item {
    id: scene
    width: 1400
    height: 540

    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Bold.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Black.ttf") }

    property var apps: [
        { id: "hermes", name: "Hermes", glyph: "hermes", launches: 3, running: true },
        { id: "devin", name: "Devin", glyph: "devin", launches: 8, running: false },
        { id: "files", name: "Files", glyph: "files", launches: 2, running: false },
        { id: "terminal", name: "Terminal", glyph: "terminal", launches: 0, running: false },
        { id: "chromium", name: "Chromium", glyph: "chrome", launches: 0, running: false },
        { id: "discord", name: "Discord", glyph: "discord", launches: 3, running: false },
        { id: "x", name: "X", glyph: "x", launches: 0, running: false },
        { id: "youtube", name: "YouTube", glyph: "youtube", launches: 0, running: false },
        { id: "whatsapp", name: "WhatsApp", glyph: "whatsapp", launches: 0, running: false },
        { id: "obs", name: "OBS Studio", glyph: "obs", launches: 1, running: false },
        { id: "arc-raiders", name: "ARC Raiders", glyph: "arc-raiders", launches: 0, running: false }
    ]

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    LauncherArc {
        x: 110
        y: 90
        tick: 12.3
        apps: scene.apps
    }

    LauncherArc {
        x: 110
        y: 330
        tick: 12.3
        apps: scene.apps
        hoverIndexOverride: 4
    }

    Timer {
        interval: 900
        running: true
        onTriggered: scene.grabToImage(function(r) {
            r.saveToFile("/home/nexuslink/.hermes/cache/scratch/hud-live/work/A/a-launcher.png")
            Qt.quit()
        })
    }
}
