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
#   logs [lines]      View recent logs (default: 50 lines)
#   help              Show this help message
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load environment
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$ENV_FILE" 2>/dev/null || true
    fi
    STATE_FILE="${STATE_FILE:-/tmp/telemon_sys_alert_state}"
    LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/telemon.log}"
}

# ---------------------------------------------------------------------------
# Backup command
# ---------------------------------------------------------------------------
cmd_backup() {
    local backup_path="${1:-${SCRIPT_DIR}/backups/telemon-backup-$(date +%Y%m%d-%H%M%S)}"
    
    echo "Creating backup at: $backup_path"
    mkdir -p "$backup_path"
    
    # Backup configuration
    if [[ -f "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "$backup_path/"
        echo "  ✓ Configuration backed up"
    fi
    
    # Backup state
    if [[ -f "$STATE_FILE" ]]; then
        cp "$STATE_FILE" "$backup_path/"
        echo "  ✓ State file backed up"
    fi
    
    # Backup logs
    if [[ -f "$LOG_FILE" ]]; then
        cp "$LOG_FILE" "$backup_path/"
        echo "  ✓ Log file backed up"
    fi
    
    if [[ -f "${SCRIPT_DIR}/telemon_cron.log" ]]; then
        cp "${SCRIPT_DIR}/telemon_cron.log" "$backup_path/"
        echo "  ✓ Cron log backed up"
    fi
    
    # Create metadata
    cat > "${backup_path}/META.txt" << EOF
Telemon Backup
==============
Created: $(date)
Hostname: $(hostname)
Version: $(cd "$SCRIPT_DIR" && git describe --tags --always 2>/dev/null || echo "unknown")
Source: ${SCRIPT_DIR}
EOF
    
    echo ""
    echo -e "${GREEN}Backup complete: ${backup_path}${NC}"
    echo "To restore: bash telemon-admin.sh restore ${backup_path}"
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
    
    # Restore files
    if [[ -f "${backup_path}/.env" ]]; then
        cp "${backup_path}/.env" "$ENV_FILE"
        echo "  ✓ Configuration restored"
    fi
    
    if [[ -f "${backup_path}/$(basename "$STATE_FILE")" ]]; then
        cp "${backup_path}/$(basename "$STATE_FILE")" "$STATE_FILE"
        echo "  ✓ State file restored"
    fi
    
    if [[ -f "${backup_path}/$(basename "$LOG_FILE")" ]]; then
        cp "${backup_path}/$(basename "$LOG_FILE")" "$LOG_FILE"
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
        echo "  Version: $(cd "$SCRIPT_DIR" && git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)"
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
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            local state="${value%%:*}"
            case "$state" in
                CRITICAL) crit_count=$((crit_count + 1)) ;;
                WARNING) warn_count=$((warn_count + 1)) ;;
                OK) ok_count=$((ok_count + 1)) ;;
            esac
        done < "$STATE_FILE"
        
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
        echo "  Main log: ${LOG_FILE} ($(numfmt --to=iec "$log_size" 2>/dev/null || echo "${log_size} bytes"))"
    fi
    if [[ -f "${SCRIPT_DIR}/telemon_cron.log" ]]; then
        echo "  Cron log: ${SCRIPT_DIR}/telemon_cron.log"
    fi
}

# ---------------------------------------------------------------------------
# Reset state command
# ---------------------------------------------------------------------------
cmd_reset_state() {
    echo "Resetting Telemon state..."
    
    if [[ -f "$STATE_FILE" ]]; then
        rm -f "$STATE_FILE"
        echo "  ✓ State file removed: ${STATE_FILE}"
    fi
    
    if [[ -f "${STATE_FILE}.lock" ]]; then
        rm -f "${STATE_FILE}.lock"
        echo "  ✓ Lock file removed"
    fi
    
    echo ""
    echo -e "${GREEN}State reset complete.${NC}"
    echo "Next run will treat all checks as new (bootstrap message will be sent)."
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
    
    if [[ -f "$LOG_FILE" ]]; then
        echo "Last ${lines} lines of ${LOG_FILE}:"
        echo "---"
        tail -n "$lines" "$LOG_FILE"
    else
        echo -e "${YELLOW}Log file not found: ${LOG_FILE}${NC}"
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
  
  logs [lines]      View recent logs (default: 50 lines)
  
  help              Show this help message

Examples:
  bash telemon-admin.sh backup
  bash telemon-admin.sh backup /path/to/custom/backup
  bash telemon-admin.sh restore ./backups/telemon-backup-20250115-120000
  bash telemon-admin.sh status
  bash telemon-admin.sh reset-state
  bash telemon-admin.sh validate
  bash telemon-admin.sh logs 100

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
        logs)
            cmd_logs "$@"
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
