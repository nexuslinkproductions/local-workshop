# Expand Omarchy root 256G → ~1.2T (btrfs multi-device over LUKS)

Decision: operator picked "extend root across a new partition".

## Current geometry (nvme1n1, 3907029168 sectors × 512B ≈ 2TB)

| Part | Start | Size | What |
|---|---|---|---|
| p1 | 34 | 32734 | MSR-ish, 16M |
| p2 | 32768 | 3366912000 | NTFS `DATA` 1.6T — **150M used** |
| p3 | 3366944768 | 4194305 | vfat `/boot` 2G |
| p4 | 3371141120 | 535887873 | LUKS `omarchy_root` btrfs 255.5G |

Free space after p4: ~175 sectors (~90KB) — none. All growth must come
from shrinking p2 (p3+p4 sit between p2 and the freed gap; a NEW
partition in the gap is fine because btrfs device add doesn't need
physical adjacency).

## Plan

1. `pacman -S --needed ntfs-3g` (provides ntfsresize + mkfs.ntfs).
2. Unmount DATA; `ntfsresize -s 620G` then `parted resizepart 2` to a
   640GiB end → frees ~965G between p2 and p3.
3. `parted mkpart` → nvme1n1p5 in the gap.
4. `cryptsetup luksFormat` p5 with a generated keyfile
   (`/etc/cryptsetup-keys.d/omarchy_ext.key`, 600 root) — no second
   boot passphrase.
5. `/etc/crypttab` + `/etc/crypttab.initramfs` entry so systemd-boot
   initramfs (systemd hooks) unlocks it before btrfs mounts root.
   Keyfile is embedded into the UKI by mkinitcpio's sd-encrypt path.
6. fstab btrfs mounts gain `device=/dev/mapper/omarchy_ext` +
   `degraded` safety flag (if p5 ever fails to unlock, system still
   boots instead of dropping to emergency shell).
7. `mkinitcpio -P` rebuilds UKIs.
8. Drop `/swap/swapfile` — btrfs swapfiles are unsupported on
   multi-device volumes, and zram (61.8G, pri 100) already carries all
   swap. Hibernation `resume=` becomes inert (UKI cmdline; harmless).
9. `btrfs device add /dev/mapper/omarchy_ext /` → root sees ~1.2T.
   Optional `btrfs balance` later to restripe old data (not required;
   new writes stripe across both devices).

## Risks / rollback

- NTFS shrink touches Windows metadata — volume is 150M used so the
  relocate set is tiny, but it is the one irreversible step. If
  ntfsresize fails, abort keeps DATA intact.
- Boot-path change: crypttab.initramfs + fstab device=. The `degraded`
  option is the rollback net — worst case boots with only p4.
- To undo after device add: `btrfs device remove /dev/mapper/omarchy_ext /`
  (online), then revert crypttab/fstab entries and mkinitcpio -P.

Run: `sudo bash /tmp/omarchy-expand.sh` — staged, aborts on any error.
