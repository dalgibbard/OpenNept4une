#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
checkout="$HOME/OpenNept4une"
config_dir="$HOME/printer_data/config"
mkdir -p "$checkout/img-config" "$config_dir"
cp "$REPO_ROOT/img-config/repo-utils.sh" "$checkout/img-config/repo-utils.sh"

git -C "$checkout" init -q
git -C "$checkout" symbolic-ref HEAD refs/heads/dev
git -C "$checkout" remote add origin "https://example.invalid/my/OpenNept4une.git"

printf '%s\n' \
    '[server]' \
    'host: 0.0.0.0' \
    '' \
    '[update_manager OpenNept4une]' \
    'type: git_repo' \
    'primary_branch: main' \
    'path: /home/mks/OpenNept4une' \
    'origin: https://github.com/OpenNeptune3D/OpenNept4une.git' \
    > "$config_dir/moonraker.conf"

# shellcheck source=../OpenNept4une.sh
source "$REPO_ROOT/OpenNept4une.sh"
declare -F set_printer_model >/dev/null
print_help | grep -q '^  set_printer_model'

# A failed child installer must propagate through install_feature (and thus
# through direct CLI dispatch such as update_mcu_rpi_fw).
sleep() { :; }
auto_yes=true
if install_feature "Expected failure" "false" "unused" >/dev/null 2>&1; then
    printf '%s\n' 'install_feature masked a child command failure' >&2
    exit 1
fi

if declare -f run_install_screen_service_with_setup | grep -q 'rm -rf'; then
    printf '%s\n' 'display installer still deletes an existing checkout' >&2
    exit 1
fi

mkdir -p "$HOME/display_connector"
git -C "$HOME/display_connector" init -q
git -C "$HOME/display_connector" symbolic-ref HEAD refs/heads/main
printf '%s\n' 'preserve me' > "$HOME/display_connector/local-display-work.txt"
current_branch=dev
if initialize_display_connector >/dev/null 2>&1; then
    printf '%s\n' 'display initializer unexpectedly accepted a branch mismatch' >&2
    exit 1
fi
grep -qx 'preserve me' "$HOME/display_connector/local-display-work.txt"

moonraker_update_manager "OpenNept4une"

grep -qx 'primary_branch: dev' "$config_dir/moonraker.conf"
grep -qx 'origin: https://example.invalid/my/OpenNept4une.git' "$config_dir/moonraker.conf"
if grep -q 'origin: https://github.com/OpenNeptune3D/OpenNept4une.git' "$config_dir/moonraker.conf"; then
    printf '%s\n' 'official origin unexpectedly remained in Moonraker config' >&2
    exit 1
fi

# The updater must refuse a dirty downstream checkout instead of resetting or
# cleaning it. Sleep is already shadowed so this remains a fast unit test.
printf '%s\n' 'local hardware work' > "$checkout/local-change.txt"
if process_repo_update "$checkout" "OpenNept4une test checkout" >/dev/null 2>&1; then
    printf '%s\n' 'updater unexpectedly accepted a dirty checkout' >&2
    exit 1
fi
grep -qx 'local hardware work' "$checkout/local-change.txt"

printf '%s\n' "OpenNept4une updater tests passed"
