pragma ComponentBehavior: Bound

import QtQuick
import "../kit"

// MacExpanded.qml - v5 MAC focus view, opened by a click on the MAC widget.
// Same shell as CrewExpanded: back chevron of five dots, title MAC, panel 1100 x 760.
//
// Content (dot language, no boxes):
//   link: latency ladder of the last 60 RTT samples, one dot per sample, higher
//         dot = slower; ms over 100 amber. Hero number is the newest sample.
//   battery: 20 dot bar, lit share = charge; state word under it.
//   thermal: 5 dots, ice when nominal, amber when throttled.
//   queue: running / ready / blocked counts from the Mac Kanban board, 10 dot rows.
//   load: 1 minute load, 12 dots.
//
// Freshness (link, same contract as MacWidget): fresh bright; stale dim with the
// age in seconds or minutes; error amber with no number (ladder drawn as an amber
// baseline, hero empty). Battery, thermal, queue and load each show NO READ in
// amber when the collector could not read that value.
//
// Data: the `link` object from LinkFeed (maclink.sh). Tests pass the same shape.
Item {
    id: root

    property var link: null
    // Seconds, from the deck's single tick. Keeps the stale age text moving.
    property real tick: 0
    signal closeRequested()

    width: 1100
    height: 760
    focus: true
    Keys.onEscapePressed: root.closeRequested()

    // ---- link freshness --------------------------------------------------
    readonly property real staleAfterS: 24
    readonly property real nowS: { root.tick; return Date.now() / 1000 }
    readonly property var rtt: (root.link && root.link.rtt_ms) ? root.link.rtt_ms : null
    readonly property var mac: (root.link && root.link.mac) ? root.link.mac : null
    readonly property bool tunnelUp: root.link !== null && root.link !== undefined
        && root.link.tunnel === "active"
    readonly property bool hasRtt: root.rtt !== null && typeof root.rtt.last === "number"
    readonly property real ageS: (root.link && typeof root.link.ts === "number")
        ? root.nowS - root.link.ts : -1
    readonly property string linkState: (!root.tunnelUp || !root.hasRtt) ? "error"
        : (root.ageS > root.staleAfterS ? "stale" : "fresh")
    readonly property string ageText: {
        var s = Math.round(root.ageS)
        return s < 120 ? "STALE " + s + " S" : "STALE " + Math.round(s / 60) + " MIN"
    }
    readonly property real linkAlpha: root.linkState === "stale" ? 0.45 : 1.0

    // ---- latency ladder ---------------------------------------------------
    readonly property int slotCount: 60
    readonly property var samples: (root.rtt && root.rtt.samples) ? root.rtt.samples : []
    readonly property int shownSamples: Math.min(root.slotCount, root.samples.length)
    readonly property real ladderX: 112
    readonly property real ladderStep: 14.6
    readonly property real ladderBase: 440
    readonly property real ladderSpan: 200

    // Slot i of 0 to 59, newest at the right. Null when there is no sample.
    function sampleAt(i) {
        var k = root.samples.length - root.slotCount + i
        if (k < 0)
            return null
        var v = Number(root.samples[k])
        return isFinite(v) ? v : null
    }
    function ladderY(v) {
        return root.ladderBase - Math.min(1, Math.max(0, v / 120)) * root.ladderSpan
    }

    Repeater {
        model: root.slotCount
        delegate: Rectangle {
            id: slot
            required property int index
            readonly property var v: root.sampleAt(slot.index)
            readonly property bool errorView: root.linkState === "error"
            width: 8
            height: 8
            radius: 4
            x: root.ladderX + slot.index * root.ladderStep - 4
            y: (slot.errorView || slot.v === null ? root.ladderBase : root.ladderY(slot.v)) - 4
            color: (slot.errorView || (slot.v !== null && slot.v >= 100)) ? Tokens.amber : Tokens.ice
            opacity: slot.errorView ? 0.5
                : (slot.v === null ? 0.14 : root.linkAlpha)
        }
    }

    // ---- battery ------------------------------------------------------------
    readonly property var batt: (root.mac && typeof root.mac.batt === "number") ? root.mac.batt : null
    readonly property int battLit: root.batt === null ? 0
        : Math.round(20 * Math.max(0, Math.min(100, root.batt)) / 100)
    readonly property string battState: (root.mac && root.mac.state)
        ? String(root.mac.state).toLowerCase() : ""
    readonly property string battText: root.batt === null ? "NO READ" : Math.round(root.batt) + " %"

    // ---- thermal ------------------------------------------------------------
    readonly property string thermal: (root.mac && root.mac.thermal) ? String(root.mac.thermal) : ""
    readonly property string thermalText: root.thermal === "" ? "NO READ" : root.thermal
    readonly property bool thermalWarn: root.thermal === "throttled"

    // ---- queue (Mac Kanban) -------------------------------------------------
    readonly property var kan: (root.mac && root.mac.kanban) ? root.mac.kanban : null
    readonly property string kanbanState: root.kan === null ? "error" : "ok"
    readonly property var queueRows: [
        { key: "running", label: "RUNNING", color: Tokens.cyan },
        { key: "ready", label: "READY", color: Tokens.ice },
        { key: "blocked", label: "BLOCKED", color: Tokens.amber }
    ]
    function queueN(key) {
        return (root.kan && typeof root.kan[key] === "number") ? root.kan[key] : null
    }
    function queueText(row) {
        var n = root.queueN(row.key)
        return n === null ? row.label + " NO READ" : row.label + " " + n
    }

    // ---- load ---------------------------------------------------------------
    readonly property var load1: (root.mac && root.mac.load && root.mac.load.length > 0
        && typeof root.mac.load[0] === "number") ? root.mac.load[0] : null
    readonly property int loadLit: root.load1 === null ? 0
        : Math.max(1, Math.round(12 * Math.min(1, root.load1 / 12)))
    readonly property string loadText: root.load1 === null ? "NO READ" : root.load1.toFixed(1)

    // ---- labels (also the word budget) ---------------------------------------
    readonly property string routeText: (root.link && root.link.route)
        ? String(root.link.route).toUpperCase() : ""
    readonly property string subText: root.linkState === "fresh" ? "LINK UP " + root.routeText
        : (root.linkState === "stale" ? root.ageText : "NO LINK")
    readonly property string heroText: root.linkState === "error" ? ""
        : String(Math.round(root.rtt.last))
    readonly property string captionText: "RTT, " + root.shownSamples + " SAMPLES"
    readonly property var labelList: [
        "MAC", root.subText, root.heroText, root.heroText === "" ? "" : "ms",
        root.captionText, "BATTERY", root.battText, root.battState,
        "THERMAL", root.thermalText, "LOAD", root.loadText,
        root.queueText(root.queueRows[0]), root.queueText(root.queueRows[1]),
        root.queueText(root.queueRows[2])
    ]
    readonly property int wordCount: root.labelList.join(" ").split(/\s+/)
        .filter(function (w) { return w.length > 0 }).length

    // ---- header -------------------------------------------------------------
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
        x: 112
        y: 30
        text: "MAC"
        color: Tokens.ink
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: 44
        font.letterSpacing: Tokens.trackLabel * 44 * 0.4
        renderType: Text.NativeRendering
    }

    Text {
        x: 114
        y: 84
        text: root.subText
        color: root.linkState === "error" ? Tokens.amber : Tokens.textLabel
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: 16
        renderType: Text.NativeRendering
    }

    // ---- hero: newest RTT ---------------------------------------------------
    Text {
        id: heroT
        x: 112
        y: 128
        visible: root.heroText !== ""
        text: root.heroText
        color: root.linkState === "stale" ? Tokens.textDim : Tokens.white
        opacity: root.linkAlpha
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeHero
        renderType: Text.NativeRendering
    }
    Text {
        x: heroT.x + heroT.implicitWidth + 8
        y: heroT.y + 26
        visible: root.heroText !== ""
        text: "ms"
        color: Tokens.textDim
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeBody
        renderType: Text.NativeRendering
    }

    Text {
        x: root.ladderX
        y: root.ladderBase + 14
        text: root.captionText
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
        renderType: Text.NativeRendering
    }

    // ---- battery (20 dots) --------------------------------------------------
    Text {
        id: battLabel
        x: 112
        y: 520
        text: "BATTERY"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
        renderType: Text.NativeRendering
    }
    Repeater {
        model: 20
        delegate: Rectangle {
            required property int index
            width: 9
            height: 9
            radius: 4.5
            x: 112 + index * 19
            y: 556
            color: Tokens.white
            opacity: index < root.battLit ? 1.0 : 0.2
        }
    }
    Text {
        x: 112
        y: 580
        text: root.battText + (root.battState !== "" ? "  " + root.battState : "")
        color: root.batt === null ? Tokens.amber : Tokens.textDim
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        renderType: Text.NativeRendering
    }

    // ---- thermal (5 dots) ---------------------------------------------------
    Text {
        x: 620
        y: 520
        text: "THERMAL"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
        renderType: Text.NativeRendering
    }
    Repeater {
        model: 5
        delegate: Rectangle {
            required property int index
            width: 11
            height: 11
            radius: 5.5
            x: 620 + index * 24
            y: 556
            color: root.thermalWarn ? Tokens.amber : Tokens.ice
            opacity: root.thermal === "" ? 0.2 : 1.0
        }
    }
    Text {
        x: 620
        y: 580
        text: root.thermalText
        color: (root.thermal === "" || root.thermalWarn) ? Tokens.amber : Tokens.textDim
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        renderType: Text.NativeRendering
    }

    // ---- queue: running / ready / blocked (10 dots each) ---------------------
    Repeater {
        model: root.queueRows
        delegate: Item {
            id: qrow
            required property var modelData
            required property int index
            readonly property int count: root.queueN(qrow.modelData.key) === null ? 0
                : root.queueN(qrow.modelData.key)
            x: 112
            y: 648 + qrow.index * 34
            width: 520
            height: 24

            Text {
                x: 0
                anchors.verticalCenter: parent.verticalCenter
                width: 150
                text: qrow.modelData.label
                color: Tokens.textLabel
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightMedium
                font.pixelSize: Tokens.sizeCaption
                font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
                renderType: Text.NativeRendering
            }
            Repeater {
                model: 10
                delegate: Rectangle {
                    required property int index
                    width: 9
                    height: 9
                    radius: 4.5
                    x: 170 + index * 17
                    y: 7.5
                    color: qrow.modelData.color
                    opacity: root.queueN(qrow.modelData.key) === null ? 0.2
                        : (index < qrow.count ? 1.0 : 0.2)
                }
            }
            Text {
                x: 170 + 10 * 17 + 6
                anchors.verticalCenter: parent.verticalCenter
                text: root.queueN(qrow.modelData.key) === null ? "NO READ"
                    : String(root.queueN(qrow.modelData.key))
                color: root.queueN(qrow.modelData.key) === null ? Tokens.amber : Tokens.white
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightMedium
                font.pixelSize: Tokens.sizeBody
                renderType: Text.NativeRendering
            }
        }
    }

    // ---- load (12 dots) -----------------------------------------------------
    Text {
        x: 620
        y: 648
        text: "LOAD"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        font.letterSpacing: Tokens.trackLabel * Tokens.sizeCaption
        renderType: Text.NativeRendering
    }
    Repeater {
        model: 12
        delegate: Rectangle {
            required property int index
            width: 9
            height: 9
            radius: 4.5
            x: 620 + index * 14
            y: 684
            color: Tokens.cyan
            opacity: index < root.loadLit ? 1.0 : 0.24
        }
    }
    Text {
        x: 620
        y: 706
        text: root.loadText
        color: root.load1 === null ? Tokens.amber : Tokens.textDim
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeCaption
        renderType: Text.NativeRendering
    }
}
