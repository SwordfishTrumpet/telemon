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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "FATAL: .env not found at ${ENV_FILE}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

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
    
    # Fallback: PID file mechanism
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null) || old_pid=""
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Another instance (PID $old_pid) is running - exiting" >&2
            exit 0
        fi
        # Stale lock file, remove it
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    if command -v flock &>/dev/null; then
        flock -u 200 2>/dev/null || true
        exec 200>&- 2>/dev/null || true
    fi
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
    local max_size=$((10 * 1024 * 1024))  # 10MB
    local max_backups=5
    
    if [[ -f "$LOG_FILE" ]]; then
        local log_size
        log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$log_size" -gt "$max_size" ]]; then
            # Rotate backups
            for i in $(seq $((max_backups - 1)) -1 1); do
                local src="${LOG_FILE}.${i}"
                local dst="${LOG_FILE}.$((i + 1))"
                [[ -f "$src" ]] && mv "$src" "$dst"
            done
            mv "$LOG_FILE" "${LOG_FILE}.1"
            : > "$LOG_FILE"
            log "INFO" "Log rotated (size exceeded 10MB)"
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
validate_thresholds() {
    local has_errors=false
    
    # Helper to check if value is a valid number
    is_valid_number() {
        [[ "$1" =~ ^[0-9]+$ ]]
    }
    
    # Helper to check warn < crit
    check_threshold_pair() {
        local name="$1"
        local warn="$2"
        local crit="$3"
        
        if ! is_valid_number "$warn"; then
            log "ERROR" "Invalid ${name}_THRESHOLD_WARN: '${warn}' must be a positive integer"
            has_errors=true
        fi
        if ! is_valid_number "$crit"; then
            log "ERROR" "Invalid ${name}_THRESHOLD_CRIT: '${crit}' must be a positive integer"
            has_errors=true
        fi
        if is_valid_number "$warn" && is_valid_number "$crit"; then
            if [[ "$warn" -ge "$crit" ]]; then
                log "WARN" "${name}_THRESHOLD_WARN (${warn}) should be less than ${name}_THRESHOLD_CRIT (${crit})"
            fi
        fi
    }
    
    # Validate all threshold pairs
    check_threshold_pair "CPU" "${CPU_THRESHOLD_WARN:-70}" "${CPU_THRESHOLD_CRIT:-80}"
    check_threshold_pair "MEM" "${MEM_THRESHOLD_WARN:-15}" "${MEM_THRESHOLD_CRIT:-10}"
    check_threshold_pair "DISK" "${DISK_THRESHOLD_WARN:-85}" "${DISK_THRESHOLD_CRIT:-90}"
    check_threshold_pair "SWAP" "${SWAP_THRESHOLD_WARN:-50}" "${SWAP_THRESHOLD_CRIT:-80}"
    check_threshold_pair "IOWAIT" "${IOWAIT_THRESHOLD_WARN:-30}" "${IOWAIT_THRESHOLD_CRIT:-50}"
    check_threshold_pair "ZOMBIE" "${ZOMBIE_THRESHOLD_WARN:-5}" "${ZOMBIE_THRESHOLD_CRIT:-20}"
    
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
declare -A PREV_STATE
declare -A CURR_STATE
declare -A PREV_COUNT
declare -A STATE_DETAIL

# Global variable to accumulate alerts
ALERTS=""

load_state() {
    PREV_STATE=()
    PREV_COUNT=()
    
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
}

save_state() {
    # Create temp file and atomically move
    local tmp_file="${STATE_FILE}.tmp.$$"
    
    for key in "${!CURR_STATE[@]}"; do
        local state="${CURR_STATE[$key]}"
        local count="${PREV_COUNT[$key]:-0}"
        echo "${key}=${state}:${count}"
    done > "$tmp_file"
    
    mv "$tmp_file" "$STATE_FILE"
}

check_state_change() {
    local key="$1"
    local new_state="$2"
    local detail="$3"
    
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
            # Alert if we just reached confirmation threshold
            if [[ "$prev_count" -eq "$confirm_count" && "$new_state" != "OK" ]]; then
                should_alert=true
            fi
        fi
    else
        # State changed - reset count to 1 (first occurrence of new state)
        PREV_COUNT["$key"]=1
        # Alert immediately on state change (count=1 means first detection)
        # But only if it's not OK (we alert on OK -> non-OK transitions)
        if [[ "$new_state" != "OK" ]]; then
            should_alert=true
        elif [[ "$prev_state" != "OK" ]]; then
            # Was not OK, now OK - resolution alert
            should_alert=true
        fi
    fi
    
    if [[ "$should_alert" == "true" ]]; then
        local emoji=""
        case "$new_state" in
            CRITICAL) emoji="&#128308;" ;;  # Red circle
            WARNING)  emoji="&#128992;" ;;  # Orange circle
            OK)       emoji="&#128994;" ;;  # Green circle
        esac
        
        ALERTS+="${emoji} <b>${key}</b>: ${detail}%0A%0A"
        log "INFO" "State change confirmed for ${key}: ${prev_state} -> ${new_state} (count: ${PREV_COUNT[$key]})"
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
    echo "$text"
}
# ===========================================================================
check_cpu() {
    local cores
    cores=$(nproc)
    local load_1m
    load_1m=$(awk '{print $1}' /proc/loadavg)

    # Calculate load as percentage of cores (bash integer math, x100 for precision)
    local load_pct
    load_pct=$(awk "BEGIN {printf \"%.0f\", (${load_1m} / ${cores}) * 100}")

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
        TOP_PROCESSES_INFO=$(get_top_processes 5)
    fi
}

