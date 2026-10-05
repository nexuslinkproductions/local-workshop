// hud-collect — stats collector for the nexuslink.hud omarchy-shell plugin.
//
// Modes:
//   hud-collect probe            static-ish info: host, kernel, gpu inventory
//   hud-collect poll             one batch of dynamic stats, then exit
//   hud-collect stream           batch every ~1s forever, "batch\t<n>" sentinel per cycle
//
// Output: one "key<TAB>value" line per stat (same contract as collect.sh).
// Deltas (cpu busy%, net rates, power watts) are raw counters — Hud.qml
// computes rates between batches.

mod devices;

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn read(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn read_u64(path: impl AsRef<Path>) -> Option<u64> {
    read(path)?.parse().ok()
}

fn out<W: Write>(w: &mut W, key: impl AsRef<str>, val: impl std::fmt::Display) {
    let key = key.as_ref();
    let _ = writeln!(w, "{}\t{}", key, val);
}

// ------------------------------------------------------------------ GPUs

#[derive(Clone, Copy, PartialEq)]
enum GpuKind {
    Nvidia,
    Amd,
    Intel,
    Other,
}

struct Gpu {
    kind: GpuKind,
    device: PathBuf, // /sys/class/drm/cardN/device
    name: String,
}

fn drm_cards() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir("/sys/class/drm")
        .map(|d| {
            d.flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| {
                            n.starts_with("card")
                                && n[4..].chars().all(|c| c.is_ascii_digit())
                                && !n.is_empty()
                                && n.len() > 4
                        })
                        .unwrap_or(false)
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

fn gpu_kind(vendor: &str) -> GpuKind {
    match vendor {
        "0x10de" => GpuKind::Nvidia,
        "0x1002" | "0x1022" => GpuKind::Amd,
        "0x8086" => GpuKind::Intel,
        _ => GpuKind::Other,
    }
}

fn pci_name(addr: &str) -> Option<String> {
    // lspci -mm gives "XX:YY.Z" "Class" "Vendor" "Device" ...
    let out = std::process::Command::new("lspci")
        .arg("-mm")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        let fields: Vec<&str> = line.split('"').collect();
        // lspci -mm layout: "slot" "class" "vendor" "device" "subvendor" "subdevice" ...
        if fields.len() >= 7 && fields[0].trim().ends_with(addr) {
            let device = fields[5].to_string();
            let vendor = fields[3].to_string();
            return Some(match vendor.as_str() {
                "Intel Corporation" => device
                    .replace("Battlemage G21 [", "")
                    .replace("]", "")
                    .trim()
                    .to_string(),
                v => format!("{} {}", v, device).trim().to_string(),
            });
        }
    }
    None
}

fn find_gpus() -> Vec<Gpu> {
    let mut gpus = Vec::new();
    for card in drm_cards() {
        let dev = card.join("device");
        let Some(vendor) = read(dev.join("vendor")) else { continue };
        let kind = gpu_kind(&vendor);
        if kind == GpuKind::Other {
            continue;
        }
        // PCI slot name from the symlink target: .../0000:03:00.0
        let addr = fs::canonicalize(&dev)
            .ok()
            .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
            .unwrap_or_default();
        let short = addr.rsplit(':').take(2).collect::<Vec<_>>();
        let short = short.iter().rev().cloned().collect::<Vec<_>>().join(":");
        let name = pci_name(&short).unwrap_or_else(|| match kind {
            GpuKind::Nvidia => "NVIDIA GPU".into(),
            GpuKind::Amd => "AMD GPU".into(),
            GpuKind::Intel => "Intel GPU".into(),
            GpuKind::Other => "GPU".into(),
        });
        gpus.push(Gpu {
            kind,
            device: dev,
            name,
        });
    }
    gpus
}

fn hwmon_dir(dev: &Path, want_name: &str) -> Option<PathBuf> {
    let hws = dev.join("hwmon");
    for e in fs::read_dir(&hws).ok()?.flatten() {
        let p = e.path();
        if read(p.join("name")).as_deref() == Some(want_name) {
            return Some(p);
        }
    }
    // fallback: first hwmon
    fs::read_dir(&hws)
        .ok()?
        .flatten()
        .next()
        .map(|e| e.path())
}

// -------------------------------------------------------------- Intel (xe)

fn emit_intel<W: Write>(w: &mut W, gpu: &Gpu, prev_energy: &mut Option<(u64, Instant)>) {
    let d = &gpu.device;
    let Some(hw) = hwmon_dir(d, "xe") else { return };

    // Optional utilisation/frequency surfaces (driver-version dependent)
    if let Some(u) = read_u64(d.join("gpu_busy_percent")) {
        out(w, "i_util", u);
    }
    if let Some(f) = read_u64(hw.join("freq1_input")) {
        out(w, "i_freq_mhz", f / 1_000_000);
    }

    // Temps by label: pkg, vram, mctrl, pcie, vram_ch_0..11
    let mut vram_ch: Vec<u64> = Vec::new();
    for i in 2..=17u8 {
        let lbl = match read(hw.join(format!("temp{}_label", i))) {
            Some(l) => l,
            None => continue,
        };
        let Some(t) = read_u64(hw.join(format!("temp{}_input", i))).map(|t| t / 1000) else {
            continue;
        };
        match lbl.as_str() {
            "pkg" => out(w, "i_temp_pkg", t),
            "vram" => out(w, "i_temp_vram", t),
            "mctrl" => out(w, "i_temp_mctrl", t),
            "pcie" => out(w, "i_temp_pcie", t),
            l if l.starts_with("vram_ch") => vram_ch.push(t),
            _ => {}
        }
    }
    if !vram_ch.is_empty() {
        out(
            w,
            "i_vram_ch_max",
            vram_ch.iter().max().copied().unwrap_or(0),
        );
        out(
            w,
            "i_vram_ch_avg",
            vram_ch.iter().sum::<u64>() / vram_ch.len() as u64,
        );
    }
    if let Some(rpm) = read_u64(hw.join("fan1_input")) {
        out(w, "i_fan_rpm", rpm);
    }
    if let Some(cap) = read_u64(hw.join("power1_cap")) {
        out(w, "i_pwr_cap_w", cap / 1_000_000);
    }
    // xe exposes cumulative energy only; watts = dEnergy/dt, needs daemon state.
    let e_card = read_u64(hw.join("energy1_input"));
    if let Some(e) = e_card {
        out(w, "i_energy_uj", e);
        if let Some((pe, pt)) = *prev_energy {
            let dt = pt.elapsed().as_secs_f64();
            if dt > 0.1 && e >= pe {
                out(w, "i_pwr_w", ((e - pe) as f64 / dt / 1e6) as u64);
            }
        }
        *prev_energy = Some((e, Instant::now()));
    }
    // VRAM usage, if the kernel exposes it
    if let Some(u) = read_u64(d.join("mem_info_vram_used")) {
        out(w, "i_vram_used", u / 1_048_576);
    }
    if let Some(t) = read_u64(d.join("mem_info_vram_total")) {
        out(w, "i_vram_total", t / 1_048_576);
    }
}

// --------------------------------------------------------------------- AMD

fn emit_amd<W: Write>(w: &mut W, gpu: &Gpu) {
    let d = &gpu.device;
    if let Some(u) = read_u64(d.join("gpu_busy_percent")) {
        out(w, "a_util", u);
    }
    if let Some(u) = read_u64(d.join("mem_info_vram_used")) {
        out(w, "a_vram_used", u / 1_048_576);
    }
    if let Some(t) = read_u64(d.join("mem_info_vram_total")) {
        out(w, "a_vram_total", t / 1_048_576);
    }
    if let Some(hw) = hwmon_dir(d, "amdgpu") {
        if let Some(t) = read_u64(hw.join("temp1_input")) {
            out(w, "a_temp", t / 1000);
        }
        if let Some(p) = read_u64(hw.join("power1_input")) {
            out(w, "a_pwr_w", p / 1_000_000);
        }
        if let Some(f) = read_u64(hw.join("freq1_input")) {
            out(w, "a_freq_mhz", f / 1_000_000);
        }
    }
}

// ------------------------------------------------------------------ probe

fn probe() {
    let stdout = io::stdout();
    let mut w = BufWriter::new(stdout.lock());
    let host = read("/proc/sys/kernel/hostname")
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_default();
    out(&mut w, "host", host);
    out(&mut w, "kernel", read("/proc/sys/kernel/osrelease").unwrap_or_default());

    let gpus = find_gpus();
    for (i, g) in gpus.iter().enumerate() {
        let kind = match g.kind {
            GpuKind::Nvidia => "nvidia",
            GpuKind::Amd => "amd",
            GpuKind::Intel => "intel",
            GpuKind::Other => "other",
        };
        out(&mut w, format!("gpu{}_kind", i), kind);
        out(&mut w, format!("gpu{}_name", i), &g.name);
    }
    // legacy single-GPU keys: prefer discrete (nvidia > intel > amd)
    if let Some(g) = gpus
        .iter()
        .find(|g| g.kind == GpuKind::Nvidia)
        .or_else(|| gpus.iter().find(|g| g.kind == GpuKind::Intel))
        .or_else(|| gpus.first())
    {
        let kind = match g.kind {
            GpuKind::Nvidia => "nvidia",
            GpuKind::Amd => "amd",
            GpuKind::Intel => "intel",
            GpuKind::Other => "other",
        };
        out(&mut w, "gpu_kind", kind);
        out(&mut w, "gpu_name", &g.name);
    }
}

// ------------------------------------------------------------------- poll

// Stateful view of counters needing deltas (per-core busy%, disk rates,
// per-process CPU). Populated between frames in `stream`; `poll` leaves it
// empty and emits raw counters only.
#[derive(Default)]
struct Prev {
    cores: Vec<(u64, u64)>,            // per-core (idle+iowait, total)
    disk: Option<(u64, u64, Instant)>, // (sectors read, written, t)
    procs: std::collections::HashMap<u32, (u64, String)>, // pid -> (utime+stime, comm)
    proc_t: Option<Instant>,
    // last frame's per-pid cpu% and harness tag, for agent aggregation
    proc_pct: Vec<(u32, f64, String, String)>, // (pid, pct, comm, tag)
}

fn emit_poll<W: Write>(w: &mut W, gpus: &[Gpu], intel_energy: &mut Vec<Option<(u64, Instant)>>, prev: &mut Prev) {
    // uptime / load
    if let Some(up) = read("/proc/uptime") {
        if let Some(s) = up.split_whitespace().next() {
            out(w, "uptime_s", s.split('.').next().unwrap_or("0"));
        }
    }
    if let Some(load) = read("/proc/loadavg") {
        let mut it = load.split_whitespace();
        out(w, "load1", it.next().unwrap_or(""));
        out(w, "load5", it.next().unwrap_or(""));
        out(w, "load15", it.next().unwrap_or(""));
    }

    // cpu aggregate line + per-core busy% (needs previous frame)
    if let Some(stat) = read("/proc/stat") {
        let mut cores: Vec<(u64, u64)> = Vec::new();
        for line in stat.lines() {
            if !line.starts_with("cpu") {
                break;
            }
            let f: Vec<u64> = line
                .split_whitespace()
                .skip(1)
                .filter_map(|s| s.parse().ok())
                .collect();
            if f.len() < 8 {
                continue;
            }
            let idle_iow = f[3] + f[4];
            let total: u64 = f.iter().sum();
            if line.starts_with("cpu ") {
                out(w, "cpu_idle", idle_iow);
                out(w, "cpu_total", total);
            } else {
                cores.push((idle_iow, total));
            }
        }
        if !prev.cores.is_empty() && cores.len() == prev.cores.len() {
            for (i, &(i1, t1)) in cores.iter().enumerate() {
                let (i0, t0) = prev.cores[i];
                if t1 > t0 {
                    let pct = 100.0 * (1.0 - (i1 - i0) as f64 / (t1 - t0) as f64);
                    out(w, format!("cpu_core_{}", i), format!("{:.0}", pct.max(0.0).min(100.0)));
                }
            }
        }
        if !cores.is_empty() {
            out(w, "cpu_cores", cores.len());
            prev.cores = cores;
        }
    }
    if let Some(n) = read("/proc/cpuinfo") {
        out(w, "cpu_count", n.matches("processor").count());
    }

    // cpu temp: known hwmon names, else first thermal zone
    'cpu_temp: {
        if let Ok(hws) = fs::read_dir("/sys/class/hwmon") {
            for e in hws.flatten() {
                let p = e.path();
                let name = read(p.join("name")).unwrap_or_default();
                if matches!(
                    name.as_str(),
                    "k10temp" | "coretemp" | "zenpower" | "cpu_thermal" | "acpitz" | "peci"
                ) {
                    if let Some(t) = read_u64(p.join("temp1_input")) {
                        out(w, "cpu_temp", t / 1000);
                        break 'cpu_temp;
                    }
                }
            }
        }
        if let Ok(zs) = fs::read_dir("/sys/class/thermal") {
            for e in zs.flatten() {
                if let Some(t) = read_u64(e.path().join("temp")) {
                    out(w, "cpu_temp", t / 1000);
                    break 'cpu_temp;
                }
            }
        }
    }

    // memory
    if let Some(mi) = read("/proc/meminfo") {
        let mut t = 0u64;
        let mut a = 0u64;
        let mut st = 0u64;
        let mut sf = 0u64;
        for l in mi.lines() {
            let mut p = l.split_whitespace();
            let key = p.next().unwrap_or("");
            let v: u64 = p.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            match key {
                "MemTotal:" => t = v,
                "MemAvailable:" => a = v,
                "SwapTotal:" => st = v,
                "SwapFree:" => sf = v,
                _ => {}
            }
        }
        out(w, "mem_total_kb", t);
        out(w, "mem_avail_kb", a);
        out(w, "swap_total_kb", st);
        out(w, "swap_free_kb", sf);
    }

    // network totals (skip lo)
    if let Some(nd) = read("/proc/net/dev") {
        let (mut rx, mut tx) = (0u64, 0u64);
        for l in nd.lines().skip(2) {
            if let Some((iface, rest)) = l.split_once(':') {
                if iface.trim() == "lo" {
                    continue;
                }
                let f: Vec<u64> = rest
                    .split_whitespace()
                    .filter_map(|s| s.parse().ok())
                    .collect();
                if f.len() >= 9 {
                    rx += f[0];
                    tx += f[8];
                }
            }
        }
        out(w, "net_rx", rx);
        out(w, "net_tx", tx);
    }

    // disk I/O: /proc/diskstats sectors (field 3 = read, 7 = written;
    // 1 sector = 512 B). Rates need the previous frame.
    if let Some(ds) = read("/proc/diskstats") {
        // whole-disk names only (partitions live under /sys/block/<disk>/)
        let disks: std::collections::HashSet<String> = fs::read_dir("/sys/block")
            .map(|d| {
                d.flatten()
                    .filter_map(|e| e.file_name().to_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        let (mut rd, mut wr) = (0u64, 0u64);
        for l in ds.lines() {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() >= 14 && disks.contains(f[2]) {
                if let (Ok(r), Ok(wr_)) = (f[5].parse::<u64>(), f[9].parse::<u64>()) {
                    rd += r;
                    wr += wr_;
                }
            }
        }
        out(w, "disk_rd_sectors", rd);
        out(w, "disk_wr_sectors", wr);
        if let Some((pr, pw, pt)) = prev.disk {
            let dt = pt.elapsed().as_secs_f64();
            if dt > 0.1 {
                out(w, "disk_read_bps", ((rd.saturating_sub(pr) * 512) as f64 / dt) as u64);
                out(w, "disk_write_bps", ((wr.saturating_sub(pw) * 512) as f64 / dt) as u64);
            }
        }
        prev.disk = Some((rd, wr, Instant::now()));
    }

    // top processes by CPU% — per-pid utime+stime deltas from /proc/<pid>/stat
    {
        let mut cur: std::collections::HashMap<u32, (u64, String)> = Default::default();
        let mut cur_tags: std::collections::HashMap<u32, String> = Default::default();
        if let Ok(rd) = fs::read_dir("/proc") {
            for e in rd.flatten() {
                let Some(name) = e.file_name().to_str().map(String::from) else { continue };
                let Ok(pid) = name.parse::<u32>() else { continue };
                let Some(stat) = read(e.path().join("stat")) else { continue };
                // comm may contain spaces/parens — fields after ')'
                let Some(rp) = stat.rfind(')') else { continue };
                let Some(comm) = stat
                    .find('(')
                    .map(|lp| stat[lp + 1..rp].to_string())
                else { continue };
                let f: Vec<&str> = stat[rp + 2..].split_whitespace().collect();
                // utime(14) + stime(15) -> indices 11,12 after ')'
                if f.len() > 12 {
                    let t: u64 = f[11].parse().unwrap_or(0) + f[12].parse().unwrap_or(0);
                    let tag = agent_tag(&e.path(), &comm);
                    if !tag.is_empty() {
                        cur_tags.insert(pid, tag);
                    }
                    cur.insert(pid, (t, comm));
                }
            }
        }
        if let Some(pt) = prev.proc_t {
            let dt = pt.elapsed().as_secs_f64();
            if dt > 0.1 {
                let hz = 100.0; // USER_HZ on x86_64 Linux
                let mut scored: Vec<(f64, String)> = Vec::new();
                let mut pct_list: Vec<(u32, f64, String, String)> = Vec::new();
                for (pid, (t, comm)) in &cur {
                    if let Some((pt_, _)) = prev.procs.get(pid) {
                        if *t >= *pt_ {
                            let pct = (*t - *pt_) as f64 / dt / hz * 100.0;
                            if pct >= 0.5 {
                                scored.push((pct, comm.clone()));
                            }
                            let tag = cur_tags.get(pid).cloned().unwrap_or_default();
                            pct_list.push((*pid, pct, comm.clone(), tag));
                        }
                    }
                }
                scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
                for (i, (pct, comm)) in scored.iter().take(6).enumerate() {
                    out(w, format!("proc{}_name", i), comm);
                    out(w, format!("proc{}_cpu", i), format!("{:.0}", pct));
                }
                prev.proc_pct = pct_list;
            }
        }
        prev.procs = cur;
        prev.proc_t = Some(Instant::now());
    }

    // filesystems via statvfs
    for (path, tag) in [("/", "root"), ("/home", "home")] {
        let c = std::ffi::CString::new(path).unwrap();
        unsafe {
            let mut st: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c.as_ptr(), &mut st) == 0 {
                let size = st.f_blocks * st.f_frsize;
                let free = st.f_bavail * st.f_frsize;
                let used = size.saturating_sub(st.f_bfree * st.f_frsize);
                let pct = if size > 0 { used * 100 / size } else { 0 };
                let _ = free;
                out(w, format!("fs_{}_used", tag), used);
                out(w, format!("fs_{}_size", tag), size);
                out(w, format!("fs_{}_pct", tag), pct);
                out(w, format!("fs_{}_target", tag), path);
            }
        }
    }

    // GPUs
    for (i, g) in gpus.iter().enumerate() {
        match g.kind {
            GpuKind::Intel => {
                if i < intel_energy.len() {
                    let mut holder = intel_energy[i].take();
                    emit_intel(w, g, &mut holder);
                    intel_energy[i] = holder;
                }
            }
            GpuKind::Amd => emit_amd(w, g),
            GpuKind::Nvidia => {
                if let Ok(o) = std::process::Command::new("nvidia-smi")
                    .args([
                        "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
                        "--format=csv,noheader,nounits",
                    ])
                    .output()
                {
                    let line = String::from_utf8_lossy(&o.stdout);
                    if let Some(l) = line.lines().next() {
                        let f: Vec<&str> = l.split(',').map(|s| s.trim()).collect();
                        if f.len() >= 4 {
                            out(w, "gpu_util", f[0]);
                            out(w, "gpu_vram_used", f[1]);
                            out(w, "gpu_vram_total", f[2]);
                            out(w, "gpu_temp", f[3]);
                        }
                    }
                }
            }
            GpuKind::Other => {}
        }
    }
}

// -------------------------------------------------------------- batteries
//
// /sys/class/power_supply/* — hidpp devices (Logitech), laptop batteries,
// anything with a capacity file. Mains adapters carry no capacity and are
// skipped implicitly.

fn emit_batteries<W: Write>(w: &mut W) {
    let mut i = 0usize;
    if let Ok(rd) = fs::read_dir("/sys/class/power_supply") {
        let mut entries: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for p in entries {
            let Some(pct) = read_u64(p.join("capacity")) else { continue };
            let name = read(p.join("model_name"))
                .filter(|s| !s.is_empty())
                .or_else(|| p.file_name().map(|n| n.to_string_lossy().to_string()))
                .unwrap_or_default();
            let state = read(p.join("status")).unwrap_or_default();
            out(w, format!("bat{}_name", i), name);
            out(w, format!("bat{}_pct", i), pct);
            out(w, format!("bat{}_state", i), state);
            i += 1;
        }
    }
    out(w, "bat_count", i);
}

// ---------------------------------------------------------- block devices
//
// Whole-disk + partition topology for the HUD storage lane — every nvme/sd/
// mmcblk/vd disk and its partitions, mounted or not. Primary source is
// `lsblk -P` (key="value" pairs, so no JSON parser is needed); when lsblk is
// absent/fails we walk /sys/block + /proc/self/mounts instead. Cheap enough
// to emit every batch.

struct BlkPart {
    name: String,
    size: u64,
    fstype: String,
    label: String,
    mount: String, // "" when unmounted
}

struct BlkDisk {
    name: String,
    model: String,
    size: u64,
    kind: &'static str, // nvme | sata | usb | virtio | mmc
    rota: u64,
    parts: Vec<BlkPart>,
}

fn blk_disk_name(n: &str) -> bool {
    n.starts_with("nvme")
        || n.starts_with("sd")
        || n.starts_with("mmcblk")
        || n.starts_with("vd")
}

fn blk_kind(name: &str, tran: &str) -> &'static str {
    if name.starts_with("nvme") {
        "nvme"
    } else if name.starts_with("vd") {
        "virtio"
    } else if name.starts_with("mmcblk") {
        "mmc"
    } else if tran == "usb" {
        "usb"
    } else {
        "sata"
    }
}

// one `lsblk -P` line -> key=value pairs. Values are "..."-quoted with \xNN
// hex escapes (multi-mountpoints arrive \x0a-joined and split out below).
fn lsblk_pairs(line: &str) -> Vec<(String, String)> {
    let b = line.as_bytes();
    let mut pairs = Vec::new();
    let mut i = 0usize;
    let hex = |c: u8| -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    };
    while i < b.len() {
        while i < b.len() && b[i] == b' ' {
            i += 1;
        }
        let ks = i;
        while i < b.len() && b[i] != b'=' && b[i] != b' ' {
            i += 1;
        }
        if i >= b.len() || b[i] != b'=' || ks == i {
            break;
        }
        let key = line[ks..i].to_string();
        i += 1;
        if i >= b.len() || b[i] != b'"' {
            break;
        }
        i += 1;
        let mut val: Vec<u8> = Vec::new();
        while i < b.len() && b[i] != b'"' {
            if b[i] == b'\\' && i + 1 < b.len() {
                if b[i + 1] == b'x'
                    && i + 3 < b.len()
                    && hex(b[i + 2]).is_some()
                    && hex(b[i + 3]).is_some()
                {
                    val.push(hex(b[i + 2]).unwrap() * 16 + hex(b[i + 3]).unwrap());
                    i += 4;
                } else {
                    val.push(b[i + 1]);
                    i += 2;
                }
            } else {
                val.push(b[i]);
                i += 1;
            }
        }
        i += 1; // closing quote
        pairs.push((key, String::from_utf8_lossy(&val).to_string()));
    }
    pairs
}

