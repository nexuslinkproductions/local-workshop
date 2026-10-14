pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import ".."

// AppModel.qml — installed-app catalogue + launch accounting for the M1
// APP-DL dial / APP-RK ladder / APP-IX index. The enumerate/decode/launch/
// use-count machinery is the AppGrid.qml contract lifted wholesale:
//   * one FolderListModel per applications root (user shadows system on
//     identical desktop-file-ids), Hidden/NoDisplay/Type!=Application skipped
//   * Name/Icon/Exec/Categories through DesktopEntries.byId first, bounded
//     FileView INI parse only when the model misses
//   * launch is argv-only gtk-launch <id>; every launch bumps a per-id
//     counter persisted to ~/.config/omarchy/nexuslink/appuse.json behind a
//     debounce timer (same FileView/atomicWrites mechanism)
// Zero-size data item — the views live in AppDial/AppLadder/AppIndex.
Item {
    id: root
    width: 0
    height: 0

    // ------------------------------------------------------------- outputs
    property var apps: []            // [{id,name,icon,meta,exec,terminal,cats,group}]
    readonly property int appCount: apps.length
    property var counts: ({})        // desktop-id -> launches (appuse.json v1)
    property bool countsLoaded: false
    readonly property int trackedCount: {
        var n = 0;
        for (var k in counts)
            if (Number(counts[k]) > 0) n++;
        return n;
    }
    readonly property int totalLaunches: {
        var s = 0;
        for (var k in counts)
            s += Math.max(0, Number(counts[k]) || 0);
        return s;
    }
    // tracked ids ranked by launches desc, then alpha — the APP-RK order
    readonly property var ranked: {
        var out = [];
        for (var k in counts) {
            var n = Number(counts[k]);
            if (isFinite(n) && n > 0)
                out.push({ "id": k, "n": n });
        }
        out.sort(function (a, b) { return b.n - a.n || (a.id < b.id ? -1 : 1); });
        return out;
    }
    property string query: ""
    // apps matching query, group-ranked then alpha (empty query = all, alpha)
    readonly property var filtered: {
        var q = query.toLowerCase();
        var out = [];
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i];
            if (q === "" || a.name.toLowerCase().indexOf(q) >= 0
                    || a.id.toLowerCase().indexOf(q) >= 0
                    || a.meta.toLowerCase().indexOf(q) >= 0
                    || a.exec.toLowerCase().indexOf(q) >= 0)
                out.push(a);
        }
        if (q === "")
            out.sort(byName);
        else
            out.sort(function (a, b) {
                var d = groupRank(a.group) - groupRank(b.group);
                return d !== 0 ? d : byName(a, b);
            });
        return out;
    }
    // category tallies for APP-IX: [{code,group,n,ex}] sorted by size desc
    readonly property var catRows: {
        var map = {};
        for (var i = 0; i < apps.length; i++) {
            var g = apps[i].group;
            if (map[g] === undefined)
                map[g] = { "group": g, "n": 0, "ex": [] };
            map[g].n++;
            if (map[g].ex.length < 2)
                map[g].ex.push(apps[i].name);
        }
        var out = [];
        for (var k in map)
            out.push(map[k]);
        out.sort(function (a, b) {
            if (a.group === "OTHER") return 1;
            if (b.group === "OTHER") return -1;
            return b.n - a.n;
        });
        for (var j = 0; j < out.length; j++)
            out[j].code = "CAT-" + (j + 1 < 10 ? "0" : "") + (j + 1);
        return out;
    }

    readonly property string useStateDir:
        Quickshell.env("HOME") + "/.config/omarchy/nexuslink/"
    readonly property string useStatePath: useStateDir + "appuse.json"

    // ------------------------------------------------------------ helpers
    function byName(a, b) {
        return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    }
    function useCount(id) {
        var n = Number(counts[String(id)]);
        return isFinite(n) && n > 0 ? n : 0;
    }
    function entryFor(id) {
        for (var i = 0; i < apps.length; i++)
            if (apps[i].id === id)
                return apps[i];
        return null;
    }

    // freedesktop Categories -> HUD group (AppGrid contract, 9 groups)
    function groupOf(cats) {
        if (!cats || cats.length === undefined || cats.length === 0)
            return "OTHER";
        var set = {};
        for (var i = 0; i < cats.length; i++)
            set[String(cats[i])] = true;
        if (set["Game"]) return "GAMES";
        if (set["Development"]) return "DEV";
        if (set["Graphics"]) return "GRAPHICS";
        if (set["AudioVideo"] || set["Audio"] || set["Video"]
                || set["Music"] || set["Player"] || set["Recorder"]
                || set["TV"]) return "MEDIA";
        if (set["Network"]) return "NET";
        if (set["Office"]) return "OFFICE";
        if (set["Settings"] || set["System"]) return "SYSTEM";
        if (set["Utility"]) return "TOOLS";
        return "OTHER";
    }
    readonly property var groupRanks: ({
            "DEV": 1, "TOOLS": 2, "MEDIA": 3, "GRAPHICS": 4, "GAMES": 5,
            "NET": 6, "OFFICE": 7, "SYSTEM": 8, "OTHER": 9
        })
    function groupRank(g) {
        var r = groupRanks[g];
        return r !== undefined ? r : 9;
    }

    // ------------------------------------------------------ use persistence
    FileView {
        id: useFile
        path: root.useStatePath
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.loadCounts(text())
        onLoadFailed: root.loadCounts("")
    }
    Process {
        id: useMkdirProc
        command: ["mkdir", "-p", root.useStateDir]
        running: false
    }
    Timer {
        id: useSaveTimer
        interval: 400
        repeat: false
        onTriggered: useFile.setText(
            JSON.stringify({ "version": 1, "counts": root.counts }, null, 2) + "\n")
    }
    Timer {
        // absent dir/file is the first-run case — never gate the list on it
        id: useWatchdog
        interval: 1200
        repeat: false
        running: true
        onTriggered: if (!root.countsLoaded) root.countsLoaded = true
    }
    function loadCounts(raw) {
        if (countsLoaded)
            return;
        countsLoaded = true;
        var data = null;
        try {
            data = JSON.parse(String(raw || ""));
        } catch (e) {
            data = null;
        }
        var merged = {};
        for (var k in counts)
            merged[k] = counts[k];
        if (data !== null && typeof data === "object"
                && data.counts !== null && typeof data.counts === "object") {
            for (var ck in data.counts) {
                var n = Math.floor(Number(data.counts[ck]));
                if (isFinite(n) && n > 0)
                    merged[ck] = merged[ck] !== undefined
                            ? Math.max(Number(merged[ck]), n) : n;
            }
        }
        counts = merged;
    }
    function bumpUse(id) {
        var key = String(id);
        var m = {};
        for (var k in counts)
            m[k] = counts[k];
        m[key] = useCount(key) + 1;
        counts = m;
        if (countsLoaded)
            useSaveTimer.restart();
    }

    // ------------------------------------------------------------- launch
    // argv-only gtk-launch, same contract as Navigator.execArgv — the shell
    // resolves the desktop-id including Terminal=true entries.
    function launchId(id) {
        if (!id || id === "")
            return;
        Quickshell.execDetached(["gtk-launch", String(id)]);
        bumpUse(id);
    }
    function launchEntry(a) {
        if (a === null || a === undefined)
            return;
        launchId(a.id);
    }

    // -------------------------------------------------------------- icons
    property var iconCache: ({})
    function iconSrc(icon) {
        if (!icon || icon === "")
            return "";
        if (icon.charAt(0) === "/")
            return "file://" + icon;
        var cached = iconCache[icon];
        if (cached !== undefined)
            return cached;
        var p = "";
        try {
            p = String(Quickshell.iconPath(icon, true) || "");
        } catch (err) {
            p = "";
        }
        iconCache[icon] = p;
        return p;
    }

    // ------------------------------------------------------ catalogue scan
    FolderListModel {
        id: localApps
        folder: "file://" + Quickshell.env("HOME") + "/.local/share/applications"
        nameFilters: ["*.desktop"]
        showDirs: false
        showDotAndDotDot: false
        showHidden: false
        sortField: FolderListModel.Name
        onCountChanged: rebuildTimer.restart()
    }
    FolderListModel {
        id: sysApps
        folder: "file:///usr/share/applications"
        nameFilters: ["*.desktop"]
        showDirs: false
        showDotAndDotDot: false
        showHidden: false
        sortField: FolderListModel.Name
        onCountChanged: rebuildTimer.restart()
    }
    Timer {
        id: rebuildTimer
        interval: 60
        onTriggered: root.rebuildApps()
    }
    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() { rebuildTimer.restart(); }
    }
    FileView {
        id: desktopFile
        path: ""
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        useMkdirProc.running = true;
        Qt.callLater(function () { useFile.reload(); });
        root.rebuildApps();
    }

    function decodeEntry(id, filePath) {
        var e = null;
        try {
            e = DesktopEntries.byId(id);
            if (!e)
                e = DesktopEntries.byId(id.replace(/\.desktop$/, ""));
        } catch (err) {
            e = null;
        }
        if (e) {
            if (e.noDisplay === true)
                return null;
            var cats = [];
            try {
                var ec = e.categories;
                if (ec && ec.length !== undefined)
                    for (var ci = 0; ci < ec.length; ci++)
                        cats.push(String(ec[ci]));
            } catch (err2) {
                cats = [];
            }
            return {
                "id": id,
                "name": (e.name && e.name !== "") ? String(e.name) : id,
                "icon": String(e.icon || ""),
                "meta": String(e.genericName || e.comment || ""),
                "exec": String(e.execString || ""),
                "terminal": e.runInTerminal === true,
                "cats": cats,
                "group": root.groupOf(cats)
            };
        }
        return parseDesktop(id, filePath);
    }

    // Minimal [Desktop Entry] reader — bounded to that group only.
    function parseDesktop(id, filePath) {
        desktopFile.path = filePath;
        var text = desktopFile.text();
        if (!text || text === "")
            return null;
        var inGroup = false;
        var kv = {};
        var lines = String(text).split("\n");
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i];
            if (/^\s*\[/.test(ln)) {
                inGroup = /^\s*\[\s*Desktop Entry\s*\]/.test(ln);
                continue;
            }
            if (!inGroup)
                continue;
            var eq = ln.indexOf("=");
            if (eq <= 0)
                continue;
            var k = ln.substring(0, eq).replace(/\s+$/, "");
            kv[k] = ln.substring(eq + 1).replace(/^\s+|\s+$/g, "");
        }
        if (kv["Type"] !== undefined && kv["Type"] !== "Application")
            return null;
        if (kv["Hidden"] === "true" || kv["NoDisplay"] === "true")
            return null;
        if (kv["Name"] === undefined || kv["Name"] === "")
            return null;
        var cats = [];
        if (kv["Categories"] !== undefined) {
            var parts = String(kv["Categories"]).split(";");
            for (var pi = 0; pi < parts.length; pi++) {
                var p = parts[pi].replace(/^\s+|\s+$/g, "");
                if (p !== "")
                    cats.push(p);
            }
        }
        return {
            "id": id,
            "name": String(kv["Name"]),
            "icon": kv["Icon"] !== undefined ? String(kv["Icon"]) : "",
            "meta": kv["GenericName"] !== undefined ? String(kv["GenericName"])
                    : (kv["Comment"] !== undefined ? String(kv["Comment"]) : ""),
            "exec": kv["Exec"] !== undefined ? String(kv["Exec"]) : "",
            "terminal": kv["Terminal"] === "true",
            "cats": cats,
            "group": root.groupOf(cats)
        };
    }

    function rebuildApps() {
        var seen = {};
        var out = [];
        for (var pass = 0; pass < 2; pass++) {
            var m = pass === 0 ? localApps : sysApps;
            var n = Math.min(m.count, 4000);
            for (var i = 0; i < n; i++) {
                var fname = String(m.get(i, "fileName"));
                if (fname.slice(-8) !== ".desktop")
                    continue;
                if (seen[fname] === true)
                    continue;                   // user root shadows system
                seen[fname] = true;
                var meta = decodeEntry(fname, String(m.get(i, "filePath")));
                if (meta === null)
                    continue;                   // Hidden / NoDisplay / unreadable
                out.push(meta);
            }
        }
        out.sort(byName);
        apps = out;
    }

    // ------------------------------------------------------ pinned targets
    // APP-DL hex crescent: tracked apps first (launch order), then this
    // machine's staple desktop-ids while installed, alpha fill after that —
    // deterministic, and every well is a real launchable entry.
    readonly property var pinnedIds: [
        "devin-desktop.desktop", "hermes-desktop.desktop", "october.desktop",
        "Discord.desktop", "org.gnome.Nautilus.desktop", "chromium.desktop",
        "foot.desktop", "nvim.desktop", "obsidian.desktop", "spotify.desktop",
        "com.obsproject.Studio.desktop", "org.kde.kdenlive.desktop",
        "Docker.desktop", "haze.desktop", "localsend.desktop",
        "Basecamp.desktop"
    ]
    readonly property var pinned: {
        var byId = {};
        for (var i = 0; i < apps.length; i++)
            byId[apps[i].id] = apps[i];
        var used = {};
        var out = [];
        for (var r = 0; r < ranked.length && out.length < 16; r++) {
            var a = byId[ranked[r].id];
            if (a && used[a.id] !== true) {
                used[a.id] = true;
                out.push(a);
            }
        }
        for (var p = 0; p < pinnedIds.length && out.length < 16; p++) {
            var b = byId[pinnedIds[p]];
            if (b && used[b.id] !== true) {
                used[b.id] = true;
                out.push(b);
            }
        }
        for (var s = 0; s < apps.length && out.length < 16; s++) {
            var c = apps[s];
            if (used[c.id] !== true) {
                used[c.id] = true;
                out.push(c);
            }
        }
        return out;
    }

    // index of a desktop-id in the alphabetical catalogue — the dial's
    // APP-0xNN serial and its tick-ring whisker both index into this order
    function alphaIndex(id) {
        for (var i = 0; i < apps.length; i++)
            if (apps[i].id === id)
                return i;
        return -1;
    }
    function serial(id) {
        var i = alphaIndex(id);
        if (i < 0)
            return "APP-" + FuiTokens.unknownGlyph;
        return "APP-0x" + (i < 16 ? "0" : "") + i.toString(16).toUpperCase();
    }
}
