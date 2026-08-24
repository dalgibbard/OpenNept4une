#!/bin/bash

# Paths
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OPENNEPT4UNE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
KLIPPER_DIR="${HOME}/klipper"
FIRMWARE_DIR="${HOME}/printer_data/config/Firmware"
MCU_SWFLASH_ALT="${OPENNEPT4UNE_DIR}/mcu-firmware/alt-method/mcu-swflash-run.sh"
USB_TOOLHEAD_CONFIG="${OPENNEPT4UNE_DIR}/mcu-firmware/usb_c_toolhead.config"
USB_TOOLHEAD_SERIAL_GLOB="/dev/serial/by-id/usb-Klipper_stm32f103xe_*"
USB_TOOLHEAD_BOOTLOADER_SERIAL_GLOB="/dev/serial/by-id/usb-MKS_DRIVER_BOOT_*"
USB_TOOLHEAD_BOOTLOADER_VIDPID="1d50:018a"
USB_TOOLHEAD_POWER_GPIO="82"
USB_TOOLHEAD_POWER_HELPER="/usr/local/sbin/opennept4une-toolhead-power"
N4FLASH_SOURCE="${SCRIPT_DIR}/n4flash/n4flash.c"
N4FLASH_BIN="${HOME}/.local/lib/opennept4une/n4flash"
USB_TOOLHEAD_MAX_FIRMWARE_BYTES=$((96 * 1024))
USB_TOOLHEAD_IDENTITY_DIR="${FIRMWARE_DIR}/usb-c-identities"
KLIPPER_SOURCE_PIN="${FIRMWARE_DIR}/klipper-build-source.commit"
FIRMWARE_BUILD_ARCHIVE_ROOT="${FIRMWARE_DIR}/builds"

# Helper to apply a minimal config and expand it
apply_minimal_config() {
    local config_file="$1"
    cd "$KLIPPER_DIR" || return 1
    make clean || return 1
    rm -rf out
    cp "$config_file" .config || return 1
    make olddefconfig || return 1
}

# Print exactly one persistent serial path. Never choose the first ttyACM node:
# its number is enumeration-order dependent and may belong to another MCU.
resolve_unique_serial_device() {
    local device_glob="$1"
    local description="$2"
    local -a matches=()
    local match

    while IFS= read -r match; do
        [[ -e "$match" ]] && matches+=("$match")
    done < <(compgen -G "$device_glob" | LC_ALL=C sort -u)

    case ${#matches[@]} in
        0)
            return 1
            ;;
        1)
            printf '%s\n' "${matches[0]}"
            return 0
            ;;
        *)
            echo "ERROR: Multiple ${description} devices matched ${device_glob}:" >&2
            printf '  %s\n' "${matches[@]}" >&2
            echo "Disconnect the extra device(s); no firmware was flashed." >&2
            return 2
            ;;
    esac
}

wait_for_unique_serial_device() {
    local device_glob="$1"
    local description="$2"
    local timeout_seconds="$3"
    local device
    local resolve_exit
    local second

    for ((second = 0; second < timeout_seconds; second++)); do
        if device=$(resolve_unique_serial_device "$device_glob" "$description"); then
            printf '%s\n' "$device"
            return 0
        else
            resolve_exit=$?
            [[ $resolve_exit -eq 2 ]] && return 2
        fi
        sleep 1
    done
    return 1
}

print_usb_toolhead_diagnostics() {
    echo ""
    echo "USB-C toolhead diagnostic capture:"
    echo "--- /dev/serial/by-id ---"
    ls -l /dev/serial/by-id 2>/dev/null || echo "(directory is absent)"
    echo "--- lsusb ---"
    lsusb 2>/dev/null || echo "(lsusb is unavailable)"
    echo ""
    # TODO(v2.3-hardware-validation): replace/extend the globs only after
    # capturing the production device's exact application and bootloader IDs.
    echo "If the toolhead is visible under a different ID, save this output before reporting it."
    echo "Expected application pattern: $USB_TOOLHEAD_SERIAL_GLOB"
    echo "Expected bootloader pattern: $USB_TOOLHEAD_BOOTLOADER_SERIAL_GLOB"
    echo ""
}

record_usb_toolhead_identity() {
    local device="$1"
    local mode="$2"
    local properties="${3:-}"
    local identity_file
    local resolved_device

    if [[ -z "$properties" ]]; then
        properties=$(udevadm info --query=property --name="$device" 2>/dev/null) || {
            echo "ERROR: Could not capture udev properties for $device"
            return 1
        }
    fi
    resolved_device=$(readlink -f "$device") || {
        echo "ERROR: Could not resolve persistent serial path: $device"
        return 1
    }
    mkdir -p "$USB_TOOLHEAD_IDENTITY_DIR" || return 1
    identity_file="${USB_TOOLHEAD_IDENTITY_DIR}/${mode}-udev.txt"

    if ! {
        printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'by_id=%s\n' "$device"
        printf 'resolved_device=%s\n' "$resolved_device"
        printf '%s\n' "$properties" \
            | grep -E '^(ID_VENDOR_ID|ID_MODEL_ID|ID_SERIAL|ID_SERIAL_SHORT|ID_PATH|ID_USB_INTERFACE_NUM)=' \
            || true
    } | tee "$identity_file"; then
        echo "ERROR: Could not save ${mode} identity to ${identity_file}"
        return 1
    fi
    echo "Saved ${mode} identity to ${identity_file}"
}

