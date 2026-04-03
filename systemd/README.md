# Telemon Systemd Installation Guide

Telemon can run as a systemd timer instead of (or alongside) cron. This provides better logging, status visibility, and integration with modern Linux systems.

## Quick Setup

The install script automatically creates systemd files if you have write access to `/etc/systemd/system`:

```bash
bash install.sh
# Then enable the timer:
sudo systemctl enable telemon.timer
sudo systemctl start telemon.timer
```

## Manual Setup

If you need to set up systemd manually:

### 1. Copy Service and Timer Files

```bash
sudo cp systemd/telemon@.service /etc/systemd/system/
sudo cp systemd/telemon.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

### 2. Enable and Start Timer

```bash
# For current user
sudo systemctl enable telemon@${USER}.timer
sudo systemctl start telemon@${USER}.timer
```

### 3. Verify Status

```bash
# Check timer status
systemctl status telemon.timer

# Check service status
systemctl status telemon@${USER}.service

# View all timers
systemctl list-timers --all
```

## Managing the Service

```bash
# Stop the timer
sudo systemctl stop telemon.timer

# Disable from auto-start
sudo systemctl disable telemon.timer

# Run manually
sudo systemctl start telemon@${USER}.service

# View logs
journalctl -u telemon@${USER}.service -f
```

## Switching from Cron to Systemd

1. Remove the cron job:
   ```bash
   crontab -e
   # Delete the line containing telemon.sh
   ```

2. Enable systemd timer:
   ```bash
   sudo systemctl enable telemon.timer
   sudo systemctl start telemon.timer
   ```

## Switching from Systemd to Cron

1. Disable systemd timer:
   ```bash
   sudo systemctl stop telemon.timer
   sudo systemctl disable telemon.timer
   ```

2. Re-run install script:
   ```bash
   bash install.sh
   ```

## Troubleshooting

### Permission Denied

If you see permission errors, ensure the service file uses the correct user:

```bash
# Edit the service file
sudo systemctl edit telemon@${USER}.service

# Add:
[Service]
User=your-username
```

### Logs Not Written

Check that the log directory exists and is writable:

```bash
ls -la ~/telemon/
# Should show telemon.log and telemon_cron.log (or be writable)
```

### Timer Not Running

Check for errors:

```bash
systemctl status telemon.timer
journalctl -u telemon.timer
```
