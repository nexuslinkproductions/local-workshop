// NAVIGATOR — lane N (BRIEF-V4-BUILD).
// Modal overlay browser: FILES / PROCESSES / DEVICES / AGENTS / REPOS / USAGE
// on F1..F6. One PanelWindow on WlrLayer.Overlay (ExclusionMode.Ignore,
// namespace "nexuslink-nav") plus transparent dismiss twins on every other
// output — Exclusive keyboard focus routes ALL pointer input to this surface
// on Hyprland, so clicks on other monitors would otherwise be unreachable.
// The window only maps while open, so focus release is just `navOpen=false`.
//
// Wiring contract for HudV4 (lane H): instantiate ONCE at the plugin root
// (never inside a per-screen Variants delegate — duplicate IpcHandler targets
// collide) and bind `stats` to the parsed collector frame and `navScreen` to
// the output the summon came from:
//   Navigator { stats: root.stats; navScreen: tileScreen }
//
// IPC: `omarchy-shell nexuslink.nav <method>` — open(section[, path]),
// back(), close(), state() -> JSON.
//
// All external paths reach processes as argv vectors or bash positional
// parameters ($1, $2 …) — never concatenated into a shell string.

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Qt.labs.folderlistmodel

Scope {
    id: root

    // ----- injected by HudV4 ------------------------------------------------
    property var stats: ({})        // parsed hud-collect frame (same map as v3)
    property var navScreen: null    // Quickshell screen to open on; null = default

    // ----- nav state --------------------------------------------------------
    property bool navOpen: false
    property int section: 0         // 0 files 1 proc 2 devices 3 agents 4 repos 5 usage
    readonly property var sectionIds: ["files", "proc", "devices", "agents", "repos", "usage"]
    readonly property var sectionNames: ["FILES", "PROCESSES", "DEVICES", "AGENTS", "REPOS", "USAGE"]
    property string filesDir: Quickshell.env("HOME") || "/"
    property string query: ""
    property bool searching: false
    property int sel: 0
    property var navStack: []       // [{section, path, sel, query}]
    property int rowsRev: 0         // bumps when `rows` is rebuilt
    property var rows: []

    // mounts sidebar (files explorer roots): [{label, path, device, fstype, icon}]
    property var mountRows: []
    property string mountActive: "/"          // longest-prefix mount of filesDir
    property bool showHiddenFiles: false      // Ctrl+H — explorer convention
    property var execSet: ({})                // names in filesDir with +x (probe)
    property int execGen: 0                   // bumped per dir; stale probes dropped

    // readability probe (dirGuard): FolderListModel reports an unreadable
    // dir (dmask/fmask 0077 mounts, /root …) as Ready+count=0 — identical to
    // an empty folder, so without a probe the explorer strands the operator
    // on a bare "no matches" (operator-verified on /boot).
    property bool dirReadable: true           // filesDir itself is r+x
    property var noReadSet: ({})              // names of unreadable child dirs
    property int dirProbeGen: 0               // bumped per dir; stale replies dropped
    property bool pendingLoad: true           // rows describe filesDir only when false
                                            // (FolderListModel swaps entries async:
                                            // folder+status can look Ready while it
                                            // still holds the previous dir's rows)
    readonly property string repoRoot: Quickshell.env("HOME") + "/NEXUS_AI_CENTER"

    // JUMPS rail: existence-probed pins + session visited list. navStack is
    // a pure back-stack (pops discard) — it cannot model forward history,
    // so the honest forward affordance is a visited quick list.
    property var jumpPins: []                 // [{label, path}] — only dirs that exist
    property var recentDirs: []               // newest-first paths, deduped, cap 8
    property var jumpRows: []                 // pins + recent, rendered by the rail

    // ----- Style contract ---------------------------------------------------
    // Style singleton is lane S; guarded so this file lints and runs before
    // merge. Fallbacks are the contract values (BRIEF §Contracts).
    readonly property var _S: (typeof Style !== "undefined") ? Style : null
    function _sc(key, fallback) { return (root._S && root._S.c && root._S.c[key] !== undefined) ? root._S.c[key] : fallback }

    QtObject {
        id: th
        readonly property color bg:      root._sc("bg",      "#0b0e11")
        readonly property color chassis: root._sc("ink",     "#161a20")
        readonly property color recess:  root._sc("recess",  "#0d0f13")
        readonly property color edge:    root._sc("edge",    "#2a3138")
        readonly property color accent:  root._sc("accent",  "#c8f31d")
        readonly property color accentDim: root._sc("accentDim", Qt.rgba(200 / 255, 243 / 255, 29 / 255, 0.55))
        readonly property color ice:     root._sc("accent2", "#8fd8e8")
        readonly property color accent2Dim: root._sc("accent2Dim", Qt.rgba(0.56, 0.85, 0.91, 0.55))
        readonly property color warn:    root._sc("warn",    "#ffb300")
        readonly property color alert:   root._sc("alert",   "#ff4a3d")
        readonly property color unknown: root._sc("unknown", "#5a646c")
        readonly property color glassLine: root._sc("glassLine", Qt.rgba(190 / 255, 220 / 255, 245 / 255, 0.16))
        readonly property color txt:   root._sc("txt",   "#d9e2ea")
        readonly property color t70:   root._sc("dim",   Qt.rgba(217 / 255, 226 / 255, 234 / 255, 0.72))
        readonly property color t55:   root._sc("mute",  Qt.rgba(217 / 255, 226 / 255, 234 / 255, 0.55))
        readonly property color t40:   root._sc("faint", Qt.rgba(217 / 255, 226 / 255, 234 / 255, 0.40))
        readonly property string fDisp: (root._S && root._S.f && root._S.f.display) ? String(root._S.f.display) : "Michroma"
        readonly property string fMono: (root._S && root._S.f && root._S.f.mono) ? String(root._S.f.mono) : "Kode Mono"
        function _sr(k, f) { return (root._S && root._S.r && root._S.r[k] !== undefined) ? root._S.r[k] : f }
        readonly property int rPane: _sr("pane", 10)
        readonly property int rCtl: _sr("emboss", 7)
        readonly property int rGlass: _sr("glass", 8)
        readonly property int rRow: 6      // list rows — half a step under rCtl
        readonly property int rKey: 4      // keycaps + micro wells
        // 4px spacing ramp. Every margin in the surface is one of these, so
        // the three columns share a rhythm instead of each inventing one.
        readonly property int g1: 4
        readonly property int g2: 8
        readonly property int g3: 12
        readonly property int g4: 16
        readonly property int g5: 20
        readonly property int cntW: 24   // rail header count slot
        // type ramp (px) — one size per role, no ad-hoc sizes in the surface
        readonly property int pxWord: 13   // wordmark
        readonly property int pxTitle: 10  // rail/pane section titles
        readonly property int pxColHead: 8 // column headers
        readonly property int pxKey: 8     // keycaps
        readonly property int pxCrumb: 11  // breadcrumb
        readonly property int pxRow: 12    // row primary
        readonly property int pxCell: 10   // row tail cells
        readonly property int pxMeta: 9    // tertiary / context
        readonly property int pxMicro: 8   // micro stat
        // engraved separator = a lit rule over a shade; a lone 1px black line
        // reads as an aliased crack on this chassis
        readonly property color ruleLit: Qt.rgba(235 / 255, 245 / 255, 252 / 255, 0.09)
        readonly property color ruleDark: Qt.rgba(0, 0, 0, 0.62)
        // hover wash: the met.wash step from the Workbench ledger rows
        readonly property color wash: Qt.rgba(0.56, 0.85, 0.91, 0.07)
        // recessed well chrome (Tag.qml / EmbossedTile.qml idiom)
        readonly property color wellTop: root._sc("recessTop", "#0a0c0f")
        readonly property color wellBot: root._sc("recess", "#0d0f13")
        // hex strings for RichText spans (alpha-hex is unreliable in QML text)
        readonly property string accentCss: root.cssHex(accent)
        readonly property string iceCss: root.cssHex(ice)
        readonly property string t55Css: "#97a8b5"
        readonly property string t40Css: "#616d77"
        readonly property string txtCss: "#d9e2ea"
        readonly property string t70Css: "#9aa7b0"
    }

    function ung() { return (root._S && root._S.unknownGlyph) ? root._S.unknownGlyph : "—" }

    function cssHex(c) {
        function h(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s }
        return "#" + h(c.r) + h(c.g) + h(c.b)
    }

    FontLoader { source: "file://" + Quickshell.env("HOME") + "/.local/share/fonts/nexushud/Michroma-Regular.ttf" }
    FontLoader { source: "file://" + Quickshell.env("HOME") + "/.local/share/fonts/nexushud/KodeMono-VF.ttf" }

    // Topology singleton (lane T) — guarded for pre-merge lint/run.
    readonly property var _T: (typeof Topology !== "undefined") ? Topology : null

    // ----- exec helpers (argv only; $n positional params, never concat) -----
    // Same contract as omarchy shell Util.execArgv: a constant `exec "$@"`
    // script, so argv lands in positional parameters without re-tokenizing.
    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "nav"].concat(argv))
    }
    // Fixed script + positional args for pipelines (e.g. printf | wl-copy).
    function execShArgv(script, args) {
        Quickshell.execDetached(["bash", "-lc", script, "nav"].concat(args || []))
    }

    function num(v) { var n = Number(v); return isFinite(n) ? n : 0 }
    function has(key) { return stats[key] !== undefined && stats[key] !== "" }
    function stat(key, fallback) { return has(key) ? String(stats[key]) : (fallback === undefined ? "—" : fallback) }

    function fmtTok(n) {
        var v = Number(n)
        if (n === null || n === undefined || !isFinite(v)) return "—"
        if (v >= 1e9) return (v / 1e9).toFixed(2) + "B"
        if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
        if (v >= 1e3) return (v / 1e3).toFixed(1) + "k"
        return String(Math.round(v))
    }
    function fmtCost(c) {
        if (c === null || c === undefined) return ""
        var v = Number(c)
        if (!isFinite(v)) return ""
        if (v >= 10) return "$" + v.toFixed(1)
        if (v >= 1) return "$" + v.toFixed(2)
        if (v > 0) return "$" + v.toFixed(3)
        return "$0"
    }
    function tokCell(b) {
        if (b === null || b === undefined || typeof b !== "object") return "—"
        var i = b["in"], o = b["out"]
        var ii = (i === null || i === undefined) ? NaN : Number(i)
        var oo = (o === null || o === undefined) ? NaN : Number(o)
        var s
        if (isFinite(ii) || isFinite(oo)) s = fmtTok(ii) + "↓ " + fmtTok(oo) + "↑"
        else if (b.total !== undefined && b.total !== null) s = "Σ" + fmtTok(b.total)
        else s = "—"
        var c = fmtCost(b.cost)
        if (c !== "") s += " · " + c
        return s
    }
    function fmtBytes(b) {
        var v = Number(b)
        if (!isFinite(v)) return "—"
        if (v >= 1073741824) return (v / 1073741824).toFixed(1) + "G"
        if (v >= 1048576) return (v / 1048576).toFixed(1) + "M"
        if (v >= 1024) return (v / 1024).toFixed(1) + "K"
        return v + "B"
    }
    function fileUrl(path) {
        if (!path) return ""
        return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
    }
    function escHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }
    function parentDir(path) {
        var p = String(path).replace(/\/+$/, "")
        var i = p.lastIndexOf("/")
        if (i <= 0) return "/"
        return p.substring(0, i)
    }
    function baseName(path) {
        var p = String(path).replace(/\/+$/, "")
        var i = p.lastIndexOf("/")
        return i < 0 ? p : p.substring(i + 1)
    }

    // ======================================================================
    // Section row builders. Each returns row dicts:
    //   { icon, name, meta, data, kind } — `data` carries the action payload.
    // ======================================================================

    // ---------- FILES ----------
    FolderListModel {
        id: filesModel
        folder: root.fileUrl(root.filesDir)
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: root.showHiddenFiles
        sortField: FolderListModel.Name
        onCountChanged: {
            if (root.folderMatchesDir()) root.pendingLoad = false
            filesRebuildTimer.restart()
        }
        onStatusChanged: {
            // Ready+match = entries for filesDir are final (sort finished);
            // this also settles 0-entry dirs, which emit no nonzero count.
            // Null (vanished/unloadable folder) must also settle, or the view
            // would sit on "loading…" forever.
            if ((status === FolderListModel.Ready || status === FolderListModel.Null)
                    && root.folderMatchesDir()) {
                root.pendingLoad = false
                filesRebuildTimer.restart()
            }
        }
    }
    Timer {
        id: filesRebuildTimer
        interval: 60
        onTriggered: if (root.navOpen && root.section === 0) root.rebuildRows()
    }

    // Per-dir +x probe: one bounded `find`, names land in execSet. Re-run on
    // every dir change; execRunGen guards against late replies from a
    // directory we already left.
    Process {
        id: execProbe
        running: false
        command: ["bash", "-lc",
            'find "$1" -maxdepth 1 -type f -executable -printf "%f\\n" 2>/dev/null | head -n 2000',
            "nav", root.filesDir]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (root.execProbeRunGen !== root.execGen) return
                var s = {}
                var lines = String(text).split("\n")
                for (var i = 0; i < lines.length; i++)
                    if (lines[i] !== "") s[lines[i]] = true
                root.execSet = s
                if (root.navOpen && root.section === 0) root.rebuildRows()
            }
        }
    }
    property int execProbeRunGen: -1
    // running=false→true in one tick is a net no-op in Quickshell's Process:
    // the in-flight run keeps going and its stale reply then passes the gen
    // check (runGen was already bumped). The kick timer lets the kill land
    // before relaunch — verified live on consecutive dir changes.
    Timer {
        id: execProbeKick
        interval: 30
        onTriggered: {
            if (!root.navOpen) return
            root.execProbeRunGen = root.execGen
            execProbe.running = true
        }
    }
    function restartExecProbe() {
        execGen++
        execProbe.running = false
        if (navOpen) execProbeKick.restart()   // execSet only feeds files rows
    }

    // Per-dir readability probe — one bounded `find`; SELF_OK marks filesDir
    // listable (test -r -x, same check readdir needs). Unreadable child dirs
    // land in noReadSet so Enter refuses to strand the operator inside them.
    // dirProbeRunGen guards against late replies from a directory we left.
    Process {
        id: dirProbe
        running: false
        command: ["bash", "-lc",
            'test -r "$1" && test -x "$1" && echo "SELF_OK"; find "$1" -maxdepth 1 -type d ! -readable -printf "%f\\n" 2>/dev/null | head -n 500',
            "nav", root.filesDir]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (root.dirProbeRunGen !== root.dirProbeGen) return
                var ok = false
                var nr = {}
                var lines = String(text).split("\n")
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i] === "") continue
                    if (lines[i] === "SELF_OK") ok = true
                    else nr[lines[i]] = true
                }
                root.dirReadable = ok
                root.noReadSet = nr
                if (root.navOpen && root.section === 0) root.rebuildRows()
            }
        }
    }
    property int dirProbeRunGen: -1
    Timer {
        id: dirProbeKick
        interval: 30
        onTriggered: {
            if (!root.navOpen) return
            root.dirProbeRunGen = root.dirProbeGen
            dirProbe.running = true
        }
    }
    function restartDirProbe() {
        dirProbeGen++
        dirProbe.running = false
        if (navOpen) dirProbeKick.restart()   // probe only feeds files rows
    }

    onFilesDirChanged: {
        pendingLoad = true
        refreshMountActive()
        restartExecProbe()
        restartDirProbe()
        pushRecent(filesDir)
    }

    // visited list — real dirs only, deduped, newest-first (JUMPS rail)
    function pushRecent(path) {
        var p = String(path || "")
        if (p === "") return
        var r = [p]
        for (var i = 0; i < recentDirs.length && r.length < 8; i++)
            if (recentDirs[i] !== p) r.push(recentDirs[i])
        recentDirs = r
        refreshJumpRows()
    }
    // JUMPS rail = existence-probed pins + visited dirs not already pinned.
    function refreshJumpRows() {
        var out = []
        var seen = {}
        for (var i = 0; i < jumpPins.length; i++) {
            seen[jumpPins[i].path] = true
            out.push({ label: jumpPins[i].label, path: jumpPins[i].path,
                       icon: jumpPins[i].icon, recent: false })
        }
        for (var j = 0; j < recentDirs.length && out.length < 12; j++) {
            var p = recentDirs[j]
            if (seen[p] || p === filesDir) continue
            seen[p] = true
            var nm = baseName(p)
            out.push({ label: nm !== "" ? nm : p, path: p, icon: "◈", recent: true })
        }
        jumpRows = out
    }
    // Pin probe — pins the brief asks for, filtered by `[ -d ]` so a missing
    // ~/Desktop can never render a dead jump (argv-positional, one pass).
    Process {
        id: jumpProbe
        running: false
        command: ["bash", "-lc",
            'for d in "$@"; do [ -d "$d" ] && printf "%s\\n" "$d"; done',
            "nav", Quickshell.env("HOME") || "/",
            (Quickshell.env("HOME") || "/") + "/Desktop",
            (Quickshell.env("HOME") || "/") + "/Downloads",
            (Quickshell.env("HOME") || "/") + "/.config",
            root.repoRoot]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var home = Quickshell.env("HOME") || "/"
                var out = []
                var lines = String(text).split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i]
                    if (p === "") continue
                    var label = root.baseName(p), icon = "▸"
                    if (p === home) { label = "HOME"; icon = "⌂" }
                    else if (p === root.repoRoot) { label = "AI CENTER"; icon = "⌂" }
                    out.push({ label: label, path: p, icon: icon })
                }
                root.jumpPins = out
                root.refreshJumpRows()
            }
        }
    }

    // ----- mounts sidebar: real storage roots from /proc/mounts ----------
    // FileView can't inotify procfs, so reload on open + slow pulse while the
    // files section is visible. Parse keeps real devices only.
    FileView {
        id: mountsFile
        path: "/proc/mounts"
        watchChanges: false
        printErrors: false
        onLoaded: root.parseMounts(String(text()))
        onLoadFailed: { /* keep last good list */ }
    }
    Timer {
        id: mountsTimer
        interval: 4000
        repeat: true
        running: root.navOpen && root.section === 0
        onTriggered: mountsFile.reload()
    }

    // mountpoint/device escaping in /proc/mounts is octal (\040 = space …)
    function unescapeMount(s) {
        return String(s).replace(/\\([0-7]{3})/g, function (m, o) {
            return String.fromCharCode(parseInt(o, 8))
        })
    }

    function parseMounts(text) {
        // pseudo filesystems that a file explorer never shows
        var pseudoFs = " proc sysfs devpts devtmpfs tmpfs cgroup cgroup2 securityfs debugfs tracefs pstore bpf configfs fusectl mqueue hugetlbfs efivarfs binfmt_misc autofs nsfs ramfs overlay squashfs rpc_pipefs nfsd selinuxfs smackfs fuse.portal fuse.gvfsd-fuse fuse.gvfs-fuse-daemon gvfs gvfs-fuse-daemon aafs fsverityfs "
        // network/fuse mounts count as storage in a real explorer
        var netFs = " nfs nfs4 cifs smb3 smb2 sshfs fuse.sshfs 9p virtiofs fuse.ceph ceph "
        // mountpoints that are OS plumbing even when a real device backs them
        var skipMp = "/proc /sys /dev /run /snap /var /tmp /etc /usr /boot/efi/EFI"
        var home = Quickshell.env("HOME") || "/home"
        var rows = []
        var seen = {}
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split(" ")
            if (f.length < 3) continue
            var dev = unescapeMount(f[0])
            var mp = unescapeMount(f[1])
            var fs = String(f[2]).toLowerCase()
            if (seen[mp]) continue
            if (pseudoFs.indexOf(" " + fs + " ") >= 0) continue
            // explorer roots: system anchors + removable/pluggable prefixes
            var wanted = (mp === "/" || mp === "/home" || mp === "/boot"
                          || mp.indexOf("/home/") === 0 || mp.indexOf("/boot/") === 0
                          || mp.indexOf("/mnt/") === 0 || mp.indexOf("/media/") === 0
                          || mp.indexOf("/run/media/") === 0)
            if (!wanted && (dev.indexOf("/dev/") === 0
                            || netFs.indexOf(" " + fs + " ") >= 0)) {
                // real device/net mount elsewhere — include unless plumbing
                wanted = true
                var sk = skipMp.split(" ")
                for (var s = 0; s < sk.length; s++) {
                    if (mp === sk[s] || mp.indexOf(sk[s] + "/") === 0) { wanted = false; break }
                }
            }
            if (!wanted) continue
            seen[mp] = true
            rows.push({ label: "", path: mp, device: dev, fstype: fs, icon: "▮" })
        }
        rows.sort(function (a, b) { return a.path < b.path ? -1 : (a.path > b.path ? 1 : 0) })

        function bestMountFor(target) {
            var best = null
            for (var i = 0; i < rows.length; i++) {
                var mp = rows[i].path
                if (target === mp || (mp !== "/" && target.indexOf(mp + "/") === 0) || mp === "/") {
                    if (!best || mp.length > best.path.length) best = rows[i]
                }
            }
            return best
        }

        var out = []
        if (home !== "/") {
            var hm = bestMountFor(home)
            out.push({ label: "HOME", path: home,
                       device: hm ? hm.device : "", fstype: hm ? hm.fstype : "", icon: "⌂" })
        }
        var rm = bestMountFor("/")
        out.push({ label: "ROOT", path: "/",
                   device: rm ? rm.device : "", fstype: rm ? rm.fstype : "", icon: "/" })
        for (var j = 0; j < rows.length; j++) {
            var m = rows[j]
            if (m.path === "/" || m.path === home) continue   // already pinned
            m.label = baseName(m.path)
            if (m.label === "") m.label = m.path
            out.push(m)
        }
        mountRows = out
        refreshMountActive()
    }

    function refreshMountActive() {
        var best = "/", bl = 0
        for (var i = 0; i < mountRows.length; i++) {
            var mp = mountRows[i].path
            if (filesDir === mp || filesDir.indexOf(mp === "/" ? "/" : mp + "/") === 0) {
                if (mp.length > bl) { best = mp; bl = mp.length }
            }
        }
        mountActive = best
    }

    // explorer roots call this — pushes the current spot for Backspace/back()
    function filesGoTo(path) {
        var dest = normalizeDir(path)
        if (dest === filesDir) { return }
        if (section !== 0) {
            navStack.push({ section: section, path: filesDir, sel: sel, query: query })
            section = 0
        } else {
            navStack.push({ section: 0, path: filesDir, sel: sel, query: query })
        }
        filesDir = dest
        sel = 0
        query = ""
        searching = false
        rebuildRows()
    }

    // "~/x", relative names and trailing slashes — IPC-safe path hygiene.
    // A bare word (no "/") also resolves against mount labels, so agents can
    // `open files DATA` / `open files home` without knowing the mountpoint.
    function resolveNavPath(p) {
        var s = String(p === undefined || p === null ? "" : p).trim()
        if (s !== "" && s.indexOf("/") < 0 && s.charAt(0) !== "~") {
            for (var i = 0; i < mountRows.length; i++)
                if (String(mountRows[i].label).toLowerCase() === s.toLowerCase())
                    return mountRows[i].path
        }
        return normalizeDir(s)
    }
    function normalizeDir(p) {
        var s = String(p === undefined || p === null ? "" : p).trim()
        if (s === "") return filesDir
        var home = Quickshell.env("HOME") || "/"
        if (s === "~") s = home
        else if (s.indexOf("~/") === 0) s = home + s.substring(1)
        if (s.charAt(0) !== "/") s = filesDir.replace(/\/+$/, "") + "/" + s
        if (s.length > 1) s = s.replace(/\/+$/, "")
        return s
    }

    // ----- explorer typing: suffix class -> glyph + detail bucket --------
    readonly property string extImage: " png jpg jpeg gif webp bmp svg ico avif heic tif tiff ppm pgm xpm kra xcf "
    readonly property string extVideo: " mp4 mkv avi mov webm flv wmv m4v mpg mpeg mts m2ts 3gp "
    readonly property string extAudio: " mp3 flac wav ogg oga opus m4a aac wma mid midi aif aiff "
    readonly property string extArchive: " zip tar gz tgz bz2 tbz2 xz txz zst 7z rar jar war iso dmg cab cpio "
    readonly property string extDoc: " pdf txt md markdown rst odt doc docx xls xlsx ods ppt pptx odp csv tsv epub log tex "
    readonly property string extCode: " c cc cpp cxx h hpp hh rs go py pyc js jsx ts tsx mjs cjs coffee java kt kts swift rb php pl pm sh bash zsh fish lua hs ml scala clj cs fs vb r jl d nim zig vala css scss sass less html htm xml xsl json jsonc yaml yml toml ini cfg conf qml qrc sql vue svelte asm s diff patch lock desktop service timer mount cmake mk ninja ui glsl frag vert "
    readonly property string extScript: " sh bash zsh fish py pl rb lua "

    function fileTypeOf(suffix, exec) {
        var s = " " + String(suffix || "").toLowerCase() + " "
        if (extImage.indexOf(s) >= 0) return "image"
        if (extVideo.indexOf(s) >= 0) return "video"
        if (extAudio.indexOf(s) >= 0) return "audio"
        if (extArchive.indexOf(s) >= 0) return "archive"
        if (extDoc.indexOf(s) >= 0) return "doc"
        if (extCode.indexOf(s) >= 0) return "code"
        if (exec) return "exec"
        return "file"
    }
    function typeIcon(ft) {
        switch (ft) {
        case "dir": return "▣"
        case "code": return "</>"
        case "image": return "▩"
        case "video": return "▶"
        case "audio": return "♪"
        case "archive": return "▧"
        case "doc": return "≡"
        case "exec": return "◆"
        default: return "▤"
        }
    }
    function fmtMtime(d) {
        if (d === undefined || d === null) return "—"
        var s = Qt.formatDateTime(d, "yyyy-MM-dd HH:mm")
        return (s === "" || s.indexOf("NaN") >= 0) ? "—" : s
    }
    function isRunnableData(d) {
        return !d.isDir && (d.exec === true || d.suffix === "desktop")
    }

    // True while the model still lists a directory other than filesDir —
    // FolderListModel swaps contents asynchronously, so right after a
    // descend its count/rows are the OLD dir's (verified: descend / → boot
    // kept count=19 of / until the load finished). Building rows from that
    // frame renders the previous directory under the new path.
    function folderMatchesDir() {
        if (filesDir === "") return true
        return decodeURIComponent(String(filesModel.folder)) === "file://" + String(filesDir)
    }

    function buildFilesRows() {
        var out = []
        // stale transition frame or mid-load → report empty (emptyTitle shows
        // "LOADING"), never the previous directory's rows
        if (pendingLoad || !folderMatchesDir() || filesModel.status === FolderListModel.Loading) return out
        var q = query.toLowerCase()
        var n = Math.min(filesModel.count, 2000)
        for (var i = 0; i < n; i++) {
            var name = String(filesModel.get(i, "fileName"))
            if (q !== "" && name.toLowerCase().indexOf(q) < 0) continue
            var isDir = filesModel.isFolder(i)
            var suffix = String(filesModel.get(i, "fileSuffix") || "").toLowerCase()
            var exec = !isDir && execSet[name] === true
            var ft = isDir ? "dir" : fileTypeOf(suffix, exec)
            var size = isDir ? NaN : Number(filesModel.get(i, "fileSize"))
            var mtime = filesModel.get(i, "fileModified")
            var readable = !isDir || noReadSet[name] !== true
            out.push({
                icon: typeIcon(ft),
                name: name,
                meta: isDir ? "dir" : (ft !== "file" ? ft + " · " : "") + fmtBytes(size),
                kind: isDir ? "dir" : "file",
                sizeTxt: isDir ? "" : fmtBytes(size),
                mtimeTxt: fmtMtime(mtime),
                data: { path: String(filesModel.get(i, "filePath")), isDir: isDir,
                        size: isDir ? 0 : size, mtime: mtime, suffix: suffix,
                        exec: exec, ftype: ft, readable: readable }
            })
            if (out.length >= 500) break
        }
        return out
    }

    // Root cause of the "Enter kicks out the files" bug: FolderListModel
    // silently reports an unreadable dir as Ready+count=0 (verified on
    // /boot, /root — dmask 0077). Descending ejected the operator into an
    // empty view with "no matches" and no visible way back. Rows now carry
    // data.readable=false (dirProbe) and activation refuses to descend,
    // surfacing the real reason instead — the parent listing stays put.
    function dirEnterBlocked(r) {
        return !!r && r.kind === "dir" && !!r.data && r.data.readable === false
    }
    function denyDescend(r) {
        previewGen++
        headProc.running = false
        fileProbe.running = false
        previewTitle = r.name
        previewText = "# " + r.data.path + "\n\npermission denied — directory is not readable"
            + "\n(no descend: staying in " + filesDir + ")"
            + "\n\n# find -maxdepth 1 -type d ! -readable"
        previewInfo = r.data.path + " · not readable"
        actions = []
    }
    function filesDescend(path) {
        navStack.push({ section: section, path: filesDir, sel: sel, query: query })
        filesDir = path
        sel = 0
        query = ""
        searching = false
        rebuildRows()
    }
    function filesUp() {
        if (query !== "") { query = ""; sel = 0; rebuildRows(); return }
        var prev = navStack.length ? navStack[navStack.length - 1] : null
        var parent = parentDir(filesDir)
        if (prev && prev.section === 0) {
            navStack.pop()
            filesDir = prev.path
            sel = prev.sel
            query = prev.query
        } else if (filesDir !== "/" && filesDir !== "") {
            navStack.push({ section: section, path: filesDir, sel: sel, query: query })
            filesDir = parent
            sel = 0
        }
        searching = false
        rebuildRows()
    }

    // ‹- back row state. filesUp() pops the section-0 navStack entry first
    // (real back target), else walks parentDir — so the row's label must
    // show the true target, and it's only dead at "/" with an empty stack
    // (the topmost mount root; mount roots mid-history stay climbable,
    // matching Backspace).
    function backTargetPath() {
        var _dep = rowsRev   // navStack.push/pop don't notify — re-eval per rebuild
        if (navStack.length > 0 && navStack[navStack.length - 1].section === 0)
            return String(navStack[navStack.length - 1].path)
        return parentDir(filesDir)
    }
    function canUp() {
        var _dep = rowsRev
        if (navStack.length > 0 && navStack[navStack.length - 1].section === 0) return true
        return filesDir !== "/" && filesDir !== ""
    }
    function upLabel() {
        var _dep = rowsRev
        var t = backTargetPath()
        if (t === "" || t === filesDir) return "/"
        var b = baseName(t)
        return b !== "" ? b : t
    }

    // ---------- PROCESSES ----------
    // Live `ps` while the section is open; argv-fixed, headerless.
    Process {
        id: procProc
        running: false
        command: ["ps", "-eo", "pid,comm,pcpu,rss,stat", "--sort=-pcpu", "--no-headers"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.parseProc(text)
        }
    }
    property var procRows: []
    function parseProc(text) {
        var out = []
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length && out.length < 40; i++) {
            var m = lines[i].match(/^\s*(\d+)\s+(\S+)\s+([\d.]+)\s+(\d+)\s+(\S+)\s*$/)
            if (!m) continue
            out.push({
                icon: "◈",
                name: m[2],
                meta: Math.round(Number(m[3])) + "% · " + fmtBytes(Number(m[4]) * 1024),
                kind: "proc",
                data: { pid: m[1], comm: m[2], cpu: Number(m[3]), rssKb: Number(m[4]), stat: m[5] }
            })
        }
        procRows = out
        if (section === 1) rebuildRows()
    }
    Timer {
        id: procTimer
        interval: 3000
        repeat: true
        running: root.navOpen && root.section === 1
        onTriggered: procProc.running = true
    }

    // ---------- DEVICES (Topology contract) ----------
    // Node record: {id,kind,label,temp,load,power,link,state,extra} — vitals may
    // carry the `unknown` sentinel; render via isUnknown/txt/tempTxt, never raw.
    function devVital(n) {
        if (!root._T) return "—"
        var T = root._T
        if (!T.isUnknown(n.temp)) return T.tempTxt(n.temp)
        if (!T.isUnknown(n.power)) return T.txt(n.power, "W")
        if (!T.isUnknown(n.load)) return T.txt(n.load, "%")
        if (!T.isUnknown(n.link)) return T.txt(n.link)
        return T.unknownGlyph
    }
    function buildDeviceRows() {
        var out = []
        if (!root._T) return out
        var list = root._T.nodeList && root._T.nodeList.length ? root._T.nodeList
                 : (root._T.nodes ? Object.keys(root._T.nodes).map(function (k) { return root._T.nodes[k] }) : [])
        for (var i = 0; i < list.length; i++) {
            var n = list[i]
            if (!n || typeof n !== "object") continue
            var st = root._T.isUnknown(n.state) ? "" : " · " + n.state
            out.push({
                icon: "▨",
                name: String(n.label !== undefined ? n.label : n.id),
                meta: devVital(n) + st,
                kind: "dev",
                data: { id: String(n.id), node: n }
            })
        }
        var q = query.toLowerCase()
        if (q !== "") out = out.filter(function (r) { return r.name.toLowerCase().indexOf(q) >= 0 })
        return out
    }

    // ---------- AGENTS (stats keys: ag_*_procs/cpu, devsess*, tmux*) ----------
    property var agentRows: []
    function buildAgentRows() {
        var out = []
        var harnesses = [
            { id: "devin", label: "devin", cls: "devin-desktop" },
            { id: "opencode", label: "opencode", cls: "" },
            { id: "haze", label: "haze", cls: "" },
            { id: "october", label: "october-desktop", cls: "october" },
            { id: "hermes", label: "hermes", cls: "" },
            { id: "build", label: "build runners", cls: "" }
        ]
        for (var i = 0; i < harnesses.length; i++) {
            var h = harnesses[i]
            var pk = "ag_" + h.id + "_procs", ck = "ag_" + h.id + "_cpu"
            var known = has(pk)
            var procs = num(stats[pk]), cpu = num(stats[ck])
            var state = !known ? "—" : (procs > 0 ? "LIVE" : "IDLE")
            var extra = h.id === "devin" && has("ag_devin_acp")
                ? " · " + stats.ag_devin_acp + " acp" : ""
            out.push({
                icon: "◉",
                name: h.label,
                meta: known ? (procs + " procs · " + Math.round(cpu) + "%" + extra) : "—",
                kind: "agent",
                data: { id: h.id, label: h.label, cls: h.cls, procs: procs, cpu: cpu,
                        state: state, known: known }
            })
        }
        var ds = num(stats.devsess_count)
        for (var j = 0; j < ds && j < 12; j++) {
            var live = String(stats["devsess" + j + "_live"])
            out.push({
                icon: "◈",
                name: "  devin · " + String(stats["devsess" + j + "_name"]),
                meta: "pid " + stat("devsess" + j + "_pid") + (live === "1" || live === "true" ? " · LIVE" : ""),
                kind: "devsess",
                data: { pid: stat("devsess" + j + "_pid", ""), name: stat("devsess" + j + "_name", "") }
            })
        }
        var tn = num(stats.tmux_n)
        for (var t = 0; t < tn && t < 12; t++) {
            out.push({
                icon: "▦",
                name: "  tmux · " + String(stats["tmux" + t + "_name"]),
                meta: stat("tmux" + t + "_win") + " win" + (String(stats["tmux" + t + "_att"]) === "1" ? " · ATT" : ""),
                kind: "tmux",
                data: { name: stat("tmux" + t + "_name", "") }
            })
        }
        var q = query.toLowerCase()
        if (q !== "") out = out.filter(function (r) { return r.name.toLowerCase().indexOf(q) >= 0 })
        agentRows = out
        return out
    }

    onStatsChanged: if (navOpen && (section === 3 || section === 2)) rebuildRows()

    // ---------- REPOS (recon/integrations-dev.json git-repos loop) ----------
    // Constant script only — repo paths are expanded inside bash, never
    // concatenated from outside data.
    readonly property string reposScript:
        'for d in "$HOME"/projects/*/; do ' +
        '[ -d "$d/.git" ] || continue; ' +
        'n=$(basename "$d"); ' +
        'dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l); ' +
        'ab=$(git -C "$d" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null | tr "\\t" "/"); ' +
        'branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null); ' +
        'echo "$n|$dirty|${ab:-none}|${branch:-?}|$d"; done'
    Process {
        id: repoProc
        running: false
        command: ["bash", "-lc", root.reposScript]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.parseRepos(text)
        }
    }
    property var repoRows: []
    function parseRepos(text) {
        var out = []
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("|")
            if (f.length < 5 || f[0] === "") continue
            var dirty = Number(f[1]), ab = f[2]
            var state = dirty > 0 ? "dirty ×" + dirty : "clean"
            var rel = ab === "none" ? "no upstream" : ab
            out.push({
                icon: "▦",
                name: f[0],
                meta: state + " · " + rel + " · " + f[3],
                kind: "repo",
                data: { name: f[0], path: f[4], dirty: dirty, ab: rel, branch: f[3] }
            })
        }
        var q = query.toLowerCase()
        if (q !== "") out = out.filter(function (r) { return r.name.toLowerCase().indexOf(q) >= 0 })
        repoRows = out
        if (section === 4) rebuildRows()
    }
    Timer {
        id: repoTimer
        interval: 60000
        repeat: true
        running: root.navOpen && root.section === 4
        onTriggered: repoProc.running = true
    }

    // ---------- USAGE (token ledger ~/.local/state/nexuslink/tokens.json) ----
    readonly property string tokPath: Quickshell.env("HOME") + "/.local/state/nexuslink/tokens.json"
    property var tokData: ({})
    FileView {
        id: tokFile
        path: root.tokPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            var d = null
            try { d = JSON.parse(String(text())) } catch (e) { d = null }
            root.tokData = (d && typeof d === "object") ? d : ({})
            if (root.navOpen && root.section === 5) root.rebuildRows()
        }
        onLoadFailed: root.tokData = ({})
    }
    readonly property var tokBlocked: ["claude", "codex", "openai", "anthropic"]
    function tokBlockedName(id, label) {
        var s = (id + " " + label).toLowerCase()
        for (var i = 0; i < tokBlocked.length; i++) {
            var b = tokBlocked[i]
            if (s === b || s.indexOf(b + "-") === 0 || s.indexOf(b + "_") === 0 || s.indexOf(b + " ") === 0)
                return true
        }
        return false
    }
    function buildUsageRows() {
        var out = []
        var prov = tokData.providers
        if (prov && typeof prov === "object") {
            for (var k in prov) {
                var p = prov[k]
                if (!p || typeof p !== "object") continue
                var label = (p.label !== undefined) ? String(p.label) : k
                if (tokBlockedName(k, label)) continue
                var status = (p.meta && p.meta.status) ? String(p.meta.status)
                           : (p.meta && p.meta.ready === false) ? "waiting for auth" : ""
                out.push({
                    icon: "◍",
                    name: label,
                    meta: tokCell(p.day) + (status !== "" ? " · " + status : ""),
                    kind: "tok",
                    data: { id: k, label: label, p: p }
                })
            }
        }
        var q = query.toLowerCase()
        if (q !== "") out = out.filter(function (r) { return r.name.toLowerCase().indexOf(q) >= 0 })
        return out
    }

    // ======================================================================
    // Row/preview/action wiring
    // ======================================================================
    function rebuildRows() {
        var r
        switch (section) {
        case 0: r = buildFilesRows(); break
        case 1: r = procRows; break
        case 2: r = buildDeviceRows(); break
        case 3: r = buildAgentRows(); break
        case 4: r = repoRows; break
        default: r = buildUsageRows(); break
        }
        rows = r
        rowsRev++
        if (sel >= r.length) sel = Math.max(0, r.length - 1)
        refreshPreview()
    }

    function setSection(i) {
        if (i < 0 || i > 5) return
        if (i === section && navOpen) { rebuildRows(); return }
        navStack.push({ section: section, path: filesDir, sel: sel, query: query })
        section = i
        sel = 0
        query = ""
        searching = false
        if (i === 1) procProc.running = true
        if (i === 4) repoProc.running = true
        if (i === 2 && root._T && root._T.refresh) root._T.refresh(root.stats)
        rebuildRows()
    }

    function openSection(secName, path) {
        var idx = -1
        var s = String(secName || "").toLowerCase()
        for (var i = 0; i < sectionIds.length; i++) if (sectionIds[i] === s) idx = i
        if (s === "processes") idx = 1
        else if (s === "tokens") idx = 5
        else if (s === "f1") idx = 0
        else if (s === "f2") idx = 1
        else if (s === "f3") idx = 2
        else if (s === "f4") idx = 3
        else if (s === "f5") idx = 4
        else if (s === "f6") idx = 5
        if (idx < 0) idx = 0
        navStack = []
        sel = 0
        query = ""
        searching = false
        if (idx === 0 && path) filesDir = resolveNavPath(path)
        if (idx === 1) procProc.running = true
        if (idx === 4) repoProc.running = true
        if (idx === 2 && root._T && root._T.refresh) root._T.refresh(root.stats)
        if (idx === 5) tokFile.reload()
        section = idx
        navOpen = true
        rebuildRows()
        Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    }

    function goBack() {
        if (navStack.length === 0) return false
        var st = navStack.pop()
        section = st.section
        filesDir = st.path
        sel = st.sel
        query = st.query
        searching = false
        rebuildRows()
        return true
    }

    // ---------- preview ----------
    property string previewText: ""
    property string previewInfo: ""
    property string previewTitle: ""
    property var actions: []      // [{id,label,key,argv?|sh?|fn}]
    property int previewGen: 0

    // Bounded file preview: `head -c 65536` via argv; NUL sniff -> binary.
    Process {
        id: headProc
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.finishPreview(text)
        }
    }
    property string headPath: ""
    property int headGen: -1
    // `file -b` probe for binary-ish rows: real type + image dims ("1920 x 1080").
    Process {
        id: fileProbe
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.finishFileProbe(text)
        }
    }
    property int fileProbeGen: -1
    function finishPreview(text) {
        if (headGen !== previewGen) return // stale read from a killed run
        var body = String(text)
        var head = body.substring(0, 8192)
        var binary = head.indexOf("\0") >= 0
        previewText = binary
            ? "(binary file — " + fmtBytes(selRowSize()) + ", preview suppressed)"
            : body
        if (body.length >= 65536) previewText += "\n\n… truncated at 64 KiB"
    }
    function finishFileProbe(text) {
        if (fileProbeGen !== previewGen) return // selection moved on
        var r = selRow()
        if (!r || !r.data || r.kind !== "file") return
        var desc = String(text).trim()
        var ft = r.data.ftype || "file"
        var dims = ""
        var m = desc.match(/(\d+)\s*x\s*(\d+)/)
        if (ft === "image" && m) dims = m[1] + " × " + m[2] + " px"
        previewText = "# " + ft + " detail\nname   " + r.name
            + "\npath   " + r.data.path
            + "\nsize   " + fmtBytes(r.data.size)
            + "\nmtime  " + fmtMtime(r.data.mtime)
            + (r.data.exec ? "\nexec   +x" : "")
            + (dims !== "" ? "\nimage  " + dims : "")
            + "\n\n" + (desc !== "" ? desc : "(file: no description)")
        previewInfo = r.data.path + " · " + fmtBytes(r.data.size)
            + (dims !== "" ? " · " + dims : "")
    }
    function selRow() { return (sel >= 0 && sel < rows.length) ? rows[sel] : null }
    function selRowSize() { var r = selRow(); return r && r.data ? r.data.size : 0 }

    function refreshPreview() {
        previewGen++
        headProc.running = false
        fileProbe.running = false
        var r = selRow()
        actions = []
        if (!r) { previewTitle = ""; previewText = ""; previewInfo = ""; return }
        previewTitle = r.name
        switch (r.kind) {
        case "dir":
            previewText = "# " + r.data.path + "\n\ndirectory — Enter to drill in"
            previewInfo = "path " + r.data.path + " · type dir · mtime " + fmtMtime(r.data.mtime)
            actions = fileActions(r)
            break
        case "file":
            var ft = r.data.ftype || "file"
            actions = fileActions(r)
            if (ft === "image" || ft === "video" || ft === "audio"
                    || ft === "archive" || ft === "exec") {
                // binary-ish: skip the head read, probe `file -b` instead —
                // image rows get pixel dims out of it.
                previewText = "# " + ft + " detail\nname   " + r.name
                    + "\npath   " + r.data.path
                    + "\nsize   " + fmtBytes(r.data.size)
                    + "\nmtime  " + fmtMtime(r.data.mtime)
                    + (r.data.exec ? "\nexec   +x" : "")
                    + "\n\n(probing file…)"
                previewInfo = "path " + r.data.path + " · size " + fmtBytes(r.data.size)
                fileProbeGen = previewGen
                fileProbe.command = ["file", "-b", "--", r.data.path]
                fileProbe.running = true
            } else {
                previewText = "(loading…)"
                previewInfo = "path " + r.data.path + " · size " + fmtBytes(r.data.size)
                    + " · mtime " + fmtMtime(r.data.mtime)
                headPath = r.data.path
                headGen = previewGen
                headProc.command = ["head", "-c", "65536", "--", r.data.path]
                headProc.running = true
            }
            break
        case "proc":
            var d = r.data
            previewText = "# process detail\nname   " + d.comm + "\npid    " + d.pid
                + "\nstate  " + d.stat + "\ncpu    " + d.cpu + "% of one core\nrss    "
                + fmtBytes(d.rssKb * 1024) + "\n\n# ps -eo pid,comm,pcpu,rss,stat"
            previewInfo = "pid " + d.pid + " · cpu " + d.cpu + "% · rss " + fmtBytes(d.rssKb * 1024)
            actions = [
                { id: "focus", label: "FOCUS WINDOW", key: "ENTER" },
                { id: "term", label: "SIGNAL TERM", key: "K" },
                { id: "proc", label: "OPEN /PROC", key: "P" }
            ]
            break
        case "dev":
            var n = r.data.node
            var T = root._T
            function dv(v) { return (T && !T.isUnknown(v)) ? String(v) : ung() }
            var extra = ""
            if (n.extra && typeof n.extra === "object")
                for (var ek in n.extra) extra += "\n" + ek + "  " + n.extra[ek]
            previewText = "# device detail\nid     " + r.data.id + "\nkind   "
                + dv(n.kind) + "\nname   " + r.name
                + "\ntemp   " + (T ? T.tempTxt(n.temp) : ung())
                + "\nload   " + dv(n.load)
                + "\npower  " + dv(n.power)
                + "\nlink   " + dv(n.link)
                + "\nstate  " + dv(n.state) + extra
                + "\n\n# Topology.nodes registry"
            previewInfo = r.data.id + " · " + dv(n.kind)
            actions = [
                { id: "info", label: "INFO", key: "ENTER" },
                { id: "topoRefresh", label: "REFRESH", key: "R" },
                { id: "copyId", label: "COPY ID", key: "C" }
            ]
            break
        case "agent":
            var a = r.data
            var sess = ""
            if (a.id === "devin" && has("devsess_count")) {
                sess = "\n\n# live session locks"
                var ds = num(stats.devsess_count)
                for (var j = 0; j < ds && j < 12; j++)
                    sess += "\n" + stat("devsess" + j + "_name") + "  pid " + stat("devsess" + j + "_pid")
            }
            if (a.id === "devin" && has("ag_devin_acp")) sess = "\nacp lanes  " + stats.ag_devin_acp + sess
            previewText = "# agent detail\nname   " + a.label + "\nstate  " + a.state
                + "\ncpu    " + (a.known ? Math.round(a.cpu) + "% of one core" : "—")
                + "\nprocs  " + (a.known ? a.procs : "—") + sess
                + "\n\n# collector ag_" + a.id + "_{procs,cpu}"
            previewInfo = a.state + " · " + (a.known ? a.procs + " procs" : "no feed")
            actions = [
                { id: "focus", label: "FOCUS", key: "ENTER" },
                { id: "procs", label: "PROCESSES", key: "P" }
            ]
            break
        case "devsess":
            previewText = "# devin session\nname   " + r.data.name + "\npid    " + r.data.pid
                + "\n\n# ~/.local/share/devin/cli/session_locks"
            previewInfo = "pid " + r.data.pid
            actions = [
                { id: "focusDevin", label: "FOCUS DEVIN", key: "ENTER" },
                { id: "copyPid", label: "COPY PID", key: "C" }
            ]
            break
        case "tmux":
            previewText = "# tmux session\nname   " + r.data.name
                + "\n\n# attach: tmux attach -t " + r.data.name
            previewInfo = "tmux " + r.data.name
            actions = [
                { id: "attach", label: "ATTACH", key: "ENTER" },
                { id: "copyName", label: "COPY NAME", key: "C" }
            ]
            break
        case "repo":
            var rp = r.data
            previewText = "# repo detail\nname   " + rp.name + "\npath   " + rp.path
                + "\nstate  " + (rp.dirty > 0 ? "dirty ×" + rp.dirty : "clean")
                + "\nbranch " + rp.branch + "\nahead/behind " + rp.ab
                + "\n\n# git-repos recon lane — ~/projects"
            previewInfo = rp.path
            actions = [
                { id: "termHere", label: "TERMINAL HERE", key: "ENTER" },
                { id: "copyPath", label: "COPY PATH", key: "C" },
                { id: "refresh", label: "REFRESH", key: "R" }
            ]
            break
        case "tok":
            var p = r.data.p
            previewText = "# provider ledger\nprovider " + r.data.label
                + "\nkind     " + (p.kind !== undefined ? p.kind : "—")
                + "\nday      " + tokCell(p.day)
                + "\nweek     " + tokCell(p.week)
                + "\nmonth    " + tokCell(p.month)
                + (p.meta && p.meta.status ? "\nstatus   " + p.meta.status : "")
                + "\n\n# ~/.local/state/nexuslink/tokens.json"
                + (tokData.updated ? "  updated " + tokData.updated : "")
            previewInfo = "today " + tokCell(p.day)
            actions = [
                { id: "revealLedger", label: "REVEAL FILE", key: "ENTER" },
                { id: "copyCell", label: "COPY DAY", key: "C" },
                { id: "reload", label: "RELOAD", key: "R" }
            ]
            break
        }
    }

    function fileActions(r) {
        if (isRunnableData(r.data)) {
            // executable row: ENTER runs it, OPEN still does xdg-open
            return [
                { id: "run", label: "RUN", key: "ENTER" },
                { id: "open", label: "OPEN", key: "O" },
                { id: "termHere", label: "TERM HERE", key: "T" },
                { id: "copyPath", label: "COPY PATH", key: "C" },
                { id: "reveal", label: "REVEAL", key: "R" }
            ]
        }
        return [
            { id: "open", label: "OPEN", key: "ENTER" },
            { id: "termHere", label: "TERMINAL HERE", key: "T" },
            { id: "copyPath", label: "COPY PATH", key: "C" },
            { id: "reveal", label: "REVEAL", key: "R" }
        ]
    }

    // ---------- action dispatch ----------
    function runAction(id) {
        var r = selRow()
        switch (id) {
        case "open":
            if (r && dirEnterBlocked(r)) { denyDescend(r); return }
            if (r && r.kind === "dir") { filesDescend(r.data.path); return }
            if (r) { execArgv(["uwsm-app", "--", "xdg-open", r.data.path]); navOpen = false }
            return
        case "run":
            // executables: scripts go through a terminal so their output is
            // visible; binaries launch detached in their own uwsm scope.
            // Both paths are argv vectors — no shell string concat.
            if (!r) return
            if (extScript.indexOf(" " + r.data.suffix + " ") >= 0)
                execArgv(["xdg-terminal-exec", "--", r.data.path])
            else if (r.data.suffix === "desktop")
                execArgv(["uwsm-app", "--", "xdg-open", r.data.path])
            else
                execArgv(["uwsm-app", "--", r.data.path])
            navOpen = false
            return
        case "termHere":
            if (!r) return
            var dir = r.data.isDir ? r.data.path : parentDir(r.data.path)
            if (r.kind === "repo") dir = r.data.path
            execArgv(["xdg-terminal-exec", "--dir=" + dir])
            navOpen = false
            return
        case "copyPath": if (r) execShArgv('printf %s "$1" | wl-copy', [r.data.path]); return
        case "reveal":
            if (r) { execArgv(["uwsm-app", "--", "nautilus", "--new-window", "--select", r.data.path]); navOpen = false }
            return
        case "focus":
            if (!r) return
            if (r.kind === "proc") execArgv(["hyprctl", "dispatch", "focuswindow", "pid:" + r.data.pid])
            else if (r.kind === "agent" && r.data.cls !== "") execArgv(["hyprctl", "dispatch", "focuswindow", "class:" + r.data.cls])
            else return
            navOpen = false
            return
        case "term": if (r) execArgv(["kill", String(r.data.pid)]); procProc.running = true; return
        case "proc": if (r) { filesDir = "/proc/" + r.data.pid; setSection(0) } return
        case "info": return
        case "topoRefresh": if (root._T && root._T.refresh) root._T.refresh(root.stats); rebuildRows(); return
        case "copyId": if (r) execShArgv('printf %s "$1" | wl-copy', [r.data.id]); return
        case "procs": setSection(1); return
        case "focusDevin": execArgv(["hyprctl", "dispatch", "focuswindow", "class:devin-desktop"]); navOpen = false; return
        case "copyPid": if (r) execShArgv('printf %s "$1" | wl-copy', [String(r.data.pid)]); return
        case "attach": if (r) { execArgv(["xdg-terminal-exec", "--", "tmux", "attach", "-t", r.data.name]); navOpen = false } return
        case "copyName": if (r) execShArgv('printf %s "$1" | wl-copy', [r.data.name]); return
        case "refresh": repoProc.running = true; return
        case "revealLedger": execArgv(["uwsm-app", "--", "nautilus", "--new-window", "--select", tokPath]); navOpen = false; return
        case "copyCell": if (r) execShArgv('printf %s "$1" | wl-copy', [tokCell(r.data.p.day)]); return
        case "reload": tokFile.reload(); return
        }
    }

    function primaryAction() {
        var r = selRow()
        if (!r) return
        if (dirEnterBlocked(r)) { denyDescend(r); return }
        if (r.kind === "dir") { filesDescend(r.data.path); return }
        if (actions.length > 0) runAction(actions[0].id)
    }

    function actionByKey(k) {
        for (var i = 0; i < actions.length; i++)
            if (actions[i].key === k) return actions[i].id
        return ""
    }

    // ======================================================================
    // IPC — target "nexuslink.nav"
    // ======================================================================
    IpcHandler {
        target: "nexuslink.nav"
        function open(section: string, path: string): string {
            root.openSection(section, path || "")
            return "ok"
        }
        function back(): string { root.goBack(); return "ok" }
        function close(): string { root.navOpen = false; return "ok" }
        function state(): string {
            return JSON.stringify({
                open: root.navOpen,
                section: root.sectionIds[root.section],
                path: root.filesDir,
                query: root.query,
                sel: root.sel,
                rows: root.rows.length,
                screen: root.navScreen && root.navScreen.name ? String(root.navScreen.name) : "",
                // files explorer state — agents read mounts here, then drive
                // them with `open files <path>` (same switch as the rail)
                mount: root.mountActive,
                mounts: root.mountRows,
                hidden: root.showHiddenFiles,
                // readable=false means the listing is empty because the dir
                // cannot be read — agents must not report it as an empty dir
                readable: root.dirReadable,
                jumps: root.jumpRows
            })
        }
        function mounts(): string { return JSON.stringify(root.mountRows) }
    }

    // ======================================================================
    // Key handling — only while open; the window unmaps on close so the
    // Exclusive grab can never outlive the overlay.
    // ======================================================================
    function isPrintable(ev) {
        return ev.text && ev.text.length > 0
            && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
    }

    function handleKey(ev) {
        if (!navOpen) { ev.accepted = false; return }
        var k = ev.key

        if (searching) {
            if (k === Qt.Key_Escape) { searching = false; query = ""; sel = 0; rebuildRows() }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) { searching = false; primaryAction() }
            else if (k === Qt.Key_Backspace) {
                query = query.length > 1 ? query.substring(0, query.length - 1) : ""
                sel = 0; rebuildRows()
            }
            else if (k === Qt.Key_Up) { sel = Math.max(0, sel - 1); refreshPreview() }
            else if (k === Qt.Key_Down) { sel = Math.min(rows.length - 1, sel + 1); refreshPreview() }
            else if (isPrintable(ev)) { query += ev.text; sel = 0; rebuildRows() }
            ev.accepted = true
            return
        }

        if (k >= Qt.Key_F1 && k <= Qt.Key_F6) { setSection(k - Qt.Key_F1); ev.accepted = true; return }
        // Ctrl+H — hidden files toggle, same chord as gtk/qt file dialogs
        if (section === 0 && (ev.modifiers & Qt.ControlModifier) && k === Qt.Key_H) {
            showHiddenFiles = !showHiddenFiles
            sel = 0
            rebuildRows()
            ev.accepted = true
            return
        }
        switch (k) {
        case Qt.Key_Escape:
            if (query !== "") { query = ""; sel = 0; rebuildRows() }
            else navOpen = false
            break
        case Qt.Key_Up:
            sel = Math.max(0, sel - 1); refreshPreview()
            break
        case Qt.Key_Down:
            sel = Math.min(rows.length - 1, sel + 1); refreshPreview()
            break
        case Qt.Key_PageUp:
            sel = Math.max(0, sel - 12); refreshPreview()
            break
        case Qt.Key_PageDown:
            sel = Math.min(rows.length - 1, sel + 12); refreshPreview()
            break
        case Qt.Key_Return:
        case Qt.Key_Enter:
            primaryAction()
            break
        case Qt.Key_Right:
            primaryAction()
            break
        case Qt.Key_Backspace:
        case Qt.Key_Left:
            if (section === 0) filesUp()
            else if (!goBack()) { /* nothing to pop — stay */ }
            break
        case Qt.Key_Slash:
            searching = true
            break
        case Qt.Key_Home:
            sel = 0; refreshPreview()
            break
        case Qt.Key_End:
            sel = Math.max(0, rows.length - 1); refreshPreview()
            break
        default:
            var aid = actionByKey(String(ev.text || "").toUpperCase())
            if (aid !== "") { runAction(aid); ev.accepted = true; return }
            if (isPrintable(ev)) { searching = true; query += ev.text; sel = 0; rebuildRows() }
            break
        }
        ev.accepted = true
    }

    onNavOpenChanged: {
        if (navOpen) {
            if (filesDir === "") filesDir = Quickshell.env("HOME") || "/"
            mountsFile.reload()
            if (section === 0) { restartExecProbe(); restartDirProbe(); jumpProbe.running = true }
            Qt.callLater(function () { keyCatcher.forceActiveFocus() })
            focusTimer.restart()
            rebuildRows()
        } else {
            searching = false
            headProc.running = false
            fileProbe.running = false
        }
    }
    Timer {
        id: focusTimer
        interval: 75
        onTriggered: keyCatcher.forceActiveFocus()
    }

    // ======================================================================
    // Surface
    // ======================================================================
    PanelWindow {
        id: navWin
        screen: root.navScreen
        visible: root.navOpen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.namespace: "nexuslink-nav"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.navOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // Whole surface takes input while open: scrim anywhere dismisses,
        // card content swallows its own clicks. Drops with the window.
        mask: Region { item: scrim }

        Item {
            id: keyCatcher
            anchors.fill: parent
            focus: true
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function (event) { root.handleKey(event) }

            // dim scrim — click anywhere outside the card dismisses
            Rectangle {
                id: scrim
                anchors.fill: parent
                color: Qt.rgba(4 / 255, 5 / 255, 7 / 255, 0.55)
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onClicked: root.navOpen = false
                }
            }

            // ---- card (1420×876 on a 1920×1200 field -> ~74%/73%) --------
            // elevation plate: a modal card with no shadow reads flat on the
            // scrim. Static offset plate, no filters (GlassPane idiom) — 2px
            // halo on the sides, a deeper skirt below so the card reads as
            // lifted rather than outlined. rgba(0,0,0,.385) is what
            // Style.shadow(black, 26) resolves to, inlined to keep this file's
            // Style guard intact.
            Rectangle {
                id: cardShadow
                anchors { left: card.left; right: card.right; top: card.top; bottom: card.bottom
                          leftMargin: -2; rightMargin: -2; topMargin: -2; bottomMargin: -10 }
                radius: th.rPane + 2
                color: Qt.rgba(0, 0, 0, 0.385)
                visible: card.visible
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: Math.min(1420, parent.width * 0.74)
                height: Math.min(880, parent.height * 0.73)
                radius: th.rPane
                color: th.chassis
                border.color: th.edge
                border.width: 1
                clip: true

                // chrome bevel: top light, bottom shade
                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.5; color: Qt.rgba(235 / 255, 245 / 255, 252 / 255, 0.5) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.75)
                }
                // holographic edge light along the top rim
                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 8; rightMargin: 8 }
                    height: 2
                    radius: 2
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.18; color: th.ice }
                        GradientStop { position: 0.42; color: "#ff7ad9" }
                        GradientStop { position: 0.66; color: th.accent }
                        GradientStop { position: 0.86; color: "#8affd0" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    opacity: 0.55
                }

                MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: function (m) { m.accepted = true } }

                Column {
                    anchors.fill: parent
                    // ---------- header ----------
                    Item {
                        id: headBar
                        width: parent.width
                        height: 56
                        // engraved rule: lit line over a shade
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: th.ruleLit }
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; anchors.bottomMargin: 1; height: 1; color: th.ruleDark }

                        // left cluster: mark · wordmark · rule · breadcrumb.
                        // The breadcrumb is bounded against the search field's
                        // left edge so the two can never collide.
                        Item {
                            id: headLeft
                            anchors { left: parent.left; leftMargin: th.g5; top: parent.top; bottom: parent.bottom }
                            width: searchBox.x - th.g4 - th.g5
                            height: parent.height

                            Row {
                                id: headRow
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                spacing: th.g3

                                // acid tick — the one saturated mark in the bar
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 3
                                    height: 18
                                    radius: 1.5
                                    color: th.accent
                                }
                                Text {
                                    id: wordmark
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "NAVIGATOR"
                                    color: th.txt
                                    font.family: th.fDisp
                                    font.pixelSize: th.pxWord
                                    font.letterSpacing: 3.0
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 1
                                    height: 16
                                    color: th.ruleDark
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    // tick 3 + 3 gaps + rule 1 — the rest is crumbs
                                    width: Math.max(0, parent.width - wordmark.implicitWidth - 40)
                                    elide: Text.ElideMiddle
                                    textFormat: Text.RichText
                                    text: root.crumbText()
                                    color: th.t55
                                    font.family: th.fMono
                                    font.pixelSize: th.pxCrumb
                                }
                            }
                        }

                        // search field (recessed well), right-aligned
                        Rectangle {
                            id: searchBox
                            anchors { right: parent.right; rightMargin: th.g5; verticalCenter: parent.verticalCenter }
                            width: 300
                            height: 32
                            radius: th.rCtl
                            border.color: root.searching ? th.accent
                                : (sMouse.containsMouse ? th.ice : Qt.rgba(0, 0, 0, 0.5))
                            border.width: 1
                            // recessed face: top shade + bottom inner light
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: th.wellTop }
                                GradientStop { position: 1.0; color: th.wellBot }
                            }
                            Rectangle {
                                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: searchBox.radius; rightMargin: searchBox.radius }
                                height: 1
                                color: Qt.rgba(0, 0, 0, 0.7)
                            }
                            Rectangle {
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: searchBox.radius; rightMargin: searchBox.radius }
                                height: 1
                                color: Qt.rgba(0.92, 0.96, 0.99, 0.07)
                            }
                            // armed marker: a 2px acid bar on the leading edge
                            Rectangle {
                                anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 1 }
                                width: 2
                                height: parent.height - 12
                                radius: 1
                                color: th.accent
                                opacity: root.searching ? 1 : 0
                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: Style.dur.snap
                                        easing.type: Style.easing.standard
                                    }
                                }
                            }
                            Text {
                                anchors { left: parent.left; leftMargin: th.g3; verticalCenter: parent.verticalCenter }
                                text: "/"
                                color: root.searching ? th.accent : th.t40
                                font.family: th.fMono
                                font.pixelSize: th.pxCrumb
                            }
                            Text {
                                anchors { left: parent.left; leftMargin: th.g3 + 12; right: parent.right; rightMargin: th.g3; verticalCenter: parent.verticalCenter }
                                elide: Text.ElideRight
                                text: root.query !== "" ? root.query + (root.searching ? "▌" : "")
                                      : (root.searching ? "▌" : "filter this section")
                                color: (root.query !== "" || root.searching) ? th.txt : th.t40
                                font.family: th.fMono
                                font.pixelSize: th.pxCrumb
                            }
                            MouseArea {
                                id: sMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: { root.searching = true; keyCatcher.forceActiveFocus() }
                            }
                        }
                    }

                    // ---------- body ----------
                    Row {
                        width: parent.width
                        height: parent.height - headBar.height - footBar.height
                        // rail
                        Item {
                            id: rail
                            width: 280
                            height: parent.height
                            // engraved vertical rule
                            Rectangle { anchors.right: parent.right; height: parent.height; width: 1; color: th.ruleDark }
                            Rectangle { anchors.right: parent.right; anchors.rightMargin: 1; height: parent.height; width: 1; color: th.ruleLit }

                            // ---- zone A: sections (fixed) ----
                            Column {
                                id: secZone
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: th.g3 }
                                spacing: 0

                                // one header recipe for the whole rail: title,
                                // hairline rule filling the slack, count at the end
                                Item {
                                    id: secHdr
                                    width: parent.width
                                    height: 22
                                    Text {
                                        id: secHdrTitle
                                        anchors { left: parent.left; leftMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        text: "SECTIONS"
                                        color: th.t55
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxTitle
                                        font.letterSpacing: 2.6
                                    }
                                    Rectangle {
                                        anchors { left: secHdrTitle.right; right: parent.right; rightMargin: th.g1 + th.cntW + th.g2; verticalCenter: parent.verticalCenter }
                                        height: 1
                                        color: th.ruleDark
                                    }
                                    Text {
                                        anchors { right: parent.right; rightMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        width: th.cntW
                                        horizontalAlignment: Text.AlignRight
                                        text: "6"
                                        color: th.t40
                                        font.family: th.fMono
                                        font.pixelSize: th.pxMicro
                                    }
                                }

                                Repeater {
                                    model: 6
                                    delegate: Rectangle {
                                        id: secBtn
                                        required property int index
                                        readonly property bool active: root.section === secBtn.index
                                        width: parent.width
                                        height: 34
                                        radius: th.rRow
                                        // constant 1px keeps the inner Row from
                                        // shifting a pixel when state changes
                                        border.width: 1
                                        border.color: secMouse.containsMouse
                                            ? (secBtn.active ? th.accent : th.accent2Dim)
                                            : (secBtn.active ? th.accentDim : "transparent")
                                        color: secMouse.containsMouse
                                            ? th.wash
                                            : (secBtn.active ? Qt.rgba(255, 255, 255, 0.045) : "transparent")
                                        Behavior on color {
                                            NumberAnimation {
                                                duration: Style.dur.snap
                                                easing.type: Style.easing.standard
                                            }
                                        }
                                        // active marker: a 2px acid bar, not a dot
                                        Rectangle {
                                            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 1 }
                                            width: 2
                                            height: 16
                                            radius: 1
                                            color: th.accent
                                            opacity: secBtn.active ? 1 : 0
                                            Behavior on opacity {
                                                NumberAnimation {
                                                    duration: Style.dur.snap
                                                    easing.type: Style.easing.standard
                                                }
                                            }
                                        }
                                        Item {
                                            anchors { fill: parent; leftMargin: th.g3; rightMargin: th.g2; topMargin: 1; bottomMargin: 1 }
                                            Row {
                                                anchors.fill: parent
                                                spacing: th.g2
                                                Text {
                                                    id: secTitle
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: Math.max(0, parent.width - cap.width - parent.spacing)
                                                    elide: Text.ElideRight
                                                    text: root.sectionNames[secBtn.index]
                                                    color: secBtn.active ? th.accent : (secMouse.containsMouse ? th.txt : th.t70)
                                                    font.family: th.fDisp
                                                    font.pixelSize: th.pxTitle
                                                    font.letterSpacing: 1.6
                                                }
                                                // F-key as a real keycap, right-aligned
                                                Rectangle {
                                                    id: cap
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 22
                                                    height: 16
                                                    radius: th.rKey
                                                    color: secBtn.active ? Qt.rgba(200 / 255, 243 / 255, 29 / 255, 0.10)
                                                        : Qt.rgba(0, 0, 0, 0.34)
                                                    border.width: 1
                                                    border.color: secBtn.active ? th.accentDim : Qt.rgba(0, 0, 0, 0.5)
                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: "F" + (secBtn.index + 1)
                                                        color: secBtn.active ? th.accent : th.t40
                                                        font.family: th.fDisp
                                                        font.pixelSize: th.pxKey
                                                        font.letterSpacing: 1.0
                                                    }
                                                }
                                            }
                                        }
                                        MouseArea {
                                            id: secMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: root.setSection(secBtn.index)
                                        }
                                    }
                                }
                            }

                            // ---- zone B: mounts + jumps (flex) ----
                            // The rail used to be one Column whose children
                            // needed 933px inside 774px, so the CONTEXT block
                            // painted straight over the list column. Zones are
                            // now explicit: A is fixed, B takes the slack,
                            // C is pinned to the bottom.
                            Item {
                                id: listZone
                                anchors {
                                    left: parent.left; right: parent.right
                                    top: secZone.bottom; bottom: ctxZone.top
                                    topMargin: th.g3
                                    bottomMargin: th.g3
                                }
                                // slack after both headers + the gap between
                                // them; MOUNTS takes the larger share
                                readonly property real free:
                                    height - 2 * 20 - th.g3
                                readonly property real mntH: Math.max(0, Math.round(free * 0.62))
                                readonly property real jmpH: Math.max(0, free - mntH)

                                Item {
                                    id: mntZone
                                    width: parent.width
                                    height: 20
                                    Text {
                                        id: mntTitle
                                        anchors { left: parent.left; leftMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        text: "MOUNTS"
                                        color: th.t55
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxTitle
                                        font.letterSpacing: 2.6
                                    }
                                    Rectangle {
                                        anchors { left: mntTitle.right; right: parent.right; rightMargin: th.g1 + th.cntW + th.g2; verticalCenter: parent.verticalCenter }
                                        height: 1
                                        color: th.ruleDark
                                    }
                                    Text {
                                        anchors { right: parent.right; rightMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        width: th.cntW
                                        horizontalAlignment: Text.AlignRight
                                        visible: root.section === 0
                                        text: String(root.mountRows.length)
                                        color: th.t40
                                        font.family: th.fMono
                                        font.pixelSize: th.pxMicro
                                    }
                                }
                                ListView {
                                    id: mountList
                                    visible: root.section === 0
                                    width: parent.width
                                    anchors { top: mntZone.bottom; topMargin: th.g1 }
                                    height: visible ? Math.min(contentHeight, listZone.mntH) : 0
                                    clip: true
                                    interactive: contentHeight > height
                                    boundsBehavior: Flickable.StopAtBounds
                                    spacing: 3
                                    model: root.mountRows
                                    delegate: Rectangle {
                                        id: mntBtn
                                        required property int index
                                        required property var modelData
                                        readonly property bool active: mntBtn.modelData.path === root.mountActive
                                        width: mountList.width
                                        height: 36
                                        radius: th.rRow
                                        border.width: 1
                                        border.color: mntMouse.containsMouse
                                            ? (mntBtn.active ? th.accent : th.accent2Dim)
                                            : (mntBtn.active ? th.accentDim : "transparent")
                                        color: mntMouse.containsMouse
                                            ? th.wash
                                            : (mntBtn.active ? Qt.rgba(255, 255, 255, 0.045) : "transparent")
                                        Behavior on color {
                                            NumberAnimation {
                                                duration: Style.dur.snap
                                                easing.type: Style.easing.standard
                                            }
                                        }
                                        Rectangle {
                                            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 1 }
                                            width: 2
                                            height: 18
                                            radius: 1
                                            color: th.accent
                                            opacity: mntBtn.active ? 1 : 0
                                            Behavior on opacity {
                                                NumberAnimation {
                                                    duration: Style.dur.snap
                                                    easing.type: Style.easing.standard
                                                }
                                            }
                                        }
                                        Item {
                                            id: mntInner
                                            anchors { fill: parent; leftMargin: th.g3; rightMargin: th.g2; topMargin: th.g1; bottomMargin: th.g1 }
                                            // fstype gets a fixed 44px column so the
                                            // filesystem names line up down the rail
                                            readonly property real fsW: 44
                                            Text {
                                                id: mntGlyph
                                                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                                                width: 16
                                                horizontalAlignment: Text.AlignHCenter
                                                text: mntBtn.modelData.icon
                                                color: mntBtn.active ? th.accent : th.ice
                                                font.family: th.fMono
                                                font.pixelSize: 11
                                            }
                                            Column {
                                                anchors {
                                                    left: mntGlyph.right; leftMargin: th.g2
                                                    right: mntFs.left; rightMargin: th.g2
                                                    verticalCenter: parent.verticalCenter
                                                }
                                                spacing: 1
                                                Text {
                                                    width: parent.width
                                                    elide: Text.ElideRight
                                                    text: mntBtn.modelData.label
                                                    color: mntBtn.active ? th.accent : (mntMouse.containsMouse ? th.txt : th.t70)
                                                    font.family: th.fMono
                                                    font.pixelSize: th.pxRow - 1
                                                }
                                                Text {
                                                    width: parent.width
                                                    // ElideLeft keeps the tail of a long
                                                    // mountpoint, which is the part that
                                                    // tells two mounts apart
                                                    elide: Text.ElideLeft
                                                    text: mntBtn.modelData.path
                                                    color: th.t40
                                                    font.family: th.fMono
                                                    font.pixelSize: th.pxMicro
                                                }
                                            }
                                            Text {
                                                id: mntFs
                                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                                width: mntInner.fsW
                                                horizontalAlignment: Text.AlignRight
                                                elide: Text.ElideRight
                                                text: mntBtn.modelData.fstype !== undefined ? mntBtn.modelData.fstype : root.ung()
                                                color: th.t40
                                                font.family: th.fMono
                                                font.pixelSize: th.pxMicro
                                            }
                                        }
                                        MouseArea {
                                            id: mntMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: root.filesGoTo(mntBtn.modelData.path)
                                        }
                                    }
                                }

                                Item {
                                    id: jmpZone
                                    width: parent.width
                                    height: 20
                                    anchors { top: parent.top; topMargin: listZone.mntH + 20 + th.g1 }
                                    Text {
                                        id: jmpTitle
                                        anchors { left: parent.left; leftMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        text: "JUMPS"
                                        color: th.t55
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxTitle
                                        font.letterSpacing: 2.6
                                    }
                                    Rectangle {
                                        anchors { left: jmpTitle.right; right: parent.right; rightMargin: th.g1 + th.cntW + th.g2; verticalCenter: parent.verticalCenter }
                                        height: 1
                                        color: th.ruleDark
                                    }
                                    Text {
                                        anchors { right: parent.right; rightMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        width: th.cntW
                                        horizontalAlignment: Text.AlignRight
                                        visible: root.section === 0
                                        text: String(root.jumpRows.length)
                                        color: th.t40
                                        font.family: th.fMono
                                        font.pixelSize: th.pxMicro
                                    }
                                }
                                ListView {
                                    id: jumpList
                                    visible: root.section === 0
                                    width: parent.width
                                    anchors { top: jmpZone.bottom; topMargin: th.g1 }
                                    height: visible ? Math.min(contentHeight, listZone.jmpH) : 0
                                    clip: true
                                    interactive: contentHeight > height
                                    boundsBehavior: Flickable.StopAtBounds
                                    spacing: 2
                                    model: root.jumpRows
                                    delegate: Rectangle {
                                        id: jmpBtn
                                        required property int index
                                        required property var modelData
                                        readonly property bool active: jmpBtn.modelData.path === root.filesDir
                                        width: jumpList.width
                                        height: 28
                                        radius: th.rRow
                                        border.width: 1
                                        border.color: jmpMouse.containsMouse
                                            ? (jmpBtn.active ? th.accent : th.accent2Dim)
                                            : (jmpBtn.active ? th.accentDim : "transparent")
                                        color: jmpMouse.containsMouse
                                            ? th.wash
                                            : (jmpBtn.active ? Qt.rgba(255, 255, 255, 0.045) : "transparent")
                                        Behavior on color {
                                            NumberAnimation {
                                                duration: Style.dur.snap
                                                easing.type: Style.easing.standard
                                            }
                                        }
                                        Rectangle {
                                            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 1 }
                                            width: 2
                                            height: 14
                                            radius: 1
                                            color: th.accent
                                            opacity: jmpBtn.active ? 1 : 0
                                        }
                                        Text {
                                            id: jmpGlyph
                                            anchors { left: parent.left; leftMargin: th.g3; verticalCenter: parent.verticalCenter }
                                            width: 16
                                            horizontalAlignment: Text.AlignHCenter
                                            text: jmpBtn.modelData.icon
                                            color: jmpBtn.active ? th.accent
                                                 : (jmpBtn.modelData.recent ? th.t55 : th.ice)
                                            font.family: th.fMono
                                            font.pixelSize: 11
                                        }
                                        Text {
                                            anchors {
                                                left: jmpGlyph.right; leftMargin: th.g2
                                                right: parent.right; rightMargin: th.g2
                                                verticalCenter: parent.verticalCenter
                                            }
                                            elide: Text.ElideMiddle
                                            text: jmpBtn.modelData.label
                                            color: jmpBtn.active ? th.accent
                                                 : (jmpMouse.containsMouse ? th.txt
                                                     : (jmpBtn.modelData.recent ? th.t55 : th.t70))
                                            font.family: th.fMono
                                            font.pixelSize: th.pxRow - 1
                                        }
                                        MouseArea {
                                            id: jmpMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: root.filesGoTo(jmpBtn.modelData.path)
                                        }
                                    }
                                }
                            }

                            // ---- zone C: context (pinned bottom) ----
                            Column {
                                id: ctxZone
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: th.g3 }
                                spacing: th.g1

                                Item {
                                    width: parent.width
                                    height: 20
                                    Text {
                                        id: ctxTitle
                                        anchors { left: parent.left; leftMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        text: "CONTEXT"
                                        color: th.t55
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxTitle
                                        font.letterSpacing: 2.6
                                    }
                                    Rectangle {
                                        anchors { left: ctxTitle.right; right: parent.right; leftMargin: th.g2; rightMargin: th.g1; verticalCenter: parent.verticalCenter }
                                        height: 1
                                        color: th.ruleDark
                                    }
                                }
                                Text {
                                    width: parent.width
                                    height: 34                                  // two lines, fixed
                                    elide: Text.ElideRight
                                    verticalAlignment: Text.AlignTop
                                    maximumLineCount: 2
                                    wrapMode: Text.WordWrap
                                    text: root.contextText()
                                    color: th.t40
                                    font.family: th.fMono
                                    font.pixelSize: th.pxMeta
                                    lineHeight: 1.45
                                }
                            }
                        }

                        // list
                        Item {
                            id: listCol
                            width: parent.width - rail.width - prevCol.width
                            height: parent.height
                            // tail geometry, declared once: the column header and
                            // the row delegate both read these, so they cannot drift
                            readonly property int wSize: 58
                            readonly property int wMtime: 118
                            readonly property int wMeta: 220
                            readonly property int colGap: th.g3
                            readonly property int tailW: root.section === 0
                                ? (wSize + colGap + wMtime) : wMeta
                            // rows live below the back row + the column header
                            readonly property int topPad: (root.section === 0 ? upRow.height + th.g2 : 0) + colHead.height
                            readonly property int rowsY: topPad + th.g2

                            // ‹- back affordance (files only) — visible escape
                            // the bare-Backspace contract never surfaced. Shows
                            // the real back target (history pop or parent dir);
                            // greyed at "/" with an empty stack.
                            Rectangle {
                                id: upRow
                                anchors { top: parent.top; left: parent.left; right: parent.right; margins: th.g3 }
                                height: root.section === 0 ? 28 : 0
                                visible: root.section === 0
                                radius: th.rRow
                                border.width: 1
                                border.color: upMouse.containsMouse ? th.accentDim : "transparent"
                                color: root.canUp()
                                    ? (upMouse.containsMouse ? Qt.rgba(255, 255, 255, 0.05) : Qt.rgba(255, 255, 255, 0.022))
                                    : "transparent"
                                Behavior on color {
                                    NumberAnimation {
                                        duration: Style.dur.snap
                                        easing.type: Style.easing.standard
                                    }
                                }
                                Text {
                                    anchors { left: parent.left; leftMargin: th.g3; verticalCenter: parent.verticalCenter }
                                    width: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    text: "‹"
                                    color: root.canUp() ? th.accent : th.t40
                                    font.family: th.fDisp
                                    font.pixelSize: 13
                                }
                                Text {
                                    anchors { left: parent.left; leftMargin: th.g3 + 12 + th.g2; verticalCenter: parent.verticalCenter }
                                    text: root.canUp() ? "up to " + root.upLabel() : "at root"
                                    color: root.canUp() ? th.t70 : th.t40
                                    font.family: th.fMono
                                    font.pixelSize: th.pxRow - 1
                                }
                                // the resolved target, right-aligned — the label
                                // alone doesn't say where "up" lands
                                Text {
                                    anchors { left: parent.left; leftMargin: 190; right: keyTag.left; rightMargin: th.g2; verticalCenter: parent.verticalCenter }
                                    elide: Text.ElideMiddle
                                    visible: root.canUp()
                                    text: root.backTargetPath()
                                    color: th.t40
                                    font.family: th.fMono
                                    font.pixelSize: th.pxMicro
                                }
                                Rectangle {
                                    id: keyTag
                                    anchors { right: parent.right; rightMargin: th.g2; verticalCenter: parent.verticalCenter }
                                    width: 34
                                    height: 16
                                    radius: th.rKey
                                    color: Qt.rgba(0, 0, 0, 0.34)
                                    border.width: 1
                                    border.color: Qt.rgba(0, 0, 0, 0.5)
                                    Text {
                                        anchors.centerIn: parent
                                        text: "BKSP"
                                        color: th.t40
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxKey
                                        font.letterSpacing: 1.0
                                    }
                                }
                                MouseArea {
                                    id: upMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: root.canUp()
                                    onClicked: root.filesUp()
                                }
                            }

                            // column header — every section gets one, so the tail
                            // cells stop being unlabelled loose text
                            Item {
                                id: colHead
                                anchors { top: parent.top; topMargin: upRow.height + th.g2; left: parent.left; right: parent.right }
                                height: 20
                                Text {
                                    // 14 row gutter + 16 glyph + 12 gap
                                    anchors { left: parent.left; leftMargin: 42; verticalCenter: parent.verticalCenter }
                                    text: "NAME"
                                    color: th.t40
                                    font.family: th.fDisp
                                    font.pixelSize: th.pxColHead
                                    font.letterSpacing: 2.2
                                }
                                // mirrors the delegate's tail block exactly
                                Item {
                                    // matches rowInner's 14px right gutter
                                    anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                                    width: listCol.tailW
                                    height: parent.height
                                    Text {
                                        id: headSize
                                        anchors { left: parent.left; right: headMtime.left; rightMargin: listCol.colGap; verticalCenter: parent.verticalCenter }
                                        horizontalAlignment: Text.AlignRight
                                        text: "SIZE"
                                        color: th.t40
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxColHead
                                        font.letterSpacing: 2.2
                                    }
                                    Text {
                                        id: headMtime
                                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                        width: listCol.wMtime
                                        elide: Text.ElideRight
                                        text: "MODIFIED"
                                        color: th.t40
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxColHead
                                        font.letterSpacing: 2.2
                                    }
                                    Text {
                                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                                        visible: root.section !== 0
                                        horizontalAlignment: Text.AlignRight
                                        elide: Text.ElideRight
                                        text: root.sectionColTitle()
                                        color: th.t40
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxColHead
                                        font.letterSpacing: 2.2
                                    }
                                }
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                    height: 1
                                    color: th.ruleDark
                                }
                            }

                            ListView {
                                id: listView
                                anchors {
                                    left: parent.left; right: parent.right
                                    top: parent.top; topMargin: listCol.rowsY
                                    bottom: parent.bottom; bottomMargin: th.g3
                                }
                                clip: true
                                model: root.rows
                                currentIndex: root.sel
                                spacing: 4
                                delegate: Rectangle {
                                    id: rowRect
                                    required property int index
                                    required property var modelData
                                    readonly property bool active: rowRect.index === root.sel
                                    width: listView.width
                                    height: 32
                                    radius: th.rRow
                                    // constant 1px: a 0/1 border switch shifted the
                                    // whole row 1px on every selection change
                                    border.width: 1
                                    border.color: rowMouse.containsMouse
                                        ? (rowRect.active ? th.accent : th.accent2Dim)
                                        : (rowRect.active ? th.accentDim : "transparent")
                                    color: rowMouse.containsMouse
                                        ? th.wash
                                        : (rowRect.active ? Qt.rgba(255, 255, 255, 0.05) : "transparent")
                                    Behavior on color {
                                        NumberAnimation {
                                            duration: Style.dur.snap
                                            easing.type: Style.easing.standard
                                        }
                                    }
                                    Rectangle {
                                        anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 1 }
                                        width: 2
                                        height: 18
                                        radius: 1
                                        color: th.accent
                                        opacity: rowRect.active ? 1 : 0
                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: Style.dur.snap
                                                easing.type: Style.easing.standard
                                            }
                                        }
                                    }
                                    Item {
                                        id: rowInner
                                        anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                                        Text {
                                            id: rowGlyph
                                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                                            width: 16
                                            horizontalAlignment: Text.AlignHCenter
                                            text: rowRect.modelData.icon
                                            color: root.section === 0 ? root.fileIconColor(rowRect.modelData)
                                                : root.rowIconColor(rowRect.modelData)
                                            font.family: th.fMono
                                            font.pixelSize: 11
                                        }
                                        // tail block: anchored, not a hand-summed Row
                                        Item {
                                            id: rowTail
                                            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                            width: listCol.tailW
                                            height: parent.height
                                            Text {
                                                id: sizeCol
                                                anchors { left: parent.left; right: mtCol.left; rightMargin: listCol.colGap; verticalCenter: parent.verticalCenter }
                                                visible: root.section === 0
                                                horizontalAlignment: Text.AlignRight
                                                elide: Text.ElideRight
                                                text: rowRect.modelData && rowRect.modelData.sizeTxt !== undefined
                                                    ? rowRect.modelData.sizeTxt : ""
                                                color: rowRect.active ? th.t55 : th.t40
                                                font.family: th.fMono
                                                font.pixelSize: th.pxCell
                                            }
                                            Text {
                                                id: mtCol
                                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                                visible: root.section === 0
                                                width: listCol.wMtime
                                                elide: Text.ElideRight
                                                text: rowRect.modelData && rowRect.modelData.mtimeTxt !== undefined
                                                    ? rowRect.modelData.mtimeTxt : ""
                                                color: rowRect.active ? th.t55 : th.t40
                                                font.family: th.fMono
                                                font.pixelSize: th.pxCell
                                            }
                                            Text {
                                                anchors.fill: parent
                                                visible: root.section !== 0
                                                horizontalAlignment: Text.AlignRight
                                                elide: Text.ElideRight
                                                text: rowRect.modelData
                                                    && rowRect.modelData.meta !== undefined
                                                    && rowRect.modelData.meta !== ""
                                                    ? rowRect.modelData.meta : root.ung()
                                                color: rowRect.active ? th.t55 : th.t40
                                                font.family: th.fMono
                                                font.pixelSize: th.pxCell
                                            }
                                        }
                                        Text {
                                            anchors {
                                                left: rowGlyph.right; leftMargin: 12
                                                right: rowTail.left; rightMargin: 12
                                                verticalCenter: parent.verticalCenter
                                            }
                                            elide: Text.ElideRight
                                            textFormat: Text.RichText
                                            text: root.highlightName(rowRect.modelData.name)
                                            color: (rowRect.active || rowMouse.containsMouse) ? th.txt : th.t70
                                            font.family: th.fMono
                                            font.pixelSize: th.pxRow
                                        }
                                    }
                                    MouseArea {
                                        id: rowMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: { root.sel = rowRect.index; root.refreshPreview(); root.primaryAction() }
                                    }
                                }
                                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                                Connections {
                                    function onRowsRevChanged() {
                                        listView.currentIndex = root.sel
                                        listView.positionViewAtIndex(root.sel, ListView.Contain)
                                    }
                                    target: root
                                }
                            }

                            // two-line empty state, centered in the rows region
                            // (was one dim line centered over the back row too)
                            Item {
                                anchors {
                                    left: parent.left; right: parent.right
                                    top: parent.top; topMargin: listCol.rowsY
                                    bottom: parent.bottom; bottomMargin: th.g3
                                }
                                visible: root.rows.length === 0
                                Column {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - th.g5 * 2
                                    spacing: th.g2
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: "◇"
                                        color: th.t40
                                        font.family: th.fMono
                                        font.pixelSize: 20
                                    }
                                    Text {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: root.emptyTitle()
                                        color: th.t55
                                        font.family: th.fDisp
                                        font.pixelSize: th.pxTitle
                                        font.letterSpacing: 2.6
                                    }
                                    Text {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: root.emptySub()
                                        color: th.t40
                                        font.family: th.fMono
                                        font.pixelSize: th.pxMeta
                                    }
                                }
                            }
                        }

                        // preview
                        Item {
                            id: prevCol
                            width: 400
                            height: parent.height
                            Rectangle { anchors.left: parent.left; height: parent.height; width: 1; color: th.ruleDark }
                            Rectangle { anchors.left: parent.left; anchors.leftMargin: 1; height: parent.height; width: 1; color: th.ruleLit }

                            Column {
                                id: prevBody
                                anchors { fill: parent; margins: th.g3 }
                                spacing: th.g2

                                // title — previewTitle was written by every
                                // refreshPreview() branch and never rendered, so
                                // the pane had no heading at all
                                Item {
                                    id: prevHead
                                    width: parent.width
                                    height: 20
                                    Text {
                                        anchors { left: parent.left; right: prevKind.left; rightMargin: th.g2; verticalCenter: parent.verticalCenter }
                                        elide: Text.ElideRight
                                        text: root.previewTitle !== "" ? root.previewTitle : root.ung()
                                        color: th.txt
                                        font.family: th.fMono
                                        font.pixelSize: th.pxRow - 1
                                    }
                                    Rectangle {
                                        id: prevKind
                                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                        width: kindTxt.implicitWidth + 12
                                        height: 15
                                        radius: th.rKey
                                        color: Qt.rgba(143 / 255, 216 / 255, 232 / 255, 0.09)
                                        border.width: 1
                                        border.color: Qt.rgba(143 / 255, 216 / 255, 232 / 255, 0.22)
                                        Text {
                                            id: kindTxt
                                            anchors.centerIn: parent
                                            text: root.previewKind(root.selRow())
                                            color: th.ice
                                            font.family: th.fDisp
                                            font.pixelSize: th.pxKey
                                            font.letterSpacing: 1.4
                                        }
                                    }
                                    Rectangle {
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                        height: 1
                                        color: th.ruleDark
                                    }
                                }

                                // glass readout
                                Rectangle {
                                    id: pvWell
                                    width: parent.width
                                    height: Math.max(0, prevBody.height - prevHead.height - detailRow.height
                                        - actsFlow.implicitHeight - 3 * prevBody.spacing)
                                    radius: th.rGlass
                                    border.width: 1
                                    border.color: th.glassLine
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "#0f1318" }
                                        GradientStop { position: 1.0; color: "#141920" }
                                    }
                                    // an unselected well is a tall blank void;
                                    // name the state instead of showing nothing
                                    Column {
                                        anchors.centerIn: parent
                                        width: parent.width - th.g4 * 2
                                        spacing: th.g2
                                        visible: root.previewText === ""
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            text: "NO SELECTION"
                                            color: th.t40
                                            font.family: th.fDisp
                                            font.pixelSize: th.pxTitle
                                            font.letterSpacing: 2.6
                                        }
                                        Text {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            elide: Text.ElideRight
                                            text: root.rows.length === 0 ? root.emptySub() : "↑↓ move · ENTER open"
                                            color: th.t40
                                            font.family: th.fMono
                                            font.pixelSize: th.pxMeta
                                        }
                                    }
                                    // recessed screen chrome: shade on top,
                                    // light along the bottom inner edge
                                    Rectangle {
                                        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: pvWell.radius; rightMargin: pvWell.radius }
                                        height: 1
                                        color: Qt.rgba(0, 0, 0, 0.55)
                                    }
                                    Rectangle {
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: pvWell.radius; rightMargin: pvWell.radius }
                                        height: 1
                                        color: Qt.rgba(0.92, 0.96, 0.99, 0.05)
                                    }
                                    Flickable {
                                        id: pvFlick
                                        anchors { fill: parent; margins: th.g3 }
                                        contentWidth: width
                                        contentHeight: pvText.implicitHeight
                                        clip: true
                                        boundsBehavior: Flickable.StopAtBounds
                                        Text {
                                            id: pvText
                                            width: parent.width - 4
                                            wrapMode: Text.Wrap
                                            // styled by root.previewRich — `#`
                                            // command lines ice, key/value pairs
                                            // split, parenthesised notes recede
                                            text: root.previewRich(root.previewText)
                                            color: th.t70
                                            font.family: th.fMono
                                            font.pixelSize: th.pxCell + 1
                                            lineHeight: 1.5
                                            textFormat: Text.RichText
                                        }
                                        // slim scroll indicator: the readout was
                                        // silently clipped with no affordance
                                        Rectangle {
                                            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                                            width: 2
                                            radius: 1
                                            color: Qt.rgba(143 / 255, 216 / 255, 232 / 255, 0.30)
                                            visible: pvFlick.contentHeight > pvFlick.height
                                            opacity: pvFlick.moving ? 0.9 : 0.45
                                            Behavior on opacity {
                                                NumberAnimation {
                                                    duration: Style.dur.snap
                                                    easing.type: Style.easing.standard
                                                }
                                            }
                                            Rectangle {
                                                width: parent.width
                                                height: Math.max(18, parent.height * (pvFlick.height / Math.max(1, pvFlick.contentHeight)))
                                                radius: 1
                                                color: th.ice
                                                y: (parent.height - height) * (pvFlick.contentY / Math.max(1, pvFlick.contentHeight - pvFlick.height))
                                            }
                                        }
                                    }
                                }

                                // detail line — a footer rule, not another field
                                Item {
                                    id: detailRow
                                    width: parent.width
                                    height: 20
                                    Rectangle {
                                        anchors { left: parent.left; right: parent.right; top: parent.top }
                                        height: 1
                                        color: th.ruleDark
                                    }
                                    Text {
                                        anchors {
                                            left: parent.left; right: pvInfo2.left; rightMargin: th.g2
                                            verticalCenter: parent.verticalCenter
                                        }
                                        elide: Text.ElideMiddle
                                        text: root.previewInfo !== "" ? root.previewInfo : root.ung()
                                        color: th.t55
                                        font.family: th.fMono
                                        font.pixelSize: th.pxMeta
                                    }
                                    Text {
                                        id: pvInfo2
                                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                        text: root.rows.length > 0 ? (root.sel + 1) + "/" + root.rows.length : root.ung()
                                        color: th.t40
                                        font.family: th.fMono
                                        font.pixelSize: th.pxMicro
                                    }
                                }

                                // action row — Flow, not an even split.
                                // Four chips at (372-27)/4 = 86.2px could not hold
                                // "TERMINAL HERE" (measured 90.0px), so the label
                                // spilled into its neighbour. Intrinsic-width chips
                                // wrap instead of overflowing.
                                Flow {
                                    id: actsFlow
                                    width: parent.width
                                    spacing: th.g2
                                    Repeater {
                                        model: root.actions
                                        delegate: Rectangle {
                                            id: actChip
                                            required property int index
                                            required property var modelData
                                            readonly property bool primary: actChip.index === 0
                                            width: actLbl.implicitWidth + actKey.width + th.g5 + th.g3
                                            height: 30
                                            radius: th.rCtl
                                            border.width: 1
                                            border.color: actChip.primary ? th.accentDim
                                                : (actMouse.containsMouse ? th.ice : Qt.rgba(0, 0, 0, 0.5))
                                            color: actChip.primary
                                                ? Qt.rgba(200 / 255, 243 / 255, 29 / 255, 0.09)
                                                : (actMouse.containsMouse ? Qt.rgba(255, 255, 255, 0.045) : Qt.rgba(255, 255, 255, 0.022))
                                            Behavior on color {
                                                NumberAnimation {
                                                    duration: Style.dur.snap
                                                    easing.type: Style.easing.standard
                                                }
                                            }
                                            Text {
                                                id: actLbl
                                                anchors { left: parent.left; leftMargin: th.g3; verticalCenter: parent.verticalCenter }
                                                elide: Text.ElideRight
                                                text: actChip.modelData.label
                                                color: actChip.primary ? th.accent : th.t70
                                                font.family: th.fMono
                                                font.pixelSize: th.pxCell
                                            }
                                            // the key as a real cap, not a 2nd line
                                            Rectangle {
                                                id: actKey
                                                anchors { right: parent.right; rightMargin: th.g2; verticalCenter: parent.verticalCenter }
                                                width: keyTxt.implicitWidth + 10
                                                height: 15
                                                radius: th.rKey
                                                color: actChip.primary ? Qt.rgba(200 / 255, 243 / 255, 29 / 255, 0.12)
                                                    : Qt.rgba(0, 0, 0, 0.36)
                                                border.width: 1
                                                border.color: actChip.primary ? th.accentDim : Qt.rgba(0, 0, 0, 0.55)
                                                Text {
                                                    id: keyTxt
                                                    anchors.centerIn: parent
                                                    text: actChip.modelData.key
                                                    color: actChip.primary ? th.accent : th.t40
                                                    font.family: th.fDisp
                                                    font.pixelSize: th.pxKey
                                                    font.letterSpacing: 1.2
                                                }
                                            }
                                            MouseArea {
                                                id: actMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                onClicked: root.runAction(actChip.modelData.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ---------- footer ----------
                    Item {
                        id: footBar
                        width: parent.width
                        height: 44
                        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: th.ruleLit }
                        Rectangle { anchors.top: parent.top; width: parent.width; anchors.topMargin: 1; height: 1; color: th.ruleDark }

                        // left: keycap legend. Anchoring both edges on a Row does
                        // not right-align its last child, so the count used to
                        // float mid-bar; it now lives in its own right-anchored
                        // item and the legend is free to elide.
                        Row {
                            id: legend
                            anchors { left: parent.left; leftMargin: th.g5; right: footCount.left; rightMargin: th.g4; verticalCenter: parent.verticalCenter }
                            height: parent.height
                            spacing: th.g4
                            Repeater {
                                model: [
                                    { k: "↑↓", v: "MOVE" },
                                    { k: "ENTER", v: "OPEN / DRILL" },
                                    { k: "BKSP", v: "UP" },
                                    { k: "/", v: "SEARCH" },
                                    { k: "ESC", v: "CLEAR / CLOSE" }
                                ]
                                delegate: Row {
                                    id: legItem
                                    required property var modelData
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: th.g2
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: legKey.implicitWidth + 10
                                        height: 16
                                        radius: th.rKey
                                        color: Qt.rgba(0, 0, 0, 0.34)
                                        border.width: 1
                                        border.color: Qt.rgba(0, 0, 0, 0.5)
                                        Text {
                                            id: legKey
                                            anchors.centerIn: parent
                                            text: legItem.modelData.k
                                            color: th.ice
                                            font.family: th.fDisp
                                            font.pixelSize: th.pxKey
                                            font.letterSpacing: 1.2
                                        }
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: legItem.modelData.v
                                        color: th.t55
                                        font.family: th.fMono
                                        font.pixelSize: th.pxMeta
                                    }
                                }
                            }
                        }
                        Text {
                            id: footCount
                            anchors { right: parent.right; rightMargin: th.g5; verticalCenter: parent.verticalCenter }
                            text: root.countText()
                            color: th.t40
                            font.family: th.fMono
                            font.pixelSize: th.pxMeta
                        }
                    }
                }

                // Static scanlines — one paint, no repaint triggers. Painted only
                // in the two chrome bands: at 0.5 × 0.09 over the whole card
                // the lines crossed every 11px glyph and read as noise, not
                // texture. The bezel keeps the cue; the reading surfaces stay
                // clean.
                Canvas {
                    id: scan
                    anchors.fill: parent
                    opacity: 0.5
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        ctx.fillStyle = "rgba(0,0,0,0.09)"
                        var top = headBar.height
                        var floor = height - footBar.height
                        for (var y = 0; y < height; y += 3) {
                            if (y < top || y >= floor) ctx.fillRect(0, y, width, 1)
                        }
                    }
                    Connections {
                        target: card
                        function onWidthChanged() { scan.requestPaint() }
                        function onHeightChanged() { scan.requestPaint() }
                    }
                }
            }
        }
    }

    // Dismiss twins on the other outputs — Exclusive focus routes every
    // pointer to this surface, so clicks elsewhere need their own catcher.
    Variants {
        model: root.navOpen ? Quickshell.screens : []
        delegate: Component {
            PanelWindow {
                required property var modelData
                screen: modelData
                visible: root.navOpen && !!navWin.screen && modelData.name !== navWin.screen.name
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                anchors { top: true; bottom: true; left: true; right: true }
                WlrLayershell.namespace: "nexuslink-nav-dismiss"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onPressed: root.navOpen = false
                }
            }
        }
    }

    // ======================================================================
    // Header/footer text builders
    // ======================================================================
    function crumbText() {
        var s = "<b><span style='color:" + th.accentCss + "'>" + sectionNames[section] + "</span></b>"
            + " <span style='color:" + th.t40Css + "'>/</span> "
        switch (section) {
        case 0:
            var segs = String(filesDir).split("/").filter(function (p) { return p !== "" })
            if (segs.length === 0) return s + "<span style='color:" + th.txtCss + "'>/</span>"
            return s + segs.map(function (p) { return "<span style='color:" + th.t55Css + "'>" + escHtml(p) + "</span>" })
                .join(" <span style='color:" + th.t40Css + "'>›</span> ")
        case 1: return s + "<span style='color:" + th.t55Css + "'>by cpu</span>"
        case 2: return s + "<span style='color:" + th.t55Css + "'>topology registry</span>"
        case 3: return s + "<span style='color:" + th.t55Css + "'>live sessions</span>"
        case 4: return s + "<span style='color:" + th.t55Css + "'>~/projects</span>"
        default: return s + "<span style='color:" + th.t55Css + "'>provider ledger</span>"
        }
    }

    function contextText() {
        switch (section) {
        case 0: return filesDir + " · " + rows.length + " items live"
            + (dirReadable ? "" : " · NO READ ACCESS")
            + (showHiddenFiles ? " · hidden on" : "")
            + " · " + mountActive
        case 1: return rows.length + " processes · 3 s pulse"
        case 2: return root._T ? "Topology.nodes · " + rows.length + " nodes" : "topology: unavailable"
        // absent keys render "—" — a "?" or a defaulted 0 would be a
        // fabricated reading, not an honest one
        case 3: return stat("agents_procs", "—") + " agent procs · " + stat("devsess_count", "—") + " devin locks"
        case 4: return rows.length + " repos · ~/projects · 60 s pulse"
        default: return (tokData.updated ? "ledger updated " + tokData.updated : "ledger: no file") + " · " + rows.length + " providers"
        }
    }

    function countText() {
        switch (section) {
        case 0: return rows.length + " items · " + filesDir
        case 1: return rows.length + " processes · sorted by cpu"
        case 2: return rows.length + " nodes"
        case 3: return rows.length + " rows · stats stream"
        case 4: return rows.length + " repos · ~/projects"
        default: return rows.length + " providers · ledger"
        }
    }

    // the one-line empty sentence this replaced is now split across
    // emptyTitle() (state) + emptySub() (detail), so the pane can show both
    // without truncating either

    // name with the filter substring highlighted in acid
    function highlightName(name) {
        var n = escHtml(name)
        if (query === "") return n
        var i = String(name).toLowerCase().indexOf(query.toLowerCase())
        if (i < 0) return n
        return escHtml(String(name).substring(0, i))
            + "<span style='color:" + th.accentCss + ";font-weight:600'>"
            + escHtml(String(name).substr(i, query.length)) + "</span>"
            + escHtml(String(name).substring(i + query.length))
    }

    // ---------- row chrome helpers ----------
    // The type glyph only earns its place if the ink says something: folders
    // and media read cool, runnables and archives read hot, text is neutral.
    function rowIconColor(r) {
        if (!r) return th.t40
        switch (r.kind) {
        case "dir": return th.ice
        case "file": return th.accent
        case "proc": return th.ice
        case "dev": return th.ice
        case "agent": return th.accent
        case "devsess": return th.ice
        case "tmux": return th.t55
        case "repo": return th.t55
        case "tok": return th.ice
        }
        return th.t40
    }
    // file glyph ink, by detected type (dir handled by kind)
    function fileIconColor(r) {
        if (!r || !r.data) return th.t40
        switch (r.data.ftype) {
        case "image": case "video": case "audio": return th.ice
        case "archive": return th.warn
        case "exec": return th.accent
        case "code": return th.t70
        case "doc": return th.t55
        }
        return th.t40
    }
    // per-section right-hand column headers — every section gets a real header
    function sectionColTitle() {
        switch (section) {
        case 0: return "SIZE"
        case 1: return "CPU · MEM"
        case 2: return "VITAL"
        case 3: return "LOAD"
        case 4: return "STATE · REL · BRANCH"
        default: return "TODAY"
        }
    }
    function sectionColWide() { return section === 4 }   // branch names need room
    // preview title badge — the kind, engraved; "—" when it cannot be known
    function previewKind(r) {
        if (!r) return "—"
        switch (r.kind) {
        case "dir": return "DIRECTORY"
        case "file": return r.data && r.data.ftype ? String(r.data.ftype).toUpperCase() : "FILE"
        case "proc": return "PROCESS"
        case "dev": return "NODE"
        case "agent": return "AGENT"
        case "devsess": return "SESSION"
        case "tmux": return "TMUX"
        case "repo": return "REPO"
        case "tok": return "LEDGER"
        }
        return "—"
    }

    // ---------- styled preview ----------
    // The readout is the largest surface in the card; flat mono made every line
    // the same weight. Now: `#` command lines read ice, `key␣␣value` pairs get
    // a dim key against a lit value, parenthesised notes recede. Everything is
    // escaped; only the spans this function adds are markup. A raw "\n" is not
    // a reliable break in QTextDocument, so lines join with <br/>.
    readonly property int previewStyleBytes: 16384
    function previewRich(text) {
        var raw = String(text === undefined || text === null ? "" : text)
        if (raw === "") return ""
        var head = raw.substring(0, root.previewStyleBytes)
        var tail = raw.substring(root.previewStyleBytes)
        var lines = head.split("\n")
        var out = []
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i]
            if (ln === "") { out.push(""); continue }
            if (ln.charAt(0) === "#") {
                out.push("<span style='color:" + th.iceCss + "'>" + escHtml(ln) + "</span>")
                continue
            }
            var m = ln.match(/^([A-Za-z][A-Za-z0-9 _-]{0,13}?)(\s{2,})(\S.*)$/)
            if (m) {
                out.push("<span style='color:" + th.t40Css + "'>" + escHtml(m[1]) + "</span>"
                    + escHtml(m[2])
                    + "<span style='color:" + th.t70Css + "'>" + escHtml(m[3]) + "</span>")
                continue
            }
            if (ln.charAt(0) === "(") {
                out.push("<i><span style='color:" + th.t40Css + "'>" + escHtml(ln) + "</span></i>")
                continue
            }
            out.push("<span style='color:" + th.t70Css + "'>" + escHtml(ln) + "</span>")
        }
        var html = out.join("<br/>")
        if (tail !== "")
            html += "<br/><span style='color:" + th.t55Css + "'>" + escHtml(tail) + "</span>"
        return html
    }

    // ---------- two-line empty state ----------
    // One dim line in the middle of a column reads like a failed load. Split
    // it: what the state IS, then the detail. Absent data stays "—".
    function emptyTitle() {
        switch (section) {
        case 0:
            if (pendingLoad || !folderMatchesDir() || filesModel.status === FolderListModel.Loading) return "LOADING"
            if (!dirReadable) return "PERMISSION DENIED"
            return query !== "" ? "NO MATCHES" : "EMPTY DIRECTORY"
        case 1: return "READING ps"
        case 2: return root._T ? "NO TOPOLOGY NODES" : "TOPOLOGY UNAVAILABLE"
        case 3: return "NO AGENT KEYS IN THIS FRAME"
        case 4: return "SCANNING ~/projects"
        default: return "LEDGER NOT WRITTEN YET"
        }
    }
    function emptySub() {
        switch (section) {
        case 0:
            if (pendingLoad || !folderMatchesDir() || filesModel.status === FolderListModel.Loading) return filesDir
            if (!dirReadable) return root.ung() + " — listing suppressed, dirGuard refused the descend"
            return query !== "" ? "query “" + query + "” · esc clears" : filesDir
        case 1: return "one sample per 3 s"
        case 2: return root._T ? "Topology.nodes is empty" : "Topology singleton not linked"
        case 3: return "awaiting the next collector frame"
        case 4: return "one git pass per 60 s"
        default: return tokPath
        }
    }
}