#!/bin/bash

# Print a repository remote URL, falling back to the supplied URL when the
# checkout or remote is unavailable. Keep this helper side-effect free so it
# can be reused by installers and tested without printer hardware.
resolve_git_remote_url() {
    local repo_dir="$1"
    local remote_name="$2"
    local fallback_url="$3"
    local remote_url=""

    remote_url=$(git -C "$repo_dir" remote get-url "$remote_name" 2>/dev/null || true)
    if [ -n "$remote_url" ]; then
        printf '%s\n' "$remote_url"
    else
        printf '%s\n' "$fallback_url"
    fi
}

# Replace every model-selection line with exactly one expected value. Build the
# new file without privilege, then install and rename a root-owned temporary on
# the same filesystem so power loss cannot expose a half-written flag.
write_model_flag_atomic() {
    local flag_file="$1"
    local flag_value="$2"
    local content_tmp target_tmp model_count

    [[ "$flag_value" != *$'\n'* && "$flag_value" =~ ^N4 ]] || {
        printf 'ERROR: Invalid model flag value: %s\n' "$flag_value" >&2
        return 1
    }

    content_tmp=$(mktemp) || return 1
    if sudo test -f "$flag_file"; then
        if ! sudo awk 'tolower(substr($0, 1, 2)) != "n4"' "$flag_file" > "$content_tmp"; then
            rm -f "$content_tmp"
            return 1
        fi
    fi
    printf '%s\n' "$flag_value" >> "$content_tmp"

    target_tmp=$(sudo mktemp "${flag_file}.opennept4une.XXXXXX") || {
        rm -f "$content_tmp"
        return 1
    }
    if ! sudo install -o root -g root -m 0644 "$content_tmp" "$target_tmp" ||
       ! sudo mv -f -- "$target_tmp" "$flag_file"; then
        sudo rm -f -- "$target_tmp" 2>/dev/null || true
        rm -f "$content_tmp"
        return 1
    fi
    rm -f "$content_tmp"

    model_count=$(sudo awk 'tolower(substr($0, 1, 2)) == "n4" { count++ } END { print count + 0 }' "$flag_file") || return 1
    [[ "$model_count" = "1" ]] || return 1
    sudo grep -Fqx -- "$flag_value" "$flag_file"
}
