#!/bin/bash
# Script location $HOME/OpenNept4une/img-config/set-printer-model.sh

# Define the flag file path
FLAG_FILE="${OPENNEPT4UNE_FLAG_FILE:-/boot/.OpenNept4une.txt}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BOARD_HARDWARE_SETUP="${BOARD_HARDWARE_SETUP:-${SCRIPT_DIR}/board-hardware-setup.sh}"
REPO_UTILS="${SCRIPT_DIR}/repo-utils.sh"

if [[ ! -r "$REPO_UTILS" ]]; then
    echo "ERROR: Model flag utility is missing: $REPO_UTILS" >&2
    exit 1
fi
# shellcheck source=repo-utils.sh
source "$REPO_UTILS"

model_key="${model_key:-}"
motor_current="${motor_current:-}"
pcb_version="${pcb_version:-}"
toolhead_variant="${toolhead_variant:-}"
auto_yes="${auto_yes:-false}"

# Check whether a USB-C Klipper toolhead MCU is currently connected
usb_c_toolhead_detected() {
    compgen -G "/dev/serial/by-id/usb-Klipper_stm32f103xe_*" > /dev/null
}

# Function to select an option
select_option() {
    local -n ref=$1
    echo -e "$2"
    select opt in "${@:3}"; do
        if [[ -n $opt ]]; then
            ref=$opt
            break
        else
            echo -e "Invalid option, please try again."
        fi
    done
}

# Normalize explicitly supplied values before deciding which missing fields to
# ask for. A supplied --printer_model must never be overwritten by the menu.
model_key="${model_key,,}"
pcb_version="${pcb_version#v}"
case "$toolhead_variant" in
    usb-c|usbc) toolhead_variant="usb-c" ;;
    ribbon|"") ;;
    *) echo "ERROR: Unsupported toolhead: $toolhead_variant" >&2; exit 1 ;;
esac

if [ "$auto_yes" != "true" ]; then
    # Interactive model selection is only needed when the caller did not
    # already provide --printer_model.
    if [ -z "$model_key" ]; then
        echo "Please select your printer model:"
        select _ in "Neptune4" "Neptune4 Pro" "Neptune4 Plus" "Neptune4 Max"; do
            case $REPLY in
                1) model_key="n4";;
                2) model_key="n4pro";;
                3) model_key="n4plus";;
                4) model_key="n4max";;
                *) echo "Invalid selection. Please try again."; continue;;
            esac
            break
        done
    fi

    # Interactive mode for motor current and PCB version if applicable
    if [[ "$model_key" = "n4" || "$model_key" = "n4pro" ]]; then
        [ -z "$motor_current" ] && select_option motor_current "Select the stepper motor current:" "0.8" "1.2"
        [ -z "$pcb_version" ] && select_option pcb_version "Select the PCB version:" "1.0" "1.1" "1.4"
    else
        [ -z "$pcb_version" ] && select_option pcb_version "Select the PCB version:" "2.0" "2.3"
    fi

    # Interactive selection of printhead/toolhead variant (applies to all models)
    if [ -z "$toolhead_variant" ]; then
        select_option toolhead_variant "Select your printhead/toolhead type:" "Ribbon-cable printhead (original)" "USB-C Klipper printhead (separate toolhead MCU)"
        case "$toolhead_variant" in
            "USB-C Klipper printhead (separate toolhead MCU)")
                toolhead_variant="usb-c"
                if ! usb_c_toolhead_detected; then
                    echo -e "WARNING: The USB-C toolhead does not yet expose a Klipper serial ID. The physical selection will be saved so board power and firmware setup can happen first."
                fi
                ;;
            *)
                toolhead_variant="ribbon"
                ;;
        esac
    fi
else
    [[ -n "$model_key" ]] || { echo "Headless mode requires --printer_model." >&2; exit 1; }
    [[ -n "$pcb_version" ]] || { echo "Headless mode requires --pcb_version." >&2; exit 1; }
    if [[ "$model_key" = "n4" || "$model_key" = "n4pro" ]]; then
        [[ -n "$motor_current" ]] || { echo "Headless mode for n4 and n4pro requires --motor_current." >&2; exit 1; }
    fi
