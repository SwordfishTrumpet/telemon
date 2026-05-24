#!/usr/bin/env bash
# =============================================================================
# Telemon Plugin: Time Machine Backup Health Monitor (CT 101)
# =============================================================================
# Monitors Apple Time Machine backups via Samba on LXC container 101.
# Detects stuck backups, stale locks, quota issues, and connection problems.
#
# Output format: STATE|KEY|DETAIL
# =============================================================================

set -euo pipefail

# Configuration
TIMEMACHINE_CT="101"
TIMEMACHINE_PATH="/srv/timemachine/TimeMachine"
SPARSEBUNDLE_NAME="Remco's MacBook Air.sparsebundle"
STALE_LOCK_HOURS=24          # Lock files older than this are stale
STALE_BACKUP_HOURS=6         # No band writes for this long = stuck
QUOTA_MIN_GB=500             # Minimum recommended quota in GB

# Check if pct command is available (Proxmox host check)
if ! command -v pct &>/dev/null; then
    echo "OK|timemachine-ct101|Not a Proxmox host - skipping CT 101 check"
    exit 0
fi

# Check if CT 101 exists and is running
if ! pct status "$TIMEMACHINE_CT" &>/dev/null; then
    echo "WARNING|timemachine-ct101|CT $TIMEMACHINE_CT does not exist"
    exit 0
fi

CT_STATUS=$(pct status "$TIMEMACHINE_CT" 2>/dev/null | awk '{print $2}')
if [[ "$CT_STATUS" != "running" ]]; then
    echo "CRITICAL|timemachine-ct101|CT $TIMEMACHINE_CT is not running (status: $CT_STATUS)"
    exit 0
fi

# Helper: Run command inside CT 101
ct_exec() {
    pct exec "$TIMEMACHINE_CT" -- "$@" 2>/dev/null || echo ""
}

# Check 1: Samba service is running
SMBD_STATUS=$(ct_exec systemctl is-active smbd 2>/dev/null || echo "unknown")
if [[ "$SMBD_STATUS" != "active" ]]; then
    echo "CRITICAL|timemachine-samba|Samba (smbd) is not running on CT $TIMEMACHINE_CT"
    exit 0
fi

# Check 2: Active SMB connections for Time Machine
# Disable pipefail temporarily for this check (grep returns 1 when no matches)
set +o pipefail
SMB_STATUS_OUTPUT=$(pct exec "$TIMEMACHINE_CT" -- smbstatus --shares 2>/dev/null)
SMB_CONNECTIONS=$(echo "$SMB_STATUS_OUTPUT" | grep "TimeMachine" 2>/dev/null | wc -l)
set -o pipefail
# Ensure we have a valid number
if ! [[ "$SMB_CONNECTIONS" =~ ^[0-9]+$ ]]; then
    SMB_CONNECTIONS=0
fi
if [[ "$SMB_CONNECTIONS" -eq 0 ]]; then
    echo "WARNING|timemachine-connection|No active Time Machine connections on CT $TIMEMACHINE_CT"
    # Continue to check other issues
fi

# Check 3: Stale lock file
LOCK_FILE="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/lock"
LOCK_EXISTS=$(ct_exec test -f "$LOCK_FILE" && echo "yes" || echo "no")

if [[ "$LOCK_EXISTS" == "yes" ]]; then
    LOCK_AGE_HOURS=$(ct_exec find "$LOCK_FILE" -mmin +$((STALE_LOCK_HOURS * 60)) 2>/dev/null | wc -l)
    if [[ "$LOCK_AGE_HOURS" -gt 0 ]]; then
        LOCK_MTIME=$(ct_exec stat -c "%y" "$LOCK_FILE" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        echo "CRITICAL|timemachine-stale-lock|Stale lock file from $LOCK_MTIME (>$STALE_LOCK_HOURS hours old)"
        exit 0
    fi
fi

# Check 4: Zombie backup state (Results.plist showing running but no activity)
RESULTS_FILE="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/com.apple.TimeMachine.Results.plist"
if ct_exec test -f "$RESULTS_FILE" &>/dev/null; then
    # Check if Results.plist indicates running backup
    IS_RUNNING=$(ct_exec grep -o "<true/>" "$RESULTS_FILE" 2>/dev/null | head -1 || echo "")
    
    if [[ -n "$IS_RUNNING" ]]; then
        # Check last band file modification time
        BANDS_DIR="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/bands"
        LATEST_BAND=$(ct_exec find "$BANDS_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 || echo "")
        
        if [[ -n "$LATEST_BAND" ]]; then
            LATEST_BAND_EPOCH=$(echo "$LATEST_BAND" | awk '{print $1}')
            CURRENT_EPOCH=$(date +%s)
            HOURS_SINCE_WRITE=$(echo "($CURRENT_EPOCH - ${LATEST_BAND_EPOCH%.*}) / 3600" | bc 2>/dev/null || echo "0")
            
            if [[ "$HOURS_SINCE_WRITE" -gt "$STALE_BACKUP_HOURS" ]]; then
                BAND_NAME=$(echo "$LATEST_BAND" | awk '{print $2}' | xargs basename 2>/dev/null)
                echo "CRITICAL|timemachine-stuck|Backup stuck for ${HOURS_SINCE_WRITE}h (last write: $BAND_NAME, >${STALE_BACKUP_HOURS}h ago)"
                exit 0
            fi
        fi
    fi
fi

# Check 5: Samba quota configuration
SMB_CONF=$(ct_exec cat /etc/samba/smb.conf 2>/dev/null || echo "")
if [[ -n "$SMB_CONF" ]]; then
    QUOTA_LINE=$(echo "$SMB_CONF" | grep "fruit:quota" | head -1 || echo "")
    if [[ -n "$QUOTA_LINE" ]]; then
        QUOTA_VALUE=$(echo "$QUOTA_LINE" | sed 's/.*= *//' | tr -d ' ')
        # Parse quota (handle G, T, M suffixes)
        QUOTA_NUM=$(echo "$QUOTA_VALUE" | sed 's/[GTMEKBgtmekb]//g')
        QUOTA_UNIT=$(echo "$QUOTA_VALUE" | sed 's/[0-9.]//g' | tr 'gtmekb' 'GTMEKB')
        
        # Convert to GB for comparison
        QUOTA_GB=0
        case "$QUOTA_UNIT" in
            G) QUOTA_GB=$QUOTA_NUM ;;
            T) QUOTA_GB=$(echo "$QUOTA_NUM * 1024" | bc 2>/dev/null || echo "1024") ;;
            M) QUOTA_GB=$(echo "$QUOTA_NUM / 1024" | bc 2>/dev/null || echo "0") ;;
            *) QUOTA_GB=$QUOTA_NUM ;;
        esac
        
        if [[ "$QUOTA_GB" -lt "$QUOTA_MIN_GB" ]]; then
            echo "WARNING|timemachine-quota|Samba quota ${QUOTA_VALUE} is below recommended ${QUOTA_MIN_GB}GB - may cause backup failures"
        fi
    fi
