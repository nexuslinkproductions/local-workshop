pragma ComponentBehavior: Bound

import QtQuick
import ".."
import QtQuick.Controls as QQC

// FuiFrame.qml — chamfered/bracketed instrument panel (M1 .frame).
// Hairline box + optional corner registration brackets + header strip
// (CODE / TITLE ......... meta). `live` flips border + brackets to acid —
// at most one live frame per deck (acid means live state only).
// Instrument codes + source metadata are quiet by default
// (showDiagnostics:false); the same text stays available as a header
// hover tooltip.
Item {
    id: root

    property string code: ""        // instrument id, e.g. "CRW-TL"
    property string title: ""       // e.g. "CREW ACTIVITY" (auto-uppercased)
    property string meta: ""        // right-aligned src/stamp string
    property bool showDiagnostics: false   // code + meta visible in the header
    property bool live: false
    property bool bare: false       // no fill, no border (brackets + header only)
    property bool brackets: true
    property int bracketLen: 12
    property int chamfer: 0         // >0 cuts all four corners (px)
    property int headerH: 28
    property int pad: 12
    readonly property int contentTop: (header.visible ? headerH : 0) + pad

    default property alias contentData: content.data
    implicitWidth: 240
    implicitHeight: 160

    Canvas {
        id: plate
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            var w = width, h = height, c = Math.min(root.chamfer, w / 2, h / 2);
            ctx.beginPath();
            ctx.moveTo(c, 0.5);
            ctx.lineTo(w - c, 0.5);
            ctx.lineTo(w - 0.5, c + 0.5);
            ctx.lineTo(w - 0.5, h - c - 0.5);
            ctx.lineTo(w - c, h - 0.5);
            ctx.lineTo(c, h - 0.5);
            ctx.lineTo(0.5, h - c - 0.5);
            ctx.lineTo(0.5, c + 0.5);
            ctx.closePath();
            if (!root.bare) {
                ctx.fillStyle = FuiTokens.css(FuiTokens.panel);
                ctx.fill();
                ctx.strokeStyle = FuiTokens.css(root.live
                        ? FuiTokens.tone(FuiTokens.acid, 0.28) : FuiTokens.hair2);
                ctx.lineWidth = FuiTokens.lwHair;
                ctx.stroke();
            }
            if (root.brackets) {
                var L = root.bracketLen;
                ctx.strokeStyle = FuiTokens.css(root.live ? FuiTokens.acid : FuiTokens.ice);
                ctx.globalAlpha = 0.85;
                ctx.lineWidth = FuiTokens.lwHair;
                ctx.beginPath();
                ctx.moveTo(0.5, L); ctx.lineTo(0.5, 0.5); ctx.lineTo(L, 0.5);
                ctx.moveTo(w - L, 0.5); ctx.lineTo(w - 0.5, 0.5); ctx.lineTo(w - 0.5, L);
                ctx.moveTo(0.5, h - L); ctx.lineTo(0.5, h - 0.5); ctx.lineTo(L, h - 0.5);
                ctx.moveTo(w - L, h - 0.5); ctx.lineTo(w - 0.5, h - 0.5); ctx.lineTo(w - 0.5, h - L);
                ctx.stroke();
                ctx.globalAlpha = 1;
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onLiveChanged() { plate.requestPaint(); }
            function onBareChanged() { plate.requestPaint(); }
            function onChamferChanged() { plate.requestPaint(); }
            function onBracketsChanged() { plate.requestPaint(); }
            function onBracketLenChanged() { plate.requestPaint(); }
        }
    }

    // header strip — hidden entirely when all three fields are empty
    Item {
        id: header
        visible: root.code !== "" || root.title !== "" || root.meta !== ""
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: root.headerH

        Text {
            id: codeTxt
            visible: root.code !== "" && root.showDiagnostics
            anchors { left: parent.left; leftMargin: root.pad; verticalCenter: parent.verticalCenter }
            text: root.code
            color: FuiTokens.ice
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.code
            font.letterSpacing: FuiTokens.ls.tag
        }
        Text {
            id: titleTxt
            visible: root.title !== ""
            anchors { left: codeTxt.visible ? codeTxt.right : parent.left
                      leftMargin: codeTxt.visible ? 10 : root.pad
                      right: metaTxt.visible ? metaTxt.left : parent.right
                      rightMargin: metaTxt.visible ? 8 : root.pad
                      verticalCenter: parent.verticalCenter }
            elide: Text.ElideRight
            text: root.title.toUpperCase()
            color: FuiTokens.white
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.code
            font.letterSpacing: FuiTokens.ls.title
        }
        Text {
            id: metaTxt
            visible: root.meta !== "" && root.showDiagnostics
            anchors { right: parent.right; rightMargin: root.pad; verticalCenter: parent.verticalCenter }
            text: root.meta
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.code
            font.letterSpacing: FuiTokens.ls.cap
        }
        // diagnostics stay reachable: hovering the header shows code + meta
        MouseArea {
            id: headerHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
        }
        QQC.ToolTip {
            // child of the header strip: opens just below it, non-modal,
            // takes no mouse input — the deck's drag pad still sees presses
            y: header.height + 4
            visible: headerHover.containsMouse && text !== ""
            delay: 250
            text: {
                var parts = [];
                if (root.code !== "") parts.push(root.code);
                if (root.title !== "") parts.push(root.title);
                if (root.meta !== "") parts.push(root.meta);
                return parts.join("  ·  ");
            }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: FuiTokens.hair3
        }
    }

    Item {
        id: content
        clip: true
        anchors {
            left: parent.left; right: parent.right
            top: parent.top; bottom: parent.bottom
            topMargin: root.contentTop; leftMargin: root.pad
            rightMargin: root.pad; bottomMargin: root.pad
        }
    }
}
