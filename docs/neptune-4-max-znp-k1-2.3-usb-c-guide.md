# OpenNept4une bring-up: Neptune 4 Max, ZNP-K1-2.3, USB-C toolhead

Last verified: 2026-08-24

This runbook covers this exact target:

- Elegoo Neptune 4 Max
- mainboard `ZNP-K1-2.3`
- factory USB-C toolhead with a separate toolhead MCU
- Cartographer v4 over USB
- Logitech C920 over USB
- the stock touchscreen through `display_connector`

## Read this first

This combination is still **experimental**. The current OpenNept4une wiki explicitly lists `ZNP-K1-2.3` boards and USB printheads as unsupported. The upstream and reference-fork `dev` branches are not turnkey for this hardware. This fork adds a guarded end-to-end software path, but it still needs validation on this physical printer before it should be treated as production support.

The safe conclusion from comparing and then integrating the repositories is:

1. Do **not** build a complete Armbian image for the first attempt.
2. Start from the complete OpenNept4une v0.1.7 Plus/Max image.
3. Use this fork on `dev`; it contains the missing board integration and flashing safeguards.
4. Run its board-hardware installer against the mounted image before first boot. It selects the board-2.3 DTB and installs persistent GPIO82 toolhead power with rollback state.
5. Use its guarded, bundled `n4flash` flow for the USB-C toolhead; do not target a `/dev/ttyACM*` node manually.
6. Bring up the stock probe first. Add Cartographer, camera, and display one at a time only after the printer is stable.

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
8. Flash the main MCU by microSD, then update the virtual Linux MCU separately.
9. Generate the Max/2.3/USB-C configuration and perform cold pin/sensor checks.
10. Establish a working baseline using the factory inductive probe.
11. Add and calibrate Cartographer.
12. Add the C920.
13. Enable `display_connector` without changing the screen firmware.
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
| USB-C toolhead MCU | No | Not through the known MKS USB bootloader; its protocol has no flash-read command | Matching factory binary, or the exact archived Klipper application while its bootloader still enumerates |
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
return firmware bytes, so it cannot dump the factory toolhead application.
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
c966b74ced89e007972ab2af45c33bbcb1c12cc27d515eda8b8a48713926e0d8
```

The expected selection is:

```text
fdtfile=rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb
```

The included 2.3 DTS differs from the 2.0 DTS mainly in Ethernet timing and video/IOMMU status. Its USB and UART nodes are unchanged, so the board-specific DTB and GPIO82 toolhead-power service are both required.

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

The selected path must be `rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb`, and its hash must still be `c966b74c...e0d8`. Verify both Ethernet and Wi-Fi if possible; the board-2.3 DTB changes Ethernet timing.

If Wi-Fi did not associate, use Ethernet and run `sudo nmtui`. The hardware serial fallback documented by OpenNept4une uses the front I/O USB-C serial connection at 1,500,000 baud, with 115200 as a fallback if required by the adapter/firmware.

Stop here if Linux does not boot consistently, the root filesystem reports errors, or both network paths fail. Restore the raw eMMC backup before attempting any MCU update.

## 5. Verify USB-C toolhead power on every boot

The USB-C toolhead rail is controlled by RK3328 GPIO2_C2, exposed by this image through legacy sysfs as GPIO82. The offline board installer should already have installed the helper, service, and Klipper dependency. Verify them:

```bash
grep '^fdtfile=' /boot/armbianEnv.txt
systemctl status opennept4une-toolhead-power.service --no-pager
systemctl cat klipper.service
sudo /usr/local/sbin/opennept4une-toolhead-power status
lsusb
ls -l /dev/serial/by-id/ 2>/dev/null
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

Do ten cold-boot checks before considering this hardware path validated:

```bash
systemctl is-active opennept4une-toolhead-power.service
sudo /usr/local/sbin/opennept4une-toolhead-power status
lsusb
ls -l /dev/serial/by-id/ 2>/dev/null
```

Record any failure and stop rather than guessing another GPIO. The sysfs GPIO API is deprecated on newer Linux systems, but it is the interface exposed by the current v0.1.7 image.

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
The MKS USB bootloader cannot return application bytes. If returning to the
exact factory toolhead application is a hard requirement and you do not have a
matching Elegoo binary, stop here. Do not assume the Type-C eMMC recovery image
contains separate MCU firmware until its contents and target have been
verified.

