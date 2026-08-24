#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_ROOT}/img-config/rpi-mcu-install.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export OPENNEPT4UNE_RPI_MCU_INSTALL_LIB_ONLY=1
mkdir -p "$HOME" "${TEST_ROOT}/serial-by-id"

# Scratch cleanup paths are owned by the updater process and must never be
# inherited from its caller's environment.
env \
    HOME="$HOME" \
    OPENNEPT4UNE_RPI_MCU_INSTALL_LIB_ONLY=1 \
    TOOLHEAD_FLASH_SNAPSHOT_DIR="${TEST_ROOT}/inherited-dir" \
    TOOLHEAD_FLASH_SNAPSHOT_FILE="${TEST_ROOT}/inherited-file" \
    bash -c 'source "$1"; test -z "${TOOLHEAD_FLASH_SNAPSHOT_DIR:-}"; test -z "${TOOLHEAD_FLASH_SNAPSHOT_FILE:-}"' \
    _ "$INSTALLER"

# shellcheck source=../img-config/rpi-mcu-install.sh
source "$INSTALLER"

# Exercise commands that are privileged on a printer against local fixtures.
sudo() { "$@"; }

# The updater must hold one process-wide lock while it uses Klipper's shared
# .config and out/ paths. A competing process must fail without waiting.
MCU_UPDATE_LOCK_FILE="${TEST_ROOT}/firmware/.mcu-update.lock"
acquire_mcu_update_lock
test -n "${MCU_UPDATE_LOCK_FD:-}"
if flock -n "$MCU_UPDATE_LOCK_FILE" -c true 2>/dev/null; then
    echo "a competing process unexpectedly acquired the MCU updater lock" >&2
    exit 1
fi
release_mcu_update_lock
flock -n "$MCU_UPDATE_LOCK_FILE" -c true

# Separate MCU runs must stay pinned to one Klipper source revision, and the
# updater must reject a silently changed checkout until the operator starts a
# deliberate new build set.
mkdir -p "$KLIPPER_DIR"
git -C "$KLIPPER_DIR" init -q
printf '%s\n' 'fixture' > "$KLIPPER_DIR/tracked.txt"
git -C "$KLIPPER_DIR" add tracked.txt
git -C "$KLIPPER_DIR" -c user.name=Test -c user.email=test@example.invalid \
    commit -qm 'fixture commit'
KLIPPER_SOURCE_PIN="${TEST_ROOT}/firmware/klipper-build-source.commit"
commit_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
commit_a=$(git -C "$KLIPPER_DIR" rev-parse HEAD)
pin_klipper_source_commit >/dev/null
grep -Fxq "$commit_a" "$KLIPPER_SOURCE_PIN"
printf '%s\n' "$commit_b" > "$KLIPPER_SOURCE_PIN"
if pin_klipper_source_commit >/dev/null 2>&1; then
    echo "Klipper source pin unexpectedly accepted a different commit" >&2
    exit 1
fi
printf '%s\n' "$commit_a" > "$KLIPPER_SOURCE_PIN"
printf '%s\n' 'dirty' > "$KLIPPER_DIR/untracked.txt"
if pin_klipper_source_commit >/dev/null 2>&1; then
    echo "Klipper source pin unexpectedly accepted a dirty worktree" >&2
    exit 1
fi
rm -f "$KLIPPER_DIR/untracked.txt"

# Every destructive MCU workflow must first publish a verified archive that the
# updater will not overwrite, containing the built binary, config, and source.
archive_firmware="${TEST_ROOT}/archive-fixture.bin"
archive_config="${KLIPPER_DIR}/.config"
printf '%s\n' 'fixture firmware payload' > "$archive_firmware"
printf '%s\n' \
    'CONFIG_MACH_STM32=y' \
    'CONFIG_MACH_STM32F4=y' \
    'CONFIG_MACH_STM32F401=y' \
    'CONFIG_SERIAL=y' \
    'CONFIG_STM32_SERIAL_USART1=y' \
    > "$archive_config"
