#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETTER="$REPO_ROOT/img-config/set-printer-model.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
printf '%s\n' '#!/bin/sh' 'exec unshare -Ur "$@"' > "$TEST_ROOT/bin/sudo"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$BOARD_CALL_LOG"' \
    > "$TEST_ROOT/board-setup"
chmod 0755 "$TEST_ROOT/bin/sudo" "$TEST_ROOT/board-setup"

export PATH="$TEST_ROOT/bin:$PATH"
export BOARD_CALL_LOG="$TEST_ROOT/board-call.txt"
export BOARD_HARDWARE_SETUP="$TEST_ROOT/board-setup"
export OPENNEPT4UNE_FLAG_FILE="$TEST_ROOT/.OpenNept4une.txt"
printf '%s\n' 'Linux fixture' 'N4Max-v2.0-tribbon' > "$OPENNEPT4UNE_FLAG_FILE"

# Supplying every field without --yes must not discard the caller's model or
# prompt for a replacement.
output=$(env \
    model_key=n4max \
    pcb_version=2.3 \
    toolhead_variant=usb-c \
    motor_current= \
    auto_yes=false \
    "$SETTER" </dev/null)
if grep -q 'Please select your printer model' <<< "$output"; then
    echo 'explicit printer model was unexpectedly re-prompted' >&2
    exit 1
fi
grep -Fxq 'apply --model n4max --pcb-version 2.3 --toolhead usb-c' "$BOARD_CALL_LOG"
grep -Fxq 'N4Max-v2.3-tusbc' "$OPENNEPT4UNE_FLAG_FILE"
test "$(grep -Eic '^n4' "$OPENNEPT4UNE_FLAG_FILE")" -eq 1

# A numeric-looking but unsupported revision must fail before touching board
# integration or the persisted flag.
rm -f "$BOARD_CALL_LOG"
if env \
    model_key=n4max \
    pcb_version=2.30 \
    toolhead_variant=usb-c \
    motor_current= \
    auto_yes=true \
    "$SETTER" </dev/null >/dev/null 2>&1; then
    echo 'unsupported PCB revision was unexpectedly accepted' >&2
    exit 1
fi
test ! -e "$BOARD_CALL_LOG"
grep -Fxq 'N4Max-v2.3-tusbc' "$OPENNEPT4UNE_FLAG_FILE"

printf '%s\n' 'set-printer-model tests passed'
