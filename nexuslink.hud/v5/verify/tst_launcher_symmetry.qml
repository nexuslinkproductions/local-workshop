import QtQuick
import QtTest
import "../kit"
import "../live"

// tst_launcher_symmetry.qml - the v5 launcher band is mirror symmetric about
// the deck centre line x = 1280 (deck coordinates, output 2560 x 1440).
//
// Case 1 (real assets/apps.json, 5 + hero + 5): every tile has a mirror twin,
// centre(i) + centre(mirror(i)) = 2560, equal pitch 116, hero at 1280 with
// scale 1.3, equal tile count each side, mirrored tiles share a y.
// Case 2: the same with a forced hover on a left tile and on its mirror.
// Case 3 (odd non hero count): the group stays balanced, one app is dropped
// and named.
//
// Positions come from mapToItem on the real tiles, never from slotX().
TestCase {
    id: test
    name: "LauncherSymmetry"
    when: windowShown
    width: 2560
    height: 1440

    readonly property Item band: deck.launcherBand
    readonly property real tol: 1.0

    // Property holder so the deck binding can be declared before initTestCase.
    QtObject {
        id: ppt
        property var appsData: []
        property var oddData: []
    }

    DeckView {
        id: deck
        x: 0
        y: 0
        width: 2560
        height: 1440
        autoTick: false
        tick: 0.7
        apps: ppt.appsData
    }

    Item {
        id: oddHost
        x: 0
        y: 0
        width: 2560
        height: 1440

        LauncherArc {
            id: oddArc
            x: 1280 - width / 2
            y: 1230
            width: 1380
            tick: 0.7
            apps: ppt.oddData
        }
    }

    function loadJson(url) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url, false)
        xhr.send()
        return JSON.parse(xhr.responseText)
    }

    function initTestCase() {
        var doc = loadJson(Qt.resolvedUrl("../live/assets/apps.json"))
        ppt.appsData = doc.apps
        // Odd case: the same list without WhatsApp, so nine non hero apps.
        var odd = []
        for (var i = 0; i < doc.apps.length; i++) {
            if (String(doc.apps[i].id) === "whatsapp")
                continue
            odd.push(doc.apps[i])
        }
        ppt.oddData = odd
        wait(200)
    }

    function centreOf(band, i, target) {
        var tile = band.tileAt(i)
        verify(tile !== null, "tile " + i + " exists")
        return tile.mapToItem(target, 32, 32)
    }

    function scalesOf(band) {
        var out = []
        for (var i = 0; i < band.count; i++)
            out.push(band.tileAt(i).scale)
        return out
    }

    function test_rest_geometry() {
        tryCompare(band, "count", 11)
        compare(band.heroIndexInList, 5, "hero is the centre slot")
        compare(band.centreIndex, 5, "centre index")
        compare(band.dropped, null, "even count, nothing dropped")

        var h = centreOf(band, band.heroIndexInList, deck)
        verify(Math.abs(h.x - 1280) <= tol, "hero centre x " + h.x + " is 1280")
        verify(Math.abs(band.tileAt(band.heroIndexInList).scale - 1.3) < 0.001,
               "hero scale " + band.tileAt(band.heroIndexInList).scale)

        var n = band.count
        verify(n % 2 === 1, "odd tile count so every slot has a twin")
        for (var i = 0; i < n; i++) {
            var c = centreOf(band, i, deck)
            var m = centreOf(band, n - 1 - i, deck)
            verify(Math.abs((c.x + m.x) - 2560) <= tol,
                   "tile " + i + " + mirror " + (n - 1 - i) + " = " + (c.x + m.x))
            verify(Math.abs(c.y - m.y) <= tol,
                   "tile " + i + " y " + c.y + " vs mirror " + m.y)
            if (i > 0) {
                var p = centreOf(band, i - 1, deck)
                verify(Math.abs((c.x - p.x) - 116) <= 0.5,
                       "pitch " + (i - 1) + "->" + i + " = " + (c.x - p.x))
            }
        }
        // equal tile count each side of the hero
        var left = 0
        var right = 0
        for (var k = 0; k < n; k++) {
            var x = centreOf(band, k, deck).x
            if (x < 1280 - tol) left++
            else if (x > 1280 + tol) right++
        }
        compare(left, 5, "tiles left of the centre line")
        compare(right, 5, "tiles right of the centre line")
        compare(left, right, "balanced")
    }

    function test_hover_mirror() {
        tryCompare(band, "count", 11)
        band.hoverIndexOverride = 1
        wait(620)
        var leftScales = scalesOf(band)
        var leftCentres = []
        for (var a = 0; a < band.count; a++)
            leftCentres.push(centreOf(band, a, deck))
        verify(leftScales[1] > 1.5, "hovered left tile grows: " + leftScales[1])

        band.hoverIndexOverride = 9
        wait(620)
        var rightScales = scalesOf(band)
        var rightCentres = []
        for (var b = 0; b < band.count; b++)
            rightCentres.push(centreOf(band, b, deck))
        verify(rightScales[9] > 1.5, "hovered right tile grows: " + rightScales[9])

        var n = band.count
        for (var i = 0; i < n; i++) {
            verify(Math.abs(leftScales[i] - rightScales[n - 1 - i]) < 0.01,
                   "scale mirror at " + i + ": " + leftScales[i] + " vs " + rightScales[n - 1 - i])
            // a hover never moves a tile, so both states share the centres
            verify(Math.abs(leftCentres[i].x - rightCentres[i].x) <= tol,
                   "hover moved x at " + i)
            verify(Math.abs(leftCentres[i].y - rightCentres[i].y) <= tol,
                   "hover moved y at " + i)
            verify(Math.abs((rightCentres[i].x + rightCentres[n - 1 - i].x) - 2560) <= tol,
                   "hover mirror at " + i + ": " + (rightCentres[i].x + rightCentres[n - 1 - i].x))
        }
        band.hoverIndexOverride = -1
        wait(500)
    }

    function test_odd_non_hero_count() {
        tryCompare(oddArc, "count", 9)
        verify(oddArc.dropped !== null, "one app dropped")
        compare(String(oddArc.dropped.id), "obs", "dropped app is the last one left out")
        compare(oddArc.heroIndexInList, 4, "hero still the centre slot")
        compare(oddArc.centreIndex, 4, "centre index of nine")

        var n = oddArc.count
        var h = centreOf(oddArc, oddArc.heroIndexInList, oddHost)
        verify(Math.abs(h.x - 1280) <= tol, "hero centre x " + h.x)
        for (var i = 0; i < n; i++) {
            var c = centreOf(oddArc, i, oddHost)
            var m = centreOf(oddArc, n - 1 - i, oddHost)
            verify(Math.abs((c.x + m.x) - 2560) <= tol,
                   "odd: tile " + i + " + mirror = " + (c.x + m.x))
            verify(Math.abs(c.y - m.y) <= tol, "odd: tile " + i + " y mirror")
            if (i > 0) {
                var p = centreOf(oddArc, i - 1, oddHost)
                verify(Math.abs((c.x - p.x) - 116) <= 0.5,
                       "odd: pitch " + (i - 1) + "->" + i + " = " + (c.x - p.x))
            }
        }
        var left = 0
        var right = 0
        for (var k = 0; k < n; k++) {
            var x = centreOf(oddArc, k, oddHost).x
            if (x < 1280 - tol) left++
            else if (x > 1280 + tol) right++
        }
        compare(left, 4, "odd: tiles left")
        compare(right, 4, "odd: tiles right")
        compare(left, right, "odd: balanced")
    }
}
