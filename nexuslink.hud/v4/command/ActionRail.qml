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
        { "label": "SCREENSHOT", "kb": "PRINT", "gl": FuiTokens.ico.shot,
          "cmd": "omarchy-capture-screenshot",
          "argv": ["omarchy-capture-screenshot"] },
        { "label": "REGION CAPTURE", "kb": "SUPER+SHIFT+S", "gl": FuiTokens.ico.region,
          "cmd": "omarchy capture screenshot region",
          "argv": ["omarchy", "capture", "screenshot", "region"] },
        { "label": "OCR TEXT", "kb": "SUPER+CTRL+PRINT", "gl": "\uf031",
          "cmd": "omarchy-capture-text",
          "argv": ["omarchy-capture-text"] },
        { "label": "COLOR PICKER", "kb": "SUPER+PRINT", "gl": FuiTokens.ico.pick,
          "cmd": "hyprpicker -a",
          "argv": ["hyprpicker", "-a"] },
        { "label": "SCREEN RECORD", "kb": "ALT+PRINT", "gl": FuiTokens.ico.rec,
          "cmd": "omarchy-capture-screenrec.",
          "shell": "omarchy-capture-screenrecording --stop-recording || omarchy-menu toggle trigger.capture.screenrecord" },
        { "label": "CAPTURE MENU", "kb": "SUPER+CTRL+C", "gl": FuiTokens.ico.menu,
          "cmd": "omarchy-menu toggle capture",
          "argv": ["omarchy-menu", "toggle", "capture"] },
        { "label": "CLIPBOARD", "kb": "SUPER+CTRL+V", "gl": FuiTokens.ico.clip,
          "cmd": "omarchy.clipboard",
          "argv": ["omarchy-shell", "shell", "toggle", "omarchy.clipboard"] },
        { "label": "NEXUS_AI_CENTER", "kb": "unbound", "gl": FuiTokens.ico.folder,
          "cmd": "nautilus ~/NEXUS_AI_CENTER",
          "argv": ["uwsm-app", "--", "nautilus",
                   Quickshell.env("HOME") + "/NEXUS_AI_CENTER"] },
        { "label": "RELOAD HUD", "kb": "unbound", "gl": FuiTokens.ico.sync,
          "cmd": "nexuslink.hud reload",
          "argv": ["qs", "ipc", "-p", "/usr/share/omarchy/shell",
                   "call", "nexuslink.hud", "reload"] },
        { "label": "KEYBINDINGS", "kb": "SUPER+K", "gl": "\uf11c",
          "cmd": "omarchy-menu-keybindings",
          "argv": ["omarchy-menu-keybindings"] },
        { "label": "LOCK", "kb": "SUPER+CTRL+L", "gl": FuiTokens.ico.lock,
          "cmd": "omarchy-system-lock", "danger": false,
          "argv": ["omarchy-system-lock"] },
        { "label": "POWER MENU", "kb": "SUPER+ESCAPE", "gl": FuiTokens.ico.power,
          "cmd": "omarchy-menu toggle system", "danger": true,
          "argv": ["omarchy-menu", "toggle", "system"] }
    ]

    Column {
        x: 12; y: 40
        width: parent.width - 24
        spacing: 7
        Repeater {
            model: root.keys
            delegate: ActionKey {
                id: key
                required property int index
                required property var modelData
                width: parent.width
                height: Math.max(60, (root.height - 40 - 34 - 11 * 7) / 12)
                label: String(key.modelData.label)
                glyph: String(key.modelData.gl)
                keybind: String(key.modelData.kb)
                code: "QA-" + (key.index + 1 < 10 ? "0" : "") + (key.index + 1)
                command: String(key.modelData.cmd)
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

    Text {
        x: 16
        anchors { bottom: parent.bottom; bottomMargin: 12 }
        text: "src: omarchy keybindings"
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
}