# Pin one Klipper source revision across the necessarily separate MCU updater
# runs. The updater never pulls implicitly: the operator deliberately updates
# Klipper once, clears this record to begin a new coordinated build set, and
# then builds each MCU from the displayed same commit.
pin_klipper_source_commit() {
    local current_commit pinned_commit temp_pin worktree_status

    current_commit=$(git -C "$KLIPPER_DIR" rev-parse --verify HEAD 2>/dev/null) || {
        echo "ERROR: Could not resolve the Klipper source commit." >&2
        return 1
    }
    [[ "$current_commit" =~ ^[0-9a-fA-F]{40}$ ]] || {
        echo "ERROR: Invalid Klipper source commit: $current_commit" >&2
        return 1
    }
    worktree_status=$(git -C "$KLIPPER_DIR" status --porcelain --untracked-files=all 2>/dev/null) || {
        echo "ERROR: Could not inspect the Klipper worktree." >&2
        return 1
    }
    if [[ -n "$worktree_status" ]]; then
        echo "ERROR: Klipper has staged, unstaged, or untracked changes; reproducible MCU builds require a clean worktree:" >&2
        printf '%s\n' "$worktree_status" >&2
        return 1
    fi

    if [[ -f "$KLIPPER_SOURCE_PIN" ]]; then
        pinned_commit=$(tr -d '[:space:]' < "$KLIPPER_SOURCE_PIN")
        if [[ "$pinned_commit" != "$current_commit" ]]; then
            echo "ERROR: Klipper is at ${current_commit}, but earlier MCU builds were pinned to ${pinned_commit}." >&2
            echo "Do not mix MCU builds. Deliberately update Klipper once, remove only ${KLIPPER_SOURCE_PIN}, then rebuild each required MCU." >&2
            return 1
        fi
    else
        mkdir -p "$(dirname -- "$KLIPPER_SOURCE_PIN")" || return 1
        temp_pin=$(mktemp "${KLIPPER_SOURCE_PIN}.XXXXXX") || return 1
        printf '%s\n' "$current_commit" > "$temp_pin"
        if ! mv -f "$temp_pin" "$KLIPPER_SOURCE_PIN"; then
            rm -f "$temp_pin"
            return 1
        fi
    fi
    echo "Klipper MCU build source pinned to: $current_commit"
}

