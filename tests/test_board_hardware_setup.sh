#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/img-config/board-hardware-setup.sh"
POWER_HELPER="${REPO_ROOT}/img-config/board-hardware/opennept4une-toolhead-power.sh"
DTB_SOURCE="${REPO_ROOT}/dtb/n4plus-n4max-v2.3/rk3328-znp-n4plus-n4max-v2.3.dtb"
DTB_RELATIVE="rockchip/rk3328-znp-n4plus-n4max-v2.3.dtb"

run_setup() {
    unshare -Ur "$SETUP" "$@"
}

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p \
    "${TEST_ROOT}/boot/dtb/rockchip" \
    "${TEST_ROOT}/etc/systemd/system" \
    "${TEST_ROOT}/usr/local/sbin" \
    "${TEST_ROOT}/var/lib"
printf '%s\n' \
    'verbosity=1' \
    'fdtfile=rockchip/original-board.dtb' \
    'extraargs=net.ifnames=0' > "${TEST_ROOT}/boot/armbianEnv.txt"
printf '%s\n' 'Linux test' 'N4max-v2.3-tusbc' > "${TEST_ROOT}/boot/.OpenNept4une.txt"

# Mutating even an offline image must require UID 0; the test suite uses a
# short-lived user namespace for the authorized fixture operations below.
if (( EUID != 0 )) && "$SETUP" apply --root "$TEST_ROOT" --from-flag >/dev/null 2>&1; then
    echo 'offline board installer unexpectedly accepted a non-root mutation' >&2
    exit 1
fi
if run_setup apply --root "$TEST_ROOT" --model n4max --pcb-version 2.30 --toolhead usb-c >/dev/null 2>&1; then
    echo 'board installer unexpectedly accepted an unsupported PCB tuple' >&2
    exit 1
fi
grep -Fxq 'fdtfile=rockchip/original-board.dtb' "${TEST_ROOT}/boot/armbianEnv.txt"

# An offline apply must select the v2.3 DTB and enable the service for first boot.
run_setup apply --root "$TEST_ROOT" --from-flag
grep -Fxq "fdtfile=${DTB_RELATIVE}" "${TEST_ROOT}/boot/armbianEnv.txt"
test "$(grep -c '^fdtfile=' "${TEST_ROOT}/boot/armbianEnv.txt")" -eq 1
cmp -s "$DTB_SOURCE" "${TEST_ROOT}/boot/dtb/${DTB_RELATIVE}"
test -x "${TEST_ROOT}/usr/local/sbin/opennept4une-toolhead-power"
test -f "${TEST_ROOT}/etc/systemd/system/opennept4une-toolhead-power.service"
grep -Fxq 'ExecStartPost=/bin/sleep 12' \
    "${TEST_ROOT}/etc/systemd/system/opennept4une-toolhead-power.service"
test -f "${TEST_ROOT}/etc/systemd/system/klipper.service.d/20-opennept4une-toolhead-power.conf"
grep -Fxq 'Nice=-18' \
    "${TEST_ROOT}/etc/systemd/system/klipper.service.d/20-opennept4une-toolhead-power.conf"
grep -Fxq 'IOSchedulingPriority=1' \
    "${TEST_ROOT}/etc/systemd/system/klipper.service.d/20-opennept4une-toolhead-power.conf"
test -L "${TEST_ROOT}/etc/systemd/system/multi-user.target.wants/opennept4une-toolhead-power.service"

# Re-applying the same selection is idempotent.
first_env_hash="$(sha256sum "${TEST_ROOT}/boot/armbianEnv.txt")"
first_dtb_hash="$(sha256sum "${TEST_ROOT}/boot/dtb/${DTB_RELATIVE}")"
run_setup apply --root "$TEST_ROOT" --from-flag
test "$(sha256sum "${TEST_ROOT}/boot/armbianEnv.txt")" = "$first_env_hash"
test "$(sha256sum "${TEST_ROOT}/boot/dtb/${DTB_RELATIVE}")" = "$first_dtb_hash"

# A rollback conflict must be detected before any power artifact is removed.
sed -i 's|^fdtfile=.*|fdtfile=rockchip/user-override.dtb|' "${TEST_ROOT}/boot/armbianEnv.txt"
if run_setup rollback --root "$TEST_ROOT" >/dev/null 2>&1; then
    echo 'rollback unexpectedly accepted a manually changed fdtfile' >&2
    exit 1
