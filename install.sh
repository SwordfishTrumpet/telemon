#!/usr/bin/env bash
# =============================================================================
# Telemon -- Installer
# =============================================================================
# Sets up the cron job, verifies dependencies, and runs an initial test.
# Usage: bash install.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="${SCRIPT_DIR}/telemon.sh"
CRON_SCHEDULE="*/5 * * * *"

# Use flock in cron if available to prevent overlapping runs
if command -v flock &>/dev/null; then
    LOCK_FILE="/tmp/telemon_sys_alert_state.lock"
    CRON_LINE="${CRON_SCHEDULE} flock -n ${LOCK_FILE} ${MONITOR_SCRIPT} >> ${SCRIPT_DIR}/telemon_cron.log 2>&1"
else
    CRON_LINE="${CRON_SCHEDULE} ${MONITOR_SCRIPT} >> ${SCRIPT_DIR}/telemon_cron.log 2>&1"
fi

echo "============================================="
echo " Telemon - Installer"
echo "============================================="
echo ""

# ---------------------------------------------------------------------------
# 1. Check dependencies
# ---------------------------------------------------------------------------
echo "[1/5] Checking dependencies..."

missing=()
for cmd in curl ping awk nproc df pgrep docker python3; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if (( ${#missing[@]} > 0 )); then
    echo "  WARNING: Missing commands: ${missing[*]}"
    echo "  Some checks may not work correctly."
else
    echo "  All dependencies found."
fi

# ---------------------------------------------------------------------------
# 2. Verify .env exists
# ---------------------------------------------------------------------------
echo "[2/5] Checking .env configuration..."

if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
    echo "  ERROR: ${SCRIPT_DIR}/.env not found!"
    echo "  Copy .env.example to .env and fill in your Telegram credentials."
    exit 1
fi
echo "  .env found."

# ---------------------------------------------------------------------------
# 3. Make script executable
# ---------------------------------------------------------------------------
echo "[3/5] Setting permissions..."
chmod +x "$MONITOR_SCRIPT"
echo "  ${MONITOR_SCRIPT} is now executable."

# ---------------------------------------------------------------------------
# 4. Setup log rotation (optional)
# ---------------------------------------------------------------------------
echo "[4/7] Setting up log rotation..."

if command -v logrotate &>/dev/null; then
    # Check if we can install system-wide logrotate config
    if [[ -d /etc/logrotate.d ]] && [[ -w /etc/logrotate.d ]]; then
        # Generate logrotate config with correct paths
        export TELEMON_DIR="${SCRIPT_DIR}"
        envsubst < "${SCRIPT_DIR}/telemon-logrotate.conf" > /etc/logrotate.d/telemon
        echo "  System logrotate config installed."
    else
        echo "  logrotate available but no write access to /etc/logrotate.d"
        echo "  Self-rotation enabled (10MB limit, 5 backups)"
    fi
else
    echo "  logrotate not found - using self-rotation (10MB limit, 5 backups)"
fi

# ---------------------------------------------------------------------------
# 5. Install cron job (idempotent)
# ---------------------------------------------------------------------------
echo "[5/7] Installing cron job..."

# Check if cron line already exists
if crontab -l 2>/dev/null | grep -qF "$MONITOR_SCRIPT"; then
    echo "  Cron job already exists. Skipping."
else
    # Append to existing crontab
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    echo "  Cron job installed: ${CRON_SCHEDULE}"
fi

echo "  Current crontab:"
crontab -l 2>/dev/null | grep telemon || echo "  (none found)"

# ---------------------------------------------------------------------------
# 6. Create systemd service (optional, alternative to cron)
# ---------------------------------------------------------------------------
echo "[6/7] Setting up systemd service (optional)..."

if command -v systemctl &>/dev/null && [[ -d /etc/systemd/system ]]; then
    if [[ -w /etc/systemd/system ]]; then
        # Create systemd service file
        cat > /etc/systemd/system/telemon.service << EOF
[Unit]
Description=Telemon System Health Monitor
After=network.target

[Service]
Type=oneshot
User=${USER}
ExecStart=${MONITOR_SCRIPT}
StandardOutput=append:${SCRIPT_DIR}/telemon_cron.log
StandardError=append:${SCRIPT_DIR}/telemon_cron.log

[Install]
WantedBy=multi-user.target
EOF

        # Create systemd timer file (runs every 5 minutes)
        cat > /etc/systemd/system/telemon.timer << EOF
[Unit]
Description=Run Telemon every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload 2>/dev/null || true
        echo "  Systemd service and timer created."
        echo "  To use systemd instead of cron:"
        echo "    sudo systemctl enable telemon.timer"
        echo "    sudo systemctl start telemon.timer"
    else
        echo "  No write access to /etc/systemd/system - skipping systemd setup"
        echo "  (Cron job will be used instead)"
    fi
else
    echo "  systemd not available - using cron only"
fi

# ---------------------------------------------------------------------------
# 7. Test run
# ---------------------------------------------------------------------------
echo ""
echo "[7/7] Running initial test..."
echo "  This will execute a full check cycle. On first run, all metrics"
echo "  will be treated as NEW and you'll receive a Telegram message."
echo ""
read -rp "  Run test now? [Y/n] " answer
answer="${answer:-Y}"

if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  Executing: bash ${MONITOR_SCRIPT}"
    echo "  ---"
    bash "$MONITOR_SCRIPT"
    echo "  ---"
    echo "  Test complete. Check your Telegram for the alert."
else
    echo "  Skipped test run."
fi

echo ""
echo "============================================="
echo " Installation complete!"
echo ""
echo " Monitor script : ${MONITOR_SCRIPT}"
echo " Config file    : ${SCRIPT_DIR}/.env"
echo " State file     : \${STATE_FILE:-/tmp/telemon_sys_alert_state}"
echo " Log file       : ${SCRIPT_DIR}/telemon.log"
echo " Cron schedule  : every 5 minutes"
echo ""
echo " To run manually:  bash ${MONITOR_SCRIPT}"
echo " To view logs:     tail -f ${SCRIPT_DIR}/telemon.log"
echo " To remove cron:   crontab -e  (delete the telemon line)"
echo " To uninstall:    bash ${SCRIPT_DIR}/uninstall.sh"
echo " To update:       bash ${SCRIPT_DIR}/update.sh"
echo " To backup:       bash ${SCRIPT_DIR}/telemon-admin.sh backup"
echo " To reset state:   rm \${STATE_FILE:-/tmp/telemon_sys_alert_state}"
echo "============================================="
