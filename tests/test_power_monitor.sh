#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
POWER_MONITOR="${REPO_ROOT}/img-config/power_monitor.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/state"
FAKE_TOOL="${TEST_ROOT}/bin/fake-tool"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'tool=$(basename "$0")' \
  'case "$tool" in' \
  '  id)' \
  '    test "${1:-}" = -u && { echo 0; exit 0; }' \
  '    exec /usr/bin/id "$@"' \
  '    ;;' \
  '  gpioinfo)' \
  '    echo "gpioinfo (libgpiod) v2.2.1"' \
  '    ;;' \
  '  gpioget)' \
  '    if test "${1:-}" = --help; then' \
  '      echo "  -c, --chip <chip>"' \
  '      exit 0' \
  '    fi' \
  '    count_file="$TEST_STATE_DIR/gpioget-count"' \
  '    count=0' \
  '    test ! -f "$count_file" || count=$(cat "$count_file")' \
  '    count=$((count + 1))' \
  '    echo "$count" > "$count_file"' \
  '    if test "$count" -le 6; then' \
  '      echo "\"10\"=inactive \"19\"=active"' \
  '    else' \
  '      echo "\"10\"=active \"19\"=active"' \
  '    fi' \
  '    ;;' \
  '  gpioset)' \
  '    count_file="$TEST_STATE_DIR/gpioset-count"' \
  '    if test -f "$count_file"; then' \
  '      echo "gpioset was called more than once" >&2' \
  '      exit 91' \
  '    fi' \
  '    echo 1 > "$count_file"' \
  '    ;;' \
  '  gpiomon)' \
  '    case " $* " in' \
  '      *" 10 ") ;;' \
  '      *) /bin/sleep 0.15 ;;' \
  '    esac' \
  '    echo "test edge"' \
  '    ;;' \
  '  pgrep)' \
  '    exit 1' \
  '    ;;' \
  '  systemctl)' \
  '    echo "$*" >> "$TEST_STATE_DIR/systemctl-calls"' \
  '    ;;' \
  '  systemd-cat)' \
  '    while IFS= read -r _line; do :; done' \
  '    ;;' \
  '  *)' \
  '    echo "unexpected fake tool: $tool" >&2' \
  '    exit 99' \
  '    ;;' \
  'esac' > "$FAKE_TOOL"
chmod 0755 "$FAKE_TOOL"

for tool in id gpioinfo gpioget gpioset gpiomon pgrep systemctl systemd-cat; do
  ln -s fake-tool "${TEST_ROOT}/bin/${tool}"
done

export TEST_STATE_DIR="${TEST_ROOT}/state"
if ! PATH="${TEST_ROOT}/bin:${PATH}" "$POWER_MONITOR" \
  > "${TEST_ROOT}/power-monitor.output" 2>&1; then
  cat "${TEST_ROOT}/power-monitor.output" >&2
  exit 1
fi

test "$(<"${TEST_ROOT}/state/gpioset-count")" = 1
test "$(grep -c 'Monitors started:' "${TEST_ROOT}/power-monitor.output")" = 2
grep -Fq 'Verification: 0/5 samples confirmed loss' \
  "${TEST_ROOT}/power-monitor.output"
grep -Fq 'Glitch detected and ignored. Restarting monitors.' \
  "${TEST_ROOT}/power-monitor.output"
grep -Fq 'Power loss verified. Initiating safe shutdown...' \
  "${TEST_ROOT}/power-monitor.output"
grep -Fxq 'poweroff' "${TEST_ROOT}/state/systemctl-calls"

echo "power-monitor tests passed"
