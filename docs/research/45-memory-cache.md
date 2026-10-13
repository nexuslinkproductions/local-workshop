# 45 memory and cache monitor (BRIEF-45)

Status: monitor, alerts and gate refusal are live. The sysctl change is applied at runtime only (1048576 / 200, set by the orchestrator; not persisted, no root to install the conf file). The before/after live Gemma run is done: KEEP.

## What is live

- `~/.local/bin/memwatch` runs every 15 s from `memwatch.timer` (user unit, Nice 19, idle IO). Each sample takes about 30 ms.
- Samples go to `~/.local/state/memwatch/memwatch.tsv`. The file has 14 columns and rotates to `.1` at 5 MB.
- `memwatch --status` prints the last row.
- Alerts use `notify-send` (critical). Each one is also logged to `alerts.log`. Each condition alerts at most once per 30 min.
  - kswapd0 gone: reboot before GPU work.
  - Kernel oops this boot (`BUG: kernel`, `Oops:`, `xe .*shrink`): reboot needed. Alerts once per new oops.
  - Memory pressure `some avg10` above 10 for 60 s: desktop stalls likely.
  - MemAvailable below 4 GiB.
- Gate: `bench/gate.sh` `gate_check` and `serve/gate-run.sh` now refuse when kswapd0 is missing (`kswapd_missing`). The GPU reset and oops refusal is unchanged. Ack is still `touch bench/.gpu-reset-ack`.

## Proof

- `bench/memwatch-drill.sh` (fixture `/proc` and kernel log, no real alerts needed):
  - faulty sample fires oops, kswapd0, psi and mem once each
  - the same sample inside the cooldown is silent
  - after the cooldown, kswapd0, psi and mem fire again; the oops does not repeat
  - a healthy sample is silent
  - psi does not fire on the first sample with the 60 s hold
  - `gate_check` refuses on the faulty fixture and passes on the healthy one
  - result: ALL PASS
- Real `notify-send` from the session returned 0.
- Timer: 15 s cadence confirmed in `memwatch.tsv` after install.

## Baseline (system state at install, 13:45 CEST)

- Kernel oops was in the previous boot (13:17:46). The current boot (up since 13:42) has no oops and kswapd0 is alive.
- Current sysctl values are in `research/45-backup/sysctl-before.txt`:
  - `vm.min_free_kbytes` 67584 KiB
  - `vm.watermark_scale_factor` 125
  - `vm.swappiness` 150, `vm.vfs_cache_pressure` 50 (from `/etc/sysctl.d/99-omarchy-sysctl.conf`)
  - dirty caps already set: 256 MiB hard, 64 MiB background

## Sysctl (staged, not applied)

- Candidate: `research/45-sysctl/99-zz-nexus-memory.conf`.
  - `vm.min_free_kbytes = 1048576` (1 GiB)
  - `vm.watermark_scale_factor = 200`
- The file is named `99-zz-` on purpose. sysctl.d applies files in name order, and Omarchy's `99-omarchy-sysctl.conf` would override a `90-` file on `watermark_scale_factor`.
- Not staged: the brief's dirty caps (already set) and `vfs_cache_pressure = 150` (it reverses a choice Omarchy documents).
- Install, only after a before/after win: `sudo install -m644 research/45-sysctl/99-zz-nexus-memory.conf /etc/sysctl.d/ && sudo sysctl --system`
- Revert: `sudo bash research/45-sysctl/revert.sh` (restores 67584 and 125).

## Not done

- `drop-clean-cache` root helper: needs root. Not built. Model cold starts use `posix_fadvise(DONTNEED)` instead, which needs no root.
- Status page line: not added. `reports/local-ai-status-2026-10-13.html` is being rebuilt by another lane. Add one line after that lands.
- Sysctl before/after: needs root for the "after" run. The live run in `bench/memcache-live.sh` measures only the current settings.

## Live Gemma run

`bench/memcache-live.sh <tag>` waits up to `WAIT_S` for the GPU lock, runs `gate_check`, drops the model file cache, starts llama-swap, loads gemma4-12b (64K), sends a 32K-token prefill, then stops only what it started. It writes `summary.txt` under `~/.local/state/memwatch/runs/<tag>/`.

