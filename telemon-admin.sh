#!/usr/bin/env bash
# =============================================================================
# Telemon -- Administration Utility
# =============================================================================
# Backup, restore, and manage Telemon state and configuration.
# Usage: bash telemon-admin.sh <command> [options]
#
# Commands:
#   backup [path]     Create backup of config, state, and logs
#   restore <path>    Restore from backup
#   status            Show current status and health
#   reset-state       Reset alert state (forces fresh alerts)
#   validate          Validate configuration
#   digest            Send a health digest summary
#   logs [lines]      View recent logs (default: 50 lines)
#   fleet-status      Show fleet heartbeat overview table
#   help              Show this help message
# =============================================================================
set -euo pipefail

# Restrict file creation permissions (owner-only read/write)
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Load shared helpers
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load environment (wraps shared helper)
load_env() {
    load_telemon_env
}

# ---------------------------------------------------------------------------
# Backup command
# ---------------------------------------------------------------------------
cmd_backup() {
    local backup_path="${1:-${SCRIPT_DIR}/backups/telemon-backup-$(date +%Y%m%d-%H%M%S)}"
    
    echo "Creating backup at: $backup_path"
    if ! mkdir -m 700 -p "$backup_path" 2>/dev/null; then
        echo -e "${RED}ERROR: Failed to create backup directory: ${backup_path}${NC}"
        exit 1
    fi
    # Defense-in-depth: mkdir -p doesn't change perms on pre-existing dirs
    chmod 700 "$backup_path"
    
    # Backup configuration (contains secrets — restrict permissions)
    if [[ -f "$ENV_FILE" ]]; then
        if ! cp -p "$ENV_FILE" "$backup_path/" 2>/dev/null; then
            echo -e "${RED}ERROR: Failed to backup .env file${NC}"
            exit 1
        fi
        chmod 600 "$backup_path/.env"
        echo "  ✓ Configuration backed up"
    fi
    
    # Backup state and all related files
    # shellcheck disable=SC2046
    for file in $(get_state_file_variants true false false); do
        if [[ -f "$file" ]]; then
            if ! cp -p "$file" "$backup_path/" 2>/dev/null; then
                echo -e "${RED}ERROR: Failed to backup $(basename "$file")${NC}"
                exit 1
            fi
            echo "  ✓ $(basename "$file") backed up"
        fi
    done
    
    # Backup drift detection baseline directory
    local drift_baseline_dir="${STATE_FILE}.drift.baseline"
    if [[ -d "$drift_baseline_dir" ]]; then
        if cp -r "$drift_baseline_dir" "$backup_path/" 2>/dev/null; then
            echo "  ✓ Drift baseline directory backed up"
        else
            echo -e "${YELLOW}WARN: Failed to backup drift baseline directory${NC}"
        fi
    fi
    
    # Backup logs
    if [[ -f "$LOG_FILE" ]]; then
        if ! cp -p "$LOG_FILE" "$backup_path/" 2>/dev/null; then
            echo -e "${YELLOW}WARN: Failed to backup log file${NC}"
        else
            echo "  ✓ Log file backed up"
        fi
    fi
    
    if [[ -f "${SCRIPT_DIR}/telemon_cron.log" ]]; then
        cp -p "${SCRIPT_DIR}/telemon_cron.log" "$backup_path/" 2>/dev/null && \
            echo "  ✓ Cron log backed up"
    fi

    # Backup own heartbeat file (if file-based heartbeat is enabled)
    if [[ "${ENABLE_HEARTBEAT:-false}" == "true" ]] && [[ "${HEARTBEAT_MODE:-file}" == "file" ]]; then
        local hb_dir="${HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
        local server_label="${SERVER_LABEL:-$(hostname)}"
        # Sanitize label same way as telemon.sh (replace non-alnum with _)
        local sanitized_label
        sanitized_label=$(printf '%s' "$server_label" | tr -c 'a-zA-Z0-9_.-' '_')
        local hb_file="${hb_dir}/${sanitized_label}"
        if [[ -f "$hb_file" ]]; then
            if cp -p "$hb_file" "$backup_path/heartbeat_${sanitized_label}" 2>/dev/null; then
                echo "  ✓ Heartbeat file backed up"
            else
                echo -e "${YELLOW}WARN: Failed to backup heartbeat file${NC}"
            fi
        fi
    fi
    
    # Create metadata
    cat > "${backup_path}/META.txt" << EOF
Telemon Backup
==============
Created: $(date)
Hostname: $(hostname)
Version: $(get_telemon_version)
Source: ${SCRIPT_DIR}
EOF
    
    echo ""
    echo -e "${GREEN}Backup complete: ${backup_path}${NC}"
    echo "To restore: bash telemon-admin.sh restore ${backup_path}"

    # Optional: purge old backups if BACKUP_KEEP_COUNT is set
    local keep_count="${BACKUP_KEEP_COUNT:-}"
    if [[ -n "$keep_count" ]] && [[ "$keep_count" =~ ^[0-9]+$ ]] && [[ "$keep_count" -gt 0 ]]; then
        local backup_dir
        backup_dir=$(dirname "$backup_path")
        local old_backups
        old_backups=$(ls -dt "${backup_dir}"/telemon-backup-* 2>/dev/null | tail -n +$((keep_count + 1)))
        if [[ -n "$old_backups" ]]; then
            echo ""
            echo "Purging old backups (keeping ${keep_count}):"
            while IFS= read -r old_bk; do
                rm -rf "$old_bk"
                echo "  ✓ Removed: $(basename "$old_bk")"
            done <<< "$old_backups"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Restore command
# ---------------------------------------------------------------------------
cmd_restore() {
    local backup_path="$1"
    
    if [[ -z "$backup_path" ]]; then
        echo -e "${RED}ERROR: Backup path required.${NC}"
        echo "Usage: bash telemon-admin.sh restore <backup-path>"
        exit 1
    fi

    # Validate path: reject control characters
    if [[ "$backup_path" =~ [[:cntrl:]] ]]; then
        echo -e "${RED}ERROR: Invalid characters in backup path${NC}"
        exit 1
    fi

    # Resolve to absolute path and verify it exists
    if command -v realpath &>/dev/null; then
        backup_path=$(realpath "$backup_path" 2>/dev/null) || {
            echo -e "${RED}ERROR: Cannot resolve backup path: ${backup_path}${NC}"
            exit 1
        }
    else
        # Fallback for macOS / systems without realpath
        backup_path=$(cd "$backup_path" 2>/dev/null && pwd) || {
            echo -e "${RED}ERROR: Cannot resolve backup path: ${backup_path}${NC}"
            exit 1
        }
    fi
    
    if [[ ! -d "$backup_path" ]]; then
        echo -e "${RED}ERROR: Backup directory not found: ${backup_path}${NC}"
        exit 1
    fi
    
    echo "Restoring from: $backup_path"
    echo ""
    
    # Show metadata if available
    if [[ -f "${backup_path}/META.txt" ]]; then
        echo "Backup information:"
        cat "${backup_path}/META.txt"
        echo ""
    fi
    
    read -rp "Continue with restore? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        exit 0
    fi
    
    # Restore files (with symlink protection)
    if [[ -f "${backup_path}/.env" ]]; then
        # Validate syntax before restoring
        if ! bash -n "${backup_path}/.env" 2>/dev/null; then
            echo -e "${RED}ERROR: Backup .env has syntax errors — aborting restore${NC}"
            exit 1
        fi
        if [[ -L "$ENV_FILE" ]]; then
            echo -e "${RED}ERROR: $ENV_FILE is a symlink — refusing to restore (possible attack)${NC}"
            exit 1
        fi
        # Backup current config before overwriting
        if [[ -f "$ENV_FILE" ]]; then
            local backup_current="${ENV_FILE}.pre-restore.$(date +%Y%m%d-%H%M%S)"
            cp -p "$ENV_FILE" "$backup_current"
            chmod 600 "$backup_current"
            echo "  ✓ Current .env backed up to: $(basename "$backup_current")"
        fi
        cp -p "${backup_path}/.env" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        echo "  ✓ Configuration restored"
    fi
    
    # Restore state and all related files (with symlink protection)
    # shellcheck disable=SC2046
    for file in $(get_state_file_variants true false false); do
        local basename_file
        basename_file=$(basename "$file")
        if [[ -f "${backup_path}/${basename_file}" ]]; then
            if [[ -L "$file" ]]; then
                echo -e "${RED}ERROR: $file is a symlink — refusing to restore (possible attack)${NC}"
                exit 1
            fi
            # Validate main state file format (key=STATE:count per line)
            if [[ "$file" == "$STATE_FILE" ]]; then
                local invalid_lines=0
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    if [[ ! "$line" =~ ^[a-zA-Z0-9_.:-]+=(OK|WARNING|CRITICAL):[0-9]+$ ]]; then
                        invalid_lines=$((invalid_lines + 1))
                    fi
                done < "${backup_path}/${basename_file}"
                if [[ "$invalid_lines" -gt 0 ]]; then
                    echo -e "${YELLOW}WARN: State file has ${invalid_lines} line(s) with unexpected format${NC}"
                fi
            fi
            cp -p "${backup_path}/${basename_file}" "$file"
            echo "  ✓ ${basename_file} restored"
        fi
    done
    
    # Restore drift detection baseline directory
    local drift_basename="$(basename "$STATE_FILE").drift.baseline"
    if [[ -d "${backup_path}/${drift_basename}" ]]; then
        if [[ -L "${STATE_FILE}.drift.baseline" ]]; then
            echo -e "${RED}ERROR: ${STATE_FILE}.drift.baseline is a symlink — refusing to restore${NC}"
            exit 1
        fi
        cp -r "${backup_path}/${drift_basename}" "${STATE_FILE}.drift.baseline"
        echo "  ✓ drift.baseline restored"
    fi
    
    if [[ -f "${backup_path}/$(basename "$LOG_FILE")" ]]; then
        if [[ -L "$LOG_FILE" ]]; then
            echo -e "${RED}ERROR: $LOG_FILE is a symlink — refusing to restore${NC}"
            exit 1
        fi
        cp -p "${backup_path}/$(basename "$LOG_FILE")" "$LOG_FILE"
        echo "  ✓ Log file restored"
    fi
    
    echo ""
    echo -e "${GREEN}Restore complete!${NC}"
}

# ---------------------------------------------------------------------------
# Status command
# ---------------------------------------------------------------------------
cmd_status() {
    echo "Telemon Status"
    echo "=============="
    echo ""
    
    # Installation info
    echo -e "${BLUE}Installation:${NC}"
    echo "  Directory: ${SCRIPT_DIR}"
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        echo "  Version: $(get_telemon_version)"
    fi
    echo ""
    
    # Configuration status
    echo -e "${BLUE}Configuration:${NC}"
    if [[ -f "$ENV_FILE" ]]; then
        echo -e "  ${GREEN}✓ .env file exists${NC}"
        
        # Check Telegram credentials
        if grep -q 'TELEGRAM_BOT_TOKEN="your-bot-token' "$ENV_FILE" 2>/dev/null || \
           grep -q 'TELEGRAM_BOT_TOKEN=""' "$ENV_FILE" 2>/dev/null; then
            echo -e "  ${RED}✗ Telegram bot token not configured${NC}"
        else
            echo -e "  ${GREEN}✓ Telegram bot token configured${NC}"
        fi
    else
        echo -e "  ${RED}✗ .env file missing${NC}"
    fi
    echo ""
    
    # Cron status
    echo -e "${BLUE}Scheduler:${NC}"
    if crontab -l 2>/dev/null | grep -qF "telemon.sh"; then
        echo -e "  ${GREEN}✓ Cron job installed${NC}"
    else
        echo -e "  ${YELLOW}⚠ No cron job found${NC}"
    fi
    
    if command -v systemctl &>/dev/null; then
        if systemctl is-enabled telemon.timer &>/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ Systemd timer enabled${NC}"
        elif systemctl list-timers --all 2>/dev/null | grep -q telemon; then
            echo -e "  ${YELLOW}⚠ Systemd timer exists but not enabled${NC}"
        fi
    fi
    echo ""
    
    # State file
    echo -e "${BLUE}State:${NC}"
    if [[ -f "$STATE_FILE" ]]; then
        echo -e "  ${GREEN}✓ State file exists${NC}"
        echo "  Location: ${STATE_FILE}"
        
        # Count states
        local crit_count=0 warn_count=0 ok_count=0
        local parse_state=""
        while IFS='=' read -r key value; do
            [[ -z "$key" || -z "$value" ]] && continue
            parse_state="${value%%:*}"
            case "$parse_state" in
                CRITICAL) crit_count=$((crit_count + 1)) ;;
                WARNING) warn_count=$((warn_count + 1)) ;;
                OK) ok_count=$((ok_count + 1)) ;;
                *) ;; # Silently ignore unknown states
            esac
        done < "$STATE_FILE" || true
        
        echo "  Current status: ${crit_count} critical, ${warn_count} warning, ${ok_count} OK"
    else
        echo -e "  ${YELLOW}⚠ No state file (first run pending)${NC}"
    fi
    echo ""
    
    # Logs
    echo -e "${BLUE}Logs:${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
        echo "  Main log: ${LOG_FILE} ($(numfmt --to=iec "$log_size" 2>/dev/null || awk "BEGIN {s=$log_size; u=\"B\"; if(s>=1024){s/=1024;u=\"K\"} if(s>=1024){s/=1024;u=\"M\"} if(s>=1024){s/=1024;u=\"G\"} printf \"%.1f%s\",s,u}"))"
    fi
    if [[ -f "${SCRIPT_DIR}/telemon_cron.log" ]]; then
        echo "  Cron log: ${SCRIPT_DIR}/telemon_cron.log"
    fi
    echo ""

    # Heartbeat info
    echo -e "${BLUE}Heartbeat:${NC}"
    if [[ "${ENABLE_HEARTBEAT:-false}" == "true" ]]; then
        local hb_mode="${HEARTBEAT_MODE:-file}"
        echo -e "  ${GREEN}✓ Heartbeat enabled (${hb_mode} mode)${NC}"
        echo "  Server label: ${SERVER_LABEL:-$(hostname)}"
        if [[ "$hb_mode" == "file" ]]; then
            local hb_dir="${HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"
            local server_label="${SERVER_LABEL:-$(hostname)}"
            local sanitized_label
            sanitized_label=$(printf '%s' "$server_label" | tr -c 'a-zA-Z0-9_.-' '_')
            local hb_file="${hb_dir}/${sanitized_label}"
            if [[ -f "$hb_file" ]]; then
                local hb_ts
                hb_ts=$(cut -f2 "$hb_file" 2>/dev/null || echo "")
                if [[ "$hb_ts" =~ ^[0-9]+$ ]]; then
                    local hb_age=$(( $(date +%s) - hb_ts ))
                    echo "  Last heartbeat: $(( hb_age / 60 ))m ago"
                else
                    echo "  Last heartbeat: unknown format"
                fi
            else
                echo "  Last heartbeat: no heartbeat file yet"
            fi
        elif [[ "$hb_mode" == "webhook" ]]; then
            echo "  Webhook URL: ${HEARTBEAT_URL:-<not set>}"
        fi
    else
        echo -e "  ${YELLOW}⚠ Heartbeat disabled${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Reset state command
