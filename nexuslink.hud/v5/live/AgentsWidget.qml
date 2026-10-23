pragma ComponentBehavior: Bound
import QtQuick
import "../kit"

// AgentsWidget.qml - v5 rest form for Kanban agent counts (s10 AGENTS box).
//
// Left column: the word AGENTS, the running count, the word running.
// Right column: one cyan dot per running task (12 at most; the count says the
// rest), then the status line "N blocked, M waiting".
//
// Freshness, from the feed's agents.status:
//   fresh  bright, no age text
//   stale  counts dimmed, age text "stale 4d ago" under the status line
//   error  amber, numeral replaced by "--", status line "source error", no dots
// All counts come from the feed. Nothing here invents a number: zeros mean the
// board has zero of that status.
WidgetBase {
    id: root

    // Object from AgentsFeed.agents, or the fixture in fixtures/agents.json.
    property var agents: ({ "status": "error", "running": 0, "blocked": 0, "waiting": 0, "ageS": -1 })

    expandable: false

    // Layout guides inside the 346 x 129 box (s10 agents box).
    readonly property real leftX: 19
    readonly property real countRightX: 95
    readonly property real rightX: 173
    readonly property int maxDots: 12

    readonly property string freshness: root.agents && root.agents.status ? String(root.agents.status) : "error"
    readonly property bool isStale: root.freshness === "stale"
    readonly property bool isError: root.freshness !== "fresh" && root.freshness !== "stale"
    readonly property real dimmed: root.isStale ? 0.45 : 1.0

    function count(v) {
        var n = Number(v)
        return (isFinite(n) && n >= 0) ? Math.floor(n) : 0
    }
    readonly property int running: root.count(root.agents ? root.agents.running : 0)
    readonly property int blocked: root.count(root.agents ? root.agents.blocked : 0)
    readonly property int waiting: root.count(root.agents ? root.agents.waiting : 0)
    readonly property int dotCount: Math.min(root.running, root.maxDots)

    function agoText(s) {
        if (!(s >= 0))
            return "no events"
        if (s < 60)
            return Math.floor(s) + "s ago"
        if (s < 3600)
            return Math.floor(s / 60) + "m ago"
        if (s < 86400)
            return Math.floor(s / 3600) + "h ago"
        return Math.floor(s / 86400) + "d ago"
    }
    readonly property string ageLine: root.agents && root.agents.ageS !== undefined
        ? "stale " + root.agoText(Number(root.agents.ageS)) : "stale"

    // ---- left column ------------------------------------------------------
    Text {
        id: label
        x: root.leftX
        y: 14
        text: "AGENTS"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightMedium
        font.letterSpacing: 16 * Tokens.trackLabel
    }

    Text {
        id: numeral
        x: root.countRightX - width
        y: 22
        text: root.isError ? "--" : String(root.running)
        color: root.isError ? Tokens.amber : Tokens.ink
        opacity: root.dimmed
        font.family: Tokens.fontFamily
        font.pixelSize: 60
        font.weight: Tokens.weightRegular
    }

    Text {
        id: runningWord
        x: root.countRightX - width
        y: 96
        text: "running"
        color: root.isError ? Tokens.amber : Tokens.textCaption
        opacity: root.dimmed
        font.family: Tokens.fontFamily
        font.pixelSize: 18
        font.weight: Tokens.weightRegular
    }

    // ---- right column: one dot per running task ----------------------------
    Repeater {
        model: root.isError ? 0 : root.dotCount

        delegate: Rectangle {
            required property int index
            x: root.rightX + index * 13
            y: 53
            width: 8
            height: 8
            radius: 4
            color: Tokens.cyan
            opacity: root.dimmed
        }
    }

    // ---- status line -------------------------------------------------------
    Text {
        id: errorLine
        x: root.rightX
        y: 83
        visible: root.isError
        text: "source error"
        color: Tokens.amber
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightRegular
    }

    Row {
        id: statusLine
        x: root.rightX
        y: 83
        spacing: 5
        visible: !root.isError
        opacity: root.dimmed

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: Tokens.amber
        }
        Text {
            text: root.blocked + " blocked,"
            color: Tokens.ink
            font.family: Tokens.fontFamily
            font.pixelSize: 16
            font.weight: Tokens.weightRegular
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: Tokens.white
        }
        Text {
            text: root.waiting + " waiting"
            color: Tokens.ink
            font.family: Tokens.fontFamily
            font.pixelSize: 16
            font.weight: Tokens.weightRegular
        }
    }

    // ---- age line: stale only ----------------------------------------------
    Text {
        id: ageText
        x: root.rightX
        y: 104
        visible: root.isStale
        text: root.ageLine
        color: Tokens.textDim
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightRegular
    }
}
