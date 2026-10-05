// devices.rs — dev_* telemetry keys (BRIEF-V4-BUILD, lane C).
//
// A key is emitted only when its source read succeeds: absent hardware means
// an absent key, never 0. Everything runs off /sys + /proc reads on the 1 Hz
// batch cadence; audio sinks and bluetooth counts come from the slow lane
// (pactl, bluetoothctl at multi-second cadence, cached — never per frame).

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::{out, read, read_u64, Gpu, GpuKind, SlowMap, hwmon_dir};

// Raw-counter state needed between frames for rates and busy%. Mirrors the
// Prev pattern in main.rs: populated each batch, read against the next.
#[derive(Default)]
pub struct DevPrev {
    cpu_topo: Option<Vec<Vec<usize>>>,       // physical core -> logical threads
    cores: Vec<(u64, u64)>,                   // per logical cpu (idle+iowait, total)
    gpu_energy: HashMap<usize, (u64, Instant)>, // gpu idx -> (energy uJ, t)
    gpu_idle: HashMap<(usize, usize, usize), (u64, Instant)>, // (gpu, tile, gt) -> (idle residency ms, t)
    nvme: HashMap<String, (u64, u64, Instant)>,  // disk -> (rd sectors, wr sectors, t)
    nic: HashMap<String, (u64, u64, Instant)>,   // iface -> (rx bytes, tx bytes, t)
}

pub fn emit_devices<W: Write>(w: &mut W, gpus: &[Gpu], prev: &mut DevPrev) {
    emit_cpu(w, prev);
    emit_ccd(w);
    emit_dimms(w);
    emit_gpus(w, gpus, prev);
    emit_pcie(w);
    emit_nvme(w, prev);
    emit_nics(w, prev);
    emit_usb(w);
    emit_fans(w);
}

// ------------------------------------------------------------ helpers

fn sorted_hwmons() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir("/sys/class/hwmon")
        .map(|d| d.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

// (label, °C) pairs for every tempN_label/tempN_input in an hwmon dir.
fn labeled_temps(hw: &Path) -> Vec<(String, u64)> {
    let mut idxs: Vec<u32> = fs::read_dir(hw)
        .map(|d| {
            d.flatten()
                .filter_map(|e| {
                    let n = e.file_name().to_str()?.to_string();
                    n.strip_prefix("temp")?.strip_suffix("_label")?.parse().ok()
                })
                .collect()
        })
        .unwrap_or_default();
    idxs.sort_unstable();
    let mut v = Vec::new();
    for i in idxs {
        if let (Some(l), Some(t)) = (
            read(hw.join(format!("temp{}_label", i))),
            read_u64(hw.join(format!("temp{}_input", i))),
        ) {
            v.push((l, t / 1000));
        }
    }
    v
}

// -------------------------------------------------- CPU cores (dev_core)

// "0,12" / "0-3,12-15" -> thread list
fn parse_cpu_list(s: &str) -> Vec<usize> {
    let mut v = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        if let Some((a, b)) = part.split_once('-') {
            if let (Ok(a), Ok(b)) = (a.parse::<usize>(), b.parse::<usize>()) {
                for i in a..=b {
                    v.push(i);
                }
            }
        } else if let Ok(n) = part.parse::<usize>() {
            v.push(n);
        }
    }
    v
}

// One SMT thread group per physical core, ordered by lowest thread id, so
// dev_core{i} lines up with the CCD core nodes in recon/devices-bus.json.
fn cpu_topology() -> Vec<Vec<usize>> {
    let mut groups: Vec<Vec<usize>> = Vec::new();
    let Ok(rd) = fs::read_dir("/sys/devices/system/cpu") else {
        return groups;
    };
    for e in rd.flatten() {
        let Some(name) = e.file_name().to_str().map(String::from) else {
            continue;
        };
        if !(name.starts_with("cpu") && name.len() > 3 && name[3..].chars().all(|c| c.is_ascii_digit())) {
            continue;
        }
        let Some(sib) = read(e.path().join("topology/thread_siblings_list")) else {
            continue;
        };
        let mut set = parse_cpu_list(&sib);
        if set.is_empty() {
            continue;
        }
        set.sort_unstable();
        set.dedup();
        let min = set[0];
        if !groups.iter().any(|g| g[0] == min) {
            groups.push(set);
        }
    }
    groups.sort_by_key(|g| g[0]);
    groups
}

