# BRIEF-45: memory and cache monitor (Marcel: "we cant have old cache, good cache handling is needed")

## Why
2026-10-13 13:17:46: kernel oops (NULL deref in xe_pt_zap_ptes, called from xe_shrinker_scan inside
kswapd0). kswapd0 died. After that: free 0 GiB, page cache 50 GiB not reclaimed, memory psi some
~40 %, desktop stalls. The safety gate only knew GPU resets; it now also refuses on "BUG: kernel|Oops:".
Root question: the xe shrinker runs when the kernel reclaims memory while GPU buffers are mapped.
Keeping reclaim calm (free headroom, early background reclaim, no huge cache spikes during model
loads) lowers the chance of hitting that path. Unproven, so measure.

## Build (small, boring, Omarchy-native)
1. `~/.local/bin/memwatch` (bash or python stdlib) run by a systemd --user timer every 15 s, Nice 19:
   reads /proc/meminfo (MemFree, Cached, Dirty, Writeback, SwapFree), /proc/pressure/memory and io,
   `pgrep -x kswapd0`, and `journalctl -k -b` for new "BUG: kernel|Oops:|xe .*shrink". Appends one
   TSV line to ~/.local/state/memwatch/memwatch.tsv (rotate at 5 MB).
2. Alerts via `notify-send` (once per condition, with cooldown): kswapd0 missing or kernel oops
   ("reboot needed"), memory psi some avg10 > 10 for 60 s, MemFree+reclaimable below 4 GiB.
3. Cache handling, measured before kept:
   - sysctl candidates in /etc/sysctl.d/90-nexus-memory.conf (via `sudo sh -c`): vm.min_free_kbytes
     (e.g. 1 GiB), vm.watermark_scale_factor (e.g. 200), vm.vfs_cache_pressure (e.g. 150),
     vm.dirty_background_bytes / vm.dirty_bytes (cap dirty pages for big model reads). Record current
     values first and keep a revert file.
   - Model loads: big GGUF reads should not flood the cache. Check whether llama.cpp's --no-mmap and
     `-lm dio` (direct IO, already used for Gemma) cover it; for other big readers (downloads, cargo,
     yuri index) use `systemd-run --user -p MemoryHigh=...` or jobcap, which already limits cgroup
     memory incl. page cache.
   - Optional root helper: a narrow sudoers or polkit rule for ONE command
     `/usr/local/bin/drop-clean-cache` (sync; echo 1 > /proc/sys/vm/drop_caches) that memwatch may call
     only when psi is high AND cache > 60 % of RAM. Never drop while a model is loading (GPU lock held).
4. Add memwatch status to `bench/gate.sh` (refuse when kswapd0 is missing or memwatch reports an
   unacked oops) and a line on the local AI status page.

## Proof (live, not unit tests)
- Before/after table with the sysctl set: load Gemma 64K + one 32K prefill under the lock while
  memwatch logs; compare peak psi, MemFree floor, Cached peak, model load time, desktop smoothness
  (psi io/cpu avg10 < 1.0). Keep a sysctl only if it measurably helps and costs nothing visible.
- Fault drill: fake the conditions (test mode env var pointing at fixture /proc files) to show each
  alert fires once and gate.sh refuses.
- Write research/45-memory-cache.md: what changed, numbers, how to revert.