# ===========================================================================
# CHECK: Memory
# ===========================================================================
check_memory() {
    local total_kb free_kb available_kb
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

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
        TOP_PROCESSES_INFO=$(get_top_processes 5)
    fi
}

# ===========================================================================
# CHECK: Disk Space
# ===========================================================================
check_disk() {
    # Parse df output, skip tmpfs/devtmpfs/overlay/squashfs
    while read -r filesystem size used avail pct mountpoint; do
        [[ "$filesystem" == "Filesystem" ]] && continue
        [[ "$filesystem" == tmpfs* || "$filesystem" == devtmpfs* ]] && continue
        [[ "$filesystem" == overlay* || "$filesystem" == squashfs* ]] && continue
        [[ "$filesystem" == udev* || "$filesystem" == efivarfs* ]] && continue
        [[ "$mountpoint" == /snap/* ]] && continue
        [[ "$mountpoint" == /boot/efi ]] && continue
        [[ "$mountpoint" == /dev || "$mountpoint" == /dev/* ]] && continue
        [[ "$mountpoint" == /sys/* ]] && continue
        [[ "$mountpoint" == /run/* ]] && continue

        local usage="${pct%%%}"  # strip trailing %
        # Sanitize key: replace / with _ for state file
        local key="disk_$(echo "$mountpoint" | tr '/' '_' | sed 's/^_/root/')"

        local state="OK"
        local detail="Disk ${mountpoint}: ${pct} used (${filesystem})"

        if (( usage >= DISK_THRESHOLD_CRIT )); then
            state="CRITICAL"
            detail="Disk <b>${mountpoint}</b>: <b>${pct}</b> used on ${filesystem} (threshold: ${DISK_THRESHOLD_CRIT}%)"
        elif (( usage >= DISK_THRESHOLD_WARN )); then
            state="WARNING"
            detail="Disk <b>${mountpoint}</b>: <b>${pct}</b> used on ${filesystem} (threshold: ${DISK_THRESHOLD_WARN}%)"
        fi

        check_state_change "$key" "$state" "$detail"
    done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null)
}

# ===========================================================================
# CHECK: Internet Connectivity
# ===========================================================================
check_internet() {
    local fail_count=0
    for (( i=1; i<=PING_FAIL_THRESHOLD; i++ )); do
        if ! ping -c 1 -W 3 "$PING_TARGET" &>/dev/null; then
            fail_count=$(( fail_count + 1 ))
        fi
    done

    local state="OK"
    local detail="Internet: connectivity to ${PING_TARGET} OK"

    if (( fail_count >= PING_FAIL_THRESHOLD )); then
        state="CRITICAL"
        detail="Internet: <b>${fail_count}/${PING_FAIL_THRESHOLD}</b> pings to ${PING_TARGET} failed -- connectivity lost"
    elif (( fail_count > 0 )); then
        state="WARNING"
        detail="Internet: ${fail_count}/${PING_FAIL_THRESHOLD} pings to ${PING_TARGET} failed -- intermittent"
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
    # Read /proc/stat to get CPU stats
    local iowait
    iowait=$(awk '/^cpu / {print $6}' /proc/stat)
    
    if [[ -n "$iowait" ]]; then
        # Calculate percentage (iowait is in jiffies, need to calculate %)
        # Read current values
        local user nice system idle iowait irq softirq steal guest guest_nice
        read -r user nice system idle iowait irq softirq steal guest guest_nice < <(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11}' /proc/stat)
        
        local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local iowait_pct=0
        if [[ "$total" -gt 0 ]]; then
            iowait_pct=$(( (iowait * 100) / total ))
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
    fi
}

# ===========================================================================
# CHECK: Zombie Processes
# ===========================================================================
check_zombies() {
    local zombie_count
    zombie_count=$(ps aux | awk '$8 ~ /^Z/ {count++} END {print count+0}')
    
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
    local output=""
    output+="<pre>Top ${count} processes by CPU:\n"
    output+=$(ps aux --sort=-%cpu | head -$((count + 1)) | tail -${count} | awk '{printf "  %s %5s%% %s\n", $2, $3, $11}')
    output+="\n\nTop ${count} processes by Memory:\n"
    output+=$(ps aux --sort=-%mem | head -$((count + 1)) | tail -${count} | awk '{printf "  %s %5s%% %s\n", $2, $4, $11}')
    output+="</pre>"
    echo "$output"
}

# Global variable to store top processes info for alerts
TOP_PROCESSES_INFO=""

# ===========================================================================
# CHECK: System Processes (via pgrep / systemctl)
# ===========================================================================
check_system_processes() {
    for proc in $CRITICAL_SYSTEM_PROCESSES; do
        local state="OK"
        local detail="Process <code>${proc}</code> is running"

        # First check if process exists via pgrep
        if pgrep -x "$proc" &>/dev/null; then
            state="OK"
        else
            # Check systemd service status
            local systemd_status
            systemd_status=$(run_with_timeout "$CHECK_TIMEOUT" systemctl show -p ActiveState --value "$proc" 2>/dev/null || echo "unknown")
            
            case "$systemd_status" in
                active)
                    state="OK"
                    ;;
                failed)
                    state="CRITICAL"
                    detail="Systemd service <code>${proc}</code> has <b>FAILED</b> - check logs with: journalctl -u ${proc}"
                    ;;
                activating)
                    state="WARNING"
                    detail="Systemd service <code>${proc}</code> is <b>still starting</b> (may be stuck)"
                    ;;
                inactive|dead)
                    state="CRITICAL"
                    detail="Systemd service <code>${proc}</code> is <b>inactive/stopped</b>"
                    ;;
                *)
                    state="CRITICAL"
                    detail="Process <code>${proc}</code> is <b>NOT running</b> (status: ${systemd_status})"
                    ;;
            esac
        fi

        check_state_change "proc_${proc}" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: Failed Systemd Services (system-wide)
# ===========================================================================
check_failed_systemd_services() {
    # Get list of failed services
    local failed_services
    failed_services=$(run_with_timeout "$CHECK_TIMEOUT" systemctl --failed --no-legend --no-pager 2>/dev/null | awk '/failed/ {print $1}' | grep -v "^●$")
    
    if [[ -n "$failed_services" ]]; then
        local count
        count=$(echo "$failed_services" | wc -l)
        
        local state="CRITICAL"
        local detail="<b>${count} failed systemd service(s):</b>"
        
        # List first 3 failed services
        local service_list
        service_list=$(echo "$failed_services" | head -3 | tr '\n' ' ')
        detail+=" ${service_list}"
        
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
    # Bail if docker is not available
    if ! command -v docker &>/dev/null; then
        check_state_change "docker_engine" "CRITICAL" "Docker engine not found on PATH"
        return
    fi

    for container in $CRITICAL_CONTAINERS; do
        local state="OK"
        local detail="Container <code>${container}</code> is running"

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
                    detail="Container <code>${container}</code> is running but <b>unhealthy</b>"
                fi
                ;;
            restarting)
                state="WARNING"
                detail="Container <code>${container}</code> is <b>restarting</b>"
                ;;
            missing|"")
                state="CRITICAL"
                detail="Container <code>${container}</code> <b>does not exist</b>"
                ;;
            *)
                state="CRITICAL"
                detail="Container <code>${container}</code> status: <b>${status}</b>"
                ;;
        esac

        check_state_change "container_${container}" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: PM2 Processes
# ===========================================================================
check_pm2_processes() {
    if ! command -v pm2 &>/dev/null; then
        # Try common paths
        local pm2_bin=""
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
    else
        local pm2_bin="pm2"
    fi

    local jlist
    jlist=$(run_with_timeout "$CHECK_TIMEOUT" "$pm2_bin" jlist 2>/dev/null) || jlist="[]"

    for proc in $CRITICAL_PM2_PROCESSES; do
        local state="OK"
        local detail="PM2 process <code>${proc}</code> is online"

        local pm2_status
        pm2_status=$(echo "$jlist" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for p in data:
        if p.get('name') == '${proc}':
            print(p.get('pm2_env', {}).get('status', 'unknown'))
            sys.exit(0)
    print('missing')
except Exception:
    print('error')
" 2>/dev/null) || pm2_status="error"
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
                detail="PM2 process <code>${proc}</code> is <b>${pm2_status}</b>"
                ;;
            errored)
                state="CRITICAL"
                detail="PM2 process <code>${proc}</code> has <b>errored</b>"
                ;;
            missing)
                state="CRITICAL"
                detail="PM2 process <code>${proc}</code> <b>not found</b> in PM2 list"
                ;;
            *)
                state="WARNING"
                detail="PM2 process <code>${proc}</code> status: <b>${pm2_status}</b>"
                ;;
        esac

        check_state_change "pm2_${proc}" "$state" "$detail"
    done
}

# ===========================================================================
# CHECK: Website/Site Reachability Monitor
# Monitors HTTP/HTTPS endpoints for availability, response time, and SSL expiry
# ===========================================================================
check_sites() {
    # Parse space-separated list of site URLs
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
            # Extract parameters from the URL string
            local param_str="${site#*|}"
            while [[ "$param_str" == *"="* ]]; do
                local key="${param_str%%=*}"
                local rest="${param_str#*=}"
                local val="${rest%%|*}"
                
                case "$key" in
                    expected_status) expected_status="$val" ;;
                    max_response_ms) max_response_ms="$val" ;;
                    check_ssl) check_ssl="$val" ;;
                esac
                
                param_str="${rest#*|}"
                [[ "$param_str" == "$rest" ]] && break
            done
        fi
        
        # Sanitize key for state file (remove special chars)
        local key="site_$(echo "$url" | sed 's|[^a-zA-Z0-9]|_|g' | sed 's|__*|_|g' | sed 's|^_||')"
        
        local state="OK"
        local detail=""
        local curl_opts="-s -o /dev/null -w '%{http_code}|%{time_total}|%{redirect_url}|%{ssl_verify_result}'"
        local curl_cmd="curl ${curl_opts} --max-time $((max_response_ms / 1000 + 5)) -L --insecure"
        
        # Add SSL certificate info retrieval if HTTPS and SSL check enabled
        local ssl_info=""
        if [[ "$url" == https://* ]] && [[ "$check_ssl" == "true" ]]; then
            ssl_info=$(run_with_timeout "$CHECK_TIMEOUT" curl -sI -o /dev/null -w '%{cert_expiry}' "$url" 2>/dev/null || echo "")
        fi
        
        # Perform the HTTP check
        local response
        response=$(run_with_timeout "$CHECK_TIMEOUT" bash -c "$curl_cmd '$url'" 2>/dev/null || echo "000|0|||1")
        
        local http_code="${response%%|*}"
        local rest="${response#*|}"
        local response_time="${rest%%|*}"
        rest="${rest#*|}"
        local redirect_url="${rest%%|*}"
        rest="${rest#*|}"
        local ssl_verify="${rest%%|*}"
        
        # Convert response time to milliseconds
        local response_ms=$(awk "BEGIN {printf \"%.0f\", ${response_time} * 1000}" 2>/dev/null || echo "0")
        
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
        
        # Check SSL certificate expiry if enabled and HTTPS
        if [[ "$state" == "OK" ]] && [[ "$url" == https://* ]] && [[ "$check_ssl" == "true" ]] && [[ -n "$ssl_info" ]]; then
            # Parse certificate expiry date
            local expiry_timestamp
            expiry_timestamp=$(date -d "$ssl_info" +%s 2>/dev/null || echo "0")
            local now_timestamp=$(date +%s)
            local days_until_expiry=$(( (expiry_timestamp - now_timestamp) / 86400 ))
            
            if [[ "$days_until_expiry" -le 0 ]]; then
                state="CRITICAL"
                detail="Site <code>$(html_escape "$url")</code> SSL certificate <b>EXPIRED</b>"
            elif [[ "$days_until_expiry" -le "$ssl_warn_days" ]]; then
                state="WARNING"
                detail="Site <code>$(html_escape "$url")</code> SSL expires in <b>${days_until_expiry} days</b>"
            fi
        fi
        
        # Check SSL verification errors
        if [[ "$state" == "OK" ]] && [[ "$url" == https://* ]] && [[ "$ssl_verify" != "" ]] && [[ "$ssl_verify" != "0" ]]; then
            state="WARNING"
            detail="Site <code>$(html_escape "$url")</code> has <b>SSL certificate issues</b> (verify code: ${ssl_verify})"
        fi
        
        check_state_change "$key" "$state" "$detail"
    done
}

# ===========================================================================
# Telegram Dispatch
# ===========================================================================
send_telegram() {
    local message="$1"
    # Convert %0A back to real newlines for --data-urlencode
    message="${message//%0A/$'\n'}"
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${message}" 2>&1)

    local ok
    ok=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")

    if [[ "$ok" != "True" ]]; then
        log "ERROR" "Telegram send failed: ${response}"
        return 1
    fi
    return 0
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    log "INFO" "--- Monitor run started ---"
    
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

    # Run all checks (respecting ENABLE_ flags)
    [[ "${ENABLE_CPU_CHECK:-true}" == "true" ]] && check_cpu
    [[ "${ENABLE_MEMORY_CHECK:-true}" == "true" ]] && check_memory
    [[ "${ENABLE_DISK_CHECK:-true}" == "true" ]] && check_disk
    [[ "${ENABLE_SWAP_CHECK:-true}" == "true" ]] && check_swap
    [[ "${ENABLE_IOWAIT_CHECK:-true}" == "true" ]] && check_iowait
    [[ "${ENABLE_ZOMBIE_CHECK:-true}" == "true" ]] && check_zombies
    [[ "${ENABLE_INTERNET_CHECK:-true}" == "true" ]] && check_internet
    [[ "${ENABLE_SYSTEM_PROCESSES:-true}" == "true" ]] && check_system_processes
    [[ "${ENABLE_FAILED_SYSTEMD_SERVICES:-true}" == "true" ]] && check_failed_systemd_services
    [[ "${ENABLE_DOCKER_CONTAINERS:-true}" == "true" ]] && check_docker_containers
    [[ "${ENABLE_PM2_PROCESSES:-true}" == "true" ]] && check_pm2_processes
    [[ "${ENABLE_SITE_MONITOR:-false}" == "true" ]] && check_sites

    # Restore confirmation count for state saving
    CONFIRMATION_COUNT="$saved_confirm_count"

    # Persist new state
    save_state

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
    if [[ "$is_first_run" == true ]]; then
        local header="<b>&#128421; [$(hostname)] Telemon Initialized</b>%0A"
        header+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"
        header+="<b>Summary:</b> &#128308; ${crit_count} critical | &#128992; ${warn_count} warning | &#128994; ${ok_count} healthy%0A"
        header+="Confirmation count: ${saved_confirm_count} (alerts require ${saved_confirm_count} consecutive matches)%0A"
        header+="-----------------------------%0A%0A"

        # On first run, only report non-OK items
        local first_alerts=""
        for key in "${!CURR_STATE[@]}"; do
            if [[ "${CURR_STATE[$key]}" != "OK" ]]; then
                first_alerts+="&#9888;&#65039; <b>${key}</b>: ${CURR_STATE[$key]}%0A"
            fi
        done

        if [[ -n "$first_alerts" ]]; then
            header+="${first_alerts}"
        else
            header+="&#9989; All ${ok_count} checks passed. Monitoring active.%0A"
        fi

        send_telegram "$header" || true
        log "INFO" "First run: bootstrap message sent (${crit_count}C/${warn_count}W/${ok_count}OK)"

    elif [[ -n "$ALERTS" ]]; then
        # Normal run -- dispatch accumulated state-change alerts
        local header="<b>&#128421; [$(hostname)] System Vital Alert</b>%0A"
        header+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"

        local summary="<b>Summary:</b> &#128308; ${crit_count} critical | &#128992; ${warn_count} warning | &#128994; ${ok_count} healthy%0A"
        summary+="-----------------------------%0A%0A"

        local full_message="${header}${summary}${ALERTS}"
        
        # Append top processes info if available
        if [[ -n "$TOP_PROCESSES_INFO" ]]; then
            full_message+="%0A<b>Process Details:</b>%0A${TOP_PROCESSES_INFO}"
        fi

        send_telegram "$full_message" || true
        log "INFO" "Alert dispatched to Telegram (${crit_count}C/${warn_count}W/${ok_count}OK)"
    else
        log "INFO" "No confirmed state changes detected -- no alerts sent"
    fi

    log "INFO" "--- Monitor run finished ---"
}

main "$@"
