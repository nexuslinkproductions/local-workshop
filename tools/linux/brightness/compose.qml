import QtQuick
import "../../../nexuslink.hud/v5/kit"
import "../../../nexuslink.hud/v5/live"

// Composed scene for brightness-gate.py: room + deck (fixtures, frozen tick).
// Full deck still at 2560 x 1440 from fixtures. Render with the GPU harness so the
// knot shader draws. Two markers are rewritten by the render script per state:
// VIEWSTATE (view) and false (find open).
//
// apps mirrors the 11 entries of live/assets/apps.json in the shipped order
// (5 + hero + 5, OBS Studio before the hero), so the GPU scene shows the real
// band. It is inlined because the v5-shot harness does not enable file XHR
// (QML_XHR_ALLOW_FILE_READ); tst_launcher_symmetry.qml reads the real file and
// is the check that the two lists agree in count and order.
Item {
    id: root
    width: 2560
    height: 1440

    // Live composition (v4/HudV4.qml): the Environment room under the deck, deck with underEnvironment.
    Environment {
        anchors.fill: parent
        origin: Qt.point(0, 0)
        world: Qt.rect(0, 0, 2560, 1440)
    }

    DeckView {
        id: deck
        anchors.fill: parent
        underEnvironment: true
        autoTick: false
        tick: 12.3
        now: new Date(2026, 9, 23, 1, 2, 0)
        view: ""
        findOpen: false
        findQuery: false ? "hud" : ""
        findResults: false ? [
            { title: "HUD main screen build", path: "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/MAIN-SCREEN-BUILD.md", kind: "md", score: 9.1 },
            { title: "HUD dashboard design", path: "/home/nexuslink/.hermes/skills/creative/hud-dashboard-design/SKILL.md", kind: "md", score: 8.2 },
            { title: "Quickshell HUD development", path: "/home/nexuslink/.hermes/skills/software-development/quickshell-hud-development/SKILL.md", kind: "md", score: 7.7 },
            { title: "HudV4", path: "/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/HudV4.qml", kind: "code", score: 6.9 },
            { title: "hud-collect notes", path: "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/OMARCHY-HUD/notes.md", kind: "md", score: 6.1 },
            { title: "comp-r1 s3 README", path: "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s3/README.md", kind: "md", score: 5.8 },
            { title: "AGENTS", path: "/home/nexuslink/NEXUS_AI_CENTER/04_PROJECTS/HUD/AGENTS.md", kind: "md", score: 5.2 }
        ] : []
        link: ({ route: "direct", tunnel: "active",
                 rtt_ms: { median: 7.5, last: 8, min: 5, max: 92,
                           samples: [8, 7, 7, 11, 5, 92, 11, 6, 8, 7, 7, 7, 71, 8, 6, 5, 9, 9, 17, 62, 5, 8, 6, 8] },
                 mac: { load: [3.94, 4.45, 4.81], batt: 100, state: "charged", rem: "0:00", up_min: 13 } })
        localAi: ({ present: true, active: false, model: "embeddinggemma", sizeGb: 0.33, vramGb: 0, tokS: 0, activity: 0 })
        disks: [
            { label: "ROOT", fs: "btrfs", mount: "/", usedPct: 47, sizeBytes: 1.2e12, usedBytes: 5.64e11, freeBytes: 6.85e11 },
            { label: "T7", fs: "exfat", mount: "/run/media/nexuslink/T7", usedPct: 81, sizeBytes: 1.0e12, usedBytes: 8.1e11, freeBytes: 1.9e11 },
            { label: "KINGSTON", fs: "ntfs3", mount: "/run/media/nexuslink/KINGSTON", usedPct: 72, sizeBytes: 1.0e12, usedBytes: 7.2e11, freeBytes: 2.8e11 },
            { label: "DATA", fs: "ntfs3", mount: "/run/media/nexuslink/DATA", usedPct: 0.4, sizeBytes: 1.0e12, usedBytes: 4.0e9, freeBytes: 9.96e11 }
        ]
        crew: [
            { id: "a01748", parent: null, model: "model-a", tools: 33, tokens: 125381, idle_s: 32, title: "Draft beta issues", activity: "starting new turn" },
            { id: "a1d052", parent: null, model: "model-a", tools: 158, tokens: 139559, idle_s: 20, title: "Enable the new mode", activity: "receiving stream response" },
            { id: "683c2c", parent: "a1d052", model: "model-a", tools: 9, tokens: 3645, idle_s: 17, title: "Composition study s1", activity: "receiving stream response" },
            { id: "b2c3d4", parent: null, model: "model-c", tools: 12, tokens: 48210, idle_s: 3600, title: "Review HUD perf PR", activity: "" },
            { id: "c4d5e6", parent: null, model: "model-b", tools: 4, tokens: 9120, idle_s: 7200, title: "Mac fleet digest", activity: "" }
        ]
        apps: [
            { id: "hermes", name: "Hermes", glyph: "hermes", launches: 3, running: true, size: "tile" },
            { id: "devin", name: "Devin", glyph: "devin", launches: 8, running: false, size: "tile" },
            { id: "files", name: "Files", glyph: "files", launches: 2, running: false, size: "tile" },
            { id: "terminal", name: "Terminal", glyph: "terminal", launches: 0, running: false, size: "tile" },
            { id: "chromium", name: "Chromium", glyph: "chrome", launches: 0, running: false, size: "tile" },
            { id: "discord", name: "Discord", glyph: "discord", launches: 3, running: false, size: "tile" },
            { id: "x", name: "X", glyph: "x", launches: 0, running: false, size: "tile" },
            { id: "youtube", name: "YouTube", glyph: "youtube", launches: 0, running: false, size: "tile" },
            { id: "whatsapp", name: "WhatsApp", glyph: "whatsapp", launches: 0, running: false, size: "tile" },
            { id: "obs", name: "OBS Studio", glyph: "obs", launches: 1, running: false, size: "tile" },
            { id: "arc-raiders", name: "ARC Raiders", glyph: "arc-raiders", launches: 0, running: true, size: "feature" }
        ]
    }
}