FIRMWARE_BUILD_ARCHIVE_ROOT="${TEST_ROOT}/firmware/builds"
OPENNEPT4UNE_BUILD_ARCHIVE_UTC="2026-08-24T12:34:56Z"
archive_dir="${FIRMWARE_BUILD_ARCHIVE_ROOT}/20260824T123456Z-main-mcu-${commit_a:0:12}"
archive_stderr="${TEST_ROOT}/main-archive.stderr"
archive_output=$(archive_klipper_firmware_build \
    main-mcu "$archive_firmware" "$archive_config" 2>"$archive_stderr")
test "$archive_output" = "$archive_dir"
grep -Fq "Archived main-mcu firmware build: ${archive_dir}" "$archive_stderr"
test -d "$archive_dir"
cmp "$archive_firmware" "${archive_dir}/klipper.bin"
cmp "$archive_config" "${archive_dir}/klipper.config"
grep -Fxq "$commit_a" "${archive_dir}/klipper-source.commit"
grep -Fxq 'target=main-mcu' "${archive_dir}/build-metadata.txt"
grep -Fxq 'created_utc=2026-08-24T12:34:56Z' \
    "${archive_dir}/build-metadata.txt"
grep -Fxq "klipper_commit=${commit_a}" "${archive_dir}/build-metadata.txt"
grep -Fxq "firmware_bytes=$(stat -c '%s' "$archive_firmware")" \
    "${archive_dir}/build-metadata.txt"
grep -Fxq 'build_invocation_hint=make' \
    "${archive_dir}/build-metadata.txt"
(
    cd "$archive_dir"
    sha256sum --check --strict SHA256SUMS >/dev/null
)
archived_firmware_sha=$(sha256sum "${archive_dir}/klipper.bin")
printf '%s\n' 'different payload that must not replace the archive' \
    > "$archive_firmware"
if archive_klipper_firmware_build \
    main-mcu "$archive_firmware" "$archive_config" >/dev/null 2>&1; then
    echo "firmware archiver unexpectedly overwrote an existing archive" >&2
    exit 1
fi
test "$(sha256sum "${archive_dir}/klipper.bin")" = "$archived_firmware_sha"
test ! -e "${archive_dir}.lock"
if find "$FIRMWARE_BUILD_ARCHIVE_ROOT" -maxdepth 1 \
    -name ".20260824T123456Z-main-mcu-${commit_a:0:12}.tmp.*" \
    -print -quit | grep -q .; then
    echo "firmware archiver left a staging directory behind" >&2
    exit 1
fi

OPENNEPT4UNE_BUILD_ARCHIVE_UTC="2026-08-24T12:34:57Z"
toolhead_archive_dir="${FIRMWARE_BUILD_ARCHIVE_ROOT}/20260824T123457Z-usb-c-toolhead-${commit_a:0:12}"
if archive_klipper_firmware_build \
    usb-c-toolhead "$archive_firmware" "$archive_config" >/dev/null 2>&1; then
    echo "toolhead archiver unexpectedly accepted a main-MCU config" >&2
    exit 1
fi
printf '%s\n' \
    'CONFIG_MACH_STM32=y' \
    'CONFIG_MACH_STM32F103=y' \
    'CONFIG_STM32_FLASH_START_8000=y' \
    'CONFIG_STM32_USB_PA11_PA12=y' \
    > "$archive_config"
toolhead_archive_output=$(archive_klipper_firmware_build \
    usb-c-toolhead "$archive_firmware" "$archive_config" \
    2>"${TEST_ROOT}/toolhead-archive.stderr")
test "$toolhead_archive_output" = "$toolhead_archive_dir"
grep -Fq "Archived usb-c-toolhead firmware build: ${toolhead_archive_dir}" \
    "${TEST_ROOT}/toolhead-archive.stderr"
grep -Fxq 'target=usb-c-toolhead' \
    "${toolhead_archive_dir}/build-metadata.txt"
grep -Fxq 'build_invocation_hint=make MCU_UPPER=STM32F103xE -mcpu=cortex-m4' \
    "${toolhead_archive_dir}/build-metadata.txt"
(
    cd "$toolhead_archive_dir"
    sha256sum --check --strict SHA256SUMS >/dev/null
)
validated_toolhead_firmware=$(validate_firmware_build_archive \
    usb-c-toolhead "$toolhead_archive_dir")
