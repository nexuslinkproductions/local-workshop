# 14 — Machine tuning for MoE-offload inference (Ryzen 9 7900X + Arc B580)

Scope: the *host* knobs — RAM bandwidth, CPU power management, VM/THP/zram, and the
GPU's clock/power/PCIe/BAR state. Sibling file `13-speed-levers.md` covers the
llama.cpp flags; this file covers everything you would otherwise change with `sysctl`,
`powerprofilesctl` or a BIOS reboot. **Nothing was changed** — read-only diagnostics
plus one bandwidth measurement and one latency measurement.

No sudo on this box (password required), so every value below was read as the
`nexuslink` user. Items needing root or a BIOS trip are marked **Marcel**.

## 1. The tuning wins, in order

| # | lever | current | recommended | expected effect on MoE decode | who |
|---|---|---|---|---|---|
| 1 | RAM speed / overclock profile | **DDR5-6000 active** — the SPD's single overclock profile ("Profile 1") is loaded, proven by the iGPU memory clock reading 3000 MHz (§2) | keep | baseline. Falling back to JEDEC DDR5-4800 would cut ~20 % decode; this is the biggest host factor and it is already correct | — |
| 2 | CPU power profile | ppd profile **balanced** → governor `powersave`, EPP `balance_performance` | `powerprofilesctl set performance` | small and free: faster clock ramp and less between-token downclocking on the CPU expert matmuls. Expect **0–3 %**, most of it in the variance | **no root** — one command |
| 3 | llama.cpp thread count + pinning | matrix configs use `-t 16`, unpinned | `-t 12 -C 0x00000fff --cpu-strict 1` | the box saturates its memory controller with ~1–2 cores (§2), so extra threads buy nothing; **pinning is the real win — unpinned 12-thread read was 39.8 GB/s vs 63.2 GB/s pinned (+58 %)** | no root (flag) — detail in `13-speed-levers.md` |
| 4 | zram can eat the expert budget | 61.8 GiB zram, `mem_limit` unlimited, 2.8 GiB of real RAM already held | cap `mem_limit` ≈ 8–16 GiB | protects `MemAvailable` for a ~40 GiB host-expert set and stops zstd competing for the same cores doing expert matmuls. Effect: fewer swap storms at 40+ GiB models | **Marcel** (root) |
| 5 | THP defrag | `enabled=[always]`, `defrag=[madvise]`, `FilePmdMapped = 0` | `defrag=defer+madvise` | the mmap'd GGUF gets **4 KiB pages** today; collapsing it to 2 MiB pages cuts TLB misses on the expert-streaming path. Expect **0–5 %**, unmeasured here | **Marcel** (root) |
| 6 | GPU clocks | max 2850 MHz (= `rp0`), idle 1200 MHz, `power_profile=base`, `reasons=none` | leave as-is | already optimal — the card reaches rp0 with no throttle reason | — |
| 7 | GPU power cap | `power1_cap` 200 W (crit 400 W) | leave as-is | already above the B580's 190 W stock TBP | — |
| 8 | PCIe link | **Gen4 x8 (16 GT/s x8)** = the card's own maximum | leave as-is | no bottleneck; `-ncmoe` expert streaming is RAM-side, not PCIe-side | — |
| 9 | Resizable BAR | **active**, 16 GiB prefetchable BAR | leave as-is | whole 12 GiB VRAM is BAR-visible; prerequisite for the best `-ngl` placements | — |
| 10 | swappiness | 150 | leave as-is | correct for zram: it compresses *anonymous* pages instead of evicting the file-backed model. Pair with `-lm mmap+mlock` (`13` §3.1) | — |
| 11 | overcommit | `0` heuristic, ratio 50 | leave as-is | llama.cpp's large mmap + compute buffers are fine under heuristic overcommit | — |
| 12 | SMT | on | leave on | costs nothing when llama.cpp is pinned to the 12 primary threads | — |
| 13 | `hugepages-2048kB` | `HugePages_Total = 0` | leave 0 | THP already covers anon memory; explicit hugetlbfs needs app support llama.cpp lacks | — |

Two items are worth acting on today and neither needs root: the ppd profile and the
`-t/-C` pinning. Everything else is already optimal or a small unmeasured increment.

