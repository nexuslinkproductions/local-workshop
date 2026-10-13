// Regression test for ../ScreenRoles.js — runs the SAME file the production
// QML imports, inside a node vm (the QML `.pragma` directive is stripped; it
// is an engine directive, not JS).
//
//   node v4/tests/screen-roles.test.cjs
//
// Cases: roles follow display identity across renamed connectors, the old
// hardcoded connector names carry no role, absent identity falls back to
// command, and XREAL/Nreal glasses are excluded from HUD windows.
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(
    path.join(__dirname, "..", "ScreenRoles.js"), "utf8")
    .split("\n")
    .filter(l => !l.trimStart().startsWith(".pragma"))
    .join("\n");

const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);

let fails = 0;
function check(label, actual, expected) {
    const ok = actual === expected;
    if (!ok) fails++;
    console.log((ok ? "PASS" : "FAIL") + "  " + label +
                "  -> " + JSON.stringify(actual) + " (want " + JSON.stringify(expected) + ")");
}

// live monitor set as reported by hyprctl (identity), connectors renamed on
// purpose — the mapping must be insensitive to `name`
check("samsung command on renamed connector DP-9",
    ctx.roleForScreen({ name: "DP-9", model: "LC27G7xT", serialNumber: "H4ZR200063" }),
    "command");
check("hp e24i hardware on renamed connector HDMI-A-1",
    ctx.roleForScreen({ name: "HDMI-A-1", model: "HP E24i G4", serialNumber: "6CM1490KNN" }),
    "hardware");
check("hp z24n ops on renamed connector DP-3",
    ctx.roleForScreen({ name: "DP-3", model: "HP Z24n G3", serialNumber: "CN42344YTJ" }),
    "ops");
check("xreal glasses excluded",
    ctx.roleForScreen({ name: "DP-7", model: "XREAL One Pro", serialNumber: "" }),
    "glasses");
check("nreal brand variant also glasses",
    ctx.roleForScreen({ name: "DP-1", model: "Nreal Air" }),
    "glasses");

// old hardcoded connector names must NOT carry roles
check("DP-2 connector no longer means hardware (dell -> command)",
    ctx.roleForScreen({ name: "DP-2", model: "Dell U2720Q", serialNumber: "XYZ" }),
    "command");
check("HDMI-A-3 connector no longer means ops (samsung -> command)",
    ctx.roleForScreen({ name: "HDMI-A-3", model: "LC27G7xT", serialNumber: "H4ZR200063" }),
    "command");
check("hardware follows the display, not the connector (e24i on DP-2)",
    ctx.roleForScreen({ name: "DP-2", model: "HP E24i G4", serialNumber: "6CM1490KNN" }),
    "hardware");
check("ops follows the display, not the connector (z24n on HDMI-A-3)",
    ctx.roleForScreen({ name: "HDMI-A-3", model: "HP Z24n G3" }),
    "ops");

// identity absent -> command fallback, never a crash
check("no model/serial -> command fallback",
    ctx.roleForScreen({ name: "DP-2" }), "command");
check("empty-string identity -> command fallback",
    ctx.roleForScreen({ name: "eDP-1", model: "", serialNumber: "" }), "command");
check("null screen -> command fallback", ctx.roleForScreen(null), "command");
check("undefined props -> command fallback",
    ctx.roleForScreen({ name: "DP-4", model: undefined, serialNumber: undefined }), "command");

// unknown external display -> command fallback
check("unknown external model -> command fallback",
    ctx.roleForScreen({ name: "DP-8", model: "AOC Q27G3XMN", serialNumber: "123" }),
    "command");

// window filtering
check("hasHudWindow samsung", ctx.hasHudWindow({ model: "LC27G7xT" }), true);
check("hasHudWindow xreal", ctx.hasHudWindow({ model: "XREAL One Pro" }), false);
check("hasHudWindow unknown", ctx.hasHudWindow({ model: "Dell U2720Q" }), true);

console.log(fails === 0 ? "\nALL PASS" : "\n" + fails + " FAILURES");
process.exit(fails === 0 ? 0 : 1);