# ---------------------------------------------------------------------------
cmd_reset_state() {
    echo "Resetting Telemon state..."

    # Check if telemon.sh is currently running (lock file held)
    local lock_file="${STATE_FILE}.lock"
    local lock_dir="${lock_file}.d"
    local is_running=false
    local running_pid=""
    if [[ -d "$lock_dir" ]]; then
        running_pid=$(cat "${lock_dir}/pid" 2>/dev/null) || running_pid=""
        if [[ -n "$running_pid" ]] && kill -0 "$running_pid" 2>/dev/null; then
            is_running=true
        fi
    fi
    if [[ "$is_running" == "true" ]]; then
        echo -e "${YELLOW}WARNING: telemon.sh appears to be running (PID ${running_pid})${NC}"
        read -rp "Reset state anyway? This may cause inconsistencies. [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Reset cancelled."
            exit 0
        fi
    fi
    
    # Remove main state file and all related state variants
    # shellcheck disable=SC2046
    for file in $(get_state_file_variants true true false); do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            echo "  ✓ Removed: $(basename "$file")"
        fi
    done
    
    # Remove drift detection baseline directory
    local drift_baseline_dir="${STATE_FILE}.drift.baseline"
    if [[ -d "$drift_baseline_dir" ]]; then
        rm -rf "$drift_baseline_dir"
        echo "  ✓ Removed: drift.baseline"
    fi
    
    # Remove first-run fingerprint to trigger new bootstrap message
    local fingerprint_file="${SCRIPT_DIR}/.telemon_first_run_done"
    if [[ -f "$fingerprint_file" ]]; then
        rm -f "$fingerprint_file"
        echo "  ✓ Removed: first-run fingerprint"
    fi
    
    echo ""
    echo -e "${GREEN}State reset complete.${NC}"
    echo "Next run will treat all checks as new (bootstrap message will be sent)."
    echo ""
    echo "Note: Heartbeat files are NOT reset (they are shared/fleet-owned)."
    echo "To clear heartbeat files: rm -f ${FLEET_HEARTBEAT_DIR:-/tmp/telemon_heartbeats}/*"
}

