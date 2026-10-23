import QtQuick
import Quickshell
import Quickshell.Io

// Disk feed: df once on activation, then every 60 s while active.
// Dedupe by device (btrfs subvolumes collapse to ROOT), skip /boot.
Item {
    id: root
    property bool active: false
    readonly property var disks: _disks
    property var _disks: []
    visible: false
    width: 0
    height: 0

    function parse(raw) {
        var out = []
        var seen = ({})
        var lines = String(raw).split("\n")
        for (var i = 1; i < lines.length; i++) {
            var line = lines[i]
            if (line.trim().length === 0)
                continue
            var f = line.trim().split(/\s+/)
            if (f.length < 7)
                continue
            var dev = f[0]
            var mount = f.slice(6).join(" ")
            if (dev === "Filesystem")
                continue
            if (mount === "/boot" || mount.indexOf("/boot/") === 0)
                continue
            if (seen[dev])
                continue
            seen[dev] = true
            var pct = parseFloat(String(f[5]).replace("%", ""))
            var size = Number(f[2])
            var used = Number(f[3])
            var free = Number(f[4])
            if (!isFinite(pct) || !isFinite(size))
                continue
            var base = mount === "/" ? "" : mount.replace(/\/+$/, "").split("/").pop()
            out.push({
                "label": mount === "/" ? "ROOT" : String(base).toUpperCase(),
                "fs": f[1],
                "mount": mount,
                "usedPct": Math.max(0, Math.min(100, pct)),
                "sizeBytes": size,
                "usedBytes": used,
                "freeBytes": free
            })
        }
        return out
    }

    Timer {
        interval: 60000
        repeat: true
        triggeredOnStart: true
        running: root.active
        onTriggered: if (!proc.running) proc.running = true
    }

    Process {
        id: proc
        command: ["df", "-PT", "-B1", "-x", "tmpfs", "-x", "devtmpfs", "-x", "efivarfs", "-x", "squashfs", "-x", "overlay"]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._disks = root.parse(text)
        }
    }
}
