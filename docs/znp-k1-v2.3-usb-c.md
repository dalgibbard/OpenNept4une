# ZNP-K1 2.3 and Neptune 4 Max USB-C support

This branch contains **experimental** support for the `ZNP-K1-2.3` controller
and the separate USB-C toolhead MCU. Klipper targets its STM32F103xE-compatible
layout, while the hardware seen in the reference work is GD32F303-compatible
and requires the Cortex-M4 build override. It has not yet completed the same
hardware-validation matrix as the officially supported boards. Keep a verified
raw backup of the original eMMC before testing it.

## Implemented in this fork

- Moonraker derives the OpenNept4une update-manager origin from the installed
  checkout's actual `origin`, so installing from a fork no longer rewrites the
  updater back to `OpenNeptune3D/OpenNept4une`.
- The built-in updater compares the local branch with `origin/<branch>`, even
  when the branch is configured to track a separate `upstream` remote. It
  refuses dirty checkouts and non-fast-forward updates instead of deleting
  local work to resolve divergence.
- The `n4max` + `usb-c` generator maps the part light to `THR:PB10` and does not
  also declare PB10 as a neopixel. The `n4max` + `ribbon` configuration remains
  on `rpi:gpiochip2/gpio15`.
- `img-config/board-hardware-setup.sh` installs/selects the 2.3 DTB, enables
  persistent GPIO82 toolhead power before Klipper, supports offline mounted
  images, is idempotent, and records state for guarded rollback. Mutations
  require root, install root-owned service artifacts, and preflight every
  managed guard before changing either the DTB or power integration.
- The v2.3 DTB corrects both parts of the RK805 PMIC interrupt mapping: its
  parent is GPIO2 and its line is 6, matching the pinctrl and maintained MKS Pi
  source. Physical testing showed that the inherited GPIO1 parent/line-24
  mapping, and an intermediate line-only correction, stormed until Linux
  disabled the PMIC IRQ.
- The power-loss monitor keeps one supercapacitor GPIO holder across rejected
  false edges, avoiding the observed `Device or resource busy` failure. On
  libgpiod v2 it uses the physically validated quiet both-edge request mode
  with 20 ms kernel debounce, releases both one-shot monitors before live-state
  verification, and re-arms only those input monitors after a rejected event.
  Image cleanup now leaves an empty
  `/etc/machine-id` placeholder suitable for first-boot initialization.
- Printer model/PCB/toolhead selection validates only supported tuples and is
  written with an atomic, exactly-one-line replacement. Explicit CLI fields
  are retained even when the command is otherwise interactive.
- The MCU updater permits one target per run, leaves the main MCU on the
  microSD/established alternative paths, and handles the USB-C toolhead through
  a unique persistent bootloader path instead of `/dev/ttyACM0`. It never
  pulls Klipper implicitly and pins every separate MCU build to one recorded
  Klipper source commit.
- Pinned MIT-licensed `n4flash` source is bundled. Before invoking it, the
  updater builds and size-checks the firmware, requires typed confirmation,
  validates one `usb-MKS_DRIVER_BOOT_*` device as VID/PID `1d50:018a`, and
  stops/restores Klipper safely. It records bootloader and application udev
  identities under `printer_data/config/Firmware/usb-c-identities/` and does
  not report success unless the application re-enumerates and `MCU_ID.cfg` is
  written. The transport ignores unrelated bootloader frames, never resends
  the mass-erasing START command, and attempts ABORT after an uncertain START.
- Every new main-MCU and USB-C-toolhead build is archived before staging or
  flashing under `printer_data/config/Firmware/builds/`, with its binary,
  expanded Klipper config, pinned source commit, metadata, and verified
  checksums. The updater never overwrites an existing archive, and an archival
  failure blocks the flash. These are OpenNept4une recovery artifacts, not
  factory-firmware dumps.
- A process-wide lock serializes all MCU updater runs that share Klipper's
  `.config` and `out/` directory. Main/toolhead archives must also pass
  target-specific config checks. Normal USB-C flashing uses the flushed,
  revalidated archived copy, not mutable build output.
