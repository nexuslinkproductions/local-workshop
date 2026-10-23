import QtQuick
import NexusHud.V5 1.0

// tests/media/scene-pill-only.qml - render B fallback: the media pill alone at
// its DeckSurface position (250, 1284) on the field colour, 2560x1440. Used
// because DeckSurface.qml did not load in this worktree at render time (its
// FindResults `filter` binding, not the pill).
//   tools/linux/deck-shot.sh nexuslink.hud/v5/tests/media/scene-pill-only.qml <out.png> 2560 1440
Item {
    id: root

    width: 2560
    height: 1440

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    MediaPill {
        x: 250
        y: 1284
        title: "Champagne Supernova"
        playing: true
        available: true
    }
}