fi
test -f "${TEST_ROOT}/etc/systemd/system/opennept4une-toolhead-power.service"
test -x "${TEST_ROOT}/usr/local/sbin/opennept4une-toolhead-power"
test -f "${TEST_ROOT}/etc/systemd/system/klipper.service.d/20-opennept4une-toolhead-power.conf"
test -L "${TEST_ROOT}/etc/systemd/system/multi-user.target.wants/opennept4une-toolhead-power.service"
sed -i "s|^fdtfile=.*|fdtfile=${DTB_RELATIVE}|" "${TEST_ROOT}/boot/armbianEnv.txt"

# Applying away from USB-C must likewise preflight the service guard before it
# changes the DTB.
printf '%s\n' '# local edit' >> "${TEST_ROOT}/etc/systemd/system/opennept4une-toolhead-power.service"
if run_setup apply --root "$TEST_ROOT" --model n4max --pcb-version 2.0 --toolhead ribbon >/dev/null 2>&1; then
    echo 'apply-away unexpectedly accepted a modified managed service' >&2
    exit 1
fi
grep -Fxq "fdtfile=${DTB_RELATIVE}" "${TEST_ROOT}/boot/armbianEnv.txt"
grep -Fxq '# local edit' "${TEST_ROOT}/etc/systemd/system/opennept4une-toolhead-power.service"
cp "$REPO_ROOT/img-config/board-hardware/opennept4une-toolhead-power.service" \
    "${TEST_ROOT}/etc/systemd/system/opennept4une-toolhead-power.service"

# Switching to a ribbon toolhead retains the board DTB but removes USB-C power management.
run_setup apply --root "$TEST_ROOT" --model n4max --pcb-version 2.3 --toolhead ribbon
grep -Fxq "fdtfile=${DTB_RELATIVE}" "${TEST_ROOT}/boot/armbianEnv.txt"
test ! -e "${TEST_ROOT}/etc/systemd/system/opennept4une-toolhead-power.service"
test ! -e "${TEST_ROOT}/usr/local/sbin/opennept4une-toolhead-power"

# Switching away from PCB 2.3 restores the exact prior DTB selection.
run_setup apply --root "$TEST_ROOT" --model n4max --pcb-version 2.0 --toolhead ribbon
grep -Fxq 'fdtfile=rockchip/original-board.dtb' "${TEST_ROOT}/boot/armbianEnv.txt"
test "$(grep -c '^fdtfile=' "${TEST_ROOT}/boot/armbianEnv.txt")" -eq 1
test ! -e "${TEST_ROOT}/boot/dtb/${DTB_RELATIVE}"

# Rollback refuses to overwrite a subsequent manual fdtfile edit unless forced.
run_setup apply --root "$TEST_ROOT" --model n4max --pcb-version 2.3 --toolhead ribbon
sed -i 's|^fdtfile=.*|fdtfile=rockchip/user-override.dtb|' "${TEST_ROOT}/boot/armbianEnv.txt"
if run_setup rollback --root "$TEST_ROOT" >/dev/null 2>&1; then
    echo 'rollback unexpectedly overwrote a user DTB selection' >&2
    exit 1
fi
grep -Fxq 'fdtfile=rockchip/user-override.dtb' "${TEST_ROOT}/boot/armbianEnv.txt"
run_setup rollback --root "$TEST_ROOT" --force
grep -Fxq 'fdtfile=rockchip/original-board.dtb' "${TEST_ROOT}/boot/armbianEnv.txt"

# Exercise the GPIO helper without real hardware using a writable sysfs fixture.
mkdir -p "${TEST_ROOT}/gpio/gpio82"
touch "${TEST_ROOT}/gpio/export"
printf 'out\n' > "${TEST_ROOT}/gpio/gpio82/direction"
printf '0\n' > "${TEST_ROOT}/gpio/gpio82/value"
OPENNEPT4UNE_GPIO_ROOT="${TEST_ROOT}/gpio" "$POWER_HELPER" high
test "$(<"${TEST_ROOT}/gpio/gpio82/value")" = '1'
OPENNEPT4UNE_GPIO_ROOT="${TEST_ROOT}/gpio" "$POWER_HELPER" cycle 0.01
test "$(<"${TEST_ROOT}/gpio/gpio82/value")" = '1'

printf '%s\n' 'board-hardware tests passed'