# ---------------------------------------------------------------------------
# Validate command
# ---------------------------------------------------------------------------
cmd_validate() {
    echo "Validating Telemon configuration..."
    echo ""
    
    local errors=0
    
    # Check .env exists
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}✗ .env file not found${NC}"
        echo "  Run: cp .env.example .env"
        errors=$((errors + 1))
    else
        echo -e "${GREEN}✓ .env file exists${NC}"
        
        # Source it to check syntax
        if bash -n "$ENV_FILE" 2>/dev/null; then
            # shellcheck source=/dev/null
            source "$ENV_FILE"
            echo -e "${GREEN}✓ .env syntax is valid${NC}"
        else
            echo -e "${RED}✗ .env has syntax errors${NC}"
            errors=$((errors + 1))
        fi
        
        # Check required variables
        if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || \
           [[ "$TELEGRAM_BOT_TOKEN" == "your-bot-token-here" ]] || \
           [[ "$TELEGRAM_BOT_TOKEN" == "your-bot-token" ]]; then
            echo -e "${RED}✗ TELEGRAM_BOT_TOKEN not configured${NC}"
            errors=$((errors + 1))
        else
            echo -e "${GREEN}✓ TELEGRAM_BOT_TOKEN configured${NC}"
        fi
        
        if [[ -z "${TELEGRAM_CHAT_ID:-}" ]] || \
           [[ "$TELEGRAM_CHAT_ID" == "your-chat-id-here" ]] || \
           [[ "$TELEGRAM_CHAT_ID" == "your-chat-id" ]]; then
            echo -e "${RED}✗ TELEGRAM_CHAT_ID not configured${NC}"
            errors=$((errors + 1))
        else
            echo -e "${GREEN}✓ TELEGRAM_CHAT_ID configured${NC}"
        fi
    fi
    
    # Check main script
    if [[ -f "${SCRIPT_DIR}/telemon.sh" ]]; then
        if bash -n "${SCRIPT_DIR}/telemon.sh" 2>/dev/null; then
            echo -e "${GREEN}✓ telemon.sh syntax is valid${NC}"
        else
            echo -e "${RED}✗ telemon.sh has syntax errors${NC}"
            errors=$((errors + 1))
        fi
    else
        echo -e "${RED}✗ telemon.sh not found${NC}"
        errors=$((errors + 1))
    fi
    
    echo ""
    if [[ $errors -eq 0 ]]; then
        echo -e "${GREEN}Validation passed!${NC}"
        return 0
    else
        echo -e "${RED}Validation failed: ${errors} error(s) found${NC}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Logs command