fn emit_cpu<W: Write>(w: &mut W, prev: &mut DevPrev) {
    if prev.cpu_topo.is_none() {
        prev.cpu_topo = Some(cpu_topology());
    }
    let Some(topo) = prev.cpu_topo.clone() else { return };
    if topo.is_empty() {
        return;
    }
    let Some(stat) = read("/proc/stat") else { return };
    let mut cur: Vec<(u64, u64)> = Vec::new();
    for line in stat.lines() {
        if !line.starts_with("cpu") || line.starts_with("cpu ") {
            continue;
        }
        let mut it = line.split_whitespace();
        let Some(name) = it.next() else { continue };
        let Ok(n) = name[3..].parse::<usize>() else {
            continue;
        };
        let f: Vec<u64> = it.filter_map(|s| s.parse().ok()).collect();
        if f.len() < 8 {
            continue;
        }
        let idle = f[3] + f[4];
        let total: u64 = f.iter().sum();
        while cur.len() <= n {
            cur.push((0, 0));
        }
        cur[n] = (idle, total);
    }
    let have_prev = !cur.is_empty() && prev.cores.len() == cur.len();
    for (i, grp) in topo.iter().enumerate() {
        let rep = grp[0];
        if let Some(f) = read_u64(format!("/sys/devices/system/cpu/cpu{}/cpufreq/scaling_cur_freq", rep)) {
            out(w, format!("dev_core{}_mhz", i), f / 1000);
        }
        if !have_prev {
            continue;
        }
        // busy% of the SMT pair: mean thread busy = 1 - ΣΔidle/ΣΔtotal
        let (mut di, mut dt) = (0u64, 0u64);
        for &t in grp {
            if t >= cur.len() {
                continue;
            }
            let (i1, t1) = cur[t];
            let (i0, t0) = prev.cores[t];
            di += i1.saturating_sub(i0);
            dt += t1.saturating_sub(t0);
        }
        if dt > 0 {
            let pct = 100.0 * (1.0 - di as f64 / dt as f64);
            out(w, format!("dev_core{}_pct", i), format!("{:.0}", pct.max(0.0).min(100.0)));
        }
    }
    if !cur.is_empty() {
        prev.cores = cur;
    }
}

// -------------------------------------------------- CCD temps (dev_ccd)

fn emit_ccd<W: Write>(w: &mut W) {
    for p in sorted_hwmons() {
        let name = read(p.join("name")).unwrap_or_default();
        if !matches!(name.as_str(), "k10temp" | "zenpower") {
            continue;
        }
        for (l, t) in labeled_temps(&p) {
            match l.as_str() {
                "Tccd1" => out(w, "dev_ccd0_t", t),
                "Tccd2" => out(w, "dev_ccd1_t", t),
                _ => {}
            }
        }
    }
}

// -------------------------------------------------- DIMM temps (dev_dimm)

fn emit_dimms<W: Write>(w: &mut W) {
    let mut i = 0usize;
    for p in sorted_hwmons() {
        if !matches!(read(p.join("name")).as_deref(), Some("spd5118") | Some("spd5100")) {
            continue;
        }
        if let Some(t) = read_u64(p.join("temp1_input")) {
            out(w, format!("dev_dimm{}_t", i), t / 1000);
            i += 1;
        }
    }
}

// -------------------------------------------------- GPU vitals (dev_gpu)

