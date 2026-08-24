#!/bin/bash
# Install, reconcile, or roll back board-specific boot integration.
# Supports both a running printer and an offline root filesystem mounted elsewhere.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
RESOURCE_DIR="${SCRIPT_DIR}/board-hardware"
DTB_SOURCE="${REPO_DIR}/dtb/n4plus-n4max-v2.3/rk3328-znp-n4plus-n4max-v2.3.dtb"
DTB_FILENAME="rk3328-znp-n4plus-n4max-v2.3.dtb"
DTB_FDTFILE="rockchip/${DTB_FILENAME}"
SERVICE_NAME="opennept4une-toolhead-power.service"

ACTION=""
MODEL=""
PCB_VERSION=""
TOOLHEAD=""
FROM_FLAG=0
FORCE=0
ROOT_DIR="${OPENNEPT4UNE_ROOT:-/}"
BOOT_DIR="${OPENNEPT4UNE_BOOT:-}"
REBOOT_REQUIRED=0

usage() {
    cat <<'EOF'
Usage:
  sudo board-hardware-setup.sh apply --model n4max --pcb-version 2.3 --toolhead usb-c
  sudo board-hardware-setup.sh apply --from-flag
  sudo board-hardware-setup.sh rollback [--force]
  board-hardware-setup.sh status

Options:
  --root PATH       Target root filesystem (default: /)
  --boot PATH       Target boot filesystem (default: ROOT/boot)
  --from-flag       Read model selection from BOOT/.OpenNept4une.txt
  --force           Roll back even if a managed file was changed afterwards

For offline image customization, mount the root filesystem, mount its boot
partition at ROOT/boot, and pass --root ROOT. No services are started offline.
EOF
}

log() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        apply|rollback|status)
            [[ -z "$ACTION" ]] || die "only one action may be specified"
            ACTION="$1"
            shift
            ;;
        --model)
            [[ $# -ge 2 ]] || die "--model requires a value"
            MODEL="${2,,}"
            shift 2
            ;;
        --pcb-version)
            [[ $# -ge 2 ]] || die "--pcb-version requires a value"
            PCB_VERSION="${2#v}"
            shift 2
            ;;
        --toolhead)
            [[ $# -ge 2 ]] || die "--toolhead requires a value"
            TOOLHEAD="${2,,}"
            shift 2
            ;;
        --from-flag)
            FROM_FLAG=1
            shift
            ;;
        --root)
            [[ $# -ge 2 ]] || die "--root requires a path"
            ROOT_DIR="$2"
            shift 2
            ;;
        --boot)
            [[ $# -ge 2 ]] || die "--boot requires a path"
            BOOT_DIR="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$ACTION" ]] || { usage >&2; exit 2; }
[[ -d "$ROOT_DIR" ]] || die "root filesystem does not exist: ${ROOT_DIR}"
ROOT_DIR="$(cd -- "$ROOT_DIR" && pwd)"
if [[ -z "$BOOT_DIR" ]]; then
    if [[ "$ROOT_DIR" = "/" ]]; then
        BOOT_DIR="/boot"
    else
        BOOT_DIR="${ROOT_DIR}/boot"
    fi
fi
[[ -d "$BOOT_DIR" ]] || die "boot filesystem does not exist: ${BOOT_DIR}"
BOOT_DIR="$(cd -- "$BOOT_DIR" && pwd)"

ARM_ENV_PATH="${BOOT_DIR}/armbianEnv.txt"
FLAG_FILE="${BOOT_DIR}/.OpenNept4une.txt"
DTB_TARGET_DIR="${BOOT_DIR}/dtb/rockchip"
DTB_TARGET="${DTB_TARGET_DIR}/${DTB_FILENAME}"
STATE_DIR="${ROOT_DIR%/}/var/lib/opennept4une/board-hardware"
UNIT_TARGET="${ROOT_DIR%/}/etc/systemd/system/${SERVICE_NAME}"
HELPER_TARGET="${ROOT_DIR%/}/usr/local/sbin/opennept4une-toolhead-power"
KLIPPER_DROPIN_DIR="${ROOT_DIR%/}/etc/systemd/system/klipper.service.d"
KLIPPER_DROPIN_TARGET="${KLIPPER_DROPIN_DIR}/20-opennept4une-toolhead-power.conf"
WANTS_DIR="${ROOT_DIR%/}/etc/systemd/system/multi-user.target.wants"
WANTS_LINK="${WANTS_DIR}/${SERVICE_NAME}"

is_online_root() {
    [[ "$ROOT_DIR" = "/" ]]
}

require_write_access() {
    (( EUID == 0 )) || die "run mutating actions with sudo, including offline image customization"
    [[ -w "$BOOT_DIR" ]] || die "boot filesystem is not writable: ${BOOT_DIR}"
    [[ -w "$ROOT_DIR" ]] || die "root filesystem is not writable: ${ROOT_DIR}"
}

normalize_selection() {
    case "$MODEL" in
        n4|n4pro)
            case "$PCB_VERSION" in
                1.0|1.1|1.4) ;;
                *) die "unsupported PCB version ${PCB_VERSION:-<empty>} for ${MODEL}" ;;
            esac
            ;;
        n4plus|n4max)
            case "$PCB_VERSION" in
                2.0|2.3) ;;
                *) die "unsupported PCB version ${PCB_VERSION:-<empty>} for ${MODEL}" ;;
            esac
            ;;
        *) die "unsupported model: ${MODEL:-<empty>}" ;;
    esac
    case "$TOOLHEAD" in
        usb-c|usbc) TOOLHEAD="usb-c" ;;
        ribbon) ;;
        *) die "unsupported toolhead: ${TOOLHEAD:-<empty>}" ;;
    esac
}