test "$validated_toolhead_firmware" = "${toolhead_archive_dir}/klipper.bin"
toolhead_expected_sha=$(archive_firmware_sha256 "$toolhead_archive_dir")
test "${#toolhead_expected_sha}" -eq 64
TOOLHEAD_FLASH_SNAPSHOT_ROOT="${TEST_ROOT}/flash-snapshots"
prepare_toolhead_flash_snapshot \
    "$validated_toolhead_firmware" "$toolhead_expected_sha"
test -f "$TOOLHEAD_FLASH_SNAPSHOT_FILE"
test "$(stat -c '%a' "$TOOLHEAD_FLASH_SNAPSHOT_FILE")" = "400"
cmp "$validated_toolhead_firmware" "$TOOLHEAD_FLASH_SNAPSHOT_FILE"
snapshot_dir="$TOOLHEAD_FLASH_SNAPSHOT_DIR"
cleanup_toolhead_flash_snapshot
test ! -e "$snapshot_dir"

# Cleanup must not follow a textually valid snapshot path through a symlink or
# accept a file other than the exact process-created klipper.bin path.
outside_snapshot_dir="${TEST_ROOT}/outside-snapshot"
mkdir -p "$outside_snapshot_dir" "$TOOLHEAD_FLASH_SNAPSHOT_ROOT"
printf '%s\n' 'must survive cleanup refusal' > "${outside_snapshot_dir}/klipper.bin"
TOOLHEAD_FLASH_SNAPSHOT_DIR="${TOOLHEAD_FLASH_SNAPSHOT_ROOT}/toolhead-flash.link"
TOOLHEAD_FLASH_SNAPSHOT_FILE="${TOOLHEAD_FLASH_SNAPSHOT_DIR}/klipper.bin"
ln -s "$outside_snapshot_dir" "$TOOLHEAD_FLASH_SNAPSHOT_DIR"
if cleanup_toolhead_flash_snapshot >/dev/null 2>&1; then
    echo "snapshot cleanup unexpectedly followed a linked directory" >&2
    exit 1
fi
test -f "${outside_snapshot_dir}/klipper.bin"
rm -f "$TOOLHEAD_FLASH_SNAPSHOT_DIR"
unset TOOLHEAD_FLASH_SNAPSHOT_DIR TOOLHEAD_FLASH_SNAPSHOT_FILE

mkdir -p "${TOOLHEAD_FLASH_SNAPSHOT_ROOT}/toolhead-flash.mismatch"
TOOLHEAD_FLASH_SNAPSHOT_DIR="${TOOLHEAD_FLASH_SNAPSHOT_ROOT}/toolhead-flash.mismatch"
TOOLHEAD_FLASH_SNAPSHOT_FILE="${TOOLHEAD_FLASH_SNAPSHOT_DIR}/unrelated.bin"
printf '%s\n' 'must also survive' > "$TOOLHEAD_FLASH_SNAPSHOT_FILE"
if cleanup_toolhead_flash_snapshot >/dev/null 2>&1; then
    echo "snapshot cleanup unexpectedly accepted a mismatched file path" >&2
    exit 1
fi
test -f "$TOOLHEAD_FLASH_SNAPSHOT_FILE"
rm -f "$TOOLHEAD_FLASH_SNAPSHOT_FILE"
rmdir "$TOOLHEAD_FLASH_SNAPSHOT_DIR"
unset TOOLHEAD_FLASH_SNAPSHOT_DIR TOOLHEAD_FLASH_SNAPSHOT_FILE

unset SELECTED_USB_TOOLHEAD_RECOVERY_ARCHIVE
select_usb_toolhead_recovery_archive <<<"1" >/dev/null 2>&1
test "$SELECTED_USB_TOOLHEAD_RECOVERY_ARCHIVE" = "$toolhead_archive_dir"

# Recovery validation must reject tampering and paths outside the managed root.
printf '%s\n' 'tampered firmware' > "${toolhead_archive_dir}/klipper.bin"
if validate_firmware_build_archive \
    usb-c-toolhead "$toolhead_archive_dir" >/dev/null 2>&1; then
    echo "recovery validator unexpectedly accepted tampered firmware" >&2
    exit 1