# ---------------------------------------------------------------------------
cmd_logs() {
    local lines="${1:-50}"
    
    # Validate input is a positive integer
    if ! [[ "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -eq 0 ]]; then
        echo -e "${RED}ERROR: Invalid line count: '${lines}' (must be a positive integer)${NC}"
        exit 1
    fi

    # Cap at 10000 to prevent DoS on large log files
    local max_lines=10000
    if [[ "$lines" -gt "$max_lines" ]]; then
        echo -e "${YELLOW}WARN: Capping line count from ${lines} to ${max_lines}${NC}"
        lines="$max_lines"
    fi
    
    if [[ -f "$LOG_FILE" ]]; then
        echo "Last ${lines} lines of ${LOG_FILE}:"
        echo "---"
        tail -n "$lines" "$LOG_FILE"
    else
        echo -e "${YELLOW}Log file not found: ${LOG_FILE}${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Fleet status command
# ---------------------------------------------------------------------------
cmd_fleet_status() {
    local fleet_dir="${FLEET_HEARTBEAT_DIR:-/tmp/telemon_heartbeats}"

    echo "Fleet Status"
    echo "============"
    echo ""

    if [[ ! -d "$fleet_dir" ]]; then
        echo -e "${YELLOW}Fleet heartbeat directory not found: ${fleet_dir}${NC}"
        echo "Set FLEET_HEARTBEAT_DIR in .env or enable heartbeat sending."
        return 1
    fi

    # Collect fleet data into arrays for sorting
    local -a fleet_labels=() fleet_ages=() fleet_statuses=() fleet_checks=() fleet_issues=() fleet_sort_keys=()
    local now
    now=$(date +%s)
    local threshold_sec=$(( ${FLEET_STALE_THRESHOLD_MIN:-15} * 60 ))
    local crit_threshold_sec=$(( threshold_sec * ${FLEET_CRITICAL_MULTIPLIER:-2} ))
    local has_files=false

    for file in "$fleet_dir"/*; do
        [[ -f "$file" ]] || continue
        has_files=true
        local filename
        filename=$(basename "$file")

        local hb_label hb_timestamp hb_status hb_check_count hb_warn hb_crit hb_uptime
        IFS=$'\t' read -r hb_label hb_timestamp hb_status hb_check_count hb_warn hb_crit hb_uptime < "$file" 2>/dev/null || continue

        if ! [[ "$hb_timestamp" =~ ^[0-9]+$ ]]; then
            fleet_labels+=("$filename")
            fleet_ages+=("?")
            fleet_statuses+=("INVALID")
            fleet_checks+=("-")
            fleet_issues+=("-")
            fleet_sort_keys+=(0)
            continue
        fi

        local file_age_sec=$(( now - hb_timestamp ))
        local age_min=$(( file_age_sec / 60 ))
        local age_str="${age_min}m ago"

        local display_status="$hb_status"
        local sort_key=2  # default: OK
        if (( file_age_sec > crit_threshold_sec )); then
            display_status="SILENT"
            sort_key=0
        elif (( file_age_sec > threshold_sec )); then
            display_status="STALE"
            sort_key=1
        fi

        # Build issues summary from warn/crit counts
        local issues="-"
        local hb_warn_n="${hb_warn:-0}" hb_crit_n="${hb_crit:-0}"
        if [[ "$hb_crit_n" =~ ^[0-9]+$ ]] && (( hb_crit_n > 0 )) && [[ "$hb_warn_n" =~ ^[0-9]+$ ]] && (( hb_warn_n > 0 )); then
            issues="${hb_crit_n}C/${hb_warn_n}W"
        elif [[ "$hb_crit_n" =~ ^[0-9]+$ ]] && (( hb_crit_n > 0 )); then
            issues="${hb_crit_n}C"
        elif [[ "$hb_warn_n" =~ ^[0-9]+$ ]] && (( hb_warn_n > 0 )); then
            issues="${hb_warn_n}W"
        fi

        fleet_labels+=("${hb_label:-$filename}")
        fleet_ages+=("$age_str")
        fleet_statuses+=("$display_status")
        fleet_checks+=("${hb_check_count:-?}")
        fleet_issues+=("$issues")
        fleet_sort_keys+=("$sort_key")
    done

    if [[ "$has_files" != "true" ]]; then
        echo -e "${YELLOW}No heartbeat files found in: ${fleet_dir}${NC}"
        return 0
    fi

    # Print header
    printf "%-20s %-12s %-10s %-8s %s\n" "SERVER" "LAST SEEN" "STATUS" "CHECKS" "ISSUES"
    printf "%-20s %-12s %-10s %-8s %s\n" "------" "---------" "------" "------" "------"

    # Print sorted: SILENT/CRITICAL first (0), then STALE (1), then OK (2)
    local sort_order
    for sort_order in 0 1 2; do
        for idx in "${!fleet_sort_keys[@]}"; do
            [[ "${fleet_sort_keys[$idx]}" -ne "$sort_order" ]] && continue
            local color="$NC"
            case "${fleet_statuses[$idx]}" in
                SILENT|CRITICAL|INVALID) color="$RED" ;;
                STALE|WARNING)           color="$YELLOW" ;;
                OK)                      color="$GREEN" ;;
            esac
            printf "%b%-20s %-12s %-10s %-8s %s%b\n" \
                "$color" \
                "${fleet_labels[$idx]}" "${fleet_ages[$idx]}" "${fleet_statuses[$idx]}" \
                "${fleet_checks[$idx]}" "${fleet_issues[$idx]}" \
                "$NC"
        done
    done

    # Check for expected servers not seen
    if [[ -n "${FLEET_EXPECTED_SERVERS:-}" ]]; then
        local missing=""
        for expected in ${FLEET_EXPECTED_SERVERS}; do
            local found=false
            for label in "${fleet_labels[@]}"; do
                [[ "$label" == "$expected" ]] && found=true && break
            done
            if [[ "$found" != "true" ]]; then
                missing="${missing:+${missing}, }${expected}"
            fi
        done
        if [[ -n "$missing" ]]; then
            echo ""
            echo -e "${RED}Expected servers not seen: ${missing}${NC}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Discover command — Comprehensive Auto-discovery of services, hardware,
# infrastructure, and applications with smart defaults
# ---------------------------------------------------------------------------

# Helper: Check if a systemd service is active
_systemd_is_active() {
    local service="$1"
    systemctl is-active "$service" &>/dev/null
}

# Helper: Check if a command exists
_cmd_exists() {
    command -v "$1" &>/dev/null
}

# Helper: Get total system memory in GB for threshold calculations
_get_total_memory_gb() {
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    echo $((mem_kb / 1024 / 1024))
}

# Helper: Get CPU core count
_get_cpu_cores() {
    nproc 2>/dev/null || echo 1
}

# Helper: Generate smart thresholds based on system specs
generate_smart_thresholds() {
    local total_mem_gb
    total_mem_gb=$(_get_total_memory_gb)
    local cores
    cores=$(_get_cpu_cores)
    
    local thresholds=""
    thresholds+="# Smart Thresholds (based on system specs: ${total_mem_gb}GB RAM, ${cores} cores)"
    thresholds+=$'\n'
    
    # Memory thresholds based on total RAM
    # More RAM = lower threshold percentages (same absolute safety margin)
    if [[ "$total_mem_gb" -ge 32 ]]; then
        thresholds+="# High memory system - using generous thresholds"
        thresholds+=$'\n'
        thresholds+="MEM_THRESHOLD_WARN=10"
        thresholds+=$'\n'
        thresholds+="MEM_THRESHOLD_CRIT=5"
        thresholds+=$'\n'
    elif [[ "$total_mem_gb" -ge 16 ]]; then
        thresholds+="MEM_THRESHOLD_WARN=12"
        thresholds+=$'\n'
        thresholds+="MEM_THRESHOLD_CRIT=8"
        thresholds+=$'\n'
    else
        thresholds+="MEM_THRESHOLD_WARN=15"
        thresholds+=$'\n'
        thresholds+="MEM_THRESHOLD_CRIT=10"
        thresholds+=$'\n'
    fi
    
    # CPU thresholds based on core count
    # More cores = can handle higher load
    if [[ "$cores" -ge 16 ]]; then
        thresholds+="CPU_THRESHOLD_WARN=80"
        thresholds+=$'\n'
        thresholds+="CPU_THRESHOLD_CRIT=90"
        thresholds+=$'\n'
    elif [[ "$cores" -ge 8 ]]; then
        thresholds+="CPU_THRESHOLD_WARN=75"
        thresholds+=$'\n'
        thresholds+="CPU_THRESHOLD_CRIT=85"
        thresholds+=$'\n'
    else
        thresholds+="CPU_THRESHOLD_WARN=70"
        thresholds+=$'\n'
        thresholds+="CPU_THRESHOLD_CRIT=80"
        thresholds+=$'\n'
    fi
    
    thresholds+=$'\n'
    echo "$thresholds"
}

# Helper: Detect hardware components
detect_hardware() {
    local hw_info=""
    local hw_suggestions=""
    
    # NVMe Drives
    local nvme_drives=""
    if _cmd_exists nvme; then
        nvme_drives=$(nvme list 2>/dev/null | awk 'NR>2 && /^\/dev\// {print $1, $2, $3}' | head -10)
    elif _cmd_exists smartctl; then
        nvme_drives=$(smartctl --scan 2>/dev/null | grep -i nvme | awk '{print $1}' | while read -r dev; do
            model=$(smartctl -i "$dev" 2>/dev/null | grep -i "Model Number" | cut -d: -f2 | xargs)
            echo "$dev $model"
        done)
    fi
    
    if [[ -n "$nvme_drives" ]]; then
        local nvme_count
        nvme_count=$(echo "$nvme_drives" | wc -l)
        hw_info+="${GREEN}✓${NC} NVMe drives detected ($nvme_count):"
        hw_info+=$'\n'
        hw_info+=$(echo "$nvme_drives" | sed 's/^/  - /')
        hw_info+=$'\n\n'
        hw_suggestions+="# NVMe health monitoring"
        hw_suggestions+=$'\n'
        hw_suggestions+="ENABLE_NVME_CHECK=true"
        hw_suggestions+=$'\n'
        hw_suggestions+="# NVME_TEMP_THRESHOLD_WARN=70"
        hw_suggestions+=$'\n'
        hw_suggestions+="# NVME_TEMP_THRESHOLD_CRIT=80"
        hw_suggestions+=$'\n\n'
    fi
    
    # GPU Detection
    local has_nvidia=false
    local has_intel_gpu=false
    
    if _cmd_exists nvidia-smi; then
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        if [[ -n "$gpu_info" ]]; then
            hw_info+="${GREEN}✓${NC} NVIDIA GPU detected: $gpu_info"
            hw_info+=$'\n\n'
            has_nvidia=true
            hw_suggestions+="# NVIDIA GPU monitoring"
            hw_suggestions+=$'\n'
            hw_suggestions+="ENABLE_GPU_CHECK=true"
            hw_suggestions+=$'\n'
            hw_suggestions+="# GPU_TEMP_THRESHOLD_WARN=80"
            hw_suggestions+=$'\n'
            hw_suggestions+="# GPU_TEMP_THRESHOLD_CRIT=95"
            hw_suggestions+=$'\n\n'
        fi
    fi
    
    # Intel GPU detection via vendor ID or intel_gpu_top
    if _cmd_exists intel_gpu_top || [[ -d /sys/class/drm/card0/device ]] && grep -q "0x8086" /sys/class/drm/card*/device/vendor 2>/dev/null; then
        hw_info+="${GREEN}✓${NC} Intel GPU detected"
        hw_info+=$'\n\n'
        has_intel_gpu=true
        if [[ "$has_nvidia" == "false" ]]; then
            hw_suggestions+="# Intel GPU monitoring (requires intel-gpu-tools)"
            hw_suggestions+=$'\n'
            hw_suggestions+="# ENABLE_GPU_CHECK=true"
            hw_suggestions+=$'\n\n'
        fi
    fi
    
    # UPS/Battery Detection
    local has_ups=false
    
    if _systemd_is_active apcupsd; then
        hw_info+="${GREEN}✓${NC} APC UPS detected (apcupsd)"
        hw_info+=$'\n\n'
        has_ups=true
    elif _cmd_exists apcaccess && [[ -f /etc/apcupsd/apcupsd.conf ]]; then
        hw_info+="${GREEN}✓${NC} APC UPS configuration found"
        hw_info+=$'\n\n'
        has_ups=true
    fi
    
    if _systemd_is_active nut-server || _systemd_is_active nut-client; then
        hw_info+="${GREEN}✓${NC} NUT UPS detected"
        hw_info+=$'\n\n'
        has_ups=true
    elif _cmd_exists upsc; then
        hw_info+="${GREEN}✓${NC} NUT (Network UPS Tools) available"
        hw_info+=$'\n\n'
        has_ups=true
    fi
    
    if _cmd_exists upower; then
        local batteries
        batteries=$(upower -e 2>/dev/null | grep -i battery | head -3)
        if [[ -n "$batteries" ]]; then
            hw_info+="${GREEN}✓${NC} Battery/UPS detected via upower"
            hw_info+=$'\n'
            hw_info+=$(echo "$batteries" | sed 's/^/  - /')
            hw_info+=$'\n\n'
            has_ups=true
        fi
    fi
    
    if [[ "$has_ups" == "true" ]]; then
        hw_suggestions+="# UPS/Battery monitoring"
        hw_suggestions+=$'\n'
        hw_suggestions+="ENABLE_UPS_CHECK=true"
        hw_suggestions+=$'\n'
        hw_suggestions+="# UPS_THRESHOLD_WARN=30"
        hw_suggestions+=$'\n'
        hw_suggestions+="# UPS_THRESHOLD_CRIT=10"
        hw_suggestions+=$'\n\n'
    fi
    
    # CPU Temperature / Sensors
    if _cmd_exists sensors; then
        local sensor_chips
        sensor_chips=$(sensors -u 2>/dev/null | grep -E '^[a-zA-Z]+-i2c' | head -5)
        if [[ -n "$sensor_chips" ]]; then
            hw_info+="${GREEN}✓${NC} lm-sensors configured"
            hw_info+=$'\n'
            hw_info+=$(echo "$sensor_chips" | sed 's/^/  - /')
            hw_info+=$'\n\n'
            hw_suggestions+="# CPU temperature monitoring"
            hw_suggestions+=$'\n'
            hw_suggestions+="ENABLE_TEMP_CHECK=true"
            hw_suggestions+=$'\n'
            hw_suggestions+="# TEMP_THRESHOLD_WARN=75"
            hw_suggestions+=$'\n'
            hw_suggestions+="# TEMP_THRESHOLD_CRIT=90"
            hw_suggestions+=$'\n\n'
        fi
    fi
    
    # RAID Detection
    local has_raid=false
    
    # mdadm software RAID
    if [[ -f /proc/mdstat ]] && grep -q "md[0-9]" /proc/mdstat 2>/dev/null; then
        local md_devices
        md_devices=$(grep "^md" /proc/mdstat | awk '{print $1}')
        hw_info+="${GREEN}✓${NC} Software RAID (mdadm) detected:"
        hw_info+=$'\n'
        hw_info+=$(echo "$md_devices" | sed 's/^/  - /')
        hw_info+=$'\n\n'
        has_raid=true
    fi
    
    # LVM
    if _cmd_exists pvs && pvs &>/dev/null; then
        local vg_count
        vg_count=$(vgs --noheadings 2>/dev/null | wc -l)
        if [[ "$vg_count" -gt 0 ]]; then
            hw_info+="${GREEN}✓${NC} LVM configured ($vg_count volume groups)"
            hw_info+=$'\n\n'
        fi
    fi
    
    # ZFS
    if _cmd_exists zpool; then
        local zfs_pools
        zfs_pools=$(zpool list -H 2>/dev/null | awk '{print $1}')
        if [[ -n "$zfs_pools" ]]; then
            hw_info+="${GREEN}✓${NC} ZFS pools detected:"
            hw_info+=$'\n'
            hw_info+=$(echo "$zfs_pools" | sed 's/^/  - /')
            hw_info+=$'\n\n'
        fi
    fi
    
    echo -e "$hw_info"
    echo "$hw_suggestions"
}

# Helper: Detect virtualization and container platforms
detect_infrastructure() {
    local infra_info=""
    local infra_suggestions=""
    
    # Docker Swarm
    if _cmd_exists docker; then
        local swarm_state
        swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "")
        if [[ "$swarm_state" == "active" ]]; then
            local swarm_role
            swarm_role=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)
            if [[ "$swarm_role" == "true" ]]; then
                infra_info+="${GREEN}✓${NC} Docker Swarm (manager node)"
            else
                infra_info+="${GREEN}✓${NC} Docker Swarm (worker node)"
            fi
            infra_info+=$'\n\n'
        fi
        
        # Check for common container images that indicate specific apps
        local all_containers
        all_containers=$(docker ps --format '{{.Image}}' 2>/dev/null | tr ':/' ' ' | awk '{print $1}')
        
        # Traefik detection
        if echo "$all_containers" | grep -qi "traefik"; then
            infra_info+="${GREEN}✓${NC} Traefik reverse proxy detected"
            infra_info+=$'\n\n'
        fi
    fi
    
    # Kubernetes
    if _cmd_exists kubectl; then
        local k8s_context
        k8s_context=$(kubectl config current-context 2>/dev/null || echo "")
        if [[ -n "$k8s_context" ]]; then
            local k8s_nodes
            k8s_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
            infra_info+="${GREEN}✓${NC} Kubernetes cluster detected ($k8s_nodes nodes, context: $k8s_context)"
            infra_info+=$'\n\n'
            infra_suggestions+="# Note: Kubernetes monitoring requires additional configuration"
            infra_suggestions+=$'\n'
            infra_suggestions+="# Consider using node-exporter or k8s-specific monitoring"
            infra_suggestions+=$'\n\n'
        fi
    fi
    
    # Proxmox VE
    if [[ -f /etc/pve/status.cfg ]] || _cmd_exists pveversion; then
        local pve_ver
        pve_ver=$(pveversion 2>/dev/null || echo "Proxmox VE")
        infra_info+="${GREEN}✓${NC} Proxmox VE detected: $pve_ver"
        infra_info+=$'\n'

        # Discover VMs
        if _cmd_exists qm; then
            local vm_count vm_running vm_stopped
            vm_count=$(qm list 2>/dev/null | tail -n +2 | wc -l || echo "0")
            vm_running=$(qm list 2>/dev/null | grep -c "running" || echo "0")
            vm_stopped=$((vm_count - vm_running))
            if [[ "$vm_count" -gt 0 ]]; then
                infra_info+="  ${GREEN}✓${NC} Virtual machines: $vm_count total ($vm_running running, $vm_stopped stopped)"
                infra_info+=$'\n'

                # Generate guest list suggestion
                local vm_ids
                vm_ids=$(qm list 2>/dev/null | awk 'NR>1 {print "vm:"$1}' | tr '\n' ' ')
                if [[ -n "$vm_ids" ]]; then
                    infra_suggestions+="# Proxmox VE guest monitoring"
                    infra_suggestions+=$'\n'
                    infra_suggestions+="ENABLE_PROXMOX_GUESTS=true"
                    infra_suggestions+=$'\n'
                    infra_suggestions+="CRITICAL_PROXMOX_GUESTS=\"$vm_ids"
                fi
            fi
        fi

        # Discover LXCs
        if _cmd_exists pct; then
            local ct_count ct_running ct_stopped
            ct_count=$(pct list 2>/dev/null | tail -n +2 | wc -l || echo "0")
            ct_running=$(pct list 2>/dev/null | grep -c "running" || echo "0")
            ct_stopped=$((ct_count - ct_running))
            if [[ "$ct_count" -gt 0 ]]; then
                infra_info+="  ${GREEN}✓${NC} Linux containers: $ct_count total ($ct_running running, $ct_stopped stopped)"
                infra_info+=$'\n'

                local ct_ids
                ct_ids=$(pct list 2>/dev/null | awk 'NR>1 {print "ct:"$1}' | tr '\n' ' ')
                infra_suggestions+=" $ct_ids\""
                infra_suggestions+=$'\n'
                infra_suggestions+="# Leave empty to auto-discover all guests, or customize:"
                infra_suggestions+=$'\n'
                infra_suggestions+="# CRITICAL_PROXMOX_GUESTS=\"vm:100 ct:101 vm:201\""
                infra_suggestions+=$'\n\n'
            fi
        fi

        # Discover storage pools
        if _cmd_exists pvesm; then
            local pool_count
            pool_count=$(pvesm status 2>/dev/null | tail -n +2 | wc -l || echo "0")
            if [[ "$pool_count" -gt 0 ]]; then
                infra_info+="  ${GREEN}✓${NC} Storage pools: $pool_count"
                infra_info+=$'\n'
                infra_suggestions+="# Proxmox storage monitoring"
                infra_suggestions+=$'\n'
                infra_suggestions+="ENABLE_PROXMOX_STORAGE=true"
                infra_suggestions+=$'\n'
                infra_suggestions+="PROXMOX_STORAGE_WARN=85"
                infra_suggestions+=$'\n'
                infra_suggestions+="PROXMOX_STORAGE_CRIT=95"
                infra_suggestions+=$'\n\n'
            fi
        fi

        # Check for cluster configuration
        if [[ -f /etc/pve/corosync.conf ]]; then
            infra_info+="  ${GREEN}✓${NC} Cluster configured"
            infra_info+=$'\n'
            infra_suggestions+="# Proxmox cluster monitoring"
            infra_suggestions+=$'\n'
            infra_suggestions+="ENABLE_PROXMOX_CLUSTER=true"
            infra_suggestions+=$'\n\n'
        else
            infra_info+="  ${NC}  Standalone node (no cluster)"
            infra_info+=$'\n'
        fi

        # Task monitoring
        if _cmd_exists pvesh; then
            infra_suggestions+="# Proxmox task monitoring"
            infra_suggestions+=$'\n'
            infra_suggestions+="ENABLE_PROXMOX_TASKS=true"
            infra_suggestions+=$'\n'
            infra_suggestions+="PROXMOX_TASK_MINUTES=60"
            infra_suggestions+=$'\n\n'
        fi

        infra_info+=$'\n'
    fi
    
    # KVM/QEMU
    if _cmd_exists virsh; then
        local vm_count
        vm_count=$(virsh list --all 2>/dev/null | grep -c "running" || echo 0)
        if [[ "$vm_count" -gt 0 ]]; then
            infra_info+="${GREEN}✓${NC} KVM/QEMU virtual machines: $vm_count running"
            infra_info+=$'\n\n'
        fi
    fi
    
    # VMware tools
    if _systemd_is_active vmtoolsd || [[ -f /etc/vmware-tools/tools.conf ]]; then
        infra_info+="${GREEN}✓${NC} VMware Tools detected (running in VMware VM)"
        infra_info+=$'\n\n'
    fi
    
    # NFS mounts
    local nfs_mounts
    nfs_mounts=$(mount | grep -E '^.* on .* type nfs' | awk '{print $3}' || true)
    if [[ -n "$nfs_mounts" ]]; then
        local nfs_count
        nfs_count=$(echo "$nfs_mounts" | wc -l)
        infra_info+="${GREEN}✓${NC} NFS mounts detected ($nfs_count):"
        infra_info+=$'\n'
        infra_info+=$(echo "$nfs_mounts" | head -5 | sed 's/^/  - /')
        infra_info+=$'\n\n'
    fi
    
    # SMB/CIFS mounts
    local cifs_mounts
    cifs_mounts=$(mount | grep -E '^.* on .* type cifs' | awk '{print $3}' || true)
    if [[ -n "$cifs_mounts" ]]; then
        local cifs_count
        cifs_count=$(echo "$cifs_mounts" | wc -l)
        infra_info+="${GREEN}✓${NC} SMB/CIFS mounts detected ($cifs_count):"
        infra_info+=$'\n'
        infra_info+=$(echo "$cifs_mounts" | head -5 | sed 's/^/  - /')
        infra_info+=$'\n\n'
    fi
    
    # Network infrastructure
    # WireGuard
    if _cmd_exists wg || [[ -d /etc/wireguard ]]; then
        local wg_interfaces
        wg_interfaces=$(wg show interfaces 2>/dev/null || true)
        if [[ -n "$wg_interfaces" ]]; then
            infra_info+="${GREEN}✓${NC} WireGuard VPN interfaces:"
            infra_info+=$'\n'
            infra_info+=$(echo "$wg_interfaces" | tr ' ' '\n' | sed 's/^/  - /')
            infra_info+=$'\n\n'
        fi
    fi
    
    # Tailscale
    if _cmd_exists tailscale; then
        local tailscale_status
        tailscale_status=$(tailscale status --json 2>/dev/null | grep -q '"Self"' && echo "active" || echo "")
        if [[ -n "$tailscale_status" ]]; then
            infra_info+="${GREEN}✓${NC} Tailscale VPN connected"
            infra_info+=$'\n\n'
        fi
    fi
    
    # HAProxy
    if _systemd_is_active haproxy; then
        infra_info+="${GREEN}✓${NC} HAProxy load balancer active"
        infra_info+=$'\n\n'
    fi
    
    echo -e "$infra_info"
    echo "$infra_suggestions"
}

# Helper: Detect application services
detect_applications() {
    local app_info=""
    local app_suggestions=""
    
    # RabbitMQ
    if _systemd_is_active rabbitmq-server || ss -tlnp 2>/dev/null | grep -q ":5672"; then
        app_info+="${GREEN}✓${NC} RabbitMQ detected"
        app_info+=$'\n\n'
    fi
    
    # Mosquitto MQTT
    if _systemd_is_active mosquitto || ss -tlnp 2>/dev/null | grep -q ":1883"; then
        app_info+="${GREEN}✓${NC} Mosquitto MQTT broker detected"
        app_info+=$'\n\n'
    fi
    
    # Fail2ban
    if _systemd_is_active fail2ban; then
        local banned_count
        banned_count=$(fail2ban-client status 2>/dev/null | grep "Currently banned:" | head -1 | awk '{print $3}' || echo "?")
        app_info+="${GREEN}✓${NC} Fail2ban active (currently banned: $banned_count)"
        app_info+=$'\n\n'
        app_suggestions+="# Security monitoring"
        app_suggestions+=$'\n'
        app_suggestions+="# Consider monitoring fail2ban log: /var/log/fail2ban.log"
        app_suggestions+=$'\n'
        app_suggestions+="# ENABLE_LOG_CHECK=true"
        app_suggestions+=$'\n'
        app_suggestions+="# LOG_WATCH_FILES=\"/var/log/fail2ban.log\""
        app_suggestions+=$'\n'
        app_suggestions+="# LOG_PATTERNS=\"BAN|ERROR|WARNING\""
        app_suggestions+=$'\n\n'
    fi
    
    # CrowdSec
    if _systemd_is_active crowdsec || _cmd_exists cscli; then
        local cs_alerts
        cs_alerts=$(cscli alerts list 2>/dev/null | grep -c "^\│" 2>/dev/null || echo "?")
        app_info+="${GREEN}✓${NC} CrowdSec active (alerts: $cs_alerts)"
        app_info+=$'\n\n'
    fi
    
    # Elasticsearch
    if ss -tlnp 2>/dev/null | grep -q ":9200"; then
        app_info+="${GREEN}✓${NC} Elasticsearch detected (port 9200)"
        app_info+=$'\n\n'
    fi
    
    # MongoDB
    if _systemd_is_active mongod || ss -tlnp 2>/dev/null | grep -q ":27017"; then
        app_info+="${GREEN}✓${NC} MongoDB detected"
        app_info+=$'\n\n'
    fi
    
    # InfluxDB
    if _systemd_is_active influxdb || ss -tlnp 2>/dev/null | grep -q ":8086"; then
        app_info+="${GREEN}✓${NC} InfluxDB detected"
        app_info+=$'\n\n'
    fi
    
    echo -e "$app_info"
    echo "$app_suggestions"
}

# Helper: Detect actually-running database servers
detect_database_servers() {
    local db_info=""
    local db_suggestions=""
    local has_running_db=false
    
    # MySQL/MariaDB Server
    if _systemd_is_active mysqld || _systemd_is_active mysql || _systemd_is_active mariadb; then
        db_info+="${GREEN}✓${NC} MySQL/MariaDB server running"
        db_info+=$'\n\n'
        has_running_db=true
        db_suggestions+="# MySQL/MariaDB (detected running)"
        db_suggestions+=$'\n'
        db_suggestions+="DB_MYSQL_HOST=\"localhost\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_MYSQL_PORT=\"3306\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_MYSQL_USER=\"telemon\""
        db_suggestions+=$'\n'
        db_suggestions+="# DB_MYSQL_PASS=\"your-secure-password\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_MYSQL_TIMEOUT=5"
        db_suggestions+=$'\n\n'
    fi
    
    # PostgreSQL Server
    if _systemd_is_active postgresql || _systemd_is_active "postgres*" 2>/dev/null; then
        # Get the specific version service
        local pg_service
        pg_service=$(systemctl list-units --type=service --state=running | grep -oE 'postgresql-[0-9]+\.[0-9]+' | head -1 || echo "postgresql")
        db_info+="${GREEN}✓${NC} PostgreSQL server running ($pg_service)"
        db_info+=$'\n\n'
        has_running_db=true
        db_suggestions+="# PostgreSQL (detected running)"
        db_suggestions+=$'\n'
        db_suggestions+="DB_POSTGRES_HOST=\"localhost\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_POSTGRES_PORT=\"5432\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_POSTGRES_USER=\"telemon\""
        db_suggestions+=$'\n'
        db_suggestions+="# DB_POSTGRES_PASS=\"your-secure-password\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_POSTGRES_TIMEOUT=5"
        db_suggestions+=$'\n\n'
    fi
    
    # Redis Server
    if _systemd_is_active redis-server || _systemd_is_active redis; then
        db_info+="${GREEN}✓${NC} Redis server running"
        db_info+=$'\n\n'
        has_running_db=true
        db_suggestions+="# Redis (detected running)"
        db_suggestions+=$'\n'
        db_suggestions+="DB_REDIS_HOST=\"localhost\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_REDIS_PORT=\"6379\""
        db_suggestions+=$'\n'
        db_suggestions+="# DB_REDIS_PASS=\"your-secure-password\""
        db_suggestions+=$'\n'
        db_suggestions+="DB_REDIS_TIMEOUT=5"
        db_suggestions+=$'\n\n'
    fi
    
    # Check for databases in Docker containers
    if _cmd_exists docker; then
        local db_containers
        db_containers=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -iE 'mysql|postgres|redis|mongo|mariadb' || true)
        if [[ -n "$db_containers" ]]; then
            db_info+="${GREEN}✓${NC} Database containers running:"
            db_info+=$'\n'
            db_info+=$(echo "$db_containers" | awk '{print "  - " $1 " (" $2 ")"}')
            db_info+=$'\n\n'
            if [[ "$has_running_db" == "false" ]]; then
                db_suggestions+="# Database containers detected - configure host ports for monitoring"
                db_suggestions+=$'\n'
                db_suggestions+="# Example: map container ports and monitor localhost:PORT"
                db_suggestions+=$'\n\n'
            fi
        fi
    fi
    
    # SQLite3 availability (always available if command exists)
    if _cmd_exists sqlite3; then
        db_info+="${GREEN}✓${NC} SQLite3 available"
        db_info+=$'\n\n'
        if [[ "$has_running_db" == "false" ]]; then
            db_suggestions+="# SQLite3 - uncomment to monitor specific databases"
            db_suggestions+=$'\n'
            db_suggestions+="# DB_SQLITE_PATHS=\"/var/lib/app/data.db /opt/other/stats.db\""
            db_suggestions+=$'\n'
            db_suggestions+="# DB_SQLITE_SIZE_THRESHOLD_WARN=500"
            db_suggestions+=$'\n'
            db_suggestions+="# DB_SQLITE_SIZE_THRESHOLD_CRIT=1000"
            db_suggestions+=$'\n\n'
        fi
    fi
    
    if [[ "$has_running_db" == "true" ]]; then
        db_suggestions+="# Enable database health checks"
        db_suggestions+=$'\n'
        db_suggestions+="ENABLE_DATABASE_CHECKS=true"
        db_suggestions+=$'\n\n'
    fi
    
    echo -e "$db_info"
    echo "$db_suggestions"
}

