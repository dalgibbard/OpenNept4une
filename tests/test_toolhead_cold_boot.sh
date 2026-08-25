#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="${REPO_ROOT}/img-config/check-toolhead-cold-boot.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/serial" "${TEST_ROOT}/state"
printf '%s\n' 'boot-one' >"${TEST_ROOT}/boot-id"
touch "${TEST_ROOT}/ttyACM0"
ln -s "${TEST_ROOT}/ttyACM0" \
  "${TEST_ROOT}/serial/usb-Klipper_stm32f103xe_TEST-if00"

printf '%s\n' \
  '#!/bin/sh' \
  'case "$(basename "$0")" in' \
  '  systemctl) echo active ;;' \
  '  sudo) shift 0; exec "$@" ;;' \
  '  lsusb) echo "Bus 001 Device 003: ID 1d50:614e OpenMoko, Inc. stm32f103xe" ;;' \
  '  toolhead-power) echo "gpio=82 direction=out value=1" ;;' \
  '  *) exit 99 ;;' \
  'esac' >"${TEST_ROOT}/bin/fake-tool"
chmod 0755 "${TEST_ROOT}/bin/fake-tool"
for tool in systemctl sudo lsusb toolhead-power; do
  ln -s fake-tool "${TEST_ROOT}/bin/${tool}"
done

run_checker() {
  OPENNEPT4UNE_SYSTEMCTL_BIN="${TEST_ROOT}/bin/systemctl" \
  OPENNEPT4UNE_SUDO_BIN="${TEST_ROOT}/bin/sudo" \
  OPENNEPT4UNE_LSUSB_BIN="${TEST_ROOT}/bin/lsusb" \
  OPENNEPT4UNE_TOOLHEAD_POWER_HELPER="${TEST_ROOT}/bin/toolhead-power" \
  OPENNEPT4UNE_SERIAL_BY_ID_DIR="${TEST_ROOT}/serial" \
  OPENNEPT4UNE_BOOT_ID_FILE="${TEST_ROOT}/boot-id" \
  OPENNEPT4UNE_COLD_BOOT_STATE_DIR="${TEST_ROOT}/state" \
    "$CHECKER" "$@"
}

output="$(run_checker)"
grep -Fq 'Validated only; recorded cold boots: 0/10' <<<"$output"
test ! -e "${TEST_ROOT}/state/toolhead-cold-boots.tsv"

output="$(run_checker --record-cold-boot)"
grep -Fq 'Recorded confirmed cold boot: 1/10.' <<<"$output"
test "$(wc -l <"${TEST_ROOT}/state/toolhead-cold-boots.tsv")" -eq 1

output="$(run_checker --record-cold-boot)"
grep -Fq 'Already recorded this Linux boot; count remains 1/10.' <<<"$output"
test "$(wc -l <"${TEST_ROOT}/state/toolhead-cold-boots.tsv")" -eq 1

printf '%s\n' 'boot-two' >"${TEST_ROOT}/boot-id"
output="$(run_checker --record-cold-boot)"
grep -Fq 'Recorded confirmed cold boot: 2/10.' <<<"$output"
test "$(wc -l <"${TEST_ROOT}/state/toolhead-cold-boots.tsv")" -eq 2

rm "${TEST_ROOT}/serial/usb-Klipper_stm32f103xe_TEST-if00"
ln -s "${TEST_ROOT}/ttyACM0" \
  "${TEST_ROOT}/serial/usb-Klipper_stm32f103xe_CHANGED-if00"
printf '%s\n' 'boot-three' >"${TEST_ROOT}/boot-id"
if run_checker --record-cold-boot >/dev/null 2>&1; then
  echo 'checker unexpectedly accepted a changed toolhead identity' >&2
  exit 1
fi
test "$(wc -l <"${TEST_ROOT}/state/toolhead-cold-boots.tsv")" -eq 2

echo 'toolhead cold-boot tests passed'
