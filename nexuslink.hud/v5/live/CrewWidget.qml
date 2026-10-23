pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// CrewWidget.qml - v5 rest form, drawn to the approved s10 mockup: CREW label,
// big session count, and a diamond lattice of dots (a square lattice cut to
// |a| + |b| <= N, the s10 crew_svg shape). One node per session, busiest first,
// on the five s10 cells; a live node is acid, the others white.
//
// Input: `crew` is the raw v4 crew object (~/.local/state/nexuslink/crew.json):
//   { generated, bots: [{ name, model, provider, state, last_active,
//     sessions_24h, calls_24h, tokens_24h, current_title,
//     events: [[start, end|null, title], ...] }], totals }
// It also accepts a plain array of session rows (the Mac fleet cleaned shape,
// v5/fixtures/sessions.json) or an object with a `sessions` array (the tokens
// feed shape). Everything else (undefined, null, {}, junk entries) yields an
// honest empty state: count 0, lattice dim, the word idle.
//
// Freshness: crew.json carries `generated` (tokens/crew.py writes it every 60 s).
//   fresh: age <= staleAfterS, or no timestamp in the input: count bright.
//   stale: age > staleAfterS: count dim, lattice dim, age text "stale 10m".
//   error: crew.error is a non-empty value: no number, amber "error: <reason>".
//
// live is decided as: the activity string says streaming/receiving/starting a
// turn, OR the session was active within the last 60 s. Raw bot events have no
// activity string, so an open event (end === null) whose idle is <= 60 s is
// live; a closed event never is.
//
// Tokens for bot-derived rows: crew.json only carries a per-bot 24 h total, so
// that total is divided evenly across that bot's listed events (documented
// estimate; it only sets node size, never a printed number).
WidgetBase {
    id: root

    property var crew: ({})
    // click opens the crew focus view (DeckView onExpandRequested); WidgetBase
    // only forwards the click when expandable is set.
    expandable: true
    readonly property int count: sessions.length

    // ---- s10 geometry (deck px, 2560 x 1440 space) -----------------------
    // Crew box in s10-spacing.json: l 184.4, t 248, r 592, b 552. DeckView
    // places this widget at (184.2, 223.4); `stage` shifts deck px back into
    // widget px, so the drawn shape lands on its s10 box at rest. Tokens has no
    // crew or lattice entries, so these s10 constants live here.
    readonly property real originX: 184.2
    readonly property real originY: 223.4
    readonly property real centreX: 440        // s10 GL, crew centre
    readonly property real centreY: 400
    readonly property real textRight: 250      // s10 TXL, text column edge
    readonly property real pitch: 10           // s10 U, one lattice pitch
    readonly property int latticeN: 15         // diamond half-diagonal, pitches
    readonly property real dotScale: 1.1       // svg radius = 1.1 * r
    readonly property real staleAfterS: 180    // three crew.json cycles
    // Node cells (a, b) in lattice pitches, busiest first (s10 crew_svg pos).
    readonly property var slotCells: [[1, 0], [-5, -4], [6, -5], [-4, 6], [5, 6]]

    // ---- adapter ---------------------------------------------------------
    function str(v) {
        return (v === undefined || v === null) ? "" : String(v)
    }
    function num(v, d) {
        var n = Number(v)
        return isFinite(n) ? n : d
    }
    function isStreaming(a) {
        var s = str(a).toLowerCase()
        return s.indexOf("stream") >= 0 || s.indexOf("receiv") >= 0
            || s.indexOf("starting new turn") >= 0 || s.indexOf("running") >= 0
            || s.indexOf("delegat") >= 0
    }
    function nowSec(raw) {
        var g = (raw && typeof raw === "object") ? num(raw.generated, 0) : 0
        return g > 0 ? g : Date.now() / 1000
    }
    function norm(s, i, now, fallbackModel, fallbackTokens) {
        if (!s || typeof s !== "object")
            return null
        var last = num(s.last_activity_at, 0)
        var idle = (s.idle_s !== undefined && s.idle_s !== null)
                 ? num(s.idle_s, -1)
                 : (last > 0 ? Math.max(0, now - last) : -1)
        var toks = num(s.tokens, -1)
        if (toks < 0)
            toks = num(s.in, 0) + num(s.out, 0)
        if (toks <= 0 && fallbackTokens > 0)
            toks = fallbackTokens
        var act = str(s.activity)
        var id = str(s.id) || str(s.full) || ("s" + i)
        return {
            "id": id,
            "parent": str(s.parent),
            "model": str(s.model) || fallbackModel,
            "tokens": Math.max(0, toks),
            "idle_s": idle,
            "title": str(s.title),
            "activity": act,
            "live": isStreaming(act) || (idle >= 0 && idle <= 60)
        }
    }
    function fromBots(bots, now) {
        var out = []
        for (var i = 0; i < bots.length; i++) {
            var b = bots[i]
            if (!b || typeof b !== "object")
                continue
            var ev = Array.isArray(b.events) ? b.events : []
            var share = ev.length > 0 ? num(b.tokens_24h, 0) / ev.length : 0
            var model = str(b.model)
            if (ev.length === 0) {
                var la = num(b.last_active, 0)
                out.push({
                    "id": str(b.name) || ("bot" + i),
                    "parent": "",
                    "model": model,
                    "tokens": Math.max(0, num(b.tokens_24h, 0)),
                    "idle_s": la > 0 ? Math.max(0, now - la) : -1,
                    "title": str(b.current_title),
                    "activity": str(b.state),
                    "live": b.state === "active" && la > 0 && (now - la) <= 60
                })
                continue
            }
            for (var j = 0; j < ev.length; j++) {
                var e = ev[j]
                if (!Array.isArray(e) || e.length < 1)
                    continue
                var start = num(e[0], 0)
                var end = (e[1] === null || e[1] === undefined) ? -1 : num(e[1], -1)
                var anchor = end > 0 ? end : num(b.last_active, 0)
                var idle = anchor > 0 ? Math.max(0, now - anchor) : -1
                out.push({
                    "id": (str(b.name) || "bot") + "#" + start.toFixed(0) + "-" + j,
                    "parent": "",
                    "model": model,
                    "tokens": Math.round(share),
                    "idle_s": idle,
                    "title": str(e[2]),
                    "activity": str(b.state),
                    "live": end < 0 && idle >= 0 && idle <= 60
                })
            }
        }
        return out
    }
    function adapt(raw) {
        var now = nowSec(raw)
        var list = []
        var i
        if (Array.isArray(raw)) {
            list = raw
        } else if (raw && typeof raw === "object") {
            if (Array.isArray(raw.sessions))
                list = raw.sessions
            else if (Array.isArray(raw.bots))
                return fromBots(raw.bots, now)
            else
                return []
        } else {
            return []
        }
        var out = []
        for (i = 0; i < list.length; i++) {
            var r = norm(list[i], i, now, "", 0)
            if (r !== null)
                out.push(r)
        }
        return out
    }
    readonly property var sessions: root.adapt(root.crew)

    // ---- freshness and error ---------------------------------------------
    // Age of the snapshot in seconds, -1 when the input carries no timestamp.
    // tick is passed in so the binding re-reads the wall clock every tick.
    function ageAt(t) {
        var g = (root.crew && typeof root.crew === "object" && !Array.isArray(root.crew))
              ? Number(root.crew.generated) : NaN
        if (!isFinite(g) || g <= 0)
            return -1
        return Math.max(0, Date.now() / 1000 - g)
    }
    readonly property real ageS: root.ageAt(root.tick)
    readonly property bool stale: root.ageS > root.staleAfterS
    readonly property string ageLabel: {
        var s = Math.floor(root.ageS)
        if (s < 60) return s + "s"
        if (s < 3600) return Math.floor(s / 60) + "m"
        if (s < 86400) return Math.floor(s / 3600) + "h"
        return Math.floor(s / 86400) + "d"
    }
    readonly property string errorText: {
        var e = (root.crew && typeof root.crew === "object" && !Array.isArray(root.crew))
              ? root.crew.error : undefined
        return (e === undefined || e === null) ? "" : String(e).trim()
    }
    readonly property bool errored: root.errorText !== ""

    // ---- stable hash and node cells --------------------------------------
    function hashId(s) {
        var h = 2166136261
        for (var i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i)
            h = (h * 16777619) >>> 0
        }
        return h >>> 0
    }

    // At most 10 nodes: live first, then by tokens (the count stays the real
    // session count). The chosen nodes are then laid out busiest first on the
    // s10 cells; sessions past the five cells take a hashed cell inside the
    // diamond, so a node does not move when the feed reorders.
    readonly property var nodes: {
        var all = root.sessions
        var mx = 0
        for (var i = 0; i < all.length; i++)
            mx = Math.max(mx, all[i].tokens)
        var src = all.slice(0)
        src.sort(function (x, y) {
            if (x.live !== y.live) return x.live ? -1 : 1
            if (x.tokens !== y.tokens) return y.tokens - x.tokens
            return x.id < y.id ? -1 : 1
        })
        var picked = src.slice(0, 10)
        picked.sort(function (x, y) {
            if (x.tokens !== y.tokens) return y.tokens - x.tokens
            return x.id < y.id ? -1 : 1
        })
        var N = root.latticeN
        var out = []
        for (var j = 0; j < picked.length; j++) {
            var s = picked[j]
            var cell
            if (j < root.slotCells.length) {
                cell = root.slotCells[j]
            } else {
                var h = root.hashId(s.id)
                var a = (h % 17) - 8
                var b = ((h >>> 9) % 17) - 8
                if (Math.abs(a) + Math.abs(b) > N - 3) {
                    a = Math.round(a * 0.6)
                    b = Math.round(b * 0.6)
                }
                cell = [a, b]
            }
            var r = mx > 0 ? 3.8 + 3.4 * Math.sqrt(s.tokens / mx) : 3.8
            out.push({ "a": cell[0], "b": cell[1], "r": r, "live": s.live })
        }
        return out
    }

    // ---- dots: the whole diamond in one list -----------------------------
    // Ambient dots brighten toward the upper left (light at -0.30, -0.35 of the
    // half-diagonal). Edge dots are smaller and dimmer. Dots next to a node are
    // white halo; a node cell is the node itself.
    function buildDots(list) {
        var N = root.latticeN
        var p = root.pitch
        var at = {}
        var near = {}
        for (var i = 0; i < list.length; i++) {
            var nd = list[i]
            at[nd.a + "," + nd.b] = i
            for (var da = -2; da <= 2; da++)
                for (var db = -2; db <= 2; db++)
                    if (Math.abs(da) + Math.abs(db) <= 2)
                        near[(nd.a + da) + "," + (nd.b + db)] = true
        }
        var out = []
        for (var a = -N; a <= N; a++) {
            var aa = Math.abs(a)
            for (var b = -N + aa; b <= N - aa; b++) {
                var key = a + "," + b
                var k = Math.max(0, 1 - Math.hypot(a / N + 0.30, b / N + 0.35) / 1.45)
                var r = 1.6 + 1.7 * k
                var op = 0.50 + 0.48 * k
                var c = Tokens.ice
                var m = aa + Math.abs(b)
                if (m >= N - 1) {
                    r = 1.8
                    op = (m === N) ? 0.64 : 0.52
                }
                if (near[key] === true) {
                    r = 2.9
                    op = 0.97
                    c = Tokens.white
                }
                if (at[key] !== undefined) {
                    var n2 = list[at[key]]
                    r = n2.r
                    op = 1
                    c = n2.live ? Tokens.acid : Tokens.white
                }
                out.push({
                    "cx": root.centreX + a * p,
                    "cy": root.centreY + b * p,
                    "d": 2 * root.dotScale * r,
                    "c": c,
                    "o": op
                })
            }
        }
        return out
    }
    readonly property var dots: root.buildDots(root.nodes)

    // ---- rest layout (deck px inside `stage`, see originX/originY) -------
    Item {
        id: stage
        x: -root.originX
        y: -root.originY
        width: 0
        height: 0

        Item {
            id: latticeBox
            x: 0
            y: 0
            opacity: root.errored ? 0.45 : (root.stale ? 0.5
                   : (root.count === 0 ? 0.7 : 1))

            Repeater {
                model: root.dots
                Rectangle {
                    required property var modelData
                    x: modelData.cx - modelData.d / 2
                    y: modelData.cy - modelData.d / 2
                    width: modelData.d
                    height: modelData.d
                    radius: modelData.d / 2
                    color: modelData.c
                    opacity: modelData.o
                }
            }
        }

        Text {
            id: label
            x: 0
            y: 345
            width: root.textRight
            horizontalAlignment: Text.AlignRight
            text: qsTr("CREW")
            color: Tokens.textLabel
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightBold
            font.pixelSize: Tokens.sizeCaption
            font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
            renderType: Text.NativeRendering
        }

        Text {
            id: bigCount
            x: 0
            y: 363
            width: root.textRight
            height: 68
            visible: !root.errored
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignTop
            lineHeight: 68
            lineHeightMode: Text.FixedHeight
            text: String(root.count)
            color: root.stale ? Tokens.textDim : Tokens.white
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightMedium
            font.pixelSize: Tokens.sizeHero
            font.letterSpacing: -Tokens.trackClock * Tokens.sizeHero
            renderType: Text.NativeRendering
        }

        // One line under the count: error (amber, no number), stale age, or idle.
        Text {
            id: stateLine
            x: 0
            y: 440
            width: root.textRight
            visible: root.errored || root.stale || root.count === 0
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            text: root.errored ? ("error: " + root.errorText)
                : (root.stale ? ("stale " + root.ageLabel) : qsTr("idle"))
            color: root.errored ? Tokens.amber : Tokens.textDim
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightRegular
            font.pixelSize: Tokens.sizeCaption
            renderType: Text.NativeRendering
        }
    }
}
