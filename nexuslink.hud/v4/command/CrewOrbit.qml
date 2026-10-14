pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import ".."

// CrewOrbit.qml — M1 CRW-OR crew orbit: provider lanes as ring arcs, one
// radial session bar + rotated name node per bot, lane leader labels, centre
// 24h totals, exhaustion banner (honest: only when tokData reports a provider
// limit at 100%) and two real action keys. Static canvas — repaints only when
// crew/tokData/geometry change.
Item {
    id: root

    property var crew: ({})
    property var tokData: ({})

    // ---------- data -------------------------------------------------------
    // crew provider -> tokens.json provider key (only confident aliases)
    readonly property var providerKey: ({
            "opencode-go": "opencode-go",
            "opencode": "opencode",
            "anthropic": "claude",
            "openai-codex": "codex",
            "codex": "codex"
        })

    function laneExhausted(provider) {
        var k = providerKey[provider];
        if (!k) return null;
        var prov = (tokData.providers || {})[k];
        var lim = prov && prov.meta && prov.meta.limits;
        if (!lim || lim.length === undefined)
            return null;
        for (var i = 0; i < lim.length; i++)
            if (Number(lim[i].percent) >= 1.0)
                return lim[i];
        return null;
    }

    // groups: [{provider, label, models, members[], exhausted}]
    readonly property var groups: {
        var bots = (crew && crew.bots) ? crew.bots : [];
        var map = {}, order = [];
        for (var i = 0; i < bots.length; i++) {
            var b = bots[i];
            var p = String(b.provider || "?");
            if (!map[p]) {
                map[p] = { "provider": p, "models": [], "members": [] };
                order.push(p);
            }
            map[p].members.push(b);
            var m = String(b.model || "");
            if (m !== "" && map[p].models.indexOf(m) === -1)
                map[p].models.push(m);
        }
        order.sort();
        var out = [];
        for (i = 0; i < order.length; i++) {
            var g = map[order[i]];
            g.exhausted = laneExhausted(order[i]);
            out.push(g);
        }
        return out;
    }
    readonly property var namedBots: {
        var out = [];
        for (var i = 0; i < groups.length; i++)
            out = out.concat(groups[i].members);
        return out;
    }
    readonly property int totalSes: {
        if (crew && crew.totals && crew.totals.sessions_24h !== undefined)
            return Number(crew.totals.sessions_24h);
        var n = 0;
        for (var i = 0; i < namedBots.length; i++)
            n += Number(namedBots[i].sessions_24h) || 0;
        return n;
    }
    readonly property int activeCount: {
        var n = 0;
        for (var i = 0; i < namedBots.length; i++)
            if (namedBots[i].state === "active") n++;
        return n;
    }
    readonly property int stalledCount: {
        var n = 0;
        for (var i = 0; i < groups.length; i++)
            if (groups[i].exhausted) n += groups[i].members.length;
        return n;
    }
    readonly property var stalledLane: {
        for (var i = 0; i < groups.length; i++)
            if (groups[i].exhausted) return groups[i];
        return null;
    }

    // ---------- geometry (design panel 796x560) -----------------------------
    readonly property real cx: width * 0.5
    readonly property real cy: height * (246 / 560)
    // ring bottom must stay above the banner zone (height-86) with margin
    readonly property real rl: Math.min(Math.min(width, height) * (196 / 560),
                                        height * 0.561 - 104)
    readonly property real rn: rl * (134 / 206)
    readonly property real barBase: rl * (72 / 206)
    readonly property real pxPerSes: rl * (5 / 206)
    // angular packing: STEP per member, GAP between lanes, from 21deg
    readonly property real gap: groups.length > 1 ? 8 : 0
    readonly property real stepDeg: namedBots.length > 0
        ? Math.min(16, (360 - groups.length * gap) / namedBots.length) : 16
    readonly property real a0: 21

    // member angle: groups in order, members contiguous inside the lane arc
    function memberAngle(gi, mi) {
        var a = a0;
        for (var g = 0; g < gi; g++)
            a += groups[g].members.length * stepDeg + gap;
        return a + stepDeg * (mi + 0.5);
    }
    function laneAngles(gi) {
        var a = a0;
        for (var g = 0; g < gi; g++)
            a += groups[g].members.length * stepDeg + gap;
        return { "a0": a, "a1": a + groups[gi].members.length * stepDeg };
    }
    function botColor(b, laneCol) {
        if (laneCol === FuiTokens.warn) return FuiTokens.warn;
        return FuiTokens.stateColor(b.state);
    }
    function modelShort(m) {
        return String(m || "").replace("claude-", "").replace("deepseek-", "ds-")
               .replace("cursor/", "").replace("-flash", "f").replace("gpt-", "gpt");
    }
    // display name only — the shared store keeps name==="default" for identity
    function displayName(n) {
        var s = String(n || "");
        return s === "default" ? "Hermes" : s;
    }

    // ---------- painted layer ----------------------------------------------
    Canvas {
        id: ring
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            if (width <= 0 || height <= 0 || !(root.rl > 0) || !(root.barBase > 0))
                return;
            var pol = FuiTokens.pol;
            // centre rings
            ctx.lineWidth = 1;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.45));
            ctx.beginPath(); ctx.arc(root.cx, root.cy, 62 * (root.rl / 206), 0, 6.284); ctx.stroke();
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.12));
            ctx.beginPath(); ctx.arc(root.cx, root.cy, 58 * (root.rl / 206), 0, 6.284); ctx.stroke();
            // session guides 0/5/10
            for (var g = 0; g <= 2; g++) {
                var rr = root.barBase + g * 5 * root.pxPerSes;
                ctx.setLineDash(g === 0 ? [] : [2, 3]);
                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, g === 0 ? 0.3 : 0.12));
                ctx.beginPath(); ctx.arc(root.cx, root.cy, rr, 0, 6.284); ctx.stroke();
            }
            ctx.setLineDash([]);
            // lanes + members
            for (var gi = 0; gi < root.groups.length; gi++) {
                var grp = root.groups[gi];
                var ang = root.laneAngles(gi);
                var laneCol = grp.exhausted ? FuiTokens.warn : FuiTokens.ice;
                // lane arcs RL & RL+6 (degrees -> rad, pol() convention: 0=up cw)
                for (var k = 0; k < 2; k++) {
                    var R = root.rl + k * 6;
                    ctx.lineWidth = k === 0 ? 1.5 : 1;
                    ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(laneCol, k === 0 ? 0.85 : 0.25));
                    ctx.beginPath();
                    ctx.arc(root.cx, root.cy, R,
                            (ang.a0 + 1 - 90) * Math.PI / 180,
                            (ang.a1 - 1 - 90) * Math.PI / 180);
                    ctx.stroke();
                }
                // lane edge ticks
                for (var s = 0; s < 2; s++) {
                    var aa = s === 0 ? ang.a0 + 1 : ang.a1 - 1;
                    var p1 = pol(root.cx, root.cy, root.rl - 5, aa);
                    var p2 = pol(root.cx, root.cy, root.rl + 10, aa);
                    ctx.lineWidth = 1;
                    ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(laneCol, 0.8));
                    ctx.beginPath(); ctx.moveTo(p1.x, p1.y); ctx.lineTo(p2.x, p2.y); ctx.stroke();
                }
                // members: radial bars + member ticks on lane arc
                for (var mi = 0; mi < grp.members.length; mi++) {
                    var b = grp.members[mi];
                    var ma = root.memberAngle(gi, mi);
                    var n = Number(b.sessions_24h) || 0;
                    var bc = root.botColor(b, laneCol);
                    if (n > 0) {
                        var q1 = pol(root.cx, root.cy, root.barBase + 2, ma);
                        // design: 5 px per session at rl=206 → n * pxPerSes * 5
                        var q2 = pol(root.cx, root.cy,
                                     root.barBase + Math.min(12, n) * 5 * root.pxPerSes, ma);
                        ctx.lineWidth = 3;
                        ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(bc, 0.85));
                        ctx.beginPath(); ctx.moveTo(q1.x, q1.y); ctx.lineTo(q2.x, q2.y); ctx.stroke();
                    }
                    var r1 = pol(root.cx, root.cy, root.rl - 3, ma);
                    var r2 = pol(root.cx, root.cy, root.rl + 3, ma);
                    ctx.lineWidth = 1;
                    ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(laneCol, 0.6));
                    ctx.beginPath(); ctx.moveTo(r1.x, r1.y); ctx.lineTo(r2.x, r2.y); ctx.stroke();
                }
                // lane leader polyline to the side column label
                var mid = (ang.a0 + ang.a1) / 2;
                var lp1 = pol(root.cx, root.cy, root.rl + 8, mid);
                var lp2 = pol(root.cx, root.cy, root.rl + 24, mid);
                var right = Math.sin(mid * Math.PI / 180) > 0;
                var lx = right ? root.width * (646 / 796) : root.width * (150 / 796);
                var ly = leaderY(gi);
                ctx.lineWidth = 1;
                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(laneCol, 0.55));
                // elbow leader: radial stub -> vertical drop outside the name
                // band -> horizontal into the label block (never crosses arcs)
                ctx.beginPath();
                ctx.moveTo(lp1.x, lp1.y);
                ctx.lineTo(lp2.x, lp2.y);
                ctx.lineTo(lp2.x, ly + 6);
                ctx.lineTo(right ? lx - 8 : lx + 8, ly + 6);
                ctx.stroke();
                ctx.fillStyle = FuiTokens.css(laneCol);
                ctx.beginPath(); ctx.arc(lp1.x, lp1.y, 2, 0, 6.284); ctx.fill();
            }
        }
        // vertical slot for lane label block gi (two columns, 78px pitch)
        function leaderY(gi) {
            var leftI = 0, rightI = 0;
            for (var g = 0; g < root.groups.length; g++) {
                var a = root.laneAngles(g);
                var mid = (a.a0 + a.a1) / 2;
                var right = Math.sin(mid * Math.PI / 180) > 0;
                if (g === gi)
                    return root.height * (right ? (58 + rightI * 78) / 560
                                                : (70 + leftI * 78) / 560);
                if (right) rightI++; else leftI++;
            }
            return 60;
        }
        Connections {
            target: root
            function onGroupsChanged() { ring.requestPaint(); }
            function onRlChanged() { ring.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // ---------- nodes + names ------------------------------------------------
    Repeater {
        model: root.namedBots.length === 0 ? 0 : root.namedBots
        delegate: Item {
            id: node
            required property int index
            required property var modelData
            // find this bot's group + member index
            readonly property int gi: {
                var i = 0;
                for (var g = 0; g < root.groups.length; g++) {
                    if (node.index < i + root.groups[g].members.length)
                        return g;
                    i += root.groups[g].members.length;
                }
                return 0;
            }
            readonly property int mi: {
                var i = 0;
                for (var g = 0; g < node.gi; g++)
                    i += root.groups[g].members.length;
                return node.index - i;
            }
            readonly property var grp: root.groups.length > 0 ? root.groups[gi] : null
            readonly property var bot: modelData
            readonly property real ang: root.memberAngle(gi, mi)
            readonly property color bc: grp ? root.botColor(bot,
                grp.exhausted ? FuiTokens.warn : FuiTokens.ice) : FuiTokens.ice

            Rectangle {                              // diamond node at RN
                x: FuiTokens.pol(root.cx, root.cy, root.rn, node.ang).x - 4
                y: FuiTokens.pol(root.cx, root.cy, root.rn, node.ang).y - 4
                width: 8; height: 8
                rotation: node.ang + 45
                transformOrigin: Item.Center
                color: node.bot.state === "active" ? node.bc : FuiTokens.bg
                border.width: 1
                border.color: FuiTokens.tone(node.bc, 0.9)
            }
            Text {                                   // tangential name
                property var p: FuiTokens.pol(root.cx, root.cy, root.rn + 12, node.ang)
                readonly property bool onRight: (node.ang % 360) < 180
                x: onRight ? p.x : p.x - width
                y: p.y - height / 2
                width: 76
                horizontalAlignment: onRight ? Text.AlignLeft : Text.AlignRight
                rotation: onRight ? node.ang - 90 : node.ang + 90
                transformOrigin: onRight ? Item.Left : Item.Right
                text: root.displayName(node.bot.name)
                elide: Text.ElideRight
                color: node.bot.state === "dormant" ? FuiTokens.dim : FuiTokens.white
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.cap
            }
        }
    }

    // lane label blocks (positioned by the same slot fn the canvas uses)
    Repeater {
        model: root.groups
        delegate: Item {
            id: lab
            required property int index
            required property var modelData
            readonly property var grp: modelData
            readonly property var la: root.laneAngles(index)
            readonly property real mid: (la.a0 + la.a1) / 2
            readonly property bool onRight: Math.sin(mid * Math.PI / 180) > 0
            readonly property real ly: ring.leaderY(index)
            readonly property color lc: grp.exhausted ? FuiTokens.warn : FuiTokens.ice
            x: onRight ? root.width * (646 / 796) : root.width * (150 / 796)
            y: ly
            width: 150
            Text {
                x: lab.onRight ? 0 : -150
                width: 150
                horizontalAlignment: lab.onRight ? Text.AlignLeft : Text.AlignRight
                text: String(lab.grp.provider || "").toUpperCase()
                color: FuiTokens.white
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: FuiTokens.ls.cap
            }
            Text {
                x: lab.onRight ? 0 : -150
                y: 15; width: 150
                horizontalAlignment: lab.onRight ? Text.AlignLeft : Text.AlignRight
                text: lab.grp.models.length > 0
                      ? lab.grp.models.slice(0, 2).map(root.modelShort).join(" / ")
                      : ""
                elide: Text.ElideRight
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
            }
            Text {
                x: lab.onRight ? 0 : -150
                y: 30; width: 150
                horizontalAlignment: lab.onRight ? Text.AlignLeft : Text.AlignRight
                text: lab.grp.members.length + " bots · "
                      + lab.grp.members.reduce(function (s, b) {
                            return s + (Number(b.sessions_24h) || 0); }, 0)
                      + " ses/24h"
                color: FuiTokens.dim
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
            }
            Text {
                x: lab.onRight ? 0 : -150
                y: 44; width: 150
                horizontalAlignment: lab.onRight ? Text.AlignLeft : Text.AlignRight
                text: lab.grp.exhausted ? "EXHAUSTED"
                    : lab.grp.members.some(function (b) { return b.state === "active"; })
                        ? "ACTIVE " + lab.grp.members.filter(function (b) {
                            return b.state === "active"; }).length
                        : "standby"
                color: lab.grp.exhausted ? FuiTokens.warn
                     : lab.grp.members.some(function (b) { return b.state === "active"; })
                        ? FuiTokens.acid : FuiTokens.faint
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
            }
        }
    }

    // ---------- centre readout ----------------------------------------------
    Text {
        x: root.cx - 60; y: root.cy - 20
        width: 120; horizontalAlignment: Text.AlignHCenter
        text: root.namedBots.length ? String(root.totalSes) : FuiTokens.unknownGlyph
        color: FuiTokens.white
        font.family: FuiTokens.display
        font.pixelSize: 34
    }
    Text {
        x: root.cx - 60; y: root.cy + 20
        width: 120; horizontalAlignment: Text.AlignHCenter
        text: "SES / 24H"
        color: FuiTokens.dim
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.cap
    }
    Text {
        x: root.cx - 46; y: root.cy - 30
        width: 40; horizontalAlignment: Text.AlignHCenter
        text: "A" + (root.activeCount < 10 ? "0" : "") + root.activeCount
        color: FuiTokens.acid
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.cap
    }
    Text {
        x: root.cx + 6; y: root.cy - 30
        width: 40; horizontalAlignment: Text.AlignHCenter
        text: "S" + (root.stalledCount < 10 ? "0" : "") + root.stalledCount
        color: root.stalledCount > 0 ? FuiTokens.warn : FuiTokens.faint
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.cap
    }
    Text {
        x: root.cx - 60; y: root.cy + 38
        width: 120; horizontalAlignment: Text.AlignHCenter
        text: root.namedBots.length + " CREW"
        color: FuiTokens.faint
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
    // guide labels
    Text {
        x: root.cx + 4; y: root.cy - root.barBase - 10 * root.pxPerSes - 6
        text: "10"
        color: FuiTokens.faint
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
    Text {
        x: root.cx + 4; y: root.cy - root.barBase - 5 * root.pxPerSes - 6
        text: "5"
        color: FuiTokens.faint
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }

    // legend (right, above keys)
    Text {
        anchors { right: parent.right; rightMargin: 16 }
        y: root.height - 112
        text: "radial = ses/24h 0-10"
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
    Text {
        anchors { right: parent.right; rightMargin: 16 }
        y: root.height - 96
        text: "node = crew handle"
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }

    // ---------- exhaustion banner (honest: only when a limit is at 100%) ------
    Rectangle {
        visible: root.stalledLane !== null
        x: 16; y: root.height - 86
        width: 400; height: 78
        color: FuiTokens.tone(FuiTokens.warn, 0.04)
        border.width: 1
        border.color: FuiTokens.tone(FuiTokens.warn, 0.55)
        Rectangle {                    // corner tab
            x: -1; y: -1; width: 10; height: 10
            color: "transparent"
            Rectangle { x: 0; y: 0; width: 2; height: 10; color: FuiTokens.warn }
            Rectangle { x: 0; y: 0; width: 10; height: 2; color: FuiTokens.warn }
        }
        Column {
            x: 12; y: 8
            spacing: 3
            Text {
                text: (root.stalledLane ? String(root.stalledLane.provider).toUpperCase() : "")
                      + " WINDOW EXHAUSTED"
                color: FuiTokens.warn
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: FuiTokens.ls.cap
            }
            Text {
                text: root.stalledCount + " BOTS ON STALLED LANE"
                      + (root.stalledLane && root.stalledLane.exhausted
                         && root.stalledLane.exhausted.resetsAt
                         ? " · reset " + String(root.stalledLane.exhausted.resetsAt).slice(11, 16)
                         : "")
                color: FuiTokens.warn
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.cap
            }
            Text {
                width: 376
                elide: Text.ElideRight
                text: root.stalledLane
                      ? root.stalledLane.members.map(function (b) {
                            return root.displayName(b.name); }).join(" ")
                      : ""
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
            }
        }
    }

    // ---------- crew status (fills the banner slot when no lane is spent) --
    Rectangle {
        visible: root.stalledLane === null && root.groups.length > 0
        x: 16; y: root.height - 86
        width: 400; height: 78
        color: FuiTokens.tone(FuiTokens.ice, 0.02)
        border.width: 1
        border.color: FuiTokens.tone(FuiTokens.ice, 0.25)
        Rectangle {                    // corner tab
            x: -1; y: -1; width: 10; height: 10
            color: "transparent"
            Rectangle { x: 0; y: 0; width: 2; height: 10; color: FuiTokens.ice }
            Rectangle { x: 0; y: 0; width: 10; height: 2; color: FuiTokens.ice }
        }
        Column {
            x: 12; y: 8
            spacing: 3
            Text {
                // neutral: with no stalled lane we only know crew state, not
                // whether live limits are actually nominal
                text: "Crew status"
                color: FuiTokens.ice
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: FuiTokens.ls.cap
            }
            Text {
                text: root.activeCount + " ACTIVE · " + root.totalSes + " SES/24H"
                color: FuiTokens.dim
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.cap
            }
        }
    }

    // ---------- action keys ---------------------------------------------------
    EngravedButton {
        x: parent.width - 368; y: parent.height - 86
        width: 352; height: 36
        label: "NEW HERMES SESSION"
        glyph: FuiTokens.ico.plus
        code: ""
        keybind: ""
        onActivated: Quickshell.execDetached(
            ["bash", "-lc", 'exec "$@"', "orbit",
             "omarchy-launch-tui", "--app-id=org.nexus.hermes", "hermes"])
    }
    EngravedButton {
        x: parent.width - 368; y: parent.height - 42
        width: 352; height: 34
        label: "CREW FEED"
        glyph: FuiTokens.ico.eye
        code: ""
        keybind: ""
        onActivated: Quickshell.execDetached(
            ["bash", "-lc", 'exec "$@"', "orbit",
             "omarchy-launch-tui", "--app-id=org.nexus.crewview",
             "less", Quickshell.env("HOME") + "/.local/state/nexuslink/crew.json"])
    }
}
