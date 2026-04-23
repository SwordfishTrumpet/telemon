# Telemon Troubleshooting Guide

## Quick Diagnostic Flowchart

```
┌─────────────────────────────────────────────────────────────┐
│                    Problem: No Alerts                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  1. Check if Telemon is running                             │
│     bash telemon-admin.sh status                            │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────────┐
│ Cron job not found      │     │ Cron job exists             │
└─────────────────────────┘     └─────────────────────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────────┐
│ Run: bash install.sh    │     │ Check logs:                 │
│                         │     │ tail telemon_cron.log       │
└─────────────────────────┘     └─────────────────────────────┘
                                              │
                              ┌───────────────┴───────────────┐
                              │                               │
                              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────────┐
│ Errors in log           │     │ No errors, no execution   │
└─────────────────────────┘     └─────────────────────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────────┐
│ See "Common Errors" below │     │ Check cron service:         │
│                         │     │ systemctl status cron         │
└─────────────────────────┘     └─────────────────────────────┘
```

## Common Problems and Solutions

### 1. No Telegram Messages Received

**Symptoms:** Telemon runs but no alerts appear in Telegram.

**Diagnosis:**
```bash
# Check configuration
bash telemon-admin.sh validate

# For comprehensive validation (thresholds, dependencies, paths):
bash telemon.sh --validate

# Test Telegram manually
curl -X POST "https://api.telegram.org/bot<YOUR_TOKEN>/sendMessage" \
  -d "chat_id=<YOUR_CHAT_ID>" \
  -d "text=Test message"
```

**Solutions:**

| Issue | Solution |
|-------|----------|
| Wrong bot token | Get correct token from @BotFather |
| Wrong chat ID | Message @userinfobot to get your ID |
| Bot not started | Send /start to your bot in Telegram |
| Bot blocked | Unblock the bot in Telegram settings |

### 2. False Alarms / Too Many Alerts

**Symptoms:** Getting alerts for brief spikes that resolve quickly.

**Solution:** Increase confirmation count in `.env`:
```bash
# Require 5 consecutive checks (25 minutes with 5-min cron)
CONFIRMATION_COUNT=5

# Or adjust thresholds
CPU_THRESHOLD_CRIT=90    # Instead of 80
MEM_THRESHOLD_CRIT=5   # Instead of 10
```

### 3. Docker Checks Failing

**Symptoms:** Container status shows CRITICAL even though containers are running.

**Diagnosis:**
```bash
# Check if user can access docker
groups | grep docker

# Test docker command
docker ps
```

**Solution:**
```bash
# Add user to docker group
sudo usermod -aG docker $USER

# Log out and back in (or run: newgrp docker)
```

### 4. PM2 Checks Failing

**Symptoms:** PM2 processes show as missing even though `pm2 list` shows them.

**Diagnosis:**
```bash
# Check if pm2 is in PATH
which pm2
pm2 --version

# Check if process name matches exactly
pm2 jlist | grep name
```

**Solution:**
```bash
# In .env, use exact PM2 process name
CRITICAL_PM2_PROCESSES="exact-process-name"

# Or add pm2 to PATH in .env or .bashrc
export PATH="$PATH:/path/to/pm2"
```

### 5. State Stuck / Not Getting Resolution Alerts

**Symptoms:** Got a CRITICAL alert but never got the OK alert when issue resolved.

**Diagnosis:**
```bash
# Check current state
cat /tmp/telemon_sys_alert_state

# Check if state is being updated
stat /tmp/telemon_sys_alert_state
```

**Solution:**
```bash
# Reset state to force fresh alerts
bash telemon-admin.sh reset-state

# Or manually remove state file
rm /tmp/telemon_sys_alert_state
```

### 6. Logs Growing Too Large

**Symptoms:** Disk space warning from telemon.log.

**Diagnosis:**
```bash
# Check log size
ls -lh telemon.log

# Check if logrotate is working
logrotate -d /etc/logrotate.d/telemon
```