selection_from_flag() {
    local flag_line lower

    [[ -f "$FLAG_FILE" ]] || die "model flag file not found: ${FLAG_FILE}"
    flag_line="$(grep -Ei '^n4' "$FLAG_FILE" | tail -n 1 || true)"
    [[ -n "$flag_line" ]] || die "no model selection found in ${FLAG_FILE}"
    lower="${flag_line,,}"

    case "$lower" in
        n4max-*) MODEL="n4max" ;;
        n4plus-*) MODEL="n4plus" ;;
        n4pro-*) MODEL="n4pro" ;;
        n4-*) MODEL="n4" ;;
        *) die "cannot parse model flag: ${flag_line}" ;;
    esac

    if [[ "$lower" =~ -v([0-9]+([.][0-9]+)?) ]]; then
        PCB_VERSION="${BASH_REMATCH[1]}"
    else
        die "cannot parse PCB version from model flag: ${flag_line}"
    fi

    if [[ "$lower" = *-tusbc ]]; then
        TOOLHEAD="usb-c"
    elif [[ "$lower" = *-tribbon ]]; then
        TOOLHEAD="ribbon"
    else
        warn "legacy model flag has no toolhead suffix; assuming ribbon"
        TOOLHEAD="ribbon"
    fi
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

current_fdtfile_lines() {
    grep '^fdtfile=' "$ARM_ENV_PATH" 2>/dev/null || true
}

replace_fdtfile_lines() {
    local replacement_file="$1"
    local tmp

    tmp="$(mktemp "${ARM_ENV_PATH}.opennept4une.XXXXXX")"
    awk '!/^fdtfile=/' "$ARM_ENV_PATH" > "$tmp"
    if [[ -s "$replacement_file" ]]; then
        cat "$replacement_file" >> "$tmp"
    fi
    chmod --reference="$ARM_ENV_PATH" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$ARM_ENV_PATH"
}

install_dtb() {
    local expected_line="fdtfile=${DTB_FDTFILE}"
    local requested_file tmp

    [[ -f "$DTB_SOURCE" ]] || die "v2.3 DTB is missing from the repository: ${DTB_SOURCE}"
    [[ -f "$ARM_ENV_PATH" ]] || die "Armbian environment file not found: ${ARM_ENV_PATH}"
    mkdir -p "$STATE_DIR" "$DTB_TARGET_DIR"

    if [[ ! -e "${STATE_DIR}/dtb-managed" ]]; then
        current_fdtfile_lines > "${STATE_DIR}/original-fdtfile-lines"
        if [[ -f "$DTB_TARGET" ]]; then
            cp -a "$DTB_TARGET" "${STATE_DIR}/original-v2.3.dtb"
            touch "${STATE_DIR}/original-dtb-present"
        else
            touch "${STATE_DIR}/original-dtb-absent"
        fi
        touch "${STATE_DIR}/dtb-managed"
    fi

    if [[ ! -f "$DTB_TARGET" ]] || ! cmp -s "$DTB_SOURCE" "$DTB_TARGET"; then
        tmp="$(mktemp "${DTB_TARGET}.opennept4une.XXXXXX")"
        install -o 0 -g 0 -m 0644 "$DTB_SOURCE" "$tmp"
        mv -f "$tmp" "$DTB_TARGET"
        log "Installed ZNP-K1 2.3 DTB at ${DTB_TARGET}"
        REBOOT_REQUIRED=1
    else
        log "ZNP-K1 2.3 DTB is already current"
    fi
    chown 0:0 "$DTB_TARGET"
    chmod 0644 "$DTB_TARGET"
    sha256_file "$DTB_TARGET" > "${STATE_DIR}/installed-dtb.sha256"

    if [[ "$(current_fdtfile_lines)" != "$expected_line" ]]; then
        requested_file="$(mktemp "${STATE_DIR}/requested-fdtfile.XXXXXX")"
        printf '%s\n' "$expected_line" > "$requested_file"
        replace_fdtfile_lines "$requested_file"
        rm -f "$requested_file"
        log "Selected ${DTB_FDTFILE} in ${ARM_ENV_PATH}"
        REBOOT_REQUIRED=1
    else
        log "Armbian already selects the ZNP-K1 2.3 DTB"
    fi
}

