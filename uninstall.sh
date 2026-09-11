#!/usr/bin/env bash
# =============================================================================
# Telemon -- Uninstaller
# =============================================================================
# Removes cron jobs, systemd services, and optionally state/logs.
# Usage: bash uninstall.sh [--full]
#   --full  Also remove state file and logs (default: keep them)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="${SCRIPT_DIR}/telemon.sh"
FULL_UNINSTALL=false

# Load shared helpers
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --full)
            FULL_UNINSTALL=true
            ;;
        --help|-h)
            echo "Usage: bash uninstall.sh [--full]"
            echo "  --full  Also remove state file and log files"
            exit 0
            ;;
    esac
done

echo "============================================="
echo " Telemon - Uninstaller"
echo "============================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Remove cron job
# ---------------------------------------------------------------------------
echo "[1/4] Removing cron job..."

if crontab -l 2>/dev/null | grep -qF "$MONITOR_SCRIPT"; then
    # Remove telemon lines from crontab
    crontab -l 2>/dev/null | grep -vF "$MONITOR_SCRIPT" | crontab -
    echo "  Cron job removed."
else
    echo "  No cron job found."
fi

# ---------------------------------------------------------------------------
# 2. Remove systemd service/timer
# ---------------------------------------------------------------------------
echo "[2/4] Removing systemd service..."

if command -v systemctl &>/dev/null; then
    # System-wide units
    if [[ -f /etc/systemd/system/telemon.service || -f /etc/systemd/system/telemon.timer ]]; then
        systemctl stop telemon.timer 2>/dev/null || true
        systemctl disable telemon.timer 2>/dev/null || true
        systemctl stop telemon.service 2>/dev/null || true
        if [[ -w /etc/systemd/system/telemon.service || -w /etc/systemd/system/telemon.timer ]]; then
            rm -f /etc/systemd/system/telemon.service /etc/systemd/system/telemon.timer
            systemctl daemon-reload 2>/dev/null || true
            echo "  System-wide units stopped, disabled and removed."
        else
            echo "  System-wide units exist but require sudo to remove:"
            echo "    sudo rm /etc/systemd/system/telemon.service /etc/systemd/system/telemon.timer"
            echo "    sudo systemctl daemon-reload"
        fi
    else
        echo "  No system-wide systemd files found."
    fi

    # GH #24: install.sh --systemd installs *user* units when it does not run as
    # root (${HOME}/.config/systemd/user/telemon.{service,timer}, enabled with
    # `systemctl --user`). Those were never removed here, so a user-mode install
    # kept monitoring (and alerting) after a nominally complete uninstall.
    user_unit_dir="${HOME}/.config/systemd/user"
    if [[ -f "${user_unit_dir}/telemon.service" || -f "${user_unit_dir}/telemon.timer" ]]; then
        systemctl --user stop telemon.timer 2>/dev/null || true
        systemctl --user disable telemon.timer 2>/dev/null || true
        systemctl --user stop telemon.service 2>/dev/null || true
        rm -f "${user_unit_dir}/telemon.service" "${user_unit_dir}/telemon.timer"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "  User-level units stopped, disabled and removed (${user_unit_dir})."
    else
        echo "  No user-level systemd units found."
    fi
else
    echo "  systemctl not available."
fi

# ---------------------------------------------------------------------------
# 3. Remove logrotate config
# ---------------------------------------------------------------------------
echo "[3/4] Removing logrotate configuration..."

if [[ -f /etc/logrotate.d/telemon ]]; then
    if [[ -w /etc/logrotate.d/telemon ]]; then
        rm -f /etc/logrotate.d/telemon
        echo "  Logrotate config removed."
    else
        echo "  Logrotate config exists but requires sudo to remove:"
        echo "    sudo rm /etc/logrotate.d/telemon"
    fi
else
    echo "  No logrotate config found."
fi

# ---------------------------------------------------------------------------
# 4. Optional: Remove state and logs
# ---------------------------------------------------------------------------
echo "[4/4] Cleaning up state and logs..."

if [[ "$FULL_UNINSTALL" == true ]]; then
    echo "  Removing state files and logs (full uninstall)..."
    
    # Load env to get STATE_FILE if it exists
    load_telemon_env
    
    # GH #24: remove every state file the runtime writes, not just the main one.
    # The list is shared (get_state_file_variants) and is the same enumeration
    # `telemon-admin.sh reset-state` uses — previously only $STATE_FILE and its
    # lock were removed, leaving nine sidecars plus the drift baseline behind.
    # shellcheck disable=SC2046
    for file in $(get_state_file_variants true true false); do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            echo "  State file removed: $(basename "$file")"
        fi
    done
    
    drift_baseline_dir="${STATE_FILE}.drift.baseline"
    if [[ -d "$drift_baseline_dir" ]]; then
        rm -rf "$drift_baseline_dir"
        echo "  Drift baseline removed: $(basename "$drift_baseline_dir")"
    fi
    
    for log in "${SCRIPT_DIR}/telemon.log" "${SCRIPT_DIR}/telemon_cron.log"; do
        if [[ -f "$log" ]]; then
            rm -f "$log"
            # Remove rotated logs too
            rm -f "${log}."*
            echo "  Log removed: $(basename "$log")"
        fi
    done
else
    echo "  Keeping state file and logs (use --full to remove them)."
    echo "  State file: \${STATE_FILE:-/tmp/telemon_sys_alert_state}"
    echo "  Log files: ${SCRIPT_DIR}/telemon.log"
fi

echo ""
echo "============================================="
echo " Uninstallation complete!"
echo ""
echo " Telemon has been removed from:"
echo "  - Cron jobs"
echo "  - Systemd timers (if installed)"
echo "  - Logrotate config (if installed)"
echo ""
if [[ "$FULL_UNINSTALL" == false ]]; then
    echo " Your configuration (.env) and logs are preserved."
    echo " To remove them manually:"
    echo "   rm -rf ${SCRIPT_DIR}"
fi
echo ""
echo " To reinstall later, run: bash ${SCRIPT_DIR}/install.sh"
echo "============================================="
