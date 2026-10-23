pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// CrewWidget.qml - v5 rest form: CREW label, big session count, and a
// non-spherical dot lattice with one bright cluster per session.
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
// live is decided as: the activity string says streaming/receiving/starting a
// turn, OR the session was active within the last 60 s. Raw bot events have no
// activity string, so an open event (end === null) whose idle is <= 60 s is
// live; a closed event never is.
//
// Tokens for bot-derived rows: crew.json only carries a per-bot 24 h total, so
// that total is divided evenly across that bot's listed events (documented
// estimate; it only sets dot cluster size, never a printed number).
WidgetBase {
    id: root

    property var crew: ({})
    readonly property int count: sessions.length

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

    // ---- stable hash and cluster geometry --------------------------------
    function hashId(s) {
        var h = 2166136261
        for (var i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i)
            h = (h * 16777619) >>> 0
        }
        return h >>> 0
    }

    // Square lattice clipped to a rounded-rectangle silhouette, integer maths.
    // 12 columns x 11 rows with the four corner blocks cut: 120 dots.
    readonly property var lattice: {
        var pts = []
        var w = 220, h = 200, step = 18, inset = 9
        for (var y = inset; y <= h - inset; y += step) {
            for (var x = inset; x <= w - inset; x += step) {
                var dx = Math.abs(x - w * 0.5)
                var dy = Math.abs(y - h * 0.5)
                if (dx > 78 && dy > 62)
                    continue
                pts.push({ "x": x, "y": y })
            }
        }
        return pts
    }

    // At most 10 clusters: live first, then by tokens. The count stays the
    // real session count; the lattice only makes the busiest ten visible.
    readonly property var clusters: {
        var src = root.sessions.slice(0)
        src.sort(function (a, b) {
            if (a.live !== b.live) return a.live ? -1 : 1
            if (a.tokens !== b.tokens) return b.tokens - a.tokens
            return a.id < b.id ? -1 : 1
        })
        var picked = src.slice(0, 10)
        var placed = {}
        var out = []
        for (var i = 0; i < picked.length; i++) {
            var s = picked[i]
            var h = root.hashId(s.id)
            var px = 30 + (h % 160)
            var py = 30 + ((h >>> 9) % 140)
            if (s.parent !== "" && placed[s.parent] !== undefined) {
                var p = placed[s.parent]
                px = Math.max(26, Math.min(194, p.x + 26))
                py = Math.max(26, Math.min(174, p.y + 16))
            }
            var n = Math.max(3, Math.min(9, Math.round(
                2 + Math.log(1 + s.tokens / 1000) / Math.LN10 * 2)))
            placed[s.id] = { "x": px, "y": py, "n": n }
            out.push({ "x": px, "y": py, "n": n,
                       "live": s.live, "id": s.id })
        }
        return out
    }

    // Flat dot lists so the whole rest form is two Repeaters.
    readonly property var clusterDots: {
        var ox = [0, 7, -7, 0, 0, 7, -7, 7, -7]
        var oy = [0, 0, 0, 7, -7, 7, -7, -7, 7]
        var out = []
        for (var i = 0; i < root.clusters.length; i++) {
            var c = root.clusters[i]
            for (var j = 0; j < c.n; j++) {
                out.push({
                    "x": c.x + ox[j] - 2.5,
                    "y": c.y + oy[j] - 2.5,
                    "s": 5,
                    "c": c.live ? Tokens.acid : Tokens.ice,
                    "o": c.live ? 0.95 : 0.8
                })
            }
            // white core dot, one per cluster
            out.push({ "x": c.x - 2, "y": c.y - 2, "s": 4,
                       "c": Tokens.white, "o": 0.95 })
        }
        return out
    }

    // ---- rest layout -----------------------------------------------------
    Item {
        id: leftBlock
        x: 0
        y: 56
        width: 128
        height: 128

        Text {
            id: label
            x: 0
            y: 0
            text: qsTr("CREW")
            color: Tokens.textLabel
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightMedium
            font.pixelSize: 16
            font.letterSpacing: Tokens.trackLabel * 16
            renderType: Text.NativeRendering
        }
        Text {
            id: bigCount
            x: -2
            y: 20
            text: String(root.count)
            color: Tokens.ink
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightRegular
            font.pixelSize: 68
            renderType: Text.NativeRendering
        }
        Text {
            id: idleWord
            x: 0
            y: 112
            visible: root.count === 0
            text: qsTr("idle")
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightRegular
            font.pixelSize: 16
            renderType: Text.NativeRendering
        }
    }

    Item {
        id: latticeBox
        x: 128
        y: 20
        width: 220
        height: 200
        opacity: root.count === 0 ? 0.7 : 1

        Repeater {
            model: root.lattice
            Rectangle {
                required property var modelData
                x: modelData.x - 4
                y: modelData.y - 4
                width: 8
                height: 8
                radius: 4
                color: Tokens.ice
                opacity: 0.22
            }
        }
        Repeater {
            model: root.clusterDots
            Rectangle {
                required property var modelData
                x: modelData.x
                y: modelData.y
                width: modelData.s
                height: modelData.s
                radius: modelData.s * 0.5
                color: modelData.c
                opacity: modelData.o
            }
        }
    }
}
