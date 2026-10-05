pragma Singleton
import QtQuick

// v4 "chrome cybercore" theme: fonts, palette, easing.
// Style.qml is the structural contract surface (c / f / r / shadow / easing);
// this singleton owns the FontLoaders and the easing map that Style re-exports.
QtObject {
    id: theme

    // ---- fonts ----------------------------------------------------------
    // OFL files installed system-wide (fc-list resolves the family names too;
    // the explicit files pin the exact faces).
    property FontLoader _display: FontLoader {
        id: displayLoader
        source: "file:///home/nexuslink/.local/share/fonts/nexushud/Michroma-Regular.ttf"
    }
    property FontLoader _mono: FontLoader {
        id: monoLoader
        source: "file:///home/nexuslink/.local/share/fonts/nexushud/KodeMono-VF.ttf"
    }

    readonly property bool fontsReady: displayLoader.status === FontLoader.Ready && monoLoader.status === FontLoader.Ready
    // Fallback chain: loaded family -> generic monospace/sans.
    readonly property string displayFamily: displayLoader.status === FontLoader.Ready && displayLoader.name !== "" ? displayLoader.name : "sans-serif"
    readonly property string monoFamily: monoLoader.status === FontLoader.Ready && monoLoader.name !== "" ? monoLoader.name : "monospace"

    function display() {
        return displayFamily;
    }
    function mono() {
        return monoFamily;
    }
    // QML font.family has no comma-fallback; this exists for Canvas/CSS-style
    // consumers that do support a chain (e.g. ctx.font).
    function monoChain() {
        return monoLoader.status === FontLoader.Ready ? monoFamily + ", monospace" : "monospace";
    }

    // ---- palette ---------------------------------------------------------
    // Authoritative values live in Style.c; this mirror lets theme-level
    // consumers read hexes without pulling the whole style map.
    readonly property var p: ({
            "bg": "#0b0e11",
            "graphite": "#0c0e11",
            "graphite2": "#101318",
            "ink": "#14171c",
            "ink2": "#181c22",
            "edge": "#2a3138",
            "txt": "#d9e2ea",
            "accent": "#c8f31d",
            "accent2": "#8fd8e8",
            "warn": "#ffb300",
            "alert": "#ff4a3d",
            "unknown": "#5a646c"
        })

    // ---- easing ----------------------------------------------------------
    // Easing.* ints; hand to NumberAnimation/Behavior via easing.type.
    readonly property var easing: ({
            "standard": Easing.OutCubic,
            "snap": Easing.OutExpo,
            "settle": Easing.InOutCubic,
            "overshoot": Easing.OutBack,
            "linear": Easing.Linear
        })
}
