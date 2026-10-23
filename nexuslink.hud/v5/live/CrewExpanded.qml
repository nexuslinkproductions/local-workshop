pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// CrewExpanded.qml - v5 crew focus view: back chevron of five dots, title
// CREW, session count, up to 12 rows sorted by tokens descending. Each row is
// a title (22 px, elided), model and idle (16 px dim) and a 20 dot token bar
// (200 000 tokens full scale, acid while live). Children sit indented under
// their parent with a small dot bullet. Total tokens as a dot row at the
// bottom. No boxes, no action buttons.
//
// Same adapter contract as CrewWidget: `crew` may be the raw v4 crew object,
// an array of session rows, or { sessions: [...] }; undefined, null and {}
// render an empty state. live is activity says streaming/receiving/starting a
// turn, or active within the last 60 s.
Item {
    id: root

    property var crew: ({})
    signal closeRequested()

    width: 1100
    height: 760
    focus: true
    Keys.onEscapePressed: root.closeRequested()

    readonly property int maxRows: 12
    readonly property real tokenScale: 200000

    // ---- adapter (kept in step with CrewWidget.qml) -----------------------
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
        return {
            "id": str(s.id) || str(s.full) || ("s" + i),
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
                    "id": str(b.name) || ("bot" + i), "parent": "",
                    "model": model,
                    "tokens": Math.max(0, num(b.tokens_24h, 0)),
                    "idle_s": la > 0 ? Math.max(0, now - la) : -1,
                    "title": str(b.current_title), "activity": str(b.state),
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
                    "parent": "", "model": model,
                    "tokens": Math.round(share), "idle_s": idle,
                    "title": str(e[2]), "activity": str(b.state),
                    "live": end < 0 && idle >= 0 && idle <= 60
                })
            }
        }
        return out
    }
    function adapt(raw) {
        var now = nowSec(raw)
        var list = []
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
        for (var i = 0; i < list.length; i++) {
            var r = norm(list[i], i, now, "", 0)
            if (r !== null)
                out.push(r)
        }
        return out
    }
    readonly property var sessions: root.adapt(root.crew)

    function fmtTokens(n) {
        var v = Number(n) || 0
        if (v >= 1000000)
            return (v / 1000000).toFixed(v >= 10000000 ? 0 : 1) + "M"
        if (v >= 1000)
            return Math.round(v / 1000) + "K"
        return String(Math.round(v))
    }
    function fmtIdle(s) {
        if (s < 0)
            return "--"
        if (s < 60)
            return Math.round(s) + "s"
        if (s < 3600)
            return Math.round(s / 60) + "m"
        if (s < 86400)
            return Math.round(s / 3600) + "h"
        return Math.round(s / 86400) + "d"
    }

    // Trailing parent grouping: a child is drawn after its parent when the
    // parent made the cut; otherwise it is drawn at root indent.
    readonly property var rows: {
        var src = root.sessions.slice(0)
        src.sort(function (a, b) {
            if (a.tokens !== b.tokens) return b.tokens - a.tokens
            return a.id < b.id ? -1 : 1
        })
        var byId = {}
        for (var i = 0; i < src.length; i++)
            byId[src[i].id] = src[i]
        var seen = {}
        var out = []
        function emit(s, depth) {
            if (out.length >= root.maxRows || seen[s.id])
                return
            seen[s.id] = true
            out.push({ "s": s, "depth": depth })
            for (var k = 0; k < src.length; k++)
                if (src[k].parent === s.id)
                    emit(src[k], depth + 1)
        }
        for (i = 0; i < src.length && out.length < root.maxRows; i++) {
            var s = src[i]
            if (s.parent !== "" && byId[s.parent] !== undefined
                    && !seen[s.parent])
                continue
            emit(s, 0)
        }
        // rows that reference a parent outside the cut still get drawn
        for (i = 0; i < src.length && out.length < root.maxRows; i++)
            if (!seen[src[i].id])
                emit(src[i], 0)
        for (i = 0; i < out.length; i++) {
            var filled = Math.round(out[i].s.tokens / root.tokenScale * 20)
            var bars = []
            for (var b = 0; b < 20; b++)
                bars.push(b < Math.max(out[i].s.tokens > 0 ? 1 : 0,
                                       Math.min(20, filled)))
            out[i].bars = bars
        }
        return out
    }
    readonly property var totalTokens: {
        var t = 0
        for (var i = 0; i < root.sessions.length; i++)
            t += root.sessions[i].tokens
        return t
    }

    // ---- header ----------------------------------------------------------
    Item {
        id: back
        x: 44
        y: 40
        width: 44
        height: 44
        Repeater {
            model: [
                { "x": 12, "y": 0 }, { "x": 6, "y": 8 },
                { "x": 0, "y": 16 }, { "x": 6, "y": 24 },
                { "x": 12, "y": 32 }
            ]
            Rectangle {
                required property var modelData
                x: modelData.x
                y: modelData.y
                width: 5
                height: 5
                radius: 2.5
                color: Tokens.ice
                opacity: 0.85
            }
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -8
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeRequested()
        }
    }

    Text {
        id: title
        x: 112
        y: 30
        text: qsTr("CREW")
        color: Tokens.ink
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: 44
        font.letterSpacing: Tokens.trackLabel * 44 * 0.4
        renderType: Text.NativeRendering
    }
    Text {
        id: sub
        x: 114
        y: 84
        text: root.sessions.length + " SESSIONS  /  " + root.fmtTokens(root.totalTokens) + " TOKENS"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: 16
        font.letterSpacing: Tokens.trackLabel * 16
        renderType: Text.NativeRendering
    }

    // ---- rows ------------------------------------------------------------
    Item {
        id: table
        x: 48
        y: 156
        width: 1004
        height: 560

        Repeater {
            model: root.rows
            Item {
                id: rowItem
                required property var modelData
                required property int index
                width: table.width
                height: 46
                y: index * 46
                readonly property var sess: modelData.s
                readonly property int indent: modelData.depth > 0 ? 26 : 0

                Rectangle {
                    x: 0
                    y: 9
                    width: 6
                    height: 6
                    radius: 3
                    visible: rowItem.indent > 0
                    color: Tokens.ice
                    opacity: 0.55
                }

                Text {
                    x: 4
                    y: 6
                    width: 470 - rowItem.indent
                    text: rowItem.sess.title !== "" ? rowItem.sess.title : qsTr("untitled")
                    color: Tokens.ink
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightRegular
                    font.pixelSize: 22
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    renderType: Text.NativeRendering
                }
                Text {
                    x: 492
                    y: 9
                    width: 150
                    text: rowItem.sess.model !== "" ? rowItem.sess.model : "--"
                    color: Tokens.textDim
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightRegular
                    font.pixelSize: 16
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    renderType: Text.NativeRendering
                }
                Text {
                    x: 650
                    y: 9
                    width: 56
                    text: root.fmtIdle(rowItem.sess.idle_s)
                    color: Tokens.textDim
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightRegular
                    font.pixelSize: 16
                    renderType: Text.NativeRendering
                }
                Row {
                    x: 730 + rowItem.indent
                    y: 13
                    spacing: 10
                    Repeater {
                        model: rowItem.modelData.bars
                        Rectangle {
                            required property bool modelData
                            width: 6
                            height: 6
                            radius: 3
                            color: modelData
                                ? (rowItem.sess.live ? Tokens.acid : Tokens.ice)
                                : Tokens.ice
                            opacity: modelData ? (rowItem.sess.live ? 0.95 : 0.75) : 0.18
                        }
                    }
                }
            }
        }
    }

    // ---- total -----------------------------------------------------------
    Item {
        id: footer
        x: 48
        y: 706
        width: 1004
        height: 24

        Text {
            id: totalLabel
            x: 0
            y: 0
            text: qsTr("TOTAL")
            color: Tokens.textLabel
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightMedium
            font.pixelSize: 16
            font.letterSpacing: Tokens.trackLabel * 16
            renderType: Text.NativeRendering
        }
        Text {
            x: 96
            y: 0
            text: root.fmtTokens(root.totalTokens)
            color: Tokens.ink
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightRegular
            font.pixelSize: 16
            renderType: Text.NativeRendering
        }
        Row {
            x: 730
            y: 5
            spacing: 10
            Repeater {
                model: 40
                Rectangle {
                    required property int index
                    width: 6
                    height: 6
                    radius: 3
                    color: Tokens.ice
                    opacity: (index * 250000) < root.totalTokens ? 0.7 : 0.16
                }
            }
        }
    }
}
