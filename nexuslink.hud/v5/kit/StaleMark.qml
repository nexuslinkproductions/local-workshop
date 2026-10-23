import QtQuick
import NexusHud.V5 1.0

// StaleMark.qml - the one text-only "STALE 3m" label (SHARED3 FRESHNESS rule c).
// Text only: no box, no outline, no glow. Satoshi through Tokens, label size,
// ice. The parent sets label and shows the mark only while its feed is stale.
Text {
    id: mark

    property string label: ""

    text: label
    color: Tokens.ice
    font.family: Tokens.fontFamily
    font.pixelSize: Tokens.sizeLabel
}
