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
        cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || \
        echo "unknown"
    else
        cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || \
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
# Check if a command exists (portable, quiet)
# Usage: _cmd_exists <command>
# ===========================================================================
_cmd_exists() { command -v "$1" &>/dev/null; }

# ===========================================================================
# Sanitize state key: strip characters that would corrupt key=STATE:count format
# Shared by telemon.sh (state keys) and telemon-admin.sh (heartbeat files).
# The lowercase step is significant: send_heartbeat writes heartbeat files with
# this function, so admin status/backup MUST use the identical transformation
# or mixed-case labels are never found.
# ===========================================================================
sanitize_state_key() {
    local key="$1"
    # Replace anything not alphanumeric, underscore, hyphen, or dot with underscore,
    # then convert to lowercase for consistent state keys
    printf '%s' "$key" | tr -c 'a-zA-Z0-9_.-' '_' | tr '[:upper:]' '[:lower:]'
}

# ===========================================================================
# HTML escaping helper for Telegram
# ===========================================================================
html_escape() {
    local text="$1"
    # Escape & first (must use \& in replacement to get literal &)
    text="${text//&/\&amp;}"
    text="${text//</\&lt;}"
    text="${text//>/\&gt;}"
    text="${text//\"/\&quot;}"
    text="${text//\'/\&#39;}"
    printf '%s' "$text"
}

# ===========================================================================
# Strip HTML for plain-text channels (webhook, email, escalation)
# Converts %0A encoded newlines back to real ones, strips HTML tags, and
# decodes entities — both named (&amp;) and numeric (&#128308;). Numeric emoji
# entities render fine in Telegram (parse_mode=HTML) but leak as literal
# "&#128308;" text into Slack/Discord/ntfy/email payloads, so they must be
# decoded here. Uses python3 html.unescape when available (python3 is already
# a declared dependency for webhook/escalation); falls back to a named-entity
# sed pipeline otherwise (numeric entities remain literal — acceptable on
# minimal systems without python3).
# ===========================================================================
strip_html_for_plain_text() {
    local message="$1"
    if command -v python3 &>/dev/null; then
        printf '%s\n' "$message" | sed 's/%0A/\n/g; s/<[^>]*>//g' \
            | python3 -c "import html,sys; sys.stdout.write(html.unescape(sys.stdin.read()))" 2>/dev/null
    else
        printf '%s\n' "$message" | sed 's/%0A/\n/g; s/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g'
    fi
}