## 2. RAM — speed, profile, bandwidth, latency

### 2.1 What is installed and what it is running at

| | value | how it was read (no root) |
|---|---|---|
| modules | 2 × 32 GiB Corsair `CMK64GX5M2B6000C30` in **DIMMA2 + DIMMB2** (A1/B1 empty) | `inxi -m`, and the SPD directly |
| module manufacturer ID | `0x9E02` (Corsair) | SPD offset 512, LE16 |
| array | 4 slots, 128 GiB max, no ECC, 2 channels × 64 bit | `inxi -m` |
| **overclock profile present** | exactly **one**, self-labelled `Profile 1`, cycle-time field **333 ps** = 3000 MHz = **DDR5-6000** | SPD, `27-0051/eeprom` |
| **speed actually in force** | **DDR5-6000 MT/s** | see below |

**How the running speed was proven without root.** `dmidecode` is not installed, the
DMI raw tables are `0400 root`, `/dev/i2c-*` is `root:i2c` and `nexuslink` is not in
`i2c`, `ee1004` is not loaded, and `decode-dimms` finds no EEPROM. Two user-readable
routes did work:

1. **`/sys/bus/i2c/devices/27-0051/eeprom` is mode `444` — world-readable.** The
   `spd5118` driver (bound to the DDR5 SPD hubs at `27-0051`/`27-0053`) exposes the raw
   1024-byte SPD. It confirms Corsair `0x9E02` and the part string
   `CMK64GX5M2B6000C30`, and shows exactly one overclock profile (`Profile 1`) with a
   333 ps cycle time. Both DIMMs' SPDs are byte-identical. SPD tells you what is
   *available*, not what is *programmed* — so this alone is not proof.
2. **The iGPU's memory clock — and this is decisive.** `card2` is the Raphael iGPU
   (`1002:164e`, `amdgpu`), and on an APU `pp_dpm_mclk` *is* the live DRAM clock:

   ```
   /sys/class/drm/card2/device/pp_dpm_mclk  ->  0: 3000Mhz *
   ```

   3000 MHz memory clock = **6000 MT/s** DDR5. The JEDEC fallback with the profile off
   would be 4800 MT/s, i.e. **2400 MHz** — not what is programmed. There is one DPM
   state and it is the active one, so the memory clock is fixed at 3000 MHz.

On the XMP-vs-EXPO question the SPD is specific: there is **one** profile block (at SPD
offset 640, self-labelled `Profile 1`, XMP-3.0-style header bytes `0c 4a 30 01`) and the
literal string `EXPO` appears **nowhere** in the 1024-byte SPD, so this Corsair kit
carries an XMP-format profile rather than a separate AMD EXPO block. AM5 boards expose
that switch as "XMP/EXPO" and load it either way — which is what happened.

**Verdict: the overclock profile is enabled, the RAM is running at DDR5-6000.**
(`inxi -m`'s `6000 MT/s` is the DMI *rated* field, not `Configured Memory Speed` — it
would print 6000 either way, which is why it was not used as evidence.)

### 2.2 Measured bandwidth

`membw3.c` in `~/.hermes/cache/scratch/membw/` — a STREAM-style probe over a **1.5 GiB**
footprint (3 × 512 MiB arrays, ≫ the 64 MiB L3), best of 5–8 reps, threads pinned to
distinct CPUs. Three paths, all verified vectorised (`vmovupd`/`vaddpd`/`vpxorq`, 98
zmm/ymm refs in `work()`):

* `read_f` — `sum(a)`, `-ffast-math` so GCC will reassociate and vectorise it
* `read_u` — `uint64` XOR reduction (integer, vectorises without fast-math)
* `triad` — `c[i] = a[i] + 2.0*b[i]` (2 reads + 1 write per element)

Every run wrapped in `flock -x bench/.gpu.lock` per the one-test-at-a-time rule; the
game check (`pgrep -f '^[A-Za-z]:\.*PioneerGame\.exe'`) was clean throughout.

Theoretical peak for 2 channels × 64 bit: **96 GB/s** at DDR5-6000 (76.8 GB/s at 4800).

