# Telemon

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> A lightweight, self-managing system health monitor that sends Telegram alerts when things go wrong. Set it and forget it.

Telemon acts as a "silent guardian" for your server — it watches CPU, memory, disk, connectivity, and critical processes, but only bothers you when something actually changes state. No spam, just signal. Once installed, it runs indefinitely without babysitting.

## Features

- **Set & Forget** — Runs via cron every 5 minutes, self-rotates logs, survives reboots
- **Smart Alerts** — Only notifies on state changes (OK → WARNING, WARNING → CRITICAL, or back to OK)
- **Confirmation Count** — Configurable consecutive check requirement prevents false alarms from transient spikes
- **System Vitals** — CPU load, memory, disk space, internet connectivity
- **Process Monitoring** — System processes, Docker containers, PM2 processes
- **Website Monitoring** — HTTP/HTTPS endpoint health, SSL certificate expiry
- **HTML Telegram Messages** — Clean, emoji-rich alerts with hostname and timestamps
- **State Persistence** — Tracks state across reboots, knows when things resolve
- **Self-Healing Logs** — Automatic log rotation prevents disk space issues

## Quick Start

### Prerequisites

You need a Telegram bot token and chat ID. If you don't have these, follow [Getting Telegram Credentials](#getting-telegram-credentials) first.

### Installation

```bash
# 1. Clone the repository
git clone https://github.com/yourusername/telemon.git
cd telemon

# 2. Copy the example config and edit it
cp .env.example .env
nano .env  # Add your Telegram bot token and chat ID

# 3. Run the installer
bash install.sh
```

**That's it.** Telemon will send you a test message and then monitor silently until something needs your attention.

## Configuration

Edit `.env` to customize your monitoring:

```bash
# Telegram credentials (required)
TELEGRAM_BOT_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"

# Enable/disable checks (set to "false" to disable)
ENABLE_CPU_CHECK=true
ENABLE_MEMORY_CHECK=true
ENABLE_DISK_CHECK=true
ENABLE_SWAP_CHECK=true
ENABLE_IOWAIT_CHECK=true
ENABLE_ZOMBIE_CHECK=true
ENABLE_INTERNET_CHECK=true
ENABLE_SYSTEM_PROCESSES=true
ENABLE_FAILED_SYSTEMD_SERVICES=true
ENABLE_DOCKER_CONTAINERS=true
ENABLE_PM2_PROCESSES=true
ENABLE_SITE_MONITOR=false    # Set to true to enable website monitoring

# Alert thresholds
CPU_THRESHOLD_WARN=70          # % of available cores
CPU_THRESHOLD_CRIT=80
MEM_THRESHOLD_WARN=15          # % free memory remaining
MEM_THRESHOLD_CRIT=10
DISK_THRESHOLD_WARN=85         # % disk used
DISK_THRESHOLD_CRIT=90
SWAP_THRESHOLD_WARN=50         # % swap used
SWAP_THRESHOLD_CRIT=80
IOWAIT_THRESHOLD_WARN=30       # % CPU waiting for I/O
IOWAIT_THRESHOLD_CRIT=50
ZOMBIE_THRESHOLD_WARN=5        # number of zombie processes
ZOMBIE_THRESHOLD_CRIT=20

# Website monitoring (requires ENABLE_SITE_MONITOR=true)
SITE_EXPECTED_STATUS=200       # Expected HTTP status code
SITE_MAX_RESPONSE_MS=10000     # Response time threshold (milliseconds)
SITE_CHECK_SSL=false           # Enable SSL certificate expiry checks
SITE_SSL_WARN_DAYS=7           # Days before expiry to warn

# Confirmation count (prevents false alarms)
CONFIRMATION_COUNT=3           # Alert only after 3 consecutive matches
                               # With 5-min cron = 15 min confirmation

# What to monitor (space-separated lists, empty to disable)
CRITICAL_SYSTEM_PROCESSES="sshd docker"
CRITICAL_CONTAINERS="postgres zilean"
CRITICAL_PM2_PROCESSES="hound"
CRITICAL_SITES=""              # URLs to monitor, e.g., "https://example.com"
```

