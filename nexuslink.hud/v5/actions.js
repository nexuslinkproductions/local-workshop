.pragma library

// actions.js - the quick-action command table for the v5 bottom row.
// Pure JS: nothing in this file starts a process. DeckMain.qml runs the plan.
//
//   id           kind   what it does
//   visualizer   deck   toggles playback (DeckMain: hud.toggleMedia)
//   apps         deck   focuses the launcher (DeckMain: hud.focusId = "launcher")
//   screen-scan  argv   omarchy screenshot capture (omarchy-capture-screenshot)
//   text-scan    argv   omarchy OCR capture, text to clipboard (omarchy-capture-text)
//   power        argv   omarchy system menu, opens the menu (omarchy-menu system)
//
// argv holds bare command names: Process resolves them through PATH, and no
// shell string is ever built. env is optional; env.binDir, when set, is put in
// front of argv[0] as an absolute directory. Default is "" (PATH lookup).

var IDS = ["visualizer", "apps", "screen-scan", "text-scan", "power"]

// null means the deck handles the action itself; no process is started.
var ARGV = {
    "visualizer": null,
    "apps": null,
    "screen-scan": ["omarchy-capture-screenshot"],
    "text-scan": ["omarchy-capture-text"],
    "power": ["omarchy-menu", "system"]
}

// "media" | "launcher" for deck actions, "" for process actions.
var DECK = {
    "visualizer": "media",
    "apps": "launcher",
    "screen-scan": "",
    "text-scan": "",
    "power": ""
}

function isKnown(actionId) {
    return IDS.indexOf(String(actionId)) >= 0
}

// argv for an action id, or null (deck action or unknown id).
function commandFor(actionId, env) {
    var id = String(actionId)
    if (!isKnown(id) || ARGV[id] === null)
        return null
    var out = ARGV[id].slice(0)
    var dir = env && env.binDir ? String(env.binDir) + "/" : ""
    out[0] = dir + out[0]
    return out
}

// What DeckMain does with an id: {known, deck, argv}. Unknown ids run nothing.
function plan(actionId, env) {
    var id = String(actionId)
    if (!isKnown(id))
        return { known: false, deck: "", argv: null }
    return { known: true, deck: DECK[id], argv: commandFor(id, env) }
}

// Every row in order, for tests and the command check.
function commandTable(env) {
    var rows = []
    for (var i = 0; i < IDS.length; ++i)
        rows.push({ id: IDS[i], argv: commandFor(IDS[i], env) })
    return rows
}
