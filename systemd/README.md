# Telemon Systemd Timer Guide

Run Telemon via systemd timer instead of cron — ideal for containerized systems, better logging, and modern Linux integration.

## Quick Setup (Recommended)

### Option 1: Via install.sh (Easiest)

```bash
# Install with systemd timer instead of cron
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --systemd

# Or for custom directory with systemd
bash install.sh /opt/telemon --systemd
```

### Option 2: User systemd (No Root Required)

Perfect for personal installs in `~/telemon`:

```bash
mkdir -p ~/.config/systemd/user/
cp systemd/telemon.timer ~/.config/systemd/user/
cp systemd/telemon@.service ~/.config/systemd/user/telemon.service

# Edit the service file to set correct paths
nano ~/.config/systemd/user/telemon.service

# Enable and start
systemctl --user daemon-reload
systemctl --user enable telemon.timer
systemctl --user start telemon.timer

# Check status
systemctl --user status telemon.timer
systemctl --user list-timers
```

### Option 3: System-wide systemd (Requires Root)

For system-wide installs in `/opt/telemon`:

```bash
sudo cp systemd/telemon.timer /etc/systemd/system/
sudo cp systemd/telemon@.service /etc/systemd/system/telemon.service

# Edit the service file
sudo nano /etc/systemd/system/telemon.service

# Set the correct user and path:
# [Service]
# User=telemon
# ExecStart=/opt/telemon/telemon.sh

sudo systemctl daemon-reload
sudo systemctl enable telemon.timer
sudo systemctl start telemon.timer
```

## Service File Configuration

The `telemon@.service` file uses `%h` (user's home directory) and `%I` (instance name). For custom setups, edit these values:

```ini
[Service]
Type=oneshot
User=%I                          # The user to run as
ExecStart=%h/telemon/telemon.sh  # Path to telemon.sh
```

### Common Configurations

**For ~/telemon (user install):**
```ini
ExecStart=/home/username/telemon/telemon.sh
User=username
```

**For /opt/telemon (system install):**
```ini
ExecStart=/opt/telemon/telemon.sh
User=telemon
```

## Managing the Service

### User Mode Commands (No sudo needed)

```bash
# Check status
systemctl --user status telemon.timer
systemctl --user status telemon.service

# View logs
journalctl --user -u telemon -f
journalctl --user -u telemon --since "1 hour ago"

# Stop/Start
systemctl --user stop telemon.timer
systemctl --user start telemon.timer

# Run manually once
systemctl --user start telemon.service

# Disable auto-start
systemctl --user disable telemon.timer

# List all timers
systemctl --user list-timers
```

### System Mode Commands (Requires sudo)

```bash
# Check status
sudo systemctl status telemon.timer
sudo systemctl status telemon.service

# View logs
sudo journalctl -u telemon -f
sudo journalctl -u telemon --since "1 hour ago"

# Stop/Start
sudo systemctl stop telemon.timer
sudo systemctl start telemon.timer

# Run manually once
sudo systemctl start telemon.service

# Disable auto-start
sudo systemctl disable telemon.timer
```

## Switching from Cron to Systemd

1. Remove cron job:
   ```bash
   crontab -l | grep -v telemon | crontab -
   ```

2. Setup systemd (see options above)

3. Verify it's working:
   ```bash
   # Check timer is running
   systemctl --user list-timers telemon.timer
   
   # Check for any errors
   journalctl --user -u telemon --since "5 minutes ago"
   ```

## Switching from Systemd to Cron

1. Stop and disable systemd timer:
   ```bash
   systemctl --user stop telemon.timer
   systemctl --user disable telemon.timer
   # Or for system mode:
   # sudo systemctl stop telemon.timer
   # sudo systemctl disable telemon.timer
   ```

2. Re-run install script with cron:
   ```bash
   bash install.sh
   # Do NOT use --systemd flag
   ```

## Timer Configuration

The default timer runs every 5 minutes. To customize:

```bash
# Edit the timer
systemctl --user edit telemon.timer

# Or for system-wide:
# sudo systemctl edit telemon.timer
```

Add your custom schedule:
```ini
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
# Or use OnCalendar for specific times:
# OnCalendar=*:0/5
```

Common schedules:
- `OnUnitActiveSec=5min` — Every 5 minutes (default)
- `OnUnitActiveSec=1min` — Every minute
- `OnCalendar=*:0/15` — Every 15 minutes
- `OnCalendar=hourly` — Once per hour

## Troubleshooting

### Permission Denied Errors

Check file ownership:
```bash
ls -la ~/telemon/
# All files should be owned by the user running telemon
```

### Logs Not Written

1. Check the service file has correct path:
   ```bash
   systemctl --user cat telemon.service | grep ExecStart
   ```

2. Verify directory is writable:
   ```bash
   touch ~/telemon/test-write && rm ~/telemon/test-write
   ```

3. Check SELinux (if enabled):
   ```bash
   # Temporarily disable to test
   sudo setenforce 0
   # If it works, create a proper SELinux policy
   ```

### Timer Not Running

1. Check for errors:
   ```bash
   systemctl --user status telemon.timer
   journalctl --user -u telemon.timer
   ```

2. Verify timer is enabled:
   ```bash
   systemctl --user is-enabled telemon.timer
   # If disabled, enable it:
   systemctl --user enable telemon.timer
   ```

3. Check if service file exists:
   ```bash
   ls -la ~/.config/systemd/user/telemon*
   ```

### "Unit file does not exist"

If you get this error, the service files aren't in the right place:

```bash
# Find where they should be:
systemctl --user --help | grep "UNIT FILE"
# Usually: ~/.config/systemd/user/

# Copy them there:
cp ~/telemon/systemd/telemon*.service ~/.config/systemd/user/
cp ~/telemon/systemd/telemon.timer ~/.config/systemd/user/
systemctl --user daemon-reload
```

### Debugging

Run telemon manually with debug logging:
```bash
# Edit .env first:
LOG_LEVEL="DEBUG"

# Then run:
cd ~/telemon && bash telemon.sh

# Or via systemd with debug output:
systemctl --user start telemon.service
journalctl --user -u telemon -n 50
```

## Comparison: Cron vs Systemd

| Feature | Cron | Systemd Timer |
|---------|------|---------------|
| **Setup** | `crontab -e` | `systemctl enable` |
| **Logging** | File-based | `journalctl` |
| **Status Check** | `crontab -l` | `systemctl status` |
| **Failed Job Alert** | ❌ No | ✅ Yes (systemd can notify) |
| **Dependency** | None | Can wait for network.target |
| **Accuracy** | ±1 minute | Millisecond precision |
| **Resource Control** | ❌ No | ✅ cgroups, CPU/memory limits |
| **Container Support** | Often missing | Always available |

## User vs System systemd

| Use Case | User Mode | System Mode |
|----------|-----------|-------------|
| Install in `~/telemon` | ✅ Perfect | ⚠️ Needs config |
| Install in `/opt/telemon` | ❌ Wrong | ✅ Perfect |
| Root required | ❌ No | ✅ Yes |
| Logs location | `journalctl --user` | `journalctl` |
| Multi-user support | ❌ Per-user | ✅ System-wide |

## See Also

- [Main README](../README.md) — General Telemon documentation
- [Admin CLI](../README.md#cli-reference) — `telemon-admin.sh` commands
- [Testing & Debugging](../README.md#testing--debugging) — Troubleshooting guide
