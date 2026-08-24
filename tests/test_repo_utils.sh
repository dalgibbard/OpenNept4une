#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../img-config/repo-utils.sh
source "$REPO_ROOT/img-config/repo-utils.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

git -C "$TEST_ROOT" init -q
git -C "$TEST_ROOT" remote add origin "https://example.invalid/my/OpenNept4une.git"

actual=$(resolve_git_remote_url "$TEST_ROOT" origin "https://fallback.invalid/OpenNept4une.git")
test "$actual" = "https://example.invalid/my/OpenNept4une.git"

actual=$(resolve_git_remote_url "$TEST_ROOT" missing "https://fallback.invalid/OpenNept4une.git")
test "$actual" = "https://fallback.invalid/OpenNept4une.git"

actual=$(resolve_git_remote_url "$TEST_ROOT/not-a-repository" origin "https://fallback.invalid/OpenNept4une.git")
test "$actual" = "https://fallback.invalid/OpenNept4une.git"

# Exercise privileged calls against the temporary fixture without requiring a
# real sudo boundary.
sudo() { unshare -Ur "$@"; }
flag_file="$TEST_ROOT/.OpenNept4une.txt"
printf '%s\n' 'Linux fixture' 'N4Max-v2.0-tribbon' 'n4-old-duplicate' > "$flag_file"
write_model_flag_atomic "$flag_file" 'N4Max-v2.3-tusbc'
grep -Fxq 'Linux fixture' "$flag_file"
grep -Fxq 'N4Max-v2.3-tusbc' "$flag_file"
test "$(grep -Eic '^n4' "$flag_file")" -eq 1

printf '%s\n' "repo-utils tests passed"