fn lsblk_val<'a>(pairs: &'a [(String, String)], key: &str) -> &'a str {
    pairs
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
        .unwrap_or("")
}

fn lsblk_disks() -> Option<Vec<BlkDisk>> {
    let o = std::process::Command::new("lsblk")
        .args([
            "-P",
            "-b",
            "-o",
            "NAME,PKNAME,MODEL,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,ROTA,TRAN",
        ])
        .output()
        .ok()?;
    if !o.status.success() {
        return None;
    }
    struct Row {
        name: String,
        pkname: String,
        model: String,
        size: u64,
        typ: String,
        fstype: String,
        label: String,
        mount: String,
        rota: u64,
        tran: String,
    }
    let text = String::from_utf8_lossy(&o.stdout);
    let mut rows: Vec<Row> = Vec::new();
    for l in text.lines() {
        if l.trim().is_empty() {
            continue;
        }
        let prs = lsblk_pairs(l);
        rows.push(Row {
            name: lsblk_val(&prs, "NAME").to_string(),
            pkname: lsblk_val(&prs, "PKNAME").to_string(),
            model: lsblk_val(&prs, "MODEL").trim().to_string(),
            size: lsblk_val(&prs, "SIZE").parse().unwrap_or(0),
            typ: lsblk_val(&prs, "TYPE").to_string(),
            fstype: lsblk_val(&prs, "FSTYPE").to_string(),
            label: lsblk_val(&prs, "LABEL").to_string(),
            mount: lsblk_val(&prs, "MOUNTPOINTS")
                .split('\n')
                .next()
                .unwrap_or("")
                .to_string(),
            rota: lsblk_val(&prs, "ROTA").parse().unwrap_or(0),
            tran: lsblk_val(&prs, "TRAN").to_string(),
        });
    }
    if rows.is_empty() {
        return None;
    }
    let mut disks: Vec<BlkDisk> = Vec::new();
    for r in &rows {
        if r.typ != "disk" || !blk_disk_name(&r.name) {
            continue;
        }
        // table order preserved: parts are the TYPE=part rows naming this disk
        let parts = rows
            .iter()
            .filter(|p| p.typ == "part" && p.pkname == r.name)
            .map(|p| BlkPart {
                name: p.name.clone(),
                size: p.size,
                fstype: p.fstype.clone(),
                label: p.label.clone(),
                mount: p.mount.clone(),
            })
            .collect();
        disks.push(BlkDisk {
            name: r.name.clone(),
            model: r.model.clone(),
            size: r.size,
            kind: blk_kind(&r.name, &r.tran),
            rota: r.rota,
            parts,
        });
    }
    disks.sort_by(|a, b| a.name.cmp(&b.name));
    Some(disks)
}