fi

# Validate only hardware tuples exposed by the supported selection menus. This
# prevents a typo such as 2.30 from silently undoing the v2.3 boot integration.
case "$model_key" in
    n4|n4pro)
        case "$motor_current" in 0.8|1.2) ;; *) echo "ERROR: Unsupported motor current '$motor_current' for $model_key." >&2; exit 1 ;; esac
        case "$pcb_version" in 1.0|1.1|1.4) ;; *) echo "ERROR: Unsupported PCB version '$pcb_version' for $model_key." >&2; exit 1 ;; esac
        ;;
    n4plus|n4max)
        case "$pcb_version" in 2.0|2.3) ;; *) echo "ERROR: Unsupported PCB version '$pcb_version' for $model_key." >&2; exit 1 ;; esac
        ;;
    *)
        echo "ERROR: Unsupported printer model '${model_key:-<empty>}'." >&2
        exit 1
        ;;
esac

# Preserve the historical headless default when --toolhead was omitted.
[[ -n "$toolhead_variant" ]] || toolhead_variant="ribbon"

# Persist the physical USB-C selection even before Klipper firmware is present.
# Printer configuration generation performs its own runtime MCU check later.
if [ "$toolhead_variant" = "usb-c" ] && ! usb_c_toolhead_detected; then
    echo "WARNING: No USB-C Klipper toolhead serial ID is present yet (expected /dev/serial/by-id/usb-Klipper_stm32f103xe_*)."
fi

# Define FLAG_LINE before generating configuration
if [[ "$model_key" = "n4" || "$model_key" = "n4pro" ]]; then
    FLAG_LINE="${model_key}-${motor_current}A-v${pcb_version}"
else
    [ -z "$pcb_version" ] && pcb_version="2.0"
    FLAG_LINE="${model_key}-v${pcb_version}"
fi

# Capitalize the 1st and 3rd letters of the model_key
FLAG_LINE=$(echo "$FLAG_LINE" | sed -E 's/^(n)(4)(.)(.*)/\U\1\2\3\E\4/')

# Append the toolhead variant ("ribbon" or "usb-c" -> "usbc") so OpenNept4une.sh
# can regenerate the right printer.cfg on headless reflashes without re-asking.
toolhead_suffix="ribbon"
[ "$toolhead_variant" = "usb-c" ] && toolhead_suffix="usbc"
FLAG_LINE="${FLAG_LINE}-t${toolhead_suffix}"

echo "DEBUG: FLAG_LINE is $FLAG_LINE"

# Reconcile boot DTB selection and USB-C toolhead power before committing the
# model flag. This is idempotent and records enough state for an explicit
# rollback if the selected hardware is changed later.
if [[ -x "$BOARD_HARDWARE_SETUP" ]]; then
    if ! sudo "$BOARD_HARDWARE_SETUP" apply \
        --model "$model_key" \
        --pcb-version "$pcb_version" \
        --toolhead "$toolhead_variant"; then
        echo "ERROR: Board-specific boot setup failed; the model selection was not saved."
        exit 1
    fi
else
    echo "ERROR: Board hardware setup script is missing or not executable: $BOARD_HARDWARE_SETUP"
    exit 1
fi

if ! write_model_flag_atomic "$FLAG_FILE" "$FLAG_LINE"; then
    echo "ERROR: Could not atomically persist ${FLAG_LINE}; restoring the prior board selection." >&2
    if sudo grep -qi '^n4' "$FLAG_FILE" 2>/dev/null; then
        sudo "$BOARD_HARDWARE_SETUP" apply --from-flag || \
            echo "CRITICAL: Automatic board-selection recovery failed; do not reboot until boot configuration is inspected." >&2
    else
        sudo "$BOARD_HARDWARE_SETUP" rollback || \
            echo "CRITICAL: Automatic board-selection rollback failed; do not reboot until boot configuration is inspected." >&2
    fi
    exit 1
fi

# Check the contents of the FLAG_FILE
#echo "DEBUG: Contents of $FLAG_FILE"
#sudo cat "$FLAG_FILE"
sync
exit 0
