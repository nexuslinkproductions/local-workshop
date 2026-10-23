import QtQuick

// W3 gauge still, launcher deep view. IconTile is not composed into DeckSurface
// (the launcher draws LauncherArc), so the tile states are rendered from
// kit/icons/TileStates.qml; this still covers the launcher deep view itself.
GaugeDeepStill { focusId: "launcher" }