fn sysfs_disks() -> Vec<BlkDisk> {
    // /proc/self/mounts: dev-basename -> (mountpoint, fstype)
    let mut mounts: std::collections::HashMap<String, (String, String)> = Default::default();
    if let Some(ms) = read("/proc/self/mounts") {
        for l in ms.lines() {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 3 || !f[0].starts_with("/dev/") {
                continue;
            }
            // resolve /dev/disk/by-* sources back to the kernel name
            let dev = fs::canonicalize(f[0])
                .ok()
                .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
                .unwrap_or_else(|| f[0].trim_start_matches("/dev/").to_string());
            mounts.insert(dev, (f[1].replace("\\040", " "), f[2].to_string()));
        }
    }
    // fs labels: /dev/disk/by-label/<label> -> ../../<part> (udev \x20-escapes)
    let mut labels: std::collections::HashMap<String, String> = Default::default();
    if let Ok(rd) = fs::read_dir("/dev/disk/by-label") {
        for e in rd.flatten() {
            if let Ok(t) = fs::canonicalize(e.path()) {
                if let Some(dev) = t.file_name().and_then(|n| n.to_str()) {
                    let lbl = e.file_name().to_string_lossy().replace("\\x20", " ");
                    labels.insert(dev.to_string(), lbl);
                }
            }
        }
    }
    let mut disks: Vec<BlkDisk> = Vec::new();
    if let Ok(rd) = fs::read_dir("/sys/block") {
        for e in rd.flatten() {
            let Some(name) = e.file_name().to_str().map(String::from) else {
                continue;
            };
            if !blk_disk_name(&name) {
                continue;
            }
            let d = e.path();
            // usb devices sit under /usbN/ in the resolved sysfs path
            let tran = if fs::canonicalize(&d)
                .map(|p| p.to_string_lossy().contains("/usb"))
                .unwrap_or(false)
            {
                "usb"
            } else {
                ""
            };
            // partition dirs carry a "partition" index file; sort by it
            let mut parts: Vec<(u64, BlkPart)> = Vec::new();
            if let Ok(prd) = fs::read_dir(&d) {
                for pe in prd.flatten() {
                    let p = pe.path();
                    let Some(idx) = read_u64(p.join("partition")) else {
                        continue;
                    };
                    let Some(pn) = p.file_name().and_then(|n| n.to_str()).map(String::from)
                    else {
                        continue;
                    };
                    let (mount, fstype) = mounts.get(&pn).cloned().unwrap_or_default();
                    parts.push((
                        idx,
                        BlkPart {
                            size: read_u64(p.join("size")).unwrap_or(0) * 512,
                            fstype,
                            label: labels.get(&pn).cloned().unwrap_or_default(),
                            mount,
                            name: pn,
                        },
                    ));
                }
            }
            parts.sort_by_key(|(idx, _)| *idx);
            disks.push(BlkDisk {
                model: read(d.join("device/model")).unwrap_or_default(),
                size: read_u64(d.join("size")).unwrap_or(0) * 512,
                rota: read_u64(d.join("queue/rotational")).unwrap_or(0),
                kind: blk_kind(&name, tran),
                parts: parts.into_iter().map(|(_, p)| p).collect(),
                name,
            });
        }
    }
    disks.sort_by(|a, b| a.name.cmp(&b.name));
    disks
}

