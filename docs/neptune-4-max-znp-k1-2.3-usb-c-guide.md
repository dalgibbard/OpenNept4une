# OpenNept4une bring-up: Neptune 4 Max, ZNP-K1-2.3, USB-C toolhead

Last verified: 2026-08-27

This runbook covers this exact target:

- Elegoo Neptune 4 Max
- mainboard `ZNP-K1-2.3`
- factory USB-C toolhead with a separate toolhead MCU
- Cartographer v4 over USB
- Logitech C920 over USB
- the stock touchscreen left unmanaged because `display_connector` causes MCU I/O instability on this hardware

## Read this first

This combination is still **experimental**. The current OpenNept4une wiki explicitly lists `ZNP-K1-2.3` boards and USB printheads as unsupported. The upstream and reference-fork `dev` branches are not turnkey for this hardware. This fork adds a guarded end-to-end software path, but it still needs validation on this physical printer before it should be treated as production support.

The safe conclusion from comparing and then integrating the repositories is:

1. Do **not** build a complete Armbian image for the first attempt.
2. Start from the complete OpenNept4une v0.1.7 Plus/Max image.
3. Use this fork on `dev`; it contains the missing board integration and flashing safeguards.
4. Run its board-hardware installer against the mounted image before first boot. It selects the board-2.3 DTB and installs persistent GPIO82 toolhead power with rollback state.
5. Use its guarded, bundled `n4flash` flow for the USB-C toolhead; do not target a `/dev/ttyACM*` node manually.
6. Bring up the stock probe first. Add Cartographer and the camera one at a time only after the printer is stable. Do not install `display_connector` on this hardware.

Keep the machine cold while commissioning it. Do not home Z, move an axis, or command a heater until the relevant endstop, probe, temperature, and pin checks have passed.

Useful project links:

