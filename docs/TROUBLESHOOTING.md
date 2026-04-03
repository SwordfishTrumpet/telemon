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
- Telemon has built-in rotation at 10MB (5 backups)
- For system logrotate, ensure config exists:
  ```bash
  ls /etc/logrotate.d/telemon
  ```
- Manual rotation:
  ```bash
  > telemon.log  # Truncate log
  ```

### 7. "Another instance is running" Warning

**Symptoms:** Log shows warning about overlapping runs.

**Diagnosis:**
```bash
# Check for stuck processes
ps aux | grep telemon.sh

# Check lock file
ls -la /tmp/telemon_sys_alert_state.lock
```

**Solution:**
```bash
# Remove stale lock
rm /tmp/telemon_sys_alert_state.lock

# If process is stuck, kill it
kill -9 <PID>
```

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
bash telemon-admin.sh validate
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