// disk temp via hwmon: the hwmon whose backing device is this block device's
// `device` (nvme controller dir for nvmeNnM, scsi dev for drivetemp SATA).
fn blk_temp(name: &str) -> Option<u64> {
    let want = fs::canonicalize(format!("/sys/block/{}/device", name)).ok()?;
    for e in fs::read_dir("/sys/class/hwmon").ok()?.flatten() {
        let p = e.path();
        let owner = fs::canonicalize(p.join("device")).ok().or_else(|| {
            // no `device` link: the hwmon dir lives inside its device dir
            fs::canonicalize(&p)
                .ok()
                .and_then(|r| r.parent().and_then(|h| h.parent()).map(Path::to_path_buf))
        });
        if owner.as_ref() == Some(&want) {
            if let Some(t) = read_u64(p.join("temp1_input")) {
                return Some(t / 1000);
            }
        }
    }
    None
}

fn part_usage(mount: &str) -> Option<(u64, u64)> {
    let c = std::ffi::CString::new(mount).ok()?;
    unsafe {
        let mut st: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c.as_ptr(), &mut st) != 0 {
            return None;
        }
        let size = st.f_blocks * st.f_frsize;
        let used = size.saturating_sub(st.f_bfree * st.f_frsize);
        let pct = if size > 0 { used * 100 / size } else { 0 };
        Some((used, pct))
    }
}

