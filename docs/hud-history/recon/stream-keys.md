# Collector key contract (hud-collect stream)

All keys are `key<TAB>value` lines; `batch<TAB>N` terminates each ~1s frame.
Additive-only contract — panels must tolerate missing keys.

## Core (existing)
cpu_idle/cpu_total, cpu_cores, cpu_core_<i>, cpu_count, cpu_temp,
load1/5/15, uptime_s, mem_total_kb, mem_avail_kb, swap_total_kb, swap_free_kb,
net_rx/net_tx (bytes counters), disk_rd_sectors/disk_wr_sectors,
disk_read_bps/disk_write_bps, proc{0..5}_{name,cpu},
fs_{root,home}_{used,size,pct,target},
i_util i_freq_mhz i_temp_pkg i_temp_vram i_temp_mctrl i_temp_pcie
i_vram_ch_max i_vram_ch_avg i_fan_rpm i_pwr_cap_w i_energy_uj i_pwr_w
i_vram_used i_vram_total (Intel B580),
a_util a_vram_used a_vram_total a_temp a_pwr_w a_freq_mhz (AMD iGPU),
gpu_kind gpu_name gpu{N}_{kind,name}, host kernel (probe mode),
agents_tmux agents_procs

## Peripherals
bat_count; bat{i}_{name,pct,state(Discharging|Charging|Full)}

## Extra sensors
nvme_count; nvme{i}_{model,temp(composite °C),temp2(hottest secondary)}
dimm_count; dimm{i}_temp
cpu_tccd1 cpu_tccd2 (per-CCD)
psi_{cpu,mem,io}_{some,full} (avg10 %)
zram_orig_mb zram_used_mb zram_ratio
cpu_mhz_avg cpu_mhz_max
media_count; media{i}_name (removable mounts)
aguse_count; aguse{i}_{id,tokens,status} (omarchy agent-usage records)
theme_name

## Agents (extended)
ag_devin_acp (live acp session count)
ag_{devin,opencode,hermes,october,claude,codex,haze,build}_{procs,cpu}
devsess_count; devsess{i}_{name,pid,live} (Devin session locks, ≤12)

## Slow lane (background thread)
github (~90s): gh_ok gh_user gh_unread ghev_count;
  ghev{i}_{type,repo,age_s}
tmux (~5s): tmux_n; tmux{i}_{name,win,att}
hyprland (~3s): win_count; win{i}_{addr,ws,wsid,class,title,mon};
  ws_count; ws{i}_{id,name,mon,wins}
misc (~15min): pkg_updates, weather

## Interactions available in QML
- spawn: Quickshell.Io.Process command lists (gtk-launch <id>, hyprctl dispatch)
- focus: `hyprctl dispatch focuswindow address:<win{i}_addr>`
- workspace: `hyprctl dispatch workspace <ws{i}_id>`
- omarchy IPC: `omarchy-shell <target> <method>` (idle toggle, media,
  nightlight, notifications clear, osd show, background set, lock lock...)
