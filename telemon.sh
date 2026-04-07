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

# Server identity — used in alert headers, heartbeat files, fleet monitoring
SERVER_LABEL="${SERVER_LABEL:-$(hostname)}"

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
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Lock file to prevent overlapping runs
# Uses flock (from util-linux) if available, falls back to PID file
# ---------------------------------------------------------------------------
LOCK_FILE="${STATE_FILE:-/tmp/telemon_sys_alert_state}.lock"

acquire_lock() {
    # Try flock first (most reliable)
    if command -v flock &>/dev/null; then
        # Open file descriptor for lock file
        exec 200>"$LOCK_FILE"
        if ! flock -n 200 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Another instance is running - exiting" >&2
            exit 0
        fi
        return 0
    fi
    
    # Fallback: atomic mkdir-based lock (avoids TOCTOU race with PID file)
    local lock_dir="${LOCK_FILE}.d"
    if mkdir "$lock_dir" 2>/dev/null; then
        # We acquired the lock — write our PID for staleness detection
        echo "$$" > "${lock_dir}/pid"
        return 0
    fi
    # Lock dir exists — check if holder is still alive
    local old_pid
    old_pid=$(cat "${lock_dir}/pid" 2>/dev/null) || old_pid=""
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Another instance (PID $old_pid) is running - exiting" >&2
        exit 0
    fi
    # Stale lock — remove and re-acquire atomically
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
        echo "$$" > "${lock_dir}/pid"
        return 0
    fi
    # Lost the race to another instance that just started
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Another instance acquired lock - exiting" >&2
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
# Logging helper
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
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
            log "INFO" "Log rotated (size exceeded ${max_size_mb}MB)"
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
# Helper to check if value is a valid positive integer (intentionally rejects floats;
# all Telemon thresholds are integers by design)
is_valid_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

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
    [[ "${ENABLE_GPU_CHECK:-false}" == "true" ]] && { check_threshold_pair "GPU_TEMP" "${GPU_TEMP_THRESHOLD_WARN:-80}" "${GPU_TEMP_THRESHOLD_CRIT:-95}" || has_errors=true; }
    [[ "${ENABLE_NETWORK_CHECK:-false}" == "true" ]] && { check_threshold_pair "NETWORK" "${NETWORK_THRESHOLD_WARN:-800}" "${NETWORK_THRESHOLD_CRIT:-950}" || has_errors=true; }
    [[ "${ENABLE_UPS_CHECK:-false}" == "true" ]] && { check_threshold_pair "UPS" "${UPS_THRESHOLD_WARN:-30}" "${UPS_THRESHOLD_CRIT:-10}" "true" || has_errors=true; }
    [[ "${ENABLE_NVME_CHECK:-false}" == "true" ]] && { check_threshold_pair "NVME_TEMP" "${NVME_TEMP_THRESHOLD_WARN:-70}" "${NVME_TEMP_THRESHOLD_CRIT:-80}" || has_errors=true; }
    
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
if ! [[ "$ALERT_COOLDOWN_SEC" =~ ^[0-9]+$ ]]; then
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
            log "INFO" "Rate limited alert for ${key}: cooldown active (${ALERT_COOLDOWN_SEC}s)"
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
        fi
    fi
}

