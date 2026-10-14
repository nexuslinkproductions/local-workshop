pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import ".."

// AppDial.qml — M1 APP-DL hero: N-tick app ring + A-Z index ring + tracked
// arc around a working circular search field, flanked by 16 HexWell launch
// targets (top-used first on the mid cells, then alphabetical). Search is a
// real TextInput — Enter launches the top hit through AppModel.launch().
// Static canvas; repaints only when the catalogue or use-counts change.
Item {
    id: root

    property var apps: []                       // AppModel.apps
    property var uses: ({})                     // AppModel.uses
    property int totalUse: 0                    // AppModel.totalUse
    property var pinnedApps: []                 // AppModel.pinned (curated)
    signal launch(var app)

    // dial geometry — design panel 1160x584, centre (580,306)
    readonly property real s: Math.min(width / 1160, height / 584)
    readonly property real dcx: width * 0.5
    readonly property real dcy: height * (306 / 584)

    readonly property var sortedApps: {
        var a = apps.slice(0);
        a.sort(function (x, y) { return String(x.id).toLowerCase() < String(y.id).toLowerCase() ? -1 : 1; });
        return a;
    }
    readonly property int nApps: sortedApps.length
    readonly property int nTracked: {
        var n = 0;
        for (var i = 0; i < apps.length; i++)
            if ((uses[apps[i].id] || 0) > 0) n++;
        return n;
    }
    readonly property var trackedIds: {
        var out = [];
        for (var i = 0; i < apps.length; i++)
            if ((uses[apps[i].id] || 0) > 0)
                out.push(apps[i].id);
        return out;
    }

    // 16 hex slots — design order puts the four mid cells first (top-used)
    readonly property var slots: [
        [-330, -69], [-330, 69], [330, -69], [330, 69],
        [-248, -204], [-248, 204], [-490, -69], [-490, 69],
        [-408, -204], [-408, 204], [248, -204], [248, 204],
        [490, -69], [490, 69], [408, -204], [408, 204]
    ]
    // curated pins first (AppModel policy); by-use only fills leftover slots
    readonly property var pinned: {
        var out = [], seen = {}, i;
        for (i = 0; i < pinnedApps.length && out.length < 16; i++) {
            out.push(pinnedApps[i]);
            seen[pinnedApps[i].id] = true;
        }
        if (out.length < 16) {
            var byUse = sortedApps.slice(0);
            byUse.sort(function (x, y) {
                var d = (uses[y.id] || 0) - (uses[x.id] || 0);
                if (d !== 0) return d;
                return String(x.name).toLowerCase() < String(y.name).toLowerCase() ? -1 : 1;
            });
            for (i = 0; i < byUse.length && out.length < 16; i++)
                if (!seen[byUse[i].id])
                    out.push(byUse[i]);
        }
        return out;
    }

    // ---- search -------------------------------------------------------------
    property string query: ""
    readonly property var results: {
        var q = query.trim().toLowerCase();
        if (q === "") return [];
        var out = [];
        for (var i = 0; i < sortedApps.length && out.length < 8; i++) {
            var a = sortedApps[i];
            if (String(a.name).toLowerCase().indexOf(q) >= 0
                || String(a.id).toLowerCase().indexOf(q) >= 0)
                out.push(a);
        }
        return out;
    }

    function focusSearch() { arm(); }
    function clearSearch() { query = ""; search.text = ""; }
    function launchTop() {
        if (results.length > 0)
            root.launch(results[0]);
        disarm();
    }

    // ---------- keyboard grab ---------------------------------------------
    // The host surface is WlrKeyboardFocus.None, so typing needs an explicit
    // hyprland_focus_grab_v1 on this window (AppGrid.qml idiom). Arm when the
    // field is clicked; release on Escape/launch/click elsewhere.
    readonly property var hostWindow: QsWindow.window
    property bool kbArmed: false

    HyprlandFocusGrab {
        windows: root.hostWindow ? [root.hostWindow] : []
        // `active` is bound, never assigned — flip kbArmed to take/release.
        active: root.kbArmed && !!root.hostWindow && root.visible
        onCleared: root.kbArmed = false
    }

    function arm() {
        kbArmed = true;
        search.forceActiveFocus();
    }
    function disarm() { kbArmed = false; }
    onVisibleChanged: if (!visible)
        disarm()

    // ------------------------------------------------------------- painting
    Canvas {
        id: dial
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var pol = FuiTokens.pol;
            var s = root.s, cx = root.dcx, cy = root.dcy;
            if (!(s > 0))
                return;
            function P(r, deg) { return pol(cx, cy, r * s, deg); }
            function ring(r, col, w) {
                if (!(r * s > 0))
                    return;
                ctx.lineWidth = w || 1;
                ctx.strokeStyle = FuiTokens.css(col);
                ctx.beginPath();
                ctx.arc(cx, cy, r * s, 0, 6.284);
                ctx.stroke();
            }
            var ice = FuiTokens.ice;

            // outer ring + N-tick wheel (one tick per app, major every 10)
            ring(222, FuiTokens.tone(ice, 0.55));
            ring(226, FuiTokens.tone(ice, 0.15));
            var N = Math.max(1, root.nApps);
            for (var i = 0; i < N; i++) {
                var ang = i * 360 / N;
                var major = i % 10 === 0;
                var a1 = P(222, ang), a2 = P(222 + (major ? 9 : 4), ang);
                ctx.lineWidth = 1;
                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(ice, major ? 0.6 : 0.3));
                ctx.beginPath(); ctx.moveTo(a1.x, a1.y); ctx.lineTo(a2.x, a2.y); ctx.stroke();
            }
            // tracked app markers 212->232
            for (i = 0; i < root.sortedApps.length; i++) {
                var app = root.sortedApps[i];
                if ((root.uses[app.id] || 0) <= 0)
                    continue;
                var aa = i / N * 360;
                var t1 = P(212, aa), t2 = P(232, aa);
                ctx.lineWidth = 2;
                ctx.strokeStyle = FuiTokens.css(ice);
                ctx.beginPath(); ctx.moveTo(t1.x, t1.y); ctx.lineTo(t2.x, t2.y); ctx.stroke();
            }
            // ring index labels every 10
            ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
            ctx.font = Math.max(11, Math.round(11 * Math.max(0.5, s))) + "px 'Kode Mono'";
            ctx.textAlign = "center";
            for (i = 0; i < N; i += 10) {
                var lp = P(240, i * 360 / N);
                ctx.fillText((i < 10 ? "0" : "") + i, lp.x, lp.y + 4);
            }
            // A-Z ring
            ring(196, FuiTokens.tone(ice, 0.25));
            ctx.fillStyle = FuiTokens.css(FuiTokens.tone(ice, 0.75));
            for (i = 0; i < 26; i++) {
                var ga = i * 360 / 26;
                var gp = P(174, ga);   // inside the 191-196 tick band, clear gap
                ctx.fillText(String.fromCharCode(65 + i), gp.x, gp.y + 4);
                var g1 = P(196, ga + 360 / 52), g2 = P(191, ga + 360 / 52);
                ctx.lineWidth = 1;
                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(ice, 0.4));
                ctx.beginPath(); ctx.moveTo(g1.x, g1.y); ctx.lineTo(g2.x, g2.y); ctx.stroke();
            }
            // dashed inner ring
            ctx.setLineDash([1, 4]);
            ring(170, FuiTokens.tone(ice, 0.18));
            ctx.setLineDash([]);
            // tracked arc: lit share = tracked count / N, from -40deg
            var a0 = -40, span = N > 0 ? 360 * root.nTracked / N : 0;
            ctx.lineWidth = 8;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(ice, 0.10));
            ctx.beginPath();
            ctx.arc(cx, cy, 160 * s, (a0 - 90) * Math.PI / 180,
                    (a0 + span - 90) * Math.PI / 180);
            ctx.stroke();
            ctx.lineWidth = 2;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(ice, 0.9));
            ctx.beginPath();
            ctx.arc(cx, cy, 160 * s, (a0 - 90) * Math.PI / 180,
                    (a0 + span - 90) * Math.PI / 180);
            ctx.stroke();
            ctx.lineWidth = 1;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(ice, 0.15));
            ctx.beginPath();
            ctx.arc(cx, cy, 160 * s, (a0 + span + 2 - 90) * Math.PI / 180,
                    (320 - 2 - 90) * Math.PI / 180);
            ctx.stroke();
            // TRACKED leader
            var lp0 = P(160, a0 + 180 * root.nTracked / Math.max(1, N));
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(ice, 0.7));
            ctx.beginPath();
            ctx.moveTo(lp0.x, lp0.y);
            ctx.lineTo(lp0.x + 22 * s, lp0.y + 22 * s);
            ctx.lineTo(cx - 30 * s, lp0.y + 22 * s);
            ctx.stroke();
            ctx.fillStyle = FuiTokens.css(ice);
            ctx.font = Math.max(11, Math.round(11 * Math.max(0.5, s))) + "px 'Kode Mono'";
            ctx.textAlign = "left";
            ctx.fillText("TRACKED " + root.nTracked + "/" + N,
                         cx - 26 * s, lp0.y + 26 * s + 4);
            // crosshair construction ticks
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(ice, 0.4));
            [[-252, -232, 0], [232, 252, 0]].forEach(function (h) {
                ctx.beginPath();
                ctx.moveTo(cx + h[0] * s, cy); ctx.lineTo(cx + h[1] * s, cy);
                ctx.stroke();
            });
            ctx.beginPath(); ctx.moveTo(cx, cy - 242 * s); ctx.lineTo(cx, cy - 232 * s); ctx.stroke();
            ctx.beginPath(); ctx.moveTo(cx, cy + 232 * s); ctx.lineTo(cx, cy + 250 * s); ctx.stroke();
            // search field frame — acid edge while the focus grab is armed
            ctx.strokeStyle = FuiTokens.css(root.kbArmed ? FuiTokens.acid
                                                       : FuiTokens.tone(ice, 0.8));
            ctx.fillStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.bg, 0.85));
            var fw = 344 * s, fh = 48 * s;
            ctx.beginPath();
            ctx.rect(cx - fw / 2, cy - fh / 2, fw, fh);
            ctx.fill(); ctx.stroke();
            ctx.strokeStyle = FuiTokens.css(root.kbArmed ? FuiTokens.tone(FuiTokens.acid, 0.55)
                                                       : FuiTokens.tone(ice, 0.4));
            ctx.strokeRect(cx - fw / 2 + 4 * s, cy - fh / 2 + 4 * s, 32 * s, fh - 8 * s);
            // acid caret marker left of text zone
            ctx.lineWidth = 1.5;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.acid);
            ctx.beginPath();
            ctx.moveTo(cx - fw / 2 + 43 * s, cy - 11 * s);
            ctx.lineTo(cx - fw / 2 + 43 * s, cy + 11 * s);
            ctx.stroke();
        }
        Connections {
            target: root
            function onAppsChanged() { dial.requestPaint(); }
            function onUsesChanged() { dial.requestPaint(); }
            function onSChanged() { dial.requestPaint(); }
            function onKbArmedChanged() { dial.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // click on empty dial area releases the grab (never eats the press —
    // children above handle their own hits, propagation reaches here only
    // when nothing else accepted)
    MouseArea {
        anchors.fill: parent
        propagateComposedEvents: true
        onPressed: function (m) { root.disarm(); m.accepted = false; }
    }

    // ------------------------------------------------------------ centre text
    Text {
        x: root.dcx - 150; y: root.dcy - 92 * root.s
        width: 300; horizontalAlignment: Text.AlignHCenter
        text: "APP-SEARCH"
        color: FuiTokens.ice
        font.family: FuiTokens.display
        font.pixelSize: FuiTokens.px.cap
        font.letterSpacing: FuiTokens.ls.label
    }
    Text {
        x: root.dcx - 150; y: root.dcy - 76 * root.s
        width: 300; horizontalAlignment: Text.AlignHCenter
        text: root.nApps + "<font color='" + FuiTokens.mute + "'><i> APPS</i></font>"
        textFormat: Text.RichText
        color: FuiTokens.white
        font.family: FuiTokens.display
        font.pixelSize: 30 * Math.max(0.6, root.s)
    }
    // ------------------------------------------------------------- search field
    Item {
        x: root.dcx - 172 * root.s
        y: root.dcy - 24 * root.s
        width: 344 * root.s
        height: 48 * root.s
        Text {                       // icon cell glyph
            x: 0; width: 40 * root.s; height: parent.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: FuiTokens.ico.search
            color: FuiTokens.ice
            font.family: FuiTokens.icons
            font.pixelSize: Math.max(11, 15 * root.s)
        }
        TextInput {
            id: search
            x: 46 * root.s; width: parent.width - x - 8
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            color: FuiTokens.txt
            font.family: FuiTokens.mono
            font.pixelSize: Math.max(11, 14 * root.s)
            clip: true
            onTextChanged: root.query = text
            Keys.onReturnPressed: root.launchTop()
            Keys.onEnterPressed: root.launchTop()
            Keys.onEscapePressed: { root.clearSearch(); root.disarm(); }
            Keys.onDownPressed: resultsList.incrementCurrentIndex()
            Keys.onUpPressed: resultsList.decrementCurrentIndex()
            Text {
                visible: search.text === ""
                anchors.verticalCenter: parent.verticalCenter
                text: "search " + root.nApps + " apps"
                color: FuiTokens.dim
                font: search.font
            }
        }
        MouseArea {                  // click anywhere in the field arms the grab
            anchors.fill: parent
            onClicked: root.arm()
            // let TextInput position the cursor where clicked
            propagateComposedEvents: true
            onPressed: function (m) { root.arm(); m.accepted = false; }
        }
    }

    // results overlay (below the field, over the A-Z ring edge)
    Rectangle {
        visible: root.query.trim() !== ""
        x: root.dcx - 172 * root.s
        y: root.dcy + 26 * root.s
        width: 344 * root.s
        height: Math.min(resultsList.count, 8) * 22 + 8
        color: FuiTokens.tone(FuiTokens.bg, 0.94)
        border.width: 1
        border.color: FuiTokens.hair
        ListView {
            id: resultsList
            anchors { fill: parent; margins: 4 }
            model: root.results
            interactive: false
            delegate: Item {
                required property int index
                required property var modelData
                width: resultsList.width
                height: 22
                Rectangle {
                    anchors.fill: parent
                    color: index === resultsList.currentIndex
                           ? FuiTokens.tone(FuiTokens.ice, 0.12) : "transparent"
                }
                Text {
                    x: 6; anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 70
                    elide: Text.ElideRight
                    text: String(modelData.name || "")
                    color: FuiTokens.txt
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.cap
                }
                Text {
                    anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                    text: (root.uses[modelData.id] || 0) + "x"
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { root.disarm(); root.launch(parent.modelData); }
                }
            }
        }
    }

    // ------------------------------------------------------------- hex wells
    Repeater {
        model: root.pinned
        delegate: HexWell {
            id: well
            required property int index
            required property var modelData
            readonly property var slot: root.slots[Math.min(index, 15)]
            x: root.dcx + slot[0] * root.s - 76 * root.s
            y: root.dcy + slot[1] * root.s - 66 * root.s
            width: 152 * root.s
            height: 132 * root.s
            margin: 5 * root.s
            icon: String(modelData.icon || "")
            glyph: FuiTokens.ico.grid
            label: String(modelData.name || "")
            sub: modelData.cats && modelData.cats.length > 0
                 ? String(modelData.cats[0]).toLowerCase().slice(0, 12) : ""
            serial: "APP-0x" + ("0" + root.sortedApps.indexOf(modelData)
                    .toString(16).toUpperCase()).slice(-2)
            count: root.uses[modelData.id] || -1
            live: (root.uses[modelData.id] || 0) > 0
            onActivated: { root.disarm(); root.launch(modelData); }
        }
    }
}
