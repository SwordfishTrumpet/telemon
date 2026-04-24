#!/usr/bin/env bash
# =============================================================================
# Telemon
# =============================================================================
# Tracks CPU, memory, disk, connectivity, and critical processes/containers.
# Sends formatted HTML alerts via Telegram with state-based deduplication
# (only notifies on state CHANGE or RESOLUTION, never repeats).
#
# Designed for cron execution every 5 minutes:
#   */5 * * * * $HOME/telemon/telemon.sh
# =============================================================================
set -euo pipefail

# Require bash 4+ for associative arrays
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "FATAL: Telemon requires bash 4.0+ (found: ${BASH_VERSION})" >&2
    echo "       On macOS: brew install bash" >&2
    exit 1
fi

# Check for curl (required for Telegram, webhooks, site checks)
if ! command -v curl &>/dev/null; then
    echo "FATAL: curl is required but not found. Install with: apt install curl" >&2
    exit 1
fi

# Restrict file creation permissions (owner-only read/write)
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source shared helpers
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "FATAL: .env not found at ${ENV_FILE}" >&2
    exit 1
fi
# SECURITY: .env is sourced as bash code — it is a trust boundary.
# Ensure .env is owned by the correct user and has 600 permissions.
# shellcheck source=/dev/null
source "$ENV_FILE"

