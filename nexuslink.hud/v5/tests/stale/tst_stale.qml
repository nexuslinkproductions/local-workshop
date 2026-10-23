import QtQuick
import QtTest
import NexusHud.V5 1.0
import "../.."

// tests/stale/tst_stale.qml - the STALE mark and the DeckSurface readout rule
// (SHARED3 FRESHNESS rule c). Run: nexuslink.hud/v5/tests/stale/run.sh
TestCase {
    id: tc
    name: "Stale"
    width: 400
    height: 120
    when: windowShown

    StaleMark {
        id: mark
        label: "STALE 3m"
    }

    DeckSurface {
        id: surface
        visible: true
        width: 2560
        height: 1440
        feedStale: ({ "sessions": true, "link": true })
        feedAge: ({ "sessions": "3m", "link": "3m" })
    }

    function test_stalemark_text() {
        compare(mark.text, "STALE 3m")
        compare(mark.font.family, Tokens.fontFamily)
        compare(mark.font.pixelSize, Tokens.sizeLabel)
        compare(mark.color, Tokens.ice)
    }

    function test_surface_rule_stale() {
        // Set after creation, the way DeckMain feeds the surface at run time.
        surface.feedStale = ({ "sessions": true, "link": true })
        surface.feedAge = ({ "sessions": "3m", "link": "3m" })
        var p = surface.readoutProbe
        compare(p.sessions.text, "--")
        compare(p.sessions.opacity, 0.45)
        compare(p.sessions.label, "STALE 3m")
        compare(p.link.text, "--")
        compare(p.link.opacity, 0.45)
        compare(p.link.label, "STALE 3m")
    }

    function test_surface_rule_untouched_feed() {
        var p = surface.readoutProbe
        compare(p.metrics.opacity, 1)
        compare(p.metrics.label, "")
        compare(p.disks.opacity, 1)
        compare(p.disks.label, "")
    }
}
