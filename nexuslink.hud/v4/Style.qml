pragma Singleton
import QtQuick

// v4 "chrome cybercore" structural tokens. Contract surface (BRIEF-V4-BUILD):
//   c      color map
//   f      font families + pixel sizes + tracking
//   r      radii
//   shadow(color, blur)  drop-shadow colour helper
//   easing  named Easing.* curves (re-exported from Theme)
QtObject {
    id: style

    // ---- colours ---------------------------------------------------------
    readonly property var c: ({
            // chassis / field
            "bg": Qt.rgba(11/255, 14/255, 17/255, 1),
            "graphite": Qt.rgba(12/255, 14/255, 17/255, 1),
            "graphite2": Qt.rgba(16/255, 19/255, 24/255, 1),
            "ink": Qt.rgba(20/255, 23/255, 28/255, 1),
            "ink2": Qt.rgba(24/255, 28/255, 34/255, 1),
            "recess": Qt.rgba(13/255, 15/255, 19/255, 1),
            "recessTop": Qt.rgba(10/255, 12/255, 15/255, 1),
            "edge": Qt.rgba(42/255, 49/255, 56/255, 1),
            // frosted glass
            "pane": Qt.rgba(1, 1, 1, 0.05),
            "glass": Qt.rgba(0.58, 0.67, 0.74, 0.07),
            "glassHi": Qt.rgba(0.75, 0.84, 0.92, 0.10),
            "glassDeep": Qt.rgba(0.47, 0.55, 0.63, 0.05),
            "glassLine": Qt.rgba(0.75, 0.86, 0.96, 0.16),
            // chrome bevel light/shade
            "chromeHi": Qt.rgba(0.92, 0.96, 0.99, 0.55),
            "chromeLo": Qt.rgba(0, 0, 0, 0.75),
            // text
            "txt": Qt.rgba(217/255, 226/255, 234/255, 1),
            "dim": Qt.rgba(0.85, 0.89, 0.92, 0.72),
            "mute": Qt.rgba(0.85, 0.89, 0.92, 0.55),
            "faint": Qt.rgba(0.85, 0.89, 0.92, 0.40),
            // accents
            "accent": Qt.rgba(200/255, 243/255, 29/255, 1),
            "accentDim": Qt.rgba(0.78, 0.95, 0.11, 0.55),
            "accent2": Qt.rgba(143/255, 216/255, 232/255, 1),
            "accent2Dim": Qt.rgba(0.56, 0.85, 0.91, 0.55),
            "warn": Qt.rgba(255/255, 179/255, 0, 1),
            "alert": Qt.rgba(255/255, 74/255, 61/255, 1),
            "unknown": Qt.rgba(90/255, 100/255, 108/255, 1),
            "magenta": Qt.rgba(255/255, 122/255, 217/255, 1),
            "mint": Qt.rgba(138/255, 255/255, 208/255, 1),
            // holographic edge-light strip (acid -> ice -> magenta -> mint)
            "holo": ["#c8f31d", "#8fd8e8", "#ff7ad9", "#8affd0"]
        })

    // ---- fonts -----------------------------------------------------------
    // Families come from Theme's FontLoaders so the fallback is reactive.
    readonly property var f: ({
            "display": Theme.displayFamily,
            "mono": Theme.monoFamily,
            "pxMicro": 8,
            "pxTag": 9,
            "pxLabel": 10,
            "pxInsight": 10.5,
            "pxTile": 11,
            "pxBody": 13,
            "pxClock": 22,
            "pxHero": 96,
            // tracking (font.letterSpacing, px) matching the mock's em tracks
            "lsEngraved": 3.4,
            "lsMast": 8.0,
            "lsTitle": 2.9,
            "lsTag": 1.0,
            "lsBody": 0.4
        })

    // ---- radii -----------------------------------------------------------
    readonly property var r: ({
            "pane": 10,
            "glass": 8,
            "emboss": 7,
            "chip": 5,
            "disc": 999
        })

    // ---- motion ----------------------------------------------------------
    readonly property var easing: Theme.easing
    readonly property var dur: ({
            "snap": 180,
            "settle": 320,
            "slow": 560
        })

    // ---- helpers ---------------------------------------------------------
    // Drop-shadow colour for a `blur` px radius: tint stays, alpha eases off
    // as the blur spreads. Feed MultiEffect.shadowColor or an offset plate.
    function shadow(col, blur) {
        var a = 10 / Math.max(4, blur);
        a = Math.max(0.15, Math.min(0.75, a));
        return Qt.rgba(col.r * 0.35, col.g * 0.35, col.b * 0.35, a);
    }

    // The "unknown" sentinel for absent collector keys (no fabricated data).
    readonly property string unknownGlyph: "—"

    function tone(col, alpha) {
        return Qt.rgba(col.r, col.g, col.b, alpha);
    }
}