fn emit_gpus<W: Write>(w: &mut W, gpus: &[Gpu], prev: &mut DevPrev) {
    for (i, g) in gpus.iter().enumerate() {
        let d = &g.device;
        match g.kind {
            GpuKind::Intel => {
                if let Some(hw) = hwmon_dir(d, "xe") {
                    for (l, t) in labeled_temps(&hw) {
                        if l == "pkg" {
                            out(w, format!("dev_gpu{}_temp", i), t);
                        }
                    }
                    // hwmon freq is Hz; xe kernels without it expose the tile clock in MHz
                    if let Some(f) = read_u64(hw.join("freq1_input")) {
                        out(w, format!("dev_gpu{}_mhz", i), f / 1_000_000);
                    } else if let Some(f) = read_u64(d.join("tile0/gt0/freq0/cur_freq")) {
                        out(w, format!("dev_gpu{}_mhz", i), f);
                    }
                    if let Some(e) = read_u64(hw.join("energy1_input")) {
                        if let Some((pe, pt)) = prev.gpu_energy.get(&i) {
                            let dt = pt.elapsed().as_secs_f64();
                            if dt > 0.1 && e >= *pe {
                                out(w, format!("dev_gpu{}_pw", i), ((e - pe) as f64 / dt / 1e6) as u64);
                            }
                        }
                        prev.gpu_energy.insert(i, (e, Instant::now()));
                    }
                }
                // Busy%: i915-era sysfs exposes gpu_busy_percent; xe does not.
                // Its GTs carry tileN/gtM/gtidle/idle_residency_ms counters
                // instead — busy = 1 - Δidle/Δwall, busiest GT wins. The first
                // frame only seeds the delta (same contract as the rate keys).
                if let Some(u) = read_u64(d.join("gpu_busy_percent")) {
                    out(w, format!("dev_gpu{}_pct", i), u);
                } else {
                    let mut busy: Option<f64> = None;
                    for tile in 0..4usize {
                        for gt in 0..8usize {
                            let p = d.join(format!("tile{}/gt{}/gtidle/idle_residency_ms", tile, gt));
                            let Some(idle) = read_u64(&p) else { continue };
                            let key = (i, tile, gt);
                            if let Some(&(pi, pt)) = prev.gpu_idle.get(&key) {
                                let dt_ms = pt.elapsed().as_secs_f64() * 1000.0;
                                if dt_ms > 100.0 && idle >= pi {
                                    let b = (1.0 - (idle - pi) as f64 / dt_ms) * 100.0;
                                    busy = Some(busy.map_or(b, |x| x.max(b)));
                                }
                            }
                            prev.gpu_idle.insert(key, (idle, Instant::now()));
                        }
                    }
                    if let Some(b) = busy {
                        out(w, format!("dev_gpu{}_pct", i), format!("{:.0}", b.clamp(0.0, 100.0)));
                    }
                }
                if let Some(v) = read_u64(d.join("mem_info_vram_used")) {
                    out(w, format!("dev_gpu{}_vram", i), v / 1_048_576);
                }
            }
            GpuKind::Amd => {
                if let Some(u) = read_u64(d.join("gpu_busy_percent")) {
                    out(w, format!("dev_gpu{}_pct", i), u);
                }
                if let Some(v) = read_u64(d.join("mem_info_vram_used")) {
                    out(w, format!("dev_gpu{}_vram", i), v / 1_048_576);
                }
                if let Some(hw) = hwmon_dir(d, "amdgpu") {
                    if let Some(t) = read_u64(hw.join("temp1_input")) {
                        out(w, format!("dev_gpu{}_temp", i), t / 1000);
                    }
                    if let Some(p) = read_u64(hw.join("power1_input")) {
                        out(w, format!("dev_gpu{}_pw", i), p / 1_000_000);
                    }
                    if let Some(f) = read_u64(hw.join("freq1_input")) {
                        out(w, format!("dev_gpu{}_mhz", i), f / 1_000_000);
                    }
                }
            }
            _ => {}
        }
    }
}

// -------------------------------------------------- PCIe links (dev_pcie)