assert_managed_file_unchanged() {
    local path="$1"
    local checksum_file="$2"
    local label="$3"
    local expected current

    [[ -f "$checksum_file" ]] || return 0
    if [[ ! -f "$path" ]]; then
        [[ "$FORCE" = "1" ]] || die "${label} was removed after installation; inspect it or use rollback --force: ${path}"
        return 0
    fi
    expected="$(<"$checksum_file")"
    current="$(sha256_file "$path")"
    if [[ "$current" != "$expected" && "$FORCE" != "1" ]]; then
        die "${label} changed after installation; inspect it or use rollback --force: ${path}"
    fi
}

preflight_dtb_rollback() {
    local current_lines expected_hash current_hash

    [[ -e "${STATE_DIR}/dtb-managed" ]] || return 0
    [[ -f "$ARM_ENV_PATH" ]] || die "Armbian environment file not found: ${ARM_ENV_PATH}"
    current_lines="$(current_fdtfile_lines)"
    if [[ "$current_lines" != "fdtfile=${DTB_FDTFILE}" && "$FORCE" != "1" ]]; then
        die "fdtfile changed after installation; inspect ${ARM_ENV_PATH} or use rollback --force"
    fi
    if [[ -f "${STATE_DIR}/installed-dtb.sha256" ]]; then
        if [[ ! -f "$DTB_TARGET" ]]; then
            [[ "$FORCE" = "1" ]] || die "managed DTB was removed after installation; inspect it or use rollback --force"
        else
            expected_hash="$(<"${STATE_DIR}/installed-dtb.sha256")"
            current_hash="$(sha256_file "$DTB_TARGET")"
            if [[ "$current_hash" != "$expected_hash" && "$FORCE" != "1" ]]; then
                die "managed DTB changed after installation; inspect it or use rollback --force"
            fi
        fi
    fi
}

rollback_dtb() {
    [[ -e "${STATE_DIR}/dtb-managed" ]] || { log "No managed DTB selection to roll back"; return 0; }
    preflight_dtb_rollback

    replace_fdtfile_lines "${STATE_DIR}/original-fdtfile-lines"
    if [[ -e "${STATE_DIR}/original-dtb-present" ]]; then
        cp -a "${STATE_DIR}/original-v2.3.dtb" "$DTB_TARGET"
    else
        rm -f "$DTB_TARGET"
    fi
    rm -f \
        "${STATE_DIR}/dtb-managed" \
        "${STATE_DIR}/original-fdtfile-lines" \
        "${STATE_DIR}/original-v2.3.dtb" \
        "${STATE_DIR}/original-dtb-present" \
        "${STATE_DIR}/original-dtb-absent" \
        "${STATE_DIR}/installed-dtb.sha256"
    log "Restored the previous DTB selection"
    REBOOT_REQUIRED=1
}

snapshot_service_path() {
    local path="$1"
    local key="$2"

    if [[ -e "$path" || -L "$path" ]]; then
        cp -a "$path" "${STATE_DIR}/original-${key}"
        touch "${STATE_DIR}/original-${key}-present"
    else
        touch "${STATE_DIR}/original-${key}-absent"
    fi
}

