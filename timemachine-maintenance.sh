#!/usr/bin/env bash
# =============================================================================
# Time Machine Maintenance Script for CT 101
# =============================================================================
# Prevents backup failures by automatically cleaning up:
# - Stale lock files (>24 hours old)
# - Zombie MachineID.plist.tmp files
# - Hung Results.plist files (stuck "Running" state)
# - Old token files
#
# Run via cron: 0 */6 * * * /opt/telemon/timemachine-maintenance.sh
# =============================================================================

set -euo pipefail

TIMEMACHINE_CT="101"
TIMEMACHINE_PATH="/srv/timemachine/TimeMachine"
SPARSEBUNDLE_NAME="Remco's MacBook Air.sparsebundle"
STALE_LOCK_HOURS=24
STALE_TMP_MINUTES=60
STALE_RESULTS_HOURS=6
LOG_FILE="/var/log/telemon-timemachine.log"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    # Also log to syslog
    logger -t "timemachine-maint" -p "user.${level,,}" "$message" 2>/dev/null || true
}

# Check if we're on Proxmox host
if ! command -v pct &>/dev/null; then
    log "INFO" "Not a Proxmox host - skipping maintenance"
    exit 0
fi

# Check if CT 101 is running
if ! pct status "$TIMEMACHINE_CT" &>/dev/null; then
    log "ERROR" "CT $TIMEMACHINE_CT does not exist"
    exit 1
fi

CT_STATUS=$(pct status "$TIMEMACHINE_CT" 2>/dev/null | awk '{print $2}')
if [[ "$CT_STATUS" != "running" ]]; then
    log "INFO" "CT $TIMEMACHINE_CT is not running (status: $CT_STATUS) - skipping maintenance"
    exit 0
fi

# Helper: Run command inside CT 101
ct_exec() {
    pct exec "$TIMEMACHINE_CT" -- "$@" 2>/dev/null || true
}

log "INFO" "Starting Time Machine maintenance for CT $TIMEMACHINE_CT"

CLEANED_ITEMS=0

# Check 1: Stale lock file
LOCK_FILE="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/lock"
if ct_exec test -f "$LOCK_FILE" &>/dev/null; then
    LOCK_AGE=$(ct_exec find "$LOCK_FILE" -mmin +$((STALE_LOCK_HOURS * 60)) 2>/dev/null | wc -l)
    if [[ "$LOCK_AGE" -gt 0 ]]; then
        LOCK_MTIME=$(ct_exec stat -c "%y" "$LOCK_FILE" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        ct_exec rm -f "$LOCK_FILE"
        log "WARN" "Removed stale lock file from $LOCK_MTIME (>$STALE_LOCK_HOURS hours old)"
        ((CLEANED_ITEMS++))
    fi
fi

# Check 2: Stale MachineID.plist.tmp
MACHINEID_TMP="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/com.apple.TimeMachine.MachineID.plist.tmp"
if ct_exec test -f "$MACHINEID_TMP" &>/dev/null; then
    TMP_AGE=$(ct_exec find "$MACHINEID_TMP" -mmin +$STALE_TMP_MINUTES 2>/dev/null | wc -l)
    if [[ "$TMP_AGE" -gt 0 ]]; then
        ct_exec rm -f "$MACHINEID_TMP"
        log "WARN" "Removed stale MachineID.plist.tmp (>$STALE_TMP_MINUTES minutes old)"
        ((CLEANED_ITEMS++))
    fi
fi

# Check 3: Hung Results.plist (stuck "Running" state with no recent activity)
RESULTS_FILE="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/com.apple.TimeMachine.Results.plist"
if ct_exec test -f "$RESULTS_FILE" &>/dev/null; then
    IS_RUNNING=$(ct_exec grep -o "<true/>" "$RESULTS_FILE" 2>/dev/null | head -1 || echo "")
    
    if [[ -n "$IS_RUNNING" ]]; then
        # Check last band write
        BANDS_DIR="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/bands"
        LATEST_BAND=$(ct_exec find "$BANDS_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 || echo "")
        
        if [[ -n "$LATEST_BAND" ]]; then
            LATEST_BAND_EPOCH=$(echo "$LATEST_BAND" | awk '{print $1}')
            CURRENT_EPOCH=$(date +%s)
            HOURS_SINCE_WRITE=$(( (CURRENT_EPOCH - ${LATEST_BAND_EPOCH%.*}) / 3600 ))
            
            if [[ "$HOURS_SINCE_WRITE" -gt "$STALE_RESULTS_HOURS" ]]; then
                # Backup is stuck - remove Results.plist to reset state
                ct_exec rm -f "$RESULTS_FILE"
                log "WARN" "Removed hung Results.plist (stuck for ${HOURS_SINCE_WRITE}h, no writes for >${STALE_RESULTS_HOURS}h)"
                ((CLEANED_ITEMS++))
            fi
        fi
    fi
fi

# Check 4: Verify Samba quota is adequate
SMB_CONF=$(ct_exec cat /etc/samba/smb.conf 2>/dev/null || echo "")
if [[ -n "$SMB_CONF" ]]; then
    QUOTA_LINE=$(echo "$SMB_CONF" | grep "fruit:quota" | head -1 || echo "")
    if [[ -n "$QUOTA_LINE" ]]; then
        QUOTA_VALUE=$(echo "$QUOTA_LINE" | sed 's/.*= *//' | tr -d ' ')
        # Check if quota is too small (less than 500GB)
        if [[ "$QUOTA_VALUE" =~ ^[0-9]+G$ ]]; then
            QUOTA_GB=$(echo "$QUOTA_VALUE" | sed 's/G$//')
            if [[ "$QUOTA_GB" -lt 500 ]]; then
                # Auto-fix quota to 1TB
                ct_exec sed -i 's/fruit:quota = .*/fruit:quota = 1T/' /etc/samba/smb.conf
                ct_exec smbcontrol smbd reload-config 2>/dev/null || ct_exec systemctl reload smbd 2>/dev/null || true
                log "WARN" "Increased Samba quota from $QUOTA_VALUE to 1T (was below 500GB minimum)"
                ((CLEANED_ITEMS++))
            fi
        fi
    fi
fi

# Check 5: Monitor sparsebundle size and alert if approaching quota
SPARSEBUNDLE_PATH="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME"
if ct_exec test -d "$SPARSEBUNDLE_PATH" &>/dev/null; then
    BUNDLE_SIZE=$(ct_exec du -sb "$SPARSEBUNDLE_PATH" 2>/dev/null | awk '{print $1}' || echo "0")
    if [[ "$BUNDLE_SIZE" -gt 0 ]]; then
        BUNDLE_SIZE_GB=$(( BUNDLE_SIZE / 1073741824 ))
        
        # Log size for trending (if over 100GB)
        if [[ "$BUNDLE_SIZE_GB" -gt 100 ]]; then
            log "INFO" "Sparsebundle size: ${BUNDLE_SIZE_GB}GB"
        fi
    fi
fi

if [[ "$CLEANED_ITEMS" -eq 0 ]]; then
    log "INFO" "No issues found - Time Machine is healthy"
else
    log "INFO" "Maintenance complete - cleaned $CLEANED_ITEMS item(s)"
fi

exit 0
