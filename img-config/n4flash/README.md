# Bundled n4flash source

This directory vendors `n4flash.c` based on
<https://codeberg.org/gggcodes/n4flash> at commit
`686c3bf1d0ea5f98d991ea56a3f5a35944f300fd` (MIT license). The pristine
upstream file has SHA-256
`fed0708f556462a6d02aba6627237b42bcdaffc3bbafde34751dbc1602f2cb2d`.

This copy adds fail-closed checks that upstream did not contain: it rejects
empty/oversized firmware itself, detects firmware read errors, and does not
report success unless the bootloader acknowledges the final END command. It
waits through unrelated periodic HELLO frames for the matching response,
never resends the mass-erasing START command, and requests ABORT when START's
outcome is uncertain. DATA acknowledgements must also echo the exact page and
length before they can advance the transfer. Its SHA-256 is
`fb44684204d97a2fbee2ab1762828ff39b2079a2794bbdaed0fc01a65720df70`.

`img-config/rpi-mcu-install.sh` compiles it locally and invokes it only after
the USB-C toolhead bootloader has been resolved through a unique persistent
`/dev/serial/by-id/usb-MKS_DRIVER_BOOT_*` path and validated as USB VID/PID
`1d50:018a`.

Although the upstream utility can speak to the main-controller bootloader,
OpenNept4une deliberately does not integrate that path. Use the documented
microSD workflow (or the existing alternative method) for the main MCU.

Important: the bootloader erases the toolhead application region at the start
of a transfer. Do not interrupt power or USB while flashing.