# ===========================================================================
# HTML escaping helper for Telegram
# ===========================================================================
html_escape() {
    local text="$1"
    # Escape HTML entities that break Telegram parsing
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    text="${text//\"/&quot;}"
    text="${text//\'/&#39;}"
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
# Portable MD5 hash: GNU md5sum or BSD md5, fallback to cksum
# ===========================================================================
portable_md5() {
    md5sum 2>/dev/null | awk '{print $1}' \
    || md5 -q 2>/dev/null \
    || { cksum | awk '{print $1}'; }
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
check_cpu() {
    [[ -f /proc/loadavg ]] || { log "WARN" "check_cpu: /proc/loadavg not found — skipping"; return; }
    
    local cores
    cores=$(nproc 2>/dev/null) || cores=1
    if ! [[ "$cores" =~ ^[0-9]+$ ]] || [[ "$cores" -lt 1 ]]; then
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
    load_pct=$(awk -v load="$load_1m" -v cores="$cores" 'BEGIN {printf "%.0f", (load / cores) * 100}')
    if [[ -z "$load_pct" || ! "$load_pct" =~ ^[0-9]+$ ]]; then
        log "WARN" "check_cpu: computed load_pct '${load_pct}' is not numeric — skipping"
        return
    fi

    local state="OK"
    local detail="CPU load ${load_1m} (${load_pct}% of ${cores} cores)"

    if (( load_pct >= CPU_THRESHOLD_CRIT )); then
        state="CRITICAL"
        detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_CRIT}%)"
    elif (( load_pct >= CPU_THRESHOLD_WARN )); then
        state="WARNING"
        detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_WARN}%)"
    fi

    check_state_change "cpu" "$state" "$detail"
    
    # Capture top processes if CPU is under stress
    if [[ "$state" == "WARNING" || "$state" == "CRITICAL" ]]; then
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
    if [[ -z "$available_kb" ]]; then
        log "WARN" "check_memory: MemAvailable not found in /proc/meminfo — skipping"
        return
    fi

    # Percentage of AVAILABLE memory (not just "free")
    local avail_pct
    avail_pct=$(( (available_kb * 100) / total_kb ))

    local total_mb=$(( total_kb / 1024 ))
    local avail_mb=$(( available_kb / 1024 ))

    local state="OK"
    local detail="Memory: ${avail_mb}MB available of ${total_mb}MB (${avail_pct}% free)"

    if (( avail_pct <= MEM_THRESHOLD_CRIT )); then
        state="CRITICAL"
        detail="Memory: only <b>${avail_mb}MB</b> available of ${total_mb}MB (<b>${avail_pct}%</b> free, threshold: ${MEM_THRESHOLD_CRIT}%)"
    elif (( avail_pct <= MEM_THRESHOLD_WARN )); then
        state="WARNING"
        detail="Memory: only <b>${avail_mb}MB</b> available of ${total_mb}MB (<b>${avail_pct}%</b> free, threshold: ${MEM_THRESHOLD_WARN}%)"
    fi

    check_state_change "mem" "$state" "$detail"
    
    # Capture top processes if memory is under stress (and not already captured by CPU)
    if [[ "$state" == "WARNING" || "$state" == "CRITICAL" ]] && [[ -z "$TOP_PROCESSES_INFO" ]]; then
        TOP_PROCESSES_INFO=$(get_top_processes "${TOP_PROCESS_COUNT:-5}")
    fi
}

# ===========================================================================
# CHECK: Disk Space
# ===========================================================================
check_disk() {
    # Parse df output, skip tmpfs/devtmpfs/overlay/squashfs/loop
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
        if ! [[ "$usage" =~ ^[0-9]+$ ]]; then
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

        if (( usage >= DISK_THRESHOLD_CRIT )); then
            state="CRITICAL"
            detail="Disk <b>${safe_mount}</b>: <b>${pct}</b> used on ${safe_fs} (threshold: ${DISK_THRESHOLD_CRIT}%)"
        elif (( usage >= DISK_THRESHOLD_WARN )); then
            state="WARNING"
            detail="Disk <b>${safe_mount}</b>: <b>${pct}</b> used on ${safe_fs} (threshold: ${DISK_THRESHOLD_WARN}%)"
        fi

        check_state_change "$key" "$state" "$detail"
    done < <(run_with_timeout "$CHECK_TIMEOUT" df -h --output=source,size,used,avail,pcent,target 2>/dev/null)
}