- **USB-C Toolhead Recovery** verifies and flashes an exact managed archive
  through the same persistent-device, VID:PID, service-restoration, and typed
  confirmation gates; it requires the archive, current Klipper checkout, and
  pinned coordinated MCU source to agree. It revalidates after interactive
  device selection, binds the original firmware digest, and flashes a private
  read-only snapshot to close the ordinary archive-change window.
- The top-level command propagates installer failures, and the display
  initializer preserves/refuses a mismatched existing checkout rather than
  deleting it.
- Automated tests exercise board installation/rollback, GPIO behavior through
  a fixture, MCU resolver/size safety, strict `n4flash` compilation, both Max
  toolhead variants, and fork-origin resolution.

Run the hardware-independent checks with:

```bash
./tests/run.sh
```

Apply the integration on a running printer after selecting this physical
hardware:

```bash
./OpenNept4une.sh --yes \
  --printer_model n4max --pcb_version 2.3 --toolhead usb-c \
  set_printer_model
./img-config/board-hardware-setup.sh status
```

`set_printer_model` persists the physical selection and board integration
without trying to generate `printer.cfg`, so it can run before the toolhead has
Klipper firmware. Full USB-C config generation still requires exactly one
final persistent application ID.

For a mounted image, mount its boot partition under its root at `ROOT/boot`
and use `--root ROOT`, or pass a separate `--boot` mount explicitly. Follow the
[full bring-up and recovery guide](neptune-4-max-znp-k1-2.3-usb-c-guide.md) for
the exact end-to-end procedure and safety gates.

## Hardware validation still required

Do not turn on heaters or start motion merely because Klipper connects. First
capture the real identities from one known-good `ZNP-K1-2.3` + USB-C machine.
Run these read-only commands once with the toolhead application running:

```bash
ls -l /dev/serial/by-id/
TOOLHEAD_LINK=$(find /dev/serial/by-id -maxdepth 1 -type l \
  -name 'usb-Klipper_stm32f103xe_*' -print -quit)
if [ -z "$TOOLHEAD_LINK" ]; then
  echo "USB-C toolhead not found" >&2
else
  udevadm info --query=property --name="$(readlink -f "$TOOLHEAD_LINK")" \
    | grep -E '^(ID_VENDOR_ID|ID_MODEL_ID|ID_SERIAL|ID_PATH)='
fi
```

Then put the toolhead into its bootloader using the supported updater flow and
repeat the two commands with the bootloader's by-id path. If no by-id symlink
is created, first identify the newly appeared node with `dmesg --follow`, then
query that explicit node with `udevadm info`. Do not guess `/dev/ttyACM0`.

Record and confirm all of the following before treating auto-detection or
flashing as production-safe:

- observed application mode: VID:PID `1d50:614e` and
  `/dev/serial/by-id/usb-Klipper_stm32f103xe_105B303534340C0039333032-if00`;
- TODO: confirm the application physical path with udev and collect additional
  device samples rather than treating the observed serial as universal;
- TODO: bootloader-mode `/dev/serial/by-id` name, VID:PID, and physical path;
- TODO: whether the node changes when the C920 or a USB hub is attached;
- TODO: GPIO82 power-cycle timing over at least ten cold boots;
- TODO: part-light, hotend fan, part fan, thermistor, heater, probe, and
  accelerometer behavior on a physical Neptune 4 Max.

Prefer `/dev/serial/by-id/...` over `/dev/ttyACM0` for every persistent Klipper
configuration. Before any flash, resolve the selected symlink and use
`udevadm info` to confirm that it is the toolhead—not a Cartographer, webcam,
or another USB serial device. Disconnect unrelated USB peripherals while
flashing.

After Klipper connects, validate cold and in this order:

1. `STATUS` and `QUERY_ENDSTOPS`; do not move an axis with an unexpected state.
2. Confirm room-temperature readings are plausible before enabling a heater.
3. Pulse each fan/light output individually and confirm the physical result.
4. Heat the hotend to only 50 °C while watching for a smooth temperature rise
   and verifying the hotend fan starts. Be ready to cut printer power.
5. Home one axis at a time only after the corresponding endstop was verified.

The model flag expected for this machine is `N4Max-v2.3-tusbc`. Generating the
USB-C configuration intentionally fails until exactly one persistent
`usb-Klipper_stm32f103xe_*` identity is present.
