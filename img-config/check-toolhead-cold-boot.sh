#!/usr/bin/env bash

set -euo pipefail

TARGET_COUNT=10
SERVICE_NAME="opennept4une-toolhead-power.service"
EXPECTED_USB_ID="1d50:614e"
SERIAL_GLOB="usb-Klipper_stm32f103xe_*-if00"

SYSTEMCTL_BIN="${OPENNEPT4UNE_SYSTEMCTL_BIN:-systemctl}"
SUDO_BIN="${OPENNEPT4UNE_SUDO_BIN:-sudo}"
LSUSB_BIN="${OPENNEPT4UNE_LSUSB_BIN:-lsusb}"
POWER_HELPER="${OPENNEPT4UNE_TOOLHEAD_POWER_HELPER:-/usr/local/sbin/opennept4une-toolhead-power}"
SERIAL_DIR="${OPENNEPT4UNE_SERIAL_BY_ID_DIR:-/dev/serial/by-id}"
BOOT_ID_FILE="${OPENNEPT4UNE_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
STATE_BASE="${XDG_STATE_HOME:-${HOME}/.local/state}"
STATE_DIR="${OPENNEPT4UNE_COLD_BOOT_STATE_DIR:-${STATE_BASE}/opennept4une}"
EXPECTED_SERIAL_FILE="${STATE_DIR}/toolhead-cold-boot.expected-serial"
BOOT_LOG="${STATE_DIR}/toolhead-cold-boots.tsv"

record=false

usage() {
  cat <<'EOF'
Usage: check-toolhead-cold-boot.sh [--record-cold-boot]

With no option, validate the current boot without recording it.

Use --record-cold-boot only after removing mains power completely and then
starting the printer. Software cannot distinguish a cold boot from a reboot.
Each Linux boot ID can be recorded only once.
EOF
}

case "${1:-}" in
  "") ;;
  --record-cold-boot) record=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for command_path in "$SYSTEMCTL_BIN" "$SUDO_BIN" "$LSUSB_BIN" sha256sum awk flock; do
  command -v "$command_path" >/dev/null 2>&1 || fail "required command not found: $command_path"
done
[ -x "$POWER_HELPER" ] || fail "toolhead-power helper is missing or not executable: $POWER_HELPER"
[ -r "$BOOT_ID_FILE" ] || fail "boot ID is unreadable: $BOOT_ID_FILE"

service_state="$($SYSTEMCTL_BIN is-active "$SERVICE_NAME" 2>/dev/null || true)"
[ "$service_state" = active ] || fail "$SERVICE_NAME is '$service_state', expected 'active'"

gpio_state="$($SUDO_BIN "$POWER_HELPER" status 2>&1)" || fail "could not read GPIO82 state: $gpio_state"
[ "$gpio_state" = 'gpio=82 direction=out value=1' ] || fail "unexpected GPIO82 state: $gpio_state"

usb_devices="$($LSUSB_BIN)" || fail "lsusb failed"
grep -Eq "ID ${EXPECTED_USB_ID}([[:space:]]|$)" <<<"$usb_devices" \
  || fail "USB-C toolhead ${EXPECTED_USB_ID} is not present"

mapfile -t serial_paths < <(compgen -G "${SERIAL_DIR}/${SERIAL_GLOB}" || true)
[ "${#serial_paths[@]}" -eq 1 ] \
  || fail "expected exactly one ${SERIAL_DIR}/${SERIAL_GLOB}, found ${#serial_paths[@]}"
serial_path="${serial_paths[0]}"
[ -L "$serial_path" ] || fail "persistent serial path is not a symlink: $serial_path"
serial_target="$(readlink -f -- "$serial_path")"
[ -e "$serial_target" ] || fail "persistent serial target does not exist: $serial_target"
serial_name="$(basename -- "$serial_path")"

printf 'PASS: service=%s\n' "$service_state"
printf 'PASS: %s\n' "$gpio_state"
printf 'PASS: toolhead USB ID=%s\n' "$EXPECTED_USB_ID"
printf 'PASS: serial=%s -> %s\n' "$serial_name" "$serial_target"

if ! $record; then
  if [ -r "$BOOT_LOG" ]; then
    recorded_count="$(awk -F '\t' '!seen[$1]++ { count++ } END { print count + 0 }' "$BOOT_LOG")"
  else
    recorded_count=0
  fi
  printf 'Validated only; recorded cold boots: %s/%s\n' "$recorded_count" "$TARGET_COUNT"
  printf 'Use --record-cold-boot only after a confirmed full power-off.\n'
  exit 0
fi

install -d -m 0700 "$STATE_DIR"
exec 9>"${STATE_DIR}/toolhead-cold-boots.lock"
flock 9

read -r boot_id <"$BOOT_ID_FILE"
[ -n "$boot_id" ] || fail "boot ID is empty"
boot_hash="$(printf '%s' "$boot_id" | sha256sum | awk '{print $1}')"

if [ -r "$EXPECTED_SERIAL_FILE" ]; then
  expected_serial="$(<"$EXPECTED_SERIAL_FILE")"
  [ "$serial_name" = "$expected_serial" ] \
    || fail "toolhead serial changed: expected $expected_serial, found $serial_name"
else
  printf '%s\n' "$serial_name" >"$EXPECTED_SERIAL_FILE"
  chmod 0600 "$EXPECTED_SERIAL_FILE"
fi

touch "$BOOT_LOG"
chmod 0600 "$BOOT_LOG"
if awk -F '\t' -v boot_hash="$boot_hash" '$1 == boot_hash { found=1 } END { exit !found }' "$BOOT_LOG"; then
  recorded_count="$(awk -F '\t' '!seen[$1]++ { count++ } END { print count + 0 }' "$BOOT_LOG")"
  printf 'Already recorded this Linux boot; count remains %s/%s.\n' "$recorded_count" "$TARGET_COUNT"
  exit 0
fi

printf '%s\t%s\t%s\n' \
  "$boot_hash" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$serial_name" >>"$BOOT_LOG"
recorded_count="$(awk -F '\t' '!seen[$1]++ { count++ } END { print count + 0 }' "$BOOT_LOG")"

printf 'Recorded confirmed cold boot: %s/%s.\n' "$recorded_count" "$TARGET_COUNT"
printf 'Evidence: %s\n' "$BOOT_LOG"
if [ "$recorded_count" -ge "$TARGET_COUNT" ]; then
  printf 'PASS: cold-boot target reached.\n'
fi
