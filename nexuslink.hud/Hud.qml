import QtQuick
import Quickshell

// v4 entry point. The shell implementation lives in v4/HudV4.qml so the
// plugin keeps a stable entry name; Loader surfaces load errors instead of
// a hard failure, and ../collect.sh resolves from inside v4/.
ShellRoot {
    Loader {
        source: "v4/HudV4.qml"
        onStatusChanged: if (status === Loader.Error) console.warn("nexuslink.hud: v4 load failed")
    }
}