# Preserve the exact inputs and output needed to reproduce or reflash a build.
# The timestamped directory is published only after every file and checksum has
# been written and verified. An existing archive is never replaced, including
# if two updater processes happen to choose the same name.
archive_klipper_firmware_build() (
    local target="$1"
    local firmware="$2"
    local expanded_config="${3:-${KLIPPER_DIR}/.config}"
    local current_commit pinned_commit created_utc archive_timestamp
    local firmware_size archive_name archive_dir archive_lock staging_dir=""

    case "$target" in
        main-mcu|usb-c-toolhead) ;;
        *)
            echo "ERROR: Unsupported firmware archive target: $target" >&2
            return 1
            ;;
    esac
    if [[ ! -s "$firmware" ]]; then
        echo "ERROR: Cannot archive absent or empty firmware: $firmware" >&2
        return 1
    fi
    if [[ ! -s "$expanded_config" ]]; then
        echo "ERROR: Cannot archive absent or empty expanded Klipper config: $expanded_config" >&2
        return 1
    fi
    if [[ ! -f "$KLIPPER_SOURCE_PIN" ]]; then
        echo "ERROR: Cannot archive firmware without the pinned Klipper commit: $KLIPPER_SOURCE_PIN" >&2
        return 1
    fi
    pinned_commit=$(tr -d '[:space:]' < "$KLIPPER_SOURCE_PIN") || return 1
    [[ "$pinned_commit" =~ ^[0-9a-fA-F]{40}$ ]] || {
        echo "ERROR: Invalid pinned Klipper commit: $pinned_commit" >&2
        return 1
    }
    current_commit=$(git -C "$KLIPPER_DIR" rev-parse --verify HEAD 2>/dev/null) || {
        echo "ERROR: Could not resolve the Klipper source commit for archival." >&2
        return 1
    }
    if [[ "$current_commit" != "$pinned_commit" ]]; then
        echo "ERROR: Refusing to archive ${target}: Klipper HEAD ${current_commit} does not match pinned commit ${pinned_commit}." >&2
        return 1
    fi
    command -v sha256sum >/dev/null 2>&1 || {
        echo "ERROR: sha256sum is required to archive firmware builds." >&2
        return 1
    }

    created_utc="${OPENNEPT4UNE_BUILD_ARCHIVE_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    if [[ ! "$created_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        echo "ERROR: Invalid UTC firmware archive timestamp: $created_utc" >&2
        return 1
    fi
    archive_timestamp="${created_utc//[-:]/}"
    archive_name="${archive_timestamp}-${target}-${pinned_commit:0:12}"
    archive_dir="${FIRMWARE_BUILD_ARCHIVE_ROOT}/${archive_name}"
    archive_lock="${archive_dir}.lock"
    firmware_size=$(stat -c '%s' "$firmware") || return 1

    mkdir -p "$FIRMWARE_BUILD_ARCHIVE_ROOT" || {
        echo "ERROR: Could not create firmware build archive root: $FIRMWARE_BUILD_ARCHIVE_ROOT" >&2
        return 1
    }
    if [[ -e "$archive_dir" ]]; then
        echo "ERROR: Firmware build archive already exists; refusing to overwrite it: $archive_dir" >&2
        return 1
    fi
    if ! mkdir "$archive_lock"; then
        echo "ERROR: Firmware build archive is already being created: $archive_dir" >&2
        return 1
    fi

    cleanup_firmware_archive() {
        if [[ -n "$staging_dir" && -d "$staging_dir" ]]; then
            rm -rf -- "$staging_dir"
        fi
        rmdir "$archive_lock" 2>/dev/null || true
    }
    trap cleanup_firmware_archive EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    staging_dir=$(mktemp -d "${FIRMWARE_BUILD_ARCHIVE_ROOT}/.${archive_name}.tmp.XXXXXX") || {
        echo "ERROR: Could not create a staging directory for the firmware archive." >&2
        return 1
    }
    chmod 0755 "$staging_dir" || return 1
    cp -- "$firmware" "${staging_dir}/klipper.bin" || return 1
    cp -- "$expanded_config" "${staging_dir}/klipper.config" || return 1
    printf '%s\n' "$pinned_commit" > "${staging_dir}/klipper-source.commit" || return 1
    chmod 0644 \
        "${staging_dir}/klipper.bin" \
        "${staging_dir}/klipper.config" \
        "${staging_dir}/klipper-source.commit" || return 1

    if ! {
        printf 'archive_schema=1\n'
        printf 'target=%s\n' "$target"
        printf 'created_utc=%s\n' "$created_utc"
        printf 'klipper_commit=%s\n' "$pinned_commit"
        printf 'firmware_bytes=%s\n' "$firmware_size"
        printf 'firmware_filename=klipper.bin\n'
        printf 'config_filename=klipper.config\n'
        printf 'commit_filename=klipper-source.commit\n'
    } > "${staging_dir}/build-metadata.txt"; then
        echo "ERROR: Could not write firmware build metadata." >&2
        return 1
    fi
    chmod 0644 "${staging_dir}/build-metadata.txt" || return 1

    if ! (
        cd "$staging_dir" || exit 1
        sha256sum \
            klipper.bin \
            klipper.config \
            klipper-source.commit \
            build-metadata.txt > SHA256SUMS &&
            sha256sum --check --strict SHA256SUMS >/dev/null
    ); then
        echo "ERROR: Could not create and verify firmware build checksums." >&2
        return 1
    fi
    chmod 0644 "${staging_dir}/SHA256SUMS" || return 1

    # GNU mv's no-clobber mode can return success after skipping an existing
    # destination, so also require the staging directory to have disappeared.
    if ! mv -T --no-clobber "$staging_dir" "$archive_dir" || [[ -d "$staging_dir" ]]; then
        echo "ERROR: Could not publish firmware archive without overwriting an existing path: $archive_dir" >&2
        return 1
    fi
    staging_dir=""
    rmdir "$archive_lock" || {
        echo "ERROR: Firmware archive was created, but its creation lock could not be removed: $archive_lock" >&2
        return 1
    }
    trap - EXIT INT TERM

    echo "Archived ${target} firmware build: $archive_dir"
)

validate_usb_toolhead_bootloader() {
    local device="$1"
    local properties

    case "$device" in
        /dev/serial/by-id/usb-MKS_DRIVER_BOOT_*) ;;
        *)
            echo "ERROR: Refusing non-persistent or unexpected bootloader path: $device"
            return 1
            ;;
    esac

    if ! command -v udevadm >/dev/null 2>&1; then
        echo "ERROR: udevadm is required to validate the USB-C bootloader."
        return 1
    fi

    properties=$(udevadm info --query=property --name="$device" 2>/dev/null) || {
        echo "ERROR: Could not read udev properties for $device"
        return 1
    }
    if ! grep -q '^ID_VENDOR_ID=1d50$' <<<"$properties" ||
       ! grep -q '^ID_MODEL_ID=018a$' <<<"$properties"; then
        echo "ERROR: $device is not the expected $USB_TOOLHEAD_BOOTLOADER_VIDPID bootloader."
        echo "No firmware was flashed."
        return 1
    fi
    record_usb_toolhead_identity "$device" "bootloader" "$properties"
}

