pragma ComponentBehavior: Bound
import QtQuick
import "../kit"

// TodayWidget.qml - v5 rest form for the TODAY box (s10: l 2060, t 84, r 2480,
// b 200, so 420 x 116 px).
//
// Layout, from the s10 mockup (build_s10.py today()):
//   TODAY label at the top left; the event time in the 68 px hero below it;
//   the event title at x 228 beside the time; a 24-dot day strip at y 98, one
//   dot per hour of the local day, bright up to the current hour, and an acid
//   dot at the event's hour.
//
// Empty state: when the feed has no timed event left today (or no source), the
// hero reads "no events" in place of the time. Nothing is invented.
//
// Freshness, from the feed's today.status:
//   fresh  bright, no age text
//   stale  everything dimmed, "stale 4m ago" beside the label
//   error  "no events" and the reason ("source missing" or "source error") in
//          amber, no number, no strip dimming
// All values come from the feed. Fixture: fixtures/today.json (render only).
WidgetBase {
    id: root

    // Object from TodayFeed.today, or the fixture in fixtures/today.json.
    property var today: ({ "status": "error", "reason": "source missing",
                           "hasEvent": false, "time": "", "hour": -1,
                           "title": "", "nowHour": 0, "ageS": -1 })

    expandable: false

    readonly property int dotCount: 24
    readonly property real stripY: 98
    readonly property real titleX: 228

    readonly property string freshness: root.today && root.today.status
        ? String(root.today.status) : "error"
    readonly property bool isStale: root.freshness === "stale"
    readonly property bool isError: root.freshness !== "fresh" && root.freshness !== "stale"
    readonly property real dimmed: root.isStale ? 0.45 : 1.0

    readonly property bool hasEvent: root.today && root.today.hasEvent === true
        && isFinite(Number(root.today.hour)) && Number(root.today.hour) >= 0
    readonly property real eventHour: root.hasEvent ? Number(root.today.hour) : -1
    readonly property real nowHour: root.today && isFinite(Number(root.today.nowHour))
        ? Number(root.today.nowHour) : 0

    function agoText(s) {
        if (!(s >= 0))
            return ""
        if (s < 60)
            return Math.floor(s) + "s ago"
        if (s < 3600)
            return Math.floor(s / 60) + "m ago"
        if (s < 86400)
            return Math.floor(s / 3600) + "h ago"
        return Math.floor(s / 86400) + "d ago"
    }
    readonly property string ageLine: root.today && root.today.ageS !== undefined
        ? "stale " + root.agoText(Number(root.today.ageS)) : "stale"

    // ---- label ------------------------------------------------------------
    Text {
        id: label
        x: 0
        y: 0
        text: "TODAY"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightBold
        font.letterSpacing: 16 * 0.26
    }

    Text {
        id: ageText
        x: 96
        y: 0
        visible: root.isStale
        text: root.ageLine
        color: Tokens.textDim
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightRegular
    }

    // ---- hero: time, or the empty state ----------------------------------
    Text {
        id: hero
        x: 0
        y: 22
        visible: root.hasEvent
        text: root.hasEvent ? String(root.today.time) : ""
        color: Tokens.white
        opacity: root.dimmed
        font.family: Tokens.fontFamily
        font.pixelSize: 68
        font.weight: Tokens.weightMedium
    }

    Text {
        id: emptyText
        x: 0
        y: 22
        visible: !root.hasEvent
        text: "no events"
        color: root.isError ? Tokens.amber : Tokens.ink
        opacity: root.isStale ? root.dimmed : 1.0
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeTitle
        font.weight: Tokens.weightMedium
    }

    // ---- title beside the time -------------------------------------------
    Text {
        id: titleText
        x: root.titleX
        y: 50
        width: root.width - root.titleX
        visible: root.hasEvent
        elide: Text.ElideRight
        text: root.hasEvent ? String(root.today.title) : ""
        color: "#c9e6ef"
        opacity: root.dimmed
        font.family: Tokens.fontFamily
        font.pixelSize: 26
        font.weight: Tokens.weightMedium
    }

    Text {
        id: reasonText
        x: root.titleX
        y: 50
        visible: root.isError
        text: root.today && root.today.reason === "source missing" ? "source missing" : "source error"
        color: Tokens.amber
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightRegular
    }

    // ---- day strip: 24 hour dots, now bright, event acid ------------------
    Item {
        id: strip
        x: 0
        y: root.stripY
        width: 420
        height: 14

        Repeater {
            model: root.dotCount

            delegate: Rectangle {
                required property int index
                x: 3.4 + index * 16
                y: 4.4
                width: 5.2
                height: 5.2
                radius: 2.6
                color: Tokens.ice
                opacity: (index <= root.nowHour ? 0.58 : 0.22) * root.dimmed
            }
        }

        Rectangle {
            visible: root.hasEvent
            x: 6 + root.eventHour * 16 - 4.6
            y: 2.4
            width: 9.2
            height: 9.2
            radius: 4.6
            color: Tokens.acid
            opacity: root.dimmed
        }
    }
}
