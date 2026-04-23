#!/usr/bin/env bash
# =============================================================================
# Telemon -- Shared helpers for admin/update/uninstall scripts
# =============================================================================
# Sourced by helper scripts. Not executed directly.
# =============================================================================

# ===========================================================================
# Fallback log function — used when common.sh is sourced by standalone scripts
# that don't have access to telemon.sh's log() function. Writes to stderr
# with timestamp and level prefix.
# Usage: log "LEVEL" "message"
# ===========================================================================
if ! type log &>/dev/null; then
    log() {
        local level="${1:-INFO}"
        local message="${2:-}"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[${timestamp}] [${level}] ${message}" >&2
    }
fi

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
# Portable SHA-256 hash helper (replaces MD5 for state key generation)
# Returns SHA-256 hash using available tool: GNU sha256sum, BSD shasum, or openssl
# Usage: echo "text" | portable_sha256
# ===========================================================================
portable_sha256() {
    sha256sum 2>/dev/null | awk '{print $1}' \
    || shasum -a 256 2>/dev/null | awk '{print $1}' \
    || { openssl dgst -sha256 2>/dev/null | awk '{print $NF}'; }
}

# ===========================================================================
# Security validation helpers
# ===========================================================================

# Validate systemd service name (alphanumeric, hyphen, underscore, dot only)
# Usage: is_valid_service_name "$svc" || { log "WARN" "Invalid service name"; continue; }
# Pattern allows: a-z A-Z 0-9 . _ -
# Rejects: shell metacharacters, spaces, command substitution, path traversal
is_valid_service_name() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

# Validate hostname for TCP port checks
# Allows: alphanumeric, hyphen, dot (for FQDNs), underscore (for service names)
# Rejects: shell metacharacters, command substitution, path traversal patterns
is_valid_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

# Validate file path for drift detection and integrity checks
# Prevents: path traversal (..), shell expansion (* ?), and command substitution
# Optionally validates against allowed prefixes for defense-in-depth
# Usage: is_safe_path "$filepath" || { log "WARN" "Unsafe path"; continue; }
is_safe_path() {
    local filepath="$1"
    # Reject paths with directory traversal
    [[ "$filepath" == *".."* ]] && return 1
    # Reject paths with shell glob characters
    [[ "$filepath" == *"*"* ]] && return 1
    [[ "$filepath" == *"?"* ]] && return 1
    # Reject paths that look like command substitution
    [[ "$filepath" == *'$'* ]] && return 1
    [[ "$filepath" == *'`'* ]] && return 1
    # Path is safe
    return 0
}

# Validate path is within allowed directories (optional additional check)
# Usage: is_path_in_allowed_dirs "$filepath" "/etc /opt /var" || return 1
is_path_in_allowed_dirs() {
    local filepath="$1"
    local allowed_dirs="$2"
    for prefix in $allowed_dirs; do
        [[ "$filepath" == "$prefix"* ]] && return 0
    done
    return 1
}