fi
cp "$archive_firmware" "${toolhead_archive_dir}/klipper.bin"
validate_firmware_build_archive \
    usb-c-toolhead "$toolhead_archive_dir" >/dev/null
outside_archive="${TEST_ROOT}/outside-usb-c-toolhead-archive"
cp -a "$toolhead_archive_dir" "$outside_archive"
if validate_firmware_build_archive \
    usb-c-toolhead "$outside_archive" >/dev/null 2>&1; then
    echo "recovery validator unexpectedly accepted an outside archive" >&2
    exit 1
fi
printf '%s\n' "$commit_b" > "$KLIPPER_SOURCE_PIN"
if validate_firmware_build_archive \
    usb-c-toolhead "$toolhead_archive_dir" >/dev/null 2>&1; then
    echo "recovery validator unexpectedly accepted a mismatched pinned commit" >&2
    exit 1
fi
printf '%s\n' "$commit_a" > "$KLIPPER_SOURCE_PIN"

# An unwritable/invalid archive root is a hard failure; callers must not be
# able to continue toward staging or flashing without the recovery artifact.
invalid_archive_root="${TEST_ROOT}/not-a-directory"
printf '%s\n' 'fixture' > "$invalid_archive_root"
FIRMWARE_BUILD_ARCHIVE_ROOT="$invalid_archive_root"
OPENNEPT4UNE_BUILD_ARCHIVE_UTC="2026-08-24T12:34:58Z"
if archive_klipper_firmware_build \
    usb-c-toolhead "$archive_firmware" "$archive_config" >/dev/null 2>&1; then
    echo "firmware archiver unexpectedly accepted an invalid archive root" >&2
    exit 1
fi
unset OPENNEPT4UNE_BUILD_ARCHIVE_UTC

# The updater's GPIO82 fallback uses the same writable fixture convention as
# the installed helper and must finish with the toolhead rail high.
mkdir -p "${TEST_ROOT}/gpio/gpio82"
touch "${TEST_ROOT}/gpio/export"
printf 'out\n' > "${TEST_ROOT}/gpio/gpio82/direction"
printf '1\n' > "${TEST_ROOT}/gpio/gpio82/value"
OPENNEPT4UNE_GPIO_ROOT="${TEST_ROOT}/gpio"
USB_TOOLHEAD_POWER_HELPER="${TEST_ROOT}/missing-power-helper"
request_usb_bootloader_gpio82 >/dev/null
test "$(<"${TEST_ROOT}/gpio/gpio82/value")" = "1"

# Identity capture must preserve the stable path and relevant udev fields.
mkdir -p "${TEST_ROOT}/bin"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "ID_VENDOR_ID=1d50" "ID_MODEL_ID=018a" "ID_SERIAL=test-toolhead" "ID_PATH=test-usb-path"' \
    > "${TEST_ROOT}/bin/udevadm"
chmod 0755 "${TEST_ROOT}/bin/udevadm"
export PATH="${TEST_ROOT}/bin:${PATH}"
USB_TOOLHEAD_IDENTITY_DIR="${TEST_ROOT}/identities"
identity_device="${TEST_ROOT}/identity-device"
touch "$identity_device"
record_usb_toolhead_identity "$identity_device" application >/dev/null
grep -Fxq "by_id=${identity_device}" \
    "${USB_TOOLHEAD_IDENTITY_DIR}/application-udev.txt"
grep -Fxq 'ID_SERIAL=test-toolhead' \
    "${USB_TOOLHEAD_IDENTITY_DIR}/application-udev.txt"

serial_glob="${TEST_ROOT}/serial-by-id/usb-MKS_DRIVER_BOOT_*"
if resolve_unique_serial_device "$serial_glob" "test bootloader" >/dev/null 2>&1; then
    echo "resolver unexpectedly accepted zero devices" >&2
    exit 1
fi

first_device="${TEST_ROOT}/serial-by-id/usb-MKS_DRIVER_BOOT_ONE-if00"
touch "$first_device"
resolved="$(resolve_unique_serial_device "$serial_glob" "test bootloader")"
test "$resolved" = "$first_device"