# ===========================================================================
# CHECK: Internet Connectivity
# ===========================================================================
check_internet() {
    if ! command -v ping &>/dev/null; then
        log "INFO" "check_internet: ping not found — skipping"
        return
    fi
    local target="${PING_TARGET:-8.8.8.8}"
    if [[ -z "$target" ]]; then
        log "WARN" "check_internet: PING_TARGET is empty — skipping"
        return
    fi
    if ! [[ "${PING_FAIL_THRESHOLD}" =~ ^[0-9]+$ ]]; then
        log "WARN" "check_internet: PING_FAIL_THRESHOLD '${PING_FAIL_THRESHOLD}' is not numeric — skipping"
        return
    fi
    local fail_count=0
    for (( i=1; i<=PING_FAIL_THRESHOLD; i++ )); do
        if ! ping -c 1 -W 3 "$target" &>/dev/null; then
            fail_count=$(( fail_count + 1 ))
        fi
    done

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

    check_state_change "inet" "$state" "$detail"
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
            
            local state="OK"
            local detail="Swap: ${swap_used_mb}MB used of ${swap_total_mb}MB (${swap_pct}%)"
            
            if (( swap_pct >= SWAP_THRESHOLD_CRIT )); then
                state="CRITICAL"
                detail="Swap: <b>${swap_used_mb}MB</b> used of ${swap_total_mb}MB (<b>${swap_pct}%</b>, threshold: ${SWAP_THRESHOLD_CRIT}%)"
            elif (( swap_pct >= SWAP_THRESHOLD_WARN )); then
                state="WARNING"
                detail="Swap: <b>${swap_used_mb}MB</b> used of ${swap_total_mb}MB (<b>${swap_pct}%</b>, threshold: ${SWAP_THRESHOLD_WARN}%)"
            fi
            
            check_state_change "swap" "$state" "$detail"
        fi
    fi
}

