// Regression test for ../GpuCards.js — runs the SAME file the production
// QML imports (HudV4 gpus() IPC + system/GpuPair.qml), inside a node vm
// (the QML `.pragma` directive is stripped; it is an engine directive,
// not JS).
//
//   node v4/tests/gpu-cards.test.cjs
//
// Cases: live-machine attribution (Intel B580 primary, NVIDIA secondary
// with no sensor lane), Intel-first ordering across reordered inventory
// indices, non-Intel/NVIDIA adapters excluded, legacy aggregate keys never
// borrowed, and unknown-vs-zero reading hygiene.
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(
    path.join(__dirname, "..", "GpuCards.js"), "utf8")
    .split("\n")
    .filter(l => !l.trimStart().startsWith(".pragma"))
    .join("\n");

const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);

let fails = 0;
function check(label, actual, expected) {
    const ok = JSON.stringify(actual) === JSON.stringify(expected);
    if (!ok) fails++;
    console.log((ok ? "PASS" : "FAIL") + "  " + label +
                "  -> " + JSON.stringify(actual) + " (want " + JSON.stringify(expected) + ")");
}

// ---- live-machine frame shape (mirrors /tmp/hud-collect-probe.tsv +
// dev_gpu0_* from the stream; NVIDIA has no dev_gpu1_* readings) ----------
const live = {
    gpu0_kind: "intel", gpu0_name: "Arc B580",
    dev_gpu0_temp: "53", dev_gpu0_mhz: "1200",
    dev_gpu0_pw: "51", dev_gpu0_pct: "96",
    gpu1_kind: "nvidia",
    gpu1_name: "NVIDIA Corporation GP108 [GeForce GT 1030]",
    gpu2_kind: "amd",
    gpu2_name: "Advanced Micro Devices, Inc. [AMD/ATI] Raphael",
    dev_gpu2_temp: "52", dev_gpu2_mhz: "600",
    dev_gpu2_pw: "33", dev_gpu2_pct: "0",
    gpu_kind: "nvidia",
    gpu_name: "NVIDIA Corporation GP108 [GeForce GT 1030]",
    gpu_temp: "61"
};

const cards = ctx.cards(live);

check("amd inventory excluded -> 2 cards", cards.length, 2);

const intel = cards[0], nvidia = cards[1];
check("card0 is intel", intel.kind, "intel");
check("card0 index", intel.index, 0);
check("card0 name", intel.name, "Arc B580");
check("card0 role", intel.role, "Primary");
check("card0 temp", intel.temp, 53);
check("card0 utilization", intel.utilization, 96);
check("card0 power", intel.power, 51);
check("card0 clock", intel.clock, 1200);

check("card1 is nvidia", nvidia.kind, "nvidia");
check("card1 index", nvidia.index, 1);
check("card1 name normalized", nvidia.name, "GeForce GT 1030");
check("card1 role", nvidia.role, "Secondary");
check("card1 temp null (no sensor lane)", nvidia.temp, null);
check("card1 utilization null", nvidia.utilization, null);
check("card1 power null", nvidia.power, null);
check("card1 clock null", nvidia.clock, null);

// legacy aggregate keys (gpu_kind/gpu_name/gpu_temp describe the NVIDIA-
// preferred selection) must never be borrowed for any card
check("intel temp not borrowed from legacy gpu_temp",
    ctx.cards({ gpu0_kind: "intel", gpu0_name: "Arc", gpu_temp: "99" })[0].temp, null);
check("nvidia temp not borrowed from legacy gpu_temp",
    ctx.cards({ gpu0_kind: "nvidia", gpu0_name: "X", gpu_temp: "77" })[0].temp, null);
check("legacy gpu_name never substitutes inventory name",
    ctx.cards({ gpu0_kind: "intel", gpu0_name: "Arc B580", gpu_name: "GT 1030" })[0].name,
    "Arc B580");
check("missing inventory name falls back to kind, not gpu_name",
    ctx.cards({ gpu0_kind: "nvidia", gpu_name: "Legacy Name" })[0].name, "nvidia GPU");

// ---- reordered inventory indices: intel still first, indices kept ------
const re = ctx.cards({
    gpu0_kind: "nvidia", gpu0_name: "GT 1030",
    dev_gpu0_temp: "41",
    gpu3_kind: "intel", gpu3_name: "Arc B580",
    dev_gpu3_temp: "50", dev_gpu3_pct: "12"
});
check("reorder: intel first", re[0].kind, "intel");
check("reorder: intel keeps index 3", re[0].index, 3);
check("reorder: nvidia second", re[1].kind, "nvidia");
check("reorder: nvidia keeps index 0", re[1].index, 0);
check("reorder: readings follow their own index",
    [re[0].temp, re[1].temp], [50, 41]);

// ---- reading hygiene ----------------------------------------------------
const hyg = ctx.cards({
    gpu0_kind: "intel",
    dev_gpu0_temp: "",            // empty string -> null
    dev_gpu0_pct: "N/A",          // non-numeric -> null
    dev_gpu0_pw: "Infinity",      // non-finite -> null
    dev_gpu0_mhz: "0"             // zero is a real reading
});
check("empty reading -> null", hyg[0].temp, null);
check("N/A reading -> null", hyg[0].utilization, null);
check("Infinity reading -> null", hyg[0].power, null);
check("zero reading is kept as 0", hyg[0].clock, 0);

const nu = ctx.cards({
    gpu0_kind: "nvidia",
    dev_gpu0_temp: null, dev_gpu0_pct: undefined
});
check("null reading -> null", nu[0].temp, null);
check("undefined reading -> null", nu[0].utilization, null);

// intel package-temp fallback only applies to intel cards
const ipkg = ctx.cards({
    gpu0_kind: "intel", i_temp_pkg: "44",
    gpu1_kind: "nvidia", i_temp_pkg2: "ignored"
});
check("intel falls back to i_temp_pkg", ipkg[0].temp, 44);

// empty / no-inventory stats -> empty list, never a crash
check("empty stats -> []", ctx.cards({}), []);
check("amd-only stats -> []", ctx.cards({ gpu0_kind: "amd" }).length, 0);
check("undefined stats -> []", ctx.cards(undefined), []);

console.log(fails === 0 ? "\nALL PASS" : "\n" + fails + " FAILURES");
process.exit(fails === 0 ? 0 : 1);