fn emit_blockdev<W: Write>(w: &mut W) {
    let disks = lsblk_disks().unwrap_or_else(sysfs_disks);
    out(w, "blk_count", disks.len());
    for (i, d) in disks.iter().enumerate() {
        out(w, format!("blk{}_name", i), &d.name);
        out(w, format!("blk{}_model", i), &d.model);
        out(w, format!("blk{}_size_bytes", i), d.size);
        out(w, format!("blk{}_type", i), d.kind);
        out(w, format!("blk{}_rota", i), d.rota);
        if let Some(t) = blk_temp(&d.name) {
            out(w, format!("blk{}_temp", i), t);
        }
        out(w, format!("blk{}p_count", i), d.parts.len());
        for (j, p) in d.parts.iter().enumerate() {
            out(w, format!("blk{}p{}_name", i, j), &p.name);
            out(w, format!("blk{}p{}_size_bytes", i, j), p.size);
            out(w, format!("blk{}p{}_fstype", i, j), &p.fstype);
            out(w, format!("blk{}p{}_label", i, j), &p.label);
            out(w, format!("blk{}p{}_mount", i, j), &p.mount);
            if !p.mount.is_empty() {
                if let Some((used, pct)) = part_usage(&p.mount) {
                    out(w, format!("blk{}p{}_used_bytes", i, j), used);
                    out(w, format!("blk{}p{}_pct", i, j), pct);
                }
            }
        }
    }
}

// ------------------------------------------------------- extra sensors
//
// Free sysfs reads: NVMe per-drive temps, DIMM temps, per-CCD CPU temps,
// PSI stalls, zram ratio, cpu freq, removable media, omarchy agent-usage
// records, current theme.

