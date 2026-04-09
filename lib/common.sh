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

# ===========================================================================
# Cross-platform stat helper
# Provides GNU stat compatible interface on both Linux (GNU) and macOS (BSD)
# Usage: portable_stat <format> <file>
#   format: mtime, size, owner (user), perms (octal)
# ===========================================================================
portable_stat() {
    local fmt="$1"
    local file="$2"
    case "$fmt" in
        mtime)
            stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0"
            ;;
        size)
            stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo "0"
            ;;
        owner)
            stat -c '%U(uid=%u)' "$file" 2>/dev/null || stat -f '%Su(uid=%u)' "$file" 2>/dev/null || echo "unknown"
            ;;
        perms)
            local perms_val
            perms_val=$(stat -c %a "$file" 2>/dev/null)
            if [[ -z "$perms_val" ]]; then
                # BSD stat returns without leading zeros, pad to 3 digits
                perms_val=$(stat -f '%Lp' "$file" 2>/dev/null)
                if [[ -n "$perms_val" ]]; then
                    printf '%03d' "$perms_val"
                else
                    echo "000"
                fi
            else
                echo "$perms_val"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# ===========================================================================
# Get list of state file variants for backup/restore/reset operations
# Returns a space-separated list of state file paths
# Usage: get_state_file_variants [include_main] [include_lock] [include_drift_baseline]
#   include_main: "true" to include main STATE_FILE (default: true for backup)
#   include_lock: "true" to include lock files
#   include_drift_baseline: "true" to include drift.baseline directory
# ===========================================================================
get_state_file_variants() {
    local include_main="${1:-true}"
    local include_lock="${2:-false}"
    local include_drift_baseline="${3:-false}"
    
    # Base variants (always included)
    local variants="${STATE_FILE}.cooldown ${STATE_FILE}.queue ${STATE_FILE}.escalation ${STATE_FILE}.integrity ${STATE_FILE}.net ${STATE_FILE}.detail ${STATE_FILE}.trend ${STATE_FILE}.drift ${STATE_FILE}.iowait"
    
    # Include main state file
    if [[ "$include_main" == "true" ]]; then
        variants="${STATE_FILE} ${variants}"
    fi
    
    # Include lock files
    if [[ "$include_lock" == "true" ]]; then
        variants="${STATE_FILE}.lock ${STATE_FILE}.lock.d ${variants}"
    fi
    
    # Include drift baseline directory path (caller checks if it's a dir)
    if [[ "$include_drift_baseline" == "true" ]]; then
        variants="${STATE_FILE}.drift.baseline ${variants}"
    fi
    
    echo "$variants"
}

# ===========================================================================
# Portable MD5 hash helper
# Returns MD5 hash using available tool: GNU md5sum, BSD md5, or cksum fallback
# Usage: echo "text" | portable_md5
# ===========================================================================
portable_md5() {
    md5sum 2>/dev/null | awk '{print $1}' \
    || md5 -q 2>/dev/null \
    || { cksum | awk '{print $1}'; }
}