ensure_n4flash() {
    local compiler
    local output_dir
    local temp_bin

    if [[ ! -r "$N4FLASH_SOURCE" ]]; then
        echo "ERROR: Audited n4flash source is missing: $N4FLASH_SOURCE"
        return 1
    fi

    if [[ -x "$N4FLASH_BIN" && "$N4FLASH_BIN" -nt "$N4FLASH_SOURCE" ]]; then
        return 0
    fi

    compiler=$(command -v cc || command -v gcc) || {
        echo "ERROR: A C compiler is required to build the bundled n4flash utility."
        echo "Install build-essential, then retry."
        return 1
    }
    output_dir=$(dirname "$N4FLASH_BIN")
    mkdir -p "$output_dir" || return 1
    temp_bin=$(mktemp "${output_dir}/n4flash.XXXXXX") || return 1

    echo "Building the bundled n4flash utility..."
    if ! "$compiler" -O2 -Wall -Wextra -o "$temp_bin" "$N4FLASH_SOURCE"; then
        rm -f "$temp_bin"
        echo "ERROR: Failed to build n4flash."
        return 1
    fi
    chmod 0755 "$temp_bin" || {
        rm -f "$temp_bin"
        return 1
    }
    mv -f "$temp_bin" "$N4FLASH_BIN" || {
        rm -f "$temp_bin"
        return 1
    }
}

validate_usb_toolhead_firmware() {
    local firmware="$1"
    local firmware_size

    if [[ ! -s "$firmware" ]]; then
        echo "ERROR: USB-C toolhead firmware is absent or empty: $firmware"
        return 1
    fi
    firmware_size=$(stat -c '%s' "$firmware") || return 1
    if (( firmware_size > USB_TOOLHEAD_MAX_FIRMWARE_BYTES )); then
        echo "ERROR: Toolhead firmware is ${firmware_size} bytes; the application region is only ${USB_TOOLHEAD_MAX_FIRMWARE_BYTES} bytes."
        echo "Refusing to flash."
        return 1
    fi
    echo "Validated USB-C toolhead firmware size: ${firmware_size} bytes."
}

is_znp_k1_v23() {
    [[ -r /boot/.OpenNept4une.txt ]] &&
        grep -Eiq '^N4(plus|max)-v2\.3([[:space:]-]|$)' /boot/.OpenNept4une.txt
}

print_usb_toolhead_id_hint() {
    local toolhead_id
    local resolve_exit

    echo "Waiting for USB-C toolhead to reconnect..."
    for _ in {1..30}; do
        if toolhead_id=$(resolve_unique_serial_device "$USB_TOOLHEAD_SERIAL_GLOB" "USB-C toolhead application"); then
            echo ""
            echo "USB-C toolhead serial ID:"
            echo "$toolhead_id"
            echo ""
            if ! record_usb_toolhead_identity "$toolhead_id" "application"; then
                echo "Failed to record the USB-C toolhead application identity."
                return 1
            fi
            if python3 "${OPENNEPT4UNE_DIR}/printer-confs/generate_conf.py" --write-mcu-id; then
                echo "Updated ${HOME}/printer_data/config/MCU_ID.cfg"
            else
                echo "Failed to update MCU_ID.cfg automatically. Add/update it manually:"
                echo ""
                echo "${HOME}/printer_data/config/MCU_ID.cfg"
                echo ""
                echo "[mcu THR]"
                echo "serial: $toolhead_id"
                echo "restart_method: command"
                return 1
            fi
            echo ""
            return 0
        else
            resolve_exit=$?
            [[ $resolve_exit -eq 2 ]] && return 1
        fi
        sleep 1
    done

    echo ""
    echo "USB-C toolhead did not reconnect as a Klipper serial device yet."
    echo "After reboot, check with:"
    echo "ls /dev/serial/by-id/usb-Klipper_stm32f103xe_*"
    echo "Then run OpenNept4une.sh -> Install/Update printer.cfg to regenerate MCU_ID.cfg."
    echo ""
    return 1
}

# Request USB serial bootloader entry via 1200 baud + DTR pulse
request_usb_bootloader_dtr() {
    local device="$1"

    python3 - "$device" <<'PY'
import sys, fcntl, termios, struct, time

dev = sys.argv[1]
with open(dev, "rb", buffering=0) as f:
    fd = f.fileno()
    fcntl.ioctl(fd, termios.TIOCMBIS, struct.pack("I", termios.TIOCM_DTR))
    attrs = termios.tcgetattr(fd)
    attrs[4] = termios.B1200
    attrs[5] = termios.B1200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    time.sleep(0.2)
    fcntl.ioctl(fd, termios.TIOCMBIC, struct.pack("I", termios.TIOCM_DTR))
PY
}