- [OpenNept4une wiki](https://github.com/OpenNeptune3D/OpenNept4une/wiki)
- [OpenNept4une v0.1.7 release](https://github.com/OpenNeptune3D/OpenNept4une/releases/tag/v0.1.7)
- [OpenNept4une issue #417: board 2.3 and USB-C work](https://github.com/OpenNeptune3D/OpenNept4une/issues/417)
- [Reference fork](https://codeberg.org/gggcodes/OpenNept4une)
- [This fork's deployment remote](https://github.com/dalgibbard/OpenNept4une)
- [`n4flash`](https://codeberg.org/gggcodes/n4flash)
- [Elegoo's stock Type-C Plus/Max recovery image](https://github.com/elegooofficial/Neptune4/releases/tag/Neptune4Plus%264Max%28TypeC%29_Image)

## Repository comparison and decision

The repository comparison used for this guide checked these three `dev`
snapshots:

| Working copy | Remote | Reviewed `dev` commit | Role |
|---|---|---:|---|
| Upstream OpenNept4une | GitHub/OpenNeptune3D | `790e7aac0ab9c7a88627706a8ba56c02a643b03c` | Initial experimental board-2.3 and USB-C support |
| gggcodes reference fork | Codeberg/gggcodes | `aba0a87237a00e94a4c7da1b16f11c2bf13ba41d` | Additional Max-specific, author-tested fixes |
| This fork | GitHub/dalgibbard | `dev`, based on `790e7aac0ab9c7a88627706a8ba56c02a643b03c` plus the changes described here | Integrated, guarded implementation to deploy |

The branches share the USB-C implementation up to `897b170`. The fork then adds the important fixes:

- `4c9a168`: correct bootloader VID/PID (`1d50:018a`), GPIO82 power cycling, and `n4flash`
- `fc63f1e`: experimental main-MCU serial flashing
- `e94b82c`: Neptune 4 Max part light on `THR:PB10`
- `aba0a87`: compile the physical GD32F303 toolhead MCU with Cortex-M4 instructions

At the reviewed heads, the only functional differences are in:

- `img-config/rpi-mcu-install.sh`
- `printer-confs/n4max/n4max.cfg`
- `printer-confs/toolheads/usb-c.cfg`

The common `dev` work provides the board-2.3 DTB, USB-C pin mappings, firmware config, fans, accelerometers, and `[mcu THR]` generation. The Codeberg reference exposed these gaps:

- the board-2.3 DTB is never installed by either project's scripts;
- GPIO82 is toggled during flashing but is never exported or enabled persistently;
- `n4flash` is called but is not included or installed;
- the flash command targets the unsafe, non-persistent name `/dev/ttyACM0`;
- the fork still writes the GitHub upstream URL into Moonraker's update manager;
- the main-MCU serial path is labelled timing-sensitive in the source itself.

This fork closes those software gaps:

- an idempotent, reversible installer selects the 2.3 DTB both online and in an offline mounted image;
- a systemd dependency raises GPIO82 before Klipper and supplies a guarded power-cycle helper;
- pinned MIT-licensed `n4flash` source is bundled and built locally;
- the toolhead updater requires one persistent bootloader by-id path and validates VID/PID `1d50:018a` before flashing;
- the unsafe mixed `All` MCU action and experimental main-MCU serial action are unavailable;
- the Max+USB-C part light uses `THR:PB10` without a conflicting neopixel declaration, while the ribbon Max remains unchanged;
- Moonraker and the built-in updater preserve the installed checkout's actual `origin`.

The remaining unknown is physical validation: the exact application/bootloader identities from this printer and repeated GPIO82 cold-boot behavior. Those are explicit TODOs rather than guessed constants.

## End-to-end order

Use this order. Each phase has a go/no-go gate so a peripheral failure cannot be confused with the base port.

1. Record the stock state and back up the entire original eMMC.
2. Download and capacity-check the complete v0.1.7 image.
3. Flash it, install this fork's board integration, and optionally preseed Wi-Fi offline.
4. First boot: verify the DTB, networking, and base Linux system.
5. Verify the persistent GPIO82 toolhead-power service.
6. Put this fork on the printer if it was not copied into the image offline.
7. Flash only the USB-C toolhead through the guarded updater and its stable bootloader by-id path.
8. Generate the Max/2.3/USB-C configuration so Klipper can identify the installed MCUs.
9. Update and verify the main MCU, then verify or update the virtual Linux MCU separately.
10. Establish a working baseline using the factory inductive probe.
11. Update Cartographer to v4 USB Lite firmware, then add and calibrate it.
12. Add the C920.
13. Keep `display_connector` and its display/affinity services disabled.
14. Make a new golden eMMC image after everything is proven.

The patched MCU updater no longer offers **All**. Update exactly one MCU per invocation.

## 1. Record and back up the stock machine

If the factory OS still boots, archive its configuration before removing the eMMC:

```bash
mkdir -p ~/n4max-stock-record
cp -a ~/printer_data/config ~/n4max-stock-record/
cat /boot/.OpenNept4une.txt 2>/dev/null | tee ~/n4max-stock-record/OpenNept4une-flag.txt
lsusb | tee ~/n4max-stock-record/lsusb.txt
ls -l /dev/serial/by-id/ | tee ~/n4max-stock-record/serial-by-id.txt
uname -a | tee ~/n4max-stock-record/uname.txt
```

Also record or photograph:

- the `ZNP-K1-2.3` board label;
- the touchscreen model and UI/firmware version from its About page;
- the factory hotend, bed, probe, filament sensor, fan, and light pins from the stock configuration;
- all Z-offset, mesh, resonance, PID, and input-shaper calibration values.

The generated experimental config currently assigns the filament sensor to main-MCU `PA12`, but reports disagree on whether some USB-C heads own that signal. Preserve the stock pin and treat runout as disabled until it is tested.

### Raw eMMC backup on the workstation

Insert the original eMMC into the reader. First identify the **whole device**:

```bash
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS
```

In the examples below, `/dev/sdX` means the whole eMMC reader device. It is a placeholder. Never paste it without replacing it, and never use a partition such as `/dev/sdX1` as the `dd` target.

Unmount every automatically mounted partition, then record the exact capacity and make the backup:

```bash
sudo umount /dev/sdX1
sudo umount /dev/sdX2
sudo blockdev --getsize64 /dev/sdX
sudo dd if=/dev/sdX of=neptune4max-znp-k1-2.3-stock-emmc.img \
  bs=4M iflag=fullblock conv=fsync status=progress
sha256sum neptune4max-znp-k1-2.3-stock-emmc.img \
  > neptune4max-znp-k1-2.3-stock-emmc.img.sha256
```

An optional, strong read-back check is:

```bash
sudo cmp --bytes="$(sudo blockdev --getsize64 /dev/sdX)" \
  neptune4max-znp-k1-2.3-stock-emmc.img /dev/sdX
```

Keep the raw image and checksum on another physical disk. A raw eMMC image does **not** back up the firmware already stored in the main MCU, USB-C toolhead MCU, or touchscreen.

### Extract an easy-to-restore configuration backup

The raw image already contains `printer.cfg` and the rest of
`/home/mks/printer_data`; a separate archive is still worthwhile because it is
much easier to inspect and restore than a multi-gigabyte disk image. With the
original eMMC still in the reader, use `lsblk` to identify its ext4 root
partition (normally, but not blindly, `/dev/sdX2`) and mount it without journal
replay:

```bash
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS /dev/sdX
stock_root=/mnt/neptune4-stock-root
sudo mkdir -p "$stock_root"
sudo mount -o ro,noload /dev/sdX2 "$stock_root"
sudo find "$stock_root/home/mks/printer_data" -xdev \
  -maxdepth 2 -type f -name printer.cfg -print
```

Stop if that does not show the expected stock `printer.cfg`; re-check the
partition rather than mounting another one read-write. Archive the complete
configuration and, when present, Moonraker's database:

```bash
stock_root=/mnt/neptune4-stock-root
mountpoint -q "$stock_root" || { echo 'Stock root is not mounted; stop.' >&2; exit 1; }
stock_paths=(home/mks/printer_data/config)
if sudo test -d "$stock_root/home/mks/printer_data/database"; then
  stock_paths+=(home/mks/printer_data/database)
fi
sudo tar --acls --xattrs --numeric-owner \
  -C "$stock_root" -cpf neptune4max-stock-printer-data.tar \
  "${stock_paths[@]}"
sudo chown "$(id -u):$(id -g)" neptune4max-stock-printer-data.tar
sha256sum neptune4max-stock-printer-data.tar \
  > neptune4max-stock-printer-data.tar.sha256
tar -tf neptune4max-stock-printer-data.tar | less
sudo umount "$stock_root"
```

Keep this archive private. It can contain Wi-Fi details, API credentials,
serial identities, print history, and machine-specific calibration. If the
factory OS still boots, the earlier `cp -a` capture is a useful second copy;
this reader-based method does not require the printer to boot.

### MCU and touchscreen backup limits

The printer has several independent firmware stores. Treat their recovery
paths separately:

| Component | Included in raw eMMC image? | Pre-flash readback on this hardware | Practical recovery artifact |
|---|---:|---|---|
| Linux SBC, Klipper config, Moonraker data | Yes | Read-only mount as above | Verified raw image plus the config archive |
| Main STM32 MCU | No | Possible in principle through the STM32 ROM UART bootloader only if readout protection is off; the v2.3 entry/reset path is not validated | Matching factory binary, or the exact archived Klipper build and microSD files |
| USB-C toolhead MCU | No | Not through the documented MKS USB bootloader protocol; no flash-read command is known or implemented | Matching factory binary, or the exact archived Klipper application while its bootloader still enumerates |
| Stock touchscreen | No | No supported readback procedure is established here | Record its version and retain an exact matching vendor update package |

The repository's `mcu-firmware/alt-method/mcu-swflash-run.sh` demonstrates an
STM32 `stm32flash -r` read, but it is **not a backup-only command**: after the
prompt it continues directly into a firmware write. Its accompanying guide is
specific to a `ZNP-K1 V1.0`, not this `ZNP-K1-2.3`. Do not run that script just
to make a backup and do not copy its GPIO sequence onto this board. A dedicated
read-only v2.3 procedure can be added only after the boot/reset wiring and ROM
bootloader path have been validated on real hardware.

The bundled toolhead flasher implements only HELLO, START/END/ABORT, and
host-to-MCU DATA. Its per-page read-back is internal verification and does not
return firmware bytes. No read command is known or implemented by the
documented protocol, so this path cannot dump the factory toolhead application;
that does not prove an undocumented vendor command cannot exist. Its START
operation erases the 96 KiB application range at
`0x08008000`-`0x08020000`, leaving the first 32 KiB custom USB bootloader
outside that range; preserving that bootloader is the non-invasive retry path.
Physical SWD might be able to read either MCU if the exact pads are known and
readout protection is disabled, but that path is invasive and unverified here.
Do **not** use a readout-unprotect operation as an experiment. For the target
STM32F401 family, changing RDP level 1 back to level 0 mass-erases user flash;
RDP level 2 is irreversible and disables debug and system-memory boot. The
GD32F30x documentation likewise says removing security protection mass-erases
main flash. See the
[stm32flash manual](https://github.com/stm32duino/stm32flash/blob/main/stm32flash.1)
for read syntax, [ST RM0368 section 3.6.3](https://www.st.com/resource/en/reference_manual/rm0368-stm32f401xb-c-d-e-mb-reference-manual-stmicroelectronics.pdf)
for STM32F401 protection behavior, and the
[GD32F30x user manual](https://www.gd32mcu.com/data/documents/userManual/GD32F30x_User_Manual_Rev2.9.pdf)
for the toolhead-compatible family.

Before flashing, retain the exact matching Elegoo main/toolhead firmware if it
can be obtained, and keep the factory eMMC untouched where possible. The
patched updater also archives every newly built OpenNept4une main/toolhead
binary, expanded Klipper config, source commit, metadata, and checksums before
it writes anything. Those artifacts provide an **OpenNept4une recovery path**;
they are not a dump of the original Elegoo applications.

Prefer doing the experiment on a spare 16 GB or larger compatible eMMC module and leaving the original untouched.

## 2. Obtain and capacity-check the base image

Use this complete printer image, not the minimal `Armbian-ZNP-K1-build` output:

```text
Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img.xz
```

Download and verify the exact asset inspected for this runbook:

```bash
curl -fL \
  -o Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img.xz \
  'https://github.com/OpenNeptune3D/OpenNept4une/releases/download/v0.1.7/Neptune4-Plus%2BMax-v0.1.7-ZNP-K1-V2.0.img.xz'
sha256sum Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img.xz
xz -t Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img.xz
```

Expected values:

```text
compressed size: 921597088 bytes
SHA-256: 67123fe13b95d6ebeeb85142043efaa829fc98672e836c26d346f69e9e80c45d
raw image size: 7818182656 bytes
```

The checksum above was calculated from the official release asset on 2026-08-24; it is not an upstream-published checksum.

### Capacity gate

Some nominal 8 GB eMMC modules are slightly smaller than this image. Check before writing:

```bash
test "$(sudo blockdev --getsize64 /dev/sdX)" -ge 7818182656
```

- Exit status `0`: it fits.
- Non-zero: **do not write it**. Prefer a larger eMMC.

If the original-size module must be used, shrink a working copy on native Linux with [PiShrink](https://github.com/Drewsif/PiShrink):

```bash
xz -dk Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img.xz
git clone --depth 1 https://github.com/Drewsif/PiShrink.git
sudo ./PiShrink/pishrink.sh -s -n \
  Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img \
  Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0-shrunk.img
stat -c '%s %n' Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0-shrunk.img
```

`-s` deliberately prevents PiShrink's own first-boot expansion. Expand later with OpenNept4une's Advanced option 3 after the printer works. Verify the shrunk byte size is below the eMMC's exact capacity.

If the workstation environment does not expose a loop device (common in WSL),
PiShrink is not usable there as-is. Use native Linux/a suitable Linux VM, or
preferably use a larger eMMC. Do not experiment with hand-written partition
arithmetic on the only copy of the image.

## 3. Flash and customize the eMMC offline

Flash the compressed image directly, or substitute the uncompressed shrunk image if one was required:

```bash
# STOP: re-identify /dev/sdX after every unplug/replug. Confirm model, serial,
# capacity, and that this is the whole eMMC device—not your workstation disk.
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS /dev/sdX || {
  echo 'Could not inspect the proposed target; stop.' >&2
  exit 1
}
test -b /dev/sdX || {
  echo 'The proposed target is not a whole block device; stop.' >&2
  exit 1
}
test "$(lsblk -dnro TYPE /dev/sdX)" = disk || {
  echo 'The proposed target is a partition or non-disk block device; stop.' >&2
  exit 1
}
candidate_disk="$(readlink -f /dev/sdX)" || exit 1
root_source="$(findmnt -nro SOURCE -e -v /)" || exit 1
case "$root_source" in
  /dev/*) ;;
  *) echo "Cannot resolve the workstation root to a block device ($root_source); stop." >&2; exit 1 ;;
esac
root_backing_disks="$(
  set -o pipefail
  lsblk -slnpo NAME,TYPE "$root_source" | awk '$2 == "disk" { print $1 }'
)" || exit 1
test -n "$root_backing_disks" || {
  echo 'Could not identify the disk backing the workstation root; stop.' >&2
  exit 1
}
if grep -Fxq "$candidate_disk" <<< "$root_backing_disks"; then
  echo 'The proposed target backs the running workstation root filesystem; stop.' >&2
  exit 1
fi
test "$(sudo blockdev --getsize64 /dev/sdX)" -ge 7818182656 || {
  echo 'The target is smaller than the raw image; stop.' >&2
  exit 1
}
read -r -p 'Type the exact whole-device path shown above to authorize overwrite: ' confirmed_target
test "$confirmed_target" = '/dev/sdX' || {
  echo 'Target confirmation did not match; stop.' >&2
  exit 1
}
target_partitions="$(
  set -o pipefail
  lsblk -lnpo NAME,TYPE /dev/sdX | awk '$2 == "part" { print $1 }'
)" || { echo 'Could not enumerate target partitions; stop.' >&2; exit 1; }
while read -r target_partition; do
  test -n "$target_partition" || continue
  sudo umount "$target_partition" 2>/dev/null || true
done <<< "$target_partitions"
target_mount_state="$(lsblk -lnpo TYPE,MOUNTPOINTS /dev/sdX)" || {
  echo 'Could not re-inspect target mount state; stop.' >&2
  exit 1
}
if awk 'NF > 1 { found=1 } END { exit !found }' <<< "$target_mount_state"; then
  echo 'The target or one of its descendants is still mounted; stop before dd.' >&2
  exit 1
fi

( set -o pipefail
  xz -dc -T0 Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img.xz | \
    sudo dd of=/dev/sdX bs=4M iflag=fullblock conv=fsync status=progress
) || {
  echo 'FLASH FAILED: do not install this eMMC; re-identify it and start again.' >&2
  exit 1
}
sync
sudo blockdev --flushbufs /dev/sdX || {
  echo 'Could not flush the target before read-back; stop.' >&2
  exit 1
}
( set -o pipefail
  xz -dc -T0 Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0.img.xz | \
    sudo cmp --bytes=7818182656 - /dev/sdX
) || {
  echo 'READ-BACK FAILED: do not install this eMMC; write it again.' >&2
  exit 1
}
```

For a PiShrink output, use the uncompressed file instead:

```bash
# Repeat the destructive-boundary checks immediately before this alternative
# write too; the reader or target may have changed since the earlier check.
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS /dev/sdX || {
  echo 'Could not inspect the proposed target; stop.' >&2
  exit 1
}
test -b /dev/sdX || {
  echo 'The proposed target is not a whole block device; stop.' >&2
  exit 1
}
test "$(lsblk -dnro TYPE /dev/sdX)" = disk || {
  echo 'The proposed target is a partition or non-disk block device; stop.' >&2
  exit 1
}
candidate_disk="$(readlink -f /dev/sdX)" || exit 1
root_source="$(findmnt -nro SOURCE -e -v /)" || exit 1
case "$root_source" in
  /dev/*) ;;
  *) echo "Cannot resolve the workstation root to a block device ($root_source); stop." >&2; exit 1 ;;
esac
root_backing_disks="$(
  set -o pipefail
  lsblk -slnpo NAME,TYPE "$root_source" | awk '$2 == "disk" { print $1 }'
)" || exit 1
test -n "$root_backing_disks" || {
  echo 'Could not identify the disk backing the workstation root; stop.' >&2
  exit 1
}
if grep -Fxq "$candidate_disk" <<< "$root_backing_disks"; then
  echo 'The proposed target backs the running workstation root filesystem; stop.' >&2
  exit 1
fi
test "$(sudo blockdev --getsize64 /dev/sdX)" \
  -ge "$(stat -c '%s' Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0-shrunk.img)" || {
    echo 'The target is smaller than the shrunk image; stop.' >&2
    exit 1
  }
read -r -p 'Type the exact whole-device path shown above to authorize overwrite: ' confirmed_target
test "$confirmed_target" = '/dev/sdX' || {
  echo 'Target confirmation did not match; stop.' >&2
  exit 1
}
target_partitions="$(
  set -o pipefail
  lsblk -lnpo NAME,TYPE /dev/sdX | awk '$2 == "part" { print $1 }'
)" || { echo 'Could not enumerate target partitions; stop.' >&2; exit 1; }
while read -r target_partition; do
  test -n "$target_partition" || continue
  sudo umount "$target_partition" 2>/dev/null || true
done <<< "$target_partitions"
target_mount_state="$(lsblk -lnpo TYPE,MOUNTPOINTS /dev/sdX)" || {
  echo 'Could not re-inspect target mount state; stop.' >&2
  exit 1
}
if awk 'NF > 1 { found=1 } END { exit !found }' <<< "$target_mount_state"; then
  echo 'The target or one of its descendants is still mounted; stop before dd.' >&2
  exit 1
fi

sudo dd \
  if=Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0-shrunk.img \
  of=/dev/sdX bs=4M iflag=fullblock conv=fsync status=progress || {
    echo 'FLASH FAILED: do not install this eMMC; re-identify it and start again.' >&2
    exit 1
  }
sync
sudo blockdev --flushbufs /dev/sdX || {
  echo 'Could not flush the target before read-back; stop.' >&2
  exit 1
}
sudo cmp \
  --bytes="$(stat -c '%s' Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0-shrunk.img)" \
  Neptune4-Plus+Max-v0.1.7-ZNP-K1-V2.0-shrunk.img \
  /dev/sdX || {
    echo 'READ-BACK FAILED: do not install this eMMC; write it again.' >&2
    exit 1
  }
```

Balena Etcher is a reasonable UI alternative, especially if Windows owns the USB reader and WSL cannot see its whole block device. In either case, replug the reader or run `sudo partprobe /dev/sdX`, then use `lsblk` again to identify the new boot and root partitions. Offline Wi-Fi seeding still requires Linux access to the ext4 root partition.

### Install the board-2.3 DTB and USB-C power integration

Mount both flashed partitions. Run the repository commands below from this
fork's checkout root:

```bash
sudo mkdir -p /mnt/n4boot /mnt/n4root
sudo mount /dev/sdX1 /mnt/n4boot
sudo mount /dev/sdX2 /mnt/n4root
```

Apply the exact hardware selection with this fork's installer:

```bash
sudo ./img-config/board-hardware-setup.sh apply \
  --root /mnt/n4root \
  --boot /mnt/n4boot \
  --model n4max \
  --pcb-version 2.3 \
  --toolhead usb-c

sudo ./img-config/board-hardware-setup.sh status \
  --root /mnt/n4root \
  --boot /mnt/n4boot
```

This does four things without booting the image:

- installs `rk3328-znp-n4plus-n4max-v2.3.dtb` under `/boot/dtb/rockchip/`;
- selects that file with `fdtfile=` in `armbianEnv.txt` rather than overwriting the image's generic DTB;
- installs and enables `opennept4une-toolhead-power.service` plus its GPIO82 helper;
- records the previous DTB and service state under `/var/lib/opennept4une/board-hardware` for guarded rollback.

Verify the DTB payload:

```bash
sha256sum \
  ./dtb/n4plus-n4max-v2.3/rk3328-znp-n4plus-n4max-v2.3.dtb \
  /mnt/n4boot/dtb/rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb
grep '^fdtfile=' /mnt/n4boot/armbianEnv.txt
```

Both hashes must be:

```text
f1b238fcbabf86b17c9e7fdbf1e8916bd36abff6c4687d80efa99ebd6b9f7bc6
```

The expected selection is:

```text
fdtfile=rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb
```

The included 2.3 DTS differs from the 2.0 DTS in Ethernet timing,
video/IOMMU status, and the RK805 PMIC interrupt. Physical validation found
the inherited GPIO1 parent/line-24 declaration producing 100,001 unhandled
interrupts before Linux disabled the RK805 IRQ. An intermediate correction
changed only the line and still stormed because the numeric parent phandle
continued to select GPIO1. The corrected declaration selects GPIO2
(`gpio@ff230000`) line 6 (`RK_PA6`), matching both its pinctrl entry and the maintained
[Armbian MKS Pi DTS](https://github.com/armbian/build/blob/e65ba52e3d99004c7dd4e39665e5f9c08516a30a/patch/kernel/archive/rockchip64-6.12/dt/rk3328-mkspi.dts).
Its USB and UART nodes are unchanged, so the board-specific DTB and GPIO82
toolhead-power service are both required.

### Optional: preconfigure Wi-Fi

Yes, Wi-Fi can be configured before first boot without rebuilding the image. The release uses NetworkManager and intentionally ships without a saved connection.

The root partition is already mounted at `/mnt/n4root`. Create the NetworkManager profile:

```bash
uuidgen
sudo install -d -o root -g root -m 0700 \
  /mnt/n4root/etc/NetworkManager/system-connections
sudo install -o root -g root -m 0600 /dev/null \
  /mnt/n4root/etc/NetworkManager/system-connections/preconfigured-wifi.nmconnection
sudoedit /mnt/n4root/etc/NetworkManager/system-connections/preconfigured-wifi.nmconnection
```

Put this in the file, replacing all three angle-bracketed values. Use the output from `uuidgen` once:

```ini
[connection]
id=preconfigured-wifi
uuid=<UUID>
type=wifi
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=<SSID>
# hidden=true

[wifi-security]
key-mgmt=wpa-psk
psk=<WPA2-PASSPHRASE>

[ipv4]
method=auto

[ipv6]
method=auto
```

Leave `interface-name` unset so the connection can bind to the actual Wi-Fi adapter. Uncomment `hidden=true` only for a hidden SSID.

Enforce the permissions NetworkManager requires:

```bash
sudo chown root:root \
  /mnt/n4root/etc/NetworkManager/system-connections/preconfigured-wifi.nmconnection
sudo chmod 0600 \
  /mnt/n4root/etc/NetworkManager/system-connections/preconfigured-wifi.nmconnection
sudo grep -v '^psk=' \
  /mnt/n4root/etc/NetworkManager/system-connections/preconfigured-wifi.nmconnection
```

The passphrase is plaintext in the image. Never commit, publish, or share that image. For unusual escaping, WPA3-only networks, or enterprise Wi-Fi, configure it after boot with `sudo nmtui` instead.

Do not create Armbian's `.not_logged_in_yet` marker or rely on `armbian_first_run.txt`; the completed v0.1.7 printer image does not use that first-run path.

### Optional: preload this fork's checkout

This is the closest useful equivalent to a "pre-updated image"; no full image
build is required. It copies the current checkout, including its Git metadata,
into the mounted root filesystem. Run this from anywhere inside the checkout,
then inspect the source and ensure the backup destination is unused:

```bash
checkout_root="$(git rev-parse --show-toplevel)"
git -C "$checkout_root" status --short --branch
git -C "$checkout_root" remote -v
if [ ! -d /mnt/n4root/home/mks/OpenNept4une/.git ]; then
  echo 'Expected image checkout is missing; stop.' >&2
  exit 1
fi
if [ -e /mnt/n4root/home/mks/OpenNept4une.v0.1.7-upstream ]; then
  echo 'Backup destination already exists; preserve it and choose a new path.' >&2
  exit 1
fi
```

Then preserve the image's original checkout and install this fork:

```bash
checkout_root="$(git rev-parse --show-toplevel)"
mks_uid="$(awk -F: '$1 == "mks" { print $3 }' /mnt/n4root/etc/passwd)"
mks_gid="$(awk -F: '$1 == "mks" { print $4 }' /mnt/n4root/etc/passwd)"
if [ -z "$mks_uid" ] || [ -z "$mks_gid" ]; then
  echo 'Could not resolve the target mks UID/GID; stop.' >&2
  exit 1
fi

sudo mv \
  /mnt/n4root/home/mks/OpenNept4une \
  /mnt/n4root/home/mks/OpenNept4une.v0.1.7-upstream
sudo cp -a \
  "$checkout_root" \
  /mnt/n4root/home/mks/OpenNept4une
sudo chown -R "${mks_uid}:${mks_gid}" \
  /mnt/n4root/home/mks/OpenNept4une \
  /mnt/n4root/home/mks/OpenNept4une.v0.1.7-upstream
```

If the source checkout is dirty, the copied checkout will intentionally remain
dirty and the guarded repository updater will refuse to update it. Record the
diff and commit/push the intended integration before enabling automatic
updates. If you skip this preload, section 6 explains deployment after first
boot.

### Prepare first-boot machine identity

The v0.1.7 image may have `/etc/machine-id` absent rather than empty. Leave an
empty root-owned placeholder so systemd can establish a transient identity
while the root filesystem is initially read-only and commit it after the
filesystem becomes writable:

```bash
sudo install -o root -g root -m 0444 /dev/null \
  /mnt/n4root/etc/machine-id
sudo ln -sfn /etc/machine-id \
  /mnt/n4root/var/lib/dbus/machine-id
```

Do not generate one reusable ID in an image that will be cloned to multiple
printers. Each machine must acquire its own identity.

### Finish the offline work

```bash
sync
sudo umount /mnt/n4root
sudo umount /mnt/n4boot
```

Reinstall the eMMC and refit the printer's lower cover before powering it, so the SBC has its intended airflow.

## 4. First boot and Linux validation

For this first boot:

- leave Cartographer and the C920 physically disconnected;
- leave the USB-C toolhead connected;
- do not run a print;
- do not command movement or heating;
- have Ethernet or serial available as a fallback even if Wi-Fi was seeded.

Find the DHCP address in the router and connect:

```bash
ssh mks@<PRINTER-IP>
```

The image's initial password is `makerbase`. Change it immediately:

```bash
passwd
```

Verify that first boot persisted a valid machine identity without printing it
into a log. If the check fails, initialize it now while the root filesystem is
writable; this is the repair path for an already-booted v0.1.7 image:

```bash
if ! sudo grep -Eq '^[0-9a-f]{32}$' /etc/machine-id; then
  sudo systemd-machine-id-setup
fi
sudo grep -Eq '^[0-9a-f]{32}$' /etc/machine-id
test "$(readlink /var/lib/dbus/machine-id)" = /etc/machine-id
```

The machine ID is host-confidential. Do not print it into a support log or
commit it to this repository. If it had to be repaired, include that change in
the planned DTB reboot below before evaluating service timestamps or status.

The release image already contains display, affinity, and `mjpg-streamer` services. Disable only the camera during base bring-up. Keep the release's `display.service` and `affinity.service` together: v0.1.7 couples those units, and affinity pins Klipper, `klipper-mcu`, and serial IRQ work as a latency safeguard. Disabling display and then starting affinity merely pulls display back in, so treat the stock screen pair as part of the base baseline. Capture both definitions and verify them:

```bash
sudo systemctl disable --now mjpg-streamer-webcam1.service 2>/dev/null || true
systemctl cat display.service | tee ~/display-v0.1.7.before-upgrade.txt
systemctl cat affinity.service | tee ~/affinity-v0.1.7.before-upgrade.txt
sudo systemctl enable --now display.service affinity.service
systemctl status display.service affinity.service --no-pager
```

Do not treat `affinity.service` as disposable display-only tuning. If either coupled service fails, inspect both units/helpers and the journal before commissioning any USB MCU; do not simply leave affinity disabled. Section 13 upgrades and backs up the pair together.

Validate the booted image and DTB:

```bash
uname -a
cat /boot/.OpenNept4une.txt
grep '^fdtfile=' /boot/armbianEnv.txt
sha256sum /boot/dtb/rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb
ip -br address
nmcli device status
journalctl -b -p warning --no-pager
```

The selected path must be
`rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb`, and its hash must still be
`f1b238fc...7bc6`. Verify both Ethernet and Wi-Fi if possible; the board-2.3
DTB changes Ethernet timing. Also confirm the RK805 interrupt is present but
not storming or disabled:

```bash
grep -E 'rk805|Err:' /proc/interrupts
journalctl -k -b --no-pager | \
  grep -Ei 'irq [0-9]+: nobody cared|disabling IRQ|rk805'
systemctl status power_monitor.service --no-pager
```

An RK805 parent line accumulating roughly 100,000 interrupts followed by
`nobody cared` or `Disabling IRQ` is a hard stop. Do not use the kernel's
`irqpoll` suggestion as a workaround and do not flash an MCU.

If the DTB still has the former `c966b74c...e0d8` or intermediate
`808c234c...c92b` hash, update this fork's
checkout, ensure it is clean, and reconcile the corrected integration before
continuing:

```bash
cd ~/OpenNept4une
git status --short --branch
git pull --ff-only origin dev
sudo ./img-config/board-hardware-setup.sh apply \
  --model n4max \
  --pcb-version 2.3 \
  --toolhead usb-c
sudo reboot
```

After reconnecting, require the new `f1b238fc...7bc6` hash, an active
`power_monitor.service`, and an RK805 parent on GPIO line 6 that is neither
rapidly increasing nor disabled:

```bash
sha256sum /boot/dtb/rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb
systemctl is-active power_monitor.service
grep -E 'rk805|Err:' /proc/interrupts
journalctl -k -b --no-pager | \
  grep -Ei 'irq [0-9]+: nobody cared|disabling IRQ|rk805'
```

If Wi-Fi did not associate, use Ethernet and run `sudo nmtui`. The hardware serial fallback documented by OpenNept4une uses the front I/O USB-C serial connection at 1,500,000 baud, with 115200 as a fallback if required by the adapter/firmware.

Stop here if Linux does not boot consistently, the root filesystem reports
errors, both network paths fail, the RK805 IRQ is disabled, or
`power_monitor.service` is failed. Restore the raw eMMC backup or correct the
specific integration fault before attempting any MCU update.

## 5. Verify USB-C toolhead power on every boot

The USB-C toolhead rail is controlled by RK3328 GPIO2_C2, exposed by this image through legacy sysfs as GPIO82. The offline board installer should already have installed the helper, service, and Klipper dependency. Verify them:

```bash
grep '^fdtfile=' /boot/armbianEnv.txt
systemctl status opennept4une-toolhead-power.service --no-pager
systemctl cat klipper.service
systemctl show klipper.service -p Nice -p IOSchedulingPriority
sudo /usr/local/sbin/opennept4une-toolhead-power status
lsusb
ls -l /dev/serial/by-id/ 2>/dev/null
```

The managed Klipper drop-in must include the following exact, case-sensitive
systemd section. These priorities reduce the chance of Klipper being delayed by
host/eMMC I/O and reporting `Timer too close` during a print:

```ini
[Service]
Nice=-18
IOSchedulingPriority=1
```

The board installer writes this into
`/etc/systemd/system/klipper.service.d/20-opennept4une-toolhead-power.conf`;
do not edit the vendor unit by hand. After applying an updated checkout, verify
that `systemctl cat` shows the block and that `systemctl show` reports `Nice=-18`
and `IOSchedulingPriority=1`. Restart Klipper after changing an already-running
machine:

```bash
sudo systemctl daemon-reload
sudo systemctl restart klipper.service
```

If the service/helper is absent, deploy this fork as described in section 6 and then apply the integration online:

```bash
sudo ~/OpenNept4une/img-config/board-hardware-setup.sh apply \
  --model n4max \
  --pcb-version 2.3 \
  --toolhead usb-c
sudo reboot
```

After reboot, `status` must report output direction and value `1`, the service must be active, and the selected DTB must be the v2.3 file. The toolhead may appear as its application, its bootloader, or not yet have a known by-id name if its factory firmware differs.

Do ten cold-boot checks before considering this hardware path validated. The
checker verifies the four conditions above and counts each Linux boot ID at
most once. Software cannot tell a warm reboot from actual power removal, so
pass `--record-cold-boot` only after removing mains power completely and then
starting the printer:

```bash
~/OpenNept4une/img-config/check-toolhead-cold-boot.sh \
  --record-cold-boot
```

Running the script without that option validates the current state without
incrementing the count. It pins the first recorded persistent serial identity,
rejects a later identity change, and stores hashed boot IDs plus timestamps in
`~/.local/state/opennept4une/toolhead-cold-boots.tsv`. Record any failure and
stop rather than guessing another GPIO. The sysfs GPIO API is deprecated on
newer Linux systems, but it is the interface exposed by the current v0.1.7
image.

## 6. Put this fork on the printer

If section 3 preloaded this fork, only verify it:

```bash
git -C ~/OpenNept4une status --short --branch
git -C ~/OpenNept4une remote -v
test -x ~/OpenNept4une/img-config/board-hardware-setup.sh
test -r ~/OpenNept4une/img-config/n4flash/n4flash.c
```

Otherwise, preserve the release's checkout on the printer:

```bash
cd ~
if [ -e ~/OpenNept4une.v0.1.7-upstream ]; then
  echo 'Backup path already exists; stop and inspect it.' >&2
  exit 1
fi
mv OpenNept4une OpenNept4une.v0.1.7-upstream
```

To deploy an unpushed local checkout, run this from anywhere inside it on the
workstation:

```bash
checkout_root="$(git rev-parse --show-toplevel)"
scp -r \
  "$checkout_root" \
  mks@<PRINTER-IP>:/home/mks/OpenNept4une
```

If the changes have first been committed and pushed to the personal fork, clone it instead:

```bash
git clone --branch dev \
  https://github.com/dalgibbard/OpenNept4une.git \
  ~/OpenNept4une
```

Back on the printer, verify the source and run the hardware-independent suite:

```bash
git -C ~/OpenNept4une status --short --branch
git -C ~/OpenNept4une remote -v
sha256sum ~/OpenNept4une/img-config/n4flash/n4flash.c
cd ~/OpenNept4une
./tests/run.sh
```

The bundled `n4flash.c` is based on pinned upstream commit `686c3bf1...` and adds fail-closed size/read/completion-ack checks. It ignores unrelated periodic HELLO frames while waiting for the matching response, sends the mass-erasing START command only once, requests ABORT if START acknowledgement remains uncertain, and advances DATA only when the acknowledgement echoes the exact page and length. Its reviewed hash must be:

```text
fb44684204d97a2fbee2ab1762828ff39b2079a2794bbdaed0fc01a65720df70
```

The test suite compiles `n4flash` with strict warnings. If no C compiler is installed, install `build-essential` on the printer and rerun it. The updater later compiles the same source privately at `~/.local/lib/opennept4une/n4flash`; there is no separate clone or hand-written `/dev/ttyACM0` command.

Persist the physical selection before flashing. This command deliberately does not generate `printer.cfg`, so it succeeds even though the final Klipper toolhead ID does not exist yet:

```bash
~/OpenNept4une/OpenNept4une.sh \
  --yes \
  --printer_model n4max \
  --pcb_version 2.3 \
  --toolhead usb-c \
  set_printer_model

grep -E '^N4' /boot/.OpenNept4une.txt
sudo ~/OpenNept4une/img-config/board-hardware-setup.sh status
```

The flag must be `N4Max-v2.3-tusbc`. This removes the old circular dependency in which selecting the physical USB-C head required its final Klipper firmware to be present first.

The distributed image also contains prepared-image SSH host keys. Regenerate them once networking is known to work:

```bash
bash ~/OpenNept4une/img-config/update-ssh-keys.sh
```

Your workstation will then report a changed host key; remove only this printer's old entry with `ssh-keygen -R <PRINTER-IP>` and verify the newly displayed fingerprint before reconnecting.

`n4flash` mass-erases the toolhead application's 96 KiB region before transferring the new image. An interrupted transfer leaves no bootable application, although the bootloader should remain available for a retry. Use stable mains power and do not flash during a storm, on a switched smart plug, or through a flaky USB connection.

### Update behavior

The patched scripts derive Moonraker's update-manager URL from the checkout's actual `origin` and compare updates with `origin/<current-branch>`. Installing the stock Moonraker template no longer rewrites a personal fork back to upstream. The updater also refuses a dirty checkout and accepts only a fast-forward; it no longer resolves divergence by deleting local work.

If the deployed integration is uncommitted, leave repository updates disabled
and do not switch branches. Once it is committed and pushed, verify that
`origin` is `dalgibbard/OpenNept4une`; the built-in and Moonraker update paths
may then follow that fork normally.

## 7. Flash the USB-C toolhead safely

Do this before generating the USB-C printer configuration, because configuration generation requires the final Klipper toolhead serial ID.

Physically disconnect all unrelated USB devices, especially Cartographer and the C920. Before flashing, capture what the factory/application state exposes:

```bash
mkdir -p ~/n4max-usbc-identities
lsusb | tee ~/n4max-usbc-identities/application-lsusb.txt
ls -l /dev/serial/by-id/ 2>&1 \
  | tee ~/n4max-usbc-identities/application-by-id.txt
```

For every plausible toolhead serial path, capture its properties using the exact path shown—not a guessed node:

```bash
udevadm info --query=property \
  --name=/dev/serial/by-id/<EXACT-APPLICATION-ID> \
  | tee ~/n4max-usbc-identities/application-udev.txt
```

This is an identity/configuration record, **not** a factory-firmware backup.
The documented MKS USB protocol has no known or implemented application-read
command. If returning to the exact factory toolhead application is a hard
requirement and you do not have a matching Elegoo binary, stop here. Do not
assume the Type-C eMMC recovery image contains separate MCU firmware until its
contents and target have been verified.

It is acceptable if another pre-Klipper application does not match
`usb-Klipper_stm32f103xe_*`. The first physically validated sample enumerated
as VID:PID `1d50:614e` with
`usb-Klipper_stm32f103xe_105B303534340C0039333032-if00`; this is one observed
device identity, not a universal serial value. The updater can use the
persisted board selection to enter the bootloader through GPIO82.

Choose the Klipper source revision once, before the first MCU build. The patched updater no longer runs `git pull` implicitly between separate MCU operations; its first run records `~/printer_data/config/Firmware/klipper-build-source.commit`, and every later MCU run must match it:

```bash
git -C ~/klipper status --short --branch
test -z "$(git -C ~/klipper status --porcelain)"
git -C ~/klipper rev-parse HEAD
test ! -e ~/printer_data/config/Firmware/klipper-build-source.commit || \
  cat ~/printer_data/config/Firmware/klipper-build-source.commit
```

For initial bring-up, keep the image's known source revision. If you deliberately fast-forward Klipper later, do that once while no MCU build is in progress, remove only `klipper-build-source.commit` to start a new coordinated build set, and rebuild every required MCU from the newly displayed SHA. Never update Klipper between the toolhead, main-MCU, and virtual-MCU runs.

Run the MCU updater and choose only **USB-C Toolhead**:

```bash
~/OpenNept4une/OpenNept4une.sh update_mcu_rpi_fw
```

The patched flow performs these gates before writing:

1. obtains a process-wide updater lock before touching Klipper's shared `.config` or `out/` directory;
2. pins the Klipper source SHA so the separate main, toolhead, and virtual-MCU runs cannot silently mix protocol revisions;
3. builds the STM32F103xE-layout firmware with the tested Cortex-M4 override for the physical GD32F303-compatible part;
4. validates the target-specific expanded config and rejects an empty image or one larger than the 96 KiB application region;
5. archives and flushes the binary, expanded `.config`, target metadata, pinned Klipper commit, size, and checksums under `~/printer_data/config/Firmware/builds/`, then revalidates and flashes that archived copy rather than mutable `~/klipper/out/klipper.bin`;
6. compiles the bundled pinned `n4flash` source locally;
7. requires the literal confirmation `FLASH`;
8. stops Klipper only after establishing its service state and restores it on exit;
9. cycles GPIO82 through the installed helper;
10. requires exactly one `/dev/serial/by-id/usb-MKS_DRIVER_BOOT_*` path;
11. confirms that path has VID/PID `1d50:018a` through udev;
12. revalidates the archive after the confirmation/device-selection interval, requires its original firmware digest, copies it into a private mode-`0400` snapshot, and gives that snapshot—not the user-readable archive path—to `n4flash`;
13. saves the bootloader identity before writing and then saves/verifies the final Klipper application identity plus `MCU_ID.cfg` before reporting success.

On the first hardware flash, pause at the `FLASH` prompt and copy the exact
reported toolhead archive directory to the workstation from a second terminal.
The updater has flushed and verified it at that point, but has not yet erased
the application. Then type `FLASH` only after the off-device copy verifies.

If the bootloader name or VID/PID differs, the updater refuses to flash and prints diagnostics. Save that output; update the detection only after the physical identity is understood. Do **not** weaken the guard to select `/dev/ttyACM0`.

Immediately after a successful flash, record both states. The application capture is the value the user plans to provide for the outstanding TODO:

```bash
cat ~/printer_data/config/Firmware/usb-c-identities/bootloader-udev.txt
cat ~/printer_data/config/Firmware/usb-c-identities/application-udev.txt
lsusb | tee ~/n4max-usbc-identities/klipper-application-lsusb.txt
ls -l /dev/serial/by-id/ 2>&1 \
  | tee ~/n4max-usbc-identities/klipper-application-by-id.txt

mapfile -t application_ids \
  < <(compgen -G '/dev/serial/by-id/usb-Klipper_stm32f103xe_*')
test "${#application_ids[@]}" -eq 1
udevadm info --query=property --name="${application_ids[0]}" \
  | tee ~/n4max-usbc-identities/klipper-application-udev.txt
cat ~/printer_data/config/MCU_ID.cfg
find ~/printer_data/config/Firmware/builds -maxdepth 3 -type f -print
for build_dir in ~/printer_data/config/Firmware/builds/*; do
  test -d "$build_dir" || continue
  (cd "$build_dir" && sha256sum --check --strict SHA256SUMS)
done
```

The updater writes `[mcu THR]` to `MCU_ID.cfg` only when exactly one final application by-id path exists. If the transfer is interrupted, do not proceed to configuration: keep power stable, re-enter the `usb-MKS_DRIVER_BOOT_*` bootloader, rerun the updater, and choose **USB-C Toolhead Recovery** with the archive just created. The bootloader should remain available even though the application region was erased.

Copy the newly reported build-archive directory off the printer and verify its
checksum manifest there. A later `make clean` or another MCU build overwrites
`~/klipper/out/klipper.bin`; the versioned archive is the durable recovery
copy.

## 8. Generate the Max/2.3/USB-C configuration

Klipper cannot inspect the main MCU, report its installed firmware identity, or
request its serial bootloader without a valid `printer.cfg`. Generate the
machine configuration before deciding whether the main MCU needs another flash.
The final USB-C toolhead by-id path must already exist:

```bash
cp -a ~/printer_data/config ~/printer_data/config.before-n4max-v2.3-usbc

~/OpenNept4une/OpenNept4une.sh \
  --yes \
  --printer_model n4max \
  --pcb_version 2.3 \
  --toolhead usb-c \
  install_printer_cfg </dev/null

sudo systemctl restart klipper.service
sleep 15
curl -sS http://127.0.0.1/printer/info | jq .
```

Require `Printer is ready`, then record all three MCU identities before
continuing:

```bash
grep -E "Loaded MCU '(mcu|THR|rpi)'" \
  ~/printer_data/logs/klippy.log | tail -n 12
```

An Elegoo identity such as `KLP_ELEGOO_N4_M_K1_...` proves the main controller
is communicating but still runs Elegoo's application. It does not prove that
the newly archived OpenNept4une build was installed. After a successful update,
the main MCU must identify with the intended coordinated Klipper source version.

## 9. Update the main MCU and virtual Linux MCU separately

### Main MCU: use microSD

Run the OpenNept4une MCU updater and choose only **STM32**:

```bash
~/OpenNept4une/OpenNept4une.sh update_mcu_rpi_fw
```

The patched updater deliberately does not expose the reference fork's timing-sensitive main-MCU serial path. It builds the two microSD files unless the printer already has OpenNept4une's established alternative method installed.

The updater creates both files in `~/printer_data/config/Firmware/`:

```text
X_4.bin
elegoo_k1.bin
```

It also creates a versioned main-MCU recovery bundle under
`~/printer_data/config/Firmware/builds/` before staging those files. Copy that
directory off the printer alongside `X_4.bin` and `elegoo_k1.bin`. This is the
new OpenNept4une application build, not a readback of the factory MCU. Each
bundle has this form:

```text
<UTC>-<TARGET>-<KLIPPER-COMMIT>/
├── klipper.bin
├── klipper.config
├── klipper-source.commit
├── build-metadata.txt
└── SHA256SUMS
```

`<TARGET>` is `main-mcu` or `usb-c-toolhead`.

After both builds, make one downloadable recovery bundle containing the build
archives, pinned commit, staged main-MCU files, and captured USB identities:

```bash
recovery_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
recovery_tar="$HOME/printer_data/config/n4max-firmware-recovery-${recovery_stamp}.tar.gz"
tar -C "$HOME/printer_data/config" -czf "$recovery_tar" Firmware
sha256sum "$recovery_tar" > "${recovery_tar}.sha256"
printf 'Recovery bundle: %s\n' "$recovery_tar"
```

Download the `.tar.gz` and its `.sha256` through Fluidd and keep them with the
raw eMMC/config backups.

Download both through Fluidd, or copy them from the printer. Put both in the root of a small FAT32-formatted microSD card. Then:

1. Shut the printer down cleanly.
2. Remove mains power.
3. Insert the card into the hidden mainboard MCU slot, not the Linux/eMMC reader.
4. Restore power and wait at least two full minutes without moving or heating
   anything. There is no validated external LED or screen indication that
   proves completion on this board.
5. If Linux and Fluidd return while the card is still installed, treat a
   Klipper `Printer is ready` state and the absence of main-MCU connection or
   protocol errors as useful supporting evidence, not proof that a new image
   was written.
6. Shut Linux down cleanly, wait for shutdown to finish, and remove mains
   power before extracting the card.
7. Inspect the card on the workstation. Some MCU bootloaders rename the file
   they consumed from `.bin` to `.CUR`, but that behavior is not documented as
   a reliable success signal for every Elegoo bootloader. Later bootloaders use
   `elegoo_k1.bin`, while earlier variants use `X_4.bin`, which is why the same
   payload is supplied under both names. Preserve a directory listing, but use
   Klipper's reported main-MCU identity after reboot as the decisive check.
8. Reinstall the mainboard cover, boot normally without the card, and require
   Fluidd to report `Printer is ready` with no main-MCU connection or protocol
   errors in `klippy.log`.

Before removing the card, the non-destructive supporting checks are:

```bash
systemctl status klipper.service --no-pager -l
grep -E "Loaded MCU 'mcu'|MCU 'mcu' config|mcu 'mcu': Unable to connect|Protocol error" \
  ~/printer_data/logs/klippy.log | tail -n 30
```

Do not remove the microSD while the printer is powered. Any `.CUR` observation
is available only after the clean shutdown and physical card removal, and is
supporting evidence rather than proof on this board.

Do not have the C920 or Cartographer connected during this operation.

### Validated serial fallback for the ZNP-K1-2.3 main MCU

On 2026-08-25, the reference fork's pristine `n4flash` main-controller path
was successfully validated on the Neptune 4 Max / `ZNP-K1-2.3` / USB-C machine
used for this guide after its microSD bootloader did not consume either staged
filename. Do not use this as the first-choice update method: it erases the MCU
application region once transfer starts, and bootloader entry is timing
sensitive.

This fallback requires all of the following:

- Klipper already reaches `Printer is ready` with the installed main MCU over
  `/dev/ttyS0`, so `firmware_restart` can request its bootloader.
- A checksum-verified `main-mcu` build archive from the coordinated Klipper
  source revision exists. Never use the shared `~/klipper/out/klipper.bin`,
  which another target build may have replaced.
- Printer power remains stable from START until transfer completion.
- The final main-MCU identity is checked even if the pristine utility prints
  `> done`; that implementation does not make its exit status depend on the
  final END acknowledgement.

The exact validated pristine source was
`gggcodes/n4flash@686c3bf1d0ea5f98d991ea56a3f5a35944f300fd`:

```text
n4flash.c SHA-256:
fed0708f556462a6d02aba6627237b42bcdaffc3bbafde34751dbc1602f2cb2d
```

Fetch and compile that exact source on the printer:

```bash
git clone https://codeberg.org/gggcodes/n4flash.git ~/n4flash-source
git -C ~/n4flash-source checkout --detach \
  686c3bf1d0ea5f98d991ea56a3f5a35944f300fd

printf '%s  %s\n' \
  fed0708f556462a6d02aba6627237b42bcdaffc3bbafde34751dbc1602f2cb2d \
  "$HOME/n4flash-source/n4flash.c" | sha256sum --check --strict

cc -O2 -Wall -Wextra -o ~/n4flash ~/n4flash-source/n4flash.c
chmod 0755 ~/n4flash
```

Select the exact archive printed by the updater; do not blindly select the
newest directory. Replace the placeholder below, then validate both its target
and checksum manifest:

```bash
main_archive="$HOME/printer_data/config/Firmware/builds/REPLACE_WITH_EXACT_MAIN_MCU_ARCHIVE"
main_firmware="${main_archive}/klipper.bin"

test -d "$main_archive" || { echo 'Exact main-MCU archive not found; stop.' >&2; exit 1; }
grep -Fx 'target=main-mcu' "$main_archive/build-metadata.txt" || exit 1
(cd "$main_archive" && sha256sum --check --strict SHA256SUMS) || exit 1
test -s "$main_firmware" || exit 1
test -w /dev/ttyS0 || exit 1
```

With the printer idle and power stable, enter the bootloader and immediately
run the transfer:

```bash
curl --fail --silent --show-error \
  http://127.0.0.1/printer/firmware_restart -d 0
sleep 1
sudo systemctl stop klipper.service
~/n4flash "$main_firmware" /dev/ttyS0
```

Do not interrupt the printer after n4flash reports `sending start`. If it
prints `> failed`, times out, or disconnects after START, keep the printer
powered and preserve the complete output for recovery diagnosis. After
`> done`, restart Klipper and require the main MCU to report the coordinated
source version rather than `KLP_ELEGOO_...`:

```bash
sudo systemctl start klipper.service
sleep 15
curl -sS http://127.0.0.1/printer/info | jq .
grep "Loaded MCU 'mcu'" ~/printer_data/logs/klippy.log | tail -n 1
```

### Virtual Linux MCU

The virtual RPi MCU is the `klipper_mcu` Linux service and executable stored on
the eMMC, not another physical controller. A prepared image may already contain
a compatible build. Check the latest MCU identities first:

```bash
grep -E "Loaded MCU '(mcu|THR|rpi)'" \
  ~/printer_data/logs/klippy.log | tail -n 3
```

If `rpi` already reports the same Klipper source version as the host, main MCU,
and THR, do not rebuild it merely to repeat the same version. If it is absent or
reports a different source version, run the updater again and choose only
**Virtual RPi**:

```bash
~/OpenNept4une/OpenNept4une.sh update_mcu_rpi_fw
```

Allow its reboot. The patched menu offers only one target per run.

After reboot, check Klipper's log and web UI. The main MCU, THR MCU, and Klipper host must report mutually compatible protocol versions before continuing.

### Verify the generated machine configuration

Section 8 generated the exact machine selection before MCU inspection and
updates. Recheck it here after the coordinated MCU set is running.

The resulting model flag should contain:

```text
N4Max-v2.3-tusbc
```

Verify the important generated values:

```bash
cat /boot/.OpenNept4une.txt
cat ~/printer_data/config/MCU_ID.cfg
grep -En 'THR:|filament|\[mcu|serial:|restart_method' \
  ~/printer_data/config/printer.cfg \
  ~/printer_data/config/MCU_ID.cfg
```

Expected USB-C mappings from this fork are:

| Function | Pin |
|---|---|
| Extruder step / dir / enable | `THR:PB14` / `THR:PB13` / `!THR:PA8` |
| Hotend heater / thermistor | `THR:PA3` / `THR:PA0` |
| Extruder TMC UART | `THR:PB15` |
| Factory inductive probe | `^THR:PB12` |
| Part / hotend / auxiliary fans | `THR:PB1` / `THR:PB0` / `THR:PB11` |
| Max part light | `THR:PB10` |
| Toolhead LIS2DW | `THR:PA4`, `PA5`, `PA7`, `PA6` |

Also verify that PB10 is declared exactly once and not as a neopixel, and that board integration remains active:

```bash
grep -n 'THR:PB10\|neopixel toolhead_led' \
  ~/printer_data/config/printer.cfg
sudo ~/OpenNept4une/img-config/board-hardware-setup.sh status
```

### Install the remaining fresh-image configuration set

This is a required fresh-install step and is separate from generating
`printer.cfg`. Run the configuration installer before checking Moonraker or
making Cartographer, webcam, KAMP, Mainsail, or Fluidd customizations:

```bash
~/OpenNept4une/OpenNept4une.sh install_configs
```

Confirm installation, then choose **1) All** inside this **configuration
installer**. This is unrelated to the removed MCU `All` action. It installs or
overwrites the stock OpenNept4une configuration files, including
`moonraker.conf`, and immediately rewrites its OpenNept4une update-manager block
from the active checkout's real branch and `origin` URL.

Restart Moonraker after the installer returns:

```bash
sudo systemctl restart moonraker.service
sleep 5
systemctl is-active moonraker.service
```

Then inspect `~/printer_data/config/moonraker.conf`. This fork should have generated this block from the checkout's real `origin`:

```ini
[update_manager OpenNept4une]
type: git_repo
primary_branch: dev
path: /home/mks/OpenNept4une
is_system_service: False
origin: https://github.com/dalgibbard/OpenNept4une.git
```

Confirm it rather than editing it blindly:

```bash
grep -A6 '^\[update_manager OpenNept4une\]' \
  ~/printer_data/config/moonraker.conf
git -C ~/OpenNept4une remote get-url origin
```

The two URLs must agree. Keep updates disabled while the deployed working tree
is dirty or contains unpushed integration work; after committing and pushing,
both update mechanisms follow the personal fork.

The generic configuration set may also contain an `[update_manager display]`
block. Remove that complete block for this hardware and restart Moonraker; the
display connector itself must remain uninstalled and disabled as specified in
section 13.

## 10. Cold commissioning and factory-probe baseline

With nozzle and bed cold, restart Klipper and inspect the logs:

```bash
sudo systemctl restart klipper.service
systemctl status klipper.service --no-pager
journalctl -u klipper.service -b --no-pager -n 150
```

In the Klipper console:

1. Confirm hotend, bed, host, and THR temperatures are plausible room-temperature values. A value near zero, several hundred degrees, or a rapidly changing idle value is a stop condition.
2. Confirm the generated `[stepper_x]` and `[stepper_y]` sections use
   `tmc2209_stepper_x:virtual_endstop` and
   `tmc2209_stepper_y:virtual_endstop`. The Max uses TMC2209 StallGuard
   sensorless homing for X/Y; it has no X/Y microswitches to press. Do not try
   to trigger these by pushing an energised carriage or bed. `QUERY_ENDSTOPS`
   is only a passive status snapshot for these virtual endstops, not a useful
   hand-actuation test.
3. Z uses the factory inductive probe as `probe:z_virtual_endstop`, not a
   separate Z switch. Run `QUERY_PROBE`, bring a clean metal object underneath
   the probe's sensing face without touching the nozzle, run `QUERY_PROBE`
   again, and require its state to change. Remove the metal and require it to
   return to the original state.
4. Run `QUERY_FILAMENT_SENSOR SENSOR=filament_sensor`; insert/remove filament and compare behavior with the stock configuration. Keep the sensor disabled if it is wrong.
5. With the toolhead and bed manually positioned away from every hard limit
   while motors are off, use `STEPPER_BUZZ STEPPER=stepper_x`, then Y and Z,
   only with safe physical clearance. Confirm the intended axis moves and
   returns approximately one millimetre; this verifies identity/direction
   before any homing move.
6. With a hand on the printer's power switch and the travel path clear, test
   sensorless homing one axis at a time using `G28 X` and then `G28 Y`. Each
   axis must travel toward its configured zero end, make only a controlled
   contact with the mechanical limit, and stop immediately. Cut power if it
   moves the wrong way, grinds, repeatedly strikes the limit, or does not stop.
7. Test each fan at low duty and identify it physically.
8. Briefly request a low hotend target, such as 40 C, while watching the displayed temperature and keeping a hand on the emergency power switch. Cancel immediately after confirming the correct sensor rises. Repeat separately for the bed.

Do not home Z until the factory probe is proven.

### Calibrate the bed with the factory probe

Complete this calibration and a baseline print before removing or disabling the
factory probe. Use a clean plate and nozzle, and keep the same plate, bed
temperature, heat-soak time, filament, slicer profile, and first-layer test for
the later Cartographer comparison.

First tram the heated bed mechanically. The generated configuration provides
`BED_LEVEL_SCREWS_TUNE`, which clears the old mesh, heats the bed to its current
target or 60 C, waits for temperature, homes, and runs
`SCREWS_TILT_CALCULATE`:

```text
BED_LEVEL_SCREWS_TUNE
```

Adjust each bed knob in the direction and clock amount reported by Klipper,
then rerun `BED_LEVEL_SCREWS_TUNE`. Repeat until every adjustable point is
approximately `00:05` or better relative to the reference screw. This changes
the physical bed plane, so any earlier probe Z offset or mesh is now invalid.

For reference, the equivalent individual console commands at 60 C are:

```text
BED_MESH_CLEAR
SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=60
TEMPERATURE_WAIT SENSOR=heater_bed MINIMUM=58 MAXIMUM=65
G28
SCREWS_TILT_CALCULATE
```

Next calibrate the factory probe's Z offset using Klipper's paper test. Turn
the heaters off and let the clean nozzle and bed return to room temperature
before this step:

```text
TURN_OFF_HEATERS
G28
PROBE_CALIBRATE
```

When the manual-probe prompt appears, place ordinary printer paper under the
nozzle and approach in progressively smaller steps, for example:

```text
TESTZ Z=-0.1
TESTZ Z=-0.05
TESTZ Z=-0.01
```

Use a positive value to back away if necessary. When the paper has slight,
repeatable drag, finish with:

```text
ACCEPT
SAVE_CONFIG
```

`SAVE_CONFIG` restarts Klipper. After it returns, heat and soak the bed using
the same conditions intended for the baseline print, then check repeatability
and create a full mesh:

```text
BED_MESH_CLEAR
SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=60
TEMPERATURE_WAIT SENSOR=heater_bed MINIMUM=58 MAXIMUM=65
G4 P600000
G28
PROBE_ACCURACY SAMPLES=10
BED_MESH_CALIBRATE
SAVE_CONFIG
```

Inspect the `PROBE_ACCURACY` range and stop if it is inconsistent or has
outliers. After the restart, use `BED_MESH_OUTPUT` to retain the baseline mesh
output, then print a conservative single-layer square/grid or another known
first-layer test. Watch the entire first layer and use emergency stop if the
nozzle approaches the plate incorrectly. Save the successful G-code, slicer
profile, mesh screenshot/output, and a photograph of the first layer, then
back up the calibrated configuration:

```bash
cp -a ~/printer_data/config \
  ~/printer_data/config.factory-probe-baseline
```

Do not install Cartographer until the printer can home carefully, tram and
mesh with the factory probe, heat correctly, and complete this baseline print.
That known-good checkpoint separates base board/toolhead problems from
Cartographer installation or calibration problems.

## 11. Cartographer v4 over USB

### Wiring and mechanical rules

- Keep the v4 in its factory USB mode initially; v4 normally ships with USB firmware.
- Supply **5 V only**. Applying 24 V destroys the probe.
- Use Cartographer's supplied USB harness back to the host SBC or a good powered hub. The USB-C toolhead MCU is not a generic Cartographer USB port.
- Mount the coil rigidly, flat, and approximately 2.6-3.0 mm above the nozzle tip for Survey Touch.
- The Max's large auxiliary fan bar behind the X axis can collide with the
  Cartographer body/mount and, on some assemblies, the protruding screws behind
  the toolhead bearings. Resolve that mechanical interference before powered
  motion.
- Keep metal outside the documented keep-out area.
- The supplied USB lead is not normally cable-chain rated; strain-relieve it along an umbilical/Bowden route.
- Prefer Cartographer direct to the host and the C920 on a powered hub if the physical ports allow it.

Official references:

- [Cartographer Klipper setup](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/klipper-setup)
- [Wiring diagrams](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/probe-installation/wiring-diagrams)
- [Scan calibration](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/scan-calibration)
- [Touch calibration](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/touch-calibration)
- [Axis twist compensation](https://docs.cartographer3d.com/cartographer-probe/features/axis-twist-compensation)
- [Full versus Lite firmware](https://docs.cartographer3d.com/cartographer-probe/firmware#full-vs-lite-firmwares)
- [Print-start template](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/print_start-template)

Follow those current pages in that order: install/configure the plugin, create
and save the manual scan model, and only then calibrate Survey Touch. The
machine-specific commands and coordinates below adapt that official workflow
to the validated Max configuration; they do not replace the safety notes on
the linked pages.

### Auxiliary fan-bar clearance

The stock Neptune 4 Max auxiliary fan bar sits close behind the toolhead. With
the Cartographer mount used in this guide it may strike the probe, and normal
assembly tolerance can also let it strike the rear toolhead-bearing screws. A
6 mm setback was not enough in physical testing, and stacking two short
spacers directed the fan airflow at the probe. Use four 20 mm spacers and four
80 mm M4 screws to move the complete bar rearward instead. The updated spacer
is available here:

- [Neptune 4 Max auxiliary fan-bar spacer](https://www.thingiverse.com/thing:7401156)

Treat the printed spacer as an installation aid, not proof of clearance. Check
that the 80 mm screws suit the actual printer and printed parts, and require
full safe thread engagement without a screw protruding into a belt, wheel,
cable, or moving component. The 20 mm setback must leave the airflow passing
under the hotend rather than directly over the Cartographer. With power off,
slowly move the toolhead
through the complete X travel and inspect from above, behind, and both ends.
Check the Cartographer PCB/coil, its mount and USB cable, every rear
toolhead-bearing screw, the fan-bar housing, and the Z-upright/end clearances.
Allow extra margin for cable flex and vibration rather than accepting parts
that merely touch at rest.

After tightening the spacer and fan bar, repeat the full manual sweep and check
that the bar is rigid, its wiring is strain-relieved, and no fan intake or
outlet is obstructed. Do not begin `G28`, corner verification, axis-twist, or
resonance motion until this test passes. Recheck all fasteners and clearance
after the first resonance test and several heat cycles.

Alternatively, remove the auxiliary fan bar completely. Secure its loose cable
to the hotend cable with a zip tie so that it cannot flap into an axis, belt,
wheel, or hot component. Never leave the disconnected cable free to move.

The linked Cartographer mount is screwed down on only one side. After its
position and offset have been verified, place a small blob of suitable glue on
the unscrewed side so vibration cannot let the probe pivot. Keep glue away from
the PCB, coil, connector, and any surface needed for later service; recheck that
the probe remains flat and at the required nozzle-to-coil height.

### Record USB topology and back up configuration

Stop the camera service, connect Cartographer, and identify it separately from the THR MCU:

```bash
sudo systemctl stop crowsnest.service 2>/dev/null || true
sudo systemctl stop mjpg-streamer-webcam1.service 2>/dev/null || true
cp -a ~/printer_data/config ~/printer_data/config.before-cartographer
lsusb
lsusb -t
ls -l /dev/serial/by-id/
```

Use Cartographer's full `/dev/serial/by-id/...` name. Never use `/dev/ttyACM0`.

### Install the current official plugin

Run as `mks`, not root:

```bash
curl -s -L \
  https://raw.githubusercontent.com/Cartographer3D/cartographer3d-plugin/refs/heads/main/scripts/install.sh | \
  bash -s -- --klipper ~/klipper --klippy-env ~/klippy-env
~/klippy-env/bin/pip show cartographer3d-plugin
```

Add the updater blocks recommended by the current project to `moonraker.conf`:

```ini
[update_manager cartographer_plugin]
type: python
channel: stable
virtualenv: ~/klippy-env
project_name: cartographer3d-plugin
is_system_service: False
managed_services: klipper
info_tags: desc=Cartographer Plugin

[update_manager Cartographer Firmware]
type: git_repo
path: ~/cartographer_firmware
is_system_service: False
origin: https://github.com/Cartographer3D/cartographer_firmware.git
primary_branch: main
```

Restart Moonraker after editing:

```bash
sudo systemctl restart moonraker.service
```

Remove any old legacy `[scanner]` section, old Cartographer plugin files, or old updater block before installing this current plugin.

### Update the Cartographer firmware before calibration

Firmware update is part of this installation, not an optional troubleshooting
step. Stop the C920 stream, then use the current official updater:

```bash
cd ~
if [ ! -d ~/cartographer_firmware/.git ]; then
  git clone https://github.com/Cartographer3D/cartographer_firmware.git
fi
cd ~/cartographer_firmware
git pull --ff-only
./fw_update.sh
```

Select **v4**, **USB**, and **Lite**. Lite reduces USB bandwidth and host work
while retaining the probe functions needed here. The Full build's denser sample
stream is intended for substantially more capable hosts; on the ZNP-K1 it adds
load alongside the THR MCU and webcam and increases the risk of timing trouble.
Never flash v3, CAN, or a mismatched bootloader-offset image. Let the current
updater manifest select the compatible Lite artifact, allow it to finish, then
power-cycle/reconnect the probe and verify its persistent by-id path before
continuing.

### Replace the stock probe configuration

Do not duplicate sections. Remove the generated `[probe]` section that uses `^THR:PB12`, plus its old probe/axis-twist entries in the `SAVE_CONFIG` block at the bottom of `printer.cfg`. Add the following, using the actual serial ID and physically measured X/Y offsets:

```ini
[mcu cartographer]
serial: /dev/serial/by-id/<ACTUAL-CARTOGRAPHER-ID>
restart_method: command

[cartographer]
mcu: cartographer
x_offset: <MEASURED-X-OFFSET>
y_offset: <MEASURED-Y-OFFSET>
verbose: no

[temperature_sensor cartographer]
sensor_type: temperature_mcu
sensor_mcu: cartographer
min_temp: 5
max_temp: 105
```

In `[stepper_z]`, keep:

```ini
endstop_pin: probe:z_virtual_endstop
```

but change:

```ini
homing_retract_dist: 0
```

Do not reuse the stock probe offsets `-24.25, 20.45` for a Cartographer mount.

If using the exact
[Beacon3D Neptune 4 Max mount](https://www.printables.com/model/858227-beacon3d-neptune-4-max-mount),
the mount-specific starting offsets validated on the machine used for this
guide are:

```ini
[cartographer]
x_offset: 0
y_offset: 20.6
```

These values apply to that printed mount and orientation only. Before any Z
home, verify physically at high Z that positive Y places the Cartographer coil
20.6 mm from the nozzle in the direction represented by the configuration.
Re-measure if the part is mirrored, modified, mounted in another orientation,
or has appreciable print/assembly tolerance.

The generated safe-home, bed-mesh, screws, and axis-twist coordinates are tied to the old probe offset. Recalculate them before any Z home:

- desired physical coil/reference centre on the Max: approximately `(215, 215)`;
- nozzle safe-home position: `(215 - x_offset, 215 - y_offset)`;
- for each axis, safe coil minimum is `max(plate_min + margin, nozzle_min + offset)`;
- safe coil maximum is `min(plate_max - margin, nozzle_max + offset)`.

Jog every proposed mesh corner and every `screws_tilt_adjust` point at high Z. Verify the coil remains over steel, the coil is over the intended screw when probing it, and the nozzle remains within travel. Do not copy guessed mount offsets into the image.

For the mount-specific `0,20.6` offset, use this internally consistent safe
home and conservative mesh:

```ini
[safe_z_home]
home_xy_position: 215,194.4
speed: 100
z_hop: 10
z_hop_speed: 5

[bed_mesh]
zero_reference_position: 215,215
speed: 300
horizontal_move_z: 3
mesh_min: 10,21
mesh_max: 397,404
probe_count: 20,20
adaptive_margin: 10
mesh_pps: 0,0
```

`home_xy_position` is a nozzle/toolhead coordinate; the bed-mesh bounds and
zero reference are physical probe/coil coordinates. The new home position puts
the coil at `(215,215)` because `(215,194.4) + (0,20.6) = (215,215)`. The old
stock value `239.75,194.55` compensated for the stock probe's approximately
`-24.25,20.45` offset and must not be retained for this Cartographer mount.

At the proposed mesh corners, Klipper commands these nozzle positions:

| Coil coordinate | Nozzle coordinate |
|---|---|
| `10,21` | `10,0.4` |
| `397,21` | `397,0.4` |
| `397,404` | `397,383.4` |
| `10,404` | `10,383.4` |

They are inside the configured `-2..430` X/Y travel, but still require a
high-Z physical check: the complete coil must remain over steel at each point.
Increase an edge margin if the printed mount or plate placement requires it;
do not enlarge this starting rectangle without measuring it.

Replace the generated stock-probe screw coordinates with these nozzle
coordinates, which put the `0,20.6` Cartographer coil over the same physical
Max screw and fixed-mount positions:

```ini
[screws_tilt_adjust]
screw1: 215,254.4
screw1_name: middle-rear bed mount (shim adjust)
screw2: 215,134.4
screw2_name: middle-front bed mount (shim adjust)
screw3: 32.5,376.9
screw3_name: rear left screw
screw4: 32.5,194.4
screw4_name: center left screw
screw5: 32.5,11.9
screw5_name: front left screw
screw6: 397.5,11.9
screw6_name: front right screw
screw7: 397.5,194.4
screw7_name: center right screw
screw8: 397.5,376.9
screw8_name: rear right screw
horizontal_move_z: 5
speed: 150
screw_thread: CW-M4
```

The complete working configuration supplied during physical commissioning was
cross-checked against these values. It also uses this active axis-twist region:

```ini
[axis_twist_compensation]
calibrate_start_x: 25
calibrate_end_x: 395
calibrate_y: 210
```

Its saved block confirms that both a Cartographer scan model and Touch model
exist and that the probe reports v4 USB Lite firmware. Do not copy its USB
serial, scan coefficients, Touch threshold/Z offset, mesh points, axis-twist
results, PID values, or input-shaper results: all are specific to the physical
machine and must be generated locally.

Clear the old stock-probe axis-twist result before restarting. Back up
`printer.cfg`, then remove only the saved block at the bottom resembling:

```ini
#*# [axis_twist_compensation]
#*# z_compensations = ...
#*# compensation_start_x = ...
#*# compensation_end_x = ...
```

Also remove saved `zy_compensations`, `compensation_start_y`, and
`compensation_end_y` entries if present. Keep the active
`[axis_twist_compensation]` section; the current Cartographer plugin needs that
section in order to register its automatic calibration command. Klipper does
not expose an `AXIS_TWIST_COMPENSATION_CLEAR` G-code. Restart immediately after
removing the saved values so the old compensation is no longer active. Later,
use `CARTOGRAPHER_AXIS_TWIST_COMPENSATION`, not the generated manual
`Axis_Twist_Comp_Tune` macro.

Do not enable Cartographer's optional ADXL during initial probe bring-up. The
generated USB-C configuration already uses the toolhead's LIS2DW for X and the
host-connected ADXL345 for the Max's bed/Y axis. Establish the Cartographer
probe baseline first so an accelerometer configuration error cannot be confused
with a probing problem.

### Later option: use the Cartographer v4 accelerometer for X

Do not perform this optional subsection during the initial installation. Finish
the restart, calibration order, mesh, and Cartographer baseline print below
first; then return here. After that baseline is proven, its onboard
ADXL345 can replace the USB-C toolhead's LIS2DW as the X/toolhead sensor. Keep
the existing host-connected `[adxl345 y]` for the moving bed. Cartographer v4
uses `cartographer:PA0`; the `PA3` examples found in older documentation are for
v3. Selecting the wrong chip-select pin can prevent the Cartographer MCU from
starting correctly.

Back up the working configuration, then remove or comment out the complete
generated `[lis2dw x]` section. Do not remove `[adxl345 y]`. Add this single X
sensor section:

```ini
[adxl345 x]
cs_pin: cartographer:PA0
spi_bus: spi1
# axes_map: <VERIFY_FOR_THE_PRINTED_MOUNT_ORIENTATION>
```

Edit the existing `[resonance_tester]` section rather than creating a second
one. Change only its X sensor and retain the Max's existing Y sensor, limits,
and centre test point:

```ini
[resonance_tester]
accel_chip_x: adxl345 x
accel_chip_y: adxl345 y
max_smoothing: 1
min_freq: 5
max_freq: 90
accel_per_hz: 120
hz_per_sec: 2
probe_points:
    215, 215, 20
```

There must be exactly one active `[resonance_tester]`, one `[adxl345 x]`, and
one `[adxl345 y]`, with no active `[lis2dw x]`. Restart Klipper and validate
both chips before resonance testing:

```text
ACCELEROMETER_QUERY CHIP=x
MEASURE_AXES_NOISE CHIP=x
ACCELEROMETER_QUERY CHIP=y
MEASURE_AXES_NOISE CHIP=y
```

At rest, each query must return plausible acceleration with one mapped axis
dominated by gravity, and the noise command must complete without an MCU/SPI
error. Determine and verify `axes_map` for the actual printed mount orientation;
do not copy the old LIS2DW mapping because it describes a different chip and
PCB orientation. Stop the C920 stream during resonance capture to reduce USB
and host load, then calibrate each moving system separately:

```text
SHAPER_CALIBRATE AXIS=X
SHAPER_CALIBRATE AXIS=Y
SAVE_CONFIG
```

Inspect both generated graphs/recommendations before accepting them. Restore
the saved LIS2DW configuration if the Cartographer ADXL does not enumerate
reliably or produces clipping, excessive noise, or implausible axes.

Restart Klipper now—Moonraker's earlier restart does not load these printer configuration changes—and stop before motion if it reports any error:

```bash
grep -RnsE '^\[(probe|scanner|cartographer|mcu cartographer)\]' \
  ~/printer_data/config --include='*.cfg'
sudo systemctl restart klipper.service
systemctl is-active klipper.service
systemctl status klipper.service --no-pager
tail -n 150 ~/printer_data/logs/klippy.log
```

Inspect the section search: there must be one active `[mcu cartographer]` and `[cartographer]`, and no active legacy `[probe]` or `[scanner]`. In Fluidd/Mainsail, confirm the `cartographer` MCU is connected, run `STATUS`, and confirm `CARTOGRAPHER_QUERY FIELD=all` is recognized before issuing any movement or calibration command. A config error, missing command, duplicate section, or disconnected MCU is a hard stop.

### Calibration order

The required dependency order is:

1. Verify geometry and clear every stock-probe calibration.
2. Create the initial scan model with the manual paper/feeler-gauge procedure.
3. Calibrate Survey Touch only after that scan model has been saved.
4. Mechanically tram the bed.
5. Recheck Touch against the final bed plane.
6. Verify scan and Touch repeatability.
7. Calibrate axis twist using Cartographer's automatic scan-plus-touch command.
8. Create the final heated bed mesh.
9. Validate a first layer and persist the Touch-model Z offset.
10. Only then change accelerometers and calibrate input shaping.

Have emergency stop/power within reach and watch every first descent. Do not
enter undocumented `START` or `MAX` overrides to force Touch calibration past a
failure.

#### 1. Verify the reachable geometry

With the gantry/nozzle physically clear of the plate, home X/Y only and visit
the nozzle coordinates corresponding to each mesh corner and the proposed home
point:

```text
G28 X Y
G90
G1 X10 Y0.4 F6000
G1 X397 Y0.4 F6000
G1 X397 Y383.4 F6000
G1 X10 Y383.4 F6000
G1 X215 Y194.4 F6000
```

At the final point the coil must be at physical `(215,215)`. Stop if the coil
leaves the steel, an axis approaches an unsafe limit, or the configured offset
direction is wrong.

#### 2. Create the initial scan model manually

Do this manual calibration before the initial Touch calibration. On this
installation, attempting the Touch-first shortcut left no scan map for the
following calibration and blocked progress. Clean the nozzle and plate, keep
the nozzle cold, reconfirm that the coil is rigid and 2.6-3.0 mm above the
nozzle, then run:

```text
G28 X Y
G1 X215 Y194.4 F6000
CARTOGRAPHER_SCAN_CALIBRATE METHOD=manual
```

Lower the nozzle carefully using the web UI or small `TESTZ` steps until a
clean sheet of ordinary paper or a 0.1 mm feeler gauge just drags:

```text
TESTZ Z=-0.01
ACCEPT
SAVE_CONFIG
```

Watch every descent and use `ABORT` if motion is unsafe. `SAVE_CONFIG` must
complete and restart Klipper; do not proceed until the saved default scan model
loads without a `no scan map`/`no scan model` error.

#### 3. Calibrate Survey Touch

After Klipper restarts with the manual scan model, clean the nozzle and plate
again and run:

```text
G28 X Y
G1 X215 Y194.4 F6000
CARTOGRAPHER_TOUCH_CALIBRATE
SAVE_CONFIG
```

Touch calibration deliberately brings the nozzle into contact with the plate.
Stop on a false trigger, missed contact, or any model/map error. Do not use the
Touch-first shortcut on this machine even though newer generic Cartographer
documentation describes it.

#### 4. Mechanically tram the bed

After the restart, use the recalculated Cartographer screw coordinates:

```text
BED_LEVEL_SCREWS_TUNE
```

The macro clears the mesh, selects the existing bed target or 60 C, waits,
homes, and runs `SCREWS_TILT_CALCULATE`. Adjust the six normal bed knobs in the
reported direction and clock amount. The middle-front and middle-rear fixed
mounts are references/shim checks, not ordinary adjustment knobs. Repeat until
every adjustable point is approximately `00:05` or better. Stop if the coil is
not centred over any named physical point.

#### 5. Recheck Touch against the final bed plane

Changing the screws changes the bed plane. Clean the nozzle and plate again and
repeat the Touch calibration:

```text
TURN_OFF_HEATERS
G28 X Y
G1 X215 Y194.4 F6000
CARTOGRAPHER_TOUCH_CALIBRATE
SAVE_CONFIG
```

After the restart:

```text
G28 X Y
CARTOGRAPHER_QUERY FIELD=all
```

The previously saved manual scan model remains the bootstrap map used by scan
operations. Do not remove it. If either model fails to load after the restart,
stop rather than attempting bed meshing.

#### 6. Heat soak, verify repeatability, then calibrate axis twist

Axis-twist compensation requires both valid scan and Touch models. Run it
after tramming and before creating the mesh, because its correction changes
the probe values used by bed meshing:

```text
BED_MESH_CLEAR
SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=60
TEMPERATURE_WAIT SENSOR=heater_bed MINIMUM=58 MAXIMUM=65
G4 P600000
G28
CARTOGRAPHER_QUERY FIELD=all
PROBE_ACCURACY SAMPLES=10
CARTOGRAPHER_TOUCH_ACCURACY
CARTOGRAPHER_AXIS_TWIST_COMPENSATION
SAVE_CONFIG
```

Stop on an outlier, unexpectedly large accuracy range, contact away from the
clean intended point, or any command error. The automatic Cartographer command
scans and touches across the axis; it replaces the old stock-probe result. Its
saved `z_compensations` are expected after this step.

#### 7. Generate the final heated mesh

`SAVE_CONFIG` restarted Klipper and disabled the heater, so restore the same
bed temperature. If the bed cooled materially, repeat the heat soak:

```text
BED_MESH_CLEAR
SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=60
TEMPERATURE_WAIT SENSOR=heater_bed MINIMUM=58 MAXIMUM=65
G4 P600000
G28
CARTOGRAPHER_QUERY FIELD=all
BED_MESH_CALIBRATE
SAVE_CONFIG
```

#### 8. Establish and save the final Touch Z offset

Touch calibration creates the contact-detection model; it does not replace a
watched first-layer test and fine adjustment. Ensure the adapted `PRINT_START`
described below uses `CARTOGRAPHER_TOUCH_HOME` after X/Y homing. The last Z-home
mode matters: `Z_OFFSET_APPLY_PROBE` updates the model used for the most recent
home, so do not run a normal scan-mode `G28 Z` between Touch homing and applying
the adjustment.

After the restart, run `BED_MESH_OUTPUT`, then print the saved factory-probe
baseline G-code with the same plate, material, temperatures, and print settings.
Watch the complete first layer. Adjust in 0.01 mm steps from Mainsail/Fluidd or
with these commands:

```text
SET_GCODE_OFFSET Z_ADJUST=+0.01 MOVE=1
SET_GCODE_OFFSET Z_ADJUST=-0.01 MOVE=1
```

Positive moves the nozzle away/up; negative moves it closer/down. Once the
first layer is correct, finish or cancel the test print safely. While the live
adjustment is still present and the last Z home was `CARTOGRAPHER_TOUCH_HOME`,
apply the adjustment to the Touch model and then save that model to disk:

```text
Z_OFFSET_APPLY_PROBE
SAVE_CONFIG
```

Do not hand-edit the saved Cartographer model offset. If the command reports
that there is nothing to do, no live G-code offset was present; repeat the
watched test instead of inventing a value. Survey Touch establishes Z at each
print, while this saved model offset retains the small first-layer bias selected
above.

Do not load or retain the stock-probe mesh or Z offset. Compare first-layer
consistency rather than comparing the two probes' numeric Z-offset values. Save
the Cartographer mesh output and a photograph, and back up the successful
configuration:

```bash
cp -a ~/printer_data/config \
  ~/printer_data/config.cartographer-baseline
```

#### 9. Calibrate resonance last

First complete the baseline print above. Input shaping does not establish bed
geometry, probe calibration, or Z offset, so it must not be used to debug those
steps. Then configure the Cartographer v4 ADXL345 for X and retain the existing
bed-mounted `[adxl345 y]` for Y as described in the earlier optional subsection.
Stop Crowsnest/the C920 stream and validate each sensor before moving:

```bash
sudo systemctl stop crowsnest.service 2>/dev/null || true
sudo systemctl stop mjpg-streamer-webcam1.service 2>/dev/null || true
```

```text
ACCELEROMETER_QUERY CHIP=x
MEASURE_AXES_NOISE CHIP=x
ACCELEROMETER_QUERY CHIP=y
MEASURE_AXES_NOISE CHIP=y
G28
SHAPER_CALIBRATE AXIS=X
SHAPER_CALIBRATE AXIS=Y
SAVE_CONFIG
```

The resonance point is the nozzle coordinate `215,215,20`; it is not adjusted
by the Cartographer probe offset. Inspect the recommendations and generated
graphs before accepting them. Restore the known-good LIS2DW X configuration if
the Cartographer accelerometer is noisy, clips, disconnects, or has an
unverified axis mapping.

The two commissioning checkpoints intentionally follow the same pattern:

| Checkpoint | Factory inductive probe | Cartographer |
|---|---|---|
| Mechanical bed tramming | `BED_LEVEL_SCREWS_TUNE` | `BED_LEVEL_SCREWS_TUNE` after recalculating and verifying screw coordinates |
| Probe/nozzle reference | `PROBE_CALIBRATE`, paper test, `ACCEPT`, `SAVE_CONFIG` | `CARTOGRAPHER_SCAN_CALIBRATE METHOD=manual`, paper/feeler test, `ACCEPT`, `SAVE_CONFIG`; only then `CARTOGRAPHER_TOUCH_CALIBRATE` and `SAVE_CONFIG` |
| Repeatability | `PROBE_ACCURACY SAMPLES=10` | `CARTOGRAPHER_QUERY`, `PROBE_ACCURACY SAMPLES=10`, and `CARTOGRAPHER_TOUCH_ACCURACY` |
| Axis twist | Manual stock-probe calibration | Clear the stock result; run `CARTOGRAPHER_AXIS_TWIST_COMPENSATION` after final tramming/models and before meshing |
| Bed compensation | Fresh full `BED_MESH_CALIBRATE` | Discard stock mesh; create a fresh full `BED_MESH_CALIBRATE` |
| Print validation | Save first-layer test G-code, settings, mesh output, and photograph | Repeat the same G-code/settings and compare first-layer consistency |

Follow step 8 for the watched first-layer adjustment and Touch-model
`Z_OFFSET_APPLY_PROBE`; do not hand-edit the saved model offset.

The generated `PRINT_START` macro must also be adapted. Its current order meshes immediately after `CG28`. For Survey Touch, the important order is:

1. clear offsets/mesh and home X/Y;
2. bring the bed to target and let it settle;
3. clean/soften the nozzle and hold it at no more than about 150 C;
4. run `CARTOGRAPHER_TOUCH_HOME`;
5. run full/adaptive `BED_MESH_CALIBRATE`;
6. heat the nozzle to print temperature and prime.

The full macro belongs in `printer.cfg`, not in the slicer. The physically
working configuration uses this implementation, adapted from Cartographer's
current print-start template and OpenNept4une's existing macros:

```ini
[gcode_macro PRINT_START]
gcode:
    Frame_Light_ON
    Part_Light_ON
    G92 E0
    G90
    SET_GCODE_OFFSET Z=0
    BED_MESH_CLEAR

    {% set BED_TEMP = params.BED_TEMP|default(60)|float %}
    {% set BED_HEAT_SOAK_MINUTES = params.BED_HEAT_SOAK_MINUTES|default(0)|float %}
    {% set BED_MESH = params.BED_MESH|default('adaptive')|string %}
    {% set EXTRUDER_TEMP = params.EXTRUDER_TEMP|default(200)|float %}

    SET_BED_TEMPERATURE TARGET={BED_TEMP}
    BED_TEMPERATURE_WAIT MINIMUM={BED_TEMP-2} MAXIMUM={BED_TEMP+4}
    {% if BED_HEAT_SOAK_MINUTES > 0 %}
      RESPOND MSG="Waiting {BED_HEAT_SOAK_MINUTES} minutes for the bed to settle."
      G4 P{BED_HEAT_SOAK_MINUTES * 60000}
    {% endif %}

    CG28

    SET_HEATER_TEMPERATURE HEATER=extruder TARGET=150
    TEMPERATURE_WAIT SENSOR=extruder MINIMUM=145 MAXIMUM=150
    CARTOGRAPHER_TOUCH_HOME

    {% if BED_MESH == 'full' %}
      BED_MESH_CALIBRATE
    {% elif BED_MESH == 'adaptive' %}
      BED_MESH_CALIBRATE ADAPTIVE=1
    {% elif BED_MESH != 'none' %}
      BED_MESH_PROFILE LOAD={BED_MESH}
    {% endif %}

    Smart_Park
    SET_FILAMENT_SENSOR SENSOR=filament_sensor ENABLE=1
    SET_HEATER_TEMPERATURE HEATER=extruder TARGET={EXTRUDER_TEMP}
    TEMPERATURE_WAIT SENSOR=extruder MINIMUM={EXTRUDER_TEMP-4} MAXIMUM={EXTRUDER_TEMP+10}
    LINE_PURGE
    G92 E0
    G1 Z2.0 F3000
    M117 Printing
```

This assumes the named OpenNept4une/KAMP macros and filament sensor exist. If a
feature was deliberately removed, remove only its corresponding call. Do not
move Touch homing after final nozzle heat: Cartographer requires it at no more
than 150 C.

In OrcaSlicer, put only this macro invocation under **Printer settings >
Machine G-code > Machine start G-code**:

```text
PRINT_START BED_TEMP=[bed_temperature_initial_layer_single] EXTRUDER_TEMP=[nozzle_temperature_initial_layer] BED_MESH=adaptive BED_HEAT_SOAK_MINUTES=0
```

Put `PRINT_END` in **Machine end G-code**. Do not duplicate homing, temperature
waits, meshing, Touch homing, or the purge line in the slicer; `PRINT_START`
owns that sequence. Orca substitutes the bracketed placeholders while slicing.
Inspect the beginning of an exported G-code file once and require numeric
`BED_TEMP` and `EXTRUDER_TEMP` values rather than unresolved brackets before
printing. Increase `BED_HEAT_SOAK_MINUTES` per material/plate when desired, or
use `BED_MESH=full`, `none`, or a saved profile name deliberately.

OpenNept4une option 1 regenerates `printer.cfg` and will restore its stock `[probe]`, mesh, home, and macro sections. Keep the pre-Cartographer backup and reapply/review the Cartographer changes after every regeneration.

### Cartographer firmware selection details

Select **v4**, **USB**, and **Lite** for this ZNP-K1 installation. Lite reduces
the number of samples sent to the Linux host while retaining the same documented
probe features. That is the better starting point for this relatively
low-powered host while it also runs the USB-C THR MCU, Cartographer, C920, and
Moonraker. Full provides the denser host sample stream
and is Cartographer's general recommendation on hosts with ample headroom; its
practical downside here is additional host/transport load. Lite's trade-off is
less raw sample density for unusually detailed diagnostics or aggressive scan
experiments, not a documented loss of scan, Touch, bed-mesh, or ADXL support.

Let the updater and current `firmware_list.csv` choose the compatible artifact;
never flash a v3 or CAN binary to this v4 USB probe. For a normal Katapult
application update, all four labels must match `V4 + USB + Lite + 8KiB offset`.
At the date of this runbook, the manifest lists
`CartographerV4_6.2.0_USB_lite_8kib_offset.bin` with plugin minimum 1.6.0, but
both the version and compatibility floor will change. A combined
`Katapult_plus_...` image is for the explicitly documented DFU bootloader
recovery/deployment path, not a normal application update.

After any later firmware change, restart Klipper, verify the final persistent
USB serial path and reported firmware/plugin compatibility, then redo the
manual scan, Touch, axis-twist, and mesh calibrations in the order above. Stop
the C920 stream during flashing and initial calibration.

## 12. Logitech C920

Use exactly one webcam stack. This runbook recommends Crowsnest v5 because it supports persistent `/dev/v4l/by-id` device names. OpenNept4une's webcam wizard deliberately removes Crowsnest and installs `mjpg-streamer`, so never run both.

The webcam is not configured in `printer.cfg`; that file configures Klipper
hardware and macros. Configure the capture service on Linux, then configure its
stream/snapshot URLs separately in the Mainsail or Fluidd camera UI as described
below.

### Identify the capture node

Connect the C920 only after all MCU work and initial Cartographer calibration are complete:

```bash
sudo apt-get install v4l-utils -y
lsusb
lsusb -t
v4l2-ctl --list-devices
ls -l /dev/v4l/by-id/ /dev/v4l/by-path/
```

Inspect each likely C920 node:

```bash
for camera_node in /dev/v4l/by-id/*C920*; do
  echo "$camera_node"
  v4l2-ctl -d "$camera_node" --list-formats-ext
done
```

Choose the stable symlink ending in `video-index0`, or whichever candidate actually lists MJPG capture modes. Use a `/dev/v4l/by-path/...-video-index0` link if the camera has no unique by-id link. Never configure `/dev/video0` directly.

### Install and configure Crowsnest

Disable the image's existing `mjpg-streamer` service first:

```bash
sudo systemctl disable --now mjpg-streamer-webcam1.service 2>/dev/null || true
sudo apt-get update
sudo apt-get install git -y
cd ~
git clone --branch v5 --single-branch \
  https://github.com/mainsail-crew/crowsnest.git
cd ~/crowsnest
sudo make install
```

The installer should add this Moonraker updater; verify it rather than creating a duplicate section:

```ini
[update_manager crowsnest]
type: git_repo
path: ~/crowsnest
origin: https://github.com/mainsail-crew/crowsnest.git
primary_branch: v5
managed_services: crowsnest
system_dependencies: system-dependencies.json
virtualenv: ~/crowsnest-env
requirements: requirements.txt
```

Use this conservative starting point in `~/printer_data/config/crowsnest.conf`:

```ini
[crowsnest]
log_level: verbose
rollover_on_start: false
no_proxy: false

[cam c920]
mode: ustreamer
port: 8080
device: <FULL-PERSISTENT-C920-PATH-SELECTED-ABOVE>
resolution: 1280x720
max_fps: 15
```

Do not add a legacy `log_path` key to the v5 config. Start with MJPEG-capable 720p15. Increase to 30 fps or 1080p only after long meshes and prints remain free of USB resets. Avoid YUYV on a shared USB bus because it is uncompressed and consumes substantially more bandwidth.

Verify:

```bash
sudo systemctl restart crowsnest.service
systemctl status crowsnest.service --no-pager
journalctl -u crowsnest.service -b --no-pager -n 100
curl -fsS -o /tmp/c920.jpg \
  'http://127.0.0.1:8080/?action=snapshot'
file /tmp/c920.jpg
```

The usual reverse-proxy URLs are:

```text
/webcam/?action=stream
/webcam/?action=snapshot
```

The Mainsail/Fluidd camera entry may not resolve those relative paths on this
image. In the web UI, open **Settings > Camera (or Cameras) > USB** and enter
absolute URLs using the printer's actual LAN address:

```text
Stream URL:   http://<printer-ip>/webcam/?action=stream
Snapshot URL: http://<printer-ip>/webcam/?action=snapshot
```

For example, if the printer is `192.168.1.123`, enter:

```text
http://192.168.1.123/webcam/?action=stream
http://192.168.1.123/webcam/?action=snapshot
```

Enter ordinary `http://` URLs; the backslashes sometimes shown when these
values are pasted through Markdown are escaping only and are not part of the
setting. A resolvable `znp-k1.local` may be used instead of the IP, but the IP
is easier to diagnose. Save the camera entry and require both live view and a
fresh snapshot to work from the browser used for printing.

After validation, change Crowsnest's log level to `quiet` to reduce eMMC writes.

If Cartographer freezes, reports `timer too close`, or an MCU disconnects, stop Crowsnest first and inspect:

```bash
journalctl -k -b --no-pager | grep -Ei 'usb|reset|disconnect|over.?current'
lsusb -t
```

A quality externally powered hub can solve power problems but cannot create more USB bandwidth. If possible, keep latency-sensitive Cartographer and the high-bandwidth C920 on different host root branches.

## 13. Keep the stock touchscreen integration disabled

Do **not** install or enable `display_connector` on this ZNP-K1-2.3 USB-C
configuration. Physical testing found that the display workload can cause I/O
timing problems with the main MCU. Do not run
`OpenNept4une.sh install_screen_service`, do not flash touchscreen firmware, and
perform all printer control and calibration through Fluidd or Mainsail.

If the connector was already installed during an earlier version of this
guide, disable its services before printing:

```bash
sudo systemctl disable --now display.service affinity.service
systemctl is-active display.service affinity.service
systemctl is-enabled display.service affinity.service
```

The expected results are `inactive` and `disabled` (or `not-found` if the units
were never installed). A stopped service that remains enabled is not sufficient
because it will return at the next boot. The unused checkout may remain on disk;
do not delete it as part of commissioning. Remove any active `[update_manager
display]` block from `moonraker.conf` and restart Moonraker so its UI does not
offer an unsupported display update:

```bash
sudo systemctl restart moonraker.service
```

## 14. Make the fully commissioned image afterward

Section 3 provides a useful bootstrap image without rebuilding Armbian: it can contain the 2.3 DTB selection, GPIO82 service, this fork's checkout, and Wi-Fi profile before first boot. It cannot safely be a fully commissioned image yet because:

- the THR, Cartographer, and C920 stable IDs are only known after enumeration;
- Cartographer offsets and safe mesh bounds are mount-specific;
- probe calibration and saved models are machine-specific;
- offline package upgrades add kernel and service drift before the hardware baseline is known.

The best reusable image is therefore a golden image made **after** the printer works:

1. Record all Git commits, package/plugin versions, MCU versions, and serial IDs.
2. Back up `~/printer_data/config` separately.
3. Shut down cleanly and remove the eMMC.
4. Make and verify another raw image using the backup procedure in section 1.
5. Optionally run PiShrink with `-s`, then compress with `xz -T0`.
6. Store its checksum and a note that it contains Wi-Fi credentials and hardware serial IDs.

Do not run an indiscriminate `apt full-upgrade` before creating the first working checkpoint. Apply OS, Klipper, fork, and Cartographer updates deliberately and one category at a time, with an eMMC/config backup first. Do not install display updates on this hardware.

The golden image also contains the machine ID, SSH host keys, calibration data, and print history. Keep it private and normally restore it only to this printer. Never run `img-config/dev-image-cleanup.sh` on the commissioned machine; that script is for preparing public release images and deliberately removes identity, network, config, log, and history data.

## Rollback and recovery

### Image does not boot after the DTB swap

Mount the eMMC boot and root partitions as in section 3. From this fork's
checkout root, use the recorded rollback state:

```bash
sudo ./img-config/board-hardware-setup.sh rollback \
  --root /mnt/n4root \
  --boot /mnt/n4boot
sudo ./img-config/board-hardware-setup.sh status \
  --root /mnt/n4root \
  --boot /mnt/n4boot
sync
sudo umount /mnt/n4root
sudo umount /mnt/n4boot
```

The rollback refuses to overwrite a DTB/service file that was manually changed after installation unless `--force` is explicitly supplied. Inspect any such conflict instead of forcing it blindly. If the state directory is unavailable, write back the verified raw stock image.

### Wi-Fi does not work

Use Ethernet or front serial, then run:

```bash
sudo nmtui
nmcli connection show
journalctl -u NetworkManager -b --no-pager
```

### USB-C toolhead is absent

```bash
systemctl status opennept4une-toolhead-power.service --no-pager
sudo /usr/local/sbin/opennept4une-toolhead-power status
lsusb
ls -l /dev/serial/by-id/
journalctl -k -b --no-pager | grep -Ei 'usb|gpio|over.?current|reset|disconnect'
```

Do not generate a ribbon-toolhead config as a workaround on a physical USB-C
machine.

If `usb-MKS_DRIVER_BOOT_*` appears but the Klipper application does not, the
custom bootloader is still alive. Keep power stable, confirm the pinned Klipper
commit and archived build, then rerun the guarded updater and choose **USB-C
Toolhead Recovery**. It selects one managed toolhead archive, constrains and
verifies its checksum manifest, target metadata, config, size, and source
commit, then digest-binds and flashes a private snapshot of its exact
`klipper.bin` through the same service, bootloader-identity, VID:PID, and
confirmation gates. It accepts an already-present bootloader and does not need
the previous application serial device:

```bash
cat ~/printer_data/config/Firmware/klipper-build-source.commit
find ~/printer_data/config/Firmware/builds -maxdepth 3 -type f -print
~/OpenNept4une/OpenNept4une.sh update_mcu_rpi_fw
```

The selected archive's Klipper commit must match both the current Klipper
checkout and `klipper-build-source.commit`. If it does not, stop and restore
the recorded coordinated source/MCU set; do not weaken that compatibility gate.

Do not bypass the identity/VID:PID/service guards with a guessed tty. If neither
the application nor bootloader enumerates after the power-service, cable, and
kernel checks, stop. Restoring eMMC cannot restore that MCU; recovery then
requires a verified physical-programming procedure, an exact vendor package,
or replacement hardware. No safe SWD procedure for this toolhead is currently
documented.

### Main MCU application recovery

The main-MCU OpenNept4une archive can be restaged to a FAT32 microSD after its
checksum manifest is verified. Copy its `klipper.bin` twice as `X_4.bin` and
`elegoo_k1.bin`, then follow section 9's powered-off microSD procedure. This
restores that archived OpenNept4une build; it does not restore Elegoo firmware.
Replace the all-caps directory component below with the exact archive printed
by the updater:

```bash
main_archive=/home/mks/printer_data/config/Firmware/builds/REPLACE_WITH_EXACT_MAIN_MCU_ARCHIVE
test -d "$main_archive" || { echo 'Exact main-MCU archive not found; stop.' >&2; exit 1; }
grep -Fx 'target=main-mcu' "$main_archive/build-metadata.txt" || exit 1
(cd "$main_archive" && sha256sum --check --strict SHA256SUMS) || exit 1
install -m 0644 "$main_archive/klipper.bin" \
  ~/printer_data/config/Firmware/X_4.bin
install -m 0644 "$main_archive/klipper.bin" \
  ~/printer_data/config/Firmware/elegoo_k1.bin
```

Ensure the Klipper host and every other MCU use a compatible source revision;
the archive records the exact commit for this build.

If the main MCU needs factory firmware, obtain a binary explicitly matching the
Neptune 4 Max Type-C / `ZNP-K1-2.3` hardware. Do not substitute old generic
Neptune 4 assets, and do not use the v1.0-only UART alternative script on this
board.

### Cartographer rollback

Restore `~/printer_data/config.before-cartographer`, physically reinstall the factory probe, and remove the current plugin with its official installer:

```bash
curl -s -L \
  https://raw.githubusercontent.com/Cartographer3D/cartographer3d-plugin/refs/heads/main/scripts/install.sh | \
  bash -s -- --klipper ~/klipper --klippy-env ~/klippy-env --uninstall
```

Remove its Moonraker updater blocks and restart Klipper/Moonraker.

### Crowsnest rollback

```bash
cd ~/crowsnest
make uninstall
```

Remove its Moonraker block and reboot. Only then use OpenNept4une's mutually exclusive `mjpg-streamer` webcam wizard if desired.

### Full factory recovery

In addition to the raw original backup, Elegoo publishes a Type-C-specific Plus/Max image:

```text
KLP_ZNP_N4E_K1_V2.3_20250909.rar
size: 1043328664 bytes
SHA-256: d157fe7f2d157d28cc6a3710a890daf1cd9cdf7de28bae27e38f36376f015353
```

That checksum was calculated from the official recovery asset inspected for this runbook; verify the release page has not replaced the asset before relying on it.

Use the [official Elegoo Neptune 4 release page](https://github.com/elegooofficial/Neptune4/releases/tag/Neptune4Plus%264Max%28TypeC%29_Image), not the old generic `ElegooSD-restore.bin`, whose 2.3/USB-C compatibility is unverified. Elegoo describes that release as a Type-C **system image** followed by an OTA update; do not infer that the archive itself contains independently flashable main-MCU, toolhead, or screen binaries without inspecting and validating them.

Restoring eMMC alone does not roll back Klipper firmware already flashed into the main MCU or toolhead MCU. A complete factory rollback may require the matching Elegoo MCU and touchscreen firmware as well. Preserve the original machine and screen versions before starting.

## Final go-live checklist

- [ ] Original raw eMMC backup and checksum verified off-device
- [ ] `printer_data/config` (and optional Moonraker database) archive verified off-device
- [ ] Exact board label photographed as `ZNP-K1-2.3`
- [ ] Stock touchscreen firmware version recorded
- [ ] Exact factory MCU/toolhead recovery files retained, or the lack of an exact factory rollback was explicitly accepted before flashing
- [ ] v0.1.7 image hash and destination capacity checked
- [ ] Board installer selected the 2.3 DTB and its hash was verified after boot
- [ ] A private, valid `/etc/machine-id` exists and was not copied into logs
- [ ] RK805 has no `nobody cared`/disabled IRQ and its interrupt count is not storming
- [ ] `power_monitor.service` remains active without a false-edge `EBUSY` failure
- [ ] Power monitors remain quiet with both-edge mode and 20 ms debounce
- [ ] Wi-Fi works, with Ethernet/serial fallback known
- [ ] GPIO82 service is active and passed repeated cold boots
- [ ] Klipper's effective systemd properties report `Nice=-18` and `IOSchedulingPriority=1`
- [ ] This fork's working tree/commit was recorded and update origin points to `dalgibbard/OpenNept4une`
- [ ] Safety-patched bundled `n4flash.c` hash is `fb446842...20df70` and compiled cleanly on the printer
- [ ] Toolhead application and bootloader by-id/udev identities were captured
- [ ] Versioned main-MCU and toolhead OpenNept4une build archives and checksum manifests were copied off-device
- [ ] Toolhead was flashed through its unique `usb-MKS_DRIVER_BOOT_*` path after VID/PID validation
- [ ] Main MCU reports the coordinated Klipper source version; its successful update method was recorded
- [ ] Main, THR, and virtual MCU protocol versions match
- [ ] `N4Max-v2.3-tusbc` config generated and backed up
- [ ] Temperatures, endstops, stock probe, runout sensor, fans, lights, and motor directions checked cold
- [ ] Factory-probe baseline print completed
- [ ] Cartographer mount/offsets/envelope calibrated on this machine
- [ ] Cartographer v4 reports current USB Lite firmware before calibration
- [ ] Manual scan model was saved before Survey Touch calibration
- [ ] C920 uses a persistent V4L path at a conservative bandwidth
- [ ] `display.service` and `affinity.service` are absent or both disabled/inactive; `display_connector` was not installed
- [ ] Touchscreen firmware was not changed during initial bring-up
- [ ] A new working golden eMMC image was made after commissioning
