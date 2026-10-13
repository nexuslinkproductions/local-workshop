.pragma library

// Inventory and per-device readings share the collector's GPU index.
// Never use legacy gpu_name/gpu_temp: they describe a different selection.
function reading(stats, key) {
    var value = stats[key]
    if (value === undefined || value === null || String(value).trim() === "")
        return null
    var n = Number(value)
    return isFinite(n) ? n : null
}

function cards(stats) {
    stats = stats || {}
    var indices = []
    for (var key in stats) {
        var match = /^gpu(\d+)_kind$/.exec(key)
        if (match && (stats[key] === "intel" || stats[key] === "nvidia"))
            indices.push(Number(match[1]))
    }
    indices.sort(function (a, b) {
        var ak = stats["gpu" + a + "_kind"]
        var bk = stats["gpu" + b + "_kind"]
        return ak === bk ? a - b : ak === "intel" ? -1 : 1
    })
    var result = []
    for (var i = 0; i < indices.length; i++) {
        var index = indices[i]
        var prefix = "dev_gpu" + index + "_"
        var kind = stats["gpu" + index + "_kind"]
        var name = String(stats["gpu" + index + "_name"] || (kind + " GPU"))
        name = name.replace(/^NVIDIA Corporation\s+/, "")
                   .replace(/^GP108\s+\[([^\]]+)\]$/, "$1")
        var temp = reading(stats, prefix + "temp")
        if (temp === null && kind === "intel")
            temp = reading(stats, "i_temp_pkg")
        result.push({
            index: index,
            kind: kind,
            name: name,
            role: kind === "intel" ? "Primary" : "Secondary",
            temp: temp,
            utilization: reading(stats, prefix + "pct"),
            power: reading(stats, prefix + "pw"),
            clock: reading(stats, prefix + "mhz")
        })
    }
    return result
}