It is acceptable if the pre-Klipper application does not match `usb-Klipper_stm32f103xe_*`; that exact production identity is the current TODO. The updater can use the persisted board selection to enter the bootloader through GPIO82.

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

1. builds the STM32F103xE-layout firmware with the tested Cortex-M4 override for the physical GD32F303-compatible part;
2. rejects an empty image or one larger than the 96 KiB application region;
3. archives the binary, expanded `.config`, target metadata, pinned Klipper commit, size, and checksums under `~/printer_data/config/Firmware/builds/` and refuses to write if archival fails;
4. compiles the bundled pinned `n4flash` source locally;
5. requires the literal confirmation `FLASH`;
6. stops Klipper only after establishing its service state and restores it on exit;
7. cycles GPIO82 through the installed helper;
8. requires exactly one `/dev/serial/by-id/usb-MKS_DRIVER_BOOT_*` path;
9. confirms that path has VID/PID `1d50:018a` through udev;
10. saves the bootloader identity before writing, invokes `n4flash` with that persistent path, and then saves/verifies the final Klipper application identity plus `MCU_ID.cfg` before reporting success;
11. pins the Klipper source SHA so the separate main, toolhead, and virtual-MCU runs cannot silently mix protocol revisions.

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

The updater writes `[mcu THR]` to `MCU_ID.cfg` only when exactly one final application by-id path exists. If the transfer is interrupted, do not proceed to configuration: keep power stable, re-enter the `usb-MKS_DRIVER_BOOT_*` bootloader, and rerun the same guarded updater. The bootloader should remain available even though the application region was erased.

Copy the newly reported build-archive directory off the printer and verify its
checksum manifest there. A later `make clean` or another MCU build overwrites
`~/klipper/out/klipper.bin`; the versioned archive is the durable recovery
copy.

## 8. Update the main MCU and virtual Linux MCU separately

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

Download both through Fluidd, or copy them from the printer. Put both in the root of a small FAT32-formatted microSD card. Then:

1. Shut the printer down cleanly.
2. Remove mains power.
3. Insert the card into the hidden mainboard MCU slot, not the Linux/eMMC reader.
4. Restore power and allow the bootloader time to flash.
5. Shut down, remove the card, and boot normally.

Do not have the C920 or Cartographer connected during this operation.

### Virtual Linux MCU

Run the updater again and choose only **Virtual RPi**:

```bash
~/OpenNept4une/OpenNept4une.sh update_mcu_rpi_fw
```

Allow its reboot. The patched menu offers only one target per run.

After reboot, check Klipper's log and web UI. The main MCU, THR MCU, and Klipper host must report mutually compatible protocol versions before continuing.

## 9. Generate Max/2.3/USB-C configuration

First back up the fresh image's current config:

```bash
cp -a ~/printer_data/config ~/printer_data/config.before-n4max-v2.3-usbc
```

Generate the exact machine selection. The final toolhead by-id path must already exist:

```bash
~/OpenNept4une/OpenNept4une.sh \
  --yes \
  --printer_model n4max \
  --pcb_version 2.3 \
  --toolhead usb-c \
  install_printer_cfg </dev/null
```

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

On a fresh install, install the other OpenNept4une configuration set from menu option 2 and choose **All** within that **configuration installer**. This is unrelated to the removed MCU `All` action. It overwrites configuration files, so do it before Cartographer customization.

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

## 10. Cold commissioning and factory-probe baseline

With nozzle and bed cold, restart Klipper and inspect the logs:

```bash
sudo systemctl restart klipper.service
systemctl status klipper.service --no-pager
journalctl -u klipper.service -b --no-pager -n 150
```

In the Klipper console:

1. Confirm hotend, bed, host, and THR temperatures are plausible room-temperature values. A value near zero, several hundred degrees, or a rapidly changing idle value is a stop condition.
2. Run `QUERY_ENDSTOPS`; manually actuate each physical endstop and verify only the expected axis changes.
3. Run `QUERY_PROBE`; bring metal to the factory probe and verify its state changes.
4. Run `QUERY_FILAMENT_SENSOR SENSOR=filament_sensor`; insert/remove filament and compare behavior with the stock configuration. Keep the sensor disabled if it is wrong.
5. Use `STEPPER_BUZZ STEPPER=stepper_x`, then Y and Z, only with safe physical clearance. Confirm each motor, direction, and one-millimetre return.
6. Test each fan at low duty and identify it physically.
7. Briefly request a low hotend target, such as 40 C, while watching the displayed temperature and keeping a hand on the emergency power switch. Cancel immediately after confirming the correct sensor rises. Repeat separately for the bed.

Do not home Z until the factory probe is proven. Do not install Cartographer until the printer can home carefully, mesh with the factory probe, heat correctly, and complete a conservative first-layer test.

That known-good checkpoint is essential: it separates base board/toolhead problems from Cartographer problems.

## 11. Cartographer v4 over USB

### Wiring and mechanical rules

- Keep the v4 in its factory USB mode initially; v4 normally ships with USB firmware.
- Supply **5 V only**. Applying 24 V destroys the probe.
- Use Cartographer's supplied USB harness back to the host SBC or a good powered hub. The USB-C toolhead MCU is not a generic Cartographer USB port.
- Mount the coil rigidly, flat, and approximately 2.6-3.0 mm above the nozzle tip for Survey Touch.
- Keep metal outside the documented keep-out area.
- The supplied USB lead is not normally cable-chain rated; strain-relieve it along an umbilical/Bowden route.
- Prefer Cartographer direct to the host and the C920 on a powered hub if the physical ports allow it.

Official references:

