pragma ComponentBehavior: Bound

import QtQuick
import ".."

// LimitCard.qml — one LIM-* cell of the LIM-02 grid (M1-dp2 limits panel):
// code/sub/state-tag header, provider name, SegGauge (USED % + window arc),
// status + reset/action caption lines, optional engraved action button.
Item {
    id: root

    property string code: ""          // LIM-CLD-WK
    property string sub: ""           // WEEKLY 7D
    property string name: ""          // CLAUDE
    property string stag: ""          // E429 | A401 | N/A | OK
    property string sev: "na"         // alert | warn | na | ok
    property var frac: null           // 0..1 used | null
    property var win: null            // 0..1 window elapsed | null
    property string statusLine: ""    // EXHAUSTED | AUTH PENDING | NO LIMIT FEED | NOMINAL
    property var lines: []            // up to 4 caption lines
    property string winlab: ""        // "7d window elapsed 52.7% calc"
    property var action: null         // {label, argv:[...]} | null

    signal runAction(var argv)

    readonly property color sevCol: sev === "alert" ? FuiTokens.alert
                                  : sev === "warn" ? FuiTokens.warn
                                  : sev === "ok" ? FuiTokens.acid
                                  : FuiTokens.ice

    implicitWidth: 216
    implicitHeight: 232

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(4/255, 6/255, 8/255, 0.35)
        border.width: 1
        border.color: FuiTokens.hair3
    }

    Column {
        anchors { left: parent.left; right: parent.right; top: parent.top
                  margins: 8 }
        spacing: 0

        Row {
            id: headRow
            width: parent.width
            spacing: 8
            Tx { id: codeTx; role: "code"; text: root.code; font.pixelSize: FuiTokens.px.micro + 1 }
            Tx {
                role: "cap"
                text: root.sub
                font.pixelSize: FuiTokens.px.micro + 1
                width: Math.max(10, headRow.width - codeTx.implicitWidth
                                - tagTx.implicitWidth - 2 * headRow.spacing)
            }
            Tx {
                id: tagTx
                role: "tag"
                text: root.stag
                color: root.sev === "alert" ? FuiTokens.alert
                     : root.sev === "warn" ? FuiTokens.warn
                     : root.sev === "ok" ? FuiTokens.acid : FuiTokens.dim
                topPadding: 1; bottomPadding: 1; leftPadding: 4; rightPadding: 4
                Rectangle {
                    z: -1
                    anchors.fill: parent
                    color: "transparent"
                    border.width: 1
                    border.color: root.sev === "alert" ? FuiTokens.tone(FuiTokens.alert, 0.6)
                                : root.sev === "warn" ? FuiTokens.tone(FuiTokens.warn, 0.55)
                                : root.sev === "ok" ? FuiTokens.tone(FuiTokens.acid, 0.55)
                                : FuiTokens.hair2
                }
            }
        }

        Tx {
            role: "lbl"
            text: root.name
            tone: FuiTokens.white
            font.pixelSize: FuiTokens.px.body
            topPadding: 5
        }
    }

    SegGauge {
        id: gauge
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 46 }
        height: Math.min(104, root.width * 0.5)
        frac: root.frac
        sev: root.sev === "na" ? "na" : root.sev
        color: FuiTokens.ice
        win: root.win
    }

    Column {
        id: bodyCol
        anchors { left: parent.left; right: parent.right; leftMargin: 8; rightMargin: 8
                  top: gauge.bottom; topMargin: 4; bottom: parent.bottom }
        spacing: 1
        Tx {
            role: "cap"
            text: root.statusLine
            tone: root.sev === "alert" ? FuiTokens.alert
                : root.sev === "warn" ? FuiTokens.warn
                : root.sev === "ok" ? FuiTokens.acid : FuiTokens.faint
            font.letterSpacing: 1.5
        }
        Repeater {
            model: root.lines
            delegate: Tx {
                required property var modelData
                role: "cap"
                text: String(modelData.v !== undefined ? modelData.v : modelData)
                tone: modelData.c !== undefined ? modelData.c : FuiTokens.dim
                width: bodyCol.width
            }
        }
        Tx { role: "faint"; text: root.winlab; visible: root.winlab !== "" }
        EngravedButton {
            visible: root.action !== null
            width: parent.width
            height: 20
            label: root.action !== null ? String(root.action.label) : ""
            chamfer: 4
            onActivated: root.runAction(root.action.argv)
        }
    }
}