// current_link_speed reads "16.0 GT/s PCIe" (or "16"): leading GT/s -> gen.
fn pcie_gen(speed: &str) -> Option<u64> {
    let g = speed.split_whitespace().next()?.parse::<f64>().ok()?;
    Some(match g {
        x if x <= 2.5 => 1,
        x if x <= 5.0 => 2,
        x if x <= 8.0 => 3,
        x if x <= 16.0 => 4,
        x if x <= 32.0 => 5,
        x if x <= 64.0 => 6,
        _ => return None,
    })
}

fn emit_pcie<W: Write>(w: &mut W) {
    let Ok(rd) = fs::read_dir("/sys/bus/pci/devices") else { return };
    let mut bdfs: Vec<String> = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(String::from))
        .collect();
    bdfs.sort();
    for bdf in bdfs {
        let d = PathBuf::from("/sys/bus/pci/devices").join(&bdf);
        let (Some(speed), Some(width)) = (read(d.join("current_link_speed")), read_u64(d.join("current_link_width")))
        else {
            continue;
        };
        let Some(gen) = pcie_gen(&speed) else { continue };
        out(w, format!("dev_pcie_{}_gen", bdf), gen);
        out(w, format!("dev_pcie_{}_width", bdf), width);
    }
}

// -------------------------------------------------- NVMe (dev_nvme)

fn emit_nvme<W: Write>(w: &mut W, prev: &mut DevPrev) {
    let Ok(rd) = fs::read_dir("/sys/class/nvme") else { return };
    let mut ctls: Vec<String> = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(String::from))
        .collect();
    ctls.sort_by_key(|n| n.trim_start_matches("nvme").parse::<u64>().unwrap_or(0));

    let diskstats = read("/proc/diskstats");
    for (i, ctl) in ctls.iter().enumerate() {
        let base = PathBuf::from("/sys/class/nvme").join(ctl);
        // composite temp: hwmonN dir lives inside the controller dir
        if let Ok(hrd) = fs::read_dir(&base) {
            let mut hws: Vec<PathBuf> = hrd
                .flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name()
                        .and_then(|n| n.to_str())
                        .map(|n| n.starts_with("hwmon"))
                        .unwrap_or(false)
                })
                .collect();
            hws.sort();
            for hw in hws {
                if let Some(t) = read_u64(hw.join("temp1_input")) {
                    out(w, format!("dev_nvme{}_t", i), t / 1000);
                    break;
                }
            }
        }
        // rd/wr B/s: whole-disk sector deltas (nvmeNn1)
        let disk = format!("{}n1", ctl);
        let Some(ds) = &diskstats else { continue };
        for line in ds.lines() {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() < 14 || f[2] != disk {
                continue;
            }
            if let (Ok(rd), Ok(wr)) = (f[5].parse::<u64>(), f[9].parse::<u64>()) {
                if let Some((prd, pwr, pt)) = prev.nvme.get(&disk) {
                    let dt = pt.elapsed().as_secs_f64();
                    if dt > 0.1 {
                        out(w, format!("dev_nvme{}_rd", i), ((rd.saturating_sub(*prd) * 512) as f64 / dt) as u64);
                        out(w, format!("dev_nvme{}_wr", i), ((wr.saturating_sub(*pwr) * 512) as f64 / dt) as u64);
                    }
                }
                prev.nvme.insert(disk.clone(), (rd, wr, Instant::now()));
            }
            break;
        }
    }
}

// -------------------------------------------------- NICs (dev_nic)

