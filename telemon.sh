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
# State file management
# ---------------------------------------------------------------------------
# The state file stores one key=value:count per line:
#   cpu=CRITICAL:2
#   mem=OK:0
#   disk_sda1=WARNING:1
#   inet=CRITICAL:3
#   proc_sshd=OK:0
#   container_zilean=CRITICAL:1
#   pm2_hound=CRITICAL:2
#
# Format: state:consecutive_count
# - state: OK | WARNING | CRITICAL
# - consecutive_count: how many times this state has been seen consecutively
#
# An alert fires only when a key's value is confirmed CONFIRMATION_COUNT times.
# This prevents false alarms from transient spikes.
# ---------------------------------------------------------------------------

declare -A PREV_STATE
declare -A PREV_COUNT
declare -A CURR_STATE
declare -A CURR_COUNT
ALERTS=""  # accumulated HTML alert lines

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            # Parse state:count format (default count=0 if no colon)
            local state="${value%%:*}"
            local count="${value##*:}"
            [[ "$state" == "$value" ]] && count=0  # no colon found
            PREV_STATE["$key"]="$state"
            PREV_COUNT["$key"]="$count"
        done < "$STATE_FILE"
    fi
}

save_state() {
    : > "$STATE_FILE"
    for key in "${!CURR_STATE[@]}"; do
        echo "${key}=${CURR_STATE[$key]}:${CURR_COUNT[$key]:-0}" >> "$STATE_FILE"
    done
}

# ---------------------------------------------------------------------------
# Alert accumulator
# ---------------------------------------------------------------------------
# Compares current state to previous for a given key.
# Only queues a message when the state is confirmed CONFIRMATION_COUNT times.
# This prevents false alarms from transient spikes.
# ---------------------------------------------------------------------------
check_state_change() {
    local key="$1"
    local new_state="$2"   # OK | WARNING | CRITICAL
    local message="$3"     # human-readable detail

    local prev_state="${PREV_STATE[$key]:-UNKNOWN}"
    local prev_count="${PREV_COUNT[$key]:-0}"
    
    # Default confirmation count from env (default to 3 if not set)
    local confirm_count="${CONFIRMATION_COUNT:-3}"
    
    # Determine new consecutive count
    local new_count=0
    if [[ "$prev_state" == "$new_state" ]]; then
        new_count=$((prev_count + 1))
    else
        new_count=1  # state changed, start counting from 1
        log "INFO" "[${key}] State changed ${prev_state} -> ${new_state}, starting confirmation count"
    fi
    
    # Store current state and count
    CURR_STATE["$key"]="$new_state"
    CURR_COUNT["$key"]="$new_count"
    
    # Only alert when we've seen the same state CONFIRMATION_COUNT times
    # This ensures transient spikes don't trigger false alarms
    local should_alert=false
    
    if [[ "$new_count" -eq "$confirm_count" ]]; then
        # Reached confirmation threshold - now we can alert
        should_alert=true
    fi
    
    if [[ "$should_alert" != "true" ]]; then
        return
    fi
    
    local icon
    case "$new_state" in
        CRITICAL) icon="&#128680; CRITICAL" ;;   # alarm siren
        WARNING)  icon="&#9888;&#65039; WARNING" ;;
        OK)       icon="&#9989; RESOLVED" ;;
    esac
    
    # Add confirmation count to message if > 1
    local confirm_note=""
    if [[ "$confirm_count" -gt 1 ]]; then
        confirm_note=" (confirmed ${new_count}x)"
    fi
    
    ALERTS+="<b>${icon}:</b> ${message}${confirm_note}%0A"
    log "ALERT" "[${key}] ${prev_state} -> ${new_state}${confirm_note}: ${message}"
}

# ===========================================================================
# CHECK: CPU Load
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
# ===========================================================================
get_top_processes() {
    local count="${1:-5}"
    echo "Top ${count} processes by CPU:"
    ps aux --sort=-%cpu | head -$((count + 1)) | tail -${count} | awk '{printf "  %s %5s%% %s\n", $2, $3, $11}'
    echo ""
    echo "Top ${count} processes by Memory:"
    ps aux --sort=-%mem | head -$((count + 1)) | tail -${count} | awk '{printf "  %s %5s%% %s\n", $2, $4, $11}'
}

# ===========================================================================
# CHECK: System Processes (via pgrep / systemctl)
# ===========================================================================
check_system_processes() {
    for proc in $CRITICAL_SYSTEM_PROCESSES; do
        local state="OK"
        local detail="Process <code>${proc}</code> is running"

        if ! pgrep -x "$proc" &>/dev/null; then
            # Fallback: check via systemctl for services like docker/sshd
            if systemctl is-active --quiet "$proc" 2>/dev/null; then
                state="OK"
            else
                state="CRITICAL"
                detail="Process <code>${proc}</code> is <b>NOT running</b>"
            fi
        fi

        check_state_change "proc_${proc}" "$state" "$detail"
    done
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
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "missing")

        case "$status" in
            running)
                state="OK"
                # Also check health if available
                local health
                health=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
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
        for candidate in /home/remcov/.npm-global/bin/pm2 /usr/local/bin/pm2 /usr/bin/pm2; do
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
    jlist=$("$pm2_bin" jlist 2>/dev/null) || jlist="[]"

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
    [[ "${ENABLE_DOCKER_CONTAINERS:-true}" == "true" ]] && check_docker_containers
    [[ "${ENABLE_PM2_PROCESSES:-true}" == "true" ]] && check_pm2_processes

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

        send_telegram "$full_message" || true
        log "INFO" "Alert dispatched to Telegram (${crit_count}C/${warn_count}W/${ok_count}OK)"
    else
        log "INFO" "No confirmed state changes detected -- no alerts sent"
    fi

    log "INFO" "--- Monitor run finished ---"
}

main "$@"