**Solution:**
- Telemon has built-in rotation (configurable via `LOG_MAX_SIZE_MB` and `LOG_MAX_BACKUPS`, defaults: 10MB, 5 backups)
- For system logrotate, ensure config exists:
  ```bash
  ls /etc/logrotate.d/telemon
  ```
- Manual rotation:
  ```bash
  > telemon.log  # Truncate log
  ```

### 7. "Another instance is running" Warning

**Symptoms:** Log shows warning about overlapping runs repeatedly. This is the most common cause of monitoring outages.

**Understanding Log Files:**
Telemon uses two log files:
- **`telemon.log`** — Main log file with all monitoring activity (respects `LOG_LEVEL` and `LOG_MAX_SIZE_MB`)
- **`telemon_cron.log`** — Captures stderr from cron invocations (lock contention messages)

When lock contention occurs, messages go to `telemon_cron.log` via stderr. This bypasses normal log rotation, which can cause disk space issues if not addressed.

**Automatic Recovery (Enhanced in v2.x):**
Telemon includes multi-layered stale lock detection:

1. **Process Verification**: Checks `/proc/$PID/cmdline` to verify the lock holder is actually telemon (prevents PID reuse issues)
2. **Age-based Detection**: Locks older than 5 minutes where the process is dead are automatically broken
3. **Force-break Old Locks**: Locks older than 10 minutes are force-broken regardless of PID status

You'll see log messages like:
```
[WARN] Stale lock detected (PID 12345 not running, age 360s) - breaking lock
[WARN] Stale lock detected (PID 12345 is not telemon - possible PID reuse, age 600s) - breaking lock
[WARN] Stale lock detected (age 900s > 600s) - force breaking lock
```

**Diagnosis:**
```bash
# Check for stuck processes
ps aux | grep telemon.sh | grep -v grep

# Check lock file location and age
LOCK_FILE="${STATE_FILE:-/tmp/telemon_sys_alert_state}.lock"
ls -la "$LOCK_FILE"
cat "$LOCK_FILE"  # Shows: PID timestamp

# Check lock directory (fallback method)
ls -la "${LOCK_FILE}.d/"
cat "${LOCK_FILE}.d/pid" 2>/dev/null

# Calculate lock age
read -r pid epoch < "$LOCK_FILE"
echo "Lock age: $(( $(date +%s) - epoch )) seconds"

# Check if process is actually telemon
[[ -f "/proc/$pid/cmdline" ]] && tr '\0' ' ' < "/proc/$pid/cmdline"
```

**Manual Solution (if automatic detection fails):**
```bash
# Method 1: Use the admin utility (recommended)
bash telemon-admin.sh reset-state

# Method 2: Manual cleanup
LOCK_FILE="${STATE_FILE:-/tmp/telemon_sys_alert_state}.lock"
rm -f "$LOCK_FILE"
rm -rf "${LOCK_FILE}.d"

# Method 3: Kill stuck process (if still running)
kill -9 <PID>  # Use PID from lock file
rm -f "$LOCK_FILE"
```

**Prevention:**
- Ensure Telemon runs with appropriate `CHECK_TIMEOUT` values (default: 30s)
- Check that the system has sufficient resources (CPU, memory)
- Review logs for any checks that may be hanging (`bash telemon-admin.sh logs 100`)
- Consider increasing cron interval if checks consistently take >5 minutes
- For critical systems, monitor `telemon_cron.log` for lock patterns:
  ```bash
  # Alert if >10 lock contention messages in last hour
  grep -c "Another instance is running" telemon_cron.log
  ```

**Lock File Locations:**
| File | Purpose |
|------|---------|
| `${STATE_FILE}.lock` | Main lock file (flock-based) |
| `${STATE_FILE}.lock.d/` | Fallback lock directory (mkdir-based) |
| `${STATE_FILE}.lock.d/pid` | PID and timestamp for stale detection |

**Note on Log Spam:**
Before v2.x, every lock contention was logged at WARN level, creating thousands of duplicate messages. Current versions use rate-limited logging - the first contention is logged, subsequent messages are suppressed to reduce disk usage.

### 8. First Run Issues

