import QtQuick
import "../../kit"
import "../../live"

// AdapterDeckA.qml - launcher adapter for deck A (v5-live). Default adapter of
// tst_launcher_symmetry.qml. Contract (see tools/linux/porting/launcher-test.md):
//   apps, tick, hoverIndexOverride        inputs
//   tiles()                              Items in visual order (left to right)
//   idAt(i), heroIndex()                 app id at visual slot i, hero slot
//   centreX, pitch, heroScale            the centre line, neighbour pitch, hero scale
//   hoverMinScale, dropId                hover growth floor, the app a odd list drops
// Deck A keeps today's geometry: DeckView places the band at x 1280 - width / 2,
// pitch 116, 11 slots, hero at slot 5, scale 1.3.
Item {
    id: root

    width: 2560
    height: 1440

    property var apps: []
    property real tick: 0.7
    property int hoverIndexOverride: -1

    // Typed as var so qmllint does not guess the band's members.
    readonly property var band: deck.launcherBand

    readonly property real centreX: 1280
    readonly property real pitch: 116
    readonly property real heroScale: 1.3
    readonly property real hoverMinScale: 1.5
    readonly property string dropId: "obs"

    DeckView {
        id: deck
        x: 0
        y: 0
        width: 2560
        height: 1440
        autoTick: false
        tick: root.tick
        apps: root.apps
    }

    Binding {
        target: deck.launcherBand
        property: "hoverIndexOverride"
        value: root.hoverIndexOverride
    }

    function tiles() {
        var out = []
        for (var i = 0; i < root.band.count; i++)
            out.push(root.band.tileAt(i))
        return out
    }

    function idAt(i) {
        return String(root.band.tileAt(i).app.id)
    }

    // Effective scale of slot i (tile scale; the hero is 1.3 by scale here).
    function scaleAt(i) {
        return root.band.tileAt(i).scale
    }

    function heroIndex() {
        return root.band.heroIndexInList
    }
}