| threads (pinned) | `read_f` GB/s | `read_u` GB/s | `triad` GB/s | % of 96 GB/s peak |
|---|---|---|---|---|
| 1 | **56.7** | 54.3 | 45.6 | 59 % |
| 2 | 57.9 | 56.5 | 46.5 | 60 % |
| 6 | 57.1 | 51.9 | 49.8 | 60 % |
| 12 | **63.2** | 55.2 | 53.7 | 66 % |
| 24 | 19.7 ⚠ | 33.0 | 60.2 | — |

| threads (unpinned) | `read_f` GB/s | `triad` GB/s |
|---|---|---|
| 6 | 57.1 | 54.8 |
| 12 | 39.8 | 52.7 |
| 24 | 34.6 | 46.5 |

⚠ The 24-thread read path is unstable (per-rep range 13.2–19.7 GB/s) and never beats
12 threads. It is reported for completeness, not as a usable figure.

Three things fall out of this, and they are the reason this section exists:

1. **One core already pulls 56.7 GB/s — 59 % of the theoretical peak.** A single Zen 4
   core's prefetchers nearly saturate this 2-channel controller. Going from 1 to 12
   threads buys only **+11 %** (56.7 → 63.2 GB/s).
2. **The box saturates at ~60–65 GB/s read / ~50–55 GB/s triad.** That is the hard
   ceiling for any `-ncmoe` configuration: a MoE decode step re-reads its routed experts
   from RAM every token, so decode tok/s ≈ usable_bandwidth / expert_bytes_per_token.
   More threads cannot buy decode; only better *placement* (fewer expert bytes per
   token) can — which is exactly what `--moe-cache-mib` and `-ncmoe` attack.
3. **Pinning is worth more than threads.** 12 unpinned = 39.8 GB/s vs 12 pinned
   = 63.2 GB/s. A `-C`/`--cpu-strict` mask that keeps each thread on its own physical
   core is a bigger, cheaper lever than raising `-t`. `-t 24` (SMT) actively hurts.

*Caveat:* the box was not quiet — a `matrix-bench` MoE sweep and a `cmake --build -j 20`
were running and ambient load sat at 6–17. These figures are **floors**; a clean box
would be somewhat higher. The *relative* conclusions (1 ≈ 12 threads, pinning ≫ threads)
are robust to that.

### 2.3 Measured latency

`lat.c` — a dependent-load pointer chase over a shuffled cycle, with `MADV_HUGEPAGE`
and the huge-page count verified from `smaps_rollup` (256 MiB region, 262144 KB of anon
huge pages, so TLB misses are not polluting the number):

| region | latency |
|---|---|
| **256 MiB (DRAM, THP confirmed)** | **77.18 ns** per dependent load |
| 16 MiB (L3-resident control) | 24.74 ns |

77 ns is a normal AM5 full-round-trip figure and sits in the DDR5-6000 CL30 band. It is
a corroborating datapoint, not a standalone discriminator — the MCLK reading in §2.1 is
what settles the speed.

## 3. CPU

| property | value |
|---|---|
| CPU | Ryzen 9 7900X, 12 cores / 24 threads, Zen 4, family 25 model 97 stepping 2 |
| microcode | `0xa60120c` |
| cpufreq driver | `amd-pstate-epp`, status `active` |
| governor (all 24) | `powersave` |
| EPP (all 24) | `balance_performance` (available: `default performance balance_performance balance_power power custom`) |
| `amd_pstate/dynamic_epp` | `disabled` |
| `amd_pstate/prefcore` | `enabled` (preferred-core boosting) |
| boost | `/sys/devices/system/cpu/cpufreq/boost = 1`; `lscpu` "Frequency boost: enabled" |
| freq | `scaling_min_freq` = **3.0 GHz** (amd-pstate lowest-non-linear), `scaling_max_freq` = 5738 MHz; observed 5.34 GHz on cpu0/6/12 under load, 3.007 GHz across all 24 when idle |
| SMT | `active=1`, `control=on` |
| cache | 32 KiB L1d + 32 KiB L1i + 1 MiB L2 per core; **2 × 32 MiB L3**, one per CCD |
| CCD layout | cores 0–5 → CCD0 (CPUs 0–5, siblings 12–17); cores 6–11 → CCD1 (CPUs 6–11, siblings 18–23) |
| NUMA | single node (node0 = CPUs 0–23); `numa_balancing = 0` |

