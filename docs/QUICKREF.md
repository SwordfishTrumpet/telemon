# Telemon Quick Reference Card

## Installation
```bash
git clone https://github.com/yourusername/telemon.git
cd telemon
cp .env.example .env
# Edit .env with your Telegram credentials
nano .env
bash install.sh
```

## Daily Commands

| Command | Description |
|---------|-------------|
| `bash telemon.sh` | Run check manually |
| `tail -f telemon.log` | Watch logs in real-time |
| `bash telemon-admin.sh status` | Show current status |
| `bash telemon-admin.sh logs 20` | View last 20 log lines |

## Administration

| Command | Description |
|---------|-------------|
| `bash telemon-admin.sh backup` | Create backup |
| `bash telemon-admin.sh restore <path>` | Restore from backup |
| `bash telemon-admin.sh validate` | Check configuration |
| `bash telemon-admin.sh reset-state` | Reset alert state |
| `bash update.sh` | Update to latest version |
| `bash uninstall.sh` | Remove from system |

## Configuration Quick Edit

```bash
# Edit config
nano .env

# Common changes:
ENABLE_DOCKER_CONTAINERS=true          # Enable Docker monitoring
CRITICAL_CONTAINERS="postgres redis"   # Set containers to watch
CONFIRMATION_COUNT=1                   # Immediate alerts (no confirmation)
CPU_THRESHOLD_CRIT=90                  # Raise CPU threshold
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| No alerts | Check `.env` credentials, run `bash telemon-admin.sh validate` |
| False alarms | Increase `CONFIRMATION_COUNT` in `.env` |
| Docker checks fail | Add user to docker group: `sudo usermod -aG docker $USER` |
| State stuck | `bash telemon-admin.sh reset-state` |
| Logs too big | Self-rotating at 10MB, or use logrotate |

## Systemd (Alternative to Cron)

```bash
# Enable systemd timer
sudo systemctl enable telemon.timer
sudo systemctl start telemon.timer

# Check status
systemctl status telemon.timer
journalctl -u telemon -f
```

## File Locations

| File | Purpose |
|------|---------|
| `telemon.sh` | Main script |
| `.env` | Configuration |
| `telemon.log` | Detailed logs |
| `telemon_cron.log` | Cron output |
| `/tmp/telemon_sys_alert_state` | State file |

## Alert States

- 🔴 **CRITICAL** - Immediate attention needed
- 🟠 **WARNING** - Monitor closely
- 🟢 **OK** - Healthy (resolution alerts)

## Support

- Issues: https://github.com/yourusername/telemon/issues
- Docs: https://github.com/yourusername/telemon/blob/main/README.md