fn emit_sensors<W: Write>(w: &mut W) {
    if let Ok(hws) = fs::read_dir("/sys/class/hwmon") {
        let mut dirs: Vec<PathBuf> = hws.flatten().map(|e| e.path()).collect();
        dirs.sort();
        let mut nvme_i = 0usize;
        let mut dimm_i = 0usize;
        for p in dirs {
            let name = read(p.join("name")).unwrap_or_default();
            match name.as_str() {
                "nvme" => {
                    // hwmon device resolves to .../nvme/nvmeN; the controller
                    // dir carries the model string.
                    let model = fs::canonicalize(p.join("device"))
                        .ok()
                        .and_then(|d| d.file_name().map(|n| n.to_string_lossy().to_string()))
                        .and_then(|ctl| read(format!("/sys/class/nvme/{}/model", ctl)))
                        .unwrap_or_else(|| "nvme".into());
                    if let Some(t) = read_u64(p.join("temp1_input")) {
                        out(w, format!("nvme{}_model", nvme_i), model.trim());
                        out(w, format!("nvme{}_temp", nvme_i), t / 1000);
                    }
                    // hottest secondary sensor
                    let mut mx = 0u64;
                    for s in 2..=4 {
                        if let Some(t) = read_u64(p.join(format!("temp{}_input", s))) {
                            mx = mx.max(t / 1000);
                        }
                    }
                    if mx > 0 {
                        out(w, format!("nvme{}_temp2", nvme_i), mx);
                    }
                    nvme_i += 1;
                }
                "spd5118" | "spd5100" => {
                    if let Some(t) = read_u64(p.join("temp1_input")) {
                        out(w, format!("dimm{}_temp", dimm_i), t / 1000);
                        dimm_i += 1;
                    }
                }
                "k10temp" | "zenpower" => {
                    for (i, tag) in [(3u8, "cpu_tccd1"), (4u8, "cpu_tccd2")] {
                        if let Some(t) = read_u64(p.join(format!("temp{}_input", i))) {
                            out(w, tag, t / 1000);
                        }
                    }
                }
                _ => {}
            }
        }
        out(w, "nvme_count", nvme_i);
        out(w, "dimm_count", dimm_i);
    }

    // PSI pressure stalls — avg10 % per resource (the "system stalling" tell)
    for (f, tag) in [
        ("cpu", "cpu"), ("memory", "mem"), ("io", "io"),
    ] {
        if let Some(psi) = read(format!("/proc/pressure/{}", f)) {
            for line in psi.lines() {
                let is_full = line.starts_with("full");
                if !(is_full || line.starts_with("some")) {
                    continue;
                }
                if let Some(a) = line
                    .split_whitespace()
                    .find_map(|kv| kv.strip_prefix("avg10="))
                {
                    out(w, format!("psi_{}_{}", tag, if is_full { "full" } else { "some" }), a);
                }
            }
        }
    }

    // zram compression ratio
    if let Some(mm) = read("/sys/block/zram0/mm_stat") {
        let f: Vec<u64> = mm.split_whitespace().filter_map(|s| s.parse().ok()).collect();
        if f.len() >= 2 && f[1] > 0 {
            out(w, "zram_orig_mb", f[0] / 1_048_576);
            out(w, "zram_used_mb", f[1] / 1_048_576);
            out(w, "zram_ratio", format!("{:.1}", f[0] as f64 / f[1] as f64));
        }
    }

    // mean + peak cpu frequency
    if let Ok(rd) = fs::read_dir("/sys/devices/system/cpu") {
        let mut sum = 0u64;
        let mut mx = 0u64;
        let mut n = 0u64;
        for e in rd.flatten() {
            let p = e.path();
            if p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("cpu") && n[3..].chars().all(|c| c.is_ascii_digit()))
                .unwrap_or(false)
            {
                if let Some(f) = read_u64(p.join("cpufreq/scaling_cur_freq")) {
                    sum += f;
                    mx = mx.max(f);
                    n += 1;
                }
            }
        }
        if n > 0 {
            out(w, "cpu_mhz_avg", sum / n / 1000);
            out(w, "cpu_mhz_max", mx / 1000);
        }
    }

    // mounted removable media under /run/media/<user>
    if let Ok(rd) = fs::read_dir(format!("/run/media/{}", std::env::var("USER").unwrap_or_default())) {
        let mut i = 0usize;
        let mut names: Vec<String> = rd.flatten()
            .filter_map(|e| e.file_name().to_str().map(String::from))
            .collect();
        names.sort();
        for n in names {
            out(w, format!("media{}_name", i), n);
            i += 1;
        }
        out(w, "media_count", i);
    }

    // omarchy agent-usage records: ~/.local/state/omarchy/agents/usage/<id>.json
    let home = std::env::var("HOME").unwrap_or_default();
    if let Ok(rd) = fs::read_dir(format!("{}/.local/state/omarchy/agents/usage", home)) {
        let mut i = 0usize;
        let mut entries: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for p in entries {
            if p.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let id = p.file_stem().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if let Some(js) = read(&p) {
                // minimal JSON scalar grab: handles "key":"str" and "key":123
                let grab = |key: &str| -> String {
                    let pat = format!("\"{}\":", key);
                    let Some(idx) = js.find(&pat) else { return String::new() };
                    let rest = js[idx + pat.len()..].trim_start();
                    if let Some(stripped) = rest.strip_prefix('"') {
                        stripped.split('"').next().unwrap_or("").to_string()
                    } else {
                        rest.split(|c: char| c == ',' || c == '}' || c == ']')
                            .next()
                            .unwrap_or("")
                            .trim()
                            .to_string()
                    }
                };
                out(w, format!("aguse{}_id", i), id);
                out(w, format!("aguse{}_tokens", i), grab("todayTotalTokens"));
                out(w, format!("aguse{}_status", i), grab("usageStatusText"));
                i += 1;
            }
        }
        out(w, "aguse_count", i);
    }

    // current omarchy theme name (single-line state file)
    if let Some(t) = read(format!("{}/.local/state/omarchy/current/theme.name", home)) {
        out(w, "theme_name", t);
    }
}

// Devin CLI live sessions: ~/.local/share/devin/cli/session_locks/*.lock
// Filename = session name; content = PID. A lock whose pid is dead is stale.
fn emit_devin_sessions<W: Write>(w: &mut W) {
    let dir = dirs_next(std::env::var("HOME").unwrap_or_default())
        .join(".local/share/devin/cli/session_locks");
    let mut i = 0usize;
    if let Ok(rd) = fs::read_dir(&dir) {
        let mut entries: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for p in entries {
            if p.extension().and_then(|e| e.to_str()) != Some("lock") {
                continue;
            }
            let pid = read(&p).unwrap_or_default();
            let alive = !pid.is_empty() && Path::new(&format!("/proc/{}", pid)).exists();
            let name = p
                .file_stem()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            out(w, format!("devsess{}_name", i), name);
            out(w, format!("devsess{}_pid", i), pid);
            out(w, format!("devsess{}_live", i), if alive { 1 } else { 0 });
            i += 1;
            if i >= 12 {
                break;
            }
        }
    }
    out(w, "devsess_count", i);
}

