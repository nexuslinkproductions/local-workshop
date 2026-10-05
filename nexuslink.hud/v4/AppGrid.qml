pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// AppGrid.qml — APPS NAVIGATOR pane (lane D3, replaces the HDMI-A-3 patch
// bay). An integrated launcher the operator can actually use:
//
//   * installed .desktop applications, enumerated with one FolderListModel
//     per root (~/.local/share/applications + /usr/share/applications),
//     merged in XDG precedence order — the user root shadows the system
//     root on identical desktop-file-ids, Hidden/NoDisplay entries are
//     skipped.
//   * Name/Icon/Exec decoded through Quickshell's DesktopEntries (byId);
//     entries missing from its model fall back to a bounded FileView read
//     of the [Desktop Entry] group.
//   * live filter while the pane holds keys, Navigator-style query buffer;
//     arrows move selection, Enter launches, Esc clears then releases.
//   * launch is argv-only: Quickshell.execDetached(["gtk-launch", <id>]) —
//     no shell, no string concatenation.
//   * MOST USED: every gtk-launch bumps a per-desktop-id counter persisted
//     to ~/.config/omarchy/nexuslink/appuse.json (same FileView mechanism as
//     HudV4.qml's hud-state-v4.json — mkdir -p Process, FileView read via
//     onLoaded/onLoadFailed, atomicWrites setText behind a debounce timer).
//     Absent/corrupt state degrades to plain grouping, never blocks the list.
//   * CATEGORIES: each entry's freedesktop Categories decode into a HUD
//     group (DEV/GAMES/GRAPHICS/MEDIA/NET/OFFICE/TOOLS/SYSTEM/OTHER) shown as
//     ListView section headers; a type-to-filter query keeps the matching
//     subset's group headers instead of flattening into noise.
//
// The host PanelWindow is WlrKeyboardFocus.None, so the pane arms a
// hyprland_focus_grab_v1 on the workbench surface while the operator wants
// to type. Clicking the filter field takes the grab; Esc (or a click
// outside the window) releases it. All mouse paths work regardless.
//
// Data honesty: an unreadable/absent entry is skipped, never faked; icon
// names that resolve nowhere draw a fallback glyph, not a fake image.