cmd_discover() {
    echo "Telemon Auto-Discovery"
    echo "======================"
    echo ""
    echo "Scanning for hardware, services, and infrastructure..."
    echo ""
    
    local suggestions=""
    local has_docker=false
    local has_pm2=false
    local has_nginx=false
    local has_apache=false
    local has_systemd_services=false
    local containers=""
    
    # ============================================
    # HARDWARE SECTION
    # ============================================
    echo -e "${BLUE}=== Hardware ===${NC}"
    echo ""
    local hw_output
    hw_output=$(detect_hardware)
    local hw_suggestions
    hw_suggestions=$(echo "$hw_output" | grep -A 1000 "^ENABLE_\|^#" || true)
    # Print only the info part (lines before suggestions)
    echo -e "$(echo "$hw_output" | grep -B 1000 "^ENABLE_" | head -n -1 || echo "$hw_output")"
    suggestions+="$hw_suggestions"
    
    # ============================================
    # INFRASTRUCTURE SECTION
    # ============================================
    echo -e "${BLUE}=== Infrastructure ===${NC}"
    echo ""
    local infra_output
    infra_output=$(detect_infrastructure)
    echo -e "$infra_output"
    
    # ============================================
    # CORE SERVICES SECTION
    # ============================================
    echo -e "${BLUE}=== Core Services ===${NC}"
    echo ""
    
    # Check for Docker containers
    if _cmd_exists docker; then
        containers=$(docker ps --format '{{.Names}}' 2>/dev/null | sort)
        if [[ -n "$containers" ]]; then
            has_docker=true
            echo -e "${GREEN}✓${NC} Docker containers found:"
            echo "$containers" | sed 's/^/  - /'
            echo ""
            
            suggestions+="# Docker containers"
            suggestions+=$'\n'
            suggestions+="ENABLE_DOCKER_CONTAINERS=true"
            suggestions+=$'\n'
            suggestions+="CRITICAL_CONTAINERS=\"${containers//$'\n'/ }\""
            suggestions+=$'\n\n'
        fi
    fi
    
    # Check for PM2 processes
    if _cmd_exists pm2; then
        local pm2_procs
        pm2_procs=$(pm2 jlist 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    names = [p.get('name', '') for p in data if p.get('name')]
    print(' '.join(names))
except Exception:
    pass
" 2>/dev/null)
        if [[ -n "$pm2_procs" ]]; then
            has_pm2=true
            echo -e "${GREEN}✓${NC} PM2 processes found:"
            for proc in $pm2_procs; do
                echo "  - $proc"
            done
            echo ""
            
            suggestions+="# PM2 processes"
            suggestions+=$'\n'
            suggestions+="ENABLE_PM2_PROCESSES=true"
            suggestions+=$'\n'
            suggestions+="CRITICAL_PM2_PROCESSES=\"${pm2_procs}\""
            suggestions+=$'\n\n'
        fi
    fi
    
    # Check for web servers
    if _cmd_exists nginx || _systemd_is_active nginx; then
        has_nginx=true
        echo -e "${GREEN}✓${NC} Nginx web server active"
        echo ""
    fi
    
    if _cmd_exists apache2 || _systemd_is_active apache2 || _systemd_is_active httpd; then
        has_apache=true
        echo -e "${GREEN}✓${NC} Apache web server active"
        echo ""
    fi
    
    # ============================================
    # DATABASE SERVERS SECTION (Enhanced)
    # ============================================
    echo -e "${BLUE}=== Databases ===${NC}"
    echo ""
    local db_output
    db_output=$(detect_database_servers)
    local db_suggestions
    db_suggestions=$(detect_database_servers | grep -A 1000 "^ENABLE_\|^#" | head -100 || true)
    # Print info part only
    echo -e "$(echo "$db_output" | grep -B 1000 "^DB_\|^ENABLE_" | grep -v "^DB_\|^ENABLE_" | head -n -1 || echo "$db_output")"
    suggestions+="$db_suggestions"
    
    # ============================================
    # NETWORK & PORTS SECTION
    # ============================================
    if _cmd_exists ss; then
        local listening_ports
        listening_ports=$(ss -tlnp 2>/dev/null | awk 'NR>1 && /LISTEN/ {
            port = $4
            gsub(/.*:/, "", port)
            proc = $0
            gsub(/.*users:/, "", proc)
            gsub(/\\)/, "", proc)
            if (proc != $0) print port, proc
        }' | sort -u -k1,1n | head -15)
        if [[ -n "$listening_ports" ]]; then
            echo -e "${BLUE}=== Network Ports ===${NC}"
            echo ""
            echo -e "${GREEN}✓${NC} Key listening ports:"
            echo "  Port  | Process"
            echo "$listening_ports" | head -10 | while read -r port proc; do
                printf "  %-5s | %s\n" "$port" "$proc"
            done
            echo ""
            
            suggestions+="# TCP Port monitoring (review and customize)"
            suggestions+=$'\n'
            suggestions+="# ENABLE_TCP_PORT_CHECK=true"
            suggestions+=$'\n'
            suggestions+="# CRITICAL_PORTS=\"localhost:22 localhost:80\""
            suggestions+=$'\n\n'
        fi
    fi
    
    # ============================================
    # APPLICATION SERVICES SECTION
    # ============================================
    local app_output
    app_output=$(detect_applications)
    if [[ -n "$app_output" ]]; then
        echo -e "${BLUE}=== Application Services ===${NC}"
        echo ""
        echo -e "$app_output"
        local app_suggestions
        app_suggestions=$(detect_applications | grep -A 1000 "^ENABLE_\|^#" || true)
        suggestions+="$app_suggestions"
    fi
    
    # ============================================
    # SYSTEMD SERVICES & CRON DETECTION
    # ============================================
    if _cmd_exists systemctl; then
        local active_services
        active_services=$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | \
            awk '{print $1}' | grep -E '^(ssh|cron|crond|cronie|anacron|systemd-cron|nginx|apache|httpd|mysql|postgres|redis|fail2ban)' || true)
        
        # Also check for systemd timers (modern cron replacement)
        local active_timers
        active_timers=$(systemctl list-timers --no-legend --plain 2>/dev/null | awk 'NR>0 {print $NF}' | grep -v "n/a" | head -5 || true)
        local has_timers=false
        if [[ -n "$active_timers" ]]; then
            has_timers=true
        fi
        
        if [[ -n "$active_services" ]] || [[ "$has_timers" == "true" ]]; then
            echo -e "${BLUE}=== Systemd Services ===${NC}"
            echo ""
            
            if [[ -n "$active_services" ]]; then
                echo -e "${GREEN}✓${NC} Key active services:"
                echo "$active_services" | sed 's/^/  - /'
                echo ""
            fi
            
            if [[ "$has_timers" == "true" ]]; then
                echo -e "${GREEN}✓${NC} Systemd timers active (cron alternative):"
                echo "$active_timers" | sed 's/^/  - /'
                echo ""
            fi
            
            # Build critical processes list based on what was detected
            local critical_procs="sshd"
            local has_cron=false
            
            if echo "$active_services" | grep -qE '^(cron|crond|cronie|anacron|systemd-cron)'; then
                has_cron=true
                # Add the specific cron service name found
                local cron_service
                cron_service=$(echo "$active_services" | grep -E '^(cron|crond|cronie|anacron|systemd-cron)' | head -1)
                critical_procs="${critical_procs} ${cron_service%.service}"
            fi
            
            suggestions+="# Systemd service monitoring"
            suggestions+=$'\n'
            suggestions+="ENABLE_FAILED_SYSTEMD_SERVICES=true"
            suggestions+=$'\n'
            suggestions+="CRITICAL_SYSTEM_PROCESSES=\"${critical_procs}\""
            suggestions+=$'\n'
            
            if [[ "$has_timers" == "true" ]] && [[ "$has_cron" == "false" ]]; then
                suggestions+="# Note: System uses systemd timers instead of traditional cron"
                suggestions+=$'\n'
                suggestions+="# Consider monitoring timer-triggered services if needed"
                suggestions+=$'\n'
            fi
            
            suggestions+=$'\n'
        fi
    fi
    
    # ============================================
    # SMART THRESHOLDS
    # ============================================
    echo -e "${BLUE}=== Smart Thresholds ===${NC}"
    echo ""
    local smart_thresholds
    smart_thresholds=$(generate_smart_thresholds)
    echo -e "${GREEN}✓${NC} Thresholds suggested based on system specs"
    echo ""
    suggestions+="$smart_thresholds"
    suggestions+=$'\n'
    
    # ============================================
    # SITE MONITORING SUGGESTION
    # ============================================
    local has_local_web=false
    if [[ "$has_nginx" == "true" || "$has_apache" == "true" ]]; then
        has_local_web=true
    fi
    # Check for common container web ports
    if [[ -n "$containers" ]]; then
        local web_ports
        web_ports=$(ss -tlnp 2>/dev/null | grep -E ':(80|8080|32400|3000|5000|8000|9000)' || true)
        if [[ -n "$web_ports" ]]; then
            has_local_web=true
        fi
    fi
    
    if [[ "$has_local_web" == "true" ]]; then
        suggestions+="# Site monitoring (local services detected)"
        suggestions+=$'\n'
        suggestions+="# For localhost monitoring, set: SITE_ALLOW_INTERNAL=true"
        suggestions+=$'\n'
        suggestions+="ENABLE_SITE_MONITOR=true"
        suggestions+=$'\n'
        suggestions+="# CRITICAL_SITES=\"http://localhost:8080|max_response_ms=5000\""
        suggestions+=$'\n\n'
    fi
    
    # ============================================
    # OUTPUT SUGGESTIONS
    # ============================================
    echo ""
    echo "==============================================="
    echo "Suggested Configuration"
    echo "==============================================="
    echo ""
    echo "Add the following to your .env file:"
    echo ""
    echo "# ============================================="
    echo "# Auto-discovered settings ($(date +%Y-%m-%d))"
    echo "# Generated by: telemon-admin.sh discover"
    echo "# ============================================="
    echo ""
    
    if [[ -n "$suggestions" ]]; then
        echo "$suggestions"
    else
        echo "# No services auto-detected."
        echo "# Consider manually configuring checks for your environment."
    fi
    
    echo ""
    echo "==============================================="
    echo ""
    echo "Usage:"
    echo "  1. Review the suggested configuration above"
    echo "  2. Copy relevant lines to your .env file"
    echo "  3. Set credentials for database connections"
    echo "  4. Run: bash telemon.sh --validate"
    echo "  5. Run: bash telemon.sh --test"
    echo ""
    echo "Tips:"
    echo "  - All suggestions are commented with # for safety"
    echo "  - Uncomment the lines you want to enable"
    echo "  - Adjust thresholds to match your environment"
    echo "  - Never commit .env files with real credentials"
}