**Symptoms:** First execution shows errors or no bootstrap message.

**Diagnosis:**
```bash
# Check if .env exists and is valid
ls -la .env
bash telemon-admin.sh validate

# Run manually with debug
bash -x telemon.sh 2>&1 | head -50
```

**Solution:**
```bash
# Ensure .env is properly configured
cp .env.example .env
nano .env

# Run validation
bash telemon.sh --validate    # Full validation (recommended)
bash telemon-admin.sh validate
```

### 9. Fleet Heartbeat Not Working

**Symptoms:** Fleet check reports servers as stale or missing even though they are running Telemon.

**Diagnosis:**
```bash
# Check heartbeat file exists and is fresh
bash telemon-admin.sh fleet-status

# Check heartbeat directory permissions
ls -la /tmp/telemon_heartbeats/

# Verify heartbeat is enabled on the remote server
grep ENABLE_HEARTBEAT /path/to/remote/.env
```

**Solutions:**

| Issue | Solution |
|-------|----------|
| Heartbeat dir doesn't exist | Create it: `mkdir -m 1755 /tmp/telemon_heartbeats/` |
| Files not appearing from other servers | Ensure NFS/shared mount is working; check `FLEET_HEARTBEAT_DIR` matches on all servers |
| Stale heartbeat (server running fine) | Check cron is running on remote server; verify `HEARTBEAT_MODE=file` is set |
| Wrong server name in alerts | Set `SERVER_LABEL` in `.env` (defaults to hostname) |
| "Missing" server that was decommissioned | Remove it from `FLEET_EXPECTED_SERVERS` in `.env` |
| Permission denied writing heartbeat | Heartbeat dir needs sticky bit: `chmod 1755 /tmp/telemon_heartbeats/` |

### 10. Fleet Status Shows Wrong Server Names

**Symptoms:** `fleet-status` shows sanitized/mangled server names.

**Diagnosis:**
```bash
# Check actual heartbeat filenames
ls /tmp/telemon_heartbeats/

# Check SERVER_LABEL on the source server
grep SERVER_LABEL /path/to/remote/.env
```

**Solution:**
```bash
# Set a clean label on each server's .env
SERVER_LABEL="web-01"

# Labels are sanitized to [a-zA-Z0-9_.-] — avoid special characters
```

## Error Message Reference

| Error | Meaning | Solution |
|-------|---------|----------|
| `FATAL: .env not found` | Configuration missing | `cp .env.example .env` |
| `Telegram send failed` | Bot token or chat ID invalid | Check credentials |
| `docker engine not found` | Docker not installed or not in PATH | Install docker or disable check |
| `PM2 not found` | PM2 not installed | Install PM2 or disable check |
| `systemctl not available` | Non-systemd system | Set `ENABLE_FAILED_SYSTEMD_SERVICES=false` |
| `Command timed out` | External command hung | Increase `CHECK_TIMEOUT` |
| `ALERT_COOLDOWN_SEC must be >= 0` | Invalid cooldown value | Set to a non-negative integer |
| `Fleet heartbeat dir not found` | `FLEET_HEARTBEAT_DIR` doesn't exist | Create dir: `mkdir -m 1755 <dir>` |
| `Server X: no heartbeat file` | Expected server has no heartbeat | Check remote server is running + writing heartbeats |
| `Server X: stale heartbeat` | Heartbeat file too old | Check cron/connectivity on remote server |

## Getting Help

If the above doesn't solve your issue:

1. **Gather information:**
   ```bash
   bash telemon-admin.sh status > debug.txt
   tail -100 telemon.log >> debug.txt
   tail -50 telemon_cron.log >> debug.txt
   cat .env | grep -v TOKEN | grep -v CHAT_ID >> debug.txt
   ```

2. **Open an issue:**
   - Go to: https://github.com/yourusername/telemon/issues
   - Use the "Bug report" template
   - Attach debug.txt (remove sensitive data)

3. **Community support:**
   - Check existing issues first
   - Provide clear reproduction steps
   - Include OS version and Telemon version