- [Cartographer Klipper setup](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/klipper-setup)
- [Wiring diagrams](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/probe-installation/wiring-diagrams)
- [Scan calibration](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/scan-calibration)
- [Touch calibration](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/touch-calibration)
- [Print-start template](https://docs.cartographer3d.com/cartographer-probe/installation-and-setup/software-configuration/print_start-template)

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

The generated safe-home, bed-mesh, screws, and axis-twist coordinates are tied to the old probe offset. Recalculate them before any Z home:

- desired physical coil/reference centre on the Max: approximately `(215, 215)`;
- nozzle safe-home position: `(215 - x_offset, 215 - y_offset)`;
- for each axis, safe coil minimum is `max(plate_min + margin, nozzle_min + offset)`;
- safe coil maximum is `min(plate_max - margin, nozzle_max + offset)`.

Jog every proposed mesh corner and every `screws_tilt_adjust` point at high Z. Verify the coil remains over steel, the coil is over the intended screw when probing it, and the nozzle remains within travel. Do not copy guessed mount offsets into the image.

A starting bed-mesh shape is:

```ini
[bed_mesh]
zero_reference_position: 215,215
speed: 300
horizontal_move_z: 3
mesh_min: <VERIFIED-COIL-X-MIN>,<VERIFIED-COIL-Y-MIN>
mesh_max: <VERIFIED-COIL-X-MAX>,<VERIFIED-COIL-Y-MAX>
probe_count: 20,20
adaptive_margin: 10
mesh_pps: 0,0
```

Disable or clear the old `[axis_twist_compensation]` data initially. Recalibrate it with the current Cartographer command only after scan/touch calibration is complete.

Do not enable Cartographer's optional ADXL at first. The fork already configures the USB-C toolhead LIS2DW for X and the host ADXL345 for the Max's bed/Y axis.

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

Have emergency stop/power within reach and watch every first descent:

1. Verify X/Y travel, signs of measured offsets, safe-home point, and every mesh corner at high Z.
2. `G28 X Y`
3. `CARTOGRAPHER_SCAN_CALIBRATE`
4. Use `TESTZ Z=-0.01` cautiously to approach paper drag while retaining a visible gap, then `ACCEPT` and `SAVE_CONFIG`.
5. Mechanically tram the bed and repeat scan calibration if the bed or gantry changed.
6. Clean the plate and nozzle; confirm the coil remains 2.6-3.0 mm above the nozzle.
7. `G28 X Y`
8. `CARTOGRAPHER_TOUCH_CALIBRATE`
9. `SAVE_CONFIG`
10. Verify `CARTOGRAPHER_QUERY FIELD=all`, `PROBE_ACCURACY`, and `CARTOGRAPHER_TOUCH_ACCURACY` using the current plugin's syntax.
11. Run a full `BED_MESH_CALIBRATE` only after those checks pass.

For the first-layer adjustment, use `CARTOGRAPHER_TOUCH_HOME`, babystep carefully, then `Z_OFFSET_APPLY_PROBE` and `SAVE_CONFIG`. Do not hand-edit the saved model's Z offset.

The generated `PRINT_START` macro must also be adapted. Its current order meshes immediately after `CG28`. For Survey Touch, the important order is:

1. clear offsets/mesh and home X/Y;
2. bring the bed to target and let it settle;
3. clean/soften the nozzle and hold it at no more than about 150 C;
4. run `CARTOGRAPHER_TOUCH_HOME`;
5. run full/adaptive `BED_MESH_CALIBRATE`;
6. heat the nozzle to print temperature and prime.

Use Cartographer's current print-start template when editing the macro rather than copying an old macro from a forum post.

OpenNept4une option 1 regenerates `printer.cfg` and will restore its stock `[probe]`, mesh, home, and macro sections. Keep the pre-Cartographer backup and reapply/review the Cartographer changes after every regeneration.

### Cartographer firmware

Do not flash the probe just because it is new. First try its factory USB firmware with the current plugin. If the official updater reports that an update is required:

```bash
cd ~
git clone https://github.com/Cartographer3D/cartographer_firmware.git
cd ~/cartographer_firmware
./fw_update.sh
```

Select **v4**, **USB**, and normally **Full**. Use Lite only for documented low-power/timing/extra-MCU issues. Let the updater and current `firmware_list.csv` choose a compatible artifact; never flash a v3 binary to v4. At the date of this runbook, the manifest lists v4 USB 6.2.0 with plugin minimum 1.6.0, but that will change.

## 12. Logitech C920

Use exactly one webcam stack. This runbook recommends Crowsnest v5 because it supports persistent `/dev/v4l/by-id` device names. OpenNept4une's webcam wizard deliberately removes Crowsnest and installs `mjpg-streamer`, so never run both.

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

After validation, change Crowsnest's log level to `quiet` to reduce eMMC writes.

If Cartographer freezes, reports `timer too close`, or an MCU disconnects, stop Crowsnest first and inspect:

```bash
journalctl -k -b --no-pager | grep -Ei 'usb|reset|disconnect|over.?current'
lsusb -t
```

A quality externally powered hub can solve power problems but cannot create more USB bandwidth. If possible, keep latency-sensitive Cartographer and the high-bandwidth C920 on different host root branches.

## 13. Stock touchscreen through `display_connector`

`display_connector/dev` supports the Neptune 4 Max and uses `/dev/ttyS1`; the main MCU uses `/dev/ttyS0`, so the USB-C THR MCU and Cartographer do not create a serial-name collision.

Support is conditional on the actual screen firmware and board UART routing. The project's current README explicitly documents the stock TJC4827X243_011 display with firmware 1.2.11 and 1.2.12. Current dev code recognizes additional versions, but USB-C machines have shipped with other versions. Treat any version not explicitly confirmed by the current project as unverified.

Do **not** flash touchscreen firmware during initial bring-up. OpenNept4une labels that updater Alpha/Risky. The connector service can be installed without changing the screen firmware.

### UART gate

Before stopping the coupled release services, preserve both units, the affinity helper, and their known-good state. The current connector installer can overwrite all three files:

```bash
if [ -e ~/display-affinity-before-connector ]; then
  echo 'Display/affinity backup already exists; preserve it and choose a new path.' >&2
  exit 1
fi
for service_file in \
  /etc/systemd/system/display.service \
  /etc/systemd/system/affinity.service \
  /usr/local/sbin/affinity-setup.sh; do
  if [ ! -f "$service_file" ]; then
    echo "Required release file is absent: $service_file" >&2
    exit 1
  fi
done
mkdir ~/display-affinity-before-connector
systemctl cat display.service \
  > ~/display-affinity-before-connector/systemctl-cat-display.txt || exit 1
systemctl cat affinity.service \
  > ~/display-affinity-before-connector/systemctl-cat-affinity.txt || exit 1
systemctl is-enabled display.service \
  > ~/display-affinity-before-connector/display-was-enabled.txt || true
systemctl is-active display.service \
  > ~/display-affinity-before-connector/display-was-active.txt || true
systemctl is-enabled affinity.service \
  > ~/display-affinity-before-connector/affinity-was-enabled.txt || true
systemctl is-active affinity.service \
  > ~/display-affinity-before-connector/affinity-was-active.txt || true
sudo cp -a /etc/systemd/system/display.service \
  /etc/systemd/system/affinity.service \
  /usr/local/sbin/affinity-setup.sh \
  ~/display-affinity-before-connector/
sudo chown -R "$(id -u):$(id -g)" ~/display-affinity-before-connector
```

Now stop both coupled units temporarily and inspect the UART:

```bash
sudo systemctl stop display.service affinity.service
test "$(systemctl is-active display.service)" = inactive || exit 1
test "$(systemctl is-active affinity.service)" = inactive || exit 1
cat /boot/.OpenNept4une.txt
test -c /dev/ttyS1 || {
  echo '/dev/ttyS1 is absent; do not install the connector.' >&2
  exit 1
}
cat /proc/cmdline
if grep -qw 'console=ttyS1' /proc/cmdline; then
  echo 'ttyS1 is a kernel console; do not install the connector.' >&2
  exit 1
fi
if systemctl is-active --quiet serial-getty@ttyS1.service; then
  echo 'ttyS1 is owned by a serial getty; do not install the connector.' >&2
  exit 1
fi
if sudo fuser -v /dev/ttyS1; then
  echo 'ttyS1 is already owned by a process; do not install the connector.' >&2
  exit 1
fi
```

Required result: `/dev/ttyS1` exists, is not a kernel console/getty, and is not owned by another user process. The v2.0 and included v2.3 DTS files have identical UART nodes, which is encouraging but not a substitute for this hardware check.

If any gate fails or you decide not to install, restore the untouched release pair with `sudo systemctl start display.service affinity.service`.

### Install the matching `dev` connector

This fork now initializes the direct `install_screen_service` command's branch correctly, preserves any existing checkout, and refuses a branch mismatch instead of deleting local display work. With the coupled release service files safely captured above, inspect the existing connector checkout next:

```bash
git -C ~/display_connector status --short --branch 2>/dev/null || true
```

If it is already a clean `dev` checkout, this is sufficient:

```bash
~/OpenNept4une/OpenNept4une.sh install_screen_service
```

Otherwise, preserve it and install the matching branch explicitly:

```bash
cd ~
if [ -d ~/display_connector ]; then
  if [ -e ~/display_connector.v0.1.7 ]; then
    echo 'Display backup path already exists; stop and choose a new name.' >&2
    exit 1
  fi
  mv ~/display_connector ~/display_connector.v0.1.7
fi
git clone --branch dev \
  https://github.com/OpenNeptune3D/display_connector.git
cd ~/display_connector
bash ./display-service-installer.sh
```

The installer enables `display.service` and `affinity.service`, rebuilds its Python environment, changes CPU-governor behavior, and restarts Moonraker. Review those side effects when diagnosing later performance issues.

Use an explicit `~/printer_data/config/display_connector.cfg`:

```ini
[general]
printer_model = N4Max
serial_port = /dev/ttyS1
display_type = elegoo
```

Ensure Moonraker tracks the connector's `dev` branch:

```ini
[update_manager display]
type: git_repo
primary_branch: dev
path: /home/mks/display_connector
virtualenv: /home/mks/display_connector/venv
requirements: requirements.txt
origin: https://github.com/OpenNeptune3D/display_connector.git
managed_services: display
```

Verify:

```bash
sudo systemctl restart display.service
systemctl status display.service --no-pager
journalctl -u display.service -b --no-pager -n 100
tail -n 100 ~/printer_data/logs/display_connector.log
```

Current `display_connector/dev` recognizes Cartographer mesh progress, but its touchscreen Z-probe calibration page calls a macro that is not supplied by the current Cartographer plugin/config. Do all Cartographer scan, touch, and Z-offset calibration in Fluidd/Mainsail. Treat the touchscreen Z-offset page as unsupported.

To roll back the connector without losing the release's latency mitigation, restore the saved connector checkout when one exists, then restore the coupled display/affinity implementation and state:

```bash
sudo systemctl disable --now display.service affinity.service
if [ -d ~/display_connector.v0.1.7 ]; then
  if [ -e ~/display_connector.failed-dev ]; then
    echo 'Failed-dev preservation path exists; choose another name and stop.' >&2
    exit 1
  fi
  mv ~/display_connector ~/display_connector.failed-dev
  mv ~/display_connector.v0.1.7 ~/display_connector
fi
sudo install -o root -g root -m 0644 \
  ~/display-affinity-before-connector/display.service \
  /etc/systemd/system/display.service
sudo install -o root -g root -m 0644 \
  ~/display-affinity-before-connector/affinity.service \
  /etc/systemd/system/affinity.service
sudo install -o root -g root -m 0755 \
  ~/display-affinity-before-connector/affinity-setup.sh \
  /usr/local/sbin/affinity-setup.sh
sudo systemctl daemon-reload
sudo systemctl enable --now display.service affinity.service
systemctl cat display.service affinity.service
systemctl status display.service affinity.service --no-pager
```

The base procedure deliberately verified both services as enabled and active, so the commands restore that known coupled state. If any saved `*-was-enabled.txt` or `*-was-active.txt` says otherwise, reproduce the recorded state explicitly instead. This service-and-file rollback is another reason not to flash the touchscreen firmware.

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

Do not run an indiscriminate `apt full-upgrade` before creating the first working checkpoint. Apply OS, Klipper, fork, Cartographer, and display updates deliberately and one category at a time, with an eMMC/config backup first.

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
Toolhead**. It accepts an already-present bootloader and can rebuild/retry the
application without the previous application serial device:

```bash
cat ~/printer_data/config/Firmware/klipper-build-source.commit
find ~/printer_data/config/Firmware/builds -maxdepth 3 -type f -print
~/OpenNept4une/OpenNept4une.sh update_mcu_rpi_fw
```

Do not bypass the identity/VID:PID/service guards with a guessed tty. If neither
the application nor bootloader enumerates after the power-service, cable, and
kernel checks, stop. Restoring eMMC cannot restore that MCU; recovery then
requires a verified physical-programming procedure, an exact vendor package,
or replacement hardware. No safe SWD procedure for this toolhead is currently
documented.

### Main MCU application recovery

The main-MCU OpenNept4une archive can be restaged to a FAT32 microSD after its
checksum manifest is verified. Copy its `klipper.bin` twice as `X_4.bin` and
`elegoo_k1.bin`, then follow section 8's powered-off microSD procedure. This
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
- [ ] Wi-Fi works, with Ethernet/serial fallback known
- [ ] GPIO82 service is active and passed repeated cold boots
- [ ] This fork's working tree/commit was recorded and update origin points to `dalgibbard/OpenNept4une`
- [ ] Safety-patched bundled `n4flash.c` hash is `fb446842...20df70` and compiled cleanly on the printer
- [ ] Toolhead application and bootloader by-id/udev identities were captured
- [ ] Versioned main-MCU and toolhead OpenNept4une build archives and checksum manifests were copied off-device
- [ ] Toolhead was flashed through its unique `usb-MKS_DRIVER_BOOT_*` path after VID/PID validation
- [ ] Main MCU was flashed by microSD, not experimental serial
- [ ] Main, THR, and virtual MCU protocol versions match
- [ ] `N4Max-v2.3-tusbc` config generated and backed up
- [ ] Temperatures, endstops, stock probe, runout sensor, fans, lights, and motor directions checked cold
- [ ] Factory-probe baseline print completed
- [ ] Cartographer mount/offsets/envelope calibrated on this machine
- [ ] C920 uses a persistent V4L path at a conservative bandwidth
- [ ] `/dev/ttyS1` and screen version validated before enabling `display_connector`
- [ ] Touchscreen firmware was not changed during initial bring-up
- [ ] A new working golden eMMC image was made after commissioning