install_managed_file() {
    local source="$1"
    local target="$2"
    local mode="$3"
    local checksum_file="$4"
    local target_dir tmp

    target_dir="$(dirname -- "$target")"
    mkdir -p "$target_dir"
    if [[ ! -f "$target" ]] || ! cmp -s "$source" "$target"; then
        tmp="$(mktemp "${target}.opennept4une.XXXXXX")"
        install -o 0 -g 0 -m "$mode" "$source" "$tmp"
        mv -f "$tmp" "$target"
    fi
    chown 0:0 "$target"
    chmod "$mode" "$target"
    [[ "$(stat -c '%u:%g' "$target")" = "0:0" ]] || die "managed file is not root-owned: ${target}"
    sha256_file "$target" > "$checksum_file"
}

preflight_power_service_install() {
    [[ -f "${RESOURCE_DIR}/${SERVICE_NAME}" ]] || die "toolhead power service unit is missing"
    [[ -f "${RESOURCE_DIR}/opennept4une-toolhead-power.sh" ]] || die "toolhead power helper is missing"
    [[ -f "${RESOURCE_DIR}/klipper-power-requirement.conf" ]] || die "Klipper power dependency is missing"
}

install_power_service() {
    local unit_source="${RESOURCE_DIR}/${SERVICE_NAME}"
    local helper_source="${RESOURCE_DIR}/opennept4une-toolhead-power.sh"
    local dropin_source="${RESOURCE_DIR}/klipper-power-requirement.conf"

    preflight_power_service_install
    mkdir -p "$STATE_DIR"
    if [[ ! -e "${STATE_DIR}/service-managed" ]]; then
        snapshot_service_path "$UNIT_TARGET" unit
        snapshot_service_path "$HELPER_TARGET" helper
        snapshot_service_path "$KLIPPER_DROPIN_TARGET" klipper-dropin
        snapshot_service_path "$WANTS_LINK" wants-link
        touch "${STATE_DIR}/service-managed"
    fi

    install_managed_file "$unit_source" "$UNIT_TARGET" 0644 "${STATE_DIR}/installed-unit.sha256"
    install_managed_file "$helper_source" "$HELPER_TARGET" 0755 "${STATE_DIR}/installed-helper.sha256"
    install_managed_file "$dropin_source" "$KLIPPER_DROPIN_TARGET" 0644 "${STATE_DIR}/installed-klipper-dropin.sha256"

    if is_online_root; then
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME" >/dev/null
        systemctl restart "$SERVICE_NAME"
    else
        mkdir -p "$WANTS_DIR"
        ln -sfn "../${SERVICE_NAME}" "$WANTS_LINK"
    fi
    if [[ -L "$WANTS_LINK" ]]; then
        readlink "$WANTS_LINK" > "${STATE_DIR}/installed-wants-link.target"
    fi
    log "Installed and enabled persistent GPIO82 USB-C toolhead power"
}

restore_service_path() {
    local path="$1"
    local key="$2"

    if [[ -e "${STATE_DIR}/original-${key}-present" ]]; then
        rm -f "$path"
        cp -a "${STATE_DIR}/original-${key}" "$path"
    else
        rm -f "$path"
    fi
}

rollback_power_service() {
    [[ -e "${STATE_DIR}/service-managed" ]] || { log "No managed toolhead power service to roll back"; return 0; }

    preflight_power_service_rollback

    if is_online_root; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
        rm -f "$WANTS_LINK"
    fi

    restore_service_path "$UNIT_TARGET" unit
    restore_service_path "$HELPER_TARGET" helper
    restore_service_path "$KLIPPER_DROPIN_TARGET" klipper-dropin
    restore_service_path "$WANTS_LINK" wants-link
    rmdir "$KLIPPER_DROPIN_DIR" 2>/dev/null || true

    rm -f \
        "${STATE_DIR}/service-managed" \
        "${STATE_DIR}"/original-unit* \
        "${STATE_DIR}"/original-helper* \
        "${STATE_DIR}"/original-klipper-dropin* \
        "${STATE_DIR}"/original-wants-link* \
        "${STATE_DIR}"/installed-unit.sha256 \
        "${STATE_DIR}"/installed-helper.sha256 \
        "${STATE_DIR}"/installed-klipper-dropin.sha256 \
        "${STATE_DIR}"/installed-wants-link.target

    if is_online_root; then
        systemctl daemon-reload
    fi
    log "Removed the managed GPIO82 USB-C toolhead power integration"
}

