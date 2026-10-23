import QtQuick
import QtTest
import NexusHud.V5 1.0

// tst_quick.qml - QuickActions: each icon emits its id exactly once; hover
// brightens; mediaPlaying and mediaAvailable switch the first glyph.
// Run by tests/quick/run.sh (qmltestrunner, offscreen).
TestCase {
    id: tc

    name: "QuickActions"
    width: 640
    height: 360
    when: windowShown

    // Design space is 2560 x 1440. The stage is scaled to 1/4 so the whole row
    // sits inside the small offscreen test window. Clicks and moves are sent in
    // design coordinates and mapped by Qt through the scale.
    Item {
        id: stage

        width: 2560
        height: 1440
        scale: 0.25
        transformOrigin: Item.TopLeft

        QuickActions {
            id: qa

            anchors.fill: parent
        }
    }

    SignalSpy {
        id: clicks

        target: qa
        signalName: "actionRequested"
    }

    readonly property var ids: ["visualizer", "apps", "screen-scan", "text-scan", "power"]
    readonly property var centres: [118, 194, 2290, 2366, 2440]

    function findChild(item, name) {
        if (item.objectName === name)
            return item
        for (var i = 0; i < item.children.length; ++i) {
            var hit = findChild(item.children[i], name)
            if (hit !== null)
                return hit
        }
        return null
    }

    function areaFor(id) {
        var a = findChild(qa, "quick-" + id)
        verify(a !== null, "no MouseArea for " + id)
        return a
    }

    function luma(c) {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    function test_targetsAreFiftySixAndCentredOnTheRow() {
        for (var i = 0; i < ids.length; ++i) {
            var a = areaFor(ids[i])
            compare(a.width, 56, ids[i] + " width")
            compare(a.height, 56, ids[i] + " height")
            var c = a.mapToItem(qa, 28, 28)
            compare(c.x, centres[i], ids[i] + " centre x")
            compare(c.y, 1310, ids[i] + " centre y")
        }
    }

    function test_clickOnEachIconEmitsItsIdExactlyOnce() {
        for (var i = 0; i < ids.length; ++i) {
            clicks.clear()
            areaFor(ids[i]).clicked(null)
            compare(clicks.count, 1, ids[i] + " click count")
            compare(clicks.signalArguments[0][0], ids[i], ids[i] + " emitted id")
        }
    }

    function test_hoverBrightensTheGlyph() {
        var a = areaFor("apps")
        var g = a.parent
        mouseMove(a, -20, -20)
        compare(g.hovered, false, "not hovered before the move")
        var rest = g.ink
        compare(rest, Tokens.ice, "rest ink is ice")
        mouseMove(a, 28, 28)
        verify(a.containsMouse, "pointer over the apps target")
        compare(g.hovered, true)
        compare(g.ink, Tokens.white, "hover ink is white")
        verify(luma(g.ink) > luma(rest), "hover is brighter than rest")
        compare(findChild(qa, "glyph-apps").scale, qa.hoverScale, "hover lift")
        mouseMove(a, -20, -20)
        compare(findChild(qa, "glyph-apps").scale, 1, "lift released")
    }

    function test_mediaPlayingSwitchesTheFirstGlyph() {
        var bars = findChild(qa, "vis-bars")
        var play = findChild(qa, "vis-play")
        var vis = areaFor("visualizer").parent
        verify(bars !== null && play !== null, "visualizer glyph parts exist")

        qa.mediaAvailable = true
        qa.mediaPlaying = false
        compare(bars.visible, false, "paused: no level bars")
        compare(play.visible, true, "paused: play mark")
        compare(vis.ink, Tokens.ice, "paused: ice")

        qa.mediaPlaying = true
        compare(bars.visible, true, "playing: level bars")
        compare(play.visible, false, "playing: no play mark")
        compare(vis.ink, Tokens.acid, "playing: acid live state")

        qa.mediaPlaying = false
    }

    function test_noPlayerDimsTheFirstGlyph() {
        var vis = areaFor("visualizer").parent
        qa.mediaPlaying = false
        qa.mediaAvailable = false
        compare(vis.inkOpacity, qa.dimOpacity, "no player: dimmed")
        qa.mediaAvailable = true
        compare(vis.inkOpacity, 1, "player present: full strength")
    }
}