second_device="${TEST_ROOT}/serial-by-id/usb-MKS_DRIVER_BOOT_TWO-if00"
touch "$second_device"
if resolve_unique_serial_device "$serial_glob" "test bootloader" >/dev/null 2>&1; then
    echo "resolver unexpectedly selected one of multiple devices" >&2
    exit 1
fi

# A detected application is not enough for success if MCU_ID.cfg generation
# fails; the real updater must return a nonzero verification result.
application_device="${TEST_ROOT}/serial-by-id/usb-Klipper_stm32f103xe_TEST-if00"
touch "$application_device"
USB_TOOLHEAD_SERIAL_GLOB="$application_device"
mkdir -p "${TEST_ROOT}/fake-opennept4une/printer-confs"
printf '%s\n' 'import sys' 'sys.exit(1)' \
    > "${TEST_ROOT}/fake-opennept4une/printer-confs/generate_conf.py"
OPENNEPT4UNE_DIR="${TEST_ROOT}/fake-opennept4une"
if print_usb_toolhead_id_hint >/dev/null 2>&1; then
    echo "toolhead verification unexpectedly ignored MCU_ID generation failure" >&2
    exit 1
fi

firmware="${TEST_ROOT}/klipper.bin"
truncate -s "$USB_TOOLHEAD_MAX_FIRMWARE_BYTES" "$firmware"
validate_usb_toolhead_firmware "$firmware" >/dev/null
truncate -s "$((USB_TOOLHEAD_MAX_FIRMWARE_BYTES + 1))" "$firmware"
if validate_usb_toolhead_firmware "$firmware" >/dev/null 2>&1; then
    echo "oversized toolhead firmware was unexpectedly accepted" >&2
    exit 1
fi

# Build the bundled source with stricter warnings than the runtime builder and
# exercise ensure_n4flash's private, non-PATH installation location.
compiler="$(command -v cc || command -v gcc)"
expected_n4flash_sha256="fb44684204d97a2fbee2ab1762828ff39b2079a2794bbdaed0fc01a65720df70"
actual_n4flash_sha256="$(sha256sum "${REPO_ROOT}/img-config/n4flash/n4flash.c" | awk '{print $1}')"
test "$actual_n4flash_sha256" = "$expected_n4flash_sha256"
"$compiler" -O2 -Wall -Wextra -Werror \
    -o "${TEST_ROOT}/n4flash-werror" "${REPO_ROOT}/img-config/n4flash/n4flash.c"

# The utility itself repeats the wrapper's destructive-boundary size checks so
# a direct invocation cannot erase the application for an empty/oversized file.
empty_firmware="${TEST_ROOT}/empty.bin"
oversized_firmware="${TEST_ROOT}/oversized.bin"
: > "$empty_firmware"
truncate -s "$((USB_TOOLHEAD_MAX_FIRMWARE_BYTES + 1))" "$oversized_firmware"
if "${TEST_ROOT}/n4flash-werror" "$empty_firmware" /dev/null >/dev/null 2>&1; then
    echo "n4flash unexpectedly accepted empty firmware" >&2
    exit 1
fi
if "${TEST_ROOT}/n4flash-werror" "$oversized_firmware" /dev/null >/dev/null 2>&1; then
    echo "n4flash unexpectedly accepted oversized firmware" >&2
    exit 1
fi

N4FLASH_BIN="${TEST_ROOT}/private-bin/n4flash"
ensure_n4flash >/dev/null
test -x "$N4FLASH_BIN"
if "$N4FLASH_BIN" >/dev/null 2>&1; then
    echo "n4flash unexpectedly accepted missing arguments" >&2
    exit 1
fi

# These invariants prevent regression to enumeration-order dependent or mixed
# multi-MCU flashing.
if grep -q '/dev/ttyACM' "$INSTALLER"; then
    echo "installer contains an unstable ttyACM device path" >&2
    exit 1
fi
if grep -Eq '\[\[.*mcu_choice.*All|mcu_choice.*==.*All' "$INSTALLER"; then
    echo "installer still contains a mixed All-target execution branch" >&2
    exit 1
fi
if grep -Eq 'git[[:space:]]+pull' "$INSTALLER"; then
    echo "MCU updater still pulls Klipper implicitly between targets" >&2
    exit 1
fi

printf '%s\n' 'rpi-mcu-install safety tests passed'