Item {
    id: root

    // Size to the content box this pane is dropped into. GlassPane
    // reparents declared children into its inner `content` item via the
    // `contentData` alias, so a consumer-side `anchors.fill: <paneId>`
    // targets an ancestor — QML discards it ("Cannot anchor to an item
    // that isn't a parent or sibling") and the grid stayed 0×0, leaving
    // body/head/foot heights at -24/0 so the ListView container computed
    // a negative height and rendered zero rows. Bind to the real parent
    // instead; a valid consumer anchor still wins when present.
    width: parent ? parent.width : 0
    height: parent ? parent.height : 0

    // ---- contract module handle (same guard as Workbench.qml) ----
    readonly property var sty: (typeof Style !== "undefined") ? Style : null
    function col(key, fallback) {
        return (root.sty !== null && root.sty.c && root.sty.c[key] !== undefined) ? root.sty.c[key] : fallback;
    }

    QtObject {
        id: pal
        readonly property color edge: root.col("edge", "#2a3138")
        readonly property color accent: root.col("accent", "#c8f31d")
        readonly property color accentDim: root.col("accentDim", Qt.rgba(0.78, 0.95, 0.11, 0.55))
        readonly property color accent2: root.col("accent2", "#8fd8e8")
        readonly property color accent2Dim: root.col("accent2Dim", Qt.rgba(0.56, 0.85, 0.91, 0.55))
        readonly property color unknown: root.col("unknown", "#5a646c")
        readonly property color txt: root.col("txt", "#d9e2ea")
        readonly property color t55: root.col("dim", "#8b959e")
        readonly property color t40: root.col("faint", "#5f686f")
        readonly property color ink: root.col("ink", "#14171c")
        readonly property color well: root.col("recess", "#0d0f13")
        readonly property color wellTop: root.col("recessTop", "#0a0c0f")
        readonly property string fDisp: (root.sty !== null && root.sty.f && root.sty.f.display) ? root.sty.f.display : "Michroma"
        readonly property string fMono: (root.sty !== null && root.sty.f && root.sty.f.mono) ? root.sty.f.mono : "Kode Mono"
        // 4px ramp + the two radii the pane uses, so every margin in the
        // layout below is a token rather than a one-off number
        readonly property int g1: 4
        readonly property int g2: 8
        readonly property int g3: 12
        readonly property int g4: 16
        readonly property int rRow: 6
        readonly property int rKey: 4
        // engraved separator: a lit rule over a shade. A lone 1px black line
        // reads as an aliased crack on this chassis.
        readonly property color ruleLit: Qt.rgba(235 / 255, 245 / 255, 252 / 255, 0.09)
        readonly property color ruleDark: Qt.rgba(0, 0, 0, 0.62)
        // row tail geometry, declared once and read by both the column header
        // and the delegate so the two cannot drift
        readonly property int iconWell: 24
        readonly property int wCount: 34
        readonly property int wMeta: 200
        // selection / hover washes — a selected row is lifted and barred, not
        // outlined in full acid; hover is the sibling met.wash step (cyan 7%)
        readonly property color selFill: Qt.rgba(255, 255, 255, 0.05)
        readonly property color hovFill: Qt.rgba(0.56, 0.85, 0.91, 0.07)
    }

    // ============================================================ model
    property var allApps: []
    property var rows: []
    property string query: ""
    property int sel: 0
    property var iconCache: ({})

    // ---- usage persistence (hud-state-v4.json mechanism, own file) ----
    readonly property string useStateDir:
        Quickshell.env("HOME") + "/.config/omarchy/nexuslink/"
    readonly property string useStatePath: useStateDir + "appuse.json"
    property var useCounts: ({})
    property bool useLoaded: false

    FileView {
        id: useFile
        path: root.useStatePath
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.loadUseCounts(text())
        onLoadFailed: root.loadUseCounts("")
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
        onTriggered: useFile.setText(JSON.stringify(root.buildUseState(), null, 2) + "\n")
    }
    Timer {
        // absent dir/file is the first-run case — never gate the list on it
        id: useWatchdog
        interval: 1200
        repeat: false
        running: true
        onTriggered: if (!root.useLoaded) root.useLoaded = true
    }

    function useCount(id) {
        var n = Number(useCounts[String(id)]);
        return isFinite(n) && n > 0 ? n : 0;
    }
    function loadUseCounts(raw) {
        if (useLoaded)
            return;
        useLoaded = true;
        var data = null;
        try {
            data = JSON.parse(String(raw || ""));
        } catch (e) {
            data = null;
        }
        // only the {version:1, counts:{id:n}} shape is accepted; anything
        // else (absent, corrupt, foreign) means zero counts — alpha order
        var merged = {};
        for (var k in useCounts)
            merged[k] = useCounts[k];
        if (data !== null && typeof data === "object" && data.counts !== null
                && typeof data.counts === "object") {
            for (var ck in data.counts) {
                var n = Math.floor(Number(data.counts[ck]));
                if (isFinite(n) && n > 0)
                    merged[ck] = merged[ck] !== undefined
                            ? Math.max(Number(merged[ck]), n) : n;
            }
        }
        useCounts = merged;
        refilter();
    }
    function buildUseState() {
        return { version: 1, counts: useCounts };
    }
    function bumpUse(id) {
        var key = String(id);
        var m = {};
        for (var k in useCounts)
            m[k] = useCounts[k];
        m[key] = useCount(key) + 1;
        useCounts = m;
        if (useLoaded)
            useSaveTimer.restart();
        refilter();
    }

    // ---- freedesktop Categories → HUD group ----
    function groupOf(cats) {
        if (!cats || cats.length === undefined || cats.length === 0)
            return "OTHER";
        var set = {};
        for (var i = 0; i < cats.length; i++)
            set[String(cats[i])] = true;
        // precedence: a dev-tool game stays a game; mixed tags resolve to
        // the most specific main category first
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
    // display order of groups inside the list (MOST USED leads implicitly)
    readonly property var groupRanks: ({
        "DEV": 1, "TOOLS": 2, "MEDIA": 3, "GRAPHICS": 4, "GAMES": 5,
        "NET": 6, "OFFICE": 7, "SYSTEM": 8, "OTHER": 9
    })
    function groupRank(g) {
        var r = groupRanks[g];
        return r !== undefined ? r : 9;
    }

    // One FolderListModel per applications root. Local is scanned first so
    // it wins the dedupe — mirrors XDG_DATA_DIRS precedence.
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
    // Live refresh when desktop files are installed/removed.
    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() {
            rebuildTimer.restart();
        }
    }

    // Fallback decoder for entries outside DesktopEntries' scan: a single
    // synchronous FileView instance shared by every fallback parse (the
    // brief's "FolderListModel + FileView" path).
    FileView {
        id: desktopFile
        path: ""
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        useMkdirProc.running = true;
        Qt.callLater(function () {
            useFile.reload();
        });
        root.rebuildApps();
    }

    // ---------- decode ----------
    // DesktopEntries first (Name/Icon/Exec/NoDisplay honouring the user's
    // locale); FileView INI parse only when byId misses.
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
                if (ec && ec.length !== undefined) {
                    for (var ci = 0; ci < ec.length; ci++)
                        cats.push(String(ec[ci]));
                }
            } catch (err) {
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
            "meta": kv["GenericName"] !== undefined ? String(kv["GenericName"]) : (kv["Comment"] !== undefined ? String(kv["Comment"]) : ""),
            "exec": kv["Exec"] !== undefined ? String(kv["Exec"]) : "",
            "terminal": kv["Terminal"] === "true",
            "cats": cats,
            "group": root.groupOf(cats)
        };
    }

    // ---------- merge + filter ----------
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
                    continue;                       // user root shadows system
                seen[fname] = true;
                var meta = decodeEntry(fname, String(m.get(i, "filePath")));
                if (meta === null)
                    continue;                       // Hidden / NoDisplay / unreadable
                out.push(meta);
            }
        }
        out.sort(function (a, b) {
            return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
        });
        allApps = out;
        refilter();
    }

    function byName(a, b) {
        return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    }

    function refilter() {
        var q = query.toLowerCase();
        var matched = [];
        for (var i = 0; i < allApps.length; i++) {
            var a = allApps[i];
            if (q === "" || a.name.toLowerCase().indexOf(q) >= 0 || a.id.toLowerCase().indexOf(q) >= 0 || a.meta.toLowerCase().indexOf(q) >= 0 || a.exec.toLowerCase().indexOf(q) >= 0)
                matched.push(a);
        }
        var out = [];
        if (q === "") {
            // unfiltered: MOST USED pinned section (count desc, cap 10 —
            // those ids leave their category group), rest grouped+alpha
            var counted = [];
            for (var mi = 0; mi < matched.length; mi++) {
                if (useCount(matched[mi].id) > 0)
                    counted.push(matched[mi]);
            }
            counted.sort(function (a, b) {
                var d = useCount(b.id) - useCount(a.id);
                return d !== 0 ? d : byName(a, b);
            });
            var top = counted.slice(0, 10);
            var inTop = {};
            for (var ti = 0; ti < top.length; ti++) {
                top[ti].section = "MOST USED";
                inTop[top[ti].id] = true;
            }
            var rest = [];
            for (var ri = 0; ri < matched.length; ri++) {
                if (inTop[matched[ri].id] !== true)
                    rest.push(matched[ri]);
            }
            rest.sort(function (a, b) {
                var rd = root.groupRank(a.group) - root.groupRank(b.group);
                return rd !== 0 ? rd : byName(a, b);
            });
            for (var si = 0; si < rest.length; si++)
                rest[si].section = rest[si].group;
            out = top.concat(rest);
        } else {
            // filtered: matching subset keeps its group headers
            matched.sort(function (a, b) {
                var rd = root.groupRank(a.group) - root.groupRank(b.group);
                return rd !== 0 ? rd : byName(a, b);
            });
            for (var fi = 0; fi < matched.length; fi++)
                matched[fi].section = matched[fi].group;
            out = matched;
        }
        if (out.length > 800)
            out = out.slice(0, 800);
        // one pass for the section headers' tallies — a header that cannot say
        // how many entries it holds is a header that has to be trusted blind
        var tally = {};
        for (var ci = 0; ci < out.length; ci++)
            tally[out[ci].section] = (tally[out[ci].section] || 0) + 1;
        sectionCounts = tally;
        rows = out;
        if (sel > rows.length - 1)
            sel = Math.max(0, rows.length - 1);
    }
    onQueryChanged: refilter()
    // per-section tallies, rebuilt with `rows` (never counted per-header)
    property var sectionCounts: ({})
    function sectionTally(name) {
        var n = sectionCounts[name];
        return n === undefined ? "—" : String(n);
    }
    // a launch count that cannot be read is unknown, not zero
    function useCell(row) {
        if (!row || row.section !== "MOST USED")
            return "";
        var n = useCount(row.id);
        return n > 0 ? n + "×" : "—";
    }

    // ---------- icons ----------
    // Theme name -> resolvable path (cached); absolute paths pass through;
    // unresolvable -> "" so the delegate draws the fallback glyph.
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

    // ---------- launch ----------
    // argv only — no shell, no concatenation (Navigator.qml execArgv
    // contract; gtk-launch resolves the desktop-file-id itself, including
    // Terminal=true entries).
    function execArgv(argv) {
        Quickshell.execDetached(argv);
    }
    function launch(row) {
        if (row === null || row === undefined)
            return;
        execArgv(["gtk-launch", row.id]);
        bumpUse(row.id);
        if (kbArmed)
            disarm();
    }

    // ==================================================== keyboard/focus
    // The host surface is WlrKeyboardFocus.None, so typing needs an
    // explicit hyprland_focus_grab_v1 on this window. `QsWindow.window`
    // resolves to the WindowInterface the grab whitelists.
    readonly property var hostWindow: QsWindow.window
    property bool kbArmed: false

    HyprlandFocusGrab {
        id: grab
        windows: root.hostWindow ? [root.hostWindow] : []
        // `active` is bound (never assigned imperatively — that would drop
        // the binding): flip root.kbArmed to take/release the grab.
        active: root.kbArmed && !!root.hostWindow && root.visible
        onCleared: root.kbArmed = false
    }

    function arm() {
        kbArmed = true;
        keyCatcher.forceActiveFocus();
    }
    function disarm() {
        kbArmed = false;
    }
    onVisibleChanged: if (!visible)
        disarm()

    function isPrintable(ev) {
        return ev.text && ev.text.length > 0 && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));
    }
    function handleKey(ev) {
        if (!kbArmed) {
            ev.accepted = false;
            return;
        }
        var k = ev.key;
        if (k === Qt.Key_Escape) {
            if (query !== "")
                query = "";
            else
                disarm();
        } else if (k === Qt.Key_Up) {
            sel = Math.max(0, sel - 1);
        } else if (k === Qt.Key_Down) {
            sel = Math.min(rows.length - 1, sel + 1);
        } else if (k === Qt.Key_PageUp) {
            sel = Math.max(0, sel - 12);
        } else if (k === Qt.Key_PageDown) {
            sel = Math.min(rows.length - 1, sel + 12);
        } else if (k === Qt.Key_Home) {
            sel = 0;
        } else if (k === Qt.Key_End) {
            sel = Math.max(0, rows.length - 1);
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (sel >= 0 && sel < rows.length)
                launch(rows[sel]);
        } else if (k === Qt.Key_Backspace) {
            query = query.length > 1 ? query.substring(0, query.length - 1) : "";
            sel = 0;
        } else if (isPrintable(ev)) {
            query += ev.text;
            sel = 0;
        }
        ev.accepted = true;
    }

    // ============================================================== LAYOUT
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
            root.handleKey(event);
        }

        Column {
            id: body
            anchors.fill: parent
            anchors.margins: pal.g3
            spacing: 0

            // ---- header
            Item {
                id: head
                width: body.width
                height: 30
                Text {
                    anchors { left: parent.left; leftMargin: pal.g1; verticalCenter: parent.verticalCenter }
                    text: "APPS"
                    color: pal.txt
                    font.family: pal.fDisp
                    font.pixelSize: 11
                    font.letterSpacing: 3.0
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; rightMargin: pal.g1 + 84 + pal.g2; verticalCenter: parent.verticalCenter }
                    height: 1
                    color: pal.ruleDark
                }
                // the workbench tab strip above already says "installed apps ·
                // gtk-launch", so this bar carries live state instead of a
                // second copy of the same hint
                Text {
                    anchors { right: parent.right; rightMargin: pal.g1; verticalCenter: parent.verticalCenter }
                    width: 84
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    text: root.query !== ""
                        ? root.rows.length + " / " + root.allApps.length
                        : root.allApps.length + " entries"
                    color: pal.t40
                    font.family: pal.fMono
                    font.pixelSize: 9
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: pal.ruleDark
                }
            }

            // ---- filter field (recessed well; click arms the key grab)
            Rectangle {
                id: filterBox
                width: body.width
                height: 32
                radius: pal.rRow
                border.color: root.kbArmed ? pal.accent
                    : (fltMouse.containsMouse ? pal.accent2 : pal.edge)
                border.width: 1
                gradient: Gradient {
                    GradientStop { position: 0.0; color: pal.wellTop }
                    GradientStop { position: 1.0; color: pal.well }
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: filterBox.radius; rightMargin: filterBox.radius }
                    height: 1
                    color: Qt.rgba(0, 0, 0, 0.7)
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: filterBox.radius; rightMargin: filterBox.radius }
                    height: 1
                    color: Qt.rgba(0.92, 0.96, 0.99, 0.07)
                }
                // armed marker: a 2px acid bar on the leading edge
                Rectangle {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 1 }
                    width: 2
                    height: parent.height - 12
                    radius: 1
                    color: pal.accent
                    opacity: root.kbArmed ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: 180
                            easing.type: Easing.OutCubic
                        }
                    }
                }
                Text {
                    anchors { left: parent.left; leftMargin: pal.g3; verticalCenter: parent.verticalCenter }
                    text: "⌕"
                    color: root.kbArmed ? pal.accent : pal.t40
                    font.family: pal.fMono
                    font.pixelSize: 12
                }
                Text {
                    anchors { left: parent.left; leftMargin: pal.g3 + 14; right: fltCount.left; rightMargin: pal.g2; verticalCenter: parent.verticalCenter }
                    elide: Text.ElideRight
                    // "type to filter…" and the footer's "click field to type"
                    // said the same thing twice; the field owns the affordance
                    // and the footer only reports the key state
                    text: root.query !== "" ? root.query : (root.kbArmed ? "▌" : "filter apps by name, id, meta or exec")
                    color: (root.query !== "" || root.kbArmed) ? pal.txt : pal.t40
                    font.family: pal.fMono
                    font.pixelSize: 11
                }
                Text {
                    id: fltCount
                    anchors { right: parent.right; rightMargin: pal.g3; verticalCenter: parent.verticalCenter }
                    horizontalAlignment: Text.AlignRight
                    font.family: pal.fMono
                    font.pixelSize: 9
                    color: root.kbArmed ? pal.accent : pal.t40
                    text: root.kbArmed ? "KEYS" : root.rows.length + " shown"
                }
                MouseArea {
                    id: fltMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.arm()
                }
            }

            // ---- column header (mirrors the delegate's tail block)
            Item {
                id: colHead
                width: body.width
                height: 20
                Text {
                    // row gutter + icon well + gap — the same three terms the
                    // delegate uses, so NAME lands exactly on the name column
                    anchors { left: parent.left; leftMargin: pal.g3 + pal.iconWell + pal.g2; verticalCenter: parent.verticalCenter }
                    text: "NAME"
                    color: pal.t40
                    font.family: pal.fDisp
                    font.pixelSize: 8
                    font.letterSpacing: 2.2
                }
                Row {
                    anchors { right: parent.right; rightMargin: pal.g3; verticalCenter: parent.verticalCenter }
                    spacing: pal.g2
                    Text {
                        width: pal.wCount
                        horizontalAlignment: Text.AlignRight
                        text: "USE"
                        color: pal.t40
                        font.family: pal.fDisp
                        font.pixelSize: 8
                        font.letterSpacing: 2.2
                    }
                    Text {
                        width: pal.wMeta
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideRight
                        text: "META"
                        color: pal.t40
                        font.family: pal.fDisp
                        font.pixelSize: 8
                        font.letterSpacing: 2.2
                    }
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: pal.ruleDark
                }
            }

            // ---- rows
            Item {
                id: listBox
                width: body.width
                height: Math.max(0, body.height - head.height - filterBox.height - colHead.height - foot.height - 4 * pal.g2)

                ListView {
                    id: appList
                    anchors.fill: parent
                    clip: true
                    model: root.rows
                    currentIndex: root.sel
                    spacing: 3
                    topMargin: pal.g1
                    bottomMargin: pal.g1
                    boundsBehavior: Flickable.StopAtBounds

                    // category headers — row `section` field is MOST USED
                    // for pinned launches, else the freedesktop group
                    section.property: "section"
                    section.criteria: ViewSection.FullString
                    section.delegate: Item {
                        id: secHead
                        required property string section
                        width: appList.width
                        height: 24
                        Text {
                            id: secTitle
                            anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter }
                            text: secHead.section
                            color: secHead.section === "MOST USED" ? pal.accent : pal.t55
                            font.family: pal.fDisp
                            font.pixelSize: 9
                            font.letterSpacing: 2.4
                        }
                        // one band recipe: title, rule filling the slack, tally
                        Rectangle {
                            anchors { left: secTitle.right; right: secCount.left; leftMargin: pal.g2; rightMargin: pal.g2; verticalCenter: parent.verticalCenter }
                            height: 1
                            color: secHead.section === "MOST USED" ? pal.accentDim : pal.ruleDark
                        }
                        Text {
                            id: secCount
                            anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                            width: 30
                            horizontalAlignment: Text.AlignRight
                            text: root.sectionTally(secHead.section)
                            color: secHead.section === "MOST USED" ? pal.accent : pal.t40
                            font.family: pal.fMono
                            font.pixelSize: 9
                        }
                        // MOST USED is the only section that is a rank, not a
                        // category — give it the leading acid tick that says so
                        Rectangle {
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                            width: 2
                            height: 12
                            radius: 1
                            color: pal.accent
                            visible: secHead.section === "MOST USED"
                        }
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 2; rightMargin: 2 }
                            height: 1
                            color: pal.ruleDark
                        }
                    }

                    delegate: Rectangle {
                        id: appRow
                        required property int index
                        required property var modelData
                        readonly property bool active: appRow.index === root.sel
                        width: appList.width
                        height: 34
                        radius: pal.rRow
                        // constant 1px so the row's contents never shift when
                        // the selection state changes
                        border.width: 1
                        border.color: rowMouse.containsMouse
                            ? (appRow.active ? pal.accent : pal.accent2Dim)
                            : (appRow.active ? pal.accentDim : "transparent")
                        color: rowMouse.containsMouse
                            ? pal.hovFill
                            : (appRow.active ? pal.selFill : "transparent")
                        Behavior on color {
                            NumberAnimation {
                                duration: 180
                                easing.type: Easing.OutCubic
                            }
                        }
                        Rectangle {
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 1 }
                            width: 2
                            height: 18
                            radius: 1
                            color: pal.accent
                            opacity: appRow.active ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation {
                                    duration: 180
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                        Item {
                            id: appRowBody
                            anchors { fill: parent; leftMargin: pal.g3; rightMargin: pal.g3 }
                            // themed icon in a recessed well, or the fallback
                            // mark — never a fake image
                            IconWell {
                                id: iconWell
                                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                                size: pal.iconWell
                                tint: Style.c.accent2
                                active: appRow.active
                                hovered: rowMouse.containsMouse
                                source: root.iconSrc(appRow.modelData.icon)
                                glyph: root.iconSrc(appRow.modelData.icon) === "" ? Style.ico.grid : ""
                            }
                            Text {
                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                width: pal.wMeta
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideRight
                                // meta can be absent — the id is the honest
                                // fallback, and neither may be blank
                                text: appRow.modelData.meta !== ""
                                    ? appRow.modelData.meta : appRow.modelData.id
                                color: appRow.active ? pal.t55 : pal.t40
                                font.family: pal.fMono
                                font.pixelSize: 9
                            }
                            Text {
                                anchors { right: parent.right; rightMargin: pal.wMeta + pal.g2; verticalCenter: parent.verticalCenter }
                                width: pal.wCount
                                horizontalAlignment: Text.AlignRight
                                text: root.useCell(appRow.modelData)
                                color: appRow.active ? pal.accent : pal.t40
                                font.family: pal.fMono
                                font.pixelSize: 9
                            }
                            Text {
                                anchors {
                                    left: iconWell.right; leftMargin: pal.g2
                                    right: parent.right; rightMargin: pal.wMeta + pal.g2 + pal.wCount + pal.g2
                                    verticalCenter: parent.verticalCenter
                                }
                                elide: Text.ElideRight
                                text: appRow.modelData.name
                                color: (appRow.active || rowMouse.containsMouse) ? pal.txt : pal.t55
                                font.family: pal.fMono
                                font.pixelSize: 12
                            }
                        }
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                root.sel = appRow.index;
                                root.launch(appRow.modelData);
                            }
                        }
                    }
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                    Connections {
                        target: root
                        function onRowsChanged() {
                            appList.currentIndex = root.sel;
                            appList.positionViewAtIndex(root.sel, ListView.Contain);
                        }
                    }
                }
                // two-line empty state, centered in the list region
                Item {
                    anchors.fill: parent
                    visible: root.rows.length === 0
                    Column {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - pal.g4 * 2
                        spacing: pal.g2
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "◇"
                            color: pal.t40
                            font.family: pal.fMono
                            font.pixelSize: 20
                        }
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: root.allApps.length === 0 ? "NO DESKTOP ENTRIES" : "NO MATCH"
                            color: pal.t55
                            font.family: pal.fDisp
                            font.pixelSize: 10
                            font.letterSpacing: 2.4
                        }
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: root.allApps.length === 0
                                ? "~/.local/share/applications + /usr/share/applications unreadable"
                                : "query “" + root.query + "” · esc clears"
                            color: pal.t40
                            font.family: pal.fMono
                            font.pixelSize: 9
                        }
                    }
                }
            }

            // ---- key legend
            Item {
                id: foot
                width: body.width
                height: 22
                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1
                    color: pal.ruleDark
                }
                Row {
                    anchors { left: parent.left; leftMargin: 2; right: parent.right; rightMargin: 2; verticalCenter: parent.verticalCenter }
                    spacing: pal.g3
                    Repeater {
                        // armed: real keycaps. disarmed: a plain sentence — a
                        // "click" rendered inside a keycap well is a lie about
                        // what the operator is pressing.
                        model: root.kbArmed
                            ? [{ k: "↑↓", v: "select" }, { k: "⏎", v: "launch" }, { k: "⌫", v: "erase" }, { k: "esc", v: "clear, then release" }]
                            : [{ k: "", v: "click the field to type · click an app to launch" }]
                        delegate: Row {
                            id: legItem
                            required property var modelData
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: legItem.modelData.k !== "" ? pal.g1 : 0
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: legItem.modelData.k !== ""
                                width: legKey.implicitWidth + 8
                                height: 14
                                radius: pal.rKey
                                color: Qt.rgba(0, 0, 0, 0.34)
                                border.width: 1
                                border.color: Qt.rgba(0, 0, 0, 0.5)
                                Text {
                                    id: legKey
                                    anchors.centerIn: parent
                                    text: legItem.modelData.k
                                    color: pal.accent2
                                    font.family: pal.fDisp
                                    font.pixelSize: 8
                                    font.letterSpacing: 1.0
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: legItem.modelData.v
                                color: pal.t40
                                font.family: pal.fMono
                                font.pixelSize: 9
                            }
                        }
                    }
                }
            }
        }
    }
}