# ZNP-K1-2.3 Plus/Max boards switch toolhead USB power through legacy sysfs
# GPIO 82. Export it on demand, explicitly drive it high, then power-cycle it.
# This path is deliberately selected only for a persisted v2.3 model or after
# an explicit interactive choice; GPIO numbering is board/image specific.
request_usb_bootloader_gpio82() {
    local gpio_root="${OPENNEPT4UNE_GPIO_ROOT:-/sys/class/gpio}"
    local gpio_dir="${gpio_root}/gpio${USB_TOOLHEAD_POWER_GPIO}"
    local value

    if [[ -x "$USB_TOOLHEAD_POWER_HELPER" ]]; then
        echo "Power-cycling the USB-C toolhead with $USB_TOOLHEAD_POWER_HELPER..."
        sudo "$USB_TOOLHEAD_POWER_HELPER" cycle 0.5 || {
            echo "ERROR: The installed toolhead-power helper failed."
            return 1
        }
        return 0
    fi

    # Contain the fallback's traps in a subshell so they cannot overwrite the
    # caller's Klipper-service restoration trap. EXIT/INT/TERM always make a
    # best-effort high write after the rail has been armed for a low pulse.
    (
    local restore_high_required=0
    restore_gpio_high() {
        if [[ "$restore_high_required" = "1" ]]; then
            if ! printf '1\n' | sudo tee "$gpio_dir/value" >/dev/null; then
                echo "CRITICAL: Could not restore GPIO ${USB_TOOLHEAD_POWER_GPIO} high from the safety trap." >&2
                echo "Power off the printer before investigating the toolhead power circuit." >&2
            fi
        fi
    }
    trap restore_gpio_high EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ ! -d "$gpio_dir" ]]; then
        if [[ ! -e "${gpio_root}/export" ]]; then
            echo "ERROR: /sys/class/gpio/export is unavailable; cannot control GPIO ${USB_TOOLHEAD_POWER_GPIO}."
            return 1
        fi
        echo "Exporting toolhead-power GPIO ${USB_TOOLHEAD_POWER_GPIO}..."
        if ! printf '%s\n' "$USB_TOOLHEAD_POWER_GPIO" | sudo tee "${gpio_root}/export" >/dev/null; then
            sleep 1
            if [[ ! -d "$gpio_dir" ]]; then
                echo "ERROR: Could not export GPIO ${USB_TOOLHEAD_POWER_GPIO}."
                return 1
            fi
        fi
        for _ in {1..20}; do
            [[ -e "$gpio_dir/value" ]] && break
            sleep 0.1
        done
    fi

    if [[ ! -e "$gpio_dir/direction" || ! -e "$gpio_dir/value" ]]; then
        echo "ERROR: GPIO ${USB_TOOLHEAD_POWER_GPIO} does not expose direction/value controls."
        return 1
    fi

    # "high" sets direction and value atomically, avoiding an unintended low
    # pulse before the controlled power cycle begins.
    if ! printf 'high\n' | sudo tee "$gpio_dir/direction" >/dev/null; then
        echo "ERROR: Could not configure GPIO ${USB_TOOLHEAD_POWER_GPIO} as a high output."
        return 1
    fi

    echo "Power-cycling the USB-C toolhead through GPIO ${USB_TOOLHEAD_POWER_GPIO}..."
    restore_high_required=1
    if ! printf '0\n' | sudo tee "$gpio_dir/value" >/dev/null; then
        echo "ERROR: Could not drive GPIO ${USB_TOOLHEAD_POWER_GPIO} low."
        return 1
    fi
    sleep 0.5
    if ! printf '1\n' | sudo tee "$gpio_dir/value" >/dev/null; then
        echo "CRITICAL: Could not restore GPIO ${USB_TOOLHEAD_POWER_GPIO} high."
        echo "Power off the printer before investigating the toolhead power circuit."
        return 1
    fi
    sleep 0.2
    value=$(<"$gpio_dir/value")
    if [[ "$value" != "1" ]]; then
        echo "CRITICAL: GPIO ${USB_TOOLHEAD_POWER_GPIO} did not read back high (read '$value')."
        echo "Power off the printer before investigating the toolhead power circuit."
        return 1
    fi
    restore_high_required=0
    trap - EXIT INT TERM
    )
}

# Permit hardware-independent tests to load the validation/resolver helpers
# without updating Klipper or presenting the interactive firmware menu.
if [[ "${OPENNEPT4UNE_RPI_MCU_INSTALL_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Get current git branch from $KLIPPER_DIR
cd "$KLIPPER_DIR" || exit 1
current_branch=$(git rev-parse --abbrev-ref HEAD)

if [[ "$current_branch" == "HEAD" ]]; then
    echo "Warning: Detached HEAD state detected!"
    sleep 30
    exit 1
fi

# Prompt user for MCU if not passed as argument
if [[ -z $1 ]]; then
    echo ""
    echo "Choose one MCU to update:"
    echo ""
    select mcu_choice in "STM32" "USB-C Toolhead" "Virtual RPi" "Pico-based USB Accelerometer" "Cancel"; do
        case $mcu_choice in
            STM32 ) break;;
            USB-C\ Toolhead ) break;;
            Virtual\ RPi ) break;;
            Pico-based\ USB\ Accelerometer ) break;;
            Cancel ) echo "Update canceled."; exit;;
        esac
    done
else
    mcu_choice=$1
fi

case "$mcu_choice" in
    STM32|USB-C\ Toolhead|Virtual\ RPi|Pico-based\ USB\ Accelerometer) ;;
    All)
        echo "ERROR: The mixed 'All' firmware update is disabled for safety."
        echo "Update exactly one target per run so each MCU can reconnect and be verified."
        exit 2
        ;;
    *)
        echo "ERROR: Unknown MCU target: $mcu_choice"
        exit 2
        ;;
esac

# Never pull between individual MCU runs. Pin the already checked-out Klipper
# commit so main, toolhead, and virtual MCUs cannot silently use different
# protocol revisions.
pin_klipper_source_commit || exit 1
cd "$KLIPPER_DIR" || exit 1