### Disabling Checks

**To disable a specific check**, set its `ENABLE_` variable to `false`:

```bash
# Don't monitor swap (e.g., if system has no swap)
ENABLE_SWAP_CHECK=false

# Don't monitor PM2 (e.g., if not using PM2)
ENABLE_PM2_PROCESSES=false

# Don't monitor Docker (e.g., if not using Docker)
ENABLE_DOCKER_CONTAINERS=false
```

**To disable process/container monitoring**, set the list to empty:

```bash
# Disable all system process monitoring
CRITICAL_SYSTEM_PROCESSES=""

# Disable all container monitoring  
CRITICAL_CONTAINERS=""
```

### Website Monitoring

Telemon can monitor HTTP/HTTPS endpoints for availability, response time, and SSL certificate health.

**Basic setup:**

```bash
# Enable site monitoring
ENABLE_SITE_MONITOR=true

# Add URLs to monitor (space-separated)
CRITICAL_SITES="https://example.com https://api.example.com"
```

**Advanced per-site configuration:**

You can customize settings per-site using pipe-separated parameters:

```bash
# Format: URL|param1=value1|param2=value2
CRITICAL_SITES="
  https://example.com|max_response_ms=5000|check_ssl=true
  https://api.example.com|expected_status=200|max_response_ms=3000
  https://status.example.com|expected_status=204
"
```

Available parameters:
- `expected_status` — HTTP status code expected (default: 200)
- `max_response_ms` — Response time threshold in milliseconds (default: 10000)
- `check_ssl` — Enable SSL certificate expiry checking (default: false)

**SSL certificate monitoring:**

```bash
# Enable SSL checks globally
SITE_CHECK_SSL=true
SITE_SSL_WARN_DAYS=7    # Warn when cert expires in 7 days

# Or enable per-site
CRITICAL_SITES="https://example.com|check_ssl=true"
```

**Alert conditions:**
- 🚨 **CRITICAL**: Site unreachable, wrong HTTP status, or SSL certificate expired
- ⚠️ **WARNING**: Slow response time, SSL expires soon, or SSL verification issues
- ✅ **RESOLVED**: Site healthy again

### Getting Telegram Credentials

#### Step 1: Create a Bot

