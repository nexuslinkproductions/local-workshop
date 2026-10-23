import QtQuick
import Quickshell
import Quickshell.Io

// Mac link feed: one JSON line from maclink.sh every 12 s while active.
// Source: tailscale ping (2 s timeout) + ssh pmset/sysctl (cached 10 s in the script).
Item {
    id: root
    property bool active: false
    readonly property var link: _link
    property var _link: ({})
    visible: false
    width: 0
    height: 0

    Timer {
        interval: 12000
        repeat: true
        triggeredOnStart: true
        running: root.active
        onTriggered: if (!proc.running) proc.running = true   // skip overlapping runs
    }

    Process {
        id: proc
        command: ["bash", Qt.resolvedUrl("maclink.sh").toString().replace(/^file:\/\//, "")]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var raw = String(text).trim()
                if (raw.length === 0)
                    return
                try {
                    const o = JSON.parse(raw)
                    if (o && typeof o === "object")
                        root._link = o
                } catch (e) { /* keep the last good sample */ }
            }
        }
    }
}