### STM32 MCU UPDATE ###
if [[ "$mcu_choice" == "STM32" ]]; then
    clear
    echo "Proceeding with STM32 MCU Update..."
    echo "Main-controller serial flashing is intentionally not offered here."
    echo "Use the microSD workflow (or the already-installed alternative method) for recovery safety."

    apply_minimal_config "${OPENNEPT4UNE_DIR}/mcu-firmware/mcu.config" || {
        echo "Failed to configure main MCU firmware."
        exit 1
    }
    make || {
        echo "Failed to build main MCU firmware."
        exit 1
    }
    archive_klipper_firmware_build \
        "main-mcu" \
        "${KLIPPER_DIR}/out/klipper.bin" \
        "${KLIPPER_DIR}/.config" || {
        echo "ERROR: Main-MCU build archival failed; refusing to stage or flash firmware."
        exit 1
    }

    if grep -q "/usr/local/bin/gpio_set.sh" "/etc/rc.local" 2>/dev/null; then
        echo "Detected MCU running the Alternative method! Running headless flash..."
        if [ -f "$MCU_SWFLASH_ALT" ]; then
            "$MCU_SWFLASH_ALT" || {
                echo "Error: Alternate MCU flash failed."
                exit 1
            }
        else
            echo "Error: Alternate MCU flash script not found."
            exit 1
        fi
    else
        mkdir -p "$FIRMWARE_DIR" || { echo "Failed to create firmware directory."; exit 1; }
        rm -f "$FIRMWARE_DIR/X_4.bin" "$FIRMWARE_DIR/elegoo_k1.bin" || {
            echo "Failed to remove stale main-MCU firmware files."
            exit 1
        }
        cp "$KLIPPER_DIR/out/klipper.bin" "$FIRMWARE_DIR/X_4.bin" || {
            echo "Failed to stage X_4.bin."
            exit 1
        }
        cp "$KLIPPER_DIR/out/klipper.bin" "$FIRMWARE_DIR/elegoo_k1.bin" || {
            echo "Failed to stage elegoo_k1.bin."
            exit 1
        }

        clear
        ip_address=$(hostname -I | awk '{print $1}')
        echo ""
        echo -e "\nTo download firmware files:"
        echo "1. Visit: http://$ip_address/#/configure"
        echo "2. Click the Firmware folder"
        echo "3. Download 'X_4.bin' and 'elegoo_k1.bin'"
        echo ""
        echo -e "\nTo complete the update:"
        echo "1. Power off the printer and insert the microSD card."
        echo "2. Power on the printer to flash."
        echo "3. Check Fluidd for version confirmation."
        echo ""
        echo -e "For internal MCUs, see the wiki:"
        echo "https://github.com/OpenNeptune3D/OpenNept4une/wiki"
        echo ""

        echo -e "\nHave you downloaded the bin files and are ready to continue? (y)"
        read continue_choice
        if [[ "$continue_choice" =~ ^[Yy]$ ]]; then
            echo "Power-off the machine and insert the microSD card."
            sleep 4
            exit
        fi
    fi
fi