# Strict email validation (RFC 5322 simplified)
# Usage: is_valid_email "$email" || { log "WARN" "Invalid email"; return 1; }
# Pattern: local@domain where both parts are non-empty and domain has a TLD
is_valid_email() {
    local email="$1"
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# Check if an IP address is internal/reserved (for SSRF protection)
# Returns 0 (true) if IP is internal, 1 (false) if external
# Usage: is_internal_ip "$host" && { log "WARN" "Internal IP blocked"; continue; }
is_internal_ip() {
    local host="$1"
    # Check for private/reserved IPv4 ranges
    [[ "$host" =~ ^127\. ]] && return 0                    # Loopback
    [[ "$host" =~ ^10\. ]] && return 0                    # Private Class A
    [[ "$host" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0   # Private Class B
    [[ "$host" =~ ^192\.168\. ]] && return 0             # Private Class C
    [[ "$host" =~ ^169\.254\. ]] && return 0             # Link-local
    [[ "$host" =~ ^0\.0\.0\.0 ]] && return 0              # Default route
    [[ "$host" == "localhost" ]] && return 0               # Localhost name
    # Check for IPv6 loopback/link-local
    [[ "$host" =~ ^::1$ ]] && return 0                     # IPv6 loopback
    [[ "$host" =~ ^fc00: ]] && return 0                  # IPv6 ULA
    [[ "$host" =~ ^fe80: ]] && return 0                  # IPv6 link-local
    # Not an internal IP
    return 1
}

# ===========================================================================
# Validation helper functions — reduce boilerplate in check functions
# ===========================================================================

# Require a file to exist, be readable, and pass safety checks
# Usage: require_file "$filepath" "description" || return
# Returns: 0 if file exists and is safe, 1 otherwise (logs warning)
require_file() {
    local filepath="$1"
    local description="${2:-file}"
    
    if ! is_safe_path "$filepath"; then
        log "WARN" "require_file: unsafe path '${filepath}' for ${description} — skipping"
        return 1
    fi
    
    if [[ ! -f "$filepath" ]]; then
        log "WARN" "require_file: ${description} '${filepath}' not found — skipping"
        return 1
    fi
    
    if [[ ! -r "$filepath" ]]; then
        log "WARN" "require_file: ${description} '${filepath}' not readable — skipping"
        return 1
    fi
    
    return 0
}

# Require a command to be available
# Usage: require_command "docker" || return
# Returns: 0 if command exists, 1 otherwise (logs warning)
require_command() {
    local cmd="$1"
    local description="${2:-$cmd}"
    
    if ! command -v "$cmd" &>/dev/null; then
        log "DEBUG" "require_command: ${description} not found — skipping"
        return 1
    fi
    
    return 0
}

# Validate a numeric value is a positive integer within optional range
# Usage: validate_numeric "$value" "description" [min] [max]
# Returns: 0 if valid, 1 otherwise (logs warning)
validate_numeric() {
    local value="$1"
    local description="$2"
    local min="${3:-}"
    local max="${4:-}"
    
    if ! is_valid_number "$value"; then
        log "WARN" "validate_numeric: ${description} '${value}' is not a valid positive integer"
        return 1
    fi
    
    if [[ -n "$min" ]] && [[ "$value" -lt "$min" ]]; then
        log "WARN" "validate_numeric: ${description} ${value} is below minimum ${min}"
        return 1
    fi
    
    if [[ -n "$max" ]] && [[ "$value" -gt "$max" ]]; then
        log "WARN" "validate_numeric: ${description} ${value} exceeds maximum ${max}"
        return 1
    fi
    
    return 0
}

# ===========================================================================
# Validate numeric and set default if invalid
# Combines is_valid_number check with default assignment
# Usage: validate_numeric_or_default "$value" "description" "default_value" [min] [max]
# Returns: valid numeric value (or default) on stdout, returns 0 always
# Example: my_var=$(validate_numeric_or_default "$input" "timeout" "30" 1 300)
# ===========================================================================
validate_numeric_or_default() {
    local value="$1"
    local description="$2"
    local default="$3"
    local min="${4:-}"
    local max="${5:-}"
    
    # Internal helper to safely log warnings (handles cases where log() isn't available)
    _vnd_log_warn() {
        local msg="$1"
        if type log &>/dev/null; then
            log "WARN" "$msg"
        else
            echo "[WARN] $msg" >&2
        fi
    }
    
    if ! is_valid_number "$value"; then
        _vnd_log_warn "validate_numeric_or_default: ${description} '${value}' is not numeric — using default ${default}"
        echo "$default"
        return 0
    fi
    
    if [[ -n "$min" ]] && [[ "$value" -lt "$min" ]]; then
        _vnd_log_warn "validate_numeric_or_default: ${description} ${value} is below minimum ${min} — using default ${default}"
        echo "$default"
        return 0
    fi
    
    if [[ -n "$max" ]] && [[ "$value" -gt "$max" ]]; then
        _vnd_log_warn "validate_numeric_or_default: ${description} ${value} exceeds maximum ${max} — using default ${default}"
        echo "$default"
        return 0
    fi
    
    echo "$value"
}

# ===========================================================================
# Validation helper — check if value is a valid positive integer
# Intentionally rejects floats; all Telemon thresholds are integers by design
# Usage: is_valid_number "$value" || log "ERROR" "Not a number"
# Returns: 0 if valid positive integer, 1 otherwise
# Pattern: ^[0-9]+$ (accepts zero and positive integers only)
# ===========================================================================
is_valid_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# ===========================================================================
# Generate a state key hash for consistent key naming
# Creates a 12-character SHA-256 hash prefix for state tracking keys
# Usage: make_state_key "prefix" "value"
# Example: make_state_key "site" "https://example.com" → "site_a1b2c3d4e5f6"
# ===========================================================================
make_state_key() {
    local prefix="$1"
    local value="$2"
    printf '%s_%s' "$prefix" "$(printf '%s' "$value" | portable_sha256 | cut -c1-12)"
}

