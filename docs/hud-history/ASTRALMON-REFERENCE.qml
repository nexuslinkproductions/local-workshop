// The astralmon cockpit as a pure-QtQuick scene — no WebEngine, no external
// effect modules. Polls <serviceUrl>/json and renders reactor, conduits,
// dials and traces. Reused by the wallpaper wrapper (main.qml) and runnable
// standalone with /usr/lib/qt6/bin/qml for development.
import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

Item {
    id: hud
    width: 1600
    height: 900

    property string serviceUrl: "http://127.0.0.1:9835"
    property int pollMs: 1000
    // Optional Home Assistant feed. Which panels exist, which entities they
    // show and how each reads are described by /etc/astralmon/ha.toml and
    // served at <serviceUrl>/panels — nothing about anyone's sensors is
    // compiled in here. The credentials stay local to this wallpaper.
    property string haUrl: ""
    property string haToken: ""
    property var ha: ({})
    property var haPanels: []    // layout, from the service
    property var haEntities: []  // flat entity list, ditto
    readonly property bool haOn: haUrl !== "" && haToken !== "" && haPanels.length > 0
    // Public-IP readout. Empty disables it and the NETWORK panel shows "--";
    // it is the one thing here that reaches outside the LAN.
    property string pubIpUrl: "https://icanhazip.com"

    // Typeface. The web HUD asks for Orbitron, and it was tried here: it does
    // look more like a cockpit, and it is harder to read. On a panel whose
    // job is to be glanced at, legibility wins, so the default stays the
    // monospace this view has always used — it also keeps numeric columns
    // aligned as values change width, which a display face does not.
    //
    // Settable, because that is a taste call and not everyone will share it.
    property string fontFamily: "monospace"

    // palette (matches the /hud web page)
    readonly property color cLine: "#1fb6dc"
    readonly property color cLineDim: "#0d4a61"
    readonly property color cTxt: "#c9f2fb"
    readonly property color cTxtDim: "#5e93a6"
    readonly property color cAccent: "#35e0ff"
    readonly property color cWarn: "#ffb020"
    readonly property color cAlert: "#ff3b4e"
    readonly property color cOk: "#39d98a"
    readonly property color cOrange: "#ff8a3d"
    readonly property color frameCol: alert ? cAlert : cLine

    property var num: ({})
    property var str: ({})
    property bool linkOk: false
    property bool alert: (num["alarm.active"] || 0) > 0
    property var histBoard: []
    property var histConn: []
    readonly property real ux: Math.max(0.75, Math.min(width / 1500, height / 845))
    readonly property real m: 14 * ux

    function g(k, d) {
        var v = num[k]
        return v === undefined ? (d === undefined ? NaN : d) : v
    }
    function fmt(v, p, u) {
        return (v === undefined || v === null || isNaN(v)) ? "--"
                                                           : v.toFixed(p) + (u || "")
    }

    function refresh() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try {
                    var d = JSON.parse(xhr.responseText)
                    hud.num = d.num || {}
                    hud.str = d.str || {}
                    var hb = histBoard.slice(-239)
                    hb.push(g("nvml.power.w", 0))
                    histBoard = hb
                    var hc = histConn.slice(-239)
                    hc.push(g("pin.total.w"))
                    histConn = hc
                    linkOk = true
                } catch (e) { linkOk = false }
            } else {
                linkOk = false
            }
        }
        xhr.open("GET", serviceUrl + "/json")
        xhr.send()
    }
    Timer {
        interval: hud.pollMs; running: true; repeat: true
        triggeredOnStart: true
        onTriggered: hud.refresh()
    }

    function haGet(k, d) {
        var v = ha[k]
        return v === undefined ? (d === undefined ? NaN : d) : v
    }
    // The layout is fetched once and retried until it arrives, because the
    // wallpaper often starts before the service does.
    function panelsRefresh() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
            try {
                var d = JSON.parse(xhr.responseText)
                hud.haPanels = d.panels || []
                hud.haEntities = d.entities || []
            } catch (err) {}
        }
        xhr.open("GET", hud.serviceUrl + "/panels")
        xhr.send()
    }
    Timer {
        interval: 30000; repeat: true; triggeredOnStart: true
        running: hud.haPanels.length === 0
        onTriggered: hud.panelsRefresh()
    }

    // Renders one part of a row: a plain number with its unit, or a duration.
    function haPartFmt(p, v) {
        if (v === undefined || v === null || isNaN(v)) return "--"
        if (p.format === "duration") return hud.runtimeFmt(v)
        return v.toFixed(p.decimals || 0) + (p.unit || "")
    }
    function haRowText(row) {
        var out = []
        for (var i = 0; i < row.parts.length; i++)
            out.push(hud.haPartFmt(row.parts[i], hud.haGet(row.parts[i].entity)))
        return out.join(row.sep === undefined ? " · " : row.sep)
    }
    // Colour follows the row's FIRST part: a fused row like "21.4°C · 45%" is
    // one reading with context, not two readings competing to set the colour.
    function haRowColor(row) {
        var v = hud.haGet(row.parts[0].entity)
        if (isNaN(v)) return hud.cAccent
        if (row.alert_above !== undefined && v > row.alert_above) return hud.cAlert
        if (row.alert_below !== undefined && v < row.alert_below) return hud.cAlert
        if (row.warn_above !== undefined && v > row.warn_above) return hud.cWarn
        if (row.warn_below !== undefined && v < row.warn_below) return hud.cWarn
        return hud.cAccent
    }

    function haRefresh() {
        hud.haEntities.forEach(function(e) {
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function() {
                if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
                try {
                    var v = parseFloat(JSON.parse(xhr.responseText).state)
                    var copy = {}
                    for (var k in hud.ha) copy[k] = hud.ha[k]
                    copy[e] = v
                    hud.ha = copy
                } catch (err) {}
            }
            xhr.open("GET", hud.haUrl + "/api/states/" + e)
            xhr.setRequestHeader("Authorization", "Bearer " + hud.haToken)
            xhr.send()
        })
    }
    Timer {
        interval: 15000; running: hud.haOn; repeat: true
        triggeredOnStart: true
        onTriggered: hud.haRefresh()
    }
    property string pubIp: ""
    function pubIpRefresh() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200)
                hud.pubIp = xhr.responseText.trim()
        }
        xhr.open("GET", hud.pubIpUrl)
        xhr.send()
    }
    Timer {
        interval: 300000; running: hud.pubIpUrl !== ""; repeat: true
        triggeredOnStart: true
        onTriggered: hud.pubIpRefresh()
    }

    // Wall clock, drawn as a seven-segment display below the conduits.
    property string clockTime: ""
    property string clockDate: ""
    function clockTick() {
        var d = new Date()
        function p2(n) { return (n < 10 ? "0" : "") + n }
        clockTime = p2(d.getHours()) + ":" + p2(d.getMinutes())
        clockDate = p2(d.getDate()) + "." + p2(d.getMonth() + 1) + "." + d.getFullYear()
    }
    Timer {
        interval: 1000; running: true; repeat: true
        triggeredOnStart: true
        onTriggered: hud.clockTick()
    }
    property bool colonOn: true
    Timer {
        interval: 500; running: true; repeat: true
        onTriggered: hud.colonOn = !hud.colonOn
    }

    function runtimeFmt(secs) {
        if (isNaN(secs)) return "--"
        if (secs >= 3600) {
            var h = Math.floor(secs / 3600)
            var m = Math.floor((secs % 3600) / 60)
            return h + "h " + (m < 10 ? "0" : "") + m + "m"
        }
        return Math.floor(secs / 60) + "m " + Math.floor(secs % 60) + "s"
    }
    // Why the per-pin panel is empty. Most cards have no such sensor at all,
    // and saying "OFFLINE" at those users describes a fault that is not
    // happening; only the last case here is actually one.
    function pinStatusText() {
        switch (hud.str["status.it8915"]) {
        case "unsupported-board": return "— NOT ON THIS BOARD —"
        case "no-permission":     return "— NO I2C ACCESS —"
        case "disabled":          return "— SENSOR DISABLED —"
        case "no-i2c-bus":        return "— NO I2C BUS —"
        default:                  return "— SENSOR OFFLINE —"
        }
    }
    function pinStatusHint() {
        switch (hud.str["status.it8915"]) {
        case "unsupported-board": return "no per-pin sensor on this GPU"
        case "no-permission":     return "add your user to the i2c group"
        case "disabled":          return "enable it in astralmon.toml"
        case "no-i2c-bus":        return "is the i2c-dev module loaded?"
        default:                  return ""
        }
    }
    function rateFmt(kbs) {
        if (isNaN(kbs)) return "--"
        return kbs >= 1024 ? (kbs / 1024).toFixed(1) + " MB/s" : kbs.toFixed(0) + " kB/s"
    }
    // How many cores the service is reporting. Counted from the data rather
    // than hardcoded or read from a config: the panel should draw whatever
    // the machine has, and this HUD runs on machines that are not this one.
    // Rebinds whenever num is replaced, which is once per poll.
    readonly property int coreCount: {
        var n = 0
        while (hud.num["sys.cpu.core." + n + ".mhz"] !== undefined) n++
        return n
    }
    // Uptime for the systems panel. Days get their own field rather than
    // rolling into hours, because "17d 04:12" is legible at a glance and
    // "412h 12m" is arithmetic. runtimeFmt above is for short spans and
    // deliberately left alone.
    function uptimeFmt(secs) {
        if (isNaN(secs)) return "--"
        function p2(n) { return (n < 10 ? "0" : "") + n }
        var d = Math.floor(secs / 86400)
        var h = Math.floor((secs % 86400) / 3600)
        var m = Math.floor((secs % 3600) / 60)
        return (d > 0 ? d + "d " : "") + p2(h) + ":" + p2(m)
    }

    // ── WireView screen control ──────────────────────────────────────────
    // The page names the service accepts, in the order its own button walks
    // them. Names only: the wallpaper never sees or sends a command byte.
    readonly property var wvPages: ["main", "simple", "current", "temp", "status"]
    property int wvPage: 0
    property string wvBtnMsg: ""          // transient feedback, "" = idle
    readonly property bool wvAvailable: hud.g("avail.wireview", 0) > 0
    function wvPageName() { return wvPages[wvPage % wvPages.length].toUpperCase() }
    function wvNextScreen() {
        const next = wvPages[(wvPage + 1) % wvPages.length]
        const xhr = new XMLHttpRequest()
        xhr.open("POST", hud.serviceUrl + "/control/screen?page=" + next)
        // Not a CORS-simple header, deliberately: the service requires it, so
        // a stray web page cannot fire this endpoint without a preflight that
        // the service declines to answer.
        xhr.setRequestHeader("X-Astralmon-Control", "1")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                hud.wvPage = (hud.wvPage + 1) % hud.wvPages.length
                hud.wvBtnMsg = ""
                hud.wvFlash = true
                wvFlashOff.restart()
            } else if (xhr.status === 403) {
                // Almost always the config gate rather than anything broken,
                // and saying so beats a silent dead button.
                hud.wvBtnMsg = "SCREEN CONTROL OFF"
                wvMsgClear.restart()
            } else {
                hud.wvBtnMsg = "NO RESPONSE"
                wvMsgClear.restart()
            }
        }
        xhr.send()
    }
    Timer { id: wvMsgClear; interval: 2500; onTriggered: hud.wvBtnMsg = "" }
    property bool wvFlash: false
    Timer { id: wvFlashOff; interval: 220; onTriggered: hud.wvFlash = false }

    // ── reusable pieces ──────────────────────────────────────────────────
    // A small bordered readout in the panel's own vocabulary: same fill and
    // hairline as the bar backgrounds, so it reads as part of the instrument
    // rather than as something bolted on.
    component WvTempBox: Rectangle {
        id: tempBox
        property string label: ""
        property real value: NaN
        property string extra: ""
        property string icon: ""
        // Ink a little short of the box height. The glyph's ink is roughly
        // 0.72 of its point size, so the font has to be asked for noticeably
        // more than the diameter actually wanted.
        property real iconSize: tempBox.height * 0.86
        // Defaults to the temperature's own colour so a badge sitting beside
        // it reads as part of the same reading unless it has something of its
        // own to say.
        property color extraColor: tempBox.valueColor
        // Well clear of the 53.6 °C this connector settles at under a
        // sustained 600 W, so a lit threshold means something unusual
        // rather than "the card is busy".
        readonly property color valueColor:
            value >= 85 ? hud.cAlert : value >= 70 ? hud.cWarn : hud.cAccent
        height: 30 * hud.ux
        color: Qt.rgba(0.05, 0.29, 0.38, 0.25)
        border.width: 1
        border.color: hud.cLineDim
        TLabel {
            anchors { left: parent.left; leftMargin: 5 * hud.ux
                      top: parent.top; topMargin: 3 * hud.ux }
            text: parent.label
            color: hud.cTxtDim
            font.pixelSize: 9.4 * hud.ux
            font.letterSpacing: 1.2 * hud.ux
        }
        TLabel {
            anchors { left: parent.left; leftMargin: 5 * hud.ux
                      bottom: parent.bottom; bottomMargin: 2 * hud.ux }
            text: isNaN(parent.value) ? "--" : hud.fmt(parent.value, 1, "°C")
            color: tempBox.valueColor
            font.pixelSize: 13.4 * hud.ux
        }
        // The badge sits on the right, sized so its ink is a little short of
        // the box height — big enough to read the colour at a glance from
        // across the room, which is the whole point of it. Set in em terms
        // rather than pixels because the glyph's ink is roughly 0.72 of its
        // point size, so asking for 26 px of fan means asking for ~36 px of
        // font.
        TLabel {
            id: badge
            anchors { right: parent.right; rightMargin: 6 * hud.ux
                      verticalCenter: parent.verticalCenter }
            text: parent.icon
            visible: text !== ""
            color: tempBox.extraColor
            font.pixelSize: tempBox.iconSize
        }
        TLabel {
            anchors { right: badge.visible ? badge.left : parent.right
                      rightMargin: 5 * hud.ux
                      verticalCenter: parent.verticalCenter }
            text: parent.extra
            visible: text !== ""
            color: tempBox.extraColor
            font.pixelSize: 11 * hud.ux
        }
    }
    component TLabel: Text {
        color: hud.cTxt
        font.family: hud.fontFamily
        font.pixelSize: 14.6 * hud.ux
    }
    component Bracket: Item {
        // one L-shaped corner mark; rotate for the other corners
        property color col: hud.frameCol
        width: 12 * hud.ux; height: 12 * hud.ux
        Rectangle { width: parent.width; height: 2; color: parent.col }
        Rectangle { width: 2; height: parent.height; color: parent.col }
    }
    component HudPanel: Item {
        id: panel
        property string title: ""
        default property alias content: inner.data
        // Corner cut, matching the web HUD's clip-path. Top-left and
        // bottom-right only — the other two keep their brackets, so every
        // corner gets exactly one treatment instead of both fighting.
        readonly property real chamfer: 14 * hud.ux

        Shape {
            anchors.fill: parent
            // Straight lines only, so the default geometry renderer is right.
            // CurveRenderer costs a much heavier fragment shader for curve
            // antialiasing there is nothing here to antialias.
            asynchronous: false
            ShapePath {
                fillColor: Qt.rgba(0.024, 0.11, 0.18, 0.62)
                strokeColor: hud.frameCol
                strokeWidth: 1
                startX: panel.chamfer; startY: 0
                PathLine { x: panel.width; y: 0 }
                PathLine { x: panel.width; y: panel.height - panel.chamfer }
                PathLine { x: panel.width - panel.chamfer; y: panel.height }
                PathLine { x: 0; y: panel.height }
                PathLine { x: 0; y: panel.chamfer }
                PathLine { x: panel.chamfer; y: 0 }
            }
        }
        Bracket { anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 3; rotation: 90 }
        Bracket { anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 3; rotation: 270 }
        TLabel {
            id: titleText
            text: parent.title
            color: hud.cAccent
            font.pixelSize: 13.4 * hud.ux
            font.letterSpacing: 3 * hud.ux
            anchors { top: parent.top; left: parent.left; right: parent.right
                      topMargin: 10 * hud.ux; leftMargin: 10 * hud.ux
                      rightMargin: 10 * hud.ux }
            // Titles must fit whatever font the machine actually has. Orbitron
            // is far wider than the monospace fallback, and "⚡ POWER CONDUITS
            // · 12V-2x6" overran its panel the moment the font changed. Shrink
            // to fit rather than eliding: the board name is the useful part.
            horizontalAlignment: Text.AlignLeft
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 8
            elide: Text.ElideRight
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: hud.cAccent
                shadowBlur: 0.7
                shadowOpacity: 0.55
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }
        }
        Rectangle {
            anchors { top: titleText.bottom; topMargin: 5 * hud.ux
                      left: parent.left; leftMargin: 10 * hud.ux }
            width: parent.width * 0.55; height: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: hud.frameCol }
                GradientStop { position: 1; color: "transparent" }
            }
        }
        Item {
            id: inner
            anchors { fill: parent; topMargin: 35 * hud.ux
                      leftMargin: 10 * hud.ux; rightMargin: 10 * hud.ux
                      bottomMargin: 10 * hud.ux }
        }
    }
    component Dial: Item {
        property string label: ""
        property real value: NaN
        property real vmax: 100
        property real warn: 101
        property real crit: 101
        readonly property color col: isNaN(value) ? hud.cLineDim
                                     : value >= crit ? hud.cAlert
                                     : value >= warn ? hud.cWarn : hud.cAccent
        Canvas {
            id: dialCanvas
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var cx = width / 2, cy = height / 2
                var r = Math.min(width, height) / 2 - 5 * hud.ux
                var a0 = Math.PI * 0.75, span = Math.PI * 1.5
                ctx.lineWidth = 5 * hud.ux
                ctx.strokeStyle = hud.cLineDim
                ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span); ctx.stroke()
                var frac = isNaN(parent.value) ? 0 : Math.min(parent.value / parent.vmax, 1)
                if (frac > 0) {
                    ctx.strokeStyle = parent.col
                    ctx.shadowColor = parent.col
                    ctx.shadowBlur = 6 * hud.ux
                    ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span * frac); ctx.stroke()
                }
            }
            Connections {
                target: dialCanvas.parent
                function onValueChanged() { dialCanvas.requestPaint() }
                function onColChanged() { dialCanvas.requestPaint() }
            }
        }
        TLabel {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -4 * hud.ux
            text: hud.fmt(parent.value, 0)
            font.pixelSize: 18.3 * hud.ux
        }
        TLabel {
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
            text: parent.label
            color: hud.cTxtDim
            font.pixelSize: 9.8 * hud.ux
            font.letterSpacing: 1.5 * hud.ux
        }
    }
    component Meter: Item {
        id: meterRoot
        property string label: ""
        property string valueText: "--"
        property real frac: 0
        property color barColor: hud.cAccent
        height: 26 * hud.ux
        TLabel { text: parent.label; color: hud.cTxtDim; font.pixelSize: 11.0 * hud.ux; font.letterSpacing: 2 * hud.ux }
        TLabel {
            anchors.right: parent.right
            text: parent.valueText; color: hud.cTxt; font.pixelSize: 11.0 * hud.ux
        }
        Rectangle {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 8 * hud.ux
            color: "transparent"; border.width: 1; border.color: hud.cLineDim
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
                width: Math.max(0, (parent.width - 2) * Math.min(meterRoot.frac, 1))
                color: meterRoot.barColor
                Behavior on width { NumberAnimation { duration: 500 } }
            }
        }
    }
    // Seven-segment display drawn on a canvas: no font dependency, and the
    // unlit "ghost" segments are what make it read as a real LED clock.
    component SevenSeg: Canvas {
        id: seg
        property string value: ""
        property real digitH: 30
        property color col: hud.cAccent
        property bool colonOn: true
        readonly property real dw: digitH * 0.58
        readonly property real th: Math.max(2, digitH * 0.13)
        readonly property real sp: digitH * 0.14
        function charW(ch) {
            return ch === ":" ? digitH * 0.20 : ch === "." ? digitH * 0.18 : dw
        }
        width: {
            var w = 0
            for (var i = 0; i < value.length; i++) w += charW(value.charAt(i)) + sp
            return Math.max(1, w - sp)
        }
        height: digitH
        onValueChanged: requestPaint()
        onColChanged: requestPaint()
        onColonOnChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var SEG = {"0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd",
                       "4": "fgbc", "5": "afgcd", "6": "afgedc", "7": "abc",
                       "8": "abcdefg", "9": "abcdfg", "-": "g"}
            function hbar(x, y, len) {
                ctx.beginPath()
                ctx.moveTo(x, y + th / 2)
                ctx.lineTo(x + th / 2, y)
                ctx.lineTo(x + len - th / 2, y)
                ctx.lineTo(x + len, y + th / 2)
                ctx.lineTo(x + len - th / 2, y + th)
                ctx.lineTo(x + th / 2, y + th)
                ctx.closePath(); ctx.fill()
            }
            function vbar(x, y, len) {
                ctx.beginPath()
                ctx.moveTo(x + th / 2, y)
                ctx.lineTo(x + th, y + th / 2)
                ctx.lineTo(x + th, y + len - th / 2)
                ctx.lineTo(x + th / 2, y + len)
                ctx.lineTo(x, y + len - th / 2)
                ctx.lineTo(x, y + th / 2)
                ctx.closePath(); ctx.fill()
            }
            function drawSeg(name, x, y) {
                var h = seg.digitH, w = seg.dw, half = h / 2
                var hl = w - 1.5 * th, vl = half - 1.25 * th
                if (name === "a") hbar(x + 0.75 * th, y, hl)
                else if (name === "g") hbar(x + 0.75 * th, y + half - th / 2, hl)
                else if (name === "d") hbar(x + 0.75 * th, y + h - th, hl)
                else if (name === "f") vbar(x, y + 0.75 * th, vl)
                else if (name === "b") vbar(x + w - th, y + 0.75 * th, vl)
                else if (name === "e") vbar(x, y + half + 0.5 * th, vl)
                else if (name === "c") vbar(x + w - th, y + half + 0.5 * th, vl)
            }
            var all = "abcdefg"
            var cx = 0
            for (var i = 0; i < value.length; i++) {
                var ch = value.charAt(i)
                if (ch === ":") {
                    ctx.fillStyle = String(col)
                    ctx.globalAlpha = seg.colonOn ? 1 : 0.11
                    var ds = th * 0.95
                    ctx.fillRect(cx, digitH * 0.30 - ds / 2, ds, ds)
                    ctx.fillRect(cx, digitH * 0.70 - ds / 2, ds, ds)
                    ctx.globalAlpha = 1
                } else if (ch === ".") {
                    ctx.fillStyle = String(col)
                    var dd = th * 0.95
                    ctx.fillRect(cx, digitH - dd, dd, dd)
                } else {
                    var lit = SEG[ch] || ""
                    // unlit segments first, then the lit ones over them
                    ctx.globalAlpha = 0.11
                    ctx.fillStyle = String(col)
                    for (var k = 0; k < all.length; k++)
                        if (lit.indexOf(all.charAt(k)) < 0) drawSeg(all.charAt(k), cx, 0)
                    ctx.globalAlpha = 1
                    for (var j = 0; j < lit.length; j++) drawSeg(lit.charAt(j), cx, 0)
                }
                cx += charW(ch) + sp
            }
        }
    }
    component KvRow: Item {
        property string k: ""
        property string v: "--"
        property color vc: hud.cAccent   // thresholds recolour the value only
        width: parent ? parent.width : 100
        height: 21 * hud.ux
        TLabel { text: parent.k; color: hud.cTxtDim; font.pixelSize: 12.8 * hud.ux }
        TLabel { anchors.right: parent.right; text: parent.v; color: parent.vc; font.pixelSize: 12.8 * hud.ux }
    }

    // A dashed ring turning slowly inside a gauge — the web HUD's #rrot, one
    // turn every 28 s. It carries no information; it is there so an idle
    // instrument still looks powered.
    //
    // Painted once and spun by the scene graph via RotationAnimator, which
    // runs on the render thread and never triggers a repaint. That matters
    // here more than it would elsewhere: this is a wallpaper, so it runs
    // forever, on the machine whose wattage it is displaying.
    component IdleRing: Item {
        id: idle
        property real radiusFrac: 0.43
        property color col: hud.cLine
        property int dashes: 36
        // Static. It began as a slowly turning ring, copying the web HUD, and
        // that cost 30 W: continuous animation keeps the GPU from dropping to
        // a low power state, so the card sat at P0/P3 rather than P5/P8 and
        // burned the difference around the clock. A wallpaper reporting GPU
        // watts has no business inflating them for decoration.
        //
        // The browser gets away with it because its compositor is not what
        // this card is being judged on. Here the ring is drawn once and never
        // moves, which keeps the instrument face and costs nothing.
        //
        // Plain rectangles rather than a Canvas, and never a child of the
        // gauge it decorates: a Canvas nested inside the gauge's own Canvas
        // forced the parent to re-render its framebuffer every frame.
        Repeater {
            model: idle.dashes
            delegate: Rectangle {
                required property int index
                readonly property real ang: index * 2 * Math.PI / idle.dashes
                readonly property real rad: idle.width * idle.radiusFrac
                width: Math.max(2, 2 * Math.PI * rad / idle.dashes * 0.45)
                height: Math.max(1, 1.1 * hud.ux)
                color: idle.col
                opacity: 0.38
                antialiasing: false
                x: idle.width / 2 + rad * Math.cos(ang) - width / 2
                y: idle.height / 2 + rad * Math.sin(ang) - height / 2
                rotation: index * 360 / idle.dashes + 90
            }
        }
    }

    // ── background: deep space + starfield ───────────────────────────────
    Rectangle { anchors.fill: parent; color: "#020a12" }
    Canvas {
        id: bgCanvas
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var grd = ctx.createRadialGradient(width / 2, height * 0.42, 0,
                                               width / 2, height * 0.42, width * 0.62)
            grd.addColorStop(0, "#0a2b47")
            grd.addColorStop(0.55, "#04141f")
            grd.addColorStop(1, "#020a12")
            ctx.fillStyle = grd
            ctx.fillRect(0, 0, width, height)
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
    Repeater {
        model: 90
        Rectangle {
            width: (index % 3 === 0 ? 2 : 1)
            height: width
            color: "#9adcee"
            x: Math.random() * hud.width
            y: Math.random() * hud.height
            opacity: 0.15 + Math.random() * 0.4
            SequentialAnimation on opacity {
                loops: Animation.Infinite
                NumberAnimation { to: 0.08; duration: 1200 + Math.random() * 3000 }
                NumberAnimation { to: 0.55; duration: 1200 + Math.random() * 3000 }
            }
        }
    }

    // ── header ───────────────────────────────────────────────────────────
    HudPanel {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: hud.m }
        height: 46 * hud.ux
        TLabel {
            id: logo
            anchors { left: parent.left; leftMargin: 14 * hud.ux; verticalCenter: parent.verticalCenter }
            text: "✦ ASTRALMON"
            color: hud.cAccent
            font.pixelSize: 18.3 * hud.ux
            font.letterSpacing: 4 * hud.ux
        }
        TLabel {
            anchors { left: logo.right; leftMargin: 18 * hud.ux; verticalCenter: parent.verticalCenter }
            text: (hud.str["nvml.name"] || "CONNECTING…").toUpperCase()
            color: hud.cTxtDim
            font.pixelSize: 12.8 * hud.ux
            font.letterSpacing: 2 * hud.ux
        }
        TLabel {
            id: statusChip
            anchors { right: linkLabel.left; rightMargin: 26 * hud.ux; verticalCenter: parent.verticalCenter }
            text: hud.alert ? "⚠ RED ALERT ⚠" : "SYSTEMS NOMINAL"
            color: hud.alert ? hud.cAlert : hud.cOk
            font.pixelSize: 14.0 * hud.ux
            font.letterSpacing: 3.5 * hud.ux
            SequentialAnimation on opacity {
                running: hud.alert; loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { to: 0.25; duration: 420 }
                NumberAnimation { to: 1.0; duration: 420 }
            }
        }
        TLabel {
            id: linkLabel
            anchors { right: parent.right; rightMargin: 14 * hud.ux; verticalCenter: parent.verticalCenter }
            text: hud.linkOk ? "LINK ▮▮▮" : "LINK LOST"
            color: hud.linkOk ? hud.cOk : hud.cAlert
            font.pixelSize: 11.6 * hud.ux
            font.letterSpacing: 2 * hud.ux
        }
    }

    // ── power conduits (left) ────────────────────────────────────────────
    HudPanel {
        id: conduits
        title: "⚡ POWER CONDUITS · 12V-2x6"
        anchors { top: header.bottom; left: parent.left; bottom: bottomRow.top; margins: hud.m }
        width: 308 * hud.ux
        readonly property bool havePins: hud.num["pin.0.a"] !== undefined
        // Weakest pin's watts over the strongest: 1.00 is perfect sharing.
        // The sense is inverted versus the pin bars below — here a full bar
        // is good — so it gets its own heavier bar to read as the headline.
        readonly property real balance: hud.g("pin.balance", 1)
        readonly property color balCol: balance < 0.80 ? hud.cAlert
                                      : balance < 0.90 ? hud.cWarn : hud.cAccent
        Column {
            id: balanceBlock
            visible: conduits.havePins
            anchors { top: parent.top; left: parent.left; right: parent.right }
            spacing: 4 * hud.ux
            Item {
                width: parent.width
                height: 14 * hud.ux
                TLabel {
                    anchors.left: parent.left
                    text: "⚖ BALANCE"
                    color: hud.cAccent
                    font.pixelSize: 11.6 * hud.ux
                    font.letterSpacing: 1.5 * hud.ux
                }
                TLabel {
                    anchors.right: parent.right
                    text: hud.fmt(conduits.balance, 3)
                    color: conduits.balCol
                    font.pixelSize: 13.4 * hud.ux
                }
            }
            Rectangle {
                width: parent.width
                height: 17 * hud.ux
                color: Qt.rgba(0.05, 0.29, 0.38, 0.25)
                border.width: 1; border.color: hud.cLineDim
                Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
                    width: Math.max(0, (parent.width - 2) * Math.max(0, Math.min(conduits.balance, 1)))
                    color: conduits.balCol
                    Behavior on width { NumberAnimation { duration: 500 } }
                }
                // Threshold notches at the alert (0.80) and warn (0.90) lines.
                // They overhang the bar so they stay readable whether the fill
                // has reached them or not.
                Repeater {
                    model: [0.80, 0.90]
                    Rectangle {
                        required property real modelData
                        x: (parent.width - 2) * modelData
                        y: -3 * hud.ux
                        width: 1
                        height: parent.height + 6 * hud.ux
                        color: hud.cTxtDim
                    }
                }
            }
        }
        Column {
            id: pinsCol
            visible: conduits.havePins
            anchors { top: balanceBlock.bottom; topMargin: 12 * hud.ux
                      left: parent.left; right: parent.right }
            spacing: 6 * hud.ux
            Repeater {
                model: 6
                Item {
                    required property int index
                    readonly property real amps: hud.g("pin." + index + ".a", 0)
                    readonly property color col: amps > 9.2 ? hud.cAlert
                                                : amps > 8 ? hud.cWarn : hud.cAccent
                    // The same pin as the WireView sees it, on the cable side
                    // of the connector. NaN when no such device is attached,
                    // which is the normal case and draws nothing.
                    readonly property real wvAmps: hud.g("wv.pin." + index + ".a")
                    readonly property bool haveWv: !isNaN(wvAmps)
                    readonly property real dev: haveWv ? Math.abs(wvAmps - amps) : 0
                    // A cross-check, not a second reading of interest, so it
                    // gets a tick rather than a bar of its own.
                    //
                    // What the tick is *not* for: spotting a failing contact.
                    // The two shunts are in series on the same wire with the
                    // connector between them, so the same current flows past
                    // both and a degrading contact cannot make them disagree
                    // — it makes that pin carry less, which both report
                    // together, and it makes the connector hot. Imbalance in
                    // the bars and CONN OUT are the signals for that.
                    //
                    // What it is for: catching a sensor that has drifted or
                    // failed, reading past the IT8915FN's 20 mA quantisation
                    // at idle, and the one fault that genuinely separates
                    // them — a bridge between adjacent pins, where current
                    // enters on one wire and leaves on another. The pair sit
                    // up to ~0.19 A apart by fixed calibration, stable across
                    // reboots, so the thresholds start above that.
                    readonly property color wvCol: dev > 0.45 ? hud.cAlert
                                                 : dev > 0.25 ? hud.cWarn
                                                 : hud.cTxt
                    width: parent.width
                    height: 20 * hud.ux
                    TLabel { text: "P" + (index + 1); color: hud.cAccent; anchors.verticalCenter: parent.verticalCenter }
                    Rectangle {
                        id: barBg
                        anchors { left: parent.left; leftMargin: 26 * hud.ux
                                  right: parent.right; rightMargin: 78 * hud.ux
                                  verticalCenter: parent.verticalCenter }
                        height: 11 * hud.ux
                        color: Qt.rgba(0.05, 0.29, 0.38, 0.25)
                        border.width: 1; border.color: hud.cLineDim
                        Rectangle {
                            anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
                            width: Math.max(0, (parent.width - 2) * Math.min(amps / 9.5, 1))
                            color: col
                            Behavior on width { NumberAnimation { duration: 500 } }
                        }
                        // Where the WireView reads the same pin, on the same
                        // scale and in the same bar. The distance between the
                        // fill edge and this tick is the disagreement — one
                        // comparison in one place, instead of two bar lengths
                        // at different heights that the eye is poor at
                        // judging. It overhangs so it stays readable whether
                        // the fill has passed it or not.
                        Rectangle {
                            visible: haveWv
                            x: (parent.width - 2) * Math.min(wvAmps / 9.5, 1)
                            y: -3 * hud.ux
                            width: Math.max(2, 1.6 * hud.ux)
                            height: parent.height + 6 * hud.ux
                            color: wvCol
                            Behavior on x { NumberAnimation { duration: 500 } }
                        }
                    }
                    TLabel {
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        text: hud.fmt(amps, 2, "A ") + hud.fmt(hud.g("pin." + index + ".w"), 0, "W")
                        font.pixelSize: 11.6 * hud.ux
                    }
                }
            }
        }
        Column {
            visible: !conduits.havePins
            anchors.centerIn: parent
            spacing: 6 * hud.ux
            TLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                text: hud.pinStatusText()
                color: hud.cTxtDim
                font.letterSpacing: 3 * hud.ux
            }
            TLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: text !== ""
                text: hud.pinStatusHint()
                color: hud.cTxtDim
                font.pixelSize: 11 * hud.ux
                opacity: 0.75
            }
        }
        // Connector temperature, from the WireView's own two probes: inlet
        // under the pin labels, outlet under the watts. This is the number
        // that actually predicts a melted plug — the pin currents can look
        // perfectly balanced while a single contact cooks — and nothing else
        // on this panel can see it. Absent entirely without the device.
        Row {
            id: wvTempRow
            visible: !isNaN(hud.g("wv.temp.in")) || !isNaN(hud.g("wv.temp.out"))
            anchors { top: pinsCol.bottom; topMargin: 10 * hud.ux
                      left: parent.left; right: parent.right }
            spacing: 8 * hud.ux
            readonly property real boxW: (width - spacing) / 2
            WvTempBox {
                width: wvTempRow.boxW
                label: "⌁ CONN IN"
                value: hud.g("wv.temp.in")
            }
            WvTempBox {
                id: connOut
                width: wvTempRow.boxW
                label: "⌁ CONN OUT"
                value: hud.g("wv.temp.out")
                // The device's fan runs off this probe, so its state belongs
                // here rather than anywhere else on the panel: measured on
                // this connector it starts at 50.9 °C and steps up at
                // 53.5 °C, dropping back at 47.5 and 43.4 — hysteresis, so
                // it does not chatter around a threshold.
                readonly property real fanPct: hud.g("wv.fan.pct", 0)
                // Always shown, so its absence never has to be interpreted:
                // the rotor in the temperature's own colour means the fan is
                // idle, which is information too. Duty only appears once
                // there is a duty worth printing.
                icon: "✼"
                extra: fanPct > 0 ? hud.fmt(fanPct, 0, "%") : ""
                extraColor: fanPct <= 0 ? valueColor
                          : fanPct < 20 ? hud.cOrange : hud.cAlert
            }
        }
        // clock, centred in the space between the last pin and the totals
        Item {
            anchors { top: wvTempRow.visible ? wvTempRow.bottom : pinsCol.bottom
                      bottom: wvButton.visible ? wvButton.top : aggCol.top
                      left: parent.left; right: parent.right }
            Column {
                anchors.centerIn: parent
                spacing: 6 * hud.ux
                SevenSeg {
                    anchors.horizontalCenter: parent.horizontalCenter
                    value: hud.clockTime
                    digitH: 40 * hud.ux
                    col: hud.cAccent
                    colonOn: hud.colonOn
                }
                SevenSeg {
                    anchors.horizontalCenter: parent.horizontalCenter
                    value: hud.clockDate
                    digitH: 17 * hud.ux
                    col: hud.cTxtDim
                }
            }
        }
        // The WireView's display page, and how to change it. Not a clickable
        // control, deliberately: a wallpaper sits underneath its containment,
        // which owns mouse input, so a button here would look pressable and
        // never respond. The action lives in the desktop's right-click menu
        // instead (see main.qml), and this strip reports what it did.
        //
        // Dim red because it is the only element on the panel tied to an
        // action rather than a measurement, and it should not be mistaken
        // for a reading. It flashes to confirm, which is the feedback a
        // button would otherwise have given.
        Rectangle {
            id: wvButton
            visible: hud.wvAvailable
            anchors { bottom: aggCol.top; bottomMargin: 8 * hud.ux
                      left: parent.left; right: parent.right }
            height: 22 * hud.ux
            radius: 1
            readonly property color dimRed: Qt.rgba(0.62, 0.18, 0.24, 1.0)
            color: hud.wvFlash ? Qt.rgba(0.35, 0.09, 0.13, 0.55)
                               : Qt.rgba(0.24, 0.06, 0.09, 0.32)
            border.width: 1
            border.color: hud.wvBtnMsg !== "" ? hud.cWarn : dimRed
            Behavior on color { ColorAnimation { duration: 180 } }
            TLabel {
                anchors.centerIn: parent
                text: hud.wvBtnMsg !== "" ? hud.wvBtnMsg
                                          : "⟳ WV SCREEN · " + hud.wvPageName()
                color: hud.wvBtnMsg !== "" ? hud.cWarn : parent.dimRed
                font.pixelSize: 11.0 * hud.ux
                font.letterSpacing: 2 * hud.ux
            }
        }
        Column {
            id: aggCol
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            spacing: 2 * hud.ux
            Rectangle { width: parent.width; height: 1; color: hud.cLineDim }
            KvRow { k: "TOTAL"; v: hud.fmt(hud.g("pin.total.a"), 1, "A · ") + hud.fmt(hud.g("pin.total.w"), 0, "W") }
            KvRow { k: "Δ MAX-MIN"; v: hud.fmt(hud.g("pin.imbalance.a"), 2, "A") }
            KvRow { k: "σ SPREAD"; v: hud.fmt(hud.g("pin.stddev.a"), 2, "A") }
        }
    }

    // ── ship systems (right) ─────────────────────────────────────────────
    HudPanel {
        id: systems
        title: "◉ SHIP SYSTEMS"
        anchors { top: header.bottom; right: parent.right; bottom: bottomRow.top; margins: hud.m }
        width: 308 * hud.ux
        Grid {
            id: dialGrid
            columns: 2
            width: parent.width
            Dial { width: parent.width / 2; height: 104 * hud.ux; label: "CORE °C"
                   value: hud.g("nvml.temp.gpu"); warn: 75; crit: 88 }
            Dial { width: parent.width / 2; height: 104 * hud.ux; label: "CPU °C"
                   value: hud.g("sys.cpu.temp"); warn: 80; crit: 95 }
            Dial { width: parent.width / 2; height: 104 * hud.ux; label: "GPU LOAD %"
                   value: hud.g("nvml.util.gpu") }
            Dial { width: parent.width / 2; height: 104 * hud.ux; label: "FAN %"
                   value: Math.max(hud.g("nvml.fan.0.pct", 0), hud.g("nvml.fan.1.pct", 0)); warn: 85 }
        }
        Column {
            id: metersCol
            anchors { top: dialGrid.bottom; topMargin: 8 * hud.ux; left: parent.left; right: parent.right }
            spacing: 8 * hud.ux
            Meter {
                width: parent.width; label: "▤ VRAM BANKS"
                frac: hud.g("nvml.vram.used_mib", 0) / Math.max(hud.g("nvml.vram.total_mib", 1), 1)
                valueText: isNaN(hud.g("nvml.vram.total_mib")) ? "--"
                           : (hud.g("nvml.vram.used_mib") / 1024).toFixed(1) + " / "
                             + (hud.g("nvml.vram.total_mib") / 1024).toFixed(0) + " GiB"
            }
            Meter {
                width: parent.width; label: "⌂ HOST RAM"
                frac: hud.g("sys.mem.used_pct", 0) / 100
                valueText: hud.fmt(hud.g("sys.mem.used_pct"), 0, "%") + " · CPU "
                           + hud.fmt(hud.g("sys.cpu.util_pct"), 0, "%")
            }
            Meter {
                readonly property real t: hud.g("sys.temp.spd5118.temp1")
                width: parent.width; label: "♨ RAM TEMP"
                frac: isNaN(t) ? 0 : t / 70
                barColor: isNaN(t) ? hud.cLineDim
                          : t >= 70 ? hud.cAlert
                          : t >= 55 ? hud.cWarn : hud.cAccent
                valueText: "A2 " + hud.fmt(t, 1, "°C")
            }
        }
        // Per-core clocks, filling the room the meters leave. One bar per
        // core, tallest first only by accident of numbering: on a hybrid
        // part the P-cores stand up near the ceiling while the E-cores sit
        // in a band of their own and the parked ones stay dark, so the
        // shape of the row says more about what the machine is doing than
        // any single averaged figure could. The headline beside the label
        // is the peak, which is the number the rest of the world quotes.
        //
        // Laid out on the panel's own left/right grid rather than centred:
        // every other row in here is justified that way, and a centred
        // block of a different width reads as floating rather than placed.
        // The CPU clock, in the room the capped bar block gives back. Drawn
        // seven-segment like the wall clock down in the conduits column,
        // because it is the same kind of readout: one number, meant to be
        // read at a glance from across the room. It carries the unit now —
        // the bar block's header handed its right-hand slot back to being
        // nothing but a header.
        Item {
            anchors { top: metersCol.bottom; bottom: coreBlock.top
                      left: parent.left; right: parent.right }
            Row {
                anchors.centerIn: parent
                spacing: 6 * hud.ux
                SevenSeg {
                    id: cpuSeg
                    value: isNaN(hud.g("sys.cpu.mhz")) ? "----"
                           : String(Math.round(hud.g("sys.cpu.mhz")))
                    digitH: 26 * hud.ux
                    col: hud.cAccent
                }
                TLabel {
                    anchors.bottom: cpuSeg.bottom
                    text: "MHz"
                    color: hud.cTxtDim
                    font.pixelSize: 12 * hud.ux
                }
            }
        }
        Item {
            id: coreBlock
            // Sits on the footer rather than stretching up to the meters, so
            // the bars keep a fixed height instead of growing to swallow
            // every spare pixel. The leftover room collects above the rule,
            // where it reads as breathing space rather than as a void with
            // something floating in it.
            anchors { bottom: hostFooter.top; bottomMargin: 8 * hud.ux
                      left: parent.left; right: parent.right }
            height: coreRule.height + 6 * hud.ux + coreHead.height
                    + 6 * hud.ux + coreRow.height
            visible: hud.coreCount > 0

            Rectangle {
                id: coreRule
                width: parent.width; height: 1; color: hud.cLineDim
            }
            Item {
                id: coreHead
                anchors { top: coreRule.bottom; topMargin: 6 * hud.ux
                          left: parent.left; right: parent.right }
                height: 17 * hud.ux
                TLabel {
                    text: "⚙ CPU CORES"
                    color: hud.cTxtDim
                    font.pixelSize: 13.0 * hud.ux
                    font.letterSpacing: 2 * hud.ux
                }
            }
            // Positioned by index rather than laid out in a Row: the bars
            // have to stretch to whatever height is left over, and a Row
            // that takes its height from anchors while its children take
            // theirs from the Row is a binding loop waiting to happen.
            Item {
                id: coreRow
                anchors { top: coreHead.bottom; topMargin: 6 * hud.ux
                          left: parent.left; right: parent.right }
                height: 68 * hud.ux
                readonly property real gap: 2 * hud.ux
                readonly property real bw:
                    (width - gap * (hud.coreCount - 1)) / Math.max(hud.coreCount, 1)
                Repeater {
                    model: hud.coreCount
                    Item {
                        x: index * (coreRow.bw + coreRow.gap)
                        width: coreRow.bw
                        height: coreRow.height
                        readonly property real frac:
                            hud.g("sys.cpu.core." + index + ".mhz", 0)
                            / Math.max(hud.g("sys.cpu.mhz.limit", 5500), 1)
                        Rectangle {
                            anchors.fill: parent
                            color: Qt.rgba(0.05, 0.29, 0.38, 0.22)
                        }
                        Rectangle {
                            anchors { left: parent.left; right: parent.right
                                      bottom: parent.bottom }
                            height: Math.max(1, parent.height * Math.min(parent.frac, 1))
                            color: parent.frac > 0.80 ? hud.cAccent
                                   : parent.frac > 0.45 ? hud.cLine : hud.cLineDim
                            Behavior on height { NumberAnimation { duration: 400 } }
                        }
                    }
                }
            }
        }
        // Machine identity on the floor of the panel, in the dim weight the
        // date uses down in the conduits column. Seven-segment would be the
        // matching face, but that font is ten glyphs and a colon.
        Item {
            id: hostFooter
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
            height: 16 * hud.ux
            TLabel {
                text: hud.str["sys.hostname"] || "--"
                color: hud.cTxtDim
                font.pixelSize: 11 * hud.ux
                font.letterSpacing: 2 * hud.ux
            }
            TLabel {
                anchors.right: parent.right
                text: "UP " + hud.uptimeFmt(hud.g("sys.uptime_s"))
                color: hud.cTxtDim
                font.pixelSize: 11 * hud.ux
            }
        }
    }

    // ── reactor (center) ─────────────────────────────────────────────────
    Item {
        id: reactor
        anchors { top: header.bottom; left: conduits.right; right: systems.left
                  bottom: bottomRow.top; margins: hud.m }
        readonly property real pw: hud.g("nvml.power.w")
        readonly property real plim: hud.g("nvml.power.limit_w", 600)
        // CPU package draw sits above the GPU reactor as a smaller ring.
        // Scaled to the chip's burst ceiling (RAPL PL2) so a spike never
        // pins the needle, with the sustained limit (PL1) as the amber mark.
        readonly property real cpuW: hud.g("sys.cpu.power_w")
        readonly property real cpuPl1: hud.g("sys.cpu.power_limit_w", 200)
        readonly property real cpuPl2: hud.g("sys.cpu.power_max_w", 295)
        readonly property bool haveCpu: !isNaN(cpuW)
        readonly property real gpuD: Math.min(width - 2 * (248 * hud.ux),
                                              height * (haveCpu ? 0.56 : 0.94))
        readonly property real cpuD: gpuD * 0.56
        readonly property real ringGap: 8 * hud.ux

        Canvas {
            id: ring
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: reactor.haveCpu
                ? (reactor.cpuD + reactor.ringGap) / 2 - 12 * hud.ux : 0
            width: reactor.gpuD
            height: width
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var cx = width / 2, cy = height / 2
                var r = width * 0.40
                var a0 = Math.PI * 0.75, span = Math.PI * 1.5
                // tick ring
                for (var i = 0; i <= 54; i++) {
                    var a = a0 + span * i / 54
                    var major = (i % 9 === 0)
                    var r1 = r + width * 0.045
                    var r2 = r1 + (major ? width * 0.035 : width * 0.018)
                    ctx.strokeStyle = major ? String(hud.cLine) : String(hud.cLineDim)
                    ctx.lineWidth = major ? 2 : 1
                    ctx.beginPath()
                    ctx.moveTo(cx + r1 * Math.cos(a), cy + r1 * Math.sin(a))
                    ctx.lineTo(cx + r2 * Math.cos(a), cy + r2 * Math.sin(a))
                    ctx.stroke()
                }
                ctx.lineWidth = width * 0.022
                ctx.strokeStyle = String(hud.cLineDim)
                ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span); ctx.stroke()
                var frac = isNaN(reactor.pw) ? 0 : Math.min(reactor.pw / reactor.plim, 1)
                if (frac > 0) {
                    var col = frac > 0.95 ? hud.cWarn : hud.cAccent
                    ctx.strokeStyle = String(col)
                    ctx.shadowColor = String(col)
                    ctx.shadowBlur = 10
                    ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span * frac); ctx.stroke()
                }
                // glow ring core
                var g2 = ctx.createRadialGradient(cx, cy, 0, cx, cy, r * 0.52)
                g2.addColorStop(0.46, "rgba(3,16,29,0)")
                g2.addColorStop(0.66, "rgba(234,252,255,0.50)")
                g2.addColorStop(0.80, "rgba(53,224,255,0.26)")
                g2.addColorStop(1, "rgba(0,0,0,0)")
                ctx.fillStyle = g2
                ctx.fillRect(cx - r, cy - r, 2 * r, 2 * r)
            }
            Connections {
                target: hud
                function onNumChanged() { ring.requestPaint() }
            }
            SequentialAnimation on scale {
                loops: Animation.Infinite
                NumberAnimation { to: 1.015; duration: 1400; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.995; duration: 1400; easing.type: Easing.InOutSine }
            }
        }
        Canvas {
            id: cpuRing
            visible: reactor.haveCpu
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: ring.top
            anchors.bottomMargin: reactor.ringGap
            width: reactor.cpuD
            height: width
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var cx = width / 2, cy = height / 2
                var r = width * 0.38
                var a0 = Math.PI * 0.75, span = Math.PI * 1.5
                for (var i = 0; i <= 30; i++) {
                    var a = a0 + span * i / 30
                    var major = (i % 5 === 0)
                    var r1 = r + width * 0.06
                    var r2 = r1 + (major ? width * 0.05 : width * 0.025)
                    ctx.strokeStyle = major ? String(hud.cLine) : String(hud.cLineDim)
                    ctx.lineWidth = major ? 1.6 : 1
                    ctx.beginPath()
                    ctx.moveTo(cx + r1 * Math.cos(a), cy + r1 * Math.sin(a))
                    ctx.lineTo(cx + r2 * Math.cos(a), cy + r2 * Math.sin(a))
                    ctx.stroke()
                }
                ctx.lineWidth = width * 0.030
                ctx.strokeStyle = String(hud.cLineDim)
                ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span); ctx.stroke()
                var frac = isNaN(reactor.cpuW) ? 0
                         : Math.min(reactor.cpuW / reactor.cpuPl2, 1)
                if (frac > 0) {
                    var col = reactor.cpuW >= reactor.cpuPl2 * 0.9 ? hud.cAlert
                            : reactor.cpuW >= reactor.cpuPl1 ? hud.cWarn : hud.cAccent
                    ctx.strokeStyle = String(col)
                    ctx.shadowColor = String(col)
                    ctx.shadowBlur = 8
                    ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span * frac); ctx.stroke()
                }
                // sustained-limit tick: where PL1 falls on the PL2 scale
                var am = a0 + span * Math.min(reactor.cpuPl1 / reactor.cpuPl2, 1)
                ctx.strokeStyle = String(hud.cWarn)
                ctx.lineWidth = 1.6
                ctx.beginPath()
                ctx.moveTo(cx + (r - width * 0.045) * Math.cos(am),
                           cy + (r - width * 0.045) * Math.sin(am))
                ctx.lineTo(cx + (r + width * 0.045) * Math.cos(am),
                           cy + (r + width * 0.045) * Math.sin(am))
                ctx.stroke()
            }
            Connections {
                target: hud
                function onNumChanged() { cpuRing.requestPaint() }
            }
        }
        // Siblings of the gauges, not children — see IdleRing. Each sits in
        // the gap between its gauge's arc and its tick ring, and they turn
        // opposite ways at different speeds so they never lock into step.
        IdleRing {
            anchors.centerIn: ring
            width: ring.width; height: width
            radiusFrac: 0.428
        }
        IdleRing {
            visible: reactor.haveCpu
            anchors.centerIn: cpuRing
            width: cpuRing.width; height: width
            radiusFrac: 0.417; dashes: 28
            rotation: 6   // offset so the two rings' dashes do not line up
        }
        TLabel {
            id: cpuText
            visible: reactor.haveCpu
            anchors.centerIn: cpuRing
            anchors.verticalCenterOffset: -4 * hud.ux
            text: hud.fmt(reactor.cpuW, 0)
            font.pixelSize: 27 * hud.ux
            color: "#eafcff"
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true; shadowColor: hud.cAccent
                shadowBlur: 1.0; shadowOpacity: 0.6
                shadowHorizontalOffset: 0; shadowVerticalOffset: 0
            }
        }
        TLabel {
            visible: reactor.haveCpu
            anchors { top: cpuText.bottom; horizontalCenter: cpuRing.horizontalCenter }
            text: "WATT · CPU"
            color: hud.cTxtDim
            font.pixelSize: 9.5 * hud.ux
            font.letterSpacing: 2.5 * hud.ux
        }
        TLabel {
            id: pwText
            anchors.centerIn: ring
            anchors.verticalCenterOffset: -6 * hud.ux
            text: hud.fmt(reactor.pw, 0)
            font.pixelSize: 41.5 * hud.ux
            color: "#eafcff"
            // The headline number, so it gets the strongest bloom on screen.
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true; shadowColor: hud.cAccent
                shadowBlur: 1.0; shadowOpacity: 0.85
                shadowHorizontalOffset: 0; shadowVerticalOffset: 0
            }
        }
        TLabel {
            anchors { top: pwText.bottom; horizontalCenter: ring.horizontalCenter }
            text: "WATT · REACTOR"
            color: hud.cTxt   // sits on the core glow, needs full-strength ink
            font.pixelSize: 10.4 * hud.ux
            font.letterSpacing: 3 * hud.ux
        }
        // ── left flank: disk + network ───────────────────────────────────
        Column {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            width: 234 * hud.ux
            spacing: hud.m
            HudPanel {
                width: parent.width; height: 126 * hud.ux
                title: "◍ DISK IO"
                Column {
                    width: parent.width
                    KvRow { k: "M.2 TEMP"; v: hud.fmt(hud.g("sys.temp.nvme.composite"), 0, "°C") }
                    KvRow { k: "ROOT"; v: hud.fmt(hud.g("sys.disk.root.used_gib") / 1024, 2, "T / ") + hud.fmt(hud.g("sys.disk.root.total_gib") / 1024, 2, "T") }
                    KvRow { k: "READ"; v: hud.fmt(hud.g("sys.disk.read_mbs"), 1, " MB/s") }
                    KvRow { k: "WRITE"; v: hud.fmt(hud.g("sys.disk.write_mbs"), 1, " MB/s") }
                }
            }
            HudPanel {
                width: parent.width; height: 148 * hud.ux
                title: "⇅ NETWORK"
                Column {
                    width: parent.width
                    KvRow { k: "LOC"; v: hud.str["sys.net.ip"] || "--" }
                    KvRow { k: "PUB"; v: hud.pubIp || "--" }
                    KvRow { k: "UP"; v: hud.rateFmt(hud.g("sys.net.up_kbs")) }
                    KvRow { k: "DOWN"; v: hud.rateFmt(hud.g("sys.net.down_kbs")) }
                    KvRow { k: "TOTAL ⇅"; v: hud.fmt(hud.g("sys.net.total_up_gib"), 1, "G / ") + hud.fmt(hud.g("sys.net.total_down_gib"), 1, "G") }
                }
            }
        }
        // ── right flank: cooling + HA-fed ship sections ──────────────────
        Column {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            width: 234 * hud.ux
            spacing: hud.m
            HudPanel {
                width: parent.width; height: 126 * hud.ux
                title: "❄ COOLING"
                Column {
                    width: parent.width
                    KvRow { k: "CASE"; v: hud.fmt(hud.g("sys.fan.nct6799.fan3"), 0, " rpm") }
                    KvRow { k: "CPU"; v: hud.fmt(hud.g("sys.fan.nct6799.fan4"), 0, " rpm") }
                    KvRow { k: "VRM"; v: hud.fmt(hud.g("sys.fan.nct6799.fan1"), 0, " rpm") }
                    KvRow { k: "AIO"; v: hud.fmt(hud.g("sys.fan.nct6799.fan7"), 0, " rpm") }
                }
            }
            // Home Assistant panels, entirely described by the served spec.
            // No entity id, label or unit is known to this file.
            Repeater {
                model: hud.haOn ? hud.haPanels : []
                delegate: HudPanel {
                    id: haPanel
                    required property var modelData
                    width: parent.width
                    // Matches the fixed panels above: 21px per row over a
                    // constant title block.
                    height: (42 + 21 * haPanel.modelData.rows.length) * hud.ux
                    title: haPanel.modelData.title
                    Column {
                        width: parent.width
                        Repeater {
                            model: haPanel.modelData.rows
                            delegate: KvRow {
                                required property var modelData
                                k: modelData.label
                                v: hud.haRowText(modelData)
                                vc: hud.haRowColor(modelData)
                            }
                        }
                    }
                }
            }
        }
        Row {
            anchors { bottom: parent.bottom; bottomMargin: 4 * hud.ux; horizontalCenter: parent.horizontalCenter }
            spacing: 26 * hud.ux
            TLabel { text: "LIMIT "; color: hud.cTxtDim; font.pixelSize: 12.8 * hud.ux
                TLabel { anchors.left: parent.right; text: hud.fmt(reactor.plim, 0, "W"); color: hud.cAccent; font.pixelSize: 12.8 * hud.ux } }
            Item { width: 40 * hud.ux; height: 1 }
            TLabel { text: "P-STATE "; color: hud.cTxtDim; font.pixelSize: 12.8 * hud.ux
                TLabel { anchors.left: parent.right; text: isNaN(hud.g("nvml.pstate")) ? "--" : "P" + hud.g("nvml.pstate"); color: hud.cAccent; font.pixelSize: 12.8 * hud.ux } }
            Item { width: 40 * hud.ux; height: 1 }
            TLabel { text: "ENERGY "; color: hud.cTxtDim; font.pixelSize: 12.8 * hud.ux
                TLabel { anchors.left: parent.right; text: hud.fmt(hud.g("nvml.energy.session_wh"), 1, " Wh"); color: hud.cAccent; font.pixelSize: 12.8 * hud.ux } }
            Item { width: 40 * hud.ux; height: 1 }
            TLabel { text: "THROTTLE "; color: hud.cTxtDim; font.pixelSize: 12.8 * hud.ux
                TLabel { anchors.left: parent.right; text: (hud.str["nvml.throttle"] || "--").toUpperCase(); color: hud.cAccent; font.pixelSize: 12.8 * hud.ux } }
        }
    }

    // ── bottom row: clocks / trace / links ───────────────────────────────
    Item {
        id: bottomRow
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: hud.m }
        height: 196 * hud.ux
        HudPanel {
            id: clocksPanel
            title: "⏲ CLOCKS MHz"
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 210 * hud.ux
            Column {
                width: parent.width
                KvRow { k: "GFX"; v: hud.fmt(hud.g("nvml.clock.gfx.mhz"), 0) + " / " + hud.fmt(hud.g("nvml.clock.gfx.max_mhz"), 0) }
                KvRow { k: "SM"; v: hud.fmt(hud.g("nvml.clock.sm.mhz"), 0) }
                KvRow { k: "MEM"; v: hud.fmt(hud.g("nvml.clock.mem.mhz"), 0) }
                KvRow { k: "VIDEO"; v: hud.fmt(hud.g("nvml.clock.video.mhz"), 0) }
            }
        }
        HudPanel {
            id: tracePanel
            title: "∿ TELEMETRY TRACE"
            anchors { left: clocksPanel.right; right: linksPanel.left; top: parent.top
                      bottom: parent.bottom; leftMargin: hud.m; rightMargin: hud.m }
            Row {
                anchors { top: parent.top; topMargin: -26 * hud.ux; right: parent.right; rightMargin: 6 * hud.ux }
                spacing: 16 * hud.ux
                Row { spacing: 5 * hud.ux
                    Rectangle { width: 13 * hud.ux; height: 3; color: hud.cAccent; anchors.verticalCenter: parent.verticalCenter }
                    TLabel { text: "BOARD W"; color: hud.cTxtDim; font.pixelSize: 10.4 * hud.ux } }
                Row { spacing: 5 * hud.ux
                    Rectangle { width: 13 * hud.ux; height: 3; color: hud.cOrange; anchors.verticalCenter: parent.verticalCenter }
                    TLabel { text: "CONNECTOR W"; color: hud.cTxtDim; font.pixelSize: 10.4 * hud.ux } }
            }
            Canvas {
                id: trace
                anchors.fill: parent
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.strokeStyle = "rgba(13,74,97,0.5)"
                    ctx.lineWidth = 1
                    ctx.beginPath()
                    for (var yy = 1; yy < 4; yy++) { ctx.moveTo(0, height * yy / 4); ctx.lineTo(width, height * yy / 4) }
                    for (var xx = 1; xx < 12; xx++) { ctx.moveTo(width * xx / 12, 0); ctx.lineTo(width * xx / 12, height) }
                    ctx.stroke()
                    var peak = 100
                    for (var i = 0; i < hud.histBoard.length; i++) if (hud.histBoard[i] > peak) peak = hud.histBoard[i]
                    for (i = 0; i < hud.histConn.length; i++) if (!isNaN(hud.histConn[i]) && hud.histConn[i] > peak) peak = hud.histConn[i]
                    peak *= 1.1
                    function line(arr, col) {
                        ctx.strokeStyle = col
                        ctx.lineWidth = 1.6
                        ctx.shadowColor = col
                        ctx.shadowBlur = 6
                        ctx.beginPath()
                        var started = false
                        for (var j = 0; j < arr.length; j++) {
                            var v = arr[j]
                            if (isNaN(v)) continue
                            var x = width - (arr.length - 1 - j) * (width / 240)
                            var y = height - (v / peak) * (height - 6) - 3
                            started ? ctx.lineTo(x, y) : ctx.moveTo(x, y)
                            started = true
                        }
                        ctx.stroke()
                        ctx.shadowBlur = 0
                    }
                    line(hud.histBoard, String(hud.cAccent))
                    line(hud.histConn, String(hud.cOrange))
                }
                Connections {
                    target: hud
                    function onHistBoardChanged() { trace.requestPaint() }
                }
            }
        }
        HudPanel {
            id: linksPanel
            title: "⇄ DATA LINKS"
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            width: 210 * hud.ux
            Column {
                width: parent.width
                KvRow { k: "PCIe"; v: isNaN(hud.g("nvml.pcie.gen")) ? "--" : "GEN" + hud.g("nvml.pcie.gen") + " ×" + hud.g("nvml.pcie.width") }
                KvRow { k: "TX"; v: hud.fmt(hud.g("nvml.pcie.tx_kbs") / 1024, 1, " MB/s") }
                KvRow { k: "RX"; v: hud.fmt(hud.g("nvml.pcie.rx_kbs") / 1024, 1, " MB/s") }
                KvRow { k: "FAN"; v: hud.fmt(hud.g("nvml.fan.0.pct"), 0, "%") }
            }
        }
    }

    // ── alarm banner ─────────────────────────────────────────────────────
    Rectangle {
        visible: hud.alert
        anchors { top: header.bottom; topMargin: 6 * hud.ux; horizontalCenter: parent.horizontalCenter }
        width: alarmText.width + 52 * hud.ux
        height: 30 * hud.ux
        color: Qt.rgba(0.16, 0.02, 0.04, 0.85)
        border.width: 1; border.color: hud.cAlert
        TLabel {
            id: alarmText
            anchors.centerIn: parent
            text: "⚠ " + ((hud.str["alarm.names"] || "ALARM").toUpperCase()) + " ⚠"
            color: hud.cAlert
            font.letterSpacing: 3 * hud.ux
        }
        SequentialAnimation on opacity {
            running: hud.alert; loops: Animation.Infinite
            NumberAnimation { to: 0.3; duration: 450 }
            NumberAnimation { to: 1.0; duration: 450 }
        }
    }

    // CRT scanlines over the whole scene: one dark line every third pixel,
    // the web HUD's #scan. It is most of why that view's solid bar fills read
    // as lit panels instead of flat colour.
    //
    // A 1x3 PNG tiled by the scene graph — 72 bytes and one quad, rather than
    // the ~480 rectangles a Repeater would need at this height. Last child so
    // it covers everything, and not smoothed so the lines stay exactly one
    // pixel and never blur into a grey wash.
    Image {
        anchors.fill: parent
        z: 100
        fillMode: Image.Tile
        smooth: false
        source: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAADCAYAAABS3WWCAAAAD0lEQVR42mNgYGDQZIADAAHSACo4Aq1+AAAAAElFTkSuQmCC"
    }
}
