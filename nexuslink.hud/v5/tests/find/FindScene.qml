import QtQuick
import "../.."

// FindScene.qml - render scene: deck B with Find open, a typed query and eight
// fake hits (one image kind). Used by tools/linux/deck-shot.sh, no Quickshell.
Item {
    width: 2560
    height: 1440

    DeckSurface {
        anchors.fill: parent
        animate: false
        stillFocusProgress: 1
        focusRequest: "find"
        findQuery: "hud"
        findFilter: "all"
        findResults: [
            { "path": "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/02-plan/CONTEXT.md", "kind": "md", "score": 0.97 },
            { "path": "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/layout-v3/B2-dp1.png", "kind": "image", "score": 0.91 },
            { "path": "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/03-build/CONTEXT.md", "kind": "md", "score": 0.88 },
            { "path": "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/01-research/CONTEXT.md", "kind": "md", "score": 0.84 },
            { "path": "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/s2/s2-rest-view.jpg", "kind": "image", "score": 0.7 },
            { "path": "~/OMARCHY-HUD/CONTEXT.md", "kind": "md", "score": 0.66 },
            { "path": "~/hud-candidates/README.md", "kind": "md", "score": 0.5 },
            { "path": "~/Downloads/arc-raiders-session.mp4", "kind": "video", "score": 0.3 }
        ]
    }
}
