import QtQuick

// Deck fixtures for the I1 stills and probes: the values the shell layer will
// bind into DeckSurface on Linux, copied from v5/fixtures on 2026-10-23 so a
// still is reproducible without a shell.
//
//   sessions      v5/fixtures/sessions.json, all three rows
//   apps/allApps  v5/fixtures/apps.json, default + arcRaiders hero + all
//   findResults   v5/fixtures/find.json, first five rows
//   rttMs         v5/fixtures/link.json  rtt_ms.median 7.5
//   batteryLevel  v5/fixtures/link.json  mac.batt 100 -> 1.0
//   loadLevel     v5/fixtures/metrics.json host.load1_frac 0.7617
//   modelGb       v5/fixtures/metrics.json local_ai.size_gb 0.33
//   disks         no feed yet: the shape DeckMain will read from `df`
QtObject {
    id: fixtures

    readonly property string clockText: "00:18"
    readonly property string dayText: "FRI"
    readonly property string dateText: "23 OCT"

    readonly property var sessions: [
        { "id": "a01748", "parent": null, "model": "sonnet-5-5", "idle_s": 32,
          "title": "Draft vari8-beta issues for the crew", "activity": "starting new turn" },
        { "id": "a1d052", "parent": null, "model": "sonnet-5-5", "idle_s": 20,
          "title": "Enable operator-mode",
          "activity": "delegate_task: subagent receiving stream response (iteration 6/100000)" },
        { "id": "683c2c", "parent": "a1d052", "model": "sonnet-5-5", "idle_s": 17,
          "title": "Composition study s1: widget-and-icon-first HUD",
          "activity": "receiving stream response" }
    ]

    readonly property var apps: [
        { "slug": "hermes", "label": "Hermes", "launchCount": 34, "kind": "app" },
        { "slug": "devin", "label": "Devin", "launchCount": 21, "kind": "app" },
        { "slug": "files", "label": "Files", "launchCount": 18, "kind": "app" },
        { "slug": "terminal", "label": "Terminal", "launchCount": 57, "kind": "app" },
        { "slug": "chrome", "label": "Chrome", "launchCount": 26, "kind": "app" },
        { "slug": "discord", "label": "Discord", "launchCount": 12, "kind": "app" },
        { "slug": "x", "label": "X", "launchCount": 9, "kind": "app" },
        { "slug": "youtube", "label": "YouTube", "launchCount": 14, "kind": "app" },
        { "slug": "whatsapp", "label": "WhatsApp", "launchCount": 11, "kind": "app" }
    ]

    readonly property var allApps: [
        { "slug": "hermes", "label": "Hermes", "launchCount": 34 },
        { "slug": "terminal", "label": "Terminal", "launchCount": 57 },
        { "slug": "chrome", "label": "Chrome", "launchCount": 26 },
        { "slug": "devin", "label": "Devin", "launchCount": 21 },
        { "slug": "files", "label": "Files", "launchCount": 18 },
        { "slug": "spotify", "label": "Spotify", "launchCount": 16 },
        { "slug": "youtube", "label": "YouTube", "launchCount": 14 },
        { "slug": "discord", "label": "Discord", "launchCount": 12 },
        { "slug": "whatsapp", "label": "WhatsApp", "launchCount": 11 },
        { "slug": "x", "label": "X", "launchCount": 9 },
        { "slug": "obsidian", "label": "Obsidian", "launchCount": 7 }
    ]

    readonly property var hero: ({ "slug": "arc-raiders", "label": "Arc Raiders", "launchCount": 6 })

    readonly property var findResults: [
        { "path": "/home/operator/NEXUS_AI_CENTER/04_PROJECTS/HUD/MAIN-SCREEN-BUILD.md", "kind": "doc", "score": 0.97 },
        { "path": "/home/operator/Documents/HUD/deck-charter-2026-10-20.md", "kind": "doc", "score": 0.91 },
        { "path": "/home/operator/Pictures/deck/s2-rest.png", "kind": "image", "score": 0.88 },
        { "path": "/home/operator/Downloads/screenshot-2026-10-22-hud-final.png", "kind": "download", "score": 0.84 },
        { "path": "/home/operator/NEXUS_AI_CENTER/04_PROJECTS/Vari8/models/deck-v5-q4.gguf", "kind": "file", "score": 0.77 }
    ]

    readonly property real rttMs: 7.5
    readonly property real batteryLevel: 1.0
    readonly property real loadLevel: 0.7617
    readonly property real modelGb: 0.33
    readonly property real modelActivity: 0.0

    readonly property var disks: [
        { "label": "nvme0n1", "used": 0.62, "usedGb": 412, "sizeGb": 664 },
        { "label": "nvme1n1", "used": 0.41, "usedGb": 381, "sizeGb": 931 }
    ]
}