# ===========================================================================
# Parse a heartbeat file line (tab-separated, 7 fields):
#   label  timestamp  status  check_count  warn_count  crit_count  uptime_sec
# Emits each field on its own line (empty string for missing fields) so both
# telemon.sh (check_fleet_heartbeats) and telemon-admin.sh (cmd_fleet_status)
# share a single source of truth for the heartbeat format — preventing
# field-count drift between the two parsers.
# Usage: IFS=$'\n' read -r l ts st cc wc cr up < <(parse_heartbeat_line "$(head -1 "$file")")
# ===========================================================================
parse_heartbeat_line() {
    local line="$1"
    printf '%s\n' "$line" | awk -F'\t' '{printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n", $1, $2, $3, $4, $5, $6, $7}'
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

# ===========================================================================
# Host / URL normalization (shared by the SSRF guard and the SSL check)
# ===========================================================================

# Normalize a host or URL into a bare lowercase hostname: strips the scheme,
# userinfo, path/query/fragment, IPv6 brackets and port.
#   normalize_host "https://[::1]:8443/path"      -> "::1"
#   normalize_host "http://user@Example.COM:80/x" -> "example.com"
# GH #14: callers previously split on ':' which turned a bracketed IPv6
# literal into "[" — so encoded/bracketed hosts bypassed is_internal_ip.
normalize_host() {
    local host="$1"
    host="${host#*://}"      # scheme
    host="${host%%/*}"       # path
    host="${host%%\?*}"      # query
    host="${host%%#*}"       # fragment
    host="${host##*@}"       # userinfo
    if [[ "$host" == \[*\]* ]]; then
        host="${host#[}"
        host="${host%%]*}"
    elif [[ "$host" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
    fi
    # tr (not ${var,,}) — bash 3.2 is a supported target (macOS)
    printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# Extract the port from a host/URL authority, emitting $2 when absent/invalid.
# Handles bracketed IPv6 authorities ([::1]:8443) that '%%:*' splitting breaks.
normalize_port() {
    local authority="${1#*://}"
    local default="${2:-}"
    authority="${authority%%/*}"
    authority="${authority%%\?*}"
    authority="${authority##*@}"
    local port=""
    if [[ "$authority" =~ ^\[.+\]:([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$authority" =~ ^[^:]+:([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    fi
    printf '%s' "${port:-$default}"
}

# ===========================================================================
# Numeric address canonicalization (GH #14)
# inet_aton — and therefore curl/getaddrinfo — accepts alternate spellings of
# the same IPv4 address: decimal/hex/octal components and 1-4 dot-separated
# parts. 2130706433, 0x7f000001, 0177.0.0.1 and 127.1 all mean 127.0.0.1.
# Matching the raw string cannot see those, so the guard canonicalizes first.
# ===========================================================================

# Convert one dotted component (decimal, 0x-hex, or 0N-octal) to decimal.
_ipv4_component_dec() {
    local part="$1"
    case "$part" in
        '') return 1 ;;
        0) printf '0' ;;
        0[xX]*)
            [[ "$part" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]] || return 1
            printf '%d' "$((16#${part#0[xX]}))"
            ;;
        0[0-7]*)
            [[ "$part" =~ ^0[0-7]+$ ]] || return 1
            printf '%d' "$((8#${part#0}))"
            ;;
        *[!0-9]*) return 1 ;;
        *) printf '%d' "$((10#$part))" ;;
    esac
}

# Canonicalize any inet_aton-accepted IPv4 literal to dotted-quad decimal.
# Prints the canonical address, or returns 1 when the input is not a numeric
# IPv4 literal (e.g. a hostname).
canonical_ipv4() {
    local host="$1"
    # Cheap bounds: longest form is 4 parts x 10 chars (0x + 8 hex digits)
    [[ ${#host} -le 48 ]] || return 1
    [[ "$host" =~ ^[0-9a-fA-FxX.]+$ ]] || return 1
    local -a parts=() dec=()
    local IFS='.'
    read -r -a parts <<< "$host"
    local n=${#parts[@]} d part
    (( n >= 1 && n <= 4 )) || return 1
    for part in "${parts[@]}"; do
        [[ ${#part} -le 12 ]] || return 1
        d=$(_ipv4_component_dec "$part") || return 1
        dec+=("$d")
    done
    # inet_aton: with fewer than 4 parts the last part holds the remaining bytes
    local a b c e
    case $n in
        4)  a=${dec[0]}; b=${dec[1]}; c=${dec[2]}; e=${dec[3]}
            (( a <= 255 && b <= 255 && c <= 255 && e <= 255 )) || return 1 ;;
        3)  a=${dec[0]}; b=${dec[1]}
            (( a <= 255 && b <= 255 && dec[2] <= 0xFFFFFF )) || return 1
            c=$(( dec[2] >> 8 )); e=$(( dec[2] & 255 )) ;;
        2)  a=${dec[0]}
            (( a <= 255 && dec[1] <= 0xFFFFFF )) || return 1
            b=$(( dec[1] >> 16 )); c=$(( (dec[1] >> 8) & 255 )); e=$(( dec[1] & 255 )) ;;
        1)  (( dec[0] <= 0xFFFFFFFF )) || return 1
            a=$(( dec[0] >> 24 )); b=$(( (dec[0] >> 16) & 255 ))
            c=$(( (dec[0] >> 8) & 255 )); e=$(( dec[0] & 255 )) ;;
    esac
    printf '%s.%s.%s.%s' "$a" "$b" "$c" "$e"
}

# True when a canonical dotted-quad address is internal/reserved.
internal_ipv4() {
    local ip="$1"
    case "$ip" in
        # loopback, RFC1918 class A/C, link-local, and "this network" (0/8)
        127.*|10.*|192.168.*|169.254.*|0.*) return 0 ;;
    esac
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0   # RFC1918 class B
    return 1
}

# Expand an IPv6 literal into its 8 lowercase zero-padded hex groups, one per
# line. Returns 1 (no output) for anything that is not a valid IPv6 literal or
# that uses '::' more than once. Brackets must already be stripped.
expand_ipv6() {
    local host="$1" left="" right=""
    local -a lg=() rg=()
    if [[ "$host" == *"::"* ]]; then
        left="${host%%::*}"
        right="${host##*::}"
        [[ "$right" == *"::"* ]] && return 1
    else
        left="$host"
    fi
    [[ -n "$left" ]] && IFS=':' read -r -a lg <<< "$left"
    [[ -n "$right" ]] && IFS=':' read -r -a rg <<< "$right"
    local g
    for g in "${lg[@]}" "${rg[@]}"; do
        [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    done
    local -a groups=()
    local g
    for g in "${lg[@]}"; do
        groups+=("$(printf '%04x' "$((16#$g))")")
    done
    if [[ "$host" == *"::"* ]]; then
        # The omitted groups belong between the left and right halves
        local fill=$(( 8 - ${#lg[@]} - ${#rg[@]} ))
        (( fill >= 1 )) || return 1
        local i
        for (( i=0; i<fill; i++ )); do groups+=(0000); done
    else
        (( ${#lg[@]} == 8 )) || return 1
    fi
    for g in "${rg[@]}"; do
        groups+=("$(printf '%04x' "$((16#$g))")")
    done
    (( ${#groups[@]} == 8 )) || return 1
    printf '%s\n' "${groups[@]}"
}

# Check if an IP address or host is internal/reserved (for SSRF protection)
# Normalizes the input first, then canonicalizes numeric forms, so encoded
# spellings of the same address cannot bypass the guard (GH #14):
#   IPv4: 2130706433, 0x7f000001, 0177.0.0.1, 127.1
#   IPv6: ::ffff:127.0.0.1, ::ffff:7f00:1, 0:0:0:0:0:ffff:7f00:1, [::1], FE80::1
# Returns 0 (true) if internal, 1 (false) if external
# Usage: is_internal_ip "$host" && { log "WARN" "Internal IP blocked"; continue; }
is_internal_ip() {
    local host
    host=$(normalize_host "$1")
    host="${host%.}"          # a trailing dot is the FQDN form of the same name
    [[ -z "$host" ]] && return 1

    # Loopback / special-use names
    case "$host" in
        localhost|localhost.localdomain|ip6-localhost|ip6-loopback) return 0 ;;
    esac

    # ---- IPv6 literals (any ':' makes it one) -----------------------------
    if [[ "$host" == *:* ]]; then
        # IPv4-mapped / IPv4-compatible forms carry a dotted-quad suffix
        if [[ "$host" =~ ([0-9]{1,3}(\.[0-9]{1,3}){3})$ ]]; then
            local embedded
            embedded=$(canonical_ipv4 "${BASH_REMATCH[1]}") || embedded=""
            if [[ -n "$embedded" ]] && internal_ipv4 "$embedded"; then
                return 0
            fi
        fi
        # Pure-hex forms (::ffff:7f00:1, ::1, fc00::1, fe80::1, ...)
        local -a groups=() g
        while IFS= read -r g; do groups+=("$g"); done < <(expand_ipv6 "$host" 2>/dev/null)
        if (( ${#groups[@]} == 8 )); then
            # Zero-prefixed addresses map onto IPv4 (::0.0.0.0, ::1, ::ffff:a.b.c.d)
            local zero_prefix=true i
            for (( i=0; i<5; i++ )); do
                [[ "${groups[i]}" == 0000 ]] || zero_prefix=false
            done
            if [[ "$zero_prefix" == "true" ]] && { [[ "${groups[5]}" == 0000 ]] || [[ "${groups[5]}" == ffff ]]; }; then
                local mapped="$((16#${groups[6]} >> 8)).$((16#${groups[6]} & 255)).$((16#${groups[7]} >> 8)).$((16#${groups[7]} & 255))"
                if internal_ipv4 "$mapped"; then
                    return 0
                fi
            fi
            local first_dec=$((16#${groups[0]}))
            (( (first_dec & 0xfe00) == 0xfc00 )) && return 0   # ULA fc00::/7
            (( (first_dec & 0xffc0) == 0xfe80 )) && return 0   # link-local fe80::/10
        fi
        return 1
    fi

    # ---- IPv4 and hostnames ----------------------------------------------
    # A numeric literal in any accepted spelling -> canonicalize, range-check
    local canonical
    if canonical=$(canonical_ipv4 "$host"); then
        if internal_ipv4 "$canonical"; then
            return 0
        fi
        return 1
    fi
    # Not numeric: keep the legacy prefix guards so names that embed a private
    # range (e.g. 10.0.0.1.nip.io) stay blocked
    case "$host" in
        10.*|127.*|192.168.*|169.254.*|0.*) return 0 ;;
    esac
    [[ "$host" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
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