# ---------------------------------------------------------------------------
# Digest command (proxy to telemon.sh --digest)
# ---------------------------------------------------------------------------
cmd_digest() {
    echo "Sending health digest..."
    local digest_output
    if digest_output=$(bash "${SCRIPT_DIR}/telemon.sh" --digest 2>&1); then
        echo -e "${GREEN}✓ Digest sent${NC}"
    else
        echo -e "${RED}✗ Digest failed${NC}"
        if [[ -n "$digest_output" ]]; then
            # Truncate to prevent unbounded error output
            echo "  Details: ${digest_output:0:500}"
        fi
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Help command
# ---------------------------------------------------------------------------
cmd_help() {
    cat << 'EOF'
Telemon Administration Utility
==============================

Usage: bash telemon-admin.sh <command> [options]

Commands:
  backup [path]     Create backup of config, state, and logs
                    Default: ./backups/telemon-backup-<timestamp>
  
  restore <path>    Restore from backup directory
  
  status            Show current installation status and health
  
  reset-state       Reset alert state (forces fresh alerts on next run)
  
  validate          Validate configuration files
  
  digest            Send a health digest summary
   
  logs [lines]      View recent logs (default: 50 lines)
   
  fleet-status      Show fleet heartbeat overview table
   
  discover          Auto-discover services and suggest .env configuration
   
  help              Show this help message

Examples:
  bash telemon-admin.sh backup
  bash telemon-admin.sh backup /path/to/custom/backup
  bash telemon-admin.sh restore ./backups/telemon-backup-20250115-120000
  bash telemon-admin.sh status
  bash telemon-admin.sh reset-state
  bash telemon-admin.sh validate
  bash telemon-admin.sh digest
  bash telemon-admin.sh logs 100
  bash telemon-admin.sh fleet-status
  bash telemon-admin.sh discover

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    load_env
    
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        backup)
            cmd_backup "$@"
            ;;
        restore)
            cmd_restore "$@"
            ;;
        status)
            cmd_status
            ;;
        reset-state)
            cmd_reset_state
            ;;
        validate)
            cmd_validate
            ;;
        digest)
            cmd_digest
            ;;
        logs)
            cmd_logs "$@"
            ;;
        fleet-status)
            cmd_fleet_status
            ;;
        discover)
            cmd_discover
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            echo -e "${RED}Unknown command: ${cmd}${NC}"
            echo "Run 'bash telemon-admin.sh help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