### USB-C TOOLHEAD MCU ###
if [[ "$mcu_choice" == "USB-C Toolhead" ]]; then
    toolhead_firmware="${KLIPPER_DIR}/out/klipper.bin"
    toolhead_device=""
    bootloader_device=""
    boot_method=""
    resolve_exit=0
    klipper_was_active=false
    klipper_state=""

    clear
    echo "Proceeding with USB-C Toolhead MCU Update..."
    echo "This updater is for the separate USB-C toolhead MCU, not the STM32 main controller."
    echo ""

    echo "Building USB-C toolhead firmware..."
    apply_minimal_config "$USB_TOOLHEAD_CONFIG" || {
        echo "Failed to configure USB-C toolhead firmware."
        exit 1
    }
    # The GD32F303-compatible controller needs Cortex-M4 instructions while
    # retaining Klipper's STM32F103xE firmware layout.
    make 'MCU_UPPER=STM32F103xE -mcpu=cortex-m4' || {
        echo "Failed to build USB-C toolhead firmware."
        exit 1
    }
    validate_usb_toolhead_firmware "$toolhead_firmware" || exit 1
    archive_klipper_firmware_build \
        "usb-c-toolhead" \
        "$toolhead_firmware" \
        "${KLIPPER_DIR}/.config" || {
        echo "ERROR: USB-C toolhead build archival failed; refusing to flash firmware."
        exit 1
    }
    ensure_n4flash || exit 1

    echo ""
    echo "WARNING: Once n4flash starts, the toolhead application is erased before data transfer."
    echo "Do not disconnect USB-C or remove printer power until it reports '> done'."
    read -r -p "Type FLASH to continue: " flash_confirmation
    if [[ "$flash_confirmation" != "FLASH" ]]; then
        echo "USB-C toolhead update canceled; no firmware was flashed."
        exit 0
    fi

    while true; do
        if bootloader_device=$(resolve_unique_serial_device "$USB_TOOLHEAD_BOOTLOADER_SERIAL_GLOB" "USB-C toolhead bootloader"); then
            boot_method="already"
            echo "USB-C toolhead bootloader detected: $bootloader_device"
            break
        else
            resolve_exit=$?
            [[ $resolve_exit -eq 2 ]] && exit 1
        fi

        if toolhead_device=$(resolve_unique_serial_device "$USB_TOOLHEAD_SERIAL_GLOB" "USB-C toolhead application"); then
            echo "USB-C toolhead application detected: $toolhead_device"
            if is_znp_k1_v23; then
                boot_method="gpio82"
                echo "Persisted ZNP-K1-2.3 model detected; GPIO82 power-cycle will enter its bootloader."
            else
                echo "The persisted printer model does not identify a ZNP-K1-2.3 Plus/Max board."
                echo "Choose the bootloader method for this hardware:"
                select method_choice in "GPIO82 power-cycle (ZNP-K1-2.3 Plus/Max only)" "1200-baud DTR request" "Cancel"; do
                    case "$REPLY" in
                        1) boot_method="gpio82"; break ;;
                        2) boot_method="dtr"; break ;;
                        3) echo "USB-C toolhead update canceled."; exit 0 ;;
                        *) echo "Invalid selection." ;;
                    esac
                done
            fi
            break
        else
            resolve_exit=$?
            [[ $resolve_exit -eq 2 ]] && exit 1
        fi

        print_usb_toolhead_diagnostics
        if is_znp_k1_v23; then
            echo "No known application ID is present, but the persisted model is ZNP-K1-2.3."
            read -r -n 1 -p "Press (g) to try its GPIO82 bootloader, (r) to rescan, or (s) to stop: " key
        else
            read -r -n 1 -p "Press (r) to rescan, (g) for ZNP-K1-2.3 GPIO82, or (s) to stop: " key
        fi
        echo ""
        case "$key" in
            g|G) boot_method="gpio82"; break ;;
            s|S) echo "USB-C toolhead update canceled."; exit 0 ;;
            *) ;;
        esac
    done

    klipper_state=$(sudo systemctl is-active klipper 2>/dev/null || true)
    case "$klipper_state" in
        active)
            klipper_was_active=true
            echo "Stopping Klipper..."
            sudo service klipper stop || {
                echo "ERROR: Klipper did not stop; no firmware was flashed."
                exit 1
            }
            ;;
        inactive|failed) ;;
        *)
            echo "ERROR: Could not establish a safe Klipper service state (reported '${klipper_state:-unknown}')."
            echo "No firmware was flashed."
            exit 1
            ;;
    esac

    restore_klipper_service() {
        local require_success="${1:-false}"
        if [[ "$klipper_was_active" == true ]]; then
            if ! sudo service klipper start; then
                echo "ERROR: Could not restore the Klipper service." >&2
                [[ "$require_success" = "true" ]] && return 1
                return 0
            fi
            klipper_was_active=false
        fi
    }
    trap restore_klipper_service EXIT
    trap 'restore_klipper_service; exit 130' INT TERM

    case "$boot_method" in
        gpio82)
            request_usb_bootloader_gpio82 || {
                print_usb_toolhead_diagnostics
                exit 1
            }
            ;;
        dtr)
            if [[ -z "$toolhead_device" || ! -e "$toolhead_device" ]]; then
                echo "ERROR: The application serial path disappeared before the DTR request."
                exit 1
            fi
            echo "Requesting USB-C toolhead bootloader through $toolhead_device..."
            request_usb_bootloader_dtr "$toolhead_device" || {
                echo "ERROR: The 1200-baud DTR bootloader request failed."
                exit 1
            }
            ;;
        already) ;;
        *)
            echo "ERROR: No USB-C bootloader method was selected."
            exit 1
            ;;
    esac

    echo "Waiting for persistent USB-C bootloader path $USB_TOOLHEAD_BOOTLOADER_SERIAL_GLOB..."
    if ! bootloader_device=$(wait_for_unique_serial_device "$USB_TOOLHEAD_BOOTLOADER_SERIAL_GLOB" "USB-C toolhead bootloader" 10); then
        echo "ERROR: USB-C bootloader path did not appear uniquely; no firmware was flashed."
        print_usb_toolhead_diagnostics
        exit 1
    fi
    validate_usb_toolhead_bootloader "$bootloader_device" || exit 1

    echo "Flashing USB-C toolhead through $bootloader_device..."
    if ! "$N4FLASH_BIN" "$toolhead_firmware" "$bootloader_device"; then
        echo "ERROR: USB-C toolhead flashing failed. Its application may now be erased."
        echo "Keep the printer powered and rerun this updater; the bootloader should remain available."
        exit 1
    fi

    echo "Firmware transfer completed; verifying application re-enumeration..."
    if ! print_usb_toolhead_id_hint; then
        print_usb_toolhead_diagnostics
        echo "ERROR: Firmware transfer finished, but the Klipper application did not verify."
        echo "The updater will not report success until one persistent application ID is present and MCU_ID.cfg is written."
        exit 1
    fi
    if ! restore_klipper_service true; then
        echo "ERROR: Firmware verified, but Klipper could not be restarted; not reporting full updater success." >&2
        exit 1
    fi
    trap - EXIT INT TERM
    echo "USB-C toolhead update completed and verified."
    sleep 2
fi