# ===========================================================================
# CHECK: I/O Wait (CPU waiting for disk I/O)
# ===========================================================================
check_iowait() {
    [[ -f /proc/stat ]] || { log "WARN" "check_iowait: /proc/stat not found — skipping"; return; }
    # Calculate iowait% over a 1-second interval using two /proc/stat samples.
    # /proc/stat values are cumulative since boot, so a single sample gives the
    # lifetime average (always near 0 on long-running systems) -- useless.
    # Delta between two samples gives the actual current interval percentage.
    # Read all CPU fields dynamically (kernel versions provide 7-10+ fields)
    local -a cpu1 cpu2
    read -r -a cpu1 < <(awk '/^cpu / {$1=""; print}' /proc/stat)
    sleep 1
    read -r -a cpu2 < <(awk '/^cpu / {$1=""; print}' /proc/stat)

    # Ensure we have at least 5 fields (user, nice, system, idle, iowait)
    if [[ ${#cpu1[@]} -lt 5 || ${#cpu2[@]} -lt 5 ]]; then
        log "WARN" "check_iowait: /proc/stat has fewer than 5 CPU fields — skipping"
        return
    fi

    # iowait is the 5th field (index 4)
    local iw1="${cpu1[4]}" iw2="${cpu2[4]}"

    # Sum all fields for total, defaulting missing fields to 0
    local dtotal=0
    for (( i=0; i<${#cpu2[@]}; i++ )); do
        dtotal=$(( dtotal + (${cpu2[$i]:-0}) - (${cpu1[$i]:-0}) ))
    done
    local diowait=$(( iw2 - iw1 ))

    local iowait_pct=0
    if [[ "$dtotal" -gt 0 ]]; then
        iowait_pct=$(( (diowait * 100) / dtotal ))
    fi

    local state="OK"
    local detail="I/O Wait: ${iowait_pct}% of CPU time"

    if (( iowait_pct >= IOWAIT_THRESHOLD_CRIT )); then
        state="CRITICAL"
        detail="I/O Wait: <b>${iowait_pct}%</b> of CPU time waiting for disk (threshold: ${IOWAIT_THRESHOLD_CRIT}%)"
    elif (( iowait_pct >= IOWAIT_THRESHOLD_WARN )); then
        state="WARNING"
        detail="I/O Wait: <b>${iowait_pct}%</b> of CPU time waiting for disk (threshold: ${IOWAIT_THRESHOLD_WARN}%)"
    fi

    check_state_change "iowait" "$state" "$detail"
}

# ===========================================================================
# CHECK: Zombie Processes
# ===========================================================================
check_zombies() {
    local zombie_count
    zombie_count=$(ps aux | awk '$8 ~ /^Z/ {count++} END {print count+0}')
    if ! [[ "$zombie_count" =~ ^[0-9]+$ ]]; then
        log "WARN" "check_zombies: non-numeric zombie_count '${zombie_count}' — skipping"
        return
    fi
    
    local state="OK"
    local detail="Zombie processes: ${zombie_count}"
    
    if (( zombie_count >= ZOMBIE_THRESHOLD_CRIT )); then
        state="CRITICAL"
        detail="Zombie processes: <b>${zombie_count}</b> (threshold: ${ZOMBIE_THRESHOLD_CRIT})"
    elif (( zombie_count >= ZOMBIE_THRESHOLD_WARN )); then
        state="WARNING"
        detail="Zombie processes: <b>${zombie_count}</b> (threshold: ${ZOMBIE_THRESHOLD_WARN})"
    fi
    
    check_state_change "zombies" "$state" "$detail"
}

# ===========================================================================
# HELPER: Get Top CPU/Memory Processes
# Called when CPU or Memory is in WARNING/CRITICAL state
# Returns: formatted string for alerts
# ===========================================================================
get_top_processes() {
    local count="${1:-5}"
    # Validate count is a positive integer in reasonable range
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]] || [[ "$count" -gt 50 ]]; then
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
        log "INFO" "check_failed_systemd_services: systemctl not found — skipping"
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
    [[ -n "$pct_used" && ! "$pct_used" =~ ^[0-9]+$ ]] && pct_used=""
    [[ -n "$temp" && ! "$temp" =~ ^[0-9]+$ ]] && temp=""
    [[ -n "$media_errors" && ! "$media_errors" =~ ^[0-9]+$ ]] && media_errors=""

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
        if ! [[ "$expected_status" =~ ^[0-9]+$ ]]; then
            log "WARN" "check_sites: invalid expected_status '${expected_status}' for ${url} — using default"
            expected_status="${SITE_EXPECTED_STATUS:-200}"
        elif [[ "$expected_status" -lt 100 ]] || [[ "$expected_status" -gt 599 ]]; then
            log "WARN" "check_sites: expected_status '${expected_status}' out of range (100-599) for ${url} — using default"
            expected_status="${SITE_EXPECTED_STATUS:-200}"
        fi
        if ! [[ "$max_response_ms" =~ ^[0-9]+$ ]]; then
            log "WARN" "check_sites: invalid max_response_ms '${max_response_ms}' for ${url} — using default"
            max_response_ms="${SITE_MAX_RESPONSE_MS:-10000}"
        elif [[ "$max_response_ms" -lt 1 ]]; then
            log "WARN" "check_sites: max_response_ms '${max_response_ms}' must be >= 1 for ${url} — using default"
            max_response_ms="${SITE_MAX_RESPONSE_MS:-10000}"
        fi
        if ! [[ "$ssl_warn_days" =~ ^[0-9]+$ ]]; then
            ssl_warn_days="${SITE_SSL_WARN_DAYS:-7}"
        fi
        
        # Hash-based key for state file (avoids collisions from regex sanitization)
        # Use awk to extract hash portably (GNU md5sum: "hash  file", BSD md5: "hash")
        local key="site_$(printf '%s' "$url" | portable_md5 | cut -c1-12)"
        
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
                cert_enddate=$(echo | run_with_timeout "$CHECK_TIMEOUT" \
                    openssl s_client -servername "$host_for_ssl" -connect "${host_for_ssl}:443" 2>/dev/null \
                    | openssl x509 -noout -enddate 2>/dev/null \
                    | sed 's/notAfter=//')
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
    for entry in $CRITICAL_PORTS; do
        local host="${entry%%:*}"
        local port="${entry##*:}"
        # Trim whitespace
        host="${host// /}"
        port="${port// /}"
        [[ -z "$host" || -z "$port" ]] && continue

        # Validate port is numeric to prevent injection
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            log "WARN" "check_tcp_ports: invalid port '${port}' in entry '${entry}' — skipping"
            continue
        fi

        local safe_host
        safe_host=$(html_escape "$host")
        # Hash-based key to avoid collisions from sanitization (e.g., host-1 vs host.1)
        local key="port_$(printf '%s' "${entry}" | portable_md5 | cut -c1-12)"
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
# Parses `sensors` output for package/core temps
# ===========================================================================
check_cpu_temp() {
    if ! command -v sensors &>/dev/null; then
        log "INFO" "CPU temp check: sensors not installed — skipping"
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
    local warn="${TEMP_THRESHOLD_WARN:-75}"
    local crit="${TEMP_THRESHOLD_CRIT:-90}"

    local state="OK"
    local detail="CPU temperature: ${temp}°C"

    if (( temp_int >= crit )); then
        state="CRITICAL"
        detail="CPU temperature: <b>${temp}°C</b> (threshold: ${crit}°C)"
    elif (( temp_int >= warn )); then
        state="WARNING"
        detail="CPU temperature: <b>${temp}°C</b> (threshold: ${warn}°C)"
    fi

    check_state_change "cpu_temp" "$state" "$detail"
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
        log "INFO" "DNS check: no resolver tool found (dig/nslookup/host) — skipping"
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
    if ! command -v nvidia-smi &>/dev/null; then
        log "INFO" "GPU check: nvidia-smi not installed — skipping"
        return
    fi

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
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
            log "WARN" "check_gpu: non-numeric GPU index '${idx}' — skipping"
            continue
        fi
        # Validate numeric fields from nvidia-smi
        if ! [[ "$temp" =~ ^[0-9]+$ ]]; then
            log "WARN" "check_gpu: GPU ${idx} returned non-numeric temperature '${temp}' — skipping"
            continue
        fi
        # Validate remaining numeric fields (defense-in-depth)
        [[ "$util" =~ ^[0-9]+$ ]] || util="?"
        [[ "$mem_used" =~ ^[0-9]+$ ]] || mem_used="?"
        [[ "$mem_total" =~ ^[0-9]+$ ]] || mem_total="?"
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
                local state="OK"
                local detail="Battery: ${bat_pct}% (${bat_state_str})"
                local warn="${UPS_THRESHOLD_WARN:-30}"
                local crit="${UPS_THRESHOLD_CRIT:-10}"

                if (( bat_pct <= crit )); then
                    state="CRITICAL"
                    detail="Battery: <b>${bat_pct}%</b> (${bat_state_str}, threshold: ${crit}%)"
                elif (( bat_pct <= warn )); then
                    state="WARNING"
                    detail="Battery: <b>${bat_pct}%</b> (${bat_state_str}, threshold: ${warn}%)"
                fi
                check_state_change "battery" "$state" "$detail"
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
            local state="OK"
            local detail="UPS: ${bcharge}% charge (${apc_status})"
            local warn="${UPS_THRESHOLD_WARN:-30}"
            local crit="${UPS_THRESHOLD_CRIT:-10}"

            if (( bcharge <= crit )); then
                state="CRITICAL"
                detail="UPS: <b>${bcharge}%</b> charge (${apc_status}, threshold: ${crit}%)"
            elif (( bcharge <= warn )); then
                state="WARNING"
                detail="UPS: <b>${bcharge}%</b> charge (${apc_status}, threshold: ${warn}%)"
            fi
            check_state_change "ups" "$state" "$detail"
            return
        fi
    fi

    # No battery/UPS tool found — silently skip
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
            log "INFO" "Network bandwidth check: 'ip' command not found — skipping"
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
    if ! [[ "$prev_rx" =~ ^[0-9]+$ && "$prev_tx" =~ ^[0-9]+$ && "$prev_ts" =~ ^[0-9]+$ ]]; then
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
        log "INFO" "check_network_bandwidth: counter wraparound detected on ${iface} — skipping rate calculation"
        check_state_change "net_bw" "OK" "Network ${safe_iface}: counter wraparound (awaiting next sample)"
        return
    fi

    # Convert to Mbit/s (rate is in bytes/sec, * 8 / 1000000)
    local rx_mbps tx_mbps
    rx_mbps=$(awk -v rate="$rx_rate" 'BEGIN {printf "%.1f", rate * 8 / 1000000}')
    tx_mbps=$(awk -v rate="$tx_rate" 'BEGIN {printf "%.1f", rate * 8 / 1000000}')

    local warn="${NETWORK_THRESHOLD_WARN:-800}"    # Mbit/s
    local crit="${NETWORK_THRESHOLD_CRIT:-950}"    # Mbit/s

    # Use the higher of rx/tx for threshold comparison
    local max_mbps
    max_mbps=$(awk -v rx="$rx_mbps" -v tx="$tx_mbps" 'BEGIN {printf "%.0f", (rx > tx) ? rx : tx}')

    local state="OK"
    local detail="Network ${safe_iface}: RX ${rx_mbps} Mbit/s, TX ${tx_mbps} Mbit/s"

    if (( max_mbps >= crit )); then
        state="CRITICAL"
        detail="Network ${safe_iface}: RX <b>${rx_mbps}</b> Mbit/s, TX <b>${tx_mbps}</b> Mbit/s (threshold: ${crit} Mbit/s)"
    elif (( max_mbps >= warn )); then
        state="WARNING"
        detail="Network ${safe_iface}: RX <b>${rx_mbps}</b> Mbit/s, TX <b>${tx_mbps}</b> Mbit/s (threshold: ${warn} Mbit/s)"
    fi

    check_state_change "net_bw" "$state" "$detail"
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
        local key="log_$(printf '%s' "$logfile" | portable_md5 | cut -c1-12)"

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
        [[ -f "$filepath" ]] || continue

        local current_sum
        current_sum=$(sha256sum "$filepath" 2>/dev/null | awk '{print $1}')
        [[ -z "$current_sum" ]] && continue

        new_checksums+="${filepath}=${current_sum}"$'\n'

        local key="integrity_$(printf '%s' "$filepath" | portable_md5 | cut -c1-12)"
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
        # Try GNU stat first, then BSD stat (macOS), fallback to current time (skip check)
        file_mtime=$(stat -c %Y "$touchfile" 2>/dev/null || stat -f %m "$touchfile" 2>/dev/null || echo "")
        if [[ -z "$file_mtime" ]]; then
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
        if ! [[ "$hb_timestamp" =~ ^[0-9]+$ ]]; then
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
        if [[ "${hb_check_count:-}" =~ ^[0-9]+$ ]]; then
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
    [[ "${ENABLE_GPU_CHECK:-false}" == "true" ]] && check_gpu
    [[ "${ENABLE_UPS_CHECK:-false}" == "true" ]] && check_ups
    [[ "${ENABLE_NETWORK_CHECK:-false}" == "true" ]] && check_network_bandwidth
    [[ "${ENABLE_LOG_CHECK:-false}" == "true" ]] && check_log_patterns
    [[ "${ENABLE_INTEGRITY_CHECK:-false}" == "true" ]] && check_file_integrity
    [[ "${ENABLE_CRON_CHECK:-false}" == "true" ]] && check_cron_jobs
    [[ "${ENABLE_FLEET_CHECK:-false}" == "true" ]] && check_fleet_heartbeats
}

# ===========================================================================
# AUTO-REMEDIATION: Restart failed services if configured
# Called after checks, before alert dispatch
# ===========================================================================
auto_remediate() {
    local restart_services="${AUTO_RESTART_SERVICES:-}"
    [[ -z "$restart_services" ]] && return

    for svc in $restart_services; do
        local key="proc_$(sanitize_state_key "$svc")"
        local svc_state="${CURR_STATE[$key]:-OK}"

        if [[ "$svc_state" == "CRITICAL" ]]; then
            log "INFO" "Auto-remediation: attempting restart of ${svc}"
            if run_with_timeout "$CHECK_TIMEOUT" systemctl restart "$svc" 2>/dev/null; then
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

        log "INFO" "Heartbeat file updated: ${target}"

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
            log "INFO" "Heartbeat ping sent to ${url%%\?*}"
        fi
    else
        log "WARN" "Heartbeat: unknown HEARTBEAT_MODE '${mode}' (expected 'file' or 'webhook')"
    fi
}

# ===========================================================================
# Alert Retry/Queue
# If dispatch fails, queue to a file and retry on next cycle
# ===========================================================================
ALERT_QUEUE_FILE="${STATE_FILE}.queue"

dispatch_with_retry() {
    local message="$1"

    # First try to send any queued alerts from previous failures
    if [[ -f "$ALERT_QUEUE_FILE" ]]; then
        local queued_msg
        queued_msg=$(cat "$ALERT_QUEUE_FILE" 2>/dev/null)
        if [[ -n "$queued_msg" ]]; then
            log "INFO" "Retrying queued alert from previous cycle"
            if send_telegram "$queued_msg" 2>/dev/null; then
                send_webhook "$queued_msg" || true
                send_email "$queued_msg" || true
                rm -f "$ALERT_QUEUE_FILE"
                log "INFO" "Queued alert delivered successfully"
            fi
        fi
    fi

    # Now try to send the current message
    export TELEMON_HOSTNAME
    TELEMON_HOSTNAME="$(hostname)"

    if send_telegram "$message" 2>/dev/null; then
        send_webhook "$message" || true
        send_email "$message" || true
    else
        # Queue for retry on next cycle (append to preserve previously queued messages)
        log "WARN" "Alert delivery failed — queuing for retry"
        local existing_queue=""
        if [[ -f "$ALERT_QUEUE_FILE" ]]; then
            existing_queue=$(cat "$ALERT_QUEUE_FILE" 2>/dev/null) || existing_queue=""
        fi
        local separator=""
        [[ -n "$existing_queue" ]] && separator=$'\n---QUEUED_ALERT---\n'
        safe_write_state_file "$ALERT_QUEUE_FILE" "${existing_queue}${separator}${message}"
        # Still try webhook and email
        send_webhook "$message" || true
        send_email "$message" || true
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
        if ! [[ "$start_h" =~ ^[0-9]+$ && "$start_m" =~ ^[0-9]+$ && "$end_h" =~ ^[0-9]+$ && "$end_m" =~ ^[0-9]+$ ]]; then
            log "WARN" "Invalid MAINT_SCHEDULE entry: '${entry}' — skipping"
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
        ENABLE_JSON_STATUS; do
        local val="${!enable_var:-}"
        if [[ -n "$val" && "$val" != "true" && "$val" != "false" ]]; then
            echo "  WARN: ${enable_var}='${val}' — expected 'true' or 'false' (value treated as false)"
            warnings=$((warnings + 1))
        fi
    done

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
        for site in ${CRITICAL_SITES:-}; do
            local url="${site%%|*}"
            echo "        → $url"
        done
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
        "GPU_CHECK:nvidia-smi" \
        "UPS_CHECK:upower/apcaccess" \
        "NETWORK_CHECK:/proc/net/dev" \
        "LOG_CHECK:LOG_WATCH_FILES" \
        "INTEGRITY_CHECK:INTEGRITY_WATCH_FILES" \
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
            elif ! [[ "$cp_port" =~ ^[0-9]+$ ]]; then
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
    [[ -n "${EMAIL_TO:-}" ]] && echo "  Email:     ${EMAIL_TO}" || echo "  Email:     not configured"
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
        local email_mailer_found=false
        for candidate in msmtp sendmail /usr/sbin/sendmail; do
            if command -v "$candidate" &>/dev/null; then
                email_mailer_found=true
                break
            fi
        done
        if [[ "$email_mailer_found" != "true" ]]; then
            echo "  WARN: EMAIL_TO is set but no mailer found (install msmtp or sendmail)"
            warnings=$((warnings + 1))
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
    if ! [[ "$acs" =~ ^[0-9]+$ ]]; then
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
                [[ "$fl_ts" =~ ^[0-9]+$ ]] || continue
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
                if [[ "${fl_count:-}" =~ ^[0-9]+$ ]]; then
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
    log "INFO" "Webhook delivered to ${webhook_url%%\?*}"
    return 0
}

# ===========================================================================
# Email (SMTP) Dispatch
# Sends plain-text alert via sendmail/msmtp if available and EMAIL_TO is set
# ===========================================================================
send_email() {
    local message="$1"
    local email_to="${EMAIL_TO:-}"
    [[ -z "$email_to" ]] && return 0

    # Basic email format validation
    if [[ ! "$email_to" == *"@"* ]]; then
        log "WARN" "send_email: EMAIL_TO '${email_to}' does not appear to be a valid email address"
        return 1
    fi

    # Find mail transport
    local mailer=""
    for candidate in msmtp sendmail /usr/sbin/sendmail; do
        if command -v "$candidate" &>/dev/null; then
            mailer="$candidate"
            break
        fi
    done
    if [[ -z "$mailer" ]]; then
        log "WARN" "EMAIL_TO is set but no mailer found (install msmtp or sendmail)"
        return 1
    fi

    # Strip HTML tags for plain-text email
    local plain_message
    plain_message=$(printf '%s\n' "$message" | sed 's/%0A/\n/g; s/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')

    local hostname
    hostname=$(hostname)
    local email_from="${EMAIL_FROM:-telemon@${hostname}}"
    # Validate EMAIL_FROM contains @
    if [[ ! "$email_from" == *"@"* ]]; then
        log "WARN" "send_email: EMAIL_FROM '${email_from}' does not appear to be a valid email address — skipping"
        return 1
    fi
    # Sanitize email headers: strip newlines, carriage returns, tabs, and null bytes
    email_from=$(printf '%s' "$email_from" | tr -d '\n\r\t\0')
    email_to=$(printf '%s' "$email_to" | tr -d '\n\r\t\0')
    local subject
    subject=$(printf '[Telemon] %s — alert' "$hostname" | tr -d '\n\r\t\0')

    {
        echo "From: ${email_from}"
        echo "To: ${email_to}"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=utf-8"
        echo ""
        echo "$plain_message"
    } | "$mailer" -t 2>/dev/null

    if [[ $? -eq 0 ]]; then
        log "INFO" "Email alert sent to ${email_to}"
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
        --help|-h)
            echo "Usage: telemon.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --test, -t       Validate config and send a test Telegram message"
            echo "  --validate, -v   Validate configuration without sending anything"
            echo "  --digest, -d     Send a health digest summary (even if everything is OK)"
            echo "  --help, -h       Show this help"
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

    local is_first_run=false
    if [[ ! -f "$STATE_FILE" ]]; then
        is_first_run=true
    fi

    load_state

    # On first run, temporarily set confirmation count to 1 for immediate feedback
    local saved_confirm_count="${CONFIRMATION_COUNT:-3}"
    if [[ "$is_first_run" == "true" ]]; then
        CONFIRMATION_COUNT=1
        log "INFO" "First run detected - using immediate alerts (confirmation=1)"
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
