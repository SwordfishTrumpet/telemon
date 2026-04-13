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