### PICO USB ACCELEROMETER ###
pico_skipped=false
if [[ "$mcu_choice" == "Pico-based USB Accelerometer" ]]; then
    clear
    echo "Proceeding with Pico-based USB Accelerometer Update..."

    while true; do
        pico_bootloader=$(lsusb | grep '2e8a:0003' 2>/dev/null)
        if [[ -z "$pico_bootloader" ]]; then
            echo ""
            read -n 1 -p "Please put your Pico in bootloader mode. Press any key to retry, or (s) to skip..." key
            if [[ $key == s || $key == S ]]; then
                pico_skipped=true
                clear
                break
            fi
        else
            echo ""
            echo "Pico detected in bootloader mode. Proceeding..."
            break
        fi
    done

    if [[ "$pico_skipped" == false ]]; then
        echo "Installing Python packages for Pico..."
        for pkg in python3-numpy python3-matplotlib libatlas3-base libopenblas-dev; do
            if ! sudo apt install -y "$pkg"; then
                echo "Failed to install required package: $pkg"
                exit 1
            fi
        done

        echo "Installing numpy in Klipper environment..."
        ~/klippy-env/bin/pip install numpy || { echo "Failed to install numpy."; exit 1; }

        apply_minimal_config "${OPENNEPT4UNE_DIR}/mcu-firmware/pico_usb.config" || {
            echo "Failed to configure Pico firmware."
            exit 1
        }
        make || { echo "Failed to build Pico firmware."; exit 1; }
        make flash FLASH_DEVICE=2e8a:0003 || { echo "Failed to flash Pico firmware."; exit 1; }

        echo ""
        echo "Pico-based Accelerometer update completed."
        sleep 2
    fi
fi

### VIRTUAL RPi MCU ###
if [[ "$mcu_choice" == "Virtual RPi" ]]; then
    virtual_klipper_was_active=false
    virtual_klipper_state=""

    clear
    echo "Proceeding with Virtual MCU RPi Update..."

    echo "Installing required packages (this may take a moment)..."
    for pkg in python3-numpy python3-matplotlib libatlas3-base libopenblas-dev; do
        echo "Installing $pkg..."
        if ! sudo apt install -y "$pkg"; then
            echo "Failed to install required package: $pkg." >&2
            exit 1
        fi
    done
    echo "Package installation complete."

    echo "Installing numpy in Klipper environment..."
    ~/klippy-env/bin/pip install numpy || { echo "Numpy installation failed."; exit 1; }

    echo "Copying klipper-mcu.service..."
    sudo cp ./scripts/klipper-mcu.service /etc/systemd/system/ || { echo "Failed to copy service file"; exit 1; }

    echo "Enabling klipper-mcu.service..."
    sudo systemctl enable klipper-mcu.service || { echo "Failed to enable service"; exit 1; }

    virtual_klipper_state=$(sudo systemctl is-active klipper 2>/dev/null || true)
    case "$virtual_klipper_state" in
        active)
            echo "Stopping klipper service..."
            sudo service klipper stop || { echo "Failed to stop Klipper; refusing to flash Virtual MCU."; exit 1; }
            virtual_klipper_was_active=true
            ;;
        inactive|failed) ;;
        *) echo "Could not establish Klipper service state (${virtual_klipper_state:-unknown}); refusing to flash Virtual MCU."; exit 1 ;;
    esac
    restore_virtual_klipper_service() {
        local require_success="${1:-false}"
        if [[ "$virtual_klipper_was_active" == true ]]; then
            if ! sudo service klipper start; then
                echo "ERROR: Could not restore the Klipper service." >&2
                [[ "$require_success" = "true" ]] && return 1
                return 0
            fi
            virtual_klipper_was_active=false
        fi
    }
    trap restore_virtual_klipper_service EXIT
    trap 'restore_virtual_klipper_service; exit 130' INT TERM

    if [[ -f /boot/.OpenNept4une.txt ]]; then
        if grep -iq "mks" /boot/.OpenNept4une.txt; then
            echo "Skipping kernel patch for MKS systems..."
        elif grep -Eqi "dec 11|oct 12" /boot/.OpenNept4une.txt; then
            echo "Applying kernel patch..."
            echo "kernel.sched_rt_runtime_us = -1" | sudo tee -a /etc/sysctl.d/10-disable-rt-group-limit.conf || {
                echo "Failed to persist the required kernel setting."
                exit 1
            }
        fi
    fi

    echo "Applying Virtual MCU configuration..."
    apply_minimal_config "${OPENNEPT4UNE_DIR}/mcu-firmware/virtualmcu.config" || {
        echo "Failed to configure Virtual MCU firmware."
        exit 1
    }

    echo "Flashing Virtual MCU..."
    make flash || { echo "Failed to flash Virtual MCU"; exit 1; }

    if ! restore_virtual_klipper_service true; then
        echo "ERROR: Virtual MCU flashed, but Klipper could not be restarted; reboot is blocked." >&2
        exit 1
    fi
    trap - EXIT INT TERM

    echo ""
    echo "Virtual MCU update completed."
    sleep 2

    countdown=20
    echo "Rebooting in $countdown seconds..."
    while [ $countdown -gt 0 ]; do
        echo "$countdown..."
        sleep 1
        countdown=$((countdown - 1))
    done
    sudo reboot
fi