fi

# Check 6: Stale MachineID.plist.tmp file (interrupted write)
MACHINEID_TMP="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/com.apple.TimeMachine.MachineID.plist.tmp"
TMP_EXISTS=$(pct exec "$TIMEMACHINE_CT" -- test -f "$MACHINEID_TMP" 2>/dev/null && echo "yes" || echo "no")
if [[ "$TMP_EXISTS" == "yes" ]]; then
    TMP_AGE=$(pct exec "$TIMEMACHINE_CT" -- find "$MACHINEID_TMP" -mmin +60 2>/dev/null | wc -l)
    if [[ "$TMP_AGE" -gt 0 ]]; then
        echo "WARNING|timemachine-tmpfile|Stale MachineID.plist.tmp exists (>1 hour old) - previous backup may have been interrupted"
    fi
fi

# Check 7: Backup progress (if running)
if [[ -n "$IS_RUNNING" ]] && [[ "$HOURS_SINCE_WRITE" -le "$STALE_BACKUP_HOURS" ]]; then
    # Get backup progress info
    BYTES_COPIED=$(ct_exec grep -A1 "com.apple.backupd.SnapshotTotalBytesCopied" "$RESULTS_FILE" 2>/dev/null | grep integer | sed 's/.*<integer>\(.*\)<\/integer>.*/\1/' || echo "0")
    TOTAL_BYTES=$(ct_exec grep -A1 "_raw_totalBytes" "$RESULTS_FILE" 2>/dev/null | grep integer | tail -1 | sed 's/.*<integer>\(.*\)<\/integer>.*/\1/' || echo "0")
    
    if [[ "$TOTAL_BYTES" -gt 0 ]] && [[ "$BYTES_COPIED" -gt 0 ]]; then
        PERCENT=$(echo "scale=1; $BYTES_COPIED * 100 / $TOTAL_BYTES" | bc 2>/dev/null || echo "?")
        COPIED_GB=$(echo "scale=1; $BYTES_COPIED / 1073741824" | bc 2>/dev/null || echo "0")
        TOTAL_GB=$(echo "scale=1; $TOTAL_BYTES / 1073741824" | bc 2>/dev/null || echo "0")
        echo "OK|timemachine-progress|Backup in progress: ${PERCENT}% (${COPIED_GB}GB/${TOTAL_GB}GB) - last write ${HOURS_SINCE_WRITE}h ago"
    else
        echo "OK|timemachine-running|Backup is running (no progress data available)"
    fi
    exit 0
fi

# Check 8: Last successful backup (from SnapshotHistory)
SNAPSHOT_HISTORY="$TIMEMACHINE_PATH/$SPARSEBUNDLE_NAME/com.apple.TimeMachine.SnapshotHistory.plist"
if ct_exec test -f "$SNAPSHOT_HISTORY" &>/dev/null; then
    # Find the most recent snapshot date
    LATEST_SNAPSHOT=$(ct_exec grep -o "[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z" "$SNAPSHOT_HISTORY" 2>/dev/null | tail -1 || echo "")
    
    if [[ -n "$LATEST_SNAPSHOT" ]]; then
        # Convert to epoch and calculate hours ago
        SNAPSHOT_EPOCH=$(date -d "$LATEST_SNAPSHOT" +%s 2>/dev/null || echo "0")
        CURRENT_EPOCH=$(date +%s)
        
        if [[ "$SNAPSHOT_EPOCH" -gt 0 ]]; then
            HOURS_SINCE_BACKUP=$(( (CURRENT_EPOCH - SNAPSHOT_EPOCH) / 3600 ))
            DAYS_SINCE_BACKUP=$(( HOURS_SINCE_BACKUP / 24 ))
            
            # Alert if no backup for >48 hours
            if [[ "$HOURS_SINCE_BACKUP" -gt 48 ]]; then
                echo "WARNING|timemachine-age|No successful backup for ${DAYS_SINCE_BACKUP} days (last: ${LATEST_SNAPSHOT:0:10})"
                exit 0
            fi
            
            # All checks passed - backup is healthy
            echo "OK|timemachine-healthy|Time Machine healthy - last backup ${HOURS_SINCE_BACKUP}h ago (${LATEST_SNAPSHOT:0:10}), ${SMB_CONNECTIONS} active connection(s)"
            exit 0
        fi
    fi
fi

# Fallback - basic health check passed
echo "OK|timemachine-healthy|Time Machine appears healthy (CT $TIMEMACHINE_CT running, Samba active)"