fn emit_nics<W: Write>(w: &mut W, prev: &mut DevPrev) {
    let Ok(rd) = fs::read_dir("/sys/class/net") else { return };
    let mut ifaces: Vec<String> = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(String::from))
        .collect();
    ifaces.sort();
    let netdev = read("/proc/net/dev");
    for name in ifaces {
        if name == "lo" {
            continue;
        }
        let p = PathBuf::from("/sys/class/net").join(&name);
        if let Some(state) = read(p.join("operstate")) {
            out(w, format!("dev_nic_{}_up", name), if state == "up" { 1 } else { 0 });
        }
        let Some(nd) = &netdev else { continue };
        for l in nd.lines().skip(2) {
            let Some((iface, rest)) = l.split_once(':') else { continue };
            if iface.trim() != name {
                continue;
            }
            let f: Vec<u64> = rest.split_whitespace().filter_map(|s| s.parse().ok()).collect();
            if f.len() >= 9 {
                let (rx, tx) = (f[0], f[8]);
                if let Some((prx, ptx, pt)) = prev.nic.get(&name) {
                    let dt = pt.elapsed().as_secs_f64();
                    if dt > 0.1 {
                        out(w, format!("dev_nic_{}_rx", name), (rx.saturating_sub(*prx) as f64 / dt) as u64);
                        out(w, format!("dev_nic_{}_tx", name), (tx.saturating_sub(*ptx) as f64 / dt) as u64);
                    }
                }
                prev.nic.insert(name.clone(), (rx, tx, Instant::now()));
            }
            break;
        }
    }
}

// -------------------------------------------------- USB (dev_usb)

// vid:pid -> capacity %, matched by longest USB-device path prefix of the
// power_supply device symlink (so a hub does not swallow a leaf battery).
fn usb_batteries(usb_real: &[(String, PathBuf)]) -> HashMap<String, u64> {
    let mut map = HashMap::new();
    let Ok(rd) = fs::read_dir("/sys/class/power_supply") else {
        return map;
    };
    for e in rd.flatten() {
        let p = e.path();
        let Some(cap) = read_u64(p.join("capacity")) else { continue };
        let Some(dev) = fs::canonicalize(p.join("device")).ok() else { continue };
        let mut best: Option<(usize, &String)> = None;
        for (id, real) in usb_real {
            if dev.starts_with(real) && best.as_ref().map(|(l, _)| real.as_os_str().len() > *l).unwrap_or(true) {
                best = Some((real.as_os_str().len(), id));
            }
        }
        if let Some((_, id)) = best {
            if let (Some(v), Some(p)) = (read(format!("/sys/bus/usb/devices/{}/idVendor", id)), read(format!("/sys/bus/usb/devices/{}/idProduct", id))) {
                map.insert(format!("{}:{}", v, p), cap);
            }
        }
    }
    map
}

fn emit_usb<W: Write>(w: &mut W) {
    let Ok(rd) = fs::read_dir("/sys/bus/usb/devices") else { return };
    let mut devs: Vec<String> = rd
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(String::from))
        .filter(|n| !n.contains(':') && !n.starts_with("usb"))
        .filter(|n| n.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false))
        .collect();
    devs.sort();
    let usb_real: Vec<(String, PathBuf)> = devs
        .iter()
        .filter_map(|n| {
            fs::canonicalize(PathBuf::from("/sys/bus/usb/devices").join(n))
                .ok()
                .map(|p| (n.clone(), p))
        })
        .collect();
    let batts = usb_batteries(&usb_real);
    let mut seen: Vec<String> = Vec::new();
    for (n, _) in &usb_real {
        let base = PathBuf::from("/sys/bus/usb/devices").join(n);
        let (Some(vid), Some(pid)) = (
            read(base.join("idVendor")),
            read(base.join("idProduct")),
        ) else {
            continue;
        };
        let key = format!("{}:{}", vid, pid);
        if seen.contains(&key) {
            continue;
        }
        let name = read(base.join("product"))
            .filter(|s| !s.is_empty())
            .or_else(|| read(base.join("manufacturer")).filter(|s| !s.is_empty()));
        let batt = batts.get(&key).copied();
        if name.is_none() && batt.is_none() {
            continue;
        }
        if let Some(nm) = name {
            out(w, format!("dev_usb_{}_name", key), nm);
        }
        if let Some(b) = batt {
            out(w, format!("dev_usb_{}_batt", key), b);
        }
        seen.push(key);
    }
}

