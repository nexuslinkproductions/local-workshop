import QtQuick
import QtTest
import HudLauncherSut 1.0

// tst_launcher_symmetry.qml - mirror symmetry of ANY launcher band.
// The launcher under test is the adapter named by run-launcher-test.sh
// (HUD_LAUNCHER_ADAPTER, default verify/launcher/AdapterDeckA.qml). The test
// imports only QtQuick and QtTest and talks to the adapter through the contract
// in tools/linux/porting/launcher-test.md. Every assertion prints one line
// "LSYM group | name | value | target | limit | PASS/FAIL"; a group fails
// after all its rows are printed.
TestCase {
    id: test
    name: "LauncherSymmetry"
    when: windowShown
    width: 2560
    height: 1440

    readonly property real tol: 1.0          // x mirror and centre line, px
    readonly property real pitchTol: 0.5     // neighbour pitch, px
    readonly property real yTol: 0.2         // mirrored tiles share a y, px
    readonly property real scaleTol: 0.001   // hero scale
    readonly property real mirrorScaleTol: 0.01

    property var appsData: []
    property var oddData: []

    LauncherSut {
        id: sut
        width: 2560
        height: 1440
        apps: test.appsData
    }

    // Odd case: the same list without WhatsApp.
    LauncherSut {
        id: oddSut
        width: 2560
        height: 1440
        apps: test.oddData
    }

    function loadJson(url) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url, false)
        xhr.send()
        return JSON.parse(xhr.responseText)
    }

    function initTestCase() {
        // QML_XHR_ALLOW_FILE_READ=1 (set by run-launcher-test.sh) lets this read
        // the shipped assets/apps.json, so every adapter gets the real list.
        var doc = loadJson(Qt.resolvedUrl("../live/assets/apps.json"))
        test.appsData = doc.apps
        var odd = []
        for (var i = 0; i < doc.apps.length; i++) {
            if (String(doc.apps[i].id) === "whatsapp")
                continue
            odd.push(doc.apps[i])
        }
        test.oddData = odd
        wait(200)
    }

    function fmt(v) {
        return (typeof v === "number") ? v.toFixed(3) : String(v)
    }

    // Prints one assertion row and records a failure in f.
    function row(f, grp, name, value, target, limit, ok) {
        console.log("LSYM " + grp + " | " + name + " | value " + fmt(value)
                    + " | target " + fmt(target) + " | limit " + fmt(limit)
                    + " | " + (ok ? "PASS" : "FAIL"))
        if (!ok)
            f.push(name)
    }

    // Centre of a tile item in the adapter root's coordinates (the test window).
    function centre(item, target) {
        return item.mapToItem(target, item.width / 2, item.height / 2)
    }

    // Rest geometry of one adapter. expectCount is the tile count the list
    // should produce. Returns the failed row names (the group also fails
    // through compare, after every row is printed).
    function checkRest(s, grp, expectCount) {
        var f = []
        var tiles = s.tiles()
        var n = tiles.length
        var cx = s.centreX
        var p = s.pitch
        var h = s.heroIndex()
        var c = []
        for (var i = 0; i < n; i++)
            c.push(centre(tiles[i], s))

        row(f, grp, "count", n, expectCount, 0, n === expectCount)
        row(f, grp, "odd_count", n, "odd", 0, n % 2 === 1)

        var hx = (h >= 0 && h < n) ? c[h].x : -1
        row(f, grp, "hero_on_centre_x", hx, cx, tol,
            h >= 0 && h < n && Math.abs(hx - cx) <= tol)
        row(f, grp, "hero_slot", h, Math.floor(n / 2), 0,
            h === Math.floor(n / 2))
        var hs = (h >= 0 && h < n) ? s.scaleAt(h) : -1
        row(f, grp, "hero_scale", hs, s.heroScale, scaleTol,
            h >= 0 && h < n && Math.abs(hs - s.heroScale) < scaleTol)

        var worstX = 0
        var worstY = 0
        for (var j = 0; j < n; j++) {
            var m = n - 1 - j
            worstX = Math.max(worstX, Math.abs((c[j].x + c[m].x) - 2 * cx))
            worstY = Math.max(worstY, Math.abs(c[j].y - c[m].y))
        }
        row(f, grp, "mirror_x_err", worstX, 0, tol, worstX <= tol)
        row(f, grp, "mirror_y_err", worstY, 0, yTol, worstY <= yTol)

        var dmin = 1e9
        var dmax = -1e9
        var dpitch = 0
        for (var k = 1; k < n; k++) {
            var d = c[k].x - c[k - 1].x
            dmin = Math.min(dmin, d)
            dmax = Math.max(dmax, d)
            dpitch = Math.max(dpitch, Math.abs(d - p))
        }
        console.log("LSYM " + grp + " | pitch_min_max | value " + fmt(dmin) + " .. "
                    + fmt(dmax) + " | info only")
        row(f, grp, "pitch_vs_target", dpitch, p, pitchTol, dpitch <= pitchTol)
        row(f, grp, "pitch_spread", dmax - dmin, 0, pitchTol,
            (dmax - dmin) <= pitchTol)

        var left = 0
        var right = 0
        for (var q = 0; q < n; q++) {
            if (c[q].x < cx - tol) left++
            else if (c[q].x > cx + tol) right++
        }
        row(f, grp, "balance_left_right", left + "/" + right, "equal", 0,
            left === right)
        compare(f.length, 0, grp + " failed rows: " + f.join(", "))
        return f
    }

    function test_rest_geometry() {
        tryVerify(function () { return sut.tiles().length > 0 }, 5000)
        // The hero tile scale is animated (200 ms) from whatever state the
        // previous case left, so settle before reading.
        wait(1000)
        checkRest(sut, "rest", test.appsData.length)
    }

    // Hover: the tile at visual slot a and its mirror b each grow; nothing moves.
    function test_hover_mirror() {
        tryVerify(function () { return sut.tiles().length > 0 }, 5000)
        var f = []
        var n = sut.tiles().length
        var a = 1
        var b = n - 2

        sut.hoverIndexOverride = a
        wait(620)
        var leftScales = []
        var leftCentres = []
        var tl = sut.tiles()
        for (var i = 0; i < n; i++) {
            leftScales.push(sut.scaleAt(i))
            leftCentres.push(centre(tl[i], sut))
        }
        row(f, "hover", "grow_left_" + a, leftScales[a], sut.hoverMinScale,
            0, leftScales[a] > sut.hoverMinScale)

        sut.hoverIndexOverride = b
        wait(620)
        var rightScales = []
        var rightCentres = []
        var tr = sut.tiles()
        for (var j = 0; j < n; j++) {
            rightScales.push(sut.scaleAt(j))
            rightCentres.push(centre(tr[j], sut))
        }
        row(f, "hover", "grow_right_" + b, rightScales[b], sut.hoverMinScale,
            0, rightScales[b] > sut.hoverMinScale)

        var worstS = 0
        var worstMove = 0
        var worstMirror = 0
        for (var k = 0; k < n; k++) {
            var m = n - 1 - k
            worstS = Math.max(worstS, Math.abs(leftScales[k] - rightScales[m]))
            worstMove = Math.max(worstMove,
                                 Math.abs(leftCentres[k].x - rightCentres[k].x),
                                 Math.abs(leftCentres[k].y - rightCentres[k].y))
            worstMirror = Math.max(worstMirror,
                Math.abs((rightCentres[k].x + rightCentres[m].x) - 2 * sut.centreX))
        }
        row(f, "hover", "scale_mirror_err", worstS, 0, mirrorScaleTol,
            worstS <= mirrorScaleTol)
        row(f, "hover", "hover_moves_tiles", worstMove, 0, tol,
            worstMove <= tol)
        row(f, "hover", "hover_mirror_x_err", worstMirror, 0, tol,
            worstMirror <= tol)

        sut.hoverIndexOverride = -1
        wait(500)
        compare(f.length, 0, "hover failed rows: " + f.join(", "))
    }

    function idsOf(s) {
        var out = []
        var n = s.tiles().length
        for (var i = 0; i < n; i++)
            out.push(s.idAt(i))
        return out
    }

    // Odd list: the adapter decides what it drops (dropId, "" when nothing).
    function test_odd_non_hero_count() {
        tryVerify(function () { return oddSut.tiles().length > 0 }, 5000)
        wait(600)
        var f = []
        var expect = test.oddData.length - (oddSut.dropId !== "" ? 1 : 0)
        var ids = idsOf(oddSut)
        var missing = []
        for (var i = 0; i < test.oddData.length; i++) {
            var id = String(test.oddData[i].id)
            if (ids.indexOf(id) < 0)
                missing.push(id)
        }
        var want = oddSut.dropId !== "" ? [oddSut.dropId] : []
        row(f, "odd", "dropped_ids", missing.join(",") || "none",
            want.join(",") || "none", 0,
            missing.join(",") === want.join(","))
        var rest = checkRest(oddSut, "odd", expect)
        f = f.concat(rest)
        compare(f.length, 0, "odd failed rows: " + f.join(", "))
    }
}