fn dirs_next(home: impl AsRef<Path>) -> PathBuf {
    PathBuf::from(home.as_ref())
}

// ----------------------------------------------------------------- agents

// Classify a process into an agent-harness tag. comm alone is not enough —
// Devin and October run as electron whose comm is "electron", so ambiguous
// comms fall through to a cmdline read.
fn agent_tag(dir: &Path, comm: &str) -> String {
    match comm {
        "opencode" => return "opencode".into(),
        "claude" => return "claude".into(),
        "codex" => return "codex".into(),
        "aider" => return "aider".into(),
        "gemini" => return "gemini".into(),
        "crush" => return "crush".into(),
        "openclaw" => return "openclaw".into(),
        "hermes" => return "hermes".into(),
        "devin" => return "devin".into(),
        "october-desktop" | "october" => return "october".into(),
        "rustc" | "cargo" | "npm" | "npx" | "vite" | "esbuild" | "tsc" | "cmake"
        | "ninja" | "make" | "g++" | "gcc" | "clang" | "link" | "ld" | "mold" => {
            return "build".into()
        }
        _ => {}
    }
    if matches!(comm, "electron" | "node" | "Electron") {
        let cmd = read(dir.join("cmdline"))
            .unwrap_or_default()
            .replace('\0', " ")
            .to_lowercase();
        for (needle, tag) in [
            ("devin", "devin"),
            ("october", "october"),
            ("opencode", "opencode"),
            ("hermes", "hermes"),
            ("haze", "haze"),
        ] {
            if cmd.contains(needle) {
                return tag.into();
            }
        }
    }
    String::new()
}

fn emit_agents<W: Write>(w: &mut W, prev: &Prev) {
    // tmux sockets: /tmp/tmux-<uid>/default* entries
    let uid = unsafe { libc::getuid() };
    let tmux_dir = format!("/tmp/tmux-{}", uid);
    let n = fs::read_dir(&tmux_dir)
        .map(|d| d.flatten().count())
        .unwrap_or(0);
    out(w, "agents_tmux", n);

    // agent procs: scan /proc/*/comm against the known set
    let names = [
        "claude", "codex", "opencode", "aider", "gemini", "crush", "devin", "openclaw", "hermes",
        "october-desktop", "october",
    ];
    let mut count = 0u64;
    let mut devin_acp = 0u64;
    if let Ok(rd) = fs::read_dir("/proc") {
        for e in rd.flatten() {
            let fname = e.file_name();
            let Some(name) = fname.to_str() else { continue };
            if !name.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            if let Some(comm) = read(e.path().join("comm")) {
                if names.iter().any(|n| comm == *n) {
                    count += 1;
                }
                // devin acp sessions ride on the desktop's electron process
                if comm == "devin" || comm == "electron" || comm == "Electron" {
                    if let Some(cmd) = read(e.path().join("cmdline")) {
                        let c = cmd.replace('\0', " ").to_lowercase();
                        if c.contains("devin") && c.contains("acp") {
                            devin_acp += 1;
                        }
                    }
                }
            }
        }
    }
    out(w, "agents_procs", count);
    out(w, "ag_devin_acp", devin_acp);

    // per-harness rollups from the last frame's per-pid cpu% table
    for tag in ["devin", "opencode", "hermes", "october", "claude", "codex", "haze", "build"] {
        let mut procs = 0u64;
        let mut cpu = 0.0f64;
        for (_pid, pct, _comm, t) in &prev.proc_pct {
            if t == tag {
                procs += 1;
                cpu += pct;
            }
        }
        out(w, format!("ag_{}_procs", tag), procs);
        out(w, format!("ag_{}_cpu", tag), format!("{:.0}", cpu));
    }
}

// -------------------------------------------------------------- slow lane
//
// Network/subprocess producers that must not run at stream cadence. A
// background thread refreshes a shared key→value map; each batch dumps the
// current cache. Stale values are better than blocking the stream.

type SlowMap = Arc<Mutex<BTreeMap<String, String>>>;

fn gh_cmd(args: &[&str]) -> Option<String> {
    let o = std::process::Command::new("gh")
        .args(args)
        .output()
        .ok()?;
    if o.status.success() {
        Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
    } else {
        None
    }
}

fn github_poll(map: &SlowMap) {
    let mut m = map.lock().unwrap();
    m.insert("gh_ok".into(), "0".into());
    let Some(login) = gh_cmd(&["api", "user", "--jq", ".login"]) else {
        return;
    };
    if login.is_empty() {
        return;
    }
    m.insert("gh_user".into(), login.clone());

    if let Some(n) = gh_cmd(&["api", "notifications", "--jq", "length"]) {
        m.insert("gh_unread".into(), n);
    }

    // events feed: type / repo / created-epoch, newest 6
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let q = ".[:6][] | [.type, .repo.name, (.created_at | fromdateiso8601 | floor | tostring)] | join(\"\\t\")";
    if let Some(feed) = gh_cmd(&["api", &format!("users/{}/events", login), "--jq", q]) {
        let mut i = 0usize;
        for line in feed.lines().take(6) {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 3 {
                continue;
            }
            m.insert(format!("ghev{}_type", i), f[0].into());
            m.insert(format!("ghev{}_repo", i), f[1].into());
            let age = f[2]
                .parse::<u64>()
                .map(|t| now.saturating_sub(t))
                .unwrap_or(0);
            m.insert(format!("ghev{}_age_s", i), age.to_string());
            i += 1;
        }
        m.insert("ghev_count".into(), i.to_string());
    }
    m.insert("gh_ok".into(), "1".into());
}

