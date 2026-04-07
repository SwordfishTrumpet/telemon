#!/usr/bin/env bash
# =============================================================================
# Telemon -- Shared helpers for admin/update/uninstall scripts
# =============================================================================
# Sourced by helper scripts. Not executed directly.
# =============================================================================

# Load .env configuration if present, set sensible defaults
load_telemon_env() {
    if [[ -z "${SCRIPT_DIR:-}" ]]; then
        echo "ERROR: SCRIPT_DIR not set — common.sh must be sourced from a script that defines it" >&2
        return 1
    fi
    local env_file="${SCRIPT_DIR}/.env"
    if [[ -f "$env_file" ]]; then
        if [[ ! -r "$env_file" ]]; then
            echo "WARN: .env exists but is not readable: ${env_file}" >&2
        else
            # shellcheck source=/dev/null
            if ! source "$env_file" 2>/dev/null; then
                echo "WARN: Failed to source .env (possible syntax error): ${env_file}" >&2
            fi
        fi
    fi
    STATE_FILE="${STATE_FILE:-/tmp/telemon_sys_alert_state}"
    LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/telemon.log}"
}

# Get current version from git (tags or short hash)
get_telemon_version() {
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || \
        git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || \
        echo "unknown"
    else
        echo "unknown"
    fi
}

