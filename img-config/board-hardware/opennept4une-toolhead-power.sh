#!/bin/bash
# Keep the USB-C toolhead power rail enabled on supported ZNP-K1 boards.

set -euo pipefail

GPIO_NUMBER="${OPENNEPT4UNE_TOOLHEAD_POWER_GPIO:-82}"
GPIO_ROOT="${OPENNEPT4UNE_GPIO_ROOT:-/sys/class/gpio}"
WAIT_SECONDS="${OPENNEPT4UNE_GPIO_WAIT_SECONDS:-15}"
GPIO_PATH="${GPIO_ROOT}/gpio${GPIO_NUMBER}"

die() {
    echo "opennept4une-toolhead-power: $*" >&2
    exit 1
}

[[ "$GPIO_NUMBER" =~ ^[0-9]+$ ]] || die "invalid GPIO number: ${GPIO_NUMBER}"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "invalid wait timeout: ${WAIT_SECONDS}"

ensure_exported() {
    local waited=0

    [[ -e "${GPIO_ROOT}/export" ]] || die "GPIO sysfs interface is unavailable at ${GPIO_ROOT}"

    if [[ ! -d "$GPIO_PATH" ]]; then
        # EBUSY means another process exported the line between the test and write.
        printf '%s\n' "$GPIO_NUMBER" > "${GPIO_ROOT}/export" 2>/dev/null || true
    fi

    while [[ ! -e "${GPIO_PATH}/direction" || ! -e "${GPIO_PATH}/value" ]]; do
        (( waited >= WAIT_SECONDS )) && die "GPIO ${GPIO_NUMBER} did not become available within ${WAIT_SECONDS}s"
        sleep 1
        ((waited += 1))
    done
}

set_level() {
    local level="$1"
    local direction

    ensure_exported
    direction="$(<"${GPIO_PATH}/direction")"

    if [[ "$direction" != "out" ]]; then
        # "high" and "low" select output direction and the initial value atomically.
        if [[ "$level" = "1" ]]; then
            printf 'high\n' > "${GPIO_PATH}/direction"
        else
            printf 'low\n' > "${GPIO_PATH}/direction"
        fi
    else
        printf '%s\n' "$level" > "${GPIO_PATH}/value"
    fi

    [[ "$(<"${GPIO_PATH}/value")" = "$level" ]] || die "failed to set GPIO ${GPIO_NUMBER} to ${level}"
}

case "${1:-}" in
    high|on)
        set_level 1
        ;;
    low|off)
        set_level 0
        ;;
    cycle)
        delay="${2:-1}"
        [[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid cycle delay: ${delay}"
        set_level 0
        trap 'set_level 1' EXIT INT TERM
        sleep "$delay"
        set_level 1
        trap - EXIT INT TERM
        ;;
    status)
        [[ -e "${GPIO_PATH}/direction" && -e "${GPIO_PATH}/value" ]] || die "GPIO ${GPIO_NUMBER} is not exported"
        printf 'gpio=%s direction=%s value=%s\n' \
            "$GPIO_NUMBER" "$(<"${GPIO_PATH}/direction")" "$(<"${GPIO_PATH}/value")"
        ;;
    *)
        echo "Usage: $0 {high|low|cycle [seconds]|status}" >&2
        exit 2
        ;;
esac
