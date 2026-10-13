.pragma library

// ScreenRoles.js — stable-identity HUD role assignment (M1 kit).
//
// Roles follow the DISPLAY, not the connector: the QsScreen name can
// renumber after GPU/topology changes, so matching on it moved the
// hardware/ops decks onto the wrong panel. Identity comes from the EDID strings Quickshell
// exposes on ShellScreen — `model` and `serialNumber` (QsScreen has no
// `manufacturer` property in this Quickshell version).
//
//   Samsung LC27G7xT  -> "command"   (primary cockpit)
//   HP E24i G4        -> "hardware"  (right)
//   HP Z24n G3        -> "ops"       (left)
//   Nreal/XREAL       -> "glasses"   (no HUD window — filtered from Variants)
//   anything else     -> "command"   (unknown external displays keep a deck)

function identityOf(screen) {
    if (screen === null || screen === undefined) return ""
    var parts = []
    var model = screen.model
    var serial = screen.serialNumber
    if (model !== undefined && model !== null && String(model) !== "")
        parts.push(String(model))
    if (serial !== undefined && serial !== null && String(serial) !== "")
        parts.push(String(serial))
    return parts.join(" ").toLowerCase()
}

// One of "command" | "hardware" | "ops" | "glasses".
function roleForScreen(screen) {
    var id = identityOf(screen)
    // glasses first: never let a substring accidentally seat a HUD window
    // on a wearable output
    if (id.indexOf("xreal") >= 0 || id.indexOf("nreal") >= 0) return "glasses"
    if (id.indexOf("e24i") >= 0) return "hardware"
    if (id.indexOf("z24n") >= 0) return "ops"
    // lc27g7 matches explicitly so an identity-bearing command panel is a
    // decision, not a fallthrough; unknown/absent identity lands here too
    if (id.indexOf("lc27g7") >= 0) return "command"
    return "command"
}

// Whether this output should get a PanelWindow at all.
function hasHudWindow(screen) {
    return roleForScreen(screen) !== "glasses"
}