1. Open Telegram and message [@BotFather](https://t.me/botfather)
2. Send `/newbot` command
3. Follow prompts:
   - Enter a name for your bot (e.g., "MyServer Monitor")
   - Enter a username (must end in `bot`, e.g., `myserver_monitor_bot`)
4. BotFather will give you a token like:
   ```
   123456789:ABCdefGHIjklMNOpqrSTUvwxyz
   ```
5. **Copy this token** — you'll need it for `.env`

#### Step 2: Get Your Chat ID

**Option A (Fastest):**
1. Message [@userinfobot](https://t.me/userinfobot)
2. It replies with your user ID (e.g., `123456789`)
3. **Copy this number** — that's your `TELEGRAM_CHAT_ID`

**Option B (If Option A doesn't work):**
1. Message your new bot (send any message)
2. Visit this URL in your browser:
   ```
   https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates
   ```
3. Look for `"chat":{"id":123456789` — that number is your chat ID

#### Step 3: Test Your Bot

Before installing Telemon, test that your bot works:

```bash
# Replace with your actual token and chat ID
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>" \
  -d "text=Test message from Telemon"
```

If you receive the message in Telegram, you're ready to proceed.

## How It Works

### Confirmation Count

Telemon uses a confirmation mechanism to filter out brief spikes:

```
Check 1: CPU=85% (CRITICAL) → count=1/3, no alert
Check 2: CPU=88% (CRITICAL) → count=2/3, no alert 
Check 3: CPU=87% (CRITICAL) → count=3/3, 🚨 ALERT!
```

Set `CONFIRMATION_COUNT=1` for immediate alerts (no confirmation).

### Log Rotation

Telemon includes built-in log rotation to prevent disk space issues:

- **Self-rotation**: When logs exceed 10MB, they automatically rotate (keeps 5 backups)
- **logrotate integration**: If system logrotate is available, installer sets up daily rotation

Rotated logs: `telemon.log.1`, `telemon.log.2`, etc. (compressed after first rotation)

### State File Format

The state file (`/tmp/telemon_sys_alert_state`) tracks:
- Current state: `OK`, `WARNING`, or `CRITICAL`
- Consecutive count: how many times this state has been seen

Example:
```
cpu=CRITICAL:2
mem=OK:0
disk_root=WARNING:1
container_postgres=OK:0
```

### Alert Behavior

| Scenario | Action |
|----------|--------|
| First run | Bootstrap message with current status |
| State unchanged | Silent |
| OK → WARNING | Alert after confirmation count |
| OK → CRITICAL | Alert after confirmation count |
| CRITICAL → OK | Resolution alert after confirmation |
| WARNING → OK | Resolution alert after confirmation |

## Manual Operations

```bash
# Run check manually
bash telemon.sh

# View logs
tail -f telemon.log
tail -f telemon_cron.log

# Administration (backup, restore, status, validate)
bash telemon-admin.sh status      # Show current status
bash telemon-admin.sh backup      # Create backup
bash telemon-admin.sh restore <path>  # Restore from backup
bash telemon-admin.sh validate    # Validate configuration
bash telemon-admin.sh logs 50     # View last 50 log lines
bash telemon-admin.sh reset-state # Reset alert state

# Update to latest version
bash update.sh

# Uninstall
bash uninstall.sh        # Keep config and logs
bash uninstall.sh --full   # Remove everything

# Reset state (forces fresh alerts)
rm /tmp/telemon_sys_alert_state

# Remove cron job
crontab -e  # delete the telemon line
```

## Alternative Deployment Methods

### Systemd Timer (Alternative to Cron)

Telemon can run as a systemd timer for better integration with modern Linux systems:

```bash
# The install script creates systemd files automatically
# To use systemd instead of cron:
sudo systemctl enable telemon.timer
sudo systemctl start telemon.timer

# Check status
systemctl status telemon.timer
journalctl -u telemon -f
```

See [systemd/README.md](systemd/README.md) for detailed setup.

### Docker

Run Telemon in a container:

```bash
# Build and run with docker-compose
docker-compose up -d

# Or run manually
docker build -t telemon .
docker run -v $(pwd)/.env:/opt/telemon/.env:ro telemon
```

See [docker-compose.yml](docker-compose.yml) for configuration options.

## Requirements

### Operating System Support

Telemon is designed for **Linux systems** and has been tested on:

| Distribution | Status | Notes |
|--------------|--------|-------|
| Ubuntu 20.04+ | ✅ Fully supported | Primary development target |
| Debian 11+ | ✅ Fully supported | Systemd services work out of box |
| CentOS/RHEL 8+ | ✅ Supported | May need EPEL for some tools |
| Alpine Linux | ⚠️ Partial | BusyBox tools may differ |
| macOS | ❌ Not supported | Uses Linux-specific /proc filesystem |
| Windows WSL | ⚠️ Partial | Some /proc metrics may differ |

### Software Requirements

All required tools are pre-installed on most Linux distributions:

- **Bash 4.0+** (standard on all modern Linux)
- **curl** (for Telegram API calls)
- **Standard Unix tools**: `awk`, `nproc`, `df`, `pgrep`, `ps`, `ping`
- **Optional**: `docker` (for container monitoring)
- **Optional**: `pm2` (for PM2 process monitoring)
- **Optional**: `logrotate` (for system log rotation)

### Why Linux Only?

Telemon reads from Linux-specific interfaces:
- `/proc/loadavg` — CPU load information
- `/proc/meminfo` — Memory statistics  
- `/proc/swaps` — Swap usage
- `/proc/stat` — I/O wait metrics
- `/proc/[pid]/stat` — Process states (for zombie detection)

These are not available on macOS or Windows natively.

## File Structure

```
telemon/
├── telemon.sh              # Main monitoring script
├── install.sh              # Setup script (cron, permissions)
├── uninstall.sh            # Clean removal script
├── update.sh               # Update to latest version
├── telemon-admin.sh        # Administration utility
├── .env.example            # Configuration template
├── .env                    # Your actual config (gitignored)
├── .gitignore              # Excludes .env and logs
├── LICENSE                 # MIT License
├── README.md               # This file
├── CHANGELOG.md            # Version history
├── CONTRIBUTING.md         # Contribution guidelines
├── AGENTS.md               # Architecture documentation
├── telemon-logrotate.conf  # Logrotate configuration
├── systemd/                # Systemd service files
│   ├── telemon@.service
│   ├── telemon.timer
│   └── README.md
├── Dockerfile              # Docker image
├── docker-compose.yml      # Docker Compose config
└── docs/                   # Documentation
    ├── man/
    │   └── telemon.1       # Man page
    ├── QUICKREF.md         # Quick reference card
    └── TROUBLESHOOTING.md  # Troubleshooting guide
```

## Documentation

- [README.md](README.md) - This file (setup and usage)
- [AGENTS.md](AGENTS.md) - Architecture and agent behavior
- [docs/QUICKREF.md](docs/QUICKREF.md) - Quick reference card
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Troubleshooting guide
- [docs/man/telemon.1](docs/man/telemon.1) - Man page
- [CONTRIBUTING.md](CONTRIBUTING.md) - Contribution guidelines
- [CHANGELOG.md](CHANGELOG.md) - Version history

## Architecture

See [AGENTS.md](AGENTS.md) for detailed architecture documentation including:
- Core agent behavior
- State management
- Alert format specification
- Integration notes

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed troubleshooting with flowcharts.

**Quick fixes:**

| Problem | Quick Solution |
|---------|---------------|
| No alerts received? | Run `bash telemon-admin.sh validate` to check config |
| False alarms? | Increase `CONFIRMATION_COUNT` in `.env` |
| Docker checks failing? | Add user to docker group: `sudo usermod -aG docker $USER` |
| State stuck? | Run `bash telemon-admin.sh reset-state` |
| Need to update? | Run `bash update.sh` |

**Common checks:**
- Check `.env` has valid `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`
- Run manually: `bash telemon.sh` and check output
- Verify cron job: `crontab -l`
- View logs: `bash telemon-admin.sh logs 100`

## Set & Forget Guarantee

Telemon is designed to run indefinitely without maintenance:

| Concern | How Telemon Handles It |
|---------|------------------------|
| **Disk space** | Self-rotating logs (10MB limit, 5 backups) |
| **Reboots** | Cron job persists, state file survives |
| **False alarms** | Confirmation count filters transient spikes |
| **Silent failures** | First-run bootstrap confirms Telegram works |
| **Log growth** | Automatic rotation + compression |
| **Config errors** | Script validates `.env` on startup, logs errors |

**Expected maintenance:** None. Just watch for Telegram alerts.

**Optional check-ins:**
- Monthly: `tail telemon.log` to verify it's still running
- Yearly: Review if thresholds still match your workload

## License

MIT License — see [LICENSE](LICENSE) file.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed contribution guidelines.

Quick start:
1. Fork the repository
2. Create a feature branch
3. Run tests: `bash telemon-admin.sh validate`
4. Submit a pull request

---

Made with 💻 for headless servers everywhere.