**Why the governor is `powersave`:** `power-profiles-daemon` is **active** and the
profile is **`balanced`**. ppd owns those files (`644 root`), so nothing there is
writable as the user — but ppd itself is:

```
powerprofilesctl get            # -> balanced
powerprofilesctl set performance
```

`performance` reports `CpuDriver: amd_pstate`, `Degraded: no`, so it sets the governor to
`performance`. That is the no-root CPU win. Expect it to be small: amd-pstate already
reaches 5.34 GHz under load with `balance_performance`, so this buys ramp latency and
less between-token downclocking, not a higher clock ceiling.

**Thread/CCD mask, derived from the topology above** (the flags themselves live in
`13-speed-levers.md`): `-C 0x00000fff` = CPUs 0–11 = **12 distinct physical cores, one
thread each, spanning both CCDs** — the correct "no-SMT" mask. `-C 0x0003f03f` = CPUs
0–5 + 12–17 = CCD0 only, 6 cores with SMT. The running matrix configs use `-t 16`, which
is neither, and §2.2 shows unpinned 16-way threading is leaving bandwidth on the table.

## 4. Memory / VM knobs

| knob | value | read |
|---|---|---|
| `transparent_hugepage/enabled` | `[always] madvise never` | favourable — anon THP on |
| `transparent_hugepage/defrag` | `always defer defer+madvise [madvise] never` | khugepaged will **not** collapse without an `madvise` hint |
| `transparent_hugepage/shmem_enabled` | `always within_size [advise] never deny force` | n/a |
| `khugepaged/scan_sleep_millisecs` | 10000 | 10 s scan interval |
| `hpage_pmd_size` | 2097152 (2 MiB) | |
| `AnonHugePages` | 6.5 GiB (rose from 1.4 GiB during the session) | THP is actively working on anon memory |
| `FilePmdMapped` | **0 kB** | **no file-backed THP** — the mmap'd GGUF gets 4 KiB pages |
| `ShmemHugePages` / `FileHugePages` | 0 / 0 | |
| `HugePages_Total` | 0 | no reserved hugetlbfs pages (fine — llama.cpp does not use hugetlbfs) |
| `vm.swappiness` | **150** | high, deliberate for zram |
| `vm.vfs_cache_pressure` | 50 | |
| `vm.dirty_bytes` / `dirty_background_bytes` | 268435456 / 67108864 | `dirty_ratio`/`dirty_background_ratio` are both 0, so the byte limits govern |
| `vm.overcommit_memory` / `ratio` | 0 / 50 | heuristic overcommit |
| `vm.min_free_kbytes` | 67584 | |
| `vm.watermark_scale_factor` | 125 | |
| `vm.zone_reclaim_mode` | 0 | correct for a single node |
| `vm.compaction_proactiveness` | 20 | |
| zram | `/dev/zram0`, zstd, **61.8 GiB** (= 100 % of RAM), `mem_limit` unlimited | |
| zram use | 5.2 GiB data → 2.7 GiB compressed, **2.8 GiB of real RAM** held, 65 479 zero-pages, 1.88:1 | |
| `lru_gen` | `0x0007` (MGLRU on) | |
| KSM | `run = 0` | |

Two items matter for MoE offload:

1. **`FilePmdMapped = 0`.** `enabled=always` covers anonymous memory, but a read-only
   `mmap` of a GGUF is file-backed, and with `defrag=madvise` khugepaged leaves it on
   4 KiB pages. Streaming ~40 GiB of experts every token is exactly the workload a 2 MiB
   mapping helps (TLB reach), and llama.cpp never issues an `madvise`
   (`13-speed-levers.md` §3.1 confirms it only sends `MADV_WILLNEED`/`POSIX_MADV_RANDOM`).
   `defrag=defer+madvise` is the cheap experiment. **root.**
2. **zram is unbounded.** 61.8 GiB of compressed swap with no `mem_limit` is a safety net
   that can also consume the RAM the host experts need, while zstd runs on the same
   threads doing the expert matmuls. Capping it at 8–16 GiB keeps a cushion without
   letting it grow into the working set. **root** (`/sys/block/zram0/mem_limit` is mode
   `200`).