// -------------------------------------------------- fans (dev_fans)

fn emit_fans<W: Write>(w: &mut W) {
    let mut i = 0usize;
    for p in sorted_hwmons() {
        let mut fans: Vec<u32> = fs::read_dir(&p)
            .map(|d| {
                d.flatten()
                    .filter_map(|e| {
                        let n = e.file_name().to_str()?.to_string();
                        n.strip_prefix("fan")?.strip_suffix("_input")?.parse().ok()
                    })
                    .collect()
            })
            .unwrap_or_default();
        fans.sort_unstable();
        for f in fans {
            if let Some(rpm) = read_u64(p.join(format!("fan{}_input", f))) {
                out(w, format!("dev_fans{}_rpm", i), rpm);
                i += 1;
            }
        }
    }
}

// -------------------------------------------------- slow lane: audio + BT

fn flush_sink(m: &mut BTreeMap<String, String>, i: usize, sink: &str, desc: &str, vol: Option<u64>) -> usize {
    if sink.is_empty() {
        return i;
    }
    if !desc.is_empty() {
        m.insert(format!("dev_audio{}_name", i), desc.to_string());
    }
    m.insert(format!("dev_audio{}_sink", i), sink.to_string());
    if let Some(v) = vol {
        m.insert(format!("dev_audio{}_vol", i), v.to_string());
    }
    i + 1
}

// "Volume: front-left: 39321 /  60% / -13.31 dB, ..." -> mean channel %
fn avg_pct(s: &str) -> Option<u64> {
    let vals: Vec<f64> = s
        .split_whitespace()
        .filter(|t| t.ends_with('%'))
        .filter_map(|t| t.trim_end_matches('%').parse::<f64>().ok())
        .collect();
    if vals.is_empty() {
        return None;
    }
    Some((vals.iter().sum::<f64>() / vals.len() as f64).round() as u64)
}

// Background refresh for the slow-lane map: pactl sinks (~3s) and, when a
// bluetooth controller exists, paired/connected counts via bluetoothctl.
pub fn audio_bt_poll(map: &SlowMap) {
    {
        let mut m = map.lock().unwrap();
        m.retain(|k, _| !k.starts_with("dev_audio"));
    }
    if let Ok(o) = std::process::Command::new("pactl")
        .args(["list", "sinks"])
        .output()
    {
        if o.status.success() {
            let text = String::from_utf8_lossy(&o.stdout).to_string();
            let mut m = map.lock().unwrap();
            let mut i = 0usize;
            let mut sink = String::new();
            let mut desc = String::new();
            let mut vol: Option<u64> = None;
            for line in text.lines() {
                let t = line.trim_start();
                if t.starts_with("Sink #") {
                    i = flush_sink(&mut m, i, &sink, &desc, vol);
                    sink.clear();
                    desc.clear();
                    vol = None;
                } else if let Some(v) = t.strip_prefix("Name: ") {
                    sink = v.trim().to_string();
                } else if let Some(v) = t.strip_prefix("Description: ") {
                    desc = v.trim().to_string();
                } else if let Some(v) = t.strip_prefix("Volume: ") {
                    vol = avg_pct(v);
                }
            }
            flush_sink(&mut m, i, &sink, &desc, vol);
        }
    }
    if Path::new("/sys/class/bluetooth/hci0").exists() {
        let count = |arg: &str| -> Option<u64> {
            let o = std::process::Command::new("bluetoothctl")
                .args(["devices", arg])
                .output()
                .ok()?;
            if !o.status.success() {
                return None;
            }
            Some(
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .filter(|l| l.trim_start().starts_with("Device "))
                    .count() as u64,
            )
        };
        let mut m = map.lock().unwrap();
        if let Some(p) = count("Paired") {
            m.insert("dev_bt_paired".into(), p.to_string());
        }
        if let Some(c) = count("Connected") {
            m.insert("dev_bt_conn".into(), c.to_string());
        }
    }
}