# SECURITY: Validate critical input variables to prevent code injection
validate_env_security() {
    local errors=0
    
    # Validate STATE_FILE doesn't contain command substitution or dangerous patterns
    if [[ -n "${STATE_FILE:-}" ]]; then
        if [[ "$STATE_FILE" =~ [\`\$\;\|\&\<\>] ]]; then
            echo "ERROR: STATE_FILE contains dangerous characters — refusing to start" >&2
            ((errors++))
        fi
    fi
    
    # Validate LOG_FILE doesn't contain command substitution or dangerous patterns
    if [[ -n "${LOG_FILE:-}" ]]; then
        if [[ "$LOG_FILE" =~ [\`\$\;\|\&\<\>] ]]; then
            echo "ERROR: LOG_FILE contains dangerous characters — refusing to start" >&2
            ((errors++))
        fi
    fi
    
    # Validate TELEGRAM_BOT_TOKEN format (should be digits:alphanumeric)
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        if [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            echo "WARN: TELEGRAM_BOT_TOKEN format looks invalid (expected '123:ABC...')" >&2
        fi
    fi
    
    # Validate TELEGRAM_CHAT_ID is numeric (or starts with - for groups)
    if [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        if [[ ! "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
            echo "WARN: TELEGRAM_CHAT_ID should be numeric (e.g., '123456789' or '-1001234567890')" >&2
        fi
    fi
    
    # Validate EMAIL_TO if set
    if [[ -n "${EMAIL_TO:-}" ]]; then
        if [[ ! "$EMAIL_TO" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo "WARN: EMAIL_TO format looks invalid" >&2
        fi
    fi
    
    # Validate SMTP_PORT is numeric
    if [[ -n "${SMTP_PORT:-}" ]]; then
        if ! is_valid_number "$SMTP_PORT" || [[ "$SMTP_PORT" -lt 1 ]] || [[ "$SMTP_PORT" -gt 65535 ]]; then
            echo "ERROR: SMTP_PORT must be a valid port number (1-65535)" >&2
            ((errors++))
        fi
    fi
    
    # Validate MAX_ALERT_QUEUE_SIZE is numeric
    if [[ -n "${MAX_ALERT_QUEUE_SIZE:-}" ]]; then
        if ! is_valid_number "$MAX_ALERT_QUEUE_SIZE"; then
            echo "WARN: MAX_ALERT_QUEUE_SIZE should be numeric (bytes)" >&2
            MAX_ALERT_QUEUE_SIZE="1048576"  # Reset to default
        fi
    fi
    
    # Validate MAX_ALERT_QUEUE_AGE is numeric
    if [[ -n "${MAX_ALERT_QUEUE_AGE:-}" ]]; then
        if ! is_valid_number "$MAX_ALERT_QUEUE_AGE"; then
            echo "WARN: MAX_ALERT_QUEUE_AGE should be numeric (seconds)" >&2
            MAX_ALERT_QUEUE_AGE="86400"  # Reset to default
        fi
    fi
    
    if [[ $errors -gt 0 ]]; then
        echo "FATAL: ${errors} security validation errors — fix .env and restart" >&2
        exit 1
    fi
}
validate_env_security

# Server identity — used in alert headers, heartbeat files, fleet monitoring
SERVER_LABEL="${SERVER_LABEL:-$(hostname)}"

# ---------------------------------------------------------------------------
# First-run fingerprint file — persists across state file changes
# Used to prevent duplicate bootstrap messages when STATE_FILE location changes
# or state file is temporarily removed (e.g., log rotation cleanup)
# ---------------------------------------------------------------------------
FIRST_RUN_FINGERPRINT="${SCRIPT_DIR}/.telemon_first_run_done"

# ---------------------------------------------------------------------------
# Maintenance window — skip monitoring if flag file exists
# Create:  touch /tmp/telemon_maint
# Remove:  rm /tmp/telemon_maint
# ---------------------------------------------------------------------------
MAINT_FLAG_FILE="${MAINT_FLAG_FILE:-/tmp/telemon_maint}"
if [[ -f "$MAINT_FLAG_FILE" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Maintenance mode active ($MAINT_FLAG_FILE exists) — skipping" >&2
    exit 0
fi

# Ensure log directory exists and log file has restrictive permissions
mkdir -p "$(dirname "${LOG_FILE:-${SCRIPT_DIR}/telemon.log}")"
touch "${LOG_FILE:-${SCRIPT_DIR}/telemon.log}"
chmod 600 "$LOG_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Lock file to prevent overlapping runs
# Uses flock (util-linux) if available, falls back to PID file
# Includes stale lock detection based on timestamp and process verification
# ---------------------------------------------------------------------------
LOCK_FILE="${STATE_FILE:-/tmp/telemon_sys_alert_state}.lock"
LOCK_TIMEOUT_SEC=300       # Consider locks older than 5 minutes as stale
LOCK_STALE_AGE_SEC=600     # Force break locks older than 10 minutes regardless of PID

# Track if we've logged a lock contention message to reduce spam
_LOCK_CONTENTION_LOGGED=false

# Verify that a PID is actually a telemon process (not just any process)
# SECURITY: Prevents PID reuse attacks where another process gets the same PID
_is_telemon_process() {
    local pid="$1"
    # Check if /proc/PID/cmdline exists and contains "telemon"
    if [[ -f "/proc/$pid/cmdline" ]]; then
        local cmdline
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        [[ "$cmdline" == *"telemon"* ]]
        return $?
    fi
    # If we can't verify, assume it's not telemon (safer)
    return 1
}

# Check if lock is stale based on age (force break very old locks)
_is_lock_stale() {
    local lock_age="$1"
    # If lock is >10 minutes old, consider it stale regardless of PID status
    [[ $lock_age -gt $LOCK_STALE_AGE_SEC ]]
}

# Log lock contention message with rate limiting
# Uses DEBUG level after first occurrence to reduce log spam
_log_lock_contention() {
    local message="$1"
    if [[ "$_LOCK_CONTENTION_LOGGED" == "false" ]]; then
        # First occurrence - log as WARN
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $message" >&2
        _LOCK_CONTENTION_LOGGED=true
    else
        # Subsequent occurrences - only log if DEBUG level is enabled
        # We can't use the log() function here yet (not defined), so we
        # write to a separate debug log or suppress entirely
        : # Suppress to reduce spam - user can check with 'ps aux | grep telemon'
    fi
}

acquire_lock() {
    # Try flock first (most reliable)
    if command -v flock &>/dev/null; then
        # Write our PID and timestamp to lock file for stale detection
        # Do this before trying flock so other processes can check age
        echo "$$ $(date +%s)" > "$LOCK_FILE" 2>/dev/null || true

        # Open file descriptor for lock file
        exec 200>"$LOCK_FILE"
        if ! flock -n 200 2>/dev/null; then
            # Check if the existing lock is stale (holder crashed)
            local lock_info
            lock_info=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
            if [[ -n "$lock_info" ]]; then
                local old_pid old_epoch current_epoch lock_age
                old_pid=$(echo "$lock_info" | awk '{print $1}')
                old_epoch=$(echo "$lock_info" | awk '{print $2}')
                current_epoch=$(date +%s)
                # Validate that we have numeric values before calculating
                if is_valid_number "$old_pid" && is_valid_number "$old_epoch"; then
                    lock_age=$((current_epoch - old_epoch))
                    # Check if lock is very old (>10 min) - force break regardless of PID
                    if _is_lock_stale "$lock_age"; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Stale lock detected (age ${lock_age}s > ${LOCK_STALE_AGE_SEC}s) - force breaking lock" >&2
                        flock -u 200 2>/dev/null || true
                        exec 200>&- 2>/dev/null || true
                        rm -f "$LOCK_FILE"
                        # Re-try once
                        echo "$$ $(date +%s)" > "$LOCK_FILE" 2>/dev/null || true
                        exec 200>"$LOCK_FILE"
                        if flock -n 200 2>/dev/null; then
                            return 0
                        fi
                    fi
                    if [[ $lock_age -gt $LOCK_TIMEOUT_SEC ]]; then
                        # Lock is stale based on age - verify process is dead AND is actually telemon
                        if ! kill -0 "$old_pid" 2>/dev/null; then
                            echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Stale lock detected (PID $old_pid not running, age ${lock_age}s) - breaking lock" >&2
                            flock -u 200 2>/dev/null || true
                            exec 200>&- 2>/dev/null || true
                            rm -f "$LOCK_FILE"
                            # Re-try once
                            echo "$$ $(date +%s)" > "$LOCK_FILE" 2>/dev/null || true
                            exec 200>"$LOCK_FILE"
                            if flock -n 200 2>/dev/null; then
                                return 0
                            fi
                        elif ! _is_telemon_process "$old_pid"; then
                            # PID exists but is NOT a telemon process (PID reuse)
                            echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Stale lock detected (PID $old_pid is not telemon - possible PID reuse, age ${lock_age}s) - breaking lock" >&2
                            flock -u 200 2>/dev/null || true
                            exec 200>&- 2>/dev/null || true
                            rm -f "$LOCK_FILE"
                            # Re-try once
                            echo "$$ $(date +%s)" > "$LOCK_FILE" 2>/dev/null || true
                            exec 200>"$LOCK_FILE"
                            if flock -n 200 2>/dev/null; then
                                return 0
                            fi
                        fi
                    fi
                fi
            fi
            _log_lock_contention "Another instance is running - exiting"
            exit 0
        fi
        return 0
    fi

    # Fallback: atomic mkdir-based lock (avoids TOCTOU race with PID file)
    local lock_dir="${LOCK_FILE}.d"
    if mkdir "$lock_dir" 2>/dev/null; then
        # We acquired the lock — write our PID and timestamp
        echo "$$ $(date +%s)" > "${lock_dir}/pid"
        return 0
    fi
    # Lock dir exists — check if holder is still alive and lock age
    local old_pid old_epoch
    old_pid=$(cat "${lock_dir}/pid" 2>/dev/null | awk '{print $1}') || old_pid=""
    old_epoch=$(cat "${lock_dir}/pid" 2>/dev/null | awk '{print $2}') || old_epoch=""

    if [[ -n "$old_pid" && -n "$old_epoch" ]]; then
        if is_valid_number "$old_pid" && is_valid_number "$old_epoch"; then
            local current_epoch lock_age
            current_epoch=$(date +%s)
            lock_age=$((current_epoch - old_epoch))
            # Check if lock is very old (>10 min) - force break regardless of PID
            if _is_lock_stale "$lock_age"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Stale lock detected (age ${lock_age}s > ${LOCK_STALE_AGE_SEC}s) - force breaking lock" >&2
                rm -rf "$lock_dir"
                if mkdir "$lock_dir" 2>/dev/null; then
                    echo "$$ $(date +%s)" > "${lock_dir}/pid"
                    return 0
                fi
            fi
            if [[ $lock_age -gt $LOCK_TIMEOUT_SEC ]] && ! kill -0 "$old_pid" 2>/dev/null; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Stale lock detected (PID $old_pid not running, age ${lock_age}s) - breaking lock" >&2
                rm -rf "$lock_dir"
                if mkdir "$lock_dir" 2>/dev/null; then
                    echo "$$ $(date +%s)" > "${lock_dir}/pid"
                    return 0
                fi
            elif [[ $lock_age -gt $LOCK_TIMEOUT_SEC ]] && ! _is_telemon_process "$old_pid"; then
                # PID exists but is NOT a telemon process (PID reuse)
                echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Stale lock detected (PID $old_pid is not telemon - possible PID reuse, age ${lock_age}s) - breaking lock" >&2
                rm -rf "$lock_dir"
                if mkdir "$lock_dir" 2>/dev/null; then
                    echo "$$ $(date +%s)" > "${lock_dir}/pid"
                    return 0
                fi
            fi
        fi
        if kill -0 "$old_pid" 2>/dev/null && _is_telemon_process "$old_pid"; then
            _log_lock_contention "Another instance (PID $old_pid) is running - exiting"
            exit 0
        fi
    fi
    # Stale lock — remove and re-acquire atomically
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
        echo "$$ $(date +%s)" > "${lock_dir}/pid"
        return 0
    fi
    # Lost the race to another instance that just started
    _log_lock_contention "Another instance acquired lock - exiting"
    exit 0
}

release_lock() {
    if command -v flock &>/dev/null; then
        flock -u 200 2>/dev/null || true
        exec 200>&- 2>/dev/null || true
    fi
    rm -rf "${LOCK_FILE}.d" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# Acquire lock on startup
acquire_lock

# Release lock on exit
trap release_lock EXIT

# ---------------------------------------------------------------------------
# State File Migration (Critical: prevents re-alerts on reboot)
# If state is in /tmp (non-persistent) and persistent location is available,
# migrate existing state to prevent confirmation count loss
# ---------------------------------------------------------------------------
migrate_state_file() {
    local current_state="${STATE_FILE:-/tmp/telemon_sys_alert_state}"
    
    # Only migrate if current state is in /tmp and file exists
    if [[ "$current_state" == /tmp/* && -f "$current_state" ]]; then
        # Determine best persistent location
        local persistent_dir=""
        if [[ -d "$SCRIPT_DIR" && -w "$SCRIPT_DIR" ]]; then
            persistent_dir="$SCRIPT_DIR"
        elif [[ -d "$HOME/.local/share" && -w "$HOME/.local/share" ]]; then
            persistent_dir="$HOME/.local/share/telemon"
            mkdir -p "$persistent_dir"
        elif [[ -d "/var/lib" && -w "/var/lib" ]]; then
            persistent_dir="/var/lib/telemon"
            mkdir -p "$persistent_dir" 2>/dev/null || true
        fi
        
        if [[ -n "$persistent_dir" && -d "$persistent_dir" && -w "$persistent_dir" ]]; then
            local new_state="${persistent_dir}/.telemon_state"
            # Copy state atomically
            if cp "$current_state" "$new_state" 2>/dev/null && chmod 600 "$new_state" 2>/dev/null; then
                log "INFO" "State file auto-migrated from /tmp to persistent location: ${new_state}"
                log "INFO" "Update STATE_FILE in .env to: STATE_FILE=\"${new_state}\" to prevent re-alerts on reboot"
                # Update runtime variable (but not the config file)
                export STATE_FILE="$new_state"
            fi
        fi
    fi
}
migrate_state_file

# ---------------------------------------------------------------------------
# Logging helper — respects LOG_LEVEL (DEBUG < INFO < WARN < ERROR)
# ---------------------------------------------------------------------------
_log_level_num() {
    case "$1" in
        DEBUG) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; ERROR) echo 3 ;; *) echo 1 ;;
    esac
}

log() {
    local level="$1"; shift
    local min_level="${LOG_LEVEL:-INFO}"
    if [[ "$(_log_level_num "$level")" -lt "$(_log_level_num "$min_level")" ]]; then
        return
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*" | tee -a "$LOG_FILE"
}

# ===========================================================================
# AUDIT LOGGING: Structured JSON audit logs for security and compliance
# Logs events like state changes, alerts, escalations in JSON format
# ===========================================================================
_audit_level_num() {
    case "$1" in
        all) echo 0 ;;
        alert|state_change|check_run|escalation) echo 1 ;;
        *) echo 0 ;;
    esac
}

_should_audit_event() {
    local event_type="$1"
    local audit_events="${AUDIT_EVENTS:-all}"

    # Check if this event type should be logged
    if [[ "$audit_events" == "all" ]]; then
        return 0
    fi

    # Check if event type is in the comma-separated list
    local IFS=',' event
    for event in $audit_events; do
        [[ "$(echo "$event" | tr '[:upper:]' '[:lower:]')" == "$(echo "$event_type" | tr '[:upper:]' '[:lower:]')" ]] && return 0
    done

    return 1
}

audit_log() {
    [[ "${ENABLE_AUDIT_LOGGING:-false}" != "true" ]] && return 0

    local event_type="$1"
    local details="$2"

    # Check if this event type should be logged
    _should_audit_event "$event_type" || return 0

    local audit_file="${AUDIT_LOG_FILE:-/var/log/telemon_audit.log}"
    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    local hostname
    hostname="$(hostname)"
    local server_label="${SERVER_LABEL:-$hostname}"

    # Build JSON entry
    # Escape special characters in details
    local escaped_details
    escaped_details=$(echo "$details" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')

    local json_entry
    json_entry="{\"timestamp\":\"${timestamp}\",\"hostname\":\"${hostname}\",\"server_label\":\"${server_label}\",\"event_type\":\"${event_type}\",\"details\":\"${escaped_details}\"}"

    # Ensure audit log directory exists and has proper permissions
    local audit_dir
    audit_dir="$(dirname "$audit_file")"
    [[ -d "$audit_dir" ]] || mkdir -p "$audit_dir" 2>/dev/null || true

    # Write to audit log (append mode with error handling)
    if ! echo "$json_entry" >> "$audit_file" 2>/dev/null; then
        # If we can't write to audit log, log to main log as fallback
        log "WARN" "Failed to write to audit log: ${audit_file}"
    fi
}

# ===========================================================================
# Log rotation (self-rotation when logrotate not available)
# Rotates when log exceeds 10MB, keeps 5 backups
# ---------------------------------------------------------------------------
rotate_logs() {
    local max_size_mb="${LOG_MAX_SIZE_MB:-10}"
    local max_size=$((max_size_mb * 1024 * 1024))
    local max_backups="${LOG_MAX_BACKUPS:-5}"
    
    if [[ -f "$LOG_FILE" ]]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$log_size" -gt "$max_size" ]]; then
            # Rotate backups
            for (( i = max_backups - 1; i >= 1; i-- )); do
                local src="${LOG_FILE}.${i}"
                local dst="${LOG_FILE}.$((i + 1))"
                [[ -f "$src" ]] && mv "$src" "$dst"
            done
            mv "$LOG_FILE" "${LOG_FILE}.1"
            : > "$LOG_FILE"
            log "DEBUG" "Log rotated (size exceeded ${max_size_mb}MB)"
        fi
    fi
}

# Rotate logs on startup
rotate_logs

# ---------------------------------------------------------------------------
# Timeout wrapper for commands that might hang
# Usage: run_with_timeout <seconds> <command> [args...]
# Returns: 0 on success, 124 on timeout, command's exit code otherwise
# ---------------------------------------------------------------------------
run_with_timeout() {
    local timeout_sec="$1"
    shift
    
    # Use timeout command if available (coreutils)
    if command -v timeout &>/dev/null; then
        timeout "$timeout_sec" "$@" 2>/dev/null
        return $?
    fi
    
    # Fallback: bash timeout using background job
    local pid
    "$@" &
    pid=$!
    
    local count=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        count=$((count + 1))
        if [[ $count -ge $timeout_sec ]]; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
            log "WARN" "Command timed out after ${timeout_sec}s: $*"
            return 124
        fi
    done
    
    wait "$pid" 2>/dev/null
    return $?
}

# Default timeout for external commands (seconds)
CHECK_TIMEOUT="${CHECK_TIMEOUT:-30}"

# ---------------------------------------------------------------------------
# Threshold validation
# ---------------------------------------------------------------------------
# Helper to check warn < crit threshold pair
# Usage: check_threshold_pair NAME WARN CRIT [inverted]
#   inverted=true for metrics where lower is worse (e.g. available memory %)
check_threshold_pair() {
    local name="$1"
    local warn="$2"
    local crit="$3"
    local inverted="${4:-false}"
    local errors=false

    if ! is_valid_number "$warn"; then
        log "ERROR" "Invalid ${name}_THRESHOLD_WARN: '${warn}' must be a positive integer"
        errors=true
    fi
    if ! is_valid_number "$crit"; then
        log "ERROR" "Invalid ${name}_THRESHOLD_CRIT: '${crit}' must be a positive integer"
        errors=true
    fi
    if is_valid_number "$warn" && is_valid_number "$crit"; then
        if [[ "$inverted" == "true" ]]; then
            if [[ "$warn" -le "$crit" ]]; then
                log "WARN" "${name}_THRESHOLD_WARN (${warn}) should be greater than ${name}_THRESHOLD_CRIT (${crit}) for inverted metrics"
            fi
        else
            if [[ "$warn" -ge "$crit" ]]; then
                log "WARN" "${name}_THRESHOLD_WARN (${warn}) should be less than ${name}_THRESHOLD_CRIT (${crit})"
            fi
        fi
    fi
    [[ "$errors" == "true" ]] && return 1
    return 0
}

validate_thresholds() {
    local has_errors=false
    
    # Validate all threshold pairs
    check_threshold_pair "CPU" "${CPU_THRESHOLD_WARN:-70}" "${CPU_THRESHOLD_CRIT:-80}" || has_errors=true
    check_threshold_pair "MEM" "${MEM_THRESHOLD_WARN:-15}" "${MEM_THRESHOLD_CRIT:-10}" "true" || has_errors=true
    check_threshold_pair "DISK" "${DISK_THRESHOLD_WARN:-85}" "${DISK_THRESHOLD_CRIT:-90}" || has_errors=true
    check_threshold_pair "SWAP" "${SWAP_THRESHOLD_WARN:-50}" "${SWAP_THRESHOLD_CRIT:-80}" || has_errors=true
    check_threshold_pair "IOWAIT" "${IOWAIT_THRESHOLD_WARN:-30}" "${IOWAIT_THRESHOLD_CRIT:-50}" || has_errors=true
    check_threshold_pair "ZOMBIE" "${ZOMBIE_THRESHOLD_WARN:-5}" "${ZOMBIE_THRESHOLD_CRIT:-20}" || has_errors=true
    
    # Extended check thresholds (only validate if check is enabled)
    [[ "${ENABLE_TEMP_CHECK:-false}" == "true" ]] && { check_threshold_pair "TEMP" "${TEMP_THRESHOLD_WARN:-75}" "${TEMP_THRESHOLD_CRIT:-90}" || has_errors=true; }
    [[ "${ENABLE_GPU_CHECK:-false}" == "true" ]] && {
        check_threshold_pair "GPU_TEMP" "${GPU_TEMP_THRESHOLD_WARN:-80}" "${GPU_TEMP_THRESHOLD_CRIT:-95}" || has_errors=true
        # Intel GPU specific thresholds (log warnings but don't fail - may not be on Intel)
        if ! check_threshold_pair "GPU_INTEL_UTIL" "${GPU_INTEL_UTIL_THRESHOLD_WARN:-80}" "${GPU_INTEL_UTIL_THRESHOLD_CRIT:-95}"; then
            log "WARN" "GPU_INTEL_UTIL thresholds invalid — ignored if not using Intel GPU"
        fi
        if ! check_threshold_pair "GPU_INTEL_TEMP" "${GPU_INTEL_TEMP_THRESHOLD_WARN:-80}" "${GPU_INTEL_TEMP_THRESHOLD_CRIT:-95}"; then
            log "WARN" "GPU_INTEL_TEMP thresholds invalid — ignored if not using Intel GPU"
        fi
    }
    [[ "${ENABLE_NETWORK_CHECK:-false}" == "true" ]] && { check_threshold_pair "NETWORK" "${NETWORK_THRESHOLD_WARN:-800}" "${NETWORK_THRESHOLD_CRIT:-950}" || has_errors=true; }
    [[ "${ENABLE_UPS_CHECK:-false}" == "true" ]] && { check_threshold_pair "UPS" "${UPS_THRESHOLD_WARN:-30}" "${UPS_THRESHOLD_CRIT:-10}" "true" || has_errors=true; }
    [[ "${ENABLE_NVME_CHECK:-false}" == "true" ]] && { check_threshold_pair "NVME_TEMP" "${NVME_TEMP_THRESHOLD_WARN:-70}" "${NVME_TEMP_THRESHOLD_CRIT:-80}" || has_errors=true; }
    
    # Validate SQLite size thresholds if database checks are enabled and SQLite paths are configured
    if [[ "${ENABLE_DATABASE_CHECKS:-false}" == "true" ]] && [[ -n "${DB_SQLITE_PATHS:-}" ]]; then
        local sqlite_warn="${DB_SQLITE_SIZE_THRESHOLD_WARN:-0}"
        local sqlite_crit="${DB_SQLITE_SIZE_THRESHOLD_CRIT:-0}"
        # Only validate if at least one threshold is set (non-zero)
        if [[ "$sqlite_warn" != "0" ]] || [[ "$sqlite_crit" != "0" ]]; then
            check_threshold_pair "DB_SQLITE_SIZE" "$sqlite_warn" "$sqlite_crit" || has_errors=true
        fi
    fi
    
    # Validate confirmation count
    if ! is_valid_number "${CONFIRMATION_COUNT:-3}"; then
        log "ERROR" "Invalid CONFIRMATION_COUNT: '${CONFIRMATION_COUNT}' must be a positive integer"
        has_errors=true
    elif [[ "${CONFIRMATION_COUNT:-3}" -lt 1 ]]; then
        log "ERROR" "CONFIRMATION_COUNT must be at least 1"
        has_errors=true
    fi
    
    # Validate ping threshold
    if ! is_valid_number "${PING_FAIL_THRESHOLD:-3}"; then
        log "ERROR" "Invalid PING_FAIL_THRESHOLD: '${PING_FAIL_THRESHOLD}' must be a positive integer"
        has_errors=true
    fi
    
    if [[ "$has_errors" == "true" ]]; then
        log "ERROR" "Configuration validation failed - please fix .env file"
        # Don't exit, just warn - thresholds have defaults
    fi
}

# ---------------------------------------------------------------------------
# State Management (Stateful Alert Deduplication)
# ---------------------------------------------------------------------------
# State file format: key=STATE:count (e.g., cpu=CRITICAL:3)
# - Tracks last known state and consecutive occurrence count
# - Only alerts when state is confirmed (prevents false alarms)
# ---------------------------------------------------------------------------

# Associative arrays for state tracking
# Note: PREV_STATE is loaded once from disk at startup and intentionally NOT
# updated during the run. All checks compare against the same baseline from
# the previous run. CURR_STATE accumulates the new state for this run.
declare -A PREV_STATE
declare -A CURR_STATE
declare -A PREV_COUNT
declare -A STATE_DETAIL
declare -A ALERT_LAST_SENT

# Global variable to accumulate alerts
ALERTS=""

# Alert cooldown: minimum seconds between alerts for the same key (default: 15 min)
ALERT_COOLDOWN_SEC="${ALERT_COOLDOWN_SEC:-900}"
# Ensure ALERT_COOLDOWN_SEC is numeric (defense-in-depth)
if ! is_valid_number "$ALERT_COOLDOWN_SEC"; then
    log "WARN" "ALERT_COOLDOWN_SEC '${ALERT_COOLDOWN_SEC}' is not numeric — defaulting to 900"
    ALERT_COOLDOWN_SEC=900
fi

load_state() {
    PREV_STATE=()
    PREV_COUNT=()
    ALERT_LAST_SENT=()
    
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            # Parse value as STATE:count
            local state="${value%%:*}"
            local count="${value##*:}"
            PREV_STATE["$key"]="$state"
            PREV_COUNT["$key"]="${count:-0}"
        done < "$STATE_FILE"
    fi
    
    # Load alert cooldown timestamps
    local cooldown_file="${STATE_FILE}.cooldown"
    if [[ -f "$cooldown_file" ]]; then
        while IFS='=' read -r key ts; do
            [[ -n "$key" ]] && ALERT_LAST_SENT["$key"]="$ts"
        done < "$cooldown_file"
    fi

    # Load state details from previous run
    local detail_file="${STATE_FILE}.detail"
    if [[ -f "$detail_file" ]]; then
        while IFS='=' read -r key detail; do
            [[ -n "$key" ]] && STATE_DETAIL["$key"]="$detail"
        done < "$detail_file"
    fi
}

save_state() {
    # Guard against symlink attacks on the state file
    if [[ -L "$STATE_FILE" ]]; then
        log "ERROR" "State file is a symlink — refusing to write (possible symlink attack)"
        return 1
    fi
    
    # Create temp file securely and atomically move (restrictive permissions)
    local tmp_file
    tmp_file=$(mktemp "${STATE_FILE}.XXXXXX") || { log "ERROR" "Failed to create temp file for state"; return 1; }
    
    # Subshell is intentional: isolates umask 077 to this write operation only
    (
        umask 077
        for key in "${!CURR_STATE[@]}"; do
            local state="${CURR_STATE[$key]}"
            local count="${PREV_COUNT[$key]:-0}"
            echo "${key}=${state}:${count}"
        done > "$tmp_file"
    )
    
    # Verify temp file has content before overwriting state (guard against empty writes)
    if [[ ! -s "$tmp_file" ]] && [[ ${#CURR_STATE[@]} -gt 0 ]]; then
        log "ERROR" "State file write produced empty output — refusing to overwrite (${#CURR_STATE[@]} keys expected)"
        rm -f "$tmp_file"
        return 1
    fi
    
    # Set restrictive permissions BEFORE moving into place (no race window)
    chmod 600 "$tmp_file" 2>/dev/null || true
    # mv -T refuses to follow symlinks at target (prevents TOCTOU race)
    if ! mv -T "$tmp_file" "$STATE_FILE" 2>/dev/null; then
        # Fallback for non-GNU mv: re-check for symlink, then plain mv
        if [[ -L "$STATE_FILE" ]]; then
            log "ERROR" "State file is a symlink — refusing to write (TOCTOU detected)"
            rm -f "$tmp_file"
            return 1
        fi
        mv "$tmp_file" "$STATE_FILE" || { log "ERROR" "Failed to write state file"; rm -f "$tmp_file"; return 1; }
    fi
    
    # Save alert cooldown timestamps (prune orphaned keys from disabled/removed checks)
    local cooldown_file="${STATE_FILE}.cooldown"
    local cooldown_content=""
    for key in "${!ALERT_LAST_SENT[@]}"; do
        # Only persist cooldown for keys that are still active in this run
        if [[ -n "${CURR_STATE[$key]+x}" ]]; then
            cooldown_content+="${key}=${ALERT_LAST_SENT[$key]}"$'\n'
        fi
    done
    if [[ -n "$cooldown_content" ]]; then
        safe_write_state_file "$cooldown_file" "$cooldown_content"
    fi

    # Save state details for digest/escalation across runs
    local detail_file="${STATE_FILE}.detail"
    local detail_content=""
    for key in "${!STATE_DETAIL[@]}"; do
        # Only persist details for keys that are still active in this run
        if [[ -n "${CURR_STATE[$key]+x}" ]]; then
            detail_content+="${key}=${STATE_DETAIL[$key]}"$'\n'
        fi
    done
    if [[ -n "$detail_content" ]]; then
        safe_write_state_file "$detail_file" "$detail_content"
    fi
}

# Helper to safely write state file variants (symlink check + permissions)
safe_write_state_file() {
    local target="$1"
    local content="$2"
    if [[ -L "$target" ]]; then
        log "ERROR" "State file ${target} is a symlink — refusing to write"
        return 1
    fi
    local tmp_target
    tmp_target=$(mktemp "${target}.XXXXXX") || { log "ERROR" "Failed to create temp file for ${target}"; return 1; }
    echo "$content" > "$tmp_target"
    chmod 600 "$tmp_target" 2>/dev/null || true
    # mv -T refuses to follow symlinks at target (prevents TOCTOU race)
    if ! mv -T "$tmp_target" "$target" 2>/dev/null; then
        # Fallback for non-GNU mv: check for symlink, then plain mv
        if [[ -L "$target" ]]; then
            log "ERROR" "State file ${target} is a symlink — refusing to write"
            rm -f "$tmp_target"
            return 1
        fi
        mv "$tmp_target" "$target" || { log "ERROR" "Failed to write ${target}"; rm -f "$tmp_target"; return 1; }
    fi
}

check_state_change() {
    local key="$1"
    local new_state="$2"
    local detail="$3"

    # Validate state is a known enum value
    case "$new_state" in
        OK|WARNING|CRITICAL) ;;
        *)
            log "ERROR" "check_state_change: invalid state '${new_state}' for key '${key}' — defaulting to CRITICAL"
            new_state="CRITICAL"
            ;;
    esac
    
    CURR_STATE["$key"]="$new_state"
    STATE_DETAIL["$key"]="$detail"
    
    local prev_state="${PREV_STATE[$key]:-OK}"
    local prev_count="${PREV_COUNT[$key]:-0}"
    local confirm_count="${CONFIRMATION_COUNT:-3}"
    
    # Determine if we should alert
    local should_alert=false
    
    if [[ "$new_state" == "$prev_state" ]]; then
        # State unchanged - increment count up to confirmation threshold
        if [[ "$prev_count" -lt "$confirm_count" ]]; then
            prev_count=$((prev_count + 1))
            PREV_COUNT["$key"]=$prev_count
            # Alert when we reach confirmation threshold (non-OK states only)
            if [[ "$prev_count" -eq "$confirm_count" && "$new_state" != "OK" ]]; then
                should_alert=true
            fi
        fi
    else
        # State changed - reset count to 1 (first occurrence of new state)
        PREV_COUNT["$key"]=1
        
        if [[ "$confirm_count" -le 1 ]]; then
            # No confirmation needed - alert immediately on state change
            if [[ "$new_state" != "OK" ]]; then
                should_alert=true
            elif [[ "$prev_state" != "OK" ]]; then
                # Resolution: was non-OK, now OK - alert immediately
                should_alert=true
            fi
        else
            # Confirmation required - only alert for resolutions of previously confirmed states
            if [[ "$new_state" == "OK" && "$prev_state" != "OK" && "$prev_count" -ge "$confirm_count" ]]; then
                # Was confirmed non-OK, now resolved to OK - alert immediately
                should_alert=true
            fi
            # Non-OK state changes wait for confirmation (handled in same-state branch above)
        fi
    fi
    
    if [[ "$should_alert" == "true" ]]; then
        # Rate limiting: skip if we alerted for this key within cooldown period
        local now_epoch
        now_epoch=$(date +%s)
        local last_sent="${ALERT_LAST_SENT[$key]:-0}"
        local time_since_last=$(( now_epoch - last_sent ))
        # Guard against clock skew (NTP corrections): negative delta means clock went backwards
        [[ "$time_since_last" -lt 0 ]] && time_since_last=$((ALERT_COOLDOWN_SEC))
        if [[ "$ALERT_COOLDOWN_SEC" -gt 0 ]] && [[ "$time_since_last" -lt "$ALERT_COOLDOWN_SEC" ]]; then
            log "DEBUG" "Rate limited alert for ${key}: cooldown active (${ALERT_COOLDOWN_SEC}s)"
        else
            local emoji=""
            case "$new_state" in
                CRITICAL) emoji="&#128308;" ;;  # Red circle
                WARNING)  emoji="&#128992;" ;;  # Orange circle
                OK)       emoji="&#128994;" ;;  # Green circle
            esac
            
            ALERTS+="${emoji} <b>${key}</b>: ${detail}%0A%0A"
            ALERT_LAST_SENT["$key"]="$now_epoch"
            log "INFO" "State change confirmed for ${key}: ${prev_state} -> ${new_state} (count: ${PREV_COUNT[$key]})"
            
            # Audit log the state change
            audit_log "state_change" "Key: ${key}, State: ${new_state}, Previous: ${prev_state}"
        fi
    fi
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
# Sanitize state key: strip characters that would corrupt key=STATE:count format
# ===========================================================================
sanitize_state_key() {
    local key="$1"
    # Replace anything not alphanumeric, underscore, hyphen, or dot with underscore
    printf '%s' "$key" | tr -c 'a-zA-Z0-9_.-' '_'
}

# ===========================================================================
# Cross-platform date-to-epoch parser
# Handles both GNU date (-d) and BSD date (-j -f) for macOS compatibility
# ===========================================================================
parse_date_to_epoch() {
    local datestr="$1"
    # Try GNU date first (Linux)
    local epoch
    epoch=$(date -d "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
    # Try BSD date (macOS) with common OpenSSL date format
    epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
    epoch=$(date -j -f "%b  %d %H:%M:%S %Y %Z" "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
    # Try python3 as last resort
    if command -v python3 &>/dev/null; then
        epoch=$(python3 -c "
import email.utils, sys, calendar
try:
    t = email.utils.parsedate_tz(sys.argv[1])
    if t: print(calendar.timegm(t[:9]) - (t[9] or 0))
    else: print('')
except Exception: print('')
" "$datestr" 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
    fi
    echo ""
}

# ===========================================================================
# Predictive Resource Exhaustion — linear regression + trend tracking
# ===========================================================================

# Compute slope and intercept via least-squares linear regression.
# Input: comma-separated "epoch:value" pairs (e.g., "1712345600:82,1712345900:83")
# Output: "slope intercept" (space-separated) on stdout.
# Returns 1 (and prints "0 0") on insufficient/malformed data.
linear_regression() {
    local datapoints="$1"
    [[ -z "$datapoints" ]] && { echo "0 0"; return 1; }
    echo "$datapoints" | awk -F',' '{
        n = 0; sx = 0; sy = 0; sxx = 0; sxy = 0
        for (i = 1; i <= NF; i++) {
            split($i, a, ":")
            if (a[1] == "" || a[2] == "") continue
            x = a[1] + 0; y = a[2] + 0
            sx += x; sy += y; sxx += x*x; sxy += x*y; n++
        }
        if (n < 2 || (n*sxx - sx*sx) == 0) { print "0 0"; exit 1 }
        slope = (n*sxy - sx*sy) / (n*sxx - sx*sx)
        intercept = (sy - slope*sx) / n
        printf "%.10f %.4f\n", slope, intercept
    }'
}

# Record a metric datapoint for trend tracking.
# Usage: record_trend "predict_disk_root" "83"
# Appends epoch:value to ${STATE_FILE}.trend, capping at PREDICT_DATAPOINTS entries.
record_trend() {
    [[ "${ENABLE_PREDICTIVE_ALERTS:-false}" == "true" ]] || return 0
    local key="$1"
    local current_value="$2"
    local trend_file="${STATE_FILE}.trend"
    local max_points="${PREDICT_DATAPOINTS:-48}"
    local now
    now=$(date +%s)

    # Symlink guard
    if [[ -L "$trend_file" ]]; then
        log "ERROR" "Trend file is a symlink — refusing to read (possible symlink attack)"
        return 1
    fi

    # Load existing trend data (all keys)
    declare -A trend_data
    if [[ -f "$trend_file" ]]; then
        while IFS='=' read -r tkey tval; do
            [[ -z "$tkey" ]] && continue
            trend_data["$tkey"]="$tval"
        done < "$trend_file"
    fi

    # Append new datapoint, validating existing ones
    local existing="${trend_data[$key]:-}"
    local cleaned=""
    if [[ -n "$existing" ]]; then
        local IFS=','
        for dp in $existing; do
            if [[ "$dp" =~ ^[0-9]+:[0-9]+$ ]]; then
                cleaned+="${cleaned:+,}${dp}"
            fi
        done
        unset IFS
    fi
    cleaned+="${cleaned:+,}${now}:${current_value}"

    # Cap to last max_points entries
    local point_count
    point_count=$(echo "$cleaned" | awk -F',' '{print NF}')
    if [[ "$point_count" -gt "$max_points" ]]; then
        local drop=$(( point_count - max_points ))
        cleaned=$(echo "$cleaned" | awk -F',' -v d="$drop" '{
            for (i = d+1; i <= NF; i++) printf "%s%s", (i>d+1?",":""), $i
            print ""
        }')
    fi

    trend_data["$key"]="$cleaned"

    # Write all keys back atomically
    local content=""
    for tkey in "${!trend_data[@]}"; do
        content+="${tkey}=${trend_data[$tkey]}"$'\n'
    done
    safe_write_state_file "$trend_file" "$content"
}

# Evaluate trend data and fire prediction alert if exhaustion is within horizon.
# Usage: check_prediction "predict_disk_root" "Disk /" "83"
check_prediction() {
    [[ "${ENABLE_PREDICTIVE_ALERTS:-false}" == "true" ]] || return 0
    local key="$1"
    local label="$2"
    local current_value="$3"
    local trend_file="${STATE_FILE}.trend"
    local min_points="${PREDICT_MIN_DATAPOINTS:-12}"
    local horizon_hours="${PREDICT_HORIZON_HOURS:-24}"

    # Read trend data for this key
    local datapoints=""
    if [[ -f "$trend_file" ]] && [[ ! -L "$trend_file" ]]; then
        while IFS='=' read -r tkey tval; do
            [[ "$tkey" == "$key" ]] && datapoints="$tval" && break
        done < "$trend_file"
    fi

    [[ -z "$datapoints" ]] && return 0

    # Count datapoints
    local point_count
    point_count=$(echo "$datapoints" | awk -F',' '{print NF}')
    if [[ "$point_count" -lt "$min_points" ]]; then
        log "DEBUG" "Prediction: ${key} has ${point_count}/${min_points} datapoints — waiting"
        return 0
    fi

    # Run linear regression
    local result
    result=$(linear_regression "$datapoints") || {
        log "DEBUG" "Prediction: ${key} regression failed — skipping"
        return 0
    }

    local slope intercept
    read -r slope intercept <<< "$result"

    # Check if slope is positive (resource growing toward exhaustion)
    local slope_positive
    slope_positive=$(awk -v s="$slope" 'BEGIN { print (s > 0) ? "1" : "0" }')

    local safe_label
    safe_label=$(html_escape "$label")

    if [[ "$slope_positive" != "1" ]]; then
        # Not growing — clear any previous prediction alert
        check_state_change "$key" "OK" "${safe_label} at ${current_value}% — stable or decreasing"
        return 0
    fi

    # Calculate hours until 100%
    local hours_to_full
    hours_to_full=$(awk -v cv="$current_value" -v s="$slope" 'BEGIN {
        if (s <= 0) { print -1; exit }
        secs = (100 - cv) / s
        hours = secs / 3600
        printf "%.1f", hours
    }')

    # Validate result
    if [[ -z "$hours_to_full" ]] || [[ "$hours_to_full" == "-1" ]]; then
        check_state_change "$key" "OK" "${safe_label} at ${current_value}% — no exhaustion predicted"
        return 0
    fi

    # Check if within horizon
    local within_horizon
    within_horizon=$(awk -v h="$hours_to_full" -v hz="$horizon_hours" 'BEGIN { print (h > 0 && h <= hz) ? "1" : "0" }')

    if [[ "$within_horizon" == "1" ]]; then
        # Format display: "< 1h", "~2.5h", "~18h"
        local hours_display
        hours_display=$(awk -v h="$hours_to_full" 'BEGIN {
            if (h < 1) printf "< 1h"
            else if (h < 10) printf "~%.1fh", h
            else printf "~%.0fh", h
        }')

        check_state_change "$key" "WARNING" \
            "&#9888; <b>PREDICTION</b>: ${safe_label} at ${current_value}% — estimated full in ${hours_display} at current rate"
    else
        check_state_change "$key" "OK" \
            "${safe_label} at ${current_value}% — no exhaustion predicted within ${horizon_hours}h"
    fi
}

# ===========================================================================
# Generic threshold checking helper
# Reduces ~200 lines of duplicated code across check functions
# Usage: check_threshold <key> <value> <warn> <crit> <inverted> <ok_detail> <warn_detail> <crit_detail>
#   key: state key for check_state_change
#   value: current numeric value to check
#   warn: warning threshold
#   crit: critical threshold
#   inverted: "true" for inverted metrics (lower = worse, e.g., memory free %)
#   ok_detail: detail message when OK
#   warn_detail: detail message when WARNING (optional, defaults to crit_detail)
#   crit_detail: detail message when CRITICAL (optional, defaults to warn_detail)
# Returns: sets global THRESHOLD_STATE and THRESHOLD_DETAIL variables
# ===========================================================================
check_threshold() {
    local key="$1"
    local value="$2"
    local warn="$3"
    local crit="$4"
    local inverted="${5:-false}"
    local ok_detail="$6"
    local warn_detail="${7:-}"
    local crit_detail="${8:-}"
    
    # Validate numeric inputs using standardized helper
    if ! is_valid_number "$value"; then
        log "WARN" "check_threshold: value '${value}' is not numeric for key '${key}'"
        value=0
    fi
    if ! is_valid_number "$warn"; then
        log "WARN" "check_threshold: warn threshold '${warn}' is not numeric for key '${key}'"
        warn=100
    fi
    if ! is_valid_number "$crit"; then
        log "WARN" "check_threshold: crit threshold '${crit}' is not numeric for key '${key}'"
        crit=100
    fi
    
    # Default warn_detail and crit_detail if not provided
    [[ -z "$warn_detail" ]] && warn_detail="${crit_detail:-}"
    [[ -z "$crit_detail" ]] && crit_detail="$warn_detail"
    
    local state="OK"
    local detail="$ok_detail"
    
    if [[ "$inverted" == "true" ]]; then
        # Inverted metrics: lower value = worse (e.g., available memory %)
        if (( value <= crit )); then
            state="CRITICAL"
            detail="$crit_detail"
        elif (( value <= warn )); then
            state="WARNING"
            detail="$warn_detail"
        fi
    else
        # Standard metrics: higher value = worse (e.g., CPU load %)
        if (( value >= crit )); then
            state="CRITICAL"
            detail="$crit_detail"
        elif (( value >= warn )); then
            state="WARNING"
            detail="$warn_detail"
        fi
    fi
    
    check_state_change "$key" "$state" "$detail"
    
    # Set global variables for caller to check
    THRESHOLD_STATE="$state"
    THRESHOLD_DETAIL="$detail"
}

# ===========================================================================
check_cpu() {
    [[ -f /proc/loadavg ]] || { log "WARN" "check_cpu: /proc/loadavg not found — skipping"; return; }
    
    local cores
    cores=$(nproc 2>/dev/null) || cores=1
    if ! is_valid_number "$cores" || [[ "$cores" -lt 1 ]]; then
        log "WARN" "check_cpu: nproc returned '${cores}', defaulting to 1"
        cores=1
    fi
    
    local load_1m
    load_1m=$(awk '{print $1}' /proc/loadavg)
    if [[ -z "$load_1m" || ! "$load_1m" =~ ^[0-9.]+$ ]]; then
        log "WARN" "check_cpu: invalid load value from /proc/loadavg — skipping"
        return
    fi

    # Calculate load as percentage of cores (bash integer math, x100 for precision)
    local load_pct
    load_pct=$(awk -v ld="$load_1m" -v cores="$cores" 'BEGIN {printf "%.0f", (ld / cores) * 100}')
    if [[ -z "$load_pct" ]] || ! is_valid_number "$load_pct"; then
        log "WARN" "check_cpu: computed load_pct '${load_pct}' is not numeric — skipping"
        return
    fi

    # Use check_threshold helper for consistent threshold handling
    check_threshold "cpu" "$load_pct" \
        "${CPU_THRESHOLD_WARN:-70}" \
        "${CPU_THRESHOLD_CRIT:-80}" \
        "false" \
        "CPU load ${load_1m} (${load_pct}% of ${cores} cores)" \
        "CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_WARN}%)" \
        "CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_CRIT}%)"
    
    # Capture top processes if CPU is under stress
    if [[ "${THRESHOLD_STATE:-OK}" == "WARNING" || "${THRESHOLD_STATE:-OK}" == "CRITICAL" ]]; then
        TOP_PROCESSES_INFO=$(get_top_processes "${TOP_PROCESS_COUNT:-5}")
    fi
}

# ===========================================================================
# CHECK: Memory
# ===========================================================================
check_memory() {
    [[ -f /proc/meminfo ]] || { log "WARN" "check_memory: /proc/meminfo not found — skipping"; return; }
    local total_kb available_kb
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

    # Guard against missing or zero values
    if [[ -z "$total_kb" || "$total_kb" -eq 0 ]]; then
        log "WARN" "check_memory: MemTotal is ${total_kb:-empty} — skipping"
        return
    fi
    
    # Fallback for kernels < 3.14 without MemAvailable (estimate: MemFree + Buffers + Cached)
    if [[ -z "$available_kb" ]]; then
        local mem_free buffers cached
        mem_free=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
        buffers=$(awk '/^Buffers:/ {print $2}' /proc/meminfo)
        cached=$(awk '/^Cached:/ {print $2}' /proc/meminfo)
        available_kb=$(( ${mem_free:-0} + ${buffers:-0} + ${cached:-0} ))
        log "DEBUG" "check_memory: MemAvailable not found — using fallback calculation (kernel < 3.14)"
    fi

    # Percentage of AVAILABLE memory (not just "free")
    local avail_pct
    avail_pct=$(( (available_kb * 100) / total_kb ))

    local total_mb=$(( total_kb / 1024 ))
    local avail_mb=$(( available_kb / 1024 ))

    # Use check_threshold helper for consistent threshold handling (inverted metric: lower = worse)
    check_threshold "mem" "$avail_pct" \
        "${MEM_THRESHOLD_WARN:-15}" \
        "${MEM_THRESHOLD_CRIT:-10}" \
        "true" \
        "Memory: ${avail_mb}MB available of ${total_mb}MB (${avail_pct}% free)" \
        "Memory: only <b>${avail_mb}MB</b> available of ${total_mb}MB (<b>${avail_pct}%</b> free, threshold: ${MEM_THRESHOLD_WARN}%)" \
        "Memory: only <b>${avail_mb}MB</b> available of ${total_mb}MB (<b>${avail_pct}%</b> free, threshold: ${MEM_THRESHOLD_CRIT}%)"
    
    # Predictive: track memory usage trend (usage = 100 - available%)
    local mem_usage_pct=$(( 100 - avail_pct ))
    record_trend "predict_memory" "$mem_usage_pct"
    check_prediction "predict_memory" "Memory" "$mem_usage_pct"

    # Capture top processes if memory is under stress
    if [[ "${THRESHOLD_STATE:-OK}" == "WARNING" || "${THRESHOLD_STATE:-OK}" == "CRITICAL" ]]; then
        TOP_PROCESSES_INFO=$(get_top_processes "${TOP_PROCESS_COUNT:-5}")
    fi
}

# ===========================================================================
# CHECK: Disk Space
# ===========================================================================
check_disk() {
    # Parse df output, skip tmpfs/devtmpfs/overlay/squashfs/loop
    local filesystem size used avail pct mountpoint
    while read -r filesystem size used avail pct mountpoint; do
        [[ "$filesystem" == "Filesystem" ]] && continue
        [[ "$filesystem" == tmpfs* || "$filesystem" == devtmpfs* ]] && continue
        [[ "$filesystem" == overlay* || "$filesystem" == squashfs* ]] && continue
        [[ "$filesystem" == udev* || "$filesystem" == efivarfs* ]] && continue
        [[ "$filesystem" == /dev/loop* ]] && continue  # Skip loop-mounted ISOs
        [[ "$mountpoint" == /snap/* ]] && continue
        [[ "$mountpoint" == /boot/efi ]] && continue
        [[ "$mountpoint" == /dev || "$mountpoint" == /dev/* ]] && continue
        [[ "$mountpoint" == /sys/* ]] && continue
        [[ "$mountpoint" == /run/* ]] && continue

        local usage
        usage=$(printf '%s' "$pct" | tr -dc '0-9')  # extract digits only (strip % and any non-numeric)
        # Skip entries where df returned non-numeric usage
        if ! is_valid_number "$usage"; then
            log "WARN" "check_disk: non-numeric usage '${pct}' for ${mountpoint} — skipping"
            continue
        fi
        # Sanitize key: replace / with _ for state file
        local key="disk_$(echo "$mountpoint" | tr '/' '_' | sed 's/^_/root/')"

        local safe_mount safe_fs
        safe_mount=$(html_escape "$mountpoint")
        safe_fs=$(html_escape "$filesystem")

        local state="OK"
        local detail="Disk ${safe_mount}: ${pct} used (${safe_fs})"

        if (( usage >= ${DISK_THRESHOLD_CRIT:-90} )); then
            state="CRITICAL"
            detail="Disk <b>${safe_mount}</b>: <b>${pct}</b> used on ${safe_fs} (threshold: ${DISK_THRESHOLD_CRIT:-90}%)"
        elif (( usage >= ${DISK_THRESHOLD_WARN:-85} )); then
            state="WARNING"
            detail="Disk <b>${safe_mount}</b>: <b>${pct}</b> used on ${safe_fs} (threshold: ${DISK_THRESHOLD_WARN:-85}%)"
        fi

        check_state_change "$key" "$state" "$detail"

        # Predictive: track disk usage trend
        local predict_key="predict_${key}"
        record_trend "$predict_key" "$usage"
        check_prediction "$predict_key" "Disk ${mountpoint}" "$usage"

        # Predictive: track inode usage trend (if available)
        if [[ "${ENABLE_PREDICTIVE_ALERTS:-false}" == "true" ]]; then
            local inode_pct_raw
            inode_pct_raw=$(df -i "$mountpoint" 2>/dev/null | awk 'NR==2 {print $5}')
            if [[ -n "$inode_pct_raw" ]]; then
                local inode_usage
                inode_usage=$(printf '%s' "$inode_pct_raw" | tr -dc '0-9')
                if is_valid_number "$inode_usage" && [[ "$inode_usage" -gt 0 ]]; then
                    local inode_predict_key="predict_inode_$(echo "$mountpoint" | tr '/' '_' | sed 's/^_/root/')"
                    record_trend "$inode_predict_key" "$inode_usage"
                    check_prediction "$inode_predict_key" "Inode ${mountpoint}" "$inode_usage"
                fi
            fi
        fi
    done < <(run_with_timeout "$CHECK_TIMEOUT" df -h --output=source,size,used,avail,pcent,target 2>/dev/null)
}

# ===========================================================================
# CHECK: Internet Connectivity
# ===========================================================================
check_internet() {
    if ! command -v ping &>/dev/null; then
        log "WARN" "check_internet: ping not found — skipping (install iputils-ping for internet checks)"
        return
    fi
    local target="${PING_TARGET:-8.8.8.8}"
    if [[ -z "$target" ]]; then
        log "WARN" "check_internet: PING_TARGET is empty — skipping"
        return
    fi
    # SECURITY: Validate target is a valid hostname/IP (prevent command injection)
    if ! is_valid_hostname "$target"; then
        log "WARN" "check_internet: PING_TARGET '${target}' contains invalid characters — skipping"
        return
    fi
    # Additional validation: reject shell metacharacters
    if [[ "$target" == *"$"* || "$target" == *";"* ]]; then
        log "WARN" "check_internet: PING_TARGET '${target}' contains unsafe characters — skipping"
        return
    fi
    if ! is_valid_number "${PING_FAIL_THRESHOLD}"; then
        log "WARN" "check_internet: PING_FAIL_THRESHOLD '${PING_FAIL_THRESHOLD}' is not numeric — skipping"
        return
    fi
    
    # Wrap entire ping check in timeout to prevent indefinite hanging
    local fail_count=0
    local ping_timeout=$(( PING_FAIL_THRESHOLD * 5 ))  # 5 seconds per ping (including -W 3 + buffer)
    
    local ping_result
    ping_result=$(run_with_timeout "$ping_timeout" bash -c '
        target="$1"; threshold="$2"; count=0
        for (( i=1; i<=threshold; i++ )); do
            if ! ping -c 1 -W 3 "$target" &>/dev/null; then
                count=$(( count + 1 ))
            fi
        done
        echo "$count"
    ' _ "$target" "$PING_FAIL_THRESHOLD" 2>/dev/null) || ping_result=""
    
    # Validate result is numeric
    if is_valid_number "$ping_result"; then
        fail_count="$ping_result"
    else
        log "WARN" "check_internet: ping check timed out or failed — assuming connectivity lost"
        fail_count="$PING_FAIL_THRESHOLD"
    fi

    local state="OK"
    local safe_target
    safe_target=$(html_escape "$target")
    local detail="Internet: connectivity to ${safe_target} OK"

    if (( fail_count >= PING_FAIL_THRESHOLD )); then
        state="CRITICAL"
        detail="Internet: <b>${fail_count}/${PING_FAIL_THRESHOLD}</b> pings to ${safe_target} failed -- connectivity lost"
    elif (( fail_count > 0 )); then
        state="WARNING"
        detail="Internet: ${fail_count}/${PING_FAIL_THRESHOLD} pings to ${safe_target} failed -- intermittent"
    fi

    check_state_change "internet" "$state" "$detail"
}

# ===========================================================================
# CHECK: Swap Usage
# ===========================================================================
check_swap() {
    local swap_total swap_used swap_pct
    
    # Read swap info from /proc/swaps
    if [[ -f /proc/swaps ]]; then
        # Skip header line, sum up all swap partitions
        swap_total=0
        swap_used=0
        while read -r device type size used priority; do
            [[ "$device" == "Filename" ]] && continue
            swap_total=$((swap_total + size))
            swap_used=$((swap_used + used))
        done < /proc/swaps
        
        if [[ "$swap_total" -gt 0 ]]; then
            swap_pct=$(( (swap_used * 100) / swap_total ))
            local swap_total_mb=$(( swap_total / 1024 ))
            local swap_used_mb=$(( swap_used / 1024 ))
            
            # Use check_threshold helper for consistent threshold handling
            check_threshold "swap" "$swap_pct" \
                "${SWAP_THRESHOLD_WARN:-50}" \
                "${SWAP_THRESHOLD_CRIT:-80}" \
                "false" \
                "Swap: ${swap_used_mb}MB used of ${swap_total_mb}MB (${swap_pct}%)" \
                "Swap: <b>${swap_used_mb}MB</b> used of ${swap_total_mb}MB (<b>${swap_pct}%</b>, threshold: ${SWAP_THRESHOLD_WARN}%)" \
                "Swap: <b>${swap_used_mb}MB</b> used of ${swap_total_mb}MB (<b>${swap_pct}%</b>, threshold: ${SWAP_THRESHOLD_CRIT}%)"
            
            # Predictive: track swap usage trend
            record_trend "predict_swap" "$swap_pct"
            check_prediction "predict_swap" "Swap" "$swap_pct"
        fi
    fi
}

# ===========================================================================
# CHECK: I/O Wait (CPU waiting for disk I/O)
# Uses state file to store previous sample, calculates delta on next run
# ===========================================================================
check_iowait() {
    [[ -f /proc/stat ]] || { log "WARN" "check_iowait: /proc/stat not found — skipping"; return; }
    
    local iowait_state_file="${STATE_FILE}.iowait"
    
    # Read all CPU fields from current sample
    local -a cpu_curr
    read -r -a cpu_curr < <(awk '/^cpu / {$1=""; print}' /proc/stat)
    
    # Ensure we have at least 5 fields (user, nice, system, idle, iowait)
    if [[ ${#cpu_curr[@]} -lt 5 ]]; then
        log "WARN" "check_iowait: /proc/stat has fewer than 5 CPU fields — skipping"
        return
    fi
    
    # iowait is the 5th field (index 4)
    local iw_curr="${cpu_curr[4]}"
    
    # Calculate total of all fields for current sample
    local total_curr=0
    for (( i=0; i<${#cpu_curr[@]}; i++ )); do
        total_curr=$(( total_curr + (${cpu_curr[$i]:-0}) ))
    done
    
    # Load previous sample from state file
    local iw_prev=0 total_prev=0 prev_ts=0
    if [[ -f "$iowait_state_file" ]]; then
        read -r iw_prev total_prev prev_ts < "$iowait_state_file" 2>/dev/null || true
    fi
    
    # Validate loaded values
    if ! is_valid_number "$iw_prev" || ! is_valid_number "$total_prev" || ! is_valid_number "$prev_ts"; then
        iw_prev=0; total_prev=0; prev_ts=0
    fi
    
    # Save current sample for next run
    local now
    now=$(date +%s)
    safe_write_state_file "$iowait_state_file" "$iw_curr $total_curr $now"
    
    # Need previous reading to calculate rate
    if [[ "$prev_ts" -eq 0 ]]; then
        log "DEBUG" "check_iowait: no previous sample — baseline established"
        return
    fi
    
    # Calculate delta
    local diowait=$(( iw_curr - iw_prev ))
    local dtotal=$(( total_curr - total_prev ))
    
    # Handle counter wraparound (32-bit counters on some systems)
    if [[ "$diowait" -lt 0 ]] || [[ "$dtotal" -lt 0 ]]; then
        log "DEBUG" "check_iowait: counter wraparound detected — skipping calculation"
        return
    fi
    
    local iowait_pct=0
    if [[ "$dtotal" -gt 0 ]]; then
        iowait_pct=$(( (diowait * 100) / dtotal ))
    fi
    
    # Use check_threshold helper for consistent threshold handling
    check_threshold "iowait" "$iowait_pct" \
        "${IOWAIT_THRESHOLD_WARN:-30}" \
        "${IOWAIT_THRESHOLD_CRIT:-50}" \
        "false" \
        "I/O Wait: ${iowait_pct}% of CPU time" \
        "I/O Wait: <b>${iowait_pct}%</b> of CPU time waiting for disk (threshold: ${IOWAIT_THRESHOLD_WARN}%)" \
        "I/O Wait: <b>${iowait_pct}%</b> of CPU time waiting for disk (threshold: ${IOWAIT_THRESHOLD_CRIT}%)"
    # check_threshold already calls check_state_change
}

# ===========================================================================
# CHECK: Zombie Processes
# ===========================================================================
check_zombies() {
    local zombie_count
    zombie_count=$(ps aux | awk '$8 ~ /^Z/ {count++} END {print count+0}')
    if ! is_valid_number "$zombie_count"; then
        log "WARN" "check_zombies: non-numeric zombie_count '${zombie_count}' — skipping"
        return
    fi
    
    # Use check_threshold helper for consistent threshold handling
    check_threshold "zombies" "$zombie_count" \
        "${ZOMBIE_THRESHOLD_WARN:-5}" \
        "${ZOMBIE_THRESHOLD_CRIT:-20}" \
        "false" \
        "Zombie processes: ${zombie_count}" \
        "Zombie processes: <b>${zombie_count}</b> (threshold: ${ZOMBIE_THRESHOLD_WARN})" \
        "Zombie processes: <b>${zombie_count}</b> (threshold: ${ZOMBIE_THRESHOLD_CRIT})"
    # check_threshold already calls check_state_change
}

# ===========================================================================
# HELPER: Get Top CPU/Memory Processes
# Called when CPU or Memory is in WARNING/CRITICAL state
# Returns: formatted string for alerts
# ===========================================================================
get_top_processes() {
    # Graceful skip if ps is not available (minimal containers)
    if ! command -v ps &>/dev/null; then
        echo ""
        return
    fi

    local count="${1:-5}"
    # Validate count is a positive integer in reasonable range
    if ! is_valid_number "$count" || [[ "$count" -lt 1 ]] || [[ "$count" -gt 50 ]]; then
        count=5
    fi
    local raw_cpu raw_mem
    raw_cpu=$(ps aux --sort=-%cpu | head -$((count + 1)) | tail -${count} | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd (i>11?" ":"") $i; printf "  %s %5s%% %s\n", $2, $3, cmd}')
    raw_mem=$(ps aux --sort=-%mem | head -$((count + 1)) | tail -${count} | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd (i>11?" ":"") $i; printf "  %s %5s%% %s\n", $2, $4, cmd}')
    # Escape HTML entities to prevent Telegram parse errors from process names
    raw_cpu=$(html_escape "$raw_cpu")
    raw_mem=$(html_escape "$raw_mem")
    local output=""
    output+="<pre>Top ${count} processes by CPU:"$'\n'
    output+="${raw_cpu}"
    output+=$'\n\n'"Top ${count} processes by Memory:"$'\n'
    output+="${raw_mem}"
    output+="</pre>"
    echo "$output"
}

# Global variable to store top processes info for alerts
TOP_PROCESSES_INFO=""

# ===========================================================================
# CHECK: System Processes (via pgrep / systemctl)
# ===========================================================================
check_system_processes() {
    [[ -z "${CRITICAL_SYSTEM_PROCESSES:-}" ]] && return
    for proc in $CRITICAL_SYSTEM_PROCESSES; do
        local safe_proc
        safe_proc=$(html_escape "$proc")
        local state="OK"
        local detail="Process <code>${safe_proc}</code> is running"

        # First check if process exists via pgrep
        if pgrep -x "$proc" &>/dev/null; then
            state="OK"
        else
            # Check systemd service status (if systemctl is available)
            if ! command -v systemctl &>/dev/null; then
                state="CRITICAL"
                detail="Process <code>${safe_proc}</code> is <b>NOT running</b> (no systemd)"
                check_state_change "proc_$(sanitize_state_key "$proc")" "$state" "$detail"
                continue
            fi
            local systemd_status
            systemd_status=$(run_with_timeout "$CHECK_TIMEOUT" systemctl show -p ActiveState --value "$proc" 2>/dev/null || echo "unknown")
            
            case "$systemd_status" in
                active)
                    state="OK"
                    ;;
                failed)
                    state="CRITICAL"
                    detail="Systemd service <code>${safe_proc}</code> has <b>FAILED</b> - check logs with: journalctl -u ${safe_proc}"
                    ;;
                activating)
                    state="WARNING"
                    detail="Systemd service <code>${safe_proc}</code> is <b>still starting</b> (may be stuck)"
                    ;;
                inactive|dead)
                    state="CRITICAL"
                    detail="Systemd service <code>${safe_proc}</code> is <b>inactive/stopped</b>"
                    ;;
                *)
                    state="CRITICAL"
                    detail="Process <code>${safe_proc}</code> is <b>NOT running</b> (status: $(html_escape "$systemd_status"))"
                    ;;
            esac
        fi

        check_state_change "proc_$(sanitize_state_key "$proc")" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: Failed Systemd Services (system-wide)
# ===========================================================================
check_failed_systemd_services() {
    if ! command -v systemctl &>/dev/null; then
        log "DEBUG" "check_failed_systemd_services: systemctl not found — skipping"
        return
    fi
    # Get list of failed services using --state=failed for reliable output
    local failed_services
    local systemctl_output
    systemctl_output=$(run_with_timeout "$CHECK_TIMEOUT" systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null) || {
        log "WARN" "check_failed_systemd_services: systemctl timed out or failed — skipping"
        return
    }
    failed_services=$(echo "$systemctl_output" | awk 'NF > 0 {print $1}' || true)
    
    if [[ -n "$failed_services" ]]; then
        local count
        count=$(echo "$failed_services" | wc -l)
        
        local state="CRITICAL"
        local detail="<b>${count} failed systemd service(s):</b>"
        
        # List first 3 failed services
        local service_list
        service_list=$(echo "$failed_services" | head -3 | tr '\n' ' ')
        detail+=" $(html_escape "$service_list")"
        
        if [[ "$count" -gt 3 ]]; then
            detail+=" (+$((count - 3)) more)"
        fi
        
        check_state_change "systemd_failed" "$state" "$detail"
    else
        # No failed services - mark as OK if previously in another state
        check_state_change "systemd_failed" "OK" "All systemd services healthy"
    fi
}

# ===========================================================================
# CHECK: Docker Containers
# ===========================================================================
check_docker_containers() {
    # Skip if no containers configured
    [[ -z "${CRITICAL_CONTAINERS:-}" ]] && return

    # Bail if docker is not available
    if ! command -v docker &>/dev/null; then
        check_state_change "docker_engine" "CRITICAL" "Docker engine not found on PATH"
        return
    fi

    for container in $CRITICAL_CONTAINERS; do
        local safe_container
        safe_container=$(html_escape "$container")
        local state="OK"
        local detail="Container <code>${safe_container}</code> is running"

        local status
        status=$(run_with_timeout "$CHECK_TIMEOUT" docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "missing")

        case "$status" in
            running)
                state="OK"
                # Also check health if available
                local health
                health=$(run_with_timeout "$CHECK_TIMEOUT" docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
                if [[ "$health" == "unhealthy" ]]; then
                    state="WARNING"
                    detail="Container <code>${safe_container}</code> is running but <b>unhealthy</b>"
                fi
                ;;
            restarting)
                state="WARNING"
                detail="Container <code>${safe_container}</code> is <b>restarting</b>"
                ;;
            missing|"")
                state="CRITICAL"
                detail="Container <code>${safe_container}</code> <b>does not exist</b>"
                ;;
            *)
                state="CRITICAL"
                detail="Container <code>${safe_container}</code> status: <b>${status}</b>"
                ;;
        esac

        check_state_change "container_$(sanitize_state_key "$container")" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: PM2 Processes
# ===========================================================================
check_pm2_processes() {
    local pm2_bin="pm2"
    if ! command -v pm2 &>/dev/null; then
        # Try common paths
        pm2_bin=""
        for candidate in "${HOME}/.npm-global/bin/pm2" /usr/local/bin/pm2 /usr/bin/pm2; do
            if [[ -x "$candidate" ]]; then
                pm2_bin="$candidate"
                break
            fi
        done
        if [[ -z "$pm2_bin" ]]; then
            check_state_change "pm2_engine" "CRITICAL" "PM2 not found on PATH"
            return
        fi
    fi

    [[ -z "${CRITICAL_PM2_PROCESSES:-}" ]] && return

    local jlist
    jlist=$(run_with_timeout "$CHECK_TIMEOUT" "$pm2_bin" jlist 2>/dev/null) || jlist="[]"

    for proc in $CRITICAL_PM2_PROCESSES; do
        local safe_proc
        safe_proc=$(html_escape "$proc")
        local state="OK"
        local detail="PM2 process <code>${safe_proc}</code> is online"

        local pm2_status
        pm2_status=$(TELEMON_PROC_NAME="$proc" python3 -c "
import sys, json, os
try:
    target = os.environ['TELEMON_PROC_NAME']
    data = json.load(sys.stdin)
    for p in data:
        if p.get('name') == target:
            print(p.get('pm2_env', {}).get('status', 'unknown'))
            sys.exit(0)
    print('missing')
except Exception:
    print('error')
" <<< "$jlist" 2>/dev/null) || pm2_status="error"
        # Trim to first line only (pm2 can emit banners on stderr)
        pm2_status="${pm2_status%%$'\n'*}"
        # Escape HTML to prevent Telegram parse errors
        pm2_status=$(html_escape "$pm2_status")

        case "$pm2_status" in
            online)
                state="OK"
                ;;
            stopped|stopping)
                state="CRITICAL"
                detail="PM2 process <code>${safe_proc}</code> is <b>${pm2_status}</b>"
                ;;
            errored)
                state="CRITICAL"
                detail="PM2 process <code>${safe_proc}</code> has <b>errored</b>"
                ;;
            missing)
                state="CRITICAL"
                detail="PM2 process <code>${safe_proc}</code> <b>not found</b> in PM2 list"
                ;;
            *)
                state="WARNING"
                detail="PM2 process <code>${safe_proc}</code> status: <b>${pm2_status}</b>"
                ;;
        esac

        check_state_change "pm2_$(sanitize_state_key "$proc")" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: NVMe / SMART Health
# Uses smartctl to check critical_warning, media errors, temp, and % used
# Only runs if smartctl is available
# ===========================================================================
check_nvme_health() {
    local device="${NVME_DEVICE:-/dev/nvme0n1}"
    local safe_device
    safe_device=$(html_escape "$device")
    
    if ! command -v smartctl &>/dev/null; then
        return
    fi
    
    if [[ ! -b "$device" ]]; then
        return
    fi
    
    local smart_out
    smart_out=$(run_with_timeout "$CHECK_TIMEOUT" smartctl -A "$device" 2>/dev/null) || smart_out=""
    
    if [[ -z "$smart_out" ]]; then
        check_state_change "nvme_health" "WARNING" "NVMe <code>${safe_device}</code>: smartctl returned no output"
        return
    fi
    
    # Parse key fields
    local critical_warning pct_used temp media_errors
    critical_warning=$(echo "$smart_out" | awk '/Critical Warning:/ {print $NF}')
    pct_used=$(echo "$smart_out"         | awk '/Percentage Used:/ {gsub(/%/,""); print $NF}')
    temp=$(echo "$smart_out"             | awk '/^Temperature:/ {print $2}')
    media_errors=$(echo "$smart_out"     | awk '/Media and Data Integrity Errors:/ {gsub(/,/,""); print $NF}')
    
    # Validate numeric fields (smartctl output format varies by drive/firmware)
    [[ -n "$pct_used" ]] && ! is_valid_number "$pct_used" && pct_used=""
    [[ -n "$temp" ]] && ! is_valid_number "$temp" && temp=""
    [[ -n "$media_errors" ]] && ! is_valid_number "$media_errors" && media_errors=""

    local state="OK"
    local issues=""
    
    # Critical warning byte (non-zero = drive is reporting a problem)
    if [[ -n "$critical_warning" && "$critical_warning" != "0x00" ]]; then
        state="CRITICAL"
        issues+=" critical_warning=${critical_warning}"
    fi
    
    # Endurance used: warn at 80%, crit at 95%
    if [[ -n "$pct_used" ]]; then
        if (( pct_used >= 95 )); then
            state="CRITICAL"
            issues+=" endurance=${pct_used}%"
        elif (( pct_used >= 80 )); then
            [[ "$state" == "OK" ]] && state="WARNING"
            issues+=" endurance=${pct_used}%"
        fi
    fi
    
    # Temperature thresholds
    local nvme_temp_warn="${NVME_TEMP_THRESHOLD_WARN:-70}"
    local nvme_temp_crit="${NVME_TEMP_THRESHOLD_CRIT:-80}"
    if [[ -n "$temp" ]]; then
        if (( temp >= nvme_temp_crit )); then
            state="CRITICAL"
            issues+=" temp=${temp}°C"
        elif (( temp >= nvme_temp_warn )); then
            [[ "$state" == "OK" ]] && state="WARNING"
            issues+=" temp=${temp}°C"
        fi
    fi
    
    local detail
    if [[ "$state" == "OK" ]]; then
        detail="NVMe <code>${safe_device}</code> healthy (temp=${temp}°C, used=${pct_used}%, media_errors=${media_errors})"
    else
        detail="NVMe <code>${safe_device}</code> <b>${state}</b>:${issues} (temp=${temp}°C, used=${pct_used}%, media_errors=${media_errors})"
    fi
    
    check_state_change "nvme_health" "$state" "$detail"
}

# ===========================================================================
# CHECK: Website/Site Reachability Monitor
# Monitors HTTP/HTTPS endpoints for availability, response time, and SSL expiry
# ===========================================================================
check_sites() {
    # Parse space-separated list of site URLs
    [[ -z "${CRITICAL_SITES:-}" ]] && return
    for site in $CRITICAL_SITES; do
        # Parse optional parameters from URL format:
        # https://example.com|expected_status=200|max_response_ms=5000|check_ssl=true
        local url="${site%%|*}"
        local params="${site#*|}"
        
        # Skip if no URL
        [[ -z "$url" ]] && continue
        
        # SECURITY: SSRF protection — block internal/reserved IP addresses
        # Extract host from URL for validation
        local host_for_validation="${url#*://}"
        host_for_validation="${host_for_validation%%/*}"
        host_for_validation="${host_for_validation%%:*}"
        
        # Skip SSRF check if explicitly allowed (for monitoring local services like Plex)
        if [[ "${SITE_ALLOW_INTERNAL:-false}" != "true" ]]; then
            if is_internal_ip "$host_for_validation"; then
                log "WARN" "check_sites: internal/reserved IP '${host_for_validation}' blocked in URL '${url}' — skipping (SSRF protection). Set SITE_ALLOW_INTERNAL=true to allow."
                continue
            fi
        fi
        
        # Default parameters
        local expected_status="${SITE_EXPECTED_STATUS:-200}"
        local max_response_ms="${SITE_MAX_RESPONSE_MS:-10000}"
        local check_ssl="${SITE_CHECK_SSL:-false}"
        local ssl_warn_days="${SITE_SSL_WARN_DAYS:-7}"
        
        # Parse custom parameters if present
        if [[ "$site" == *"|"* ]]; then
            # Extract parameters: split on | then split each segment on first =
            local remaining="${site#*|}"
            while [[ -n "$remaining" ]]; do
                local segment="${remaining%%|*}"
                if [[ "$segment" == *"="* ]]; then
                    local pkey="${segment%%=*}"
                    local pval="${segment#*=}"
                    case "$pkey" in
                        expected_status) expected_status="$pval" ;;
                        max_response_ms) max_response_ms="$pval" ;;
                        check_ssl) check_ssl="$pval" ;;
                        ssl_warn_days) ssl_warn_days="$pval" ;;
                    esac
                fi
                # Advance: if no more |, we're done
                [[ "$remaining" == *"|"* ]] || break
                remaining="${remaining#*|}"
            done
        fi

        # Validate numeric parameters, fall back to defaults
        if ! is_valid_number "$expected_status"; then
            log "WARN" "check_sites: invalid expected_status '${expected_status}' for ${url} — using default"
            expected_status="${SITE_EXPECTED_STATUS:-200}"
        elif [[ "$expected_status" -lt 100 ]] || [[ "$expected_status" -gt 599 ]]; then
            log "WARN" "check_sites: expected_status '${expected_status}' out of range (100-599) for ${url} — using default"
            expected_status="${SITE_EXPECTED_STATUS:-200}"
        fi
        if ! is_valid_number "$max_response_ms"; then
            log "WARN" "check_sites: invalid max_response_ms '${max_response_ms}' for ${url} — using default"
            max_response_ms="${SITE_MAX_RESPONSE_MS:-10000}"
        elif [[ "$max_response_ms" -lt 1 ]]; then
            log "WARN" "check_sites: max_response_ms '${max_response_ms}' must be >= 1 for ${url} — using default"
            max_response_ms="${SITE_MAX_RESPONSE_MS:-10000}"
        fi
        if ! is_valid_number "$ssl_warn_days"; then
            ssl_warn_days="${SITE_SSL_WARN_DAYS:-7}"
        fi
        
        # Hash-based key for state file (avoids collisions from regex sanitization)
        local key
        key=$(make_state_key "site" "$url")
        
        local state="OK"
        local detail=""
        
        # Retrieve SSL certificate expiry if HTTPS and SSL check enabled
        local ssl_expiry_epoch=""
        if [[ "$url" == https://* ]] && [[ "$check_ssl" == "true" ]]; then
            local host_for_ssl="${url#https://}"
            host_for_ssl="${host_for_ssl%%/*}"
            host_for_ssl="${host_for_ssl%%:*}"
            if command -v openssl &>/dev/null; then
                local cert_enddate
                # Use timeout wrapper to prevent hanging on slow/unresponsive SSL servers
                cert_enddate=$(run_with_timeout "$CHECK_TIMEOUT" bash -c '
                    echo | openssl s_client -servername "$1" -connect "$1:443" 2>/dev/null | \
                    openssl x509 -noout -enddate 2>/dev/null | sed "s/notAfter=//"
                ' _ "$host_for_ssl" 2>/dev/null) || cert_enddate=""
                if [[ -n "$cert_enddate" ]]; then
                    ssl_expiry_epoch=$(parse_date_to_epoch "$cert_enddate")
                    # Guard: treat parse failure (empty or "0") as no SSL data
                    if [[ -z "$ssl_expiry_epoch" || "$ssl_expiry_epoch" == "0" ]]; then
                        log "WARN" "check_sites: could not parse SSL cert date '${cert_enddate}' — skipping expiry check"
                        ssl_expiry_epoch=""
                    fi
                fi
            fi
        fi
        
        # Perform the HTTP check (direct curl, no shell interpolation)
        local response
        response=$(run_with_timeout "$CHECK_TIMEOUT" \
            curl -s -o /dev/null \
                -w '%{http_code}|%{time_total}|%{redirect_url}|%{ssl_verify_result}' \
                --max-time $(( max_response_ms / 1000 + 5 )) \
                -L \
                "$url" 2>/dev/null) || response="000|0|||1"
        
        local http_code="${response%%|*}"
        local rest="${response#*|}"
        local response_time="${rest%%|*}"
        rest="${rest#*|}"
        local redirect_url="${rest%%|*}"
        rest="${rest#*|}"
        local ssl_verify="${rest%%|*}"
        
        # Convert response time to milliseconds (validate numeric input)
        local response_ms=0
        if [[ "$response_time" =~ ^[0-9.]+$ ]]; then
            response_ms=$(awk -v rt="$response_time" 'BEGIN {printf "%.0f", rt * 1000}' 2>/dev/null || echo "0")
        fi
        
        # Determine state based on checks
        if [[ "$http_code" == "000" ]]; then
            state="CRITICAL"
            detail="Site <code>$(html_escape "$url")</code> is <b>UNREACHABLE</b> - connection failed"
        elif [[ "$http_code" != "$expected_status" ]]; then
            state="CRITICAL"
            detail="Site <code>$(html_escape "$url")</code> returned HTTP <b>${http_code}</b> (expected: ${expected_status})"
        elif [[ "$response_ms" -gt "$max_response_ms" ]]; then
            state="WARNING"
            detail="Site <code>$(html_escape "$url")</code> slow response: <b>${response_ms}ms</b> (threshold: ${max_response_ms}ms)"
        else
            state="OK"
            detail="Site <code>$(html_escape "$url")</code> healthy (${http_code}, ${response_ms}ms)"
        fi
        
        # Check SSL certificate expiry if enabled and HTTPS (even on non-OK, unless connection failed)
        if [[ "$http_code" != "000" ]] && [[ "$url" == https://* ]] && [[ "$check_ssl" == "true" ]] && [[ -n "$ssl_expiry_epoch" ]] && [[ "$ssl_expiry_epoch" != "0" ]]; then
            local now_timestamp
            now_timestamp=$(date +%s)
            local days_until_expiry=$(( (ssl_expiry_epoch - now_timestamp) / 86400 ))
            
            if [[ "$days_until_expiry" -le 0 ]]; then
                # EXPIRED: always CRITICAL (upgrade or same)
                state="CRITICAL"
                detail="Site <code>$(html_escape "$url")</code> SSL certificate <b>EXPIRED</b>"
            elif [[ "$days_until_expiry" -le "$ssl_warn_days" ]]; then
                # Expiring soon: only upgrade to WARNING if currently OK
                if [[ "$state" == "OK" ]]; then
                    state="WARNING"
                    detail="Site <code>$(html_escape "$url")</code> SSL expires in <b>${days_until_expiry} days</b>"
                fi
            fi
        fi
        
        # Check SSL verification errors — only upgrade state severity, never downgrade
        if [[ "$http_code" != "000" ]] && [[ "$url" == https://* ]] && [[ "$ssl_verify" != "" ]] && [[ "$ssl_verify" != "0" ]]; then
            if [[ "$state" == "OK" ]]; then
                state="WARNING"
                detail="Site <code>$(html_escape "$url")</code> has <b>SSL certificate issues</b> (verify code: ${ssl_verify})"
            fi
        fi
        
        check_state_change "$key" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: TCP Port Reachability
# Tests connectivity to host:port pairs defined in CRITICAL_PORTS
# ===========================================================================
check_tcp_ports() {
    [[ -z "${CRITICAL_PORTS:-}" ]] && return
    
    # Check if bash supports /dev/tcp (some minimal builds don't)
    if [[ ! -e /dev/tcp ]]; then
        # Try to create a test connection to see if feature works
        if ! bash -c 'echo test >/dev/tcp/localhost/1' 2>/dev/null; then
            log "DEBUG" "check_tcp_ports: /dev/tcp not supported in this bash build — skipping"
            return
        fi
    fi
    
    for entry in $CRITICAL_PORTS; do
        local host="${entry%%:*}"
        local port="${entry##*:}"
        # Trim whitespace
        host="${host// /}"
        port="${port// /}"
        [[ -z "$host" || -z "$port" ]] && continue

        # SECURITY: Validate hostname to prevent command injection via /dev/tcp
        if ! is_valid_hostname "$host"; then
            log "WARN" "check_tcp_ports: invalid host '${host}' in entry '${entry}' — skipping (only a-z, 0-9, ., _, - allowed)"
            continue
        fi

        # Validate port is numeric to prevent injection
        if ! is_valid_number "$port"; then
            log "WARN" "check_tcp_ports: invalid port '${port}' in entry '${entry}' — skipping"
            continue
        fi
        
        # Validate port is in valid range (1-65535)
        if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
            log "WARN" "check_tcp_ports: port '${port}' out of range (1-65535) in entry '${entry}' — skipping"
            continue
        fi

        local safe_host
        safe_host=$(html_escape "$host")
        # Hash-based key to avoid collisions from sanitization (e.g., host-1 vs host.1)
        local key
        key=$(make_state_key "port" "$entry")
        local state="OK"
        local detail="TCP port <code>${safe_host}:${port}</code> is reachable"

        if ! run_with_timeout "$CHECK_TIMEOUT" bash -c 'echo >/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null; then
            state="CRITICAL"
            detail="TCP port <code>${safe_host}:${port}</code> is <b>UNREACHABLE</b>"
        fi

        check_state_change "$key" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: CPU Temperature (via lm-sensors)
# Parses sensors output for package/core temps
# ===========================================================================
check_cpu_temp() {
    if ! command -v sensors &>/dev/null; then
        log "WARN" "CPU temp check: lm-sensors not installed — skipping (install lm-sensors for temperature monitoring)"
        return
    fi

    local sensors_out
    sensors_out=$(run_with_timeout "$CHECK_TIMEOUT" sensors 2>/dev/null) || return

    # Try Package temp first (max across all packages for multi-socket), fall back to first Core temp
    local temp=""
    temp=$(echo "$sensors_out" | awk '/^Package id [0-9]+:/ {gsub(/[+°C]/, "", $4); if ($4+0 > max+0) max=$4} END {if (max!="") print max}')
    if [[ -z "$temp" ]]; then
        temp=$(echo "$sensors_out" | awk '/^Core [0-9]+:/ {gsub(/[+°C]/, "", $3); if ($3+0 > max+0) max=$3} END {if (max!="") print max}')
    fi
    [[ -z "$temp" ]] && return

    # Truncate to integer
    local temp_int="${temp%%.*}"

    # Use check_threshold helper for consistent threshold handling
    check_threshold "cpu_temp" "$temp_int" \
        "${TEMP_THRESHOLD_WARN:-75}" \
        "${TEMP_THRESHOLD_CRIT:-90}" \
        "false" \
        "CPU temperature: ${temp}°C" \
        "CPU temperature: <b>${temp}°C</b> (threshold: ${TEMP_THRESHOLD_WARN}°C)" \
        "CPU temperature: <b>${temp}°C</b> (threshold: ${TEMP_THRESHOLD_CRIT}°C)"
}

# ===========================================================================
# CHECK: DNS Resolution Health
# Tests name resolution against configurable domain
# ===========================================================================
check_dns() {
    local domain="${DNS_CHECK_DOMAIN:-example.com}"

    local state="OK"
    local safe_domain
    safe_domain=$(html_escape "$domain")
    local detail="DNS resolution for <code>${safe_domain}</code> OK"

    # Try dig first, fall back to nslookup, then host
    local resolved=false
    if command -v dig &>/dev/null; then
        if run_with_timeout 10 dig +short +time=3 "$domain" 2>/dev/null | grep -qE '^[0-9.]+$|^[a-zA-Z0-9._-]+\.$'; then
            resolved=true
        fi
    elif command -v nslookup &>/dev/null; then
        if run_with_timeout 10 nslookup "$domain" &>/dev/null; then
            resolved=true
        fi
    elif command -v host &>/dev/null; then
        if run_with_timeout 10 host "$domain" &>/dev/null; then
            resolved=true
        fi
    else
        log "WARN" "DNS check: no resolver tool found (dig/nslookup/host) — skipping (install dnsutils or bind-utils for DNS monitoring)"
        return
    fi

    if [[ "$resolved" != "true" ]]; then
        state="CRITICAL"
        detail="DNS resolution for <code>${safe_domain}</code> <b>FAILED</b>"
    fi

    check_state_change "dns" "$state" "$detail"
}

# ===========================================================================
# CHECK: GPU Usage/Temperature (nvidia-smi)
# ===========================================================================
check_gpu() {
    # Try NVIDIA first
    if command -v nvidia-smi &>/dev/null; then
        check_gpu_nvidia
        return
    fi
    
    # Try Intel GPU
    if command -v intel_gpu_top &>/dev/null; then
        check_gpu_intel
        return
    fi
    
    log "WARN" "GPU check: neither nvidia-smi nor intel_gpu_top found — skipping (install nvidia-utils for NVIDIA or intel-gpu-tools for Intel GPU monitoring)"
}

# ===========================================================================
# CHECK: NVIDIA GPU (via nvidia-smi)
# ===========================================================================
check_gpu_nvidia() {
    local gpu_info
    gpu_info=$(run_with_timeout "$CHECK_TIMEOUT" nvidia-smi --query-gpu=index,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null) || return

    while IFS=',' read -r idx temp util mem_used mem_total; do
        # Trim leading/trailing spaces from CSV fields
        idx="${idx## }"; idx="${idx%% }"
        temp="${temp## }"; temp="${temp%% }"
        util="${util## }"; util="${util%% }"
        mem_used="${mem_used## }"; mem_used="${mem_used%% }"
        mem_total="${mem_total## }"; mem_total="${mem_total%% }"
        [[ -z "$idx" ]] && continue
        # Validate idx is numeric
        if ! is_valid_number "$idx"; then
            log "WARN" "check_gpu: non-numeric GPU index '${idx}' — skipping"
            continue
        fi
        # Validate numeric fields from nvidia-smi
        if ! is_valid_number "$temp"; then
            log "WARN" "check_gpu: GPU ${idx} returned non-numeric temperature '${temp}' — skipping"
            continue
        fi
        # Validate remaining numeric fields (defense-in-depth)
        is_valid_number "$util" || util="?"
        is_valid_number "$mem_used" || mem_used="?"
        is_valid_number "$mem_total" || mem_total="?"
        local key="gpu_${idx}"

        local warn="${GPU_TEMP_THRESHOLD_WARN:-80}"
        local crit="${GPU_TEMP_THRESHOLD_CRIT:-95}"

        # HTML-escape non-numeric fields that may contain unexpected chars
        local safe_util safe_mem_used safe_mem_total
        safe_util=$(html_escape "$util")
        safe_mem_used=$(html_escape "$mem_used")
        safe_mem_total=$(html_escape "$mem_total")

        local state="OK"
        local detail="GPU ${idx}: ${temp}°C, util ${safe_util}%, VRAM ${safe_mem_used}/${safe_mem_total} MiB"

        if (( temp >= crit )); then
            state="CRITICAL"
            detail="GPU ${idx}: <b>${temp}°C</b> (threshold: ${crit}°C), util ${safe_util}%, VRAM ${safe_mem_used}/${safe_mem_total} MiB"
        elif (( temp >= warn )); then
            state="WARNING"
            detail="GPU ${idx}: <b>${temp}°C</b> (threshold: ${warn}°C), util ${safe_util}%, VRAM ${safe_mem_used}/${safe_mem_total} MiB"
        fi

        check_state_change "$key" "$state" "$detail"
    done <<< "$gpu_info"
}

# ===========================================================================
# CHECK: Intel GPU (via intel_gpu_top)
# ===========================================================================
check_gpu_intel() {
    # intel_gpu_top requires root access to GPU metrics
    # Use single sample mode with short duration to avoid hanging
    local gpu_data
    gpu_data=$(run_with_timeout 3 bash -c 'intel_gpu_top -s 1000 -o - 2>/dev/null | head -50' 2>/dev/null) || {
        log "DEBUG" "check_gpu: intel_gpu_top failed or timed out (may need root)"
        return
    }
    
    [[ -z "$gpu_data" ]] && {
        log "DEBUG" "check_gpu: intel_gpu_top returned no data"
        return
    }
    
    # Parse the output for render and video utilization
    # Sample output includes lines like:
    # "engines": { "Render": { "busy": 23.4 }, "Video": { "busy": 0.0 } }
    # "frequency": { "actual": 450 }
    
    local render_busy="0"
    local video_busy="0"
    local freq="0"
    local temp=""
    
    # Try to parse JSON-like output from intel_gpu_top
    if echo "$gpu_data" | grep -q '"busy":'; then
        render_busy=$(echo "$gpu_data" | grep -oP '"Render".*?"busy":\s*\K[0-9.]+' | head -1 || echo "0")
        video_busy=$(echo "$gpu_data" | grep -oP '"Video".*?"busy":\s*\K[0-9.]+' | head -1 || echo "0")
        freq=$(echo "$gpu_data" | grep -oP '"actual":\s*\K[0-9]+' | head -1 || echo "0")
    fi
    
    # Get temperature from hwmon if available (standard Linux thermal interface)
    for hwmon in /sys/class/drm/card*/device/hwmon/hwmon*/temp1_input; do
        if [[ -r "$hwmon" ]]; then
            local temp_milli
            temp_milli=$(cat "$hwmon" 2>/dev/null) && {
                temp=$(( temp_milli / 1000 ))
                break
            }
        fi
    done
    
    # Also check alternative hwmon path
    if [[ -z "$temp" ]]; then
        for hwmon in /sys/class/hwmon/hwmon*/temp1_input; do
            if [[ -r "$hwmon" ]]; then
                # Verify this is a GPU temp by checking the name
                local name_path="${hwmon%/*}/name"
                if [[ -r "$name_path" ]]; then
                    local name
                    name=$(cat "$name_path" 2>/dev/null)
                    if [[ "$name" == "i915" || "$name" == "intel"* ]]; then
                        local temp_milli
                        temp_milli=$(cat "$hwmon" 2>/dev/null) && {
                            temp=$(( temp_milli / 1000 ))
                            break
                        }
                    fi
                fi
            fi
        done
    fi
    
    # Convert to integers for comparison
    local render_int=${render_busy%.*}
    local video_int=${video_busy%.*}
    [[ -z "$render_int" ]] && render_int=0
    [[ -z "$video_int" ]] && video_int=0
    
    local key="gpu_intel"
    local warn_util="${GPU_INTEL_UTIL_THRESHOLD_WARN:-80}"
    local crit_util="${GPU_INTEL_UTIL_THRESHOLD_CRIT:-95}"
    local warn_temp="${GPU_INTEL_TEMP_THRESHOLD_WARN:-80}"
    local crit_temp="${GPU_INTEL_TEMP_THRESHOLD_CRIT:-95}"
    
    local state="OK"
    local temp_str=""
    [[ -n "$temp" ]] && temp_str=", ${temp}°C"
    
    local detail="Intel GPU: ${render_int}% render, ${video_int}% video${temp_str}, ${freq} MHz"
    
    # Determine worst state based on utilization or temperature
    if (( render_int >= crit_util )) || [[ -n "$temp" && "$temp" -ge "$crit_temp" ]]; then
        state="CRITICAL"
        detail="Intel GPU: <b>${render_int}% render</b>, ${video_int}% video${temp_str}, ${freq} MHz"
    elif (( render_int >= warn_util )) || [[ -n "$temp" && "$temp" -ge "$warn_temp" ]]; then
        state="WARNING"
        detail="Intel GPU: <b>${render_int}% render</b>, ${video_int}% video${temp_str}, ${freq} MHz"
    fi
    
    check_state_change "$key" "$state" "$detail"
}

# ===========================================================================
# CHECK: DNS Record Monitoring - Validate specific DNS records
# Validates A, AAAA, MX, TXT, CNAME, NS, SOA records against expected values
# Supports wildcard (*) to check only resolution (not specific value)
# ===========================================================================
check_dns_records() {
    local records="${DNS_CHECK_RECORDS:-}"
    [[ -z "$records" ]] && return

    # Check for dig command (required for proper record lookups)
    if ! command -v dig &>/dev/null; then
        log "WARN" "DNS record check: dig not available — skipping (install dnsutils or bind-utils for DNS record validation)"
        return
    fi

    local nameserver="${DNS_CHECK_NAMESERVER:-}"
    local dig_opts="+short +time=3"
    [[ -n "$nameserver" ]] && dig_opts="@${nameserver} ${dig_opts}"

    # Parse comma-separated records
    local IFS=',' record_count=0
    for record in $records; do
        record_count=$((record_count + 1))

        # Parse record format: domain:record_type:expected_value
        local domain record_type expected_value
        domain="${record%%:*}"
        local rest="${record#*:}"
        record_type="${rest%%:*}"
        expected_value="${rest#*:}"

        # Validate inputs
        if [[ -z "$domain" || -z "$record_type" || -z "$expected_value" ]]; then
            log "WARN" "DNS record check: invalid record format '${record}' (expected domain:type:value)"
            continue
        fi

        # Validate domain format (basic security check)
        if ! is_valid_hostname "$domain"; then
            log "WARN" "DNS record check: invalid domain '${domain}'"
            continue
        fi

        # Normalize record type to uppercase
        record_type=$(echo "$record_type" | tr '[:lower:]' '[:upper:]')

        local state="OK"
        local detail=""
        local key="dnsrecord_${domain}_${record_type}"
        key=$(sanitize_state_key "$key")

        # Query DNS based on record type
        local resolved_values=""
        local query_result=""

        case "$record_type" in
            A)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
                ;;
            AAAA)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)
                ;;
            MX)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" MX 2>/dev/null | grep -E '^[0-9]+\s' || true)
                # Extract just the MX server names, ignore priorities
                query_result=$(echo "$query_result" | sed 's/^[0-9]\+\s\+//' || true)
                ;;
            TXT)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" TXT 2>/dev/null | grep '^"' || true)
                # Remove quotes for comparison
                query_result=$(echo "$query_result" | tr -d '"')
                ;;
            CNAME)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" CNAME 2>/dev/null | grep -E '^[a-zA-Z0-9._-]+\.?$' || true)
                ;;
            NS)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" NS 2>/dev/null | grep -E '^[a-zA-Z0-9._-]+\.?$' || true)
                ;;
            SOA)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" SOA 2>/dev/null | grep -E '^[a-zA-Z0-9._-]+\.' || true)
                ;;
            PTR)
                query_result=$(run_with_timeout 10 dig ${dig_opts} -x "$domain" 2>/dev/null | grep -E '^[a-zA-Z0-9._-]+\.?$' || true)
                ;;
            SRV)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" SRV 2>/dev/null | grep -E '^[0-9]+\s' || true)
                ;;
            CAA)
                query_result=$(run_with_timeout 10 dig ${dig_opts} "$domain" CAA 2>/dev/null | grep -E '^[0-9]+\s' || true)
                ;;
            *)
                log "WARN" "DNS record check: unsupported record type '${record_type}'"
                continue
                ;;
        esac

        # Trim trailing dots for comparison
        query_result=$(echo "$query_result" | sed 's/\.$//' 2>/dev/null || echo "$query_result")

        # Check results
        if [[ -z "$query_result" ]]; then
            state="CRITICAL"
            if [[ "$expected_value" == "*" ]]; then
                detail="DNS ${record_type} record for <code>$(html_escape "$domain")</code> <b>not resolvable</b>"
            else
                detail="DNS ${record_type} record for <code>$(html_escape "$domain")</code> <b>not found</b> (expected: $(html_escape "$expected_value"))"
            fi
        else
            # If expected value is wildcard (*), any result is OK
            if [[ "$expected_value" == "*" ]]; then
                local first_result
                first_result=$(echo "$query_result" | head -1)
                detail="DNS ${record_type} for <code>$(html_escape "$domain")</code>: $(html_escape "$first_result")"
            else
                # Check if expected value is in the results
                local found=false
                local value_line
                while IFS= read -r value_line; do
                    [[ -z "$value_line" ]] && continue
                    # Normalize: trim whitespace and trailing dots
                    value_line=$(echo "$value_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\.$//')
                    expected_value=$(echo "$expected_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\.$//')

                    # Support wildcard matching at the start (e.g., v=DMARC1*)
                    if [[ "$expected_value" == *\* ]]; then
                        local prefix="${expected_value%\*}"
                        if [[ "$value_line" == "$prefix"* ]]; then
                            found=true
                            break
                        fi
                    elif [[ "$value_line" == "$expected_value" ]]; then
                        found=true
                        break
                    fi
                done <<< "$query_result"

                if [[ "$found" == "true" ]]; then
                    detail="DNS ${record_type} for <code>$(html_escape "$domain")</code>: $(html_escape "$expected_value")"
                else
                    state="CRITICAL"
                    local actual_values
                    actual_values=$(echo "$query_result" | tr '\n' ',' | sed 's/,$//;s/,/, /g')
                    detail="DNS ${record_type} for <code>$(html_escape "$domain")</code> <b>MISMATCH</b>%0AExpected: $(html_escape "$expected_value")%0AGot: $(html_escape "$actual_values")"
                fi
            fi
        fi

        check_state_change "$key" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: Battery / UPS Status (upower or apcaccess)
# ===========================================================================
check_ups() {
    # Try upower (laptop batteries)
    if command -v upower &>/dev/null; then
        local bat_path
        bat_path=$(run_with_timeout "$CHECK_TIMEOUT" upower -e 2>/dev/null | grep -m1 'battery' || true)
        if [[ -n "$bat_path" ]]; then
            local bat_info
            bat_info=$(run_with_timeout "$CHECK_TIMEOUT" upower -i "$bat_path" 2>/dev/null)
            local bat_pct
            bat_pct=$(echo "$bat_info" | awk '/percentage:/ {gsub(/%/,""); print $2}')
            local bat_state_str
            bat_state_str=$(echo "$bat_info" | awk '/state:/ {print $2}')

            if [[ -n "$bat_pct" ]]; then
                # Use check_threshold helper for consistent threshold handling (inverted: lower = worse)
                check_threshold "battery" "$bat_pct" \
                    "${UPS_THRESHOLD_WARN:-30}" \
                    "${UPS_THRESHOLD_CRIT:-10}" \
                    "true" \
                    "Battery: ${bat_pct}% (${bat_state_str})" \
                    "Battery: <b>${bat_pct}%</b> (${bat_state_str}, threshold: ${UPS_THRESHOLD_WARN}%)" \
                    "Battery: <b>${bat_pct}%</b> (${bat_state_str}, threshold: ${UPS_THRESHOLD_CRIT}%)"
                return
            fi
        fi
    fi

    # Try apcaccess (APC UPS)
    if command -v apcaccess &>/dev/null; then
        local apc_out
        apc_out=$(run_with_timeout "$CHECK_TIMEOUT" apcaccess 2>/dev/null) || return
        local bcharge
        bcharge=$(echo "$apc_out" | awk -F: '/^BCHARGE/ {gsub(/[^0-9.]/, "", $2); printf "%.0f", $2}')
        # Guard: awk prints "0" for empty input; verify BCHARGE line actually existed
        if ! echo "$apc_out" | grep -q '^BCHARGE'; then
            bcharge=""
        fi
        local apc_status
        apc_status=$(echo "$apc_out" | awk -F: '/^STATUS/ {gsub(/^ +| +$/, "", $2); print $2}')

        if [[ -n "$bcharge" ]]; then
            # Use check_threshold helper for consistent threshold handling (inverted: lower = worse)
            check_threshold "ups" "$bcharge" \
                "${UPS_THRESHOLD_WARN:-30}" \
                "${UPS_THRESHOLD_CRIT:-10}" \
                "true" \
                "UPS: ${bcharge}% charge (${apc_status})" \
                "UPS: <b>${bcharge}%</b> charge (${apc_status}, threshold: ${UPS_THRESHOLD_WARN}%)" \
                "UPS: <b>${bcharge}%</b> charge (${apc_status}, threshold: ${UPS_THRESHOLD_CRIT}%)"
            return
        fi
    fi

    # No battery/UPS tool found — silently skip
}

# ===========================================================================
# CHECK: Database Health (MySQL, PostgreSQL, Redis)
# Monitors database connectivity and basic health metrics
# ===========================================================================
check_databases() {
    [[ "${ENABLE_DATABASE_CHECKS:-false}" == "true" ]] || return
    
    local check_timeout="${DB_CHECK_TIMEOUT:-${CHECK_TIMEOUT:-30}}"
    
    # MySQL/MariaDB Check
    if [[ -n "${DB_MYSQL_HOST:-}" ]]; then
        local mysql_state="OK"
        local mysql_detail=""
        
        if ! command -v mysql &>/dev/null; then
            log "WARN" "Database check: mysql/mariadb-client not found — skipping MySQL check"
        else
            local mysql_port="${DB_MYSQL_PORT:-3306}"
            local mysql_user="${DB_MYSQL_USER:-}"
            local mysql_pass="${DB_MYSQL_PASS:-}"
            local mysql_name="${DB_MYSQL_NAME:-mysql}"
            local mysql_host="${DB_MYSQL_HOST}"
            
            # SECURITY: Pass password via environment variable, not command line
            # Command-line args are visible in 'ps aux' on some systems
            local mysql_opts="--host=${mysql_host} --port=${mysql_port} --user=${mysql_user}"
            mysql_opts="${mysql_opts} --connect-timeout=${check_timeout}"
            
            # Test connection with a simple query - password via env var
            local mysql_result
            mysql_result=$(run_with_timeout "$check_timeout" bash -c '
                export MYSQL_PWD="$1"
                shift
                mysql "$@" -e "SELECT 1"
            ' _ "$mysql_pass" ${mysql_opts} "$mysql_name" 2>&1)
            local mysql_exit=$?
            
            if [[ $mysql_exit -ne 0 ]]; then
                mysql_state="CRITICAL"
                # Sanitize error message (remove password from output)
                local safe_error
                safe_error=$(echo "$mysql_result" | sed 's/--password=[^[:space:]]*/--password=***/g' | head -1)
                mysql_detail="MySQL <b>${mysql_host}:${mysql_port}</b> connection failed: $(html_escape "$safe_error")"
            else
                # Check replication lag if applicable
                local repl_lag
                repl_lag=$(run_with_timeout "$check_timeout" mysql ${mysql_opts} -e "SHOW SLAVE STATUS\G" 2>/dev/null | awk '/Seconds_Behind_Master:/ {print $2}')
                if [[ -n "$repl_lag" && "$repl_lag" != "NULL" ]]; then
                    if is_valid_number "$repl_lag"; then
                        if [[ "$repl_lag" -gt 300 ]]; then
                            mysql_state="CRITICAL"
                            mysql_detail="MySQL <b>${mysql_host}:${mysql_port}</b> replication lag: <b>${repl_lag}s</b> (>5 min)"
                        elif [[ "$repl_lag" -gt 60 ]]; then
                            mysql_state="WARNING"
                            mysql_detail="MySQL <b>${mysql_host}:${mysql_port}</b> replication lag: <b>${repl_lag}s</b> (>1 min)"
                        else
                            mysql_detail="MySQL <b>${mysql_host}:${mysql_port}</b> connected, replication lag: ${repl_lag}s"
                        fi
                    else
                        mysql_detail="MySQL <b>${mysql_host}:${mysql_port}</b> connected"
                    fi
                else
                    mysql_detail="MySQL <b>${mysql_host}:${mysql_port}</b> connected"
                fi
            fi
            
            check_state_change "mysql_$(sanitize_state_key "$mysql_host")" "$mysql_state" "$mysql_detail"
        fi
    fi
    
    # PostgreSQL Check
    if [[ -n "${DB_POSTGRES_HOST:-}" ]]; then
        local pg_state="OK"
        local pg_detail=""
        
        if ! command -v psql &>/dev/null; then
            log "WARN" "Database check: postgresql-client not found — skipping PostgreSQL check"
        else
            local pg_port="${DB_POSTGRES_PORT:-5432}"
            local pg_user="${DB_POSTGRES_USER:-}"
            local pg_pass="${DB_POSTGRES_PASS:-}"
            local pg_name="${DB_POSTGRES_NAME:-postgres}"
            local pg_host="${DB_POSTGRES_HOST}"
            
            # SECURITY: Pass password via environment variable, not connection string
            # Connection strings may be visible in process listings
            local pg_opts="host=${pg_host} port=${pg_port} user=${pg_user} dbname=${pg_name} connect_timeout=${check_timeout}"
            
            # Test connection - password via env var
            local pg_result
            pg_result=$(run_with_timeout "$check_timeout" bash -c '
                export PGPASSWORD="$1"
                shift
                psql "$@" -c "SELECT 1"
            ' _ "$pg_pass" "${pg_opts}" 2>&1)
            local pg_exit=$?
            
            if [[ $pg_exit -ne 0 ]]; then
                pg_state="CRITICAL"
                # Sanitize error message
                local safe_error
                safe_error=$(echo "$pg_result" | sed 's/password=[^[:space:]]*/password=***/g' | head -1)
                pg_detail="PostgreSQL <b>${pg_host}:${pg_port}</b> connection failed: $(html_escape "$safe_error")"
            else
                # Check replication lag if applicable
                local repl_lag
                repl_lag=$(run_with_timeout "$check_timeout" bash -c '
                    export PGPASSWORD="$1"
                    shift
                    psql "$@" -c "SELECT CASE WHEN pg_is_in_recovery() THEN EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) ELSE 0 END AS lag;"
                ' _ "$pg_pass" "${pg_opts}" 2>/dev/null | tail -1 | tr -d ' ')
                if [[ -n "$repl_lag" && "$repl_lag" != "0" && "$repl_lag" =~ ^[0-9.]+$ ]]; then
                    local repl_lag_int="${repl_lag%.*}"
                    if [[ "$repl_lag_int" -gt 300 ]]; then
                        pg_state="CRITICAL"
                        pg_detail="PostgreSQL <b>${pg_host}:${pg_port}</b> replication lag: <b>${repl_lag_int}s</b> (>5 min)"
                    elif [[ "$repl_lag_int" -gt 60 ]]; then
                        pg_state="WARNING"
                        pg_detail="PostgreSQL <b>${pg_host}:${pg_port}</b> replication lag: <b>${repl_lag_int}s</b> (>1 min)"
                    else
                        pg_detail="PostgreSQL <b>${pg_host}:${pg_port}</b> connected, replication lag: ${repl_lag_int}s"
                    fi
                else
                    pg_detail="PostgreSQL <b>${pg_host}:${pg_port}</b> connected"
                fi
            fi
            
            check_state_change "postgres_$(sanitize_state_key "$pg_host")" "$pg_state" "$pg_detail"
        fi
    fi
    
    # Redis Check
    if [[ -n "${DB_REDIS_HOST:-}" ]]; then
        local redis_state="OK"
        local redis_detail=""
        
        if ! command -v redis-cli &>/dev/null; then
            log "WARN" "Database check: redis-tools not found — skipping Redis check"
        else
            local redis_port="${DB_REDIS_PORT:-6379}"
            local redis_pass="${DB_REDIS_PASS:-}"
            local redis_host="${DB_REDIS_HOST}"
            local redis_timeout="${DB_REDIS_TIMEOUT_SEC:-5}"
            
            # Build redis-cli command - SECURITY: pass password via env var
            local redis_opts="-h ${redis_host} -p ${redis_port} --raw"
            # Use REDISCLI_AUTH env var instead of -a flag (visible in ps)
            
            # Test connection with PING - password via env var
            local redis_result
            redis_result=$(run_with_timeout "$redis_timeout" bash -c '
                export REDISCLI_AUTH="$1"
                shift
                redis-cli "$@" PING
            ' _ "$redis_pass" ${redis_opts} 2>&1)
            local redis_exit=$?
            
            # Check for password authentication error
            if [[ "$redis_result" == *"NOAUTH"* ]] || [[ "$redis_result" == *"authentication"* ]]; then
                redis_state="CRITICAL"
                redis_detail="Redis <b>${redis_host}:${redis_port}</b> authentication failed (invalid password)"
            elif [[ $redis_exit -ne 0 ]] || [[ "$redis_result" != "PONG" ]]; then
                redis_state="CRITICAL"
                redis_detail="Redis <b>${redis_host}:${redis_port}</b> not responding (expected PONG, got: $(html_escape "${redis_result:-no response}"))"
            else
                # Get additional info
                local redis_info
                redis_info=$(run_with_timeout "$redis_timeout" bash -c '
                    export REDISCLI_AUTH="$1"
                    shift
                    redis-cli "$@" INFO replication
                ' _ "$redis_pass" ${redis_opts} 2>/dev/null | grep -E "^(role|master_link_status|connected_slaves):" || true)
                if [[ -n "$redis_info" ]]; then
                    local role="${redis_info%%$'\n'*}"
                    role="${role#role:}"
                    if [[ "$role" == "slave" ]]; then
                        local link_status=$(echo "$redis_info" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r')
                        if [[ "$link_status" == "down" ]]; then
                            redis_state="CRITICAL"
                            redis_detail="Redis <b>${redis_host}:${redis_port}</b> replica: master link DOWN"
                        else
                            redis_detail="Redis <b>${redis_host}:${redis_port}</b> replica: connected to master"
                        fi
                    elif [[ "$role" == "master" ]]; then
                        local slaves=$(echo "$redis_info" | grep "connected_slaves:" | cut -d: -f2 | tr -d '\r')
                        redis_detail="Redis <b>${redis_host}:${redis_port}</b> master: ${slaves} connected replica(s)"
                    else
                        redis_detail="Redis <b>${redis_host}:${redis_port}</b> connected (standalone)"
                    fi
                else
                    redis_detail="Redis <b>${redis_host}:${redis_port}</b> connected"
                fi
            fi
            
            check_state_change "redis_$(sanitize_state_key "${redis_host}_${redis_port}")" "$redis_state" "$redis_detail"
        fi
    fi

    # SQLite3 Check
    if [[ -n "${DB_SQLITE_PATHS:-}" ]]; then
        if ! command -v sqlite3 &>/dev/null; then
            log "DEBUG" "Database check: sqlite3 not found — skipping SQLite check"
        else
            for db_path in $DB_SQLITE_PATHS; do
                # SECURITY: Validate path to prevent directory traversal
                if ! is_safe_path "$db_path"; then
                    log "WARN" "SQLite check: unsafe path '${db_path}' — skipping (contains .., *, ?, or $)"
                    continue
                fi

                # Generate state key from path hash (consistent with integrity/drift patterns)
                local sqlite_key
                sqlite_key=$(make_state_key "sqlite" "$db_path")
                local sqlite_state="OK"
                local sqlite_detail=""
                local safe_db_name
                safe_db_name=$(basename "$db_path")
                safe_db_name=$(html_escape "$safe_db_name")

                # Check file exists and is readable
                if [[ ! -f "$db_path" ]]; then
                    sqlite_state="CRITICAL"
                    sqlite_detail="SQLite DB <code>${safe_db_name}</code> not found: ${db_path}"
                    check_state_change "$sqlite_key" "$sqlite_state" "$sqlite_detail"
                    continue
                fi

                if [[ ! -r "$db_path" ]]; then
                    sqlite_state="CRITICAL"
                    sqlite_detail="SQLite DB <code>${safe_db_name}</code> not readable: ${db_path}"
                    check_state_change "$sqlite_key" "$sqlite_state" "$sqlite_detail"
                    continue
                fi

                # Check DB file size (if thresholds configured)
                local db_size_bytes
                db_size_bytes=$(portable_stat size "$db_path")
                local db_size_mb=$(( db_size_bytes / 1024 / 1024 ))
                local size_warn_mb="${DB_SQLITE_SIZE_THRESHOLD_WARN:-0}"
                local size_crit_mb="${DB_SQLITE_SIZE_THRESHOLD_CRIT:-0}"

                # Run integrity check (PRAGMA quick_check is fast; full PRAGMA integrity_check can be slow on large DBs)
                local integrity_result
                integrity_result=$(run_with_timeout "$check_timeout" sqlite3 "$db_path" "PRAGMA quick_check;" 2>&1)
                local integrity_exit=$?

                if [[ $integrity_exit -ne 0 ]]; then
                    sqlite_state="CRITICAL"
                    local safe_error
                    safe_error=$(html_escape "$integrity_result")
                    sqlite_detail="SQLite DB <code>${safe_db_name}</code> check failed: ${safe_error}"
                elif [[ "$integrity_result" != "ok" ]]; then
                    sqlite_state="CRITICAL"
                    local safe_result
                    safe_result=$(html_escape "$integrity_result")
                    sqlite_detail="SQLite DB <code>${safe_db_name}</code> corruption detected: ${safe_result}"
                elif [[ "$size_crit_mb" -gt 0 && "$db_size_mb" -ge "$size_crit_mb" ]]; then
                    sqlite_state="CRITICAL"
                    sqlite_detail="SQLite DB <code>${safe_db_name}</code> size <b>${db_size_mb}MB</b> exceeds critical threshold (${size_crit_mb}MB)"
                elif [[ "$size_warn_mb" -gt 0 && "$db_size_mb" -ge "$size_warn_mb" ]]; then
                    sqlite_state="WARNING"
                    sqlite_detail="SQLite DB <code>${safe_db_name}</code> size <b>${db_size_mb}MB</b> exceeds warning threshold (${size_warn_mb}MB)"
                else
                    sqlite_detail="SQLite DB <code>${safe_db_name}</code> OK (${db_size_mb}MB)"
                fi

                # Check for WAL file (indicates uncommitted transactions or ongoing write activity)
                local wal_path="${db_path}-wal"
                if [[ -f "$wal_path" ]]; then
                    local wal_size_bytes
                    wal_size_bytes=$(portable_stat size "$wal_path" 2>/dev/null || echo "0")
                    local wal_size_mb=$(( wal_size_bytes / 1024 / 1024 ))
                    if [[ "$wal_size_mb" -gt 100 ]]; then
                        # Large WAL file may indicate checkpointing issues
                        sqlite_detail+=" <i>(large WAL: ${wal_size_mb}MB)</i>"
                    fi
                fi

                check_state_change "$sqlite_key" "$sqlite_state" "$sqlite_detail"
            done
        fi
    fi
}

# ===========================================================================
# CHECK: ODBC Database Connections
# Monitors any database via ODBC using unixODBC isql command.
# Supports DSN-based and connection string-based configurations.
# ===========================================================================
check_odbc() {
    [[ "${ENABLE_ODBC_CHECKS:-false}" == "true" ]] || return
    [[ -n "${ODBC_CONNECTIONS:-}" ]] || return
    
    if ! command -v isql &>/dev/null; then
        log "WARN" "ODBC check: isql (unixODBC) not found — install with: apt install unixodbc"
        return
    fi
    
    local check_timeout="${ODBC_CHECK_TIMEOUT:-${CHECK_TIMEOUT:-30}}"
    
    # Check each defined ODBC connection
    for conn_name in $ODBC_CONNECTIONS; do
        # SECURITY: Validate connection name
        if ! is_valid_service_name "$conn_name"; then
            log "WARN" "ODBC check: invalid connection name '${conn_name}' — skipping (alphanumeric, underscore, hyphen, dot only)"
            continue
        fi
        
        # Build variable names using indirect expansion
        local dsn_var="ODBC_${conn_name}_DSN"
        local driver_var="ODBC_${conn_name}_DRIVER"
        local server_var="ODBC_${conn_name}_SERVER"
        local database_var="ODBC_${conn_name}_DATABASE"
        local user_var="ODBC_${conn_name}_USER"
        local pass_var="ODBC_${conn_name}_PASS"
        local query_var="ODBC_${conn_name}_QUERY"
        
        # Get values via indirect expansion
        local conn_dsn="${!dsn_var:-}"
        local conn_driver="${!driver_var:-}"
        local conn_server="${!server_var:-}"
        local conn_database="${!database_var:-}"
        local conn_user="${!user_var:-}"
        local conn_pass="${!pass_var:-}"
        local conn_query="${!query_var:-"SELECT 1"}"
        
        local odbc_state="OK"
        local odbc_detail=""
        local safe_conn_name
        safe_conn_name=$(html_escape "$conn_name")
        
        # Validate: must have either DSN or connection string components
        if [[ -z "$conn_dsn" && ( -z "$conn_driver" || -z "$conn_server" ) ]]; then
            odbc_state="CRITICAL"
            odbc_detail="ODBC <code>${safe_conn_name}</code> configuration error: need ODBC_${conn_name}_DSN or (DRIVER + SERVER)"
            check_state_change "odbc_$(sanitize_state_key "$conn_name")" "$odbc_state" "$odbc_detail"
            continue
        fi
        
        # Build connection string or use DSN
        local conn_str=""
        if [[ -n "$conn_dsn" ]]; then
            # DSN-based connection
            conn_str="${conn_dsn}"
        else
            # Connection string-based
            conn_str="DRIVER={${conn_driver}};SERVER=${conn_server};"
            [[ -n "$conn_database" ]] && conn_str+="DATABASE=${conn_database};"
            [[ -n "$conn_user" ]] && conn_str+="UID=${conn_user};"
            [[ -n "$conn_pass" ]] && conn_str+="PWD=${conn_pass};"
        fi
        
        # Test connection using isql
        local odbc_result
        local odbc_exit=0
        local start_time end_time duration_ms
        
        start_time=$(date +%s%3N 2>/dev/null || echo "0")
        
        if [[ -n "$conn_dsn" ]]; then
            # DSN-based: isql DSN user pass -b -c';' query
            if [[ -n "$conn_user" && -n "$conn_pass" ]]; then
                odbc_result=$(run_with_timeout "$check_timeout" bash -c '
                    export ODBCUSER="$1"
                    export ODBCPASS="$2"
                    isql "$3" "$ODBCUSER" "$ODBCPASS" -b -c ";" <<< "$4" 2>&1
                ' _ "$conn_user" "$conn_pass" "$conn_dsn" "$conn_query" 2>&1) || odbc_exit=$?
            else
                odbc_result=$(run_with_timeout "$check_timeout" isql "$conn_dsn" -b -c ";" <<< "$conn_query" 2>&1) || odbc_exit=$?
            fi
        else
            # Connection string-based: isql -k "connection_string" -b -c';' query
            odbc_result=$(run_with_timeout "$check_timeout" bash -c '
                isql -k "$1" -b -c ";" <<< "$2" 2>&1
            ' _ "$conn_str" "$conn_query" 2>&1) || odbc_exit=$?
        fi
        
        end_time=$(date +%s%3N 2>/dev/null || echo "0")
        duration_ms=$((end_time - start_time))
        
        # Analyze result
        if [[ $odbc_exit -ne 0 ]]; then
            odbc_state="CRITICAL"
            # Sanitize error message (remove passwords)
            local safe_error
            safe_error=$(echo "$odbc_result" | sed 's/PWD=[^;]*;/PWD=***/g; s/PASS=[^;]*;/PASS=***/g; s/password=[^[:space:]]*/***/gi' | head -2)
            safe_error=$(html_escape "$safe_error")
            odbc_detail="ODBC <code>${safe_conn_name}</code> connection failed: ${safe_error}"
        elif [[ "$odbc_result" == *"[ISQL]"*"ERROR"* || "$odbc_result" == *"[08001]"* || "$odbc_result" == *"[HY000]"* ]]; then
            odbc_state="CRITICAL"
            local safe_error
            safe_error=$(echo "$odbc_result" | sed 's/PWD=[^;]*;/PWD=***/g; s/PASS=[^;]*;/PASS=***/g' | head -2)
            safe_error=$(html_escape "$safe_error")
            odbc_detail="ODBC <code>${safe_conn_name}</code> query failed: ${safe_error}"
        elif [[ $duration_ms -gt 5000 ]]; then
            odbc_state="WARNING"
            odbc_detail="ODBC <code>${safe_conn_name}</code> slow response: <b>${duration_ms}ms</b> (>5s)"
        else
            odbc_detail="ODBC <code>${safe_conn_name}</code> connected (${duration_ms}ms)"
        fi
        
        # Generate state key and record state change
        local state_key="odbc_$(sanitize_state_key "$conn_name")"
        check_state_change "$state_key" "$odbc_state" "$odbc_detail"
    done
}

# ===========================================================================
# CHECK: Network Bandwidth Monitoring
# Reads /proc/net/dev, stores previous counters in state file, computes rate
# ===========================================================================
check_network_bandwidth() {
    local iface="${NETWORK_INTERFACE:-}"
    # Auto-detect primary interface if not set
    if [[ -z "$iface" ]]; then
        if ! command -v ip &>/dev/null; then
            log "DEBUG" "Network bandwidth check: 'ip' command not found — skipping"
            return
        fi
        iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
        if [[ -z "$iface" ]]; then
            log "WARN" "Network bandwidth check: could not detect default interface — skipping"
            return
        fi
    fi

    local safe_iface
    safe_iface=$(html_escape "$iface")

    local net_state_file="${STATE_FILE}.net"
    local now
    now=$(date +%s)

    # Read current counters from /proc/net/dev
    local rx_bytes tx_bytes
    read -r rx_bytes tx_bytes < <(awk -v iface="${iface}:" '$1 == iface {print $2, $10}' /proc/net/dev)
    [[ -z "$rx_bytes" ]] && return

    # Load previous counters
    local prev_rx=0 prev_tx=0 prev_ts=0
    if [[ -f "$net_state_file" ]]; then
        read -r prev_rx prev_tx prev_ts < "$net_state_file" 2>/dev/null || true
    fi
    # Validate loaded values are numeric (defense against corrupt state file)
    if ! is_valid_number "$prev_rx" || ! is_valid_number "$prev_tx" || ! is_valid_number "$prev_ts"; then
        log "WARN" "check_network_bandwidth: corrupt net state file — resetting baseline"
        prev_rx=0 prev_tx=0 prev_ts=0
    fi

    # Save current counters
    safe_write_state_file "$net_state_file" "$rx_bytes $tx_bytes $now"

    # Need previous reading to calculate rate
    [[ "$prev_ts" -eq 0 ]] && return
    local interval=$(( now - prev_ts ))
    if [[ "$interval" -le 0 ]]; then
        log "WARN" "check_network_bandwidth: interval is ${interval}s (clock skew?) — skipping"
        return
    fi

    local rx_rate=$(( (rx_bytes - prev_rx) / interval ))
    local tx_rate=$(( (tx_bytes - prev_tx) / interval ))

    # Handle counter wraparound: report OK and let next cycle use fresh baseline
    if [[ "$rx_rate" -lt 0 ]] || [[ "$tx_rate" -lt 0 ]]; then
        log "DEBUG" "check_network_bandwidth: counter wraparound detected on ${iface} — skipping rate calculation"
        local iface_key_wrap="net_$(printf '%s' "$iface" | tr -c 'a-zA-Z0-9_' '_')"
        check_state_change "$iface_key_wrap" "OK" "Network ${safe_iface}: counter wraparound (awaiting next sample)"
        return
    fi

    # Convert to Mbit/s (rate is in bytes/sec, * 8 / 1000000)
    # Use higher precision awk to avoid integer division artifacts
    local rx_mbps tx_mbps
    rx_mbps=$(awk -v rb="$rx_bytes" -v prb="$prev_rx" -v intv="$interval" 'BEGIN {printf "%.2f", ((rb - prb) / intv) * 8 / 1000000}')
    tx_mbps=$(awk -v tb="$tx_bytes" -v ptb="$prev_tx" -v intv="$interval" 'BEGIN {printf "%.2f", ((tb - ptb) / intv) * 8 / 1000000}')

    local warn="${NETWORK_THRESHOLD_WARN:-800}"    # Mbit/s
    local crit="${NETWORK_THRESHOLD_CRIT:-950}"    # Mbit/s

    # Use the higher of rx/tx for threshold comparison
    local max_mbps
    max_mbps=$(awk -v rx="$rx_mbps" -v tx="$tx_mbps" 'BEGIN {printf "%.0f", (rx > tx) ? rx : tx}')

    local state="OK"
    local detail="Network ${safe_iface}: RX ${rx_mbps} Mbit/s, TX ${tx_mbps} Mbit/s"
    
    # Use consistent key format: net_<iface> (replace non-alphanumeric with underscore)
    local iface_key="net_$(printf '%s' "$iface" | tr -c 'a-zA-Z0-9_' '_')"

    if (( max_mbps >= crit )); then
        state="CRITICAL"
        detail="Network ${safe_iface}: RX <b>${rx_mbps}</b> Mbit/s, TX <b>${tx_mbps}</b> Mbit/s (threshold: ${crit} Mbit/s)"
    elif (( max_mbps >= warn )); then
        state="WARNING"
        detail="Network ${safe_iface}: RX <b>${rx_mbps}</b> Mbit/s, TX <b>${tx_mbps}</b> Mbit/s (threshold: ${warn} Mbit/s)"
    fi

    check_state_change "$iface_key" "$state" "$detail"
}

# ===========================================================================
# CHECK: Log Pattern Matching
# Tails last N lines of configured log files and matches regex patterns
# ===========================================================================
check_log_patterns() {
    local watch_files="${LOG_WATCH_FILES:-}"
    local patterns="${LOG_WATCH_PATTERNS:-}"
    local tail_lines="${LOG_WATCH_LINES:-100}"

    [[ -z "$watch_files" || -z "$patterns" ]] && return

    for logfile in $watch_files; do
        [[ -f "$logfile" ]] || continue

        local matched_lines=""
        local match_count=0

        # Build combined regex for efficient single-pass matching
        local combined_pattern=""
        for pattern in $patterns; do
            combined_pattern+="${combined_pattern:+|}${pattern}"
        done
        
        # Validate the combined regex pattern before using it
        # Use 'test' as input; grep returns exit code 2 for invalid regex
        echo "test" | grep -qE "$combined_pattern" 2>/dev/null
        local grep_exit=$?
        if [[ $grep_exit -eq 2 ]]; then
            log "WARN" "check_log_patterns: invalid regex pattern '${combined_pattern}' for ${logfile} — skipping"
            continue
        fi

        while IFS= read -r line; do
            match_count=$((match_count + 1))
            if [[ $match_count -le 3 ]]; then
                # Truncate long lines to prevent exceeding Telegram message limits
                [[ ${#line} -gt 200 ]] && line="${line:0:200}..."
                matched_lines+="$(html_escape "$line")%0A"
            fi
        done < <(tail -n "$tail_lines" "$logfile" 2>/dev/null | run_with_timeout "$CHECK_TIMEOUT" grep -E "$combined_pattern" 2>/dev/null || true)

        local logname
        logname=$(basename "$logfile")
        local safe_logname
        safe_logname=$(html_escape "$logname")
        local key
        key=$(make_state_key "log" "$logfile")

        local state="OK"
        local detail="Log <code>${safe_logname}</code>: no matching patterns"

        if [[ $match_count -gt 0 ]]; then
            state="WARNING"
            detail="Log <code>${safe_logname}</code>: <b>${match_count} matches</b> in last ${tail_lines} lines"
            if [[ -n "$matched_lines" ]]; then
                detail+="%0A<pre>$(printf '%s' "$matched_lines" | head -3)</pre>"
            fi
        fi

        check_state_change "$key" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: File/Directory Integrity (checksum monitoring)
# ===========================================================================
check_file_integrity() {
    local watch_files="${INTEGRITY_WATCH_FILES:-}"
    [[ -z "$watch_files" ]] && return

    local integrity_state_file="${STATE_FILE}.integrity"

    # Load previous checksums
    declare -A prev_checksums
    if [[ -f "$integrity_state_file" ]]; then
        while IFS='=' read -r fpath checksum; do
            [[ -n "$fpath" ]] && prev_checksums["$fpath"]="$checksum"
        done < "$integrity_state_file"
    fi

    # Compute current checksums and save
    local new_checksums=""
    for filepath in $watch_files; do
        # SECURITY: Validate path to prevent directory traversal and file inclusion attacks
        if ! is_safe_path "$filepath"; then
            log "WARN" "Integrity check: unsafe path '${filepath}' — skipping (contains .., *, ?, or $)"
            continue
        fi
        
        [[ -f "$filepath" ]] || continue

        local current_sum
        current_sum=$(sha256sum "$filepath" 2>/dev/null | awk '{print $1}') || true
        [[ -z "$current_sum" ]] && continue

        new_checksums+="${filepath}=${current_sum}"$'\n'

        local key
        key=$(make_state_key "integrity" "$filepath")
        local fname
        fname=$(basename "$filepath")

        if [[ -n "${prev_checksums[$filepath]:-}" ]]; then
            if [[ "${prev_checksums[$filepath]}" != "$current_sum" ]]; then
                check_state_change "$key" "WARNING" "File <code>${fname}</code> was <b>modified</b> since last check"
            else
                check_state_change "$key" "OK" "File <code>${fname}</code> integrity OK"
            fi
        else
            # First time seeing this file — baseline
            check_state_change "$key" "OK" "File <code>${fname}</code> integrity baselined"
        fi
    done

    # Save new checksums
    if [[ -n "$new_checksums" ]]; then
        safe_write_state_file "$integrity_state_file" "$new_checksums"
    fi
}

# ===========================================================================
# HELPER: Build drift detection alert detail
# Constructs rich HTML alert with diff, metadata changes, and user attribution
# ===========================================================================
build_drift_detail() {
    local filepath="$1" safe_fname="$2"
    local prev_sum="$3" current_sum="$4"
    local prev_mtime="$5" current_mtime="$6"
    local prev_size="$7" current_size="$8"
    local prev_owner="$9" current_owner="${10}"
    local prev_perms="${11}" current_perms="${12}"
    local ignore_pattern="${13}" max_diff_lines="${14}"
    local sensitive_files="${15}" baseline_dir="${16}"

    local detail=""
    local safe_filepath
    safe_filepath=$(html_escape "$filepath")

    # Format change timestamp
    local change_time
    change_time=$(date -d "@${current_mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || date -r "$current_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || echo "unknown")

    detail="<b>File:</b> <code>${safe_filepath}</code>%0A"
    detail+="<b>Changed:</b> ${change_time}%0A"

    # User attribution — try ausearch for audit trail, fallback to file owner
    local change_user=""
    if command -v ausearch &>/dev/null; then
        # Search audit log for recent writes to this file (last 300 seconds)
        change_user=$(ausearch -f "$filepath" -ts recent --raw 2>/dev/null \
            | grep -oP 'uid=\K[0-9]+' | tail -1)
        if [[ -n "$change_user" ]]; then
            local username
            username=$(getent passwd "$change_user" 2>/dev/null | cut -d: -f1)
            change_user="${username:-uid=$change_user} (uid=${change_user})"
        fi
    fi
    if [[ -z "$change_user" ]]; then
        # Fallback: current file owner
        local safe_owner
        safe_owner=$(html_escape "$current_owner")
        change_user="$safe_owner (file owner)"
    fi
    detail+="<b>By User:</b> $(html_escape "$change_user")%0A"

    # Content diff (only if checksum changed)
    if [[ "$prev_sum" != "$current_sum" ]]; then
        local baseline_file="${baseline_dir}/$(printf '%s' "$filepath" | portable_sha256 | cut -c1-12)"

        # Check if this is a sensitive file
        local is_sensitive=false
        for sf in $sensitive_files; do
            [[ "$filepath" == "$sf" ]] && { is_sensitive=true; break; }
        done

        if [[ "$is_sensitive" == "true" ]]; then
            detail+="%0A<b>Changes:</b> <i>(content redacted — sensitive file)</i>%0A"
        elif [[ -f "$baseline_file" ]]; then
            local diff_output
            diff_output=$(run_with_timeout "$CHECK_TIMEOUT" diff -u "$baseline_file" "$filepath" 2>/dev/null || true)

            # Filter by ignore pattern if set
            if [[ -n "$ignore_pattern" && -n "$diff_output" ]]; then
                # Keep header lines (---/+++) and non-matching change lines
                local filtered=""
                local has_real_changes=false
                while IFS= read -r line; do
                    case "$line" in
                        ---*|+++*|@@*) filtered+="${line}"$'\n' ;;
                        [-+]*)
                            # Strip the leading +/- for pattern matching
                            local content="${line:1}"
                            if ! printf '%s' "$content" | grep -qE "$ignore_pattern" 2>/dev/null; then
                                filtered+="${line}"$'\n'
                                has_real_changes=true
                            fi
                            ;;
                        *) filtered+="${line}"$'\n' ;;
                    esac
                done <<< "$diff_output"

                if [[ "$has_real_changes" != "true" ]]; then
                    # All changes matched ignore pattern — no real drift
                    printf ''
                    return 0
                fi
                diff_output="$filtered"
            fi

            if [[ -n "$diff_output" ]]; then
                # Truncate to max lines
                local line_count
                line_count=$(printf '%s' "$diff_output" | wc -l)
                local truncated_diff
                truncated_diff=$(printf '%s' "$diff_output" | head -n "$max_diff_lines")

                # HTML-escape the diff
                local safe_diff
                safe_diff=$(html_escape "$truncated_diff")

                detail+="%0A<b>Changes:</b>%0A<pre>"
                detail+="${safe_diff}"
                detail+="</pre>"

                if [[ "$line_count" -gt "$max_diff_lines" ]]; then
                    detail+="%0A<i>(truncated: showing ${max_diff_lines} of ${line_count} lines)</i>"
                fi
                detail+="%0A"
            fi
        fi
    fi

    # Metadata changes section
    local meta_changes=""
    if [[ "$prev_size" != "$current_size" ]]; then
        local prev_size_h current_size_h
        prev_size_h=$(numfmt --to=iec-i "$prev_size" 2>/dev/null || echo "${prev_size}B")
        current_size_h=$(numfmt --to=iec-i "$current_size" 2>/dev/null || echo "${current_size}B")
        meta_changes+="Size: ${prev_size_h} → ${current_size_h}%0A"
    fi
    if [[ "$prev_perms" != "$current_perms" ]]; then
        meta_changes+="Permissions: ${prev_perms} → ${current_perms}%0A"
    fi
    if [[ "$prev_owner" != "$current_owner" ]]; then
        local safe_prev_owner safe_curr_owner
        safe_prev_owner=$(html_escape "$prev_owner")
        safe_curr_owner=$(html_escape "$current_owner")
        meta_changes+="Owner: ${safe_prev_owner} → ${safe_curr_owner}%0A"
    fi

    if [[ -n "$meta_changes" ]]; then
        detail+="%0A<b>Metadata Changes:</b>%0A${meta_changes}"
    fi

    printf '%s' "$detail"
}

# ===========================================================================
# CHECK: Configuration Drift Detection
# Monitors critical files for changes with rich context (diff, metadata, user)
# ===========================================================================
check_drift_detection() {
    local watch_files="${DRIFT_WATCH_FILES:-}"
    [[ -z "$watch_files" ]] && return

    local drift_state_file="${STATE_FILE}.drift"
    local baseline_dir="${STATE_FILE}.drift.baseline"
    local ignore_pattern="${DRIFT_IGNORE_PATTERN:-}"
    local max_diff_lines="${DRIFT_MAX_DIFF_LINES:-20}"
    local sensitive_files="${DRIFT_SENSITIVE_FILES:-}"

    # Create baseline directory if needed (700 perms)
    [[ -d "$baseline_dir" ]] || mkdir -m 700 "$baseline_dir" 2>/dev/null || true

    # Load previous metadata from drift state file
    declare -A prev_meta
    if [[ -f "$drift_state_file" ]]; then
        while IFS='=' read -r fpath meta; do
            [[ -n "$fpath" ]] && prev_meta["$fpath"]="$meta"
        done < "$drift_state_file"
    fi

    local new_meta=""
    for filepath in $watch_files; do
        # SECURITY: Validate path to prevent directory traversal and file inclusion attacks
        if ! is_safe_path "$filepath"; then
            log "WARN" "Drift detection: unsafe path '${filepath}' — skipping (contains .., *, ?, or $)"
            continue
        fi
        
        [[ -f "$filepath" ]] || continue

        # Gather current metadata
        local current_sum current_mtime current_size current_owner current_perms
        current_sum=$(run_with_timeout "$CHECK_TIMEOUT" sha256sum "$filepath" 2>/dev/null | awk '{print $1}') || true
        [[ -z "$current_sum" ]] && continue

        # Use portable_stat helper for cross-platform compatibility
        current_mtime=$(portable_stat mtime "$filepath")
        current_size=$(portable_stat size "$filepath")
        current_owner=$(portable_stat owner "$filepath")
        current_perms=$(portable_stat perms "$filepath")

        # Pack metadata: checksum|mtime|size|owner|perms
        local current_meta="${current_sum}|${current_mtime}|${current_size}|${current_owner}|${current_perms}"
        new_meta+="${filepath}=${current_meta}"$'\n'

        # Compute state key
        local key
        key=$(make_state_key "drift" "$filepath")
        local fname
        fname=$(basename "$filepath")
        local safe_fname
        safe_fname=$(html_escape "$fname")

        if [[ -n "${prev_meta[$filepath]:-}" ]]; then
            local prev="${prev_meta[$filepath]}"
            local prev_sum="${prev%%|*}"; local rest="${prev#*|}"
            local prev_mtime="${rest%%|*}"; rest="${rest#*|}"
            local prev_size="${rest%%|*}"; rest="${rest#*|}"
            local prev_owner="${rest%%|*}"
            local prev_perms="${rest#*|}"

            if [[ "$current_meta" != "$prev" ]]; then
                # Something changed — build detail
                local detail
                detail=$(build_drift_detail "$filepath" "$safe_fname" \
                    "$prev_sum" "$current_sum" \
                    "$prev_mtime" "$current_mtime" \
                    "$prev_size" "$current_size" \
                    "$prev_owner" "$current_owner" \
                    "$prev_perms" "$current_perms" \
                    "$ignore_pattern" "$max_diff_lines" "$sensitive_files" "$baseline_dir")

                # If detail is empty, ignore pattern filtered all changes
                if [[ -z "$detail" ]]; then
                    check_state_change "$key" "OK" "File <code>${safe_fname}</code> drift OK (filtered changes only)"
                else
                    check_state_change "$key" "WARNING" "$detail"
                fi
            else
                check_state_change "$key" "OK" "File <code>${safe_fname}</code> drift OK"
            fi
        else
            # First time — baseline
            check_state_change "$key" "OK" "File <code>${safe_fname}</code> drift baselined"
        fi

        # Update baseline copy (for diff on next run)
        local baseline_file="${baseline_dir}/$(printf '%s' "$filepath" | portable_sha256 | cut -c1-12)"
        cp -f "$filepath" "$baseline_file" 2>/dev/null || true
        chmod 600 "$baseline_file" 2>/dev/null || true
    done

    # Save metadata
    if [[ -n "$new_meta" ]]; then
        safe_write_state_file "$drift_state_file" "$new_meta"
    fi
}

# ===========================================================================
# CHECK: Cron Job Completion Tracking
# Detects missed/slow cron jobs via heartbeat touch files
# ===========================================================================
check_cron_jobs() {
    local cron_jobs="${CRON_WATCH_JOBS:-}"
    [[ -z "$cron_jobs" ]] && return

    # Format: name:touchfile:max_age_minutes
    for entry in $cron_jobs; do
        local name="${entry%%:*}"
        local rest="${entry#*:}"
        local touchfile="${rest%%:*}"
        local max_age="${rest##*:}"

        [[ -z "$name" || -z "$touchfile" || -z "$max_age" ]] && continue

        local key="cron_${name}"

        if [[ ! -f "$touchfile" ]]; then
            check_state_change "$key" "CRITICAL" "Cron job <code>${name}</code>: heartbeat file <b>missing</b> (${touchfile})"
            continue
        fi

        local file_age_sec
        local file_mtime
        # Use portable_stat helper for cross-platform compatibility
        file_mtime=$(portable_stat mtime "$touchfile")
        if [[ -z "$file_mtime" || "$file_mtime" == "0" ]]; then
            log "WARN" "Cron check: cannot stat ${touchfile} — skipping"
            continue
        fi
        file_age_sec=$(( $(date +%s) - file_mtime ))
        local max_age_sec=$(( max_age * 60 ))

        if (( file_age_sec > max_age_sec )); then
            local age_min=$(( file_age_sec / 60 ))
            check_state_change "$key" "WARNING" "Cron job <code>${name}</code>: last run <b>${age_min}m ago</b> (max: ${max_age}m)"
        else
            check_state_change "$key" "OK" "Cron job <code>${name}</code>: last run $(( file_age_sec / 60 ))m ago"
        fi
    done
}

# ===========================================================================
# CHECK: Plugin System (/checks.d/)
# Sources and executes all executable scripts in the checks.d directory.
# Each plugin outputs STATE|KEY|DETAIL format for integration with Telemon.
# ===========================================================================
check_plugins() {
    local plugin_dir="${CHECKS_DIR:-${SCRIPT_DIR}/checks.d}"
    
    # Skip if directory doesn't exist or isn't readable
    if [[ ! -d "$plugin_dir" ]]; then
        log "DEBUG" "Plugin check: directory ${plugin_dir} not found — skipping"
        return
    fi
    
    if [[ ! -r "$plugin_dir" ]]; then
        log "WARN" "Plugin check: directory ${plugin_dir} not readable — skipping"
        return
    fi
    
    # Iterate through all executable files in the directory
    local plugin_count=0
    for plugin in "$plugin_dir"/*; do
        [[ -f "$plugin" ]] || continue
        [[ -x "$plugin" ]] || continue
        [[ -L "$plugin" ]] && continue  # Skip symlinks (security)
        
        plugin_count=$((plugin_count + 1))
        local plugin_name
        plugin_name=$(basename "$plugin")
        local safe_plugin_name
        safe_plugin_name=$(html_escape "$plugin_name")
        
        # Run the plugin with timeout
        local plugin_output
        plugin_output=$(run_with_timeout "$CHECK_TIMEOUT" "$plugin" 2>/dev/null) || plugin_output=""
        
        if [[ -z "$plugin_output" ]]; then
            log "WARN" "Plugin ${safe_plugin_name} returned no output"
            continue
        fi
        
        # Parse plugin output: STATE|KEY|DETAIL
        # State must be OK, WARNING, or CRITICAL
        local plugin_state="${plugin_output%%|*}"
        local rest="${plugin_output#*|}"
        local plugin_key="${rest%%|*}"
        local plugin_detail="${rest#*|}"
        
        # Validate state
        case "$plugin_state" in
            OK|WARNING|CRITICAL)
                # Valid state
                ;;
            *)
                log "WARN" "Plugin ${safe_plugin_name} returned invalid state: ${plugin_state}"
                continue
                ;;
        esac
        
        # Validate key (alphanumeric, underscore, hyphen, dot only)
        if [[ ! "$plugin_key" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            log "WARN" "Plugin ${safe_plugin_name} returned invalid key: ${plugin_key}"
            continue
        fi
        
        # Use plugin key or generate one from plugin name
        local key="${plugin_key:-plugin_${safe_plugin_name}}"
        
        # HTML-escape detail
        local safe_detail
        safe_detail=$(html_escape "$plugin_detail")
        
        # Report state change
        check_state_change "$key" "$plugin_state" "$safe_detail"
    done
    
    if [[ "$plugin_count" -eq 0 ]]; then
        log "DEBUG" "Plugin check: no executable plugins found in ${plugin_dir}"
    else
        log "DEBUG" "Plugin check: executed ${plugin_count} plugin(s)"
    fi
}

# ===========================================================================
# Fleet Heartbeat Monitor
# Scans heartbeat directory for stale/missing sibling servers
# ===========================================================================
check_fleet_heartbeats() {
    local dir="${FLEET_HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
    if [[ ! -d "$dir" ]] || [[ ! -r "$dir" ]]; then
        log "WARN" "Fleet heartbeat dir not found or not readable: ${dir} — skipping"
        return
    fi

    local threshold_sec=$(( ${FLEET_STALE_THRESHOLD_MIN:-15} * 60 ))
    local crit_threshold_sec=$(( threshold_sec * ${FLEET_CRITICAL_MULTIPLIER:-2} ))
    local now
    now=$(date +%s)
    local seen_servers=()

    # Determine our own sanitized label for self-skip
    local self_label
    self_label=$(sanitize_state_key "${SERVER_LABEL}")

    # Scan all heartbeat files in directory
    for file in "$dir"/*; do
        [[ -f "$file" ]] || continue
        [[ -L "$file" ]] && continue  # Skip symlinks (defense-in-depth)
        local filename
        filename=$(basename "$file")
        seen_servers+=("$filename")

        # Skip self (don't alert on our own heartbeat)
        [[ "$filename" == "$self_label" ]] && continue

        # Read heartbeat line (first line only, tab-separated)
        # Only parse fields needed for monitoring (label, timestamp, status, check_count)
        local hb_label hb_timestamp hb_status hb_check_count _
        IFS=$'\t' read -r hb_label hb_timestamp hb_status hb_check_count _ < "$file" || continue

        # Validate minimum field count: label, timestamp, and status must be non-empty
        if [[ -z "${hb_label:-}" || -z "${hb_timestamp:-}" || -z "${hb_status:-}" ]]; then
            log "WARN" "Fleet: heartbeat file has insufficient fields: ${filename} (need at least 3 tab-separated fields)"
            continue
        fi

        # Validate timestamp is numeric
        if ! is_valid_number "$hb_timestamp"; then
            log "WARN" "Fleet: invalid heartbeat file format: ${filename}"
            continue
        fi

        local safe_label
        safe_label=$(html_escape "$hb_label")
        local file_age_sec=$(( now - hb_timestamp ))
        local age_min=$(( file_age_sec / 60 ))

        # Validate fields from untrusted heartbeat files (shared storage)
        local safe_status safe_count
        if [[ "${hb_status:-}" =~ ^(OK|WARNING|CRITICAL)$ ]]; then
            safe_status="$hb_status"
        else
            safe_status="unknown"
        fi
        if is_valid_number "${hb_check_count:-}"; then
            safe_count="$hb_check_count"
        else
            safe_count="?"
        fi

        local key="fleet_$(sanitize_state_key "$filename")"
        local state detail

        if (( file_age_sec > crit_threshold_sec )); then
            state="CRITICAL"
            detail="Fleet server <code>${safe_label}</code> <b>SILENT</b> for ${age_min}m (threshold: ${FLEET_STALE_THRESHOLD_MIN:-15}m)"
        elif (( file_age_sec > threshold_sec )); then
            state="WARNING"
            detail="Fleet server <code>${safe_label}</code> stale for ${age_min}m (threshold: ${FLEET_STALE_THRESHOLD_MIN:-15}m)"
        else
            state="OK"
            detail="Fleet server <code>${safe_label}</code> last seen ${age_min}m ago (${safe_status}, ${safe_count} checks)"
        fi

        check_state_change "$key" "$state" "$detail"
    done

    # Check for expected servers that never checked in
    if [[ -n "${FLEET_EXPECTED_SERVERS:-}" ]]; then
        for expected in ${FLEET_EXPECTED_SERVERS}; do
            local expected_sanitized
            expected_sanitized=$(sanitize_state_key "$expected")
            # Skip self
            [[ "$expected_sanitized" == "$self_label" ]] && continue
            local found=false
            for seen in "${seen_servers[@]}"; do
                [[ "$seen" == "$expected_sanitized" ]] && found=true && break
            done
            if [[ "$found" == "false" ]]; then
                local key="fleet_$(sanitize_state_key "$expected")"
                local safe_expected
                safe_expected=$(html_escape "$expected")
                check_state_change "$key" "CRITICAL" "Fleet server <code>${safe_expected}</code> <b>NEVER checked in</b> (expected in fleet)"
            fi
        done
    fi
}

# ===========================================================================
# Run all enabled checks (single source of truth)
# Called by both main() and run_digest() to avoid duplication
# ===========================================================================
run_all_checks() {
    [[ "${ENABLE_CPU_CHECK:-true}" == "true" ]] && check_cpu
    [[ "${ENABLE_MEMORY_CHECK:-true}" == "true" ]] && check_memory
    [[ "${ENABLE_DISK_CHECK:-true}" == "true" ]] && check_disk
    [[ "${ENABLE_SWAP_CHECK:-true}" == "true" ]] && check_swap
    [[ "${ENABLE_IOWAIT_CHECK:-true}" == "true" ]] && check_iowait
    [[ "${ENABLE_ZOMBIE_CHECK:-true}" == "true" ]] && check_zombies
    [[ "${ENABLE_INTERNET_CHECK:-true}" == "true" ]] && check_internet
    [[ "${ENABLE_SYSTEM_PROCESSES:-true}" == "true" ]] && check_system_processes
    [[ "${ENABLE_FAILED_SYSTEMD_SERVICES:-true}" == "true" ]] && check_failed_systemd_services
    [[ "${ENABLE_DOCKER_CONTAINERS:-false}" == "true" ]] && check_docker_containers
    [[ "${ENABLE_PM2_PROCESSES:-false}" == "true" ]] && check_pm2_processes
    [[ "${ENABLE_SITE_MONITOR:-false}" == "true" ]] && check_sites
    [[ "${ENABLE_NVME_CHECK:-false}" == "true" ]] && check_nvme_health
    [[ "${ENABLE_TCP_PORT_CHECK:-false}" == "true" ]] && check_tcp_ports
    [[ "${ENABLE_TEMP_CHECK:-false}" == "true" ]] && check_cpu_temp
    [[ "${ENABLE_DNS_CHECK:-false}" == "true" ]] && check_dns
    [[ "${ENABLE_DNS_RECORD_CHECK:-false}" == "true" ]] && check_dns_records
    [[ "${ENABLE_GPU_CHECK:-false}" == "true" ]] && check_gpu
    [[ "${ENABLE_UPS_CHECK:-false}" == "true" ]] && check_ups
    [[ "${ENABLE_DATABASE_CHECKS:-false}" == "true" ]] && check_databases
    [[ "${ENABLE_ODBC_CHECKS:-false}" == "true" ]] && check_odbc
    [[ "${ENABLE_NETWORK_CHECK:-false}" == "true" ]] && check_network_bandwidth
    [[ "${ENABLE_LOG_CHECK:-false}" == "true" ]] && check_log_patterns
    [[ "${ENABLE_INTEGRITY_CHECK:-false}" == "true" ]] && check_file_integrity
    [[ "${ENABLE_DRIFT_DETECTION:-false}" == "true" ]] && check_drift_detection
    [[ "${ENABLE_CRON_CHECK:-false}" == "true" ]] && check_cron_jobs
    [[ "${ENABLE_FLEET_CHECK:-false}" == "true" ]] && check_fleet_heartbeats
    [[ "${ENABLE_PLUGINS:-false}" == "true" ]] && check_plugins
}

# ===========================================================================
# AUTO-REMEDIATION: Restart failed services if configured
# Called after checks, before alert dispatch
# ===========================================================================
auto_remediate() {
    local restart_services="${AUTO_RESTART_SERVICES:-}"
    [[ -z "$restart_services" ]] && return

    for svc in $restart_services; do
        # SECURITY: Validate service name to prevent command injection
        # Only allow alphanumeric, hyphen, underscore, and dot characters
        if ! is_valid_service_name "$svc"; then
            log "WARN" "Auto-remediation: invalid service name '${svc}' — skipping (only a-z, 0-9, ., _, - allowed)"
            continue
        fi
        
        local key="proc_$(sanitize_state_key "$svc")"
        local svc_state="${CURR_STATE[$key]:-OK}"

        if [[ "$svc_state" == "CRITICAL" ]]; then
            log "INFO" "Auto-remediation: attempting restart of ${svc}"
            # SECURITY: Use -- to prevent option injection; validated service name above
            if run_with_timeout "$CHECK_TIMEOUT" systemctl restart -- "$svc" 2>/dev/null; then
                log "INFO" "Auto-remediation: ${svc} restart succeeded"
                # Update the detail to note remediation was attempted
                STATE_DETAIL["$key"]="${STATE_DETAIL[$key]:-} (auto-restart <b>attempted</b>)"
                ALERTS+="&#128260; <b>$(html_escape "$key")</b>: auto-restart attempted for <code>$(html_escape "$svc")</code>%0A%0A"
                # Reset count so next cycle's resolution detection starts fresh
                PREV_COUNT["$key"]=0
            else
                log "WARN" "Auto-remediation: ${svc} restart FAILED"
                STATE_DETAIL["$key"]="${STATE_DETAIL[$key]:-} (auto-restart <b>failed</b>)"
            fi
        fi
    done
}

# ===========================================================================
# Prometheus Textfile Export
# Writes metrics to a textfile for node_exporter --collector.textfile
# ===========================================================================
export_prometheus() {
    [[ "${ENABLE_PROMETHEUS_EXPORT:-false}" != "true" ]] && return
    local prom_dir="${PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    [[ -d "$prom_dir" ]] || return

    local prom_file="${prom_dir}/telemon.prom"
    local tmp_file
    tmp_file=$(mktemp "${prom_file}.XXXXXX") || { log "ERROR" "Failed to create temp file for prometheus export"; return; }

    {
        echo "# HELP telemon_check_state Telemon check state (0=OK, 1=WARNING, 2=CRITICAL)"
        echo "# TYPE telemon_check_state gauge"
        for key in "${!CURR_STATE[@]}"; do
            local val=0
            case "${CURR_STATE[$key]}" in
                WARNING)  val=1 ;;
                CRITICAL) val=2 ;;
            esac
            # Sanitize key for Prometheus label
            local safe_key
            safe_key=$(echo "$key" | tr -c 'a-zA-Z0-9_' '_')
            echo "telemon_check_state{check=\"${safe_key}\"} ${val}"
        done

        echo "# HELP telemon_checks_total Total number of checks in this run"
        echo "# TYPE telemon_checks_total gauge"
        echo "telemon_checks_total ${#CURR_STATE[@]}"

        echo "# HELP telemon_last_run_timestamp Unix timestamp of last run"
        echo "# TYPE telemon_last_run_timestamp gauge"
        echo "telemon_last_run_timestamp $(date +%s)"
    } > "$tmp_file"

    mv "$tmp_file" "$prom_file"
    chmod 644 "$prom_file" 2>/dev/null || true
}

# ===========================================================================
# JSON Status File Export
# Writes current state to JSON for lightweight status API
# ===========================================================================
export_json_status() {
    [[ "${ENABLE_JSON_STATUS:-false}" != "true" ]] && return
    local json_file="${JSON_STATUS_FILE:-/tmp/telemon_status.json}"

    if ! command -v python3 &>/dev/null; then
        log "WARN" "JSON status export: python3 not found — skipping"
        return
    fi

    local tmp_file
    tmp_file=$(mktemp "${json_file}.XXXXXX") || { log "ERROR" "Failed to create temp file for JSON export"; return; }

    local py_err
    # Pipe in-memory CURR_STATE directly instead of re-reading STATE_FILE from disk
    # (eliminates race condition with concurrent telemon instances)
    local state_input=""
    for key in "${!CURR_STATE[@]}"; do
        state_input+="${key}=${CURR_STATE[$key]}:${PREV_COUNT[$key]:-0}"$'\n'
    done
    py_err=$(TELEMON_HOSTNAME="$(hostname)" TELEMON_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" python3 -c "
import json, sys, os
hostname = os.environ.get('TELEMON_HOSTNAME', '')
timestamp = os.environ.get('TELEMON_TIMESTAMP', '')
checks = {}
for line in sys.stdin:
    line = line.strip()
    if '=' not in line: continue
    key, rest = line.split('=', 1)
    state = rest.split(':')[0] if ':' in rest else rest
    checks[key] = state
data = {
    'hostname': hostname,
    'timestamp': timestamp,
    'checks': checks,
    'summary': {
        'critical': sum(1 for v in checks.values() if v == 'CRITICAL'),
        'warning': sum(1 for v in checks.values() if v == 'WARNING'),
        'ok': sum(1 for v in checks.values() if v == 'OK'),
    }
}
print(json.dumps(data, indent=2))
" <<< "$state_input" > "$tmp_file" 2>&1)
    local py_exit=$?

    if [[ $py_exit -eq 0 ]]; then
        mv "$tmp_file" "$json_file"
        chmod 644 "$json_file" 2>/dev/null || true
    else
        log "WARN" "JSON status export failed: ${py_err}"
        rm -f "$tmp_file"
    fi
}

# ===========================================================================
# Static HTML Status Page Generator
# Generates a self-contained HTML status page from current state
# Can be served via nginx/caddy or committed to GitHub Pages
# ===========================================================================
generate_status_page() {
    local output_file="${1:-${STATUS_PAGE_FILE:-${SCRIPT_DIR}/status.html}}"
    local state_file="${STATE_FILE:-/tmp/telemon_sys_alert_state}"
    local detail_file="${state_file}.detail"

    # Create temp file for atomic write
    local tmp_file
    tmp_file=$(mktemp "${output_file}.XXXXXX") || { log "ERROR" "Failed to create temp file for status page"; return 1; }

    # Load current state into associative arrays if not already loaded
    if [[ ${#CURR_STATE[@]} -eq 0 ]] && [[ -f "$state_file" ]]; then
        load_state
    fi

    # Build summary counts
    local crit_count=0 warn_count=0 ok_count=0 total=0
    for key in "${!CURR_STATE[@]}"; do
        total=$((total + 1))
        case "${CURR_STATE[$key]}" in
            CRITICAL) crit_count=$((crit_count + 1)) ;;
            WARNING)  warn_count=$((warn_count + 1)) ;;
            OK)       ok_count=$((ok_count + 1)) ;;
        esac
    done

    # Determine overall status
    local overall_status="OK"
    local status_color="#10b981"  # green
    local status_emoji="✅"
    if [[ $crit_count -gt 0 ]]; then
        overall_status="CRITICAL"
        status_color="#ef4444"  # red
        status_emoji="🔴"
    elif [[ $warn_count -gt 0 ]]; then
        overall_status="WARNING"
        status_color="#f59e0b"  # orange
        status_emoji="🟡"
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local hostname
    hostname=$(hostname)
    local server_label="${SERVER_LABEL:-$hostname}"

    # Generate HTML
    cat > "$tmp_file" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
HTMLHEAD

    # Add title and refresh meta tag (if auto-refresh enabled)
    local refresh_meta=""
    if [[ "${STATUS_PAGE_AUTO_REFRESH:-false}" == "true" ]]; then
        local refresh_sec="${STATUS_PAGE_REFRESH_SEC:-60}"
        refresh_meta="<meta http-equiv=\"refresh\" content=\"${refresh_sec}\">"
    fi

    cat >> "$tmp_file" << HTMLHEAD2
    <title>Telemon Status - ${server_label}</title>
    ${refresh_meta}
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: #0f172a;
            color: #e2e8f0;
            line-height: 1.6;
            padding: 20px;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        .header {
            background: linear-gradient(135deg, #1e293b 0%, #334155 100%);
            border-radius: 12px;
            padding: 30px;
            margin-bottom: 20px;
            border: 1px solid #475569;
        }
        .header-top {
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 15px;
            margin-bottom: 20px;
        }
        .server-info h1 {
            font-size: 1.8rem;
            color: #f8fafc;
            margin-bottom: 5px;
        }
        .server-info .hostname {
            color: #94a3b8;
            font-size: 0.9rem;
        }
        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 12px 24px;
            border-radius: 8px;
            font-weight: 600;
            font-size: 1.1rem;
            background: ${status_color}20;
            color: ${status_color};
            border: 2px solid ${status_color};
        }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
        }
        .summary-card {
            background: #1e293b;
            border-radius: 8px;
            padding: 20px;
            text-align: center;
            border: 1px solid #334155;
        }
        .summary-card.critical { border-color: #ef4444; background: #ef444420; }
        .summary-card.warning { border-color: #f59e0b; background: #f59e0b20; }
        .summary-card.ok { border-color: #10b981; background: #10b98120; }
        .summary-card .count {
            font-size: 2rem;
            font-weight: 700;
            margin-bottom: 5px;
        }
        .summary-card.critical .count { color: #ef4444; }
        .summary-card.warning .count { color: #f59e0b; }
        .summary-card.ok .count { color: #10b981; }
        .summary-card .label {
            color: #94a3b8;
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .checks-section {
            background: #1e293b;
            border-radius: 12px;
            padding: 20px;
            border: 1px solid #334155;
        }
        .checks-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
            flex-wrap: wrap;
            gap: 10px;
        }
        .checks-header h2 {
            font-size: 1.3rem;
            color: #f8fafc;
        }
        .timestamp {
            color: #64748b;
            font-size: 0.85rem;
        }
        .checks-table {
            width: 100%;
            border-collapse: collapse;
        }
        .checks-table th {
            text-align: left;
            padding: 12px;
            color: #94a3b8;
            font-weight: 500;
            font-size: 0.85rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            border-bottom: 2px solid #334155;
        }
        .checks-table td {
            padding: 12px;
            border-bottom: 1px solid #334155;
        }
        .checks-table tr:hover {
            background: #33415540;
        }
        .status-cell {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 4px 12px;
            border-radius: 4px;
            font-size: 0.85rem;
            font-weight: 500;
        }
        .status-critical {
            background: #ef444420;
            color: #ef4444;
        }
        .status-warning {
            background: #f59e0b20;
            color: #f59e0b;
        }
        .status-ok {
            background: #10b98120;
            color: #10b981;
        }
        .detail-text {
            color: #cbd5e1;
            font-size: 0.9rem;
            max-width: 500px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .detail-text:hover {
            white-space: normal;
            word-break: break-word;
        }
        .filter-buttons {
            display: flex;
            gap: 10px;
            margin-bottom: 15px;
        }
        .filter-btn {
            background: #334155;
            border: none;
            color: #e2e8f0;
            padding: 8px 16px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.85rem;
            transition: all 0.2s;
        }
        .filter-btn:hover { background: #475569; }
        .filter-btn.active {
            background: #3b82f6;
            color: white;
        }
        .no-checks {
            text-align: center;
            padding: 60px 20px;
            color: #64748b;
        }
        .footer {
            text-align: center;
            margin-top: 30px;
            padding: 20px;
            color: #64748b;
            font-size: 0.85rem;
        }
        .footer a {
            color: #3b82f6;
            text-decoration: none;
        }
        .footer a:hover { text-decoration: underline; }
        @media (max-width: 768px) {
            .header-top { flex-direction: column; text-align: center; }
            .checks-header { flex-direction: column; align-items: flex-start; }
            .checks-table th, .checks-table td { padding: 8px; }
            .detail-text { max-width: 200px; }
        }
    </style>
HTMLHEAD2

    cat >> "$tmp_file" << 'HTMLSCRIPT'
    <script>
        function filterChecks(status) {
            const rows = document.querySelectorAll('.check-row');
            const buttons = document.querySelectorAll('.filter-btn');
            
            buttons.forEach(btn => btn.classList.remove('active'));
            event.target.classList.add('active');
            
            rows.forEach(row => {
                if (status === 'all' || row.dataset.status === status) {
                    row.style.display = '';
                } else {
                    row.style.display = 'none';
                }
            });
        }
    </script>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="header-top">
                <div class="server-info">
HTMLSCRIPT

    # Server info section
    cat >> "$tmp_file" << SERVERINFO
                    <h1>${status_emoji} ${server_label}</h1>
                    <div class="hostname">${hostname}</div>
                </div>
                <div class="status-badge" style="background: ${status_color}20; color: ${status_color}; border-color: ${status_color};">
                    ${status_emoji} ${overall_status}
                </div>
            </div>
            <div class="summary-cards">
                <div class="summary-card critical">
                    <div class="count">${crit_count}</div>
                    <div class="label">Critical</div>
                </div>
                <div class="summary-card warning">
                    <div class="count">${warn_count}</div>
                    <div class="label">Warning</div>
                </div>
                <div class="summary-card ok">
                    <div class="count">${ok_count}</div>
                    <div class="label">Healthy</div>
                </div>
                <div class="summary-card">
                    <div class="count">${total}</div>
                    <div class="label">Total Checks</div>
                </div>
            </div>
        </div>
SERVERINFO

    # Checks table section
    cat >> "$tmp_file" << 'CHECKSHEAD'
        <div class="checks-section">
            <div class="checks-header">
                <h2>🔍 Check Details</h2>
                <div class="timestamp">Last updated: 
CHECKSHEAD
    printf '%s' "$timestamp" >> "$tmp_file"
    cat >> "$tmp_file" << 'CHECKSMID'
</div>
            </div>
            <div class="filter-buttons">
                <button class="filter-btn active" onclick="filterChecks('all')">All</button>
                <button class="filter-btn" onclick="filterChecks('CRITICAL')">Critical</button>
                <button class="filter-btn" onclick="filterChecks('WARNING')">Warning</button>
                <button class="filter-btn" onclick="filterChecks('OK')">OK</button>
            </div>
            <table class="checks-table">
                <thead>
                    <tr>
                        <th>Status</th>
                        <th>Check</th>
                        <th>Detail</th>
                    </tr>
                </thead>
                <tbody>
CHECKSMID

    # Add check rows
    if [[ $total -eq 0 ]]; then
        cat >> "$tmp_file" << 'NOCHECKS'
                    <tr>
                        <td colspan="3" class="no-checks">
                            <p>No checks have been run yet.</p>
                            <p style="margin-top: 10px; font-size: 0.9rem;">Run telemon.sh to populate status.</p>
                        </td>
                    </tr>
NOCHECKS
    else
        # Sort by status: CRITICAL first, then WARNING, then OK
        local sorted_keys=()
        
        # Add CRITICAL items first
        for key in "${!CURR_STATE[@]}"; do
            [[ "${CURR_STATE[$key]}" == "CRITICAL" ]] && sorted_keys+=("$key")
        done
        
        # Add WARNING items next
        for key in "${!CURR_STATE[@]}"; do
            [[ "${CURR_STATE[$key]}" == "WARNING" ]] && sorted_keys+=("$key")
        done
        
        # Add OK items last
        for key in "${!CURR_STATE[@]}"; do
            [[ "${CURR_STATE[$key]}" == "OK" ]] && sorted_keys+=("$key")
        done

        for key in "${sorted_keys[@]}"; do
            local state="${CURR_STATE[$key]}"
            local detail="${STATE_DETAIL[$key]:-$state}"
            local status_class="status-ok"
            local status_emoji_row="✅"
            
            case "$state" in
                CRITICAL)
                    status_class="status-critical"
                    status_emoji_row="🔴"
                    ;;
                WARNING)
                    status_class="status-warning"
                    status_emoji_row="🟡"
                    ;;
            esac

            # Escape HTML in detail
            detail=$(html_escape "$detail")

            cat >> "$tmp_file" << ROW
                    <tr class="check-row" data-status="${state}">
                        <td><span class="status-cell ${status_class}">${status_emoji_row} ${state}</span></td>
                        <td><code style="background: #334155; padding: 2px 6px; border-radius: 4px; font-size: 0.85rem;">${key}</code></td>
                        <td><div class="detail-text" title="${detail}">${detail}</div></td>
                    </tr>
ROW
        done
    fi

    # Footer
    cat >> "$tmp_file" << 'FOOTER'
                </tbody>
            </table>
        </div>
        <div class="footer">
            <p>Generated by <a href="https://github.com/SwordfishTrumpet/telemon" target="_blank">Telemon</a></p>
FOOTER
    
    # Add generation timestamp
    cat >> "$tmp_file" << FOOTER2
            <p style="margin-top: 5px;">Page generated: ${timestamp}</p>
        </div>
    </div>
</body>
</html>
FOOTER2

    # Atomic move
    if mv "$tmp_file" "$output_file"; then
        chmod 644 "$output_file" 2>/dev/null || true
        log "INFO" "Status page generated: ${output_file} (${total} checks)"
        return 0
    else
        log "ERROR" "Failed to write status page: ${output_file}"
        rm -f "$tmp_file"
        return 1
    fi
}

# ===========================================================================
# Heartbeat Sender (Dead Man's Switch)
# Writes a heartbeat file or pings a webhook URL after each run
# ===========================================================================
send_heartbeat() {
    [[ "${ENABLE_HEARTBEAT:-false}" != "true" ]] && return

    local label="${SERVER_LABEL}"
    local sanitized_label
    sanitized_label=$(sanitize_state_key "$label")
    local mode="${HEARTBEAT_MODE:-file}"

    if [[ "$mode" == "file" ]]; then
        local dir="${HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
        if ! mkdir -p "$dir" 2>/dev/null; then
            log "WARN" "Heartbeat: failed to create directory ${dir}"
            return
        fi
        chmod 1755 "$dir" 2>/dev/null || true

        # Build heartbeat payload (tab-separated)
        # NOTE: Only counts are written (not key names) to avoid leaking internal
        # infrastructure details (service names, URLs, ports) to shared storage
        local timestamp
        timestamp=$(date +%s)
        local status="OK"
        local warn_count=0 crit_count=0
        for key in "${!CURR_STATE[@]}"; do
            case "${CURR_STATE[$key]}" in
                CRITICAL) status="CRITICAL"; crit_count=$((crit_count + 1)) ;;
                WARNING)  [[ "$status" != "CRITICAL" ]] && status="WARNING"; warn_count=$((warn_count + 1)) ;;
            esac
        done
        local check_count=${#CURR_STATE[@]}

        local uptime_sec
        uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo "0")

        local heartbeat_line
        heartbeat_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "$label" "$timestamp" "$status" "$check_count" "$warn_count" "$crit_count" "$uptime_sec")

        # Atomic write via temp file + mv -T (NFS-safe, symlink-safe)
        # chmod 1755 (sticky bit) prevents other users from replacing files in shared dir
        local target="${dir}/${sanitized_label}"
        chmod 1755 "$dir" 2>/dev/null || true
        local tmp
        tmp=$(mktemp "${target}.XXXXXX") || { log "WARN" "Heartbeat: failed to create temp file"; return; }
        printf '%s\n' "$heartbeat_line" > "$tmp"
        chmod 644 "$tmp" 2>/dev/null || true
        # mv -T refuses to follow symlinks at target (prevents TOCTOU race)
        if ! mv -T "$tmp" "$target" 2>/dev/null; then
            # Fallback for non-GNU mv: check for symlink, then plain mv
            if [[ -L "$target" ]]; then
                log "WARN" "Heartbeat: target is a symlink — refusing to write: ${target}"
                rm -f "$tmp"
                return
            fi
            mv "$tmp" "$target" || { log "WARN" "Heartbeat: failed to write ${target}"; rm -f "$tmp"; return; }
        fi

        log "DEBUG" "Heartbeat file updated: ${target}"

    elif [[ "$mode" == "webhook" ]]; then
        local url="${HEARTBEAT_URL:-}"
        if [[ -z "$url" ]]; then
            log "WARN" "Heartbeat: HEARTBEAT_URL is empty (required for webhook mode)"
            return
        fi
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null) || http_code="000"
        if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
            log "WARN" "Heartbeat ping failed (HTTP ${http_code})"
        else
            log "DEBUG" "Heartbeat ping sent to ${url%%\?*}"
        fi
    else
        log "WARN" "Heartbeat: unknown HEARTBEAT_MODE '${mode}' (expected 'file' or 'webhook')"
    fi
}

# ===========================================================================
# Alert Retry/Queue
# If dispatch fails, queue to a file and retry on next cycle
# ===========================================================================
ALERT_QUEUE_FILE="${STATE_FILE:-/tmp/telemon_sys_alert_state}.queue"

dispatch_with_retry() {
    local message="$1"

    # Export hostname for all dispatchers
    export TELEMON_HOSTNAME
    TELEMON_HOSTNAME="$(hostname)"

    # First try to send any queued alerts from previous failures
    if [[ -f "$ALERT_QUEUE_FILE" ]]; then
        local queued_msg
        queued_msg=$(cat "$ALERT_QUEUE_FILE" 2>/dev/null)
        if [[ -n "$queued_msg" ]]; then
            log "DEBUG" "Retrying queued alert from previous cycle"
            # Try all channels - remove queue only if Telegram succeeds (primary)
            if send_telegram "$queued_msg" 2>/dev/null; then
                send_webhook "$queued_msg" || true
                send_email "$queued_msg" || true
                rm -f "$ALERT_QUEUE_FILE"
                log "DEBUG" "Queued alert delivered successfully"
            fi
        fi
    fi

    # Now try to send the current message to all channels
    # Track individual channel failures for proper retry logic
    local telegram_ok="false"
    local webhook_ok="false"
    local email_ok="false"

    # Try Telegram (primary channel)
    if send_telegram "$message" 2>/dev/null; then
        telegram_ok="true"
    fi

    # Try Webhook (independent of Telegram)
    if send_webhook "$message" 2>/dev/null; then
        webhook_ok="true"
    fi

    # Try Email (independent of Telegram)
    if send_email "$message" 2>/dev/null; then
        email_ok="true"
    fi

    # Determine overall success and audit log
    if [[ "$telegram_ok" == "true" ]]; then
        # Telegram is the primary channel - if it works, consider alert delivered
        # But log if other channels failed
        if [[ "$webhook_ok" == "false" && -n "${WEBHOOK_URL:-}" ]]; then
            log "WARN" "Telegram delivered but webhook failed — will NOT retry webhook (configure webhook retry separately if needed)"
        fi
        if [[ "$email_ok" == "false" && -n "${EMAIL_TO:-}" ]]; then
            log "WARN" "Telegram delivered but email failed — will NOT retry email (configure email retry separately if needed)"
        fi
        audit_log "alert" "Alert dispatched successfully (Telegram primary)"
    else
        # Telegram failed - queue for full retry (all channels)
        log "WARN" "Alert delivery failed — queuing for retry (Telegram primary channel failed)"
        local existing_queue=""
        if [[ -f "$ALERT_QUEUE_FILE" ]]; then
            existing_queue=$(cat "$ALERT_QUEUE_FILE" 2>/dev/null) || existing_queue=""
            
            # BOUNDED QUEUE: Check size and age to prevent unbounded growth
            local max_queue_size="${MAX_ALERT_QUEUE_SIZE:-1048576}"  # Default 1MB
            local max_queue_age="${MAX_ALERT_QUEUE_AGE:-86400}"    # Default 24 hours
            local queue_size queue_age
            
            queue_size=$(stat -c%s "$ALERT_QUEUE_FILE" 2>/dev/null || echo "0")
            queue_age=$(( $(date +%s) - $(stat -c%Y "$ALERT_QUEUE_FILE" 2>/dev/null || echo "0") ))
            
            # Evict old queue if exceeds max size or age
            if [[ $queue_size -gt $max_queue_size ]]; then
                log "WARN" "Alert queue exceeds ${max_queue_size} bytes (${queue_size} bytes) — truncating to prevent disk fill"
                # Keep only last 50% of queue (approximate by line count)
                local total_lines
                total_lines=$(wc -l < "$ALERT_QUEUE_FILE")
                existing_queue=$(tail -n $(( total_lines / 2 )) "$ALERT_QUEUE_FILE")
            elif [[ $queue_age -gt $max_queue_age ]]; then
                log "WARN" "Alert queue older than ${max_queue_age}s (${queue_age}s) — clearing stale alerts"
                existing_queue=""  # Clear queue entirely
            fi
        fi
        local separator=""
        [[ -n "$existing_queue" ]] && separator=$'\n---QUEUED_ALERT---\n'
        safe_write_state_file "$ALERT_QUEUE_FILE" "${existing_queue}${separator}${message}"
        # Audit log failed alert (with queued status)
        audit_log "alert" "Alert delivery failed - queued for retry"
    fi
}

# ===========================================================================
# Scheduled Maintenance Windows
# Checks MAINT_SCHEDULE for recurring time windows (e.g., "Sun 02:00-04:00")
# ===========================================================================
is_in_maintenance_window() {
    local schedule="${MAINT_SCHEDULE:-}"
    [[ -z "$schedule" ]] && return 1  # no schedule = not in maintenance

    local current_day
    current_day=$(date '+%a')  # Mon, Tue, Wed, Thu, Fri, Sat, Sun
    local current_minutes
    current_minutes=$(( $(date '+%-H') * 60 + $(date '+%-M') ))

    # Parse schedule entries separated by semicolons: "Sun 02:00-04:00;Sat 03:00-05:00"
    local IFS=';'
    for entry in $schedule; do
        entry=$(echo "$entry" | xargs)  # trim whitespace
        [[ -z "$entry" ]] && continue

        local sched_day="${entry%% *}"
        local time_range="${entry##* }"
        local start_time="${time_range%%-*}"
        local end_time="${time_range##*-}"

        # Check if day matches
        if [[ "$current_day" != "$sched_day" ]]; then
            continue
        fi

        # Parse start/end times to minutes (with validation)
        local start_h="${start_time%%:*}"
        local start_m="${start_time##*:}"
        local end_h="${end_time%%:*}"
        local end_m="${end_time##*:}"

        # Validate time components are numeric before arithmetic
        if ! is_valid_number "$start_h" || ! is_valid_number "$start_m" || ! is_valid_number "$end_h" || ! is_valid_number "$end_m"; then
            log "WARN" "Invalid MAINT_SCHEDULE entry: '${entry}' — skipping"
            continue
        fi

        # Validate hour/minute ranges
        if (( 10#$start_h > 23 || 10#$start_m > 59 || 10#$end_h > 23 || 10#$end_m > 59 )); then
            log "WARN" "Invalid time range in MAINT_SCHEDULE entry: '${entry}' — hours must be 0-23, minutes 0-59"
            continue
        fi

        local start_min=$(( 10#$start_h * 60 + 10#$start_m ))
        local end_min=$(( 10#$end_h * 60 + 10#$end_m ))

        if (( current_minutes >= start_min && current_minutes < end_min )); then
            return 0  # in maintenance window
        fi
    done

    return 1  # not in any window
}

# ===========================================================================
# Alert Escalation
# Sends to escalation channel if alert stays unresolved for N minutes
# ===========================================================================
check_escalation() {
    local escalation_url="${ESCALATION_WEBHOOK_URL:-}"
    local escalation_after="${ESCALATION_AFTER_MIN:-30}"
    [[ -z "$escalation_url" ]] && return

    local escalation_state_file="${STATE_FILE}.escalation"

    # Load previous escalation timestamps
    declare -A esc_timestamps
    if [[ -f "$escalation_state_file" ]]; then
        while IFS='=' read -r key ts; do
            [[ -n "$key" ]] && esc_timestamps["$key"]="$ts"
        done < "$escalation_state_file"
    fi

    local now
    now=$(date +%s)
    local new_escalation_state=""
    local escalation_alerts=""

    for key in "${!CURR_STATE[@]}"; do
        local cstate="${CURR_STATE[$key]}"

        if [[ "$cstate" == "CRITICAL" || "$cstate" == "WARNING" ]]; then
            local first_seen="${esc_timestamps[$key]:-$now}"
            new_escalation_state+="${key}=${first_seen}"$'\n'

            local elapsed_min=$(( (now - first_seen) / 60 ))
            if (( elapsed_min >= escalation_after )); then
                # Only escalate once — check if already escalated
                local already_esc="${esc_timestamps[${key}_escalated]:-}"
                if [[ -z "$already_esc" ]]; then
                    escalation_alerts+="&#128680; <b>${key}</b>: ${STATE_DETAIL[$key]:-$cstate} (unresolved for ${elapsed_min}m)%0A%0A"
                    new_escalation_state+="${key}_escalated=1"$'\n'
                fi
            fi
        fi
        # Note: Keys that are now OK are intentionally NOT added to new_escalation_state
        # This effectively prunes resolved alerts from the escalation tracking.
        # The _escalated markers are also automatically cleaned up since we only
        # persist keys that are currently in WARNING/CRITICAL state.
    done

    # Save escalation state
    # Note: _escalated markers are automatically cleared when keys transition to OK
    # because only non-OK keys are written to new_escalation_state above.
    safe_write_state_file "$escalation_state_file" "$new_escalation_state"

    # Send escalation if any
    if [[ -n "$escalation_alerts" ]]; then
        local esc_message="<b>&#128680; [${SERVER_LABEL}] ESCALATION ALERT</b>%0A"
        esc_message+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"
        esc_message+="${escalation_alerts}"

        # Audit log the escalation
        audit_log "escalation" "Escalation triggered after ${escalation_after}min: ${escalation_alerts//%0A/ }"

        # Send to escalation webhook (requires python3 for safe JSON encoding)
        if ! command -v python3 &>/dev/null; then
            log "WARN" "Escalation webhook: python3 not found — skipping"
            return
        fi

        local plain_msg
        plain_msg=$(printf '%s\n' "$esc_message" | sed 's/%0A/\n/g; s/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')

        local json_payload
        json_payload=$(TELEMON_HOSTNAME="$(hostname)" TELEMON_SERVER_LABEL="${SERVER_LABEL}" TELEMON_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            run_with_timeout "$CHECK_TIMEOUT" python3 -c "
import json, sys, os
data = {
    'hostname': os.environ.get('TELEMON_HOSTNAME', ''),
    'server_label': os.environ.get('TELEMON_SERVER_LABEL', ''),
    'type': 'escalation',
    'timestamp': os.environ.get('TELEMON_TIMESTAMP', ''),
    'message': sys.stdin.read().strip()
}
print(json.dumps(data))
" <<< "$plain_msg" 2>/dev/null) || return

        curl -s --max-time 30 -X POST \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            "$escalation_url" &>/dev/null || log "WARN" "Escalation webhook delivery failed"

        log "INFO" "Escalation alert sent"
    fi
}

# ===========================================================================
# CLI Modes: --test, --validate, --digest
# ===========================================================================
run_validate() {
    echo "Telemon configuration validation"
    echo "================================="
    echo ""
    
    local errors=0
    local warnings=0
    
    # Check Telegram credentials
    echo "[Telegram Credentials]"
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || "$TELEGRAM_BOT_TOKEN" == "your-bot-token-here" ]]; then
        echo "  FAIL: TELEGRAM_BOT_TOKEN is not set"
        errors=$((errors + 1))
    else
        echo "  OK:   TELEGRAM_BOT_TOKEN is set (${#TELEGRAM_BOT_TOKEN} chars)"
    fi
    
    if [[ -z "${TELEGRAM_CHAT_ID:-}" || "$TELEGRAM_CHAT_ID" == "your-chat-id-here" ]]; then
        echo "  FAIL: TELEGRAM_CHAT_ID is not set"
        errors=$((errors + 1))
    else
        echo "  OK:   TELEGRAM_CHAT_ID is set (${#TELEGRAM_CHAT_ID} chars)"
    fi
    
    # Check .env permissions
    echo ""
    echo "[Security]"
    local env_perms
    env_perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null)
    if [[ "$env_perms" != "600" ]]; then
        echo "  WARN: .env permissions are $env_perms (should be 600)"
        echo "        Fix: chmod 600 $ENV_FILE"
        warnings=$((warnings + 1))
    else
        echo "  OK:   .env permissions are 600 (owner-only)"
    fi
    
    # Check enabled features and their dependencies
    echo ""
    echo "[Enabled Checks]"
    local enabled=0

    # Check for non-standard boolean values in ENABLE_* flags
    for enable_var in ENABLE_CPU_CHECK ENABLE_MEMORY_CHECK ENABLE_DISK_CHECK \
        ENABLE_SWAP_CHECK ENABLE_IOWAIT_CHECK ENABLE_ZOMBIE_CHECK \
        ENABLE_INTERNET_CHECK ENABLE_SYSTEM_PROCESSES \
        ENABLE_FAILED_SYSTEMD_SERVICES ENABLE_DOCKER_CONTAINERS \
        ENABLE_PM2_PROCESSES ENABLE_SITE_MONITOR ENABLE_NVME_CHECK \
        ENABLE_TCP_PORT_CHECK ENABLE_TEMP_CHECK ENABLE_DNS_CHECK \
        ENABLE_GPU_CHECK ENABLE_UPS_CHECK ENABLE_NETWORK_CHECK \
        ENABLE_LOG_CHECK ENABLE_INTEGRITY_CHECK ENABLE_CRON_CHECK \
        ENABLE_FLEET_CHECK ENABLE_HEARTBEAT ENABLE_PROMETHEUS_EXPORT \
        ENABLE_JSON_STATUS ENABLE_PREDICTIVE_ALERTS ENABLE_DRIFT_DETECTION \
        ENABLE_PLUGINS ENABLE_DATABASE_CHECKS ENABLE_DNS_RECORD_CHECK \
        ENABLE_AUDIT_LOGGING; do
        local val="${!enable_var:-}"
        if [[ -n "$val" && "$val" != "true" && "$val" != "false" ]]; then
            echo "  WARN: ${enable_var}='${val}' — expected 'true' or 'false' (value treated as false)"
            warnings=$((warnings + 1))
        fi
    done

    # Validate SITE_ALLOW_INTERNAL if set (boolean check)
    if [[ -n "${SITE_ALLOW_INTERNAL:-}" && "${SITE_ALLOW_INTERNAL}" != "true" && "${SITE_ALLOW_INTERNAL}" != "false" ]]; then
        echo "  WARN: SITE_ALLOW_INTERNAL='${SITE_ALLOW_INTERNAL}' — expected 'true' or 'false'"
        warnings=$((warnings + 1))
    fi

    for check in CPU MEMORY DISK SWAP IOWAIT ZOMBIE INTERNET; do
        local var="ENABLE_${check}_CHECK"
        if [[ "${!var:-true}" == "true" ]]; then
            echo "  ON:   $check"
            enabled=$((enabled + 1))
        else
            echo "  OFF:  $check"
        fi
    done
    
    if [[ "${ENABLE_SYSTEM_PROCESSES:-true}" == "true" ]]; then
        echo "  ON:   SYSTEM_PROCESSES (${CRITICAL_SYSTEM_PROCESSES:-<empty>})"
        enabled=$((enabled + 1))
        if [[ -z "${CRITICAL_SYSTEM_PROCESSES:-}" ]]; then
            echo "  WARN: SYSTEM_PROCESSES enabled but CRITICAL_SYSTEM_PROCESSES is empty"
            warnings=$((warnings + 1))
        fi
    else
        echo "  OFF:  SYSTEM_PROCESSES"
    fi
    
    if [[ "${ENABLE_FAILED_SYSTEMD_SERVICES:-true}" == "true" ]]; then
        if ! command -v systemctl &>/dev/null; then
            echo "  WARN: FAILED_SYSTEMD_SERVICES enabled but systemctl not found"
            warnings=$((warnings + 1))
        else
            echo "  ON:   FAILED_SYSTEMD_SERVICES"
            enabled=$((enabled + 1))
        fi
    else
        echo "  OFF:  FAILED_SYSTEMD_SERVICES"
    fi
    
    if [[ "${ENABLE_DOCKER_CONTAINERS:-false}" == "true" ]]; then
        if ! command -v docker &>/dev/null; then
            echo "  FAIL: DOCKER_CONTAINERS enabled but docker not found"
            errors=$((errors + 1))
        else
            echo "  ON:   DOCKER_CONTAINERS (${CRITICAL_CONTAINERS:-<empty>})"
            enabled=$((enabled + 1))
            if [[ -z "${CRITICAL_CONTAINERS:-}" ]]; then
                echo "  WARN: DOCKER_CONTAINERS enabled but CRITICAL_CONTAINERS is empty"
                warnings=$((warnings + 1))
            fi
            # Verify listed containers exist
            for c in ${CRITICAL_CONTAINERS:-}; do
                if docker inspect "$c" &>/dev/null; then
                    echo "        ✓ $c exists"
                else
                    echo "        ✗ $c not found (will alert as CRITICAL)"
                    warnings=$((warnings + 1))
                fi
            done
        fi
    else
        echo "  OFF:  DOCKER_CONTAINERS"
    fi
    
    if [[ "${ENABLE_PM2_PROCESSES:-false}" == "true" ]]; then
        if ! command -v pm2 &>/dev/null; then
            echo "  WARN: PM2_PROCESSES enabled but pm2 not found"
            warnings=$((warnings + 1))
        else
            echo "  ON:   PM2_PROCESSES (${CRITICAL_PM2_PROCESSES:-<empty>})"
            enabled=$((enabled + 1))
            if [[ -z "${CRITICAL_PM2_PROCESSES:-}" ]]; then
                echo "  WARN: PM2_PROCESSES enabled but CRITICAL_PM2_PROCESSES is empty"
                warnings=$((warnings + 1))
            fi
        fi
    else
        echo "  OFF:  PM2_PROCESSES"
    fi
    
    if [[ "${ENABLE_SITE_MONITOR:-false}" == "true" ]]; then
        echo "  ON:   SITE_MONITOR"
        enabled=$((enabled + 1))
        if [[ -z "${CRITICAL_SITES:-}" ]]; then
            echo "  WARN: SITE_MONITOR enabled but CRITICAL_SITES is empty"
            warnings=$((warnings + 1))
        fi
        
        # Check for internal/localhost URLs and warn if SITE_ALLOW_INTERNAL not set
        local has_internal_url=false
        for site in ${CRITICAL_SITES:-}; do
            local url="${site%%|*}"
            local host_check="${url#*://}"
            host_check="${host_check%%/*}"
            host_check="${host_check%%:*}"
            if is_internal_ip "$host_check" 2>/dev/null; then
                has_internal_url=true
            fi
            echo "        → $url"
        done
        
        if [[ "$has_internal_url" == "true" ]]; then
            if [[ "${SITE_ALLOW_INTERNAL:-false}" == "true" ]]; then
                echo "  OK:   Internal URL monitoring enabled (SITE_ALLOW_INTERNAL=true)"
            else
                echo "  WARN: CRITICAL_SITES contains internal/localhost URLs but SITE_ALLOW_INTERNAL is not set to true"
                echo "        These URLs will be skipped due to SSRF protection. Add: SITE_ALLOW_INTERNAL=true"
                warnings=$((warnings + 1))
            fi
        fi
    else
        echo "  OFF:  SITE_MONITOR"
    fi
    
    if [[ "${ENABLE_NVME_CHECK:-false}" == "true" ]]; then
        if ! command -v smartctl &>/dev/null; then
            echo "  WARN: NVME_CHECK enabled but smartctl not found"
            warnings=$((warnings + 1))
        else
            echo "  ON:   NVME_CHECK (${NVME_DEVICE:-/dev/nvme0n1})"
            enabled=$((enabled + 1))
        fi
    else
        echo "  OFF:  NVME_CHECK"
    fi
    
    # New checks validation
    for check_pair in \
        "TCP_PORT_CHECK:CRITICAL_PORTS" \
        "TEMP_CHECK:sensors" \
        "DNS_CHECK:dig/nslookup" \
        "GPU_CHECK:nvidia-smi/intel_gpu_top" \
        "UPS_CHECK:upower/apcaccess" \
        "NETWORK_CHECK:/proc/net/dev" \
        "LOG_CHECK:LOG_WATCH_FILES" \
        "INTEGRITY_CHECK:INTEGRITY_WATCH_FILES" \
        "DRIFT_DETECTION:DRIFT_WATCH_FILES" \
        "CRON_CHECK:CRON_WATCH_JOBS"; do
        local ck="${check_pair%%:*}"
        local dep="${check_pair##*:}"
        local var="ENABLE_${ck}"
        if [[ "${!var:-false}" == "true" ]]; then
            echo "  ON:   ${ck} (${dep})"
            enabled=$((enabled + 1))
        else
            echo "  OFF:  ${ck}"
        fi
    done

    # GPU check — show which driver/tool is detected
    if [[ "${ENABLE_GPU_CHECK:-false}" == "true" ]]; then
        if command -v nvidia-smi &>/dev/null; then
            echo "        ✓ nvidia-smi detected (NVIDIA)"
        elif command -v intel_gpu_top &>/dev/null; then
            echo "        ✓ intel_gpu_top detected (Intel)"
        else
            echo "        ⚠ No GPU tool found (nvidia-smi or intel_gpu_top)"
            warnings=$((warnings + 1))
        fi
    fi

    # Heartbeat / Fleet checks
    if [[ "${ENABLE_HEARTBEAT:-false}" == "true" ]]; then
        echo "  ON:   HEARTBEAT (${HEARTBEAT_MODE:-file})"
        enabled=$((enabled + 1))
    else
        echo "  OFF:  HEARTBEAT"
    fi
    if [[ "${ENABLE_FLEET_CHECK:-false}" == "true" ]]; then
        echo "  ON:   FLEET_CHECK (${FLEET_HEARTBEAT_DIR:-/tmp/telemon_heartbeats})"
        enabled=$((enabled + 1))
    else
        echo "  OFF:  FLEET_CHECK"
    fi
    if [[ "${ENABLE_PREDICTIVE_ALERTS:-false}" == "true" ]]; then
        echo "  ON:   PREDICTIVE_ALERTS (horizon: ${PREDICT_HORIZON_HOURS:-24}h, datapoints: ${PREDICT_DATAPOINTS:-48})"
        enabled=$((enabled + 1))
    else
        echo "  OFF:  PREDICTIVE_ALERTS"
    fi

    # Empty-list warnings for extended checks
    if [[ "${ENABLE_TCP_PORT_CHECK:-false}" == "true" ]] && [[ -z "${CRITICAL_PORTS:-}" ]]; then
        echo "  WARN: TCP_PORT_CHECK enabled but CRITICAL_PORTS is empty"
        warnings=$((warnings + 1))
    fi
    if [[ "${ENABLE_TCP_PORT_CHECK:-false}" == "true" ]] && [[ -n "${CRITICAL_PORTS:-}" ]]; then
        for entry in ${CRITICAL_PORTS}; do
            local cp_host="${entry%%:*}"
            local cp_port="${entry##*:}"
            if [[ -z "$cp_host" || -z "$cp_port" || "$cp_host" == "$cp_port" ]]; then
                echo "  FAIL: Invalid CRITICAL_PORTS entry '${entry}' (expected host:port)"
                errors=$((errors + 1))
            elif ! is_valid_number "$cp_port"; then
                echo "  FAIL: Invalid port in CRITICAL_PORTS entry '${entry}' (not numeric)"
                errors=$((errors + 1))
            elif [[ "$cp_port" -lt 1 || "$cp_port" -gt 65535 ]]; then
                echo "  FAIL: Port out of range in CRITICAL_PORTS entry '${entry}' (1-65535)"
                errors=$((errors + 1))
            fi
        done
    fi

    # Integrity check validation
    if [[ "${ENABLE_INTEGRITY_CHECK:-false}" == "true" ]] && [[ -z "${INTEGRITY_WATCH_FILES:-}" ]]; then
        echo "  WARN: INTEGRITY_CHECK enabled but INTEGRITY_WATCH_FILES is empty"
        warnings=$((warnings + 1))
    fi
    if [[ "${ENABLE_INTEGRITY_CHECK:-false}" == "true" ]] && [[ -n "${INTEGRITY_WATCH_FILES:-}" ]]; then
        for iw_file in ${INTEGRITY_WATCH_FILES}; do
            if [[ ! -f "$iw_file" ]]; then
                echo "  WARN: INTEGRITY_WATCH_FILES: '${iw_file}' does not exist"
                warnings=$((warnings + 1))
            fi
        done
    fi

    # Drift detection validation
    if [[ "${ENABLE_DRIFT_DETECTION:-false}" == "true" ]]; then
        if [[ -z "${DRIFT_WATCH_FILES:-}" ]]; then
            echo "  WARN: DRIFT_DETECTION enabled but DRIFT_WATCH_FILES is empty"
            warnings=$((warnings + 1))
        else
            for df_file in ${DRIFT_WATCH_FILES}; do
                if [[ ! -f "$df_file" ]]; then
                    echo "  WARN: DRIFT_WATCH_FILES: '${df_file}' does not exist (will be monitored when created)"
                    warnings=$((warnings + 1))
                elif [[ ! -r "$df_file" ]]; then
                    echo "  WARN: DRIFT_WATCH_FILES: '${df_file}' is not readable"
                    warnings=$((warnings + 1))
                fi
            done
        fi

        # Validate ignore pattern regex
        if [[ -n "${DRIFT_IGNORE_PATTERN:-}" ]]; then
            echo "" | grep -qE "${DRIFT_IGNORE_PATTERN}" 2>/dev/null
            if [[ $? -eq 2 ]]; then
                echo "  FAIL: DRIFT_IGNORE_PATTERN is not a valid regex"
                errors=$((errors + 1))
            fi
        fi

        # Validate max diff lines is a positive integer
        if [[ -n "${DRIFT_MAX_DIFF_LINES:-}" ]]; then
            if ! is_valid_number "${DRIFT_MAX_DIFF_LINES}" 2>/dev/null; then
                echo "  FAIL: DRIFT_MAX_DIFF_LINES must be a positive integer"
                errors=$((errors + 1))
            fi
        fi

        # Check for diff command
        if ! command -v diff &>/dev/null; then
            echo "  WARN: DRIFT_DETECTION enabled but 'diff' command not found (install diffutils)"
            warnings=$((warnings + 1))
        fi

        # Note about ausearch availability
        if ! command -v ausearch &>/dev/null; then
            echo "  INFO: DRIFT_DETECTION: ausearch not found — user attribution will use file owner only"
        fi
    fi

    # Log pattern validation
    if [[ "${ENABLE_LOG_CHECK:-false}" == "true" ]]; then
        if [[ -z "${LOG_WATCH_FILES:-}" ]]; then
            echo "  WARN: LOG_CHECK enabled but LOG_WATCH_FILES is empty"
            warnings=$((warnings + 1))
        fi
        if [[ -z "${LOG_WATCH_PATTERNS:-}" ]]; then
            echo "  WARN: LOG_CHECK enabled but LOG_WATCH_PATTERNS is empty"
            warnings=$((warnings + 1))
        else
            for pattern in ${LOG_WATCH_PATTERNS}; do
                # Test regex validity: grep returns 2 for invalid regex
                echo "" | grep -qE "$pattern" 2>/dev/null
                if [[ $? -eq 2 ]]; then
                    echo "  FAIL: Invalid regex in LOG_WATCH_PATTERNS: '${pattern}'"
                    errors=$((errors + 1))
                fi
            done
        fi
    fi

    # Cron job format validation
    if [[ "${ENABLE_CRON_CHECK:-false}" == "true" ]]; then
        if [[ -z "${CRON_WATCH_JOBS:-}" ]]; then
            echo "  WARN: CRON_CHECK enabled but CRON_WATCH_JOBS is empty"
            warnings=$((warnings + 1))
        else
            for entry in ${CRON_WATCH_JOBS}; do
                local cron_name="${entry%%:*}"
                local cron_rest="${entry#*:}"
                local cron_touchfile="${cron_rest%%:*}"
                local cron_max_age="${cron_rest##*:}"

                if [[ -z "$cron_name" || -z "$cron_touchfile" || -z "$cron_max_age" ]]; then
                    echo "  FAIL: Invalid CRON_WATCH_JOBS entry: '${entry}' (expected name:touchfile:max_age_minutes)"
                    errors=$((errors + 1))
                elif ! is_valid_number "$cron_max_age"; then
                    echo "  FAIL: Invalid max_age in CRON_WATCH_JOBS entry: '${entry}' (must be a positive integer)"
                    errors=$((errors + 1))
                elif [[ "$cron_max_age" -le 0 ]]; then
                    echo "  FAIL: max_age must be > 0 in CRON_WATCH_JOBS entry: '${entry}'"
                    errors=$((errors + 1))
                fi
            done
        fi
    fi

    # Plugin system validation
    if [[ "${ENABLE_PLUGINS:-false}" == "true" ]]; then
        local checks_dir="${CHECKS_DIR:-${SCRIPT_DIR}/checks.d}"
        echo "  ON:   PLUGINS (${checks_dir})"
        enabled=$((enabled + 1))
        if [[ ! -d "$checks_dir" ]]; then
            echo "  WARN: CHECKS_DIR '${checks_dir}' does not exist (will be monitored when created)"
            warnings=$((warnings + 1))
        elif [[ ! -r "$checks_dir" ]]; then
            echo "  FAIL: CHECKS_DIR '${checks_dir}' is not readable"
            errors=$((errors + 1))
        else
            local plugin_count=0
            for plugin in "$checks_dir"/*; do
                [[ -f "$plugin" ]] || continue
                [[ -x "$plugin" ]] || continue
                plugin_count=$((plugin_count + 1))
            done
            echo "  OK:   ${plugin_count} executable plugin(s) found"
        fi
    else
        echo "  OFF:  PLUGINS"
    fi

    # Database checks validation
    if [[ "${ENABLE_DATABASE_CHECKS:-false}" == "true" ]]; then
        echo "  ON:   DATABASE_CHECKS"
        enabled=$((enabled + 1))
        
        # Validate MySQL configuration
        if [[ -n "${DB_MYSQL_HOST:-}" ]]; then
            if [[ -z "${DB_MYSQL_USER:-}" ]]; then
                echo "  WARN: DB_MYSQL_HOST is set but DB_MYSQL_USER is empty"
                warnings=$((warnings + 1))
            fi
        fi
        
        # Validate PostgreSQL configuration
        if [[ -n "${DB_POSTGRES_HOST:-}" ]]; then
            if [[ -z "${DB_POSTGRES_USER:-}" ]]; then
                echo "  WARN: DB_POSTGRES_HOST is set but DB_POSTGRES_USER is empty"
                warnings=$((warnings + 1))
            fi
        fi
        
        # Validate Redis configuration
        if [[ -n "${DB_REDIS_HOST:-}" ]]; then
            echo "  OK:   Redis configuration present (${DB_REDIS_HOST}:${DB_REDIS_PORT:-6379})"
        fi
        
        # Validate SQLite configuration
        if [[ -n "${DB_SQLITE_PATHS:-}" ]]; then
            echo "  OK:   SQLite configuration present"
            if ! command -v sqlite3 &>/dev/null; then
                echo "  WARN: SQLite DB paths configured but sqlite3 command not found"
                warnings=$((warnings + 1))
            fi
            # Validate each path
            for db_path in $DB_SQLITE_PATHS; do
                if ! is_safe_path "$db_path"; then
                    echo "  WARN: SQLite path unsafe (contains .., *, ?, or $): ${db_path}"
                    warnings=$((warnings + 1))
                elif [[ ! -f "$db_path" ]]; then
                    echo "  WARN: SQLite database file not found: ${db_path}"
                    warnings=$((warnings + 1))
                elif [[ ! -r "$db_path" ]]; then
                    echo "  WARN: SQLite database file not readable: ${db_path}"
                    warnings=$((warnings + 1))
                fi
            done
            # Validate size thresholds are numeric
            if [[ -n "${DB_SQLITE_SIZE_THRESHOLD_WARN:-}" && "${DB_SQLITE_SIZE_THRESHOLD_WARN}" != "0" ]]; then
                if ! is_valid_number "$DB_SQLITE_SIZE_THRESHOLD_WARN"; then
                    echo "  WARN: DB_SQLITE_SIZE_THRESHOLD_WARN is not a valid number: ${DB_SQLITE_SIZE_THRESHOLD_WARN}"
                    warnings=$((warnings + 1))
                fi
            fi
            if [[ -n "${DB_SQLITE_SIZE_THRESHOLD_CRIT:-}" && "${DB_SQLITE_SIZE_THRESHOLD_CRIT}" != "0" ]]; then
                if ! is_valid_number "$DB_SQLITE_SIZE_THRESHOLD_CRIT"; then
                    echo "  WARN: DB_SQLITE_SIZE_THRESHOLD_CRIT is not a valid number: ${DB_SQLITE_SIZE_THRESHOLD_CRIT}"
                    warnings=$((warnings + 1))
                fi
                # Validate crit > warn if both set
                if [[ -n "${DB_SQLITE_SIZE_THRESHOLD_WARN:-}" && "${DB_SQLITE_SIZE_THRESHOLD_WARN}" != "0" ]]; then
                    if [[ "$DB_SQLITE_SIZE_THRESHOLD_WARN" -ge "$DB_SQLITE_SIZE_THRESHOLD_CRIT" ]]; then
                        echo "  WARN: DB_SQLITE_SIZE_THRESHOLD_WARN (${DB_SQLITE_SIZE_THRESHOLD_WARN}) should be less than DB_SQLITE_SIZE_THRESHOLD_CRIT (${DB_SQLITE_SIZE_THRESHOLD_CRIT})"
                        warnings=$((warnings + 1))
                    fi
                fi
            fi
        fi
        
        # Validate ODBC configuration
        if [[ "${ENABLE_ODBC_CHECKS:-false}" == "true" ]]; then
            echo "  ON:   ODBC_CHECKS"
            enabled=$((enabled + 1))
            if [[ -z "${ODBC_CONNECTIONS:-}" ]]; then
                echo "  WARN: ODBC_CHECKS enabled but ODBC_CONNECTIONS is empty"
                warnings=$((warnings + 1))
            else
                if ! command -v isql &>/dev/null; then
                    echo "  WARN: ODBC_CHECKS enabled but isql not found (install unixodbc)"
                    warnings=$((warnings + 1))
                fi
                # Validate each ODBC connection
                for conn_name in $ODBC_CONNECTIONS; do
                    if ! is_valid_service_name "$conn_name"; then
                        echo "  WARN: Invalid ODBC connection name '${conn_name}' (alphanumeric, underscore, hyphen, dot only)"
                        warnings=$((warnings + 1))
                        continue
                    fi
                    local dsn_var="ODBC_${conn_name}_DSN"
                    local driver_var="ODBC_${conn_name}_DRIVER"
                    local server_var="ODBC_${conn_name}_SERVER"
                    if [[ -z "${!dsn_var:-}" && ( -z "${!driver_var:-}" || -z "${!server_var:-}" ) ]]; then
                        echo "  WARN: ODBC connection '${conn_name}' needs ODBC_${conn_name}_DSN or (ODBC_${conn_name}_DRIVER + ODBC_${conn_name}_SERVER)"
                        warnings=$((warnings + 1))
                    fi
                done
            fi
        else
            echo "  OFF:  ODBC_CHECKS"
        fi
    else
        echo "  OFF:  DATABASE_CHECKS"
    fi

    # DNS Record check validation
    if [[ "${ENABLE_DNS_RECORD_CHECK:-false}" == "true" ]]; then
        echo "  ON:   DNS_RECORD_CHECK"
        enabled=$((enabled + 1))
        if [[ -z "${DNS_CHECK_RECORDS:-}" ]]; then
            echo "  WARN: DNS_RECORD_CHECK enabled but DNS_CHECK_RECORDS is empty"
            warnings=$((warnings + 1))
        else
            # Check for dig command
            if ! command -v dig &>/dev/null; then
                echo "  WARN: DNS_RECORD_CHECK enabled but dig not found (install bind-utils or dnsutils)"
                warnings=$((warnings + 1))
            fi
            # Validate record format
            local valid_types="A AAAA MX TXT CNAME NS SOA PTR SRV CAA"
            local IFS=',' record_count=0
            for record in ${DNS_CHECK_RECORDS}; do
                record_count=$((record_count + 1))
                local rec_domain="${record%%:*}"
                local rec_rest="${record#*:}"
                local rec_type="${rec_rest%%:*}"
                local rec_expected="${rec_rest##*:}"
                
                if [[ -z "$rec_domain" || -z "$rec_type" || -z "$rec_expected" || "$rec_rest" == "$rec_domain" ]]; then
                    echo "  FAIL: Invalid DNS_CHECK_RECORDS entry '${record}' (expected domain:type:expected_value)"
                    errors=$((errors + 1))
                else
                    # Check record type validity
                    local type_valid=false
                    for vt in $valid_types; do
                        if [[ "$(echo "$rec_type" | tr '[:lower:]' '[:upper:]')" == "$vt" ]]; then
                            type_valid=true
                            break
                        fi
                    done
                    if [[ "$type_valid" != "true" ]]; then
                        echo "  WARN: Unknown record type '${rec_type}' in '${record}' (valid: ${valid_types})"
                        warnings=$((warnings + 1))
                    fi
                fi
            done
            echo "  OK:   ${record_count} DNS record(s) configured"
        fi
    else
        echo "  OFF:  DNS_RECORD_CHECK"
    fi

    # Audit logging validation
    if [[ "${ENABLE_AUDIT_LOGGING:-false}" == "true" ]]; then
        echo "  ON:   AUDIT_LOGGING"
        local audit_file="${AUDIT_LOG_FILE:-/var/log/telemon_audit.log}"
        local audit_dir
        audit_dir="$(dirname "$audit_file")"
        if [[ ! -d "$audit_dir" ]]; then
            echo "  WARN: AUDIT_LOGGING enabled but directory '${audit_dir}' does not exist (will attempt creation)"
            warnings=$((warnings + 1))
        elif [[ ! -w "$audit_dir" ]]; then
            echo "  WARN: AUDIT_LOGGING enabled but directory '${audit_dir}' is not writable"
            warnings=$((warnings + 1))
        else
            echo "  OK:   Audit log path: ${audit_file}"
        fi
        local audit_events="${AUDIT_EVENTS:-all}"
        echo "  OK:   Audit events: ${audit_events}"
    else
        echo "  OFF:  AUDIT_LOGGING"
    fi

    # Heartbeat / Fleet validation
    if [[ "${ENABLE_HEARTBEAT:-false}" == "true" ]] || [[ "${ENABLE_FLEET_CHECK:-false}" == "true" ]]; then
        echo ""
        echo "[Heartbeat / Fleet]"
        echo "  OK:   SERVER_LABEL=${SERVER_LABEL}"
        if [[ "${ENABLE_HEARTBEAT:-false}" == "true" ]]; then
            local hb_mode="${HEARTBEAT_MODE:-file}"
            if [[ "$hb_mode" != "file" && "$hb_mode" != "webhook" ]]; then
                echo "  FAIL: HEARTBEAT_MODE '${hb_mode}' must be 'file' or 'webhook'"
                errors=$((errors + 1))
            else
                echo "  OK:   HEARTBEAT_MODE=${hb_mode}"
            fi
            if [[ "$hb_mode" == "file" ]]; then
                local hb_dir="${HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
                if [[ -d "$hb_dir" ]]; then
                    if [[ ! -w "$hb_dir" ]]; then
                        echo "  FAIL: HEARTBEAT_DIR '${hb_dir}' is not writable"
                        errors=$((errors + 1))
                    else
                        echo "  OK:   HEARTBEAT_DIR=${hb_dir} (exists, writable)"
                    fi
                else
                    echo "  WARN: HEARTBEAT_DIR '${hb_dir}' does not exist yet (will be created on first run)"
                    warnings=$((warnings + 1))
                fi
            fi
            if [[ "$hb_mode" == "webhook" ]]; then
                local hb_url="${HEARTBEAT_URL:-}"
                if [[ -z "$hb_url" ]]; then
                    echo "  FAIL: HEARTBEAT_URL is empty (required for webhook mode)"
                    errors=$((errors + 1))
                elif [[ ! "$hb_url" =~ ^https?:// ]]; then
                    echo "  FAIL: HEARTBEAT_URL must start with http:// or https://"
                    errors=$((errors + 1))
                else
                    echo "  OK:   HEARTBEAT_URL=${hb_url%%\?*}..."
                fi
                if [[ "${ENABLE_FLEET_CHECK:-false}" == "true" ]]; then
                    echo "  WARN: Webhook heartbeat mode does not write files — fleet monitoring requires file mode on sender nodes"
                    warnings=$((warnings + 1))
                fi
            fi
        fi
        if [[ "${ENABLE_FLEET_CHECK:-false}" == "true" ]]; then
            local fleet_dir="${FLEET_HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
            if [[ ! -d "$fleet_dir" ]]; then
                echo "  WARN: FLEET_HEARTBEAT_DIR '${fleet_dir}' does not exist"
                warnings=$((warnings + 1))
            elif [[ ! -r "$fleet_dir" ]]; then
                echo "  FAIL: FLEET_HEARTBEAT_DIR '${fleet_dir}' is not readable"
                errors=$((errors + 1))
            else
                echo "  OK:   FLEET_HEARTBEAT_DIR=${fleet_dir} (exists, readable)"
            fi
            local fleet_thresh="${FLEET_STALE_THRESHOLD_MIN:-15}"
            if ! is_valid_number "$fleet_thresh" || [[ "$fleet_thresh" -le 0 ]]; then
                echo "  FAIL: FLEET_STALE_THRESHOLD_MIN '${fleet_thresh}' must be a positive integer"
                errors=$((errors + 1))
            else
                echo "  OK:   FLEET_STALE_THRESHOLD_MIN=${fleet_thresh}"
            fi
            local fleet_mult="${FLEET_CRITICAL_MULTIPLIER:-2}"
            if ! is_valid_number "$fleet_mult" || [[ "$fleet_mult" -le 0 ]]; then
                echo "  FAIL: FLEET_CRITICAL_MULTIPLIER '${fleet_mult}' must be a positive integer"
                errors=$((errors + 1))
            else
                echo "  OK:   FLEET_CRITICAL_MULTIPLIER=${fleet_mult} (critical at $(( fleet_thresh * fleet_mult ))m)"
            fi
            if [[ -n "${FLEET_EXPECTED_SERVERS:-}" ]]; then
                echo "  INFO: Expected servers: ${FLEET_EXPECTED_SERVERS}"
            fi
        fi
    fi

    # Auto-remediation validation
    if [[ -n "${AUTO_RESTART_SERVICES:-}" ]]; then
        echo ""
        echo "[Auto-Remediation]"
        if ! command -v systemctl &>/dev/null; then
            echo "  FAIL: AUTO_RESTART_SERVICES is set but systemctl not found"
            errors=$((errors + 1))
        else
            for svc in ${AUTO_RESTART_SERVICES}; do
                if systemctl cat "$svc" &>/dev/null; then
                    echo "  OK:   ${svc} is a valid systemd service"
                else
                    echo "  WARN: ${svc} is not a known systemd service"
                    warnings=$((warnings + 1))
                fi
            done
        fi
    fi

    # Alerting channels
    echo ""
    echo "[Alert Channels]"
    echo "  Telegram:  ${TELEGRAM_BOT_TOKEN:+configured}"
    [[ -n "${WEBHOOK_URL:-}" ]] && echo "  Webhook:   ${WEBHOOK_URL}" || echo "  Webhook:   not configured"
    if [[ -n "${EMAIL_TO:-}" ]]; then
        if [[ -n "${SMTP_HOST:-}" ]]; then
            echo "  Email:     ${EMAIL_TO} (SMTP: ${SMTP_HOST}:${SMTP_PORT:-587})"
        else
            echo "  Email:     ${EMAIL_TO} (local mailer)"
        fi
    else
        echo "  Email:     not configured"
    fi
    [[ -n "${ESCALATION_WEBHOOK_URL:-}" ]] && echo "  Escalation: ${ESCALATION_WEBHOOK_URL}" || echo "  Escalation: not configured"
    [[ -n "${MAINT_SCHEDULE:-}" ]] && echo "  Maint windows: ${MAINT_SCHEDULE}" || echo "  Maint windows: not configured"
    [[ "${ENABLE_PROMETHEUS_EXPORT:-false}" == "true" ]] && echo "  Prometheus: ${PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}" || echo "  Prometheus: disabled"
    [[ "${ENABLE_JSON_STATUS:-false}" == "true" ]] && echo "  JSON Status: ${JSON_STATUS_FILE:-/tmp/telemon_status.json}" || echo "  JSON Status: disabled"
    if [[ "${ENABLE_HEARTBEAT:-false}" == "true" ]]; then
        if [[ "${HEARTBEAT_MODE:-file}" == "webhook" ]]; then
            echo "  Heartbeat:  webhook → ${HEARTBEAT_URL:-<not set>}"
        else
            echo "  Heartbeat:  file → ${HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
        fi
    else
        echo "  Heartbeat:  disabled"
    fi

    # Email provider validation
    if [[ -n "${EMAIL_TO:-}" ]]; then
        # Check for native SMTP
        if [[ -n "${SMTP_HOST:-}" ]]; then
            if command -v curl &>/dev/null; then
                echo "  OK:   Email configured with native SMTP (${SMTP_HOST}:${SMTP_PORT:-587})"
            else
                echo "  WARN: SMTP_HOST is set but curl not found (required for native SMTP)"
                warnings=$((warnings + 1))
            fi
        else
            # Check for local mailers
            local email_mailer_found=false
            for candidate in msmtp sendmail /usr/sbin/sendmail; do
                if command -v "$candidate" &>/dev/null; then
                    email_mailer_found=true
                    break
                fi
            done
            if [[ "$email_mailer_found" != "true" ]]; then
                echo "  WARN: EMAIL_TO is set but no mailer found (install msmtp/sendmail, or configure SMTP_HOST)"
                warnings=$((warnings + 1))
            fi
        fi
    fi

    # Webhook URL format validation
    if [[ -n "${WEBHOOK_URL:-}" ]] && [[ ! "$WEBHOOK_URL" =~ ^https?:// ]]; then
        echo "  FAIL: WEBHOOK_URL must start with http:// or https://"
        errors=$((errors + 1))
    fi
    if [[ -n "${ESCALATION_WEBHOOK_URL:-}" ]] && [[ ! "$ESCALATION_WEBHOOK_URL" =~ ^https?:// ]]; then
        echo "  FAIL: ESCALATION_WEBHOOK_URL must start with http:// or https://"
        errors=$((errors + 1))
    fi
    if [[ -n "${ESCALATION_WEBHOOK_URL:-}" ]]; then
        local eam="${ESCALATION_AFTER_MIN:-30}"
        if ! is_valid_number "$eam" || [[ "$eam" -lt 1 ]]; then
            echo "  FAIL: ESCALATION_AFTER_MIN '${eam}' must be a positive integer"
            errors=$((errors + 1))
        else
            echo "  OK:   ESCALATION_AFTER_MIN=${eam}m"
        fi
    fi

    # Check python3 dependency for features that require it
    local needs_python3=false
    [[ -n "${WEBHOOK_URL:-}" ]] && needs_python3=true
    [[ -n "${ESCALATION_WEBHOOK_URL:-}" ]] && needs_python3=true
    [[ "${ENABLE_JSON_STATUS:-false}" == "true" ]] && needs_python3=true
    [[ "${ENABLE_PM2_PROCESSES:-false}" == "true" ]] && needs_python3=true
    if [[ "$needs_python3" == "true" ]]; then
        if ! command -v python3 &>/dev/null; then
            echo "  FAIL: python3 is required for webhook/escalation/JSON/PM2 but not found"
            errors=$((errors + 1))
        else
            echo "  OK:   python3 found (required for webhook/escalation/JSON/PM2)"
        fi
    fi

    # MAINT_SCHEDULE format validation
    if [[ -n "${MAINT_SCHEDULE:-}" ]]; then
        local IFS=';'
        local maint_valid=true
        for ms_entry in ${MAINT_SCHEDULE}; do
            ms_entry=$(echo "$ms_entry" | xargs)  # trim
            [[ -z "$ms_entry" ]] && continue
            if [[ ! "$ms_entry" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\ [0-9]{1,2}:[0-9]{2}-[0-9]{1,2}:[0-9]{2}$ ]]; then
                echo "  WARN: Invalid MAINT_SCHEDULE entry: '${ms_entry}' (expected: 'Day HH:MM-HH:MM' or 'Day H:MM-H:MM')"
                warnings=$((warnings + 1))
                maint_valid=false
            else
                # Validate hour/minute ranges
                local ms_time_range="${ms_entry##* }"
                local ms_start="${ms_time_range%%-*}"
                local ms_end="${ms_time_range##*-}"
                local ms_sh="${ms_start%%:*}" ms_sm="${ms_start##*:}"
                local ms_eh="${ms_end%%:*}" ms_em="${ms_end##*:}"
                if (( 10#$ms_sh > 23 || 10#$ms_sm > 59 || 10#$ms_eh > 23 || 10#$ms_em > 59 )); then
                    echo "  WARN: MAINT_SCHEDULE entry '${ms_entry}': hours must be 0-23, minutes 0-59"
                    warnings=$((warnings + 1))
                fi
            fi
        done
        unset IFS
    fi
    
    # Export path validation
    if [[ "${ENABLE_PROMETHEUS_EXPORT:-false}" == "true" ]]; then
        local prom_dir="${PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
        if [[ ! -d "$prom_dir" ]]; then
            echo "  WARN: PROMETHEUS_TEXTFILE_DIR '${prom_dir}' does not exist"
            warnings=$((warnings + 1))
        elif [[ ! -w "$prom_dir" ]]; then
            echo "  FAIL: PROMETHEUS_TEXTFILE_DIR '${prom_dir}' is not writable"
            errors=$((errors + 1))
        fi
    fi
    if [[ "${ENABLE_JSON_STATUS:-false}" == "true" ]]; then
        local json_export_file="${JSON_STATUS_FILE:-/tmp/telemon_status.json}"
        local json_dir
        json_dir=$(dirname "$json_export_file")
        if [[ ! -d "$json_dir" ]]; then
            echo "  WARN: Directory for JSON_STATUS_FILE '${json_dir}' does not exist"
            warnings=$((warnings + 1))
        elif [[ ! -w "$json_dir" ]]; then
            echo "  FAIL: Directory for JSON_STATUS_FILE '${json_dir}' is not writable"
            errors=$((errors + 1))
        fi
    fi
    
    # Threshold validation
    echo ""
    echo "[Thresholds]"
    validate_thresholds 2>&1 | grep -v "Monitor run" || echo "  All thresholds valid."
    
    # Additional parameter validation
    echo ""
    echo "[Parameters]"
    
    # STATE_FILE writability
    local state_dir
    state_dir=$(dirname "${STATE_FILE:-/tmp/telemon_sys_alert_state}")
    if [[ ! -d "$state_dir" ]]; then
        echo "  FAIL: STATE_FILE directory '${state_dir}' does not exist"
        errors=$((errors + 1))
    elif [[ ! -w "$state_dir" ]]; then
        echo "  FAIL: STATE_FILE directory '${state_dir}' is not writable"
        errors=$((errors + 1))
    else
        echo "  OK:   STATE_FILE directory writable (${state_dir})"
    fi
    
    # TOP_PROCESS_COUNT
    local tpc="${TOP_PROCESS_COUNT:-5}"
    if ! is_valid_number "$tpc" || [[ "$tpc" -lt 1 ]]; then
        echo "  WARN: TOP_PROCESS_COUNT '${tpc}' should be a positive integer"
        warnings=$((warnings + 1))
    else
        echo "  OK:   TOP_PROCESS_COUNT=${tpc}"
    fi

    # ALERT_COOLDOWN_SEC
    local acs="${ALERT_COOLDOWN_SEC:-900}"
    if ! is_valid_number "$acs"; then
        echo "  FAIL: ALERT_COOLDOWN_SEC '${acs}' must be a non-negative integer"
        errors=$((errors + 1))
    else
        echo "  OK:   ALERT_COOLDOWN_SEC=${acs}s"
    fi

    # CHECK_TIMEOUT
    local ct="${CHECK_TIMEOUT:-30}"
    if ! is_valid_number "$ct" || [[ "$ct" -lt 1 ]]; then
        echo "  WARN: CHECK_TIMEOUT '${ct}' should be a positive integer"
        warnings=$((warnings + 1))
    else
        echo "  OK:   CHECK_TIMEOUT=${ct}s"
    fi

    # ODBC_CHECK_TIMEOUT (only validate if ODBC is enabled)
    if [[ "${ENABLE_ODBC_CHECKS:-false}" == "true" ]]; then
        local oct="${ODBC_CHECK_TIMEOUT:-${CHECK_TIMEOUT:-30}}"
        if ! is_valid_number "$oct" || [[ "$oct" -lt 1 ]]; then
            echo "  WARN: ODBC_CHECK_TIMEOUT '${oct}' should be a positive integer"
            warnings=$((warnings + 1))
        else
            echo "  OK:   ODBC_CHECK_TIMEOUT=${oct}s"
        fi
    fi

    # LOG_MAX_SIZE_MB
    local lms="${LOG_MAX_SIZE_MB:-10}"
    if ! is_valid_number "$lms" || [[ "$lms" -lt 1 ]]; then
        echo "  WARN: LOG_MAX_SIZE_MB '${lms}' should be a positive integer"
        warnings=$((warnings + 1))
    else
        echo "  OK:   LOG_MAX_SIZE_MB=${lms}"
    fi

    # LOG_MAX_BACKUPS
    local lmb="${LOG_MAX_BACKUPS:-5}"
    if ! is_valid_number "$lmb" || [[ "$lmb" -lt 0 ]]; then
        echo "  WARN: LOG_MAX_BACKUPS '${lmb}' should be a non-negative integer"
        warnings=$((warnings + 1))
    else
        echo "  OK:   LOG_MAX_BACKUPS=${lmb}"
    fi

    # LOG_LEVEL
    local ll="${LOG_LEVEL:-INFO}"
    if [[ ! "$ll" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]]; then
        echo "  WARN: LOG_LEVEL '${ll}' is invalid (must be DEBUG, INFO, WARN, or ERROR)"
        warnings=$((warnings + 1))
    else
        echo "  OK:   LOG_LEVEL=${ll}"
    fi

    # Predictive alerts parameter validation
    if [[ "${ENABLE_PREDICTIVE_ALERTS:-false}" == "true" ]]; then
        local phh="${PREDICT_HORIZON_HOURS:-24}"
        if ! is_valid_number "$phh" || [[ "$phh" -lt 1 ]]; then
            echo "  FAIL: PREDICT_HORIZON_HOURS '${phh}' must be a positive integer"
            errors=$((errors + 1))
        else
            echo "  OK:   PREDICT_HORIZON_HOURS=${phh}"
        fi

        local pmd="${PREDICT_MIN_DATAPOINTS:-12}"
        if ! is_valid_number "$pmd" || [[ "$pmd" -lt 3 ]]; then
            echo "  FAIL: PREDICT_MIN_DATAPOINTS '${pmd}' must be a positive integer >= 3"
            errors=$((errors + 1))
        else
            echo "  OK:   PREDICT_MIN_DATAPOINTS=${pmd}"
        fi

        local pdp="${PREDICT_DATAPOINTS:-48}"
        if ! is_valid_number "$pdp" || [[ "$pdp" -lt 3 ]]; then
            echo "  FAIL: PREDICT_DATAPOINTS '${pdp}' must be a positive integer >= 3"
            errors=$((errors + 1))
        elif is_valid_number "$pmd" && [[ "$pdp" -lt "$pmd" ]]; then
            echo "  FAIL: PREDICT_DATAPOINTS (${pdp}) must be >= PREDICT_MIN_DATAPOINTS (${pmd})"
            errors=$((errors + 1))
        else
            echo "  OK:   PREDICT_DATAPOINTS=${pdp}"
        fi
    fi

    # PING_TARGET validation (if internet check enabled)
    if [[ "${ENABLE_INTERNET_CHECK:-true}" == "true" ]]; then
        local pt="${PING_TARGET:-8.8.8.8}"
        if [[ -z "$pt" ]]; then
            echo "  WARN: PING_TARGET is empty (will default to 8.8.8.8)"
            warnings=$((warnings + 1))
        elif [[ ! "$pt" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
            echo "  FAIL: PING_TARGET '${pt}' contains invalid characters"
            errors=$((errors + 1))
        else
            echo "  OK:   PING_TARGET=${pt}"
        fi
    fi

    # DNS_CHECK_DOMAIN validation (if DNS check enabled)
    if [[ "${ENABLE_DNS_CHECK:-false}" == "true" ]]; then
        local dcd="${DNS_CHECK_DOMAIN:-example.com}"
        if [[ -z "$dcd" ]]; then
            echo "  WARN: DNS_CHECK_DOMAIN is empty"
            warnings=$((warnings + 1))
        elif [[ ! "$dcd" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            echo "  FAIL: DNS_CHECK_DOMAIN '${dcd}' contains invalid characters"
            errors=$((errors + 1))
        else
            echo "  OK:   DNS_CHECK_DOMAIN=${dcd}"
        fi
    fi

    # NETWORK_INTERFACE validation (if network check enabled)
    if [[ "${ENABLE_NETWORK_CHECK:-false}" == "true" ]] && [[ -n "${NETWORK_INTERFACE:-}" ]]; then
        if [[ ! "${NETWORK_INTERFACE}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "  FAIL: NETWORK_INTERFACE '${NETWORK_INTERFACE}' contains invalid characters"
            errors=$((errors + 1))
        elif [[ -f /proc/net/dev ]] && ! grep -q "^ *${NETWORK_INTERFACE}:" /proc/net/dev 2>/dev/null; then
            echo "  WARN: NETWORK_INTERFACE '${NETWORK_INTERFACE}' not found in /proc/net/dev"
            warnings=$((warnings + 1))
        else
            echo "  OK:   NETWORK_INTERFACE=${NETWORK_INTERFACE}"
        fi
    fi
    
    # SITE_* parameters (only if site monitor is enabled)
    if [[ "${ENABLE_SITE_MONITOR:-false}" == "true" ]]; then
        local ses="${SITE_EXPECTED_STATUS:-200}"
        if ! is_valid_number "$ses" || [[ "$ses" -lt 100 || "$ses" -gt 599 ]]; then
            echo "  WARN: SITE_EXPECTED_STATUS '${ses}' should be a valid HTTP status (100-599)"
            warnings=$((warnings + 1))
        fi
        local smr="${SITE_MAX_RESPONSE_MS:-10000}"
        if ! is_valid_number "$smr" || [[ "$smr" -lt 1 ]]; then
            echo "  WARN: SITE_MAX_RESPONSE_MS '${smr}' should be a positive integer"
            warnings=$((warnings + 1))
        fi
        local sswd="${SITE_SSL_WARN_DAYS:-7}"
        if ! is_valid_number "$sswd" || [[ "$sswd" -lt 1 ]]; then
            echo "  WARN: SITE_SSL_WARN_DAYS '${sswd}' should be a positive integer"
            warnings=$((warnings + 1))
        fi
    fi
    
    # LOG_WATCH_LINES (only if log check is enabled)
    if [[ "${ENABLE_LOG_CHECK:-false}" == "true" ]]; then
        local lwl="${LOG_WATCH_LINES:-100}"
        if ! is_valid_number "$lwl" || [[ "$lwl" -lt 1 ]]; then
            echo "  WARN: LOG_WATCH_LINES '${lwl}' should be a positive integer"
            warnings=$((warnings + 1))
        fi
    fi
    
    # Summary
    echo ""
    echo "================================="
    echo "Checks enabled: $enabled"
    echo "Errors: $errors | Warnings: $warnings"
    if [[ $errors -gt 0 ]]; then
        echo "STATUS: FAIL — fix errors above before running"
        return 1
    elif [[ $warnings -gt 0 ]]; then
        echo "STATUS: OK (with warnings)"
        return 0
    else
        echo "STATUS: OK"
        return 0
    fi
}

run_test() {
    echo "Telemon test mode"
    echo "================="
    echo ""
    
    # Validate first
    if ! run_validate; then
        echo ""
        echo "Fix validation errors before testing."
        return 1
    fi
    
    echo ""
    echo "[Telegram Connectivity Test]"
    echo "  Sending test message..."
    
    local test_msg="<b>&#128421; [${SERVER_LABEL}] Telemon Test</b>%0A"
    test_msg+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"
    test_msg+="&#9989; Configuration is valid. Telegram delivery works.%0A"
    test_msg+="This is a test message from <code>telemon.sh --test</code>."
    
    if send_telegram "$test_msg"; then
        echo "  OK: Test message sent — check your Telegram!"
        return 0
    else
        echo "  FAIL: Could not send message. Check bot token and chat ID."
        return 1
    fi
}

# ===========================================================================
# Digest Mode: --digest
# Sends a health summary even when everything is OK
# Designed for separate cron entry (e.g., daily at 9am)
# ===========================================================================
run_digest() {
    log "INFO" "--- Digest run started ---"
    validate_thresholds
    load_state

    # Digest reports all current states — bypass confirmation logic
    local saved_confirm_count="${CONFIRMATION_COUNT:-3}"
    CONFIRMATION_COUNT=1

    # Run all enabled checks (same as normal run)
    run_all_checks

    # Restore confirmation count
    CONFIRMATION_COUNT="$saved_confirm_count"

    # Build counts
    local crit_count=0 warn_count=0 ok_count=0
    for key in "${!CURR_STATE[@]}"; do
        case "${CURR_STATE[$key]}" in
            CRITICAL) crit_count=$(( crit_count + 1 )) ;;
            WARNING)  warn_count=$(( warn_count + 1 )) ;;
            OK)       ok_count=$(( ok_count + 1 )) ;;
        esac
    done

    # Build digest message — always sent
    local msg="<b>&#128202; [${SERVER_LABEL}] Health Digest</b>%0A"
    msg+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"
    msg+="<b>Summary:</b> &#128308; ${crit_count} critical | &#128992; ${warn_count} warning | &#128994; ${ok_count} healthy%0A"
    msg+="-----------------------------%0A%0A"

    # Guard: if no checks ran, note this in the digest
    if [[ ${#CURR_STATE[@]} -eq 0 ]]; then
        msg+="<i>No checks enabled or all checks skipped.</i>%0A%0A"
    fi

    # List all checks grouped by state
    for state_label in CRITICAL WARNING OK; do
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if [[ "${CURR_STATE[$key]}" == "$state_label" ]]; then
                local emoji=""
                case "$state_label" in
                    CRITICAL) emoji="&#128308;" ;;
                    WARNING)  emoji="&#128992;" ;;
                    OK)       emoji="&#128994;" ;;
                esac
                msg+="${emoji} <b>${key}</b>: ${STATE_DETAIL[$key]:-${CURR_STATE[$key]}}%0A"
            fi
        done < <(printf '%s\n' "${!CURR_STATE[@]}" | sort)
    done

    # Fleet summary (if fleet monitoring is enabled)
    if [[ "${ENABLE_FLEET_CHECK:-false}" == "true" ]]; then
        local fleet_dir="${FLEET_HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
        if [[ -d "$fleet_dir" ]]; then
            msg+="%0A<b>Fleet Status:</b>%0A"
            local fleet_now
            fleet_now=$(date +%s)
            local fleet_threshold_sec=$(( ${FLEET_STALE_THRESHOLD_MIN:-15} * 60 ))
            local fleet_crit_sec=$(( fleet_threshold_sec * ${FLEET_CRITICAL_MULTIPLIER:-2} ))
            local fleet_self
            fleet_self=$(sanitize_state_key "${SERVER_LABEL}")
            local fleet_has_entries=false
            for fleet_file in "$fleet_dir"/*; do
                [[ -f "$fleet_file" ]] || continue
                fleet_has_entries=true
                local fleet_fname
                fleet_fname=$(basename "$fleet_file")
                local fl_label fl_ts fl_status fl_count _
                IFS=$'\t' read -r fl_label fl_ts fl_status fl_count _ < "$fleet_file" 2>/dev/null || continue
                is_valid_number "$fl_ts" || continue
                local fl_age=$(( fleet_now - fl_ts ))
                local fl_age_min=$(( fl_age / 60 ))
                local fl_emoji="&#128994;"
                if (( fl_age > fleet_crit_sec )); then
                    fl_emoji="&#128308;"
                elif (( fl_age > fleet_threshold_sec )); then
                    fl_emoji="&#128992;"
                fi
                local fl_safe_label
                fl_safe_label=$(html_escape "${fl_label:-$fleet_fname}")
                # Validate fields from untrusted heartbeat files
                local fl_safe_status fl_safe_count
                if [[ "${fl_status:-}" =~ ^(OK|WARNING|CRITICAL)$ ]]; then
                    fl_safe_status="$fl_status"
                else
                    fl_safe_status="?"
                fi
                if is_valid_number "${fl_count:-}"; then
                    fl_safe_count="$fl_count"
                else
                    fl_safe_count="?"
                fi
                if [[ "$fleet_fname" == "$fleet_self" ]]; then
                    msg+="${fl_emoji} <code>${fl_safe_label}</code> (self): ${fl_safe_status}, ${fl_safe_count} checks%0A"
                else
                    msg+="${fl_emoji} <code>${fl_safe_label}</code>: last seen ${fl_age_min}m ago (${fl_safe_status}, ${fl_safe_count} checks)%0A"
                fi
            done
            if [[ "$fleet_has_entries" != "true" ]]; then
                msg+="<i>No heartbeat files found</i>%0A"
            fi
            # Show expected-but-missing servers
            if [[ -n "${FLEET_EXPECTED_SERVERS:-}" ]]; then
                for fleet_exp in ${FLEET_EXPECTED_SERVERS}; do
                    local fleet_exp_san
                    fleet_exp_san=$(sanitize_state_key "$fleet_exp")
                    local fleet_exp_found=false
                    for fleet_chk in "$fleet_dir"/*; do
                        [[ -f "$fleet_chk" ]] || continue
                        [[ "$(basename "$fleet_chk")" == "$fleet_exp_san" ]] && fleet_exp_found=true && break
                    done
                    if [[ "$fleet_exp_found" != "true" ]]; then
                        local fl_safe_exp
                        fl_safe_exp=$(html_escape "$fleet_exp")
                        msg+="&#128308; <code>${fl_safe_exp}</code>: <b>NEVER checked in</b>%0A"
                    fi
                done
            fi
        fi
    fi

    # Uptime info
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1, $2}')
    msg+="%0A<i>Uptime: ${uptime_str}</i>"

    dispatch_alert "$msg"

    # Update heartbeat and exports (digest runs may be the only cron entry)
    send_heartbeat
    export_prometheus
    export_json_status

    log "INFO" "Digest sent (${crit_count}C/${warn_count}W/${ok_count}OK)"
    log "INFO" "--- Digest run finished ---"
    return 0
}

# ===========================================================================
# Generic Webhook Dispatch
# Posts JSON payload to WEBHOOK_URL if configured
# ===========================================================================
send_webhook() {
    local message="$1"
    local webhook_url="${WEBHOOK_URL:-}"
    [[ -z "$webhook_url" ]] && return 0

    # Strip HTML tags for plain-text webhook payload
    local plain_message
    plain_message=$(printf '%s\n' "$message" | sed 's/%0A/\n/g; s/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')

    local hostname
    hostname=$(hostname)

    # Build JSON payload (requires python3 for safe JSON encoding)
    if ! command -v python3 &>/dev/null; then
        log "WARN" "Webhook dispatch: python3 not found — skipping"
        return 1
    fi

    local json_payload
    json_payload=$(TELEMON_HOSTNAME="$hostname" TELEMON_SERVER_LABEL="${SERVER_LABEL}" TELEMON_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        run_with_timeout "$CHECK_TIMEOUT" python3 -c "
import json, sys, os
data = {
    'hostname': os.environ.get('TELEMON_HOSTNAME', ''),
    'server_label': os.environ.get('TELEMON_SERVER_LABEL', ''),
    'timestamp': os.environ.get('TELEMON_TIMESTAMP', ''),
    'message': sys.stdin.read().strip()
}
print(json.dumps(data))
" <<< "$plain_message" 2>/dev/null) || return 1

    local http_code
    http_code=$(curl -s --max-time 30 -X POST \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        -w '%{http_code}' \
        -o /dev/null \
        "$webhook_url" 2>/dev/null) || http_code="000"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log "WARN" "Webhook delivery failed (HTTP ${http_code})"
        return 1
    fi
    log "DEBUG" "Webhook delivered to ${webhook_url%%\?*}"
    return 0
}

# ===========================================================================
# Email (SMTP) Dispatch
# Supports three methods (in order of preference):
#   1. Native SMTP via curl (direct to SMTP server with auth)
#   2. msmtp (lightweight SMTP relay)
#   3. sendmail (local MTA)
# ===========================================================================
send_email() {
    local message="$1"
    local email_to="${EMAIL_TO:-}"
    [[ -z "$email_to" ]] && return 0

    # SECURITY: Strict email validation (RFC 5322 simplified)
    if ! is_valid_email "$email_to"; then
        log "WARN" "send_email: EMAIL_TO '${email_to}' failed validation — skipping"
        return 1
    fi

    local hostname
    hostname=$(hostname)
    local email_from="${EMAIL_FROM:-telemon@${hostname}}"
    
    # SECURITY: Validate EMAIL_FROM with same strict validation
    if ! is_valid_email "$email_from"; then
        log "WARN" "send_email: EMAIL_FROM '${email_from}' failed validation — using default"
        email_from="telemon@${hostname}"
    fi
    
    # Sanitize email headers
    email_from=$(printf '%s' "$email_from" | tr -d '\n\r\t\0')
    email_to=$(printf '%s' "$email_to" | tr -d '\n\r\t\0')
    local subject
    subject=$(printf '[Telemon] %s — alert' "$hostname" | tr -d '\n\r\t\0')
    
    # Strip HTML tags for plain-text email
    local plain_message
    plain_message=$(printf '%s\n' "$message" | sed 's/%0A/\n/g; s/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')

    # Method 1: Native SMTP via curl (if SMTP_HOST is configured)
    local smtp_host="${SMTP_HOST:-}"
    if [[ -n "$smtp_host" ]]; then
        send_email_native_smtp "$email_from" "$email_to" "$subject" "$plain_message"
        return $?
    fi
    
    # Method 2 & 3: Local mailers (msmtp, sendmail)
    send_email_local_mailer "$email_from" "$email_to" "$subject" "$plain_message"
    return $?
}

# ---------------------------------------------------------------------------
# Native SMTP via curl (supports external SMTP servers with auth)
# ---------------------------------------------------------------------------
send_email_native_smtp() {
    local email_from="$1"
    local email_to="$2"
    local subject="$3"
    local plain_message="$4"
    
    local smtp_host="${SMTP_HOST:-}"
    local smtp_port="${SMTP_PORT:-587}"
    local smtp_user="${SMTP_USER:-}"
    local smtp_pass="${SMTP_PASS:-}"
    local smtp_tls="${SMTP_TLS:-yes}"
    
    if ! command -v curl &>/dev/null; then
        log "WARN" "Native SMTP requires curl — not found"
        return 1
    fi
    
    # Build curl SMTP URL
    local smtp_url
    if [[ "$smtp_port" == "465" ]]; then
        # SMTPS (SSL/TLS wrapper)
        smtp_url="smtps://${smtp_host}:${smtp_port}"
    else
        # SMTP with STARTTLS or plain
        smtp_url="smtp://${smtp_host}:${smtp_port}"
    fi
    
    # Build email content
    local email_content
    email_content=$(cat << EOF
From: ${email_from}
To: ${email_to}
Subject: ${subject}
Content-Type: text/plain; charset=utf-8

${plain_message}
EOF
)
    
    # Build curl command arguments
    local curl_args=()
    curl_args+=(--url "$smtp_url")
    curl_args+=(--max-time 30)
    curl_args+=(--silent --show-error)
    
    # Add authentication if configured
    if [[ -n "$smtp_user" && -n "$smtp_pass" ]]; then
        # SECURITY: URL-encode password to handle special characters (@, #, %, &, etc)
        # Order matters: encode % first, then other characters
        # This prevents curl from misinterpreting characters like @ in passwords
        local encoded_pass
        encoded_pass=$(printf '%s' "$smtp_pass" | sed 's/%/%25/g; s/@/%40/g; s/#/%23/g; s/&/%26/g; s/=/%3D/g; s/?/%3F/g')
        curl_args+=(--user "${smtp_user}:${encoded_pass}")
    fi
    
    # Add TLS/SSL options
    if [[ "$smtp_tls" == "yes" && "$smtp_port" != "465" ]]; then
        # Use STARTTLS on port 587
        curl_args+=(--ssl-reqd)
    elif [[ "$smtp_port" == "465" ]]; then
        # SMTPS requires SSL
        curl_args+=(--ssl-reqd)
    fi
    
    # SECURITY: Warn if sending credentials without encryption
    if [[ -n "$smtp_user" && "$smtp_tls" != "yes" && "$smtp_port" != "465" ]]; then
        log "WARN" "SMTP authentication without TLS - credentials will be sent in plaintext!"
    fi
    
    # Send the email
    local curl_output
    curl_output=$(curl "${curl_args[@]}" --mail-from "$email_from" --mail-rcpt "$email_to" <<< "$email_content" 2>&1)
    local curl_exit=$?
    
    if [[ $curl_exit -eq 0 ]]; then
        log "DEBUG" "Email alert sent to ${email_to} via SMTP ${smtp_host}:${smtp_port}"
        return 0
    else
        # Log the actual error for debugging (but sanitize credentials)
        local sanitized_error
        sanitized_error=$(echo "$curl_output" | grep -E "(^< [0-9]|^curl:|Failed|Could not|Error|timeout|refused|resolve)" | tail -3 | sed "s|$smtp_pass|***|g")
        log "WARN" "Email delivery failed via SMTP ${smtp_host}:${smtp_port}: ${sanitized_error:-"Unknown error (exit $curl_exit)"}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Local mailer (msmtp, sendmail)
# ---------------------------------------------------------------------------
send_email_local_mailer() {
    local email_from="$1"
    local email_to="$2"
    local subject="$3"
    local plain_message="$4"
    
    # Find mail transport
    local mailer=""
    for candidate in msmtp sendmail /usr/sbin/sendmail; do
        if command -v "$candidate" &>/dev/null; then
            mailer="$candidate"
            break
        fi
    done
    
    if [[ -z "$mailer" ]]; then
        log "WARN" "EMAIL_TO is set but no mailer found (install msmtp, sendmail, or configure SMTP_HOST for native SMTP)"
        return 1
    fi

    {
        echo "From: ${email_from}"
        echo "To: ${email_to}"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=utf-8"
        echo ""
        echo "$plain_message"
    } | "$mailer" -t 2>/dev/null

    if [[ $? -eq 0 ]]; then
        log "DEBUG" "Email alert sent to ${email_to} via ${mailer}"
        return 0
    else
        log "WARN" "Email delivery failed via ${mailer}"
        return 1
    fi
}

# ===========================================================================
# Unified alert dispatcher — sends to all configured channels
# ===========================================================================
dispatch_alert() {
    local message="$1"
    export TELEMON_HOSTNAME
    TELEMON_HOSTNAME="$(hostname)"

    send_telegram "$message" || true
    send_webhook "$message" || true
    send_email "$message" || true
}

# ===========================================================================
# Telegram Dispatch
# ===========================================================================
send_telegram() {
    local message="$1"
    # Convert %0A back to real newlines for --data-urlencode
    message="${message//%0A/$'\n'}"
    local response
    # Use --config with process substitution to keep bot token out of
    # process args (hidden from ps aux / /proc/*/cmdline)
    # Fallback to temp file if /dev/fd is unavailable (restricted containers/chroots)
    local config_arg
    if [[ -e /dev/fd/0 ]]; then
        # Process substitution: preferred (no temp file, auto-cleaned)
        response=$(curl -s --max-time 30 -X POST \
            --config <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN") \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "parse_mode=HTML" \
            --data-urlencode "text=${message}" 2>&1)
    else
        # Fallback: secure temp file (umask 077 inherited, cleaned on exit)
        local tmp_config
        tmp_config=$(mktemp) || { log "ERROR" "send_telegram: failed to create temp config"; return 1; }
        # Ensure cleanup on all exit paths
        trap 'rm -f "$tmp_config" 2>/dev/null' RETURN
        printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" > "$tmp_config"
        chmod 600 "$tmp_config" 2>/dev/null || true
        response=$(curl -s --max-time 30 -X POST \
            --config "$tmp_config" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "parse_mode=HTML" \
            --data-urlencode "text=${message}" 2>&1)
        rm -f "$tmp_config" 2>/dev/null
    fi

    local ok
    ok=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")

    if [[ "$ok" != "True" ]]; then
        # S2: Sanitize error output — never log raw API response (may contain token)
        local error_desc
        error_desc=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('description', 'Unknown error'))
except Exception:
    print('Non-JSON response or connection error')
" 2>/dev/null || echo "Unknown error")
        log "ERROR" "Telegram send failed: ${error_desc}"
        return 1
    fi
    return 0
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    # Disable exit-on-error for the main monitoring logic
    # (we handle errors explicitly with proper logging)
    set +e
    
    # Handle CLI flags
    case "${1:-}" in
        --test|-t)
            run_test
            exit $?
            ;;
        --validate|-v)
            run_validate
            exit $?
            ;;
        --digest|-d)
            run_digest
            exit $?
            ;;
        --generate-status-page|-g)
            # Generate static HTML status page from current state
            load_state
            generate_status_page "${2:-}"
            exit $?
            ;;
        --help|-h)
            echo "Usage: telemon.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --test, -t                Validate config and send a test Telegram message"
            echo "  --validate, -v          Validate configuration without sending anything"
            echo "  --digest, -d              Send a health digest summary (even if everything is OK)"
            echo "  --generate-status-page,-g [FILE]  Generate static HTML status page"
            echo "  --help, -h                Show this help"
            echo ""
            echo "With no options, runs a full monitoring check cycle."
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run 'telemon.sh --help' for usage information." >&2
            exit 1
            ;;
    esac
    
    log "INFO" "--- Monitor run started ---"
    
    # Check scheduled maintenance windows
    if is_in_maintenance_window; then
        log "INFO" "Scheduled maintenance window active — skipping"
        exit 0
    fi
    
    # Validate configuration thresholds
    validate_thresholds

    # First-run detection: use fingerprint file to prevent duplicate bootstrap messages
    # State file may be moved/deleted (e.g., migration, cleanup), but fingerprint persists
    local is_first_run=false
    if [[ ! -f "$FIRST_RUN_FINGERPRINT" ]]; then
        # No fingerprint found — this is truly a first run
        is_first_run=true
        # Create fingerprint file to mark first run as done
        echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$FIRST_RUN_FINGERPRINT" 2>/dev/null || true
        chmod 600 "$FIRST_RUN_FINGERPRINT" 2>/dev/null || true
        log "INFO" "First run detected (fingerprint created) - using immediate alerts (confirmation=1)"
    elif [[ ! -f "$STATE_FILE" ]]; then
        # Has fingerprint but no state file — state was reset but not first install
        # Log at DEBUG level only to avoid confusion
        log "DEBUG" "State file missing but fingerprint exists — treating as state reset, not first run"
    fi

    load_state

    # On first run, temporarily set confirmation count to 1 for immediate feedback
    local saved_confirm_count="${CONFIRMATION_COUNT:-3}"
    if [[ "$is_first_run" == "true" ]]; then
        CONFIRMATION_COUNT=1
    fi

    # Reset per-run globals to prevent stale data from previous cycles
    ALERTS=""
    TOP_PROCESSES_INFO=""
    CURR_STATE=()
    STATE_DETAIL=()

    # Run all checks (respecting ENABLE_ flags)
    run_all_checks

    # Auto-remediation (after checks, before alerts)
    auto_remediate

    # Restore confirmation count for state saving
    CONFIRMATION_COUNT="$saved_confirm_count"

    # On first run, set counts to saved confirmation count so next run
    # requires full confirmation before re-alerting
    if [[ "$is_first_run" == "true" ]]; then
        for key in "${!CURR_STATE[@]}"; do
            PREV_COUNT["$key"]="$saved_confirm_count"
        done
    fi

    # Persist new state
    save_state

    # Send heartbeat (dead man's switch)
    send_heartbeat

    # Build summary counts
    local crit_count=0 warn_count=0 ok_count=0
    for key in "${!CURR_STATE[@]}"; do
        case "${CURR_STATE[$key]}" in
            CRITICAL) crit_count=$(( crit_count + 1 )) ;;
            WARNING)  warn_count=$(( warn_count + 1 )) ;;
            OK)       ok_count=$(( ok_count + 1 )) ;;
        esac
    done

    # On first run, send a single bootstrap message instead of per-item alerts
    if [[ "$is_first_run" == "true" ]]; then
        local header="<b>&#128421; [${SERVER_LABEL}] Telemon Initialized</b>%0A"
        header+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"
        header+="<b>Summary:</b> &#128308; ${crit_count} critical | &#128992; ${warn_count} warning | &#128994; ${ok_count} healthy%0A"
        header+="Confirmation count: ${saved_confirm_count} (alerts require ${saved_confirm_count} consecutive matches)%0A"
        header+="-----------------------------%0A%0A"

        # On first run, only report non-OK items
        local first_alerts=""
        for key in "${!CURR_STATE[@]}"; do
            if [[ "${CURR_STATE[$key]}" != "OK" ]]; then
                local emoji=""
                case "${CURR_STATE[$key]}" in
                    CRITICAL) emoji="&#128308;" ;;
                    WARNING)  emoji="&#128992;" ;;
                esac
                first_alerts+="${emoji} <b>${key}</b>: ${STATE_DETAIL[$key]:-${CURR_STATE[$key]}}%0A"
            fi
        done

        if [[ -n "$first_alerts" ]]; then
            header+="${first_alerts}"
        else
            header+="&#9989; All ${ok_count} checks passed. Monitoring active.%0A"
        fi

        dispatch_with_retry "$header"
        log "INFO" "First run: bootstrap message sent (${crit_count}C/${warn_count}W/${ok_count}OK)"

    elif [[ -n "$ALERTS" ]]; then
        # Normal run -- dispatch accumulated state-change alerts
        local header="<b>&#128421; [${SERVER_LABEL}] System Vital Alert</b>%0A"
        header+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"

        local summary="<b>Summary:</b> &#128308; ${crit_count} critical | &#128992; ${warn_count} warning | &#128994; ${ok_count} healthy%0A"
        summary+="-----------------------------%0A%0A"

        local full_message="${header}${summary}${ALERTS}"
        
        # Append top processes info if available
        if [[ -n "$TOP_PROCESSES_INFO" ]]; then
            # Convert literal newlines to %0A encoding for Telegram message format
            local encoded_top_procs="${TOP_PROCESSES_INFO//$'\n'/%0A}"
            full_message+="%0A<b>Process Details:</b>%0A${encoded_top_procs}"
        fi

        dispatch_with_retry "$full_message"
        log "INFO" "Alert dispatched (${crit_count}C/${warn_count}W/${ok_count}OK)"
    else
        log "INFO" "No confirmed state changes detected -- no alerts sent"
    fi

    # Post-dispatch: exports and escalation
    export_prometheus
    export_json_status
    check_escalation

    log "INFO" "--- Monitor run finished ---"
}

main "$@"
