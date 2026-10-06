pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick

// FuiTokens.qml — M1 "instrument grade" design tokens (docs/m1).
// Single source for the FUI palette, fonts, type scale and hairline widths.
// Palette is copied 1:1 from src-M/m_base.css; fonts load the same files
// Theme.qml pins (~/.local/share/fonts/nexushud).
//
// Colour semantics (M-README): acid marks LIVE state only, azure marks flow,
// warn/alert mark limits and alarms, ice is the default instrument stroke.
QtObject {
    id: t

    // ---- palette ---------------------------------------------------------
    readonly property color bg: "#06080a"
    readonly property color panel: Qt.rgba(12/255, 17/255, 22/255, 0.72)
    readonly property color recess: Qt.rgba(4/255, 6/255, 8/255, 0.85)
    readonly property color txt: "#e2ecf2"
    readonly property color dim: Qt.rgba(226/255, 236/255, 242/255, 0.74)
    readonly property color mute: Qt.rgba(226/255, 236/255, 242/255, 0.56)
    readonly property color faint: Qt.rgba(226/255, 236/255, 242/255, 0.36)
    // hairline ice strokes at three opacities
    readonly property color hair: Qt.rgba(143/255, 216/255, 232/255, 0.30)
    readonly property color hair2: Qt.rgba(143/255, 216/255, 232/255, 0.16)
    readonly property color hair3: Qt.rgba(143/255, 216/255, 232/255, 0.08)
    readonly property color ice: "#8fd8e8"
    readonly property color acid: "#c8f31d"
    readonly property color azure: "#60a5fa"
    readonly property color warn: "#ffb300"
    readonly property color alert: "#ff4a3d"
    readonly property color white: "#f4f8fb"

    // ---- line weights (px) -----------------------------------------------
    readonly property real lwHair: 1        // every structural line
    readonly property real lwArc: 2         // value arcs
    readonly property real lwGlow: 8        // static glow = wide low-alpha under-stroke
    readonly property real glowAlpha: 0.10

    // ---- grid ------------------------------------------------------------
    readonly property int gridMinor: 16     // background schematic pitch
    readonly property int gridMajor: 128
    readonly property int deckMargin: 32    // outer margin (DP-2/HDMI sheets)
    readonly property int gutter: 24

    // ---- fonts -----------------------------------------------------------
    property FontLoader _display: FontLoader {
        id: displayLoader
        source: "file:///home/nexuslink/.local/share/fonts/nexushud/Michroma-Regular.ttf"
    }
    property FontLoader _mono: FontLoader {
        id: monoLoader
        source: "file:///home/nexuslink/.local/share/fonts/nexushud/KodeMono-VF.ttf"
    }
    // FA glyphs for engraved controls (same file the HTML sheets used).
    property FontLoader _icons: FontLoader {
        id: iconLoader
        source: "file:///usr/share/fonts/WOFF2/fa-solid-900.woff2"
    }
    readonly property string display: displayLoader.status === FontLoader.Ready
                                      && displayLoader.name !== "" ? displayLoader.name : "sans-serif"
    readonly property string mono: monoLoader.status === FontLoader.Ready
                                   && monoLoader.name !== "" ? monoLoader.name : "monospace"
    readonly property string icons: iconLoader.status === FontLoader.Ready
                                    && iconLoader.name !== "" ? iconLoader.name : "sans-serif"

    // ---- type ramp (px / letterSpacing) ----------------------------------
    // Mirrors m_base.css: code 11 ice ls1, title Michroma 11 ls3 white caps,
    // lbl Michroma 11 ls2.5 dim, cap/meta 11 mute, num Kode white, hero Michroma.
    readonly property var px: ({
            "micro": 11, "tag": 11, "cap": 11, "code": 11, "body": 11,
            "num": 11, "mid": 14, "big": 20, "hero": 52, "heroXL": 92
        })
    readonly property var ls: ({
            "cap": 0.5, "tag": 1.0, "body": 0.4, "label": 2.5,
            "title": 3.0, "hero": 2.0
        })

    // ---- misc ------------------------------------------------------------
    readonly property string unknownGlyph: "—"

    // FA7 Solid codepoints used by M1 sheets (same faces as Style.ico).
    readonly property var ico: ({
            "play": "\uf04b", "pause": "\uf04c", "next": "\uf051", "prev": "\uf048",
            "vol": "\uf028", "mute": "\uf6a9", "mic": "\uf130", "power": "\uf011",
            "shot": "\uf030", "pick": "\uf1fb", "folder": "\uf07c", "term": "\uf120",
            "sync": "\uf2f1", "bolt": "\uf0e7", "moon": "\uf186", "display": "\uf390",
            "chip": "\uf2db", "robot": "\uf544", "search": "\uf002", "layers": "\uf5fd",
            "grid": "\uf00a", "home": "\uf015", "sliders": "\uf1de", "down": "\uf019",
            "broom": "\uf51a", "checks": "\uf560", "eye": "\uf06e", "wifi": "\uf1eb",
            "disk": "\uf0a0", "rocket": "\uf135", "menu": "\uf0c9", "bell": "\uf0f3",
            "gear": "\uf013", "copy": "\uf0c5", "plus": "\uf067", "stop": "\uf04d",
            "refresh": "\uf021", "key": "\uf084", "link": "\uf0c1", "pulse": "\uf21e",
            "lock": "\uf023", "clip": "\uf328", "rec": "\uf111", "region": "\uf125", "cam": "\uf03d"
        })

    // ---- helpers ---------------------------------------------------------
    function tone(col, alpha) {
        return Qt.rgba(col.r, col.g, col.b, alpha);
    }
    // color|string -> canvas css. Qt rgba() colors have no css form, so emit
    // the functional rgba() string canvas accepts.
    function css(col) {
        if (typeof col === "string")
            return col;
        function p(v) { return Math.round(v * 255); }
        return "rgba(" + p(col.r) + "," + p(col.g) + "," + p(col.b) + "," + col.a + ")";
    }
    // 0 deg = 12 o'clock, clockwise — same convention as src-M/m_lib.py pol().
    function pol(cx, cy, r, deg) {
        var a = (deg - 90) * Math.PI / 180;
        return { "x": cx + r * Math.cos(a), "y": cy + r * Math.sin(a) };
    }
    // crew state -> colour (active = live = acid; stalled lanes warn/alert).
    function stateColor(state) {
        switch (String(state)) {
        case "active":  return acid;
        case "warm":    return warn;
        case "idle":    return ice;
        case "stalled": return warn;
        case "alert":   return alert;
        default:        return faint;   // dormant / unknown
        }
    }
    // 2203800000 -> "2.20B", 484000000 -> "484M", 26800000 -> "26.8M"
    function fmtTok(n) {
        var v = Math.abs(Number(n) || 0);
        if (v >= 1e9) return (v / 1e9).toFixed(2) + "B";
        if (v >= 1e8) return Math.round(v / 1e6) + "M";
        if (v >= 1e6) return (v / 1e6).toFixed(1) + "M";
        if (v >= 1e3) return (v / 1e3).toFixed(1) + "K";
        return String(Math.round(v));
    }
    // compact HH:MM from epoch seconds ("" when absent)
    function fmtHm(epochS) {
        if (epochS === null || epochS === undefined || !isFinite(epochS))
            return unknownGlyph;
        var d = new Date(epochS * 1000);
        function p2(x) { return (x < 10 ? "0" : "") + x; }
        return p2(d.getHours()) + ":" + p2(d.getMinutes());
    }
}
