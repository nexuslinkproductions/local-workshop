import QtQuick
import QtTest
import "../../kit"

// tests/media/tst_media.qml - MediaPill states. Run with qmltestrunner and an
// imports dir that maps NexusHud/V5 -> kit (see the report for the exact line).
TestCase {
    id: tc
    name: "MediaPill"
    width: 400
    height: 120
    when: windowShown
    visible: true

    Component {
        id: pillComp
        MediaPill {}
    }

    Component {
        id: spyComp
        SignalSpy {}
    }

    // Count dots in the pill with the lit (acid) colour and the pill's full dot
    // count. The dots are the 5 px Rectangles the level meter repeats.
    function litCount(pill) {
        var n = 0
        var dots = 0
        for (var i = 0; i < pill.children.length; ++i) {
            var c = pill.children[i]
            if (c.width === pill.glyphDot && c.height === pill.glyphDot && c.radius === pill.glyphDot / 2) {
                dots++
                if (Qt.colorEqual(c.color, Tokens.acid))
                    n++
            }
        }
        return { lit: n, dots: dots }
    }

    function test_unavailable_is_transparent_and_has_no_hit_area() {
        var pill = createTemporaryObject(pillComp, tc, { title: "Champagne Supernova", available: false, playing: true })
        verify(pill !== null)
        compare(pill.opacity, 0)
        compare(pill.hitEnabled, false)
        compare(pill.levelRunning, false)
        var spy = createTemporaryObject(spyComp, tc, { target: pill, signalName: "toggleRequested" })
        mouseClick(pill, 150, 28)
        compare(spy.count, 0)
    }

    function test_available_paused_is_static_and_dim() {
        var pill = createTemporaryObject(pillComp, tc, { title: "Champagne Supernova", available: true, playing: false })
        compare(pill.opacity, 1)
        compare(pill.hitEnabled, true)
        compare(pill.levelRunning, false)
        compare(pill.label, "Champagne Supernova")
        compare(pill.truncated, false)
        var r = litCount(pill)
        compare(r.dots, 12)
        compare(r.lit, 0)
    }

    function test_playing_animates_and_lights_the_meter() {
        var pill = createTemporaryObject(pillComp, tc, { title: "Champagne Supernova", available: true, playing: true })
        compare(pill.levelRunning, true)
        // Column c lights 1 + ((floor(step) + c) mod 4) dots from the bottom.
        var s = Math.floor(pill.step)
        var expected = 0
        for (var c = 0; c < 3; ++c)
            expected += 1 + ((s + c) % 4)
        var r = litCount(pill)
        compare(r.dots, 12)
        compare(r.lit, expected)
    }

    function test_long_title_elides_inside_the_capsule() {
        var long = "An extremely long track title that certainly does not fit on one line inside the capsule at this size, so it must be elided on the right"
        var pill = createTemporaryObject(pillComp, tc, { title: long, artist: "Some Artist", available: true, playing: false })
        compare(pill.showArtist, false)
        compare(pill.truncated, true)
        verify(pill.titleX + pill.titleWidth <= pill.width, "title exceeds capsule")
        verify(pill.titleX >= 0)
    }

    function test_short_title_shows_artist_when_it_fits() {
        var pill = createTemporaryObject(pillComp, tc, { title: "Lux", artist: "Nile", available: true, playing: false })
        compare(pill.showArtist, true)
        compare(pill.label, "Lux - Nile")
        compare(pill.truncated, false)
    }

    function test_click_emits_toggle_once() {
        var pill = createTemporaryObject(pillComp, tc, { title: "Champagne Supernova", available: true, playing: true })
        var spy = createTemporaryObject(spyComp, tc, { target: pill, signalName: "toggleRequested" })
        verify(spy.valid)
        mouseClick(pill, 150, 28)
        compare(spy.count, 1)
        mouseClick(pill, 20, 5)
        compare(spy.count, 2)
    }

    function test_hover_brightens_the_fill() {
        var pill = createTemporaryObject(pillComp, tc, { title: "Champagne Supernova", available: true, playing: false })
        mouseMove(pill, 150, 28)
        tryVerify(function () { return pill.hovered }, 2000)
        var hoverAlpha = pill.hoverFillAlpha
        tryVerify(function () {
            return Math.abs(pill.fillColor.a - hoverAlpha) < 0.01
        }, 2000)
        mouseMove(pill, 400, 100)
        tryVerify(function () {
            return Math.abs(pill.fillColor.a - Tokens.capsuleFillAlpha) < 0.01
        }, 2000)
    }
}