`swappiness=150` is correct and should be left alone: with a zram device it steers
reclaim toward compressing anonymous pages rather than evicting the clean file-backed
model. The complementary action is app-side — `-lm mmap+mlock` or `-lm none` per `13`
§3.1 — not a sysctl.

## 5. GPU — Arc B580

| property | value |
|---|---|
| device | `0000:03:00.0`, Battlemage G21 [Arc B580], ASRock `1849:6021`, `8086:e20b` |
| driver | `xe` (all module params default; `vram_bar_size` unset) |
| freq0 | `min 1200`, `max 2850` (= `rp0` = `rpa`), `rpe 400`, `rpn 400`; `act_freq` 2850 under load, **1200 MHz idle** |
| power_profile | `[base] power_saving` |
| throttle | `reasons = none` (`pl1/pl2/pl4/prochot/thermal/vr_tdc/vr_thermalert/ratl` all 0) |
| power cap | `power1_cap` = **200 W** (hwmon `power1_crit` 400 W); no `power1_max`; file is `664 root` |
| temps | pkg 51 °C, vram 54 °C, mctrl 51 °C, pcie 50 °C, fan 640 rpm |
| slices | `num_cslices = 2`, `ccs_mode = 1`, engines `rcs`/`ccs`/`bcs` |
| host PCIe link | root port `00:01.1` → card upstream switch `01:00.0`: **16.0 GT/s PCIe x8** (Gen4 x8), stable across three reads while loaded |
| link power | `link/l1_aspm = 1` |
| BAR | Region 0 16 MiB non-prefetchable; **Region 2 = 16 GiB prefetchable**; `resource2_resize = 0x7f00` |
| ReBAR | **active at the maximum 16 GiB size** |

**The `2.5 GT/s x1` readings are not a fault.** `lspci` shows
`00:01.1 → 01:00.0 (8086:e2ff) → 02:01.0 (8086:e2f0) → 03:00.0 (B580)`. `e2ff`/`e2f0`/
`e2f1` are the B580's **on-card PCIe switch** — every Battlemage card has one — and its
downstream ports advertise Gen1 x1 as their capability. The platform-facing link is
`00:01.1 ↔ 01:00.0`, training at **Gen4 x8**, which is the B580's own maximum (it is an
electrically x8 card). There is no PCIe headroom to recover.

ReBAR is confirmed independently of `lspci`: `resource2` spans 16 GiB prefetchable and
`resource2_resize = 0x7f00` (bits 8–14) advertises 256 MiB … 16 GiB as settable, with
16 GiB in force. That is the full 12 GiB VRAM visible through the BAR.

Nothing on the GPU side needs tuning: the card reaches rp0, reports no throttle reason,
has a 200 W cap above its 190 W stock TBP, sits on its maximum PCIe link, and has ReBAR
on. The GPU half of MoE decode (attention + dense layers) is not host-limited.

## 6. What was measured, what was not

* **Measured:** the running DRAM speed (iGPU MCLK = 3000 MHz) and the installed SPD
  (raw SPD bytes read as a normal user); read/triad bandwidth and DRAM latency (§2.2,
  §2.3, under contention); all sysfs and `inxi` values above; the PCIe link width/speed
  under load; the ReBAR BAR size.
* **Not measured:** any *effect* of the ppd profile, the zram cap, or the THP defrag
  change — those need a before/after decode row, which belongs in
  `bench/results-matrix.tsv`, not here. DIMM temperature (`spd5118` returns
  `temp1_input = 0` for both modules — a driver/SMBus read problem, not a real 0 °C).
* **Not attempted (would need root or a reboot):** PBO / Curve Optimizer / memory-context
  restore, `dmidecode -t memory` (not installed), `modprobe ee1004`. Note
  `powerprofilesctl set performance` needs **no** root — it was deliberately not run,
  because this file changes nothing.

### Reusable trick for the next audit

Two user-readable routes on this box replace root-only `dmidecode`:

```
# the installed module's SPD, raw, no root needed:
cat /sys/bus/i2c/devices/27-0051/eeprom        # mode 444; spd5118 must be bound

# the LIVE dram clock (APU memory clock == DRAM clock; 3000 MHz == DDR5-6000):
cat /sys/class/drm/card2/device/pp_dpm_mclk
```