// Hyprland clients/workspaces via jq — fields unit-separator joined so window
// titles containing tabs don't corrupt the TSV contract.
fn hypr_poll(map: &SlowMap) {
    let o = std::process::Command::new("sh")
        .args([
            "-c",
            "hyprctl -j clients 2>/dev/null | jq -r '.[] | [.address, .workspace.name, .workspace.id, .class, .initialClass, (.title | gsub(\"[\\t\\n\\u001f]\"; \" \")), .monitor] | join(\"\\u001f\")' 2>/dev/null",
        ])
        .output();
    if let Ok(o) = o {
        if o.status.success() {
            let text = String::from_utf8_lossy(&o.stdout);
            let mut m = map.lock().unwrap();
            let mut i = 0usize;
            for line in text.lines().take(24) {
                let f: Vec<&str> = line.split('\u{1f}').collect();
                if f.len() < 7 {
                    continue;
                }
                m.insert(format!("win{}_addr", i), f[0].into());
                m.insert(format!("win{}_ws", i), f[1].into());
                m.insert(format!("win{}_wsid", i), f[2].into());
                m.insert(format!("win{}_class", i), f[3].into());
                m.insert(format!("win{}_title", i), f[5].into());
                m.insert(format!("win{}_mon", i), f[6].into());
                i += 1;
            }
            m.insert("win_count".into(), i.to_string());
        }
    }

    let o2 = std::process::Command::new("sh")
        .args([
            "-c",
            "hyprctl -j workspaces 2>/dev/null | jq -r '.[] | [.id, .name, .monitor, (.windows | tostring)] | join(\"\\u001f\")' 2>/dev/null",
        ])
        .output();
    if let Ok(o) = o2 {
        if o.status.success() {
            let text = String::from_utf8_lossy(&o.stdout);
            let mut m = map.lock().unwrap();
            let mut i = 0usize;
            for line in text.lines().take(16) {
                let f: Vec<&str> = line.split('\u{1f}').collect();
                if f.len() < 4 {
                    continue;
                }
                m.insert(format!("ws{}_id", i), f[0].into());
                m.insert(format!("ws{}_name", i), f[1].into());
                m.insert(format!("ws{}_mon", i), f[2].into());
                m.insert(format!("ws{}_wins", i), f[3].into());
                i += 1;
            }
            m.insert("ws_count".into(), i.to_string());
        }
    }
}

fn tmux_poll(map: &SlowMap) {
    if let Ok(o) = std::process::Command::new("tmux")
        .args([
            "list-sessions",
            "-F",
            "#{session_name}\t#{session_windows}\t#{session_attached}",
        ])
        .output()
    {
        if o.status.success() {
            let text = String::from_utf8_lossy(&o.stdout);
            let mut m = map.lock().unwrap();
            let mut i = 0usize;
            for line in text.lines().take(8) {
                let f: Vec<&str> = line.split('\t').collect();
                if f.len() < 3 {
                    continue;
                }
                m.insert(format!("tmux{}_name", i), f[0].into());
                m.insert(format!("tmux{}_win", i), f[1].into());
                m.insert(format!("tmux{}_att", i), f[2].into());
                i += 1;
            }
            m.insert("tmux_n".into(), i.to_string());
        }
    }
}

fn misc_poll(map: &SlowMap) {
    // pending updates (pacman-contrib); weather via omarchy's wttr.in wrapper
    if let Ok(o) = std::process::Command::new("sh")
        .args(["-c", "checkupdates 2>/dev/null | wc -l"])
        .output()
    {
        if o.status.success() {
            let n = String::from_utf8_lossy(&o.stdout).trim().to_string();
            map.lock().unwrap().insert("pkg_updates".into(), n);
        }
    }
    if let Ok(o) = std::process::Command::new("omarchy-weather-status").output() {
        if o.status.success() {
            let t = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !t.is_empty() {
                map.lock().unwrap().insert("weather".into(), t);
            }
        }
    }
}

fn start_slow_lane() -> SlowMap {
    let map: SlowMap = Arc::new(Mutex::new(BTreeMap::new()));
    let m2 = Arc::clone(&map);
    std::thread::spawn(move || {
        let mut gh_t = Instant::now() - Duration::from_secs(120);
        let mut tmux_t = Instant::now() - Duration::from_secs(10);
        let mut hypr_t = Instant::now() - Duration::from_secs(10);
        let mut misc_t = Instant::now() - Duration::from_secs(1900);
        let mut abt_t = Instant::now() - Duration::from_secs(10);
        loop {
            if gh_t.elapsed().as_secs() >= 90 {
                gh_t = Instant::now();
                github_poll(&m2);
            }
            if tmux_t.elapsed().as_secs() >= 5 {
                tmux_t = Instant::now();
                tmux_poll(&m2);
            }
            if hypr_t.elapsed().as_secs() >= 3 {
                hypr_t = Instant::now();
                hypr_poll(&m2);
            }
            if misc_t.elapsed().as_secs() >= 900 {
                misc_t = Instant::now();
                misc_poll(&m2);
            }
            if abt_t.elapsed().as_secs() >= 3 {
                abt_t = Instant::now();
                devices::audio_bt_poll(&m2);
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    });
    map
}

fn emit_slow<W: Write>(w: &mut W, map: &SlowMap) {
    if let Ok(m) = map.lock() {
        for (k, v) in m.iter() {
            out(w, k, v);
        }
    }
}

// ------------------------------------------------------------------- main

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(|s| s.as_str()).unwrap_or("poll");

    match mode {
        "probe" => probe(),
        "stream" => {
            let gpus = find_gpus();
            let mut intel_energy: Vec<Option<(u64, Instant)>> = vec![None; gpus.len()];
            let mut prev = Prev::default();
            let mut dev_prev = devices::DevPrev::default();
            let slow = start_slow_lane();
            let mut batch = 0u64;
            loop {
                let stdout = io::stdout();
                let mut w = BufWriter::new(stdout.lock());
                emit_poll(&mut w, &gpus, &mut intel_energy, &mut prev);
                emit_batteries(&mut w);
                emit_sensors(&mut w);
                devices::emit_devices(&mut w, &gpus, &mut dev_prev);
                emit_blockdev(&mut w);
                emit_devin_sessions(&mut w);
                emit_agents(&mut w, &prev);
                emit_slow(&mut w, &slow);
                out(&mut w, "batch", batch);
                let _ = w.flush();
                batch += 1;
                std::thread::sleep(Duration::from_millis(1000));
            }
        }
        _ => {
            // poll (single batch)
            let gpus = find_gpus();
            let mut intel_energy: Vec<Option<(u64, Instant)>> = vec![None; gpus.len()];
            let mut prev = Prev::default();
            let mut dev_prev = devices::DevPrev::default();
            let stdout = io::stdout();
            let mut w = BufWriter::new(stdout.lock());
            emit_poll(&mut w, &gpus, &mut intel_energy, &mut prev);
            emit_batteries(&mut w);
            emit_sensors(&mut w);
            devices::emit_devices(&mut w, &gpus, &mut dev_prev);
            emit_blockdev(&mut w);
            emit_devin_sessions(&mut w);
            emit_agents(&mut w, &prev);
            let _ = w.flush();
        }
    }
}