preflight_power_service_rollback() {
    local expected_link current_link

    [[ -e "${STATE_DIR}/service-managed" ]] || return 0

    assert_managed_file_unchanged "$UNIT_TARGET" "${STATE_DIR}/installed-unit.sha256" "systemd unit"
    assert_managed_file_unchanged "$HELPER_TARGET" "${STATE_DIR}/installed-helper.sha256" "GPIO helper"
    assert_managed_file_unchanged "$KLIPPER_DROPIN_TARGET" "${STATE_DIR}/installed-klipper-dropin.sha256" "Klipper drop-in"
    if [[ -f "${STATE_DIR}/installed-wants-link.target" ]]; then
        expected_link="$(<"${STATE_DIR}/installed-wants-link.target")"
        if [[ ! -L "$WANTS_LINK" ]]; then
            [[ "$FORCE" = "1" ]] || die "service enablement link was removed after installation; inspect it or use rollback --force"
        else
            current_link="$(readlink "$WANTS_LINK")"
            if [[ "$current_link" != "$expected_link" && "$FORCE" != "1" ]]; then
                die "service enablement link changed after installation; inspect it or use rollback --force"
            fi
        fi
    fi
}

show_status() {
    local selected="<none>" gpio_status="unavailable"

    if [[ -f "$ARM_ENV_PATH" ]]; then
        selected="$(current_fdtfile_lines)"
        [[ -n "$selected" ]] || selected="<default supplied by bootloader>"
    fi
    printf 'root: %s\nboot: %s\nfdtfile: %s\n' "$ROOT_DIR" "$BOOT_DIR" "$selected"
    printf 'v2.3 DTB installed: %s\n' "$([[ -f "$DTB_TARGET" ]] && echo yes || echo no)"
    printf 'DTB managed by this script: %s\n' "$([[ -e "${STATE_DIR}/dtb-managed" ]] && echo yes || echo no)"
    printf 'toolhead power service installed: %s\n' "$([[ -f "$UNIT_TARGET" ]] && echo yes || echo no)"
    printf 'toolhead power service managed by this script: %s\n' "$([[ -e "${STATE_DIR}/service-managed" ]] && echo yes || echo no)"
    if is_online_root && [[ -x "$HELPER_TARGET" ]]; then
        gpio_status="$($HELPER_TARGET status 2>&1 || true)"
    fi
    printf 'GPIO82: %s\n' "$gpio_status"
}

case "$ACTION" in
    status)
        show_status
        ;;
    rollback)
        require_write_access
        # Validate every managed artifact before changing any of them. A
        # conflict must leave both DTB and power integration untouched.
        preflight_power_service_rollback
        preflight_dtb_rollback
        rollback_power_service
        rollback_dtb
        (( REBOOT_REQUIRED == 0 )) || warn "reboot is required for the restored DTB selection to take effect"
        ;;
    apply)
        require_write_access
        (( FROM_FLAG == 0 )) || selection_from_flag
        normalize_selection
        log "Reconciling hardware for model=${MODEL}, PCB=${PCB_VERSION}, toolhead=${TOOLHEAD}"

        wants_v23=0
        wants_power=0
        [[ "$MODEL" =~ ^n4(plus|max)$ && "$PCB_VERSION" = "2.3" ]] && wants_v23=1
        [[ "$wants_v23" = "1" && "$TOOLHEAD" = "usb-c" ]] && wants_power=1

        # Preflight every rollback and every install resource before the first
        # mutation, preventing a known guard failure from producing a mixed
        # DTB/service state.
        if [[ "$wants_v23" = "1" ]]; then
            [[ ! -e "${STATE_DIR}/dtb-managed" ]] || preflight_dtb_rollback
        else
            preflight_dtb_rollback
        fi
        if [[ "$wants_power" = "1" ]]; then
            preflight_power_service_install
            [[ ! -e "${STATE_DIR}/service-managed" ]] || preflight_power_service_rollback
        else
            preflight_power_service_rollback
        fi

        if [[ "$wants_v23" = "1" ]]; then
            install_dtb
        else
            rollback_dtb
        fi

        if [[ "$wants_power" = "1" ]]; then
            install_power_service
        else
            rollback_power_service
            if [[ "$TOOLHEAD" = "usb-c" ]]; then
                warn "GPIO82 integration is currently limited to Neptune 4 Plus/Max PCB 2.3"
            fi
        fi

        (( REBOOT_REQUIRED == 0 )) || warn "reboot is required for the DTB change to take effect"
        ;;
esac
