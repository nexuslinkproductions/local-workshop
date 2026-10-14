pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import ".."

// ActionRail.qml — M1 QA quick-action rail: 12 ActionKey cells wired to the
// real omarchy/hypr commands (same argv exec wrapper UtilityDock used).
Item {
    id: root

    // argv through the login-shell `exec "$@"` wrapper (UtilityDock contract)
    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "qa"].concat(argv));
    }
    // one fixed compound command (record toggle) — static string, no input
    function execShell(line) {
        Quickshell.execDetached(["bash", "-lc", line]);
    }

    readonly property var keys: [
        { "label": "Screenshot", "kb": "PRINT", "gl": FuiTokens.ico.shot,
          "cmd": "omarchy-capture-screenshot",
          "argv": ["omarchy-capture-screenshot"] },
        { "label": "Region capture", "kb": "SUPER+SHIFT+S", "gl": FuiTokens.ico.region,
          "cmd": "omarchy capture screenshot region",
          "argv": ["omarchy", "capture", "screenshot", "region"] },
        { "label": "OCR text", "kb": "SUPER+CTRL+PRINT", "gl": "\uf031",
          "cmd": "omarchy-capture-text",
          "argv": ["omarchy-capture-text"] },
        { "label": "Color picker", "kb": "SUPER+PRINT", "gl": FuiTokens.ico.pick,
          "cmd": "hyprpicker -a",
          "argv": ["hyprpicker", "-a"] },
        { "label": "Record screen", "kb": "ALT+PRINT", "gl": FuiTokens.ico.rec,
          "cmd": "omarchy-capture-screenrec.",
          "shell": "omarchy-capture-screenrecording --stop-recording || omarchy-menu toggle trigger.capture.screenrecord" },
        { "label": "Capture menu", "kb": "SUPER+CTRL+C", "gl": FuiTokens.ico.menu,
          "cmd": "omarchy-menu toggle capture",
          "argv": ["omarchy-menu", "toggle", "capture"] },
        { "label": "Clipboard", "kb": "SUPER+CTRL+V", "gl": FuiTokens.ico.clip,
          "cmd": "omarchy.clipboard",
          "argv": ["omarchy-shell", "shell", "toggle", "omarchy.clipboard"] },
        { "label": "AI center", "kb": "unbound", "gl": FuiTokens.ico.folder,
          "cmd": "~/NEXUS_AI_CENTER",
          "argv": ["uwsm-app", "--", "nautilus",
                   Quickshell.env("HOME") + "/NEXUS_AI_CENTER"] },
        { "label": "Reload HUD", "kb": "unbound", "gl": FuiTokens.ico.sync,
          "cmd": "nexuslink.hud reload",
          "argv": ["qs", "ipc", "-p", "/usr/share/omarchy/shell",
                   "call", "nexuslink.hud", "reload"] },
        { "label": "Keybindings", "kb": "SUPER+K", "gl": "\uf11c",
          "cmd": "omarchy-menu-keybindings",
          "argv": ["omarchy-menu-keybindings"] },
        { "label": "Lock", "kb": "SUPER+CTRL+L", "gl": FuiTokens.ico.lock,
          "cmd": "omarchy-system-lock", "danger": false,
          "argv": ["omarchy-system-lock"] },
        { "label": "Power menu", "kb": "SUPER+ESCAPE", "gl": FuiTokens.ico.power,
          "cmd": "omarchy-menu toggle system", "danger": true,
          "argv": ["omarchy-menu", "toggle", "system"] }
    ]

    // 12 rows share the panel height: 12px inset + 6px gaps. Target minimum
    // is 44px but the floor is never forced — a shorter panel just gets
    // shorter keys, every action stays reachable.
    readonly property real rowH: Math.max(1, (root.height - 24 - 11 * 6) / 12)

    Column {
        x: 12; y: 12
        width: parent.width - 24
        spacing: 6
        Repeater {
            model: root.keys
            delegate: ActionKey {
                id: key
                required property int index
                required property var modelData
                width: parent.width
                height: root.rowH
                label: String(key.modelData.label)
                glyph: String(key.modelData.gl)
                keybind: String(key.modelData.kb)
                danger: key.modelData.danger === true
                onActivated: {
                    if (key.modelData.shell)
                        root.execShell(key.modelData.shell);
                    else
                        root.execArgv(key.modelData.argv);
                }
            }
        }
    }
}