Result, run `before-64k-32k` (14:14 CEST, current sysctl values, gate passed, lock held, llama-swap stopped after):

| Metric | Value |
|---|---|
| Model load + first reply (cold file cache) | 4.1 s |
| Prefill | 32,852 tokens in 41.6 s (about 790 tok/s) |
| Peak psi memory some10 / full10 | 0.00 / 0.00 |
| Peak psi io some10 / full10 (desktop line: below 1.0) | 0.57 / 0.48 |
| MemAvailable floor | 38.9 GiB (39,824 MiB) |
| MemFree floor | 8.4 GiB (8,650 MiB) |
| Cached peak | 32.8 GiB (33,561 MiB) |
| kswapd0 present in all samples | yes |
| Alerts fired | none |

The first run (`before-64k`) used a 130 KB prompt. It tokenized to 21,338 tokens, not 32K, so the second run replaced it as the reference. Its numbers are kept in `~/.local/state/memwatch/runs/before-64k/`.

Session-wide, 27 min of samples (13:45 to 14:15): psi memory max 0.54, psi io some10 max 4.23 (other lanes' disk work), MemAvailable min 31.4 GiB, Cached max 46.6 GiB. No alert fired, no kswapd0 loss.

What this does not show: the "after" with the staged sysctl. That needs root, so the before/after comparison is still open. Keep or drop the sysctl only after that run. (Superseded: the orchestrator applied the sysctl at runtime and the after run ran on 2026-10-13 14:17. See the verdict section below.)

## Before/after verdict (sysctl applied at runtime, run after-64k)

After run `after-64k` (2026-10-13 14:17-14:18) ran the identical `bench/memcache-live.sh` flow under the applied sysctl (`vm.min_free_kbytes=1048576`, `vm.watermark_scale_factor=200`): lock and gate passed instantly, prompt was the current script's 200 KB / 32,852 tokens. The quoted before-64k numbers (21,338 tokens) came from the earlier 130 KB prompt, so the like-for-like prefill comparison is the same-workload `before-64k-32k` run; `before-64k` is shown for reference.

| Metric | before-64k (21,338 tok) | before-64k-32k (32,852 tok) | after-64k (sysctl on) | Δ vs before-64k-32k |
|---|---|---|---|---|
| Model load + first reply (cold cache) | 4.1 s | 4.1 s | 4.2 s | +2.4% |
| Prefill | 794.3 tok/s @ 21,337 | 792.5 tok/s @ 32,851 | 765.3 tok/s @ 32,851 | -3.4% |
| psi mem some10 / full10 | 0.00 / 0.00 | 0.00 / 0.00 | 0.00 / 0.00 | no new psi |
| psi io some10 / full10 | 0.58 / 0.43 | 0.57 / 0.48 | 1.09 / 0.93 | full stays under 1.0 |
| MemAvailable floor | 36,225 MiB | 39,824 MiB | 35,953 MiB | -3,871 MiB (the bought headroom) |
| MemFree floor | 10,096 MiB | 8,650 MiB | 8,006 MiB | -644 MiB |
| Cached peak | 30,994 MiB | 33,561 MiB | 33,682 MiB | +121 MiB (unchanged) |
| kswapd0 present / alerts | yes / none | yes / none | yes / none | ok |

Verdict: **KEEP.** Load +2.4% and prefill -3.4% are both inside the 5% band, psi memory stays 0.00 (no new memory pressure), kswapd0 present in all samples, no alert fired, GPU cleanly released. psi io some10 hit 1.09 during the cold 7 GiB model read (before: 0.57) but full10 0.93 stays under the 1.0 desktop line, and io pressure during a cold model load is disk-bound, not a reclaim story; a single run also cannot separate it from run-to-run variance. The MemAvailable floor drop (~3.7 GiB) is the setting working as intended: higher watermarks reclaim cache earlier to keep crash headroom. Next step when root exists: install the conf per the install line above (still runtime-only today, lost on reboot).

## Revert everything

```
systemctl --user disable --now memwatch.timer
rm ~/.config/systemd/user/memwatch.service ~/.config/systemd/user/memwatch.timer ~/.local/bin/memwatch
cp research/45-backup/gate.sh.orig bench/gate.sh
cp research/45-backup/gate-run.sh.orig serve/gate-run.sh
```
