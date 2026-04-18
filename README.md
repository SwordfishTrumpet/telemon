# Telemon

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI](https://github.com/SwordfishTrumpet/telemon/workflows/CI/badge.svg)](https://github.com/SwordfishTrumpet/telemon/actions)
[![GitHub release](https://img.shields.io/github/v/release/SwordfishTrumpet/telemon)](https://github.com/SwordfishTrumpet/telemon/releases)
[![GitHub stars](https://img.shields.io/github/stars/SwordfishTrumpet/telemon?style=social)](https://github.com/SwordfishTrumpet/telemon/stargazers)
[![GitHub issues](https://img.shields.io/github/issues/SwordfishTrumpet/telemon)](https://github.com/SwordfishTrumpet/telemon/issues)

> Lightweight, self-managing system health monitor with Telegram, webhook, and email alerts. Set it and forget it.

Telemon watches your Linux server — CPU, memory, disk, containers, services, ports, SSL certs, hardware health, and more — and only alerts you when something **changes state**. No spam, just signal. It runs via cron every 5 minutes and requires zero ongoing maintenance.

## 🚀 One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash
```

**That's it.** The installer will prompt for your Telegram credentials and configure everything automatically.

For **silent/CI/CD installs** (no prompts):

```bash
TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="yyy" \
  curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --silent
```

[📖 Full installation options](#quick-install-one-liner) | [🔧 Manual install](#quick-start-manual-install)

## Features

### Core System Monitoring
- **CPU Load** — 1-minute load average as percentage of available cores
- **Memory** — Available memory percentage (inverted thresholds: lower = worse)
- **Disk Space** — Per-partition monitoring, auto-filters tmpfs/overlay/snap
- **Swap Usage** — Swap partition monitoring, gracefully skips if no swap
- **I/O Wait** — CPU time spent waiting for disk I/O (stateful differential sampling, no blocking sleep)
- **Zombie Processes** — Detects processes stuck in Z state
- **Internet Connectivity** — Ping-based reachability with configurable target and failure threshold

### Process & Service Monitoring
- **System Processes** — Monitors via `pgrep` with `systemctl` fallback (gracefully skips on non-systemd systems)
- **Failed Systemd Services** — System-wide scan for failed units, lists first 3 with overflow count (gracefully skips if systemctl unavailable)
- **Docker Containers** — Status and health checks (`running`, `unhealthy`, `restarting`, `missing`); silently skips if no containers configured
- **PM2 Processes** — Node.js process monitoring via `pm2 jlist` with secure Python3 JSON parsing

### Website & Endpoint Monitoring
- **HTTP/HTTPS Health** — Availability, HTTP status codes, and response times
- **Per-Site Overrides** — Customize expected status, timeout, and SSL settings per URL via pipe-separated parameters
- **SSL Certificate Expiry** — Cross-platform via `openssl s_client` with GNU/BSD/python3 date parsing fallback

### Extended Monitoring
- **TCP Port Checks** — Reachability testing for arbitrary `host:port` pairs via `/dev/tcp`
- **CPU Temperature** — Thermal monitoring via `lm-sensors` (`sensors` command)
- **DNS Resolution** — Health checking via `dig`, `nslookup`, or `host` (auto-detected)
- **GPU Monitoring** — NVIDIA via `nvidia-smi` (temp, util, VRAM) or Intel via `intel_gpu_top` (render/video util, freq, temp)
- **UPS / Battery** — Charge level monitoring via `upower` or `apcaccess`
- **Network Bandwidth** — Interface throughput monitoring against Mbit/s thresholds
- **Log Pattern Matching** — Watch log files for regex patterns (e.g., `ERROR`, `OOM`); shows first 3 matching lines, truncated at 200 chars
- **File Integrity** — SHA256 checksum monitoring for critical files (`/etc/passwd`, configs, etc.)
- **Configuration Drift Detection** — Rich change tracking with unified diffs, metadata changes (size, permissions, owner), and user attribution. Filters comment-only changes, redacts sensitive files.
- **Cron Job Heartbeats** — Detect stale cron jobs via heartbeat file age tracking

### DNS Record Monitoring
- **Record Type Validation** — Verify A, AAAA, MX, TXT, CNAME, NS, SOA, PTR, SRV, CAA records
- **Value Matching** — Compare resolved values against expected values (supports wildcards)
- **Multiple Nameservers** — Optionally use specific DNS server for queries
- **Security Focused** — Validates domains, checks DMARC/SPF records for email security

### Predictive Resource Exhaustion
- **Trend Tracking** — Records metric snapshots across runs in a compact trend file
- **Linear Regression** — Calculates growth rate from historical datapoints using least-squares regression (pure awk)
- **Exhaustion Prediction** — Fires a WARNING when disk, memory, swap, or inodes are projected to hit 100% within a configurable horizon
- **Inode Prediction** — Tracks inode usage per mountpoint alongside disk space
- **No Dependencies** — Pure Bash + awk, zero external tools required

### Fleet Monitoring (Multi-Server)
- **Dead Man's Switch** — Each instance writes a heartbeat file (or pings a webhook) after every run, proving liveness
- **Fleet Heartbeat Check** — A designated instance monitors a shared heartbeat directory and alerts when sibling servers go silent
- **Server Identity** — `SERVER_LABEL` provides human-readable names in all alerts and heartbeat files
- **Stale Detection** — WARNING when a server's heartbeat exceeds the threshold (default: 15m), CRITICAL at 2× threshold
- **Missing Server Detection** — CRITICAL when an expected server has never checked in
- **Fleet Status CLI** — `telemon-admin.sh fleet-status` prints a color-coded fleet overview table
- **Two Heartbeat Modes** — File-based (NFS/shared storage) for fleet monitoring, or webhook (Healthchecks.io, UptimeRobot) for external monitoring

### Hardware Monitoring
- **NVMe / SMART Health** — Critical warning byte, endurance wear (warn 80%, crit 95%), temperature, and media errors via `smartctl`

### Plugin System
- **Directory-Based Plugins** — Place executable scripts in `checks.d/` to extend Telemon without modifying core code
- **Simple Output Format** — Plugins output `STATE|KEY|DETAIL` for automatic integration
- **Security-First** — Plugins run with timeout, symlinks skipped, output validated before processing
- **Zero Dependencies** — Pure Bash plugins work; any language that outputs text works

### Database Health Checks
- **MySQL/MariaDB** — Connection check and replication lag monitoring
- **PostgreSQL** — Connection check and streaming replication lag monitoring  
- **Redis** — Connection check, authentication validation, master/replica status
- **Configurable Timeouts** — Per-database timeout settings to prevent hanging

### Alert Channels

Telemon sends alerts through up to three channels simultaneously:

| Channel | Config | Dependencies |
|---------|--------|-------------|
| **Telegram** | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | curl |
| **Webhook** | `WEBHOOK_URL` (Slack, Discord, ntfy, n8n, etc.) | python3 |
| **Email** | `EMAIL_TO`, `EMAIL_FROM` | sendmail or msmtp |

- **Telegram** is the primary channel. If it fails, messages are queued and retried next cycle.
- **Webhook** sends a JSON POST to any URL. Works with Slack, Discord, ntfy, and generic endpoints. See [Webhook Payload Format](#webhook-payload-format).
- **Email** sends plain-text via `sendmail` or `msmtp`. Header injection is prevented.

### Alert Intelligence
- **State Change Detection** — Only notifies on transitions (OK ↔ WARNING ↔ CRITICAL), never repeats
- **Confirmation Count** — Configurable consecutive check requirement (default: 3 checks = 15 min) prevents false alarms
- **Alert Rate Limiting** — Per-key cooldown (`ALERT_COOLDOWN_SEC`, default 900s) prevents floods from flapping checks
- **Alert Batching** — Collects all state changes in a cycle into a single message
- **Resolution Alerts** — Immediate notification when a confirmed problem resolves
- **First-Run Bootstrap** — Sends initial status summary confirming monitoring is active
- **Digest Mode** — `--digest` bypasses confirmation count to report all current states immediately
- **Retry Queue** — Failed Telegram alerts are queued to disk and retried next cycle
- **Top Process Capture** — Includes top N CPU/memory consuming processes in alerts when under stress
- **Alert Escalation** — Separate webhook for alerts that remain unresolved after N minutes
- **Enhanced Audit Logging** — Structured JSON audit logs for compliance and security analysis (state changes, alerts, escalations)

### Auto-Remediation
- **Automatic Service Restart** — `AUTO_RESTART_SERVICES` lists systemd services to auto-restart on detected failure
- Runs after checks, before alert dispatch — remediation attempts are noted in alert messages

### Maintenance Windows
- **Flag File** — `touch /tmp/telemon_maint` to silence all alerts during planned work; `rm` when done
- **Scheduled Windows** — Recurring windows via `MAINT_SCHEDULE` (e.g., `"Sun 02:00-04:00;Sat 03:00-05:00"`)

### Exports & Integrations
- **Prometheus** — Writes metrics to textfile for `node_exporter --collector.textfile` — no HTTP server needed. See [Prometheus Metrics](#prometheus-metrics).
- **JSON Status** — Writes current state to JSON file after each run; serve with nginx/caddy for a status API. See [JSON Status Format](#json-status-format).
- **Static Status Page** — Generates a self-contained HTML dashboard with `telemon.sh --generate-status-page`. No web server required — can be served via nginx/caddy or uploaded to static hosting. See [Static HTML Status Page](#static-html-status-page).
- **Health Digest** — `telemon.sh --digest` sends a full health summary even when everything is OK (schedule daily/weekly via cron)

### Security
- **Credential Protection** — Bot token passed via process substitution, hidden from `ps` and `/proc/*/cmdline`; falls back to secure temp file in restricted containers
- **Config Protection** — `.env` enforced to `chmod 600` (owner-only)
- **State File Protection** — Symlink attack prevention, atomic writes via temp file + `mv`, `umask 077`
- **Heartbeat File Protection** — Symlink-safe writes via `mv -T`, sticky bit on shared directories, no infrastructure details leaked (counts only, not key names)
- **Code Injection Prevention** — PM2 names via environment variables, TCP port validation, hostname via env vars in Python
- **HTML Escaping** — All user-supplied content sanitized (including single quotes) for Telegram HTML mode; untrusted heartbeat data validated against allowlists before embedding in alerts
- **Email Safety** — Header injection prevention in email alerts (newlines, carriage returns, tabs, and null bytes stripped)

### Reliability
- **Lock File** — Prevents overlapping runs via `flock` (atomic) with PID file fallback; includes automatic stale lock detection (breaks locks older than 5 minutes if holder process is dead)
- **Command Timeouts** — All external commands wrapped with configurable timeout (default 30s)
- **Self-Healing Logs** — Automatic rotation (configurable via `LOG_MAX_SIZE_MB` and `LOG_MAX_BACKUPS`, defaults: 10MB, 5 backups)
- **State Persistence** — Tracks state across reboots, survives cron/systemd restarts

### Check Reference

<details>
<summary><strong>Complete check reference table</strong> (click to expand)</summary>

| Check | Function | Enable Flag | Default | Dependencies | State Key | Thresholds |
|-------|----------|-------------|---------|-------------|-----------|------------|
| CPU Load | `check_cpu` | `ENABLE_CPU_CHECK` | `true` | `/proc/loadavg` | `cpu` | `CPU_THRESHOLD_WARN=70`, `_CRIT=80` (% of cores) |
| Memory | `check_memory` | `ENABLE_MEMORY_CHECK` | `true` | `/proc/meminfo` | `mem` | `MEM_THRESHOLD_WARN=15`, `_CRIT=10` (% free, inverted) |
| Disk Space | `check_disk` | `ENABLE_DISK_CHECK` | `true` | `df` | `disk_<mount>` | `DISK_THRESHOLD_WARN=85`, `_CRIT=90` (% used) |
| Swap | `check_swap` | `ENABLE_SWAP_CHECK` | `true` | `/proc/swaps` | `swap` | `SWAP_THRESHOLD_WARN=50`, `_CRIT=80` (% used) |
| I/O Wait | `check_iowait` | `ENABLE_IOWAIT_CHECK` | `true` | `/proc/stat` | `iowait` | `IOWAIT_THRESHOLD_WARN=30`, `_CRIT=50` (% CPU) |
| Zombies | `check_zombies` | `ENABLE_ZOMBIE_CHECK` | `true` | `ps` | `zombies` | `ZOMBIE_THRESHOLD_WARN=5`, `_CRIT=20` (count) |
| Internet | `check_internet` | `ENABLE_INTERNET_CHECK` | `true` | `ping` | `internet` | `PING_FAIL_THRESHOLD=3` (consecutive failures) |
| Sys Processes | `check_system_processes` | `ENABLE_SYSTEM_PROCESSES` | `true` | `pgrep`, `systemctl` | `proc_<name>` | Binary: running or not |
| Failed Systemd | `check_failed_systemd_services` | `ENABLE_FAILED_SYSTEMD_SERVICES` | `true` | `systemctl` | `systemd_failed` | Binary: any failed units |
| Docker | `check_docker_containers` | `ENABLE_DOCKER_CONTAINERS` | `false` | `docker` | `container_<name>` | Binary: running/healthy or not |
| PM2 | `check_pm2_processes` | `ENABLE_PM2_PROCESSES` | `false` | `pm2`, `python3` | `pm2_<name>` | Binary: online or not |
| Sites | `check_sites` | `ENABLE_SITE_MONITOR` | `false` | `curl`, `openssl` | `site_<hash>` | Per-site: status, response time, SSL expiry |
| NVMe | `check_nvme_health` | `ENABLE_NVME_CHECK` | `false` | `smartctl` | `nvme_health` | Critical warning byte, endurance 80/95%, temp |
| TCP Ports | `check_tcp_ports` | `ENABLE_TCP_PORT_CHECK` | `false` | `/dev/tcp` | `port_<hash>` | Binary: reachable or not |
| CPU Temp | `check_cpu_temp` | `ENABLE_TEMP_CHECK` | `false` | `sensors` | `cpu_temp` | `TEMP_THRESHOLD_WARN=75`, `_CRIT=90` (°C) |
| DNS | `check_dns` | `ENABLE_DNS_CHECK` | `false` | `dig`/`nslookup`/`host` | `dns` | Binary: resolves or not |
| DNS Records | `check_dns_records` | `ENABLE_DNS_RECORD_CHECK` | `false` | `dig` | `dnsrecord_<domain>_<type>` | Binary: matches expected value |
| GPU | `check_gpu` | `ENABLE_GPU_CHECK` | `false` | `nvidia-smi` or `intel_gpu_top` | `gpu_<idx>` / `gpu_intel` | NVIDIA: `GPU_TEMP_THRESHOLD_WARN=80` (°C). Intel: `GPU_INTEL_UTIL_THRESHOLD_WARN=80` (%), `GPU_INTEL_TEMP_THRESHOLD_WARN=80` (°C) |
| UPS/Battery | `check_ups` | `ENABLE_UPS_CHECK` | `false` | `upower`/`apcaccess` | `ups` | `UPS_THRESHOLD_WARN=30`, `_CRIT=10` (%, inverted) |
| Network BW | `check_network_bandwidth` | `ENABLE_NETWORK_CHECK` | `false` | `/proc/net/dev` | `net_<iface>` | `NETWORK_THRESHOLD_WARN=800`, `_CRIT=950` (Mbit/s) |
| Log Patterns | `check_log_patterns` | `ENABLE_LOG_CHECK` | `false` | `tail`, `grep` | `log_<hash>` | Binary: patterns found or not |
| File Integrity | `check_file_integrity` | `ENABLE_INTEGRITY_CHECK` | `false` | `sha256sum` | `integrity_<hash>` | Binary: checksum changed or not |
| Config Drift | `check_drift_detection` | `ENABLE_DRIFT_DETECTION` | `false` | `diff`, `stat` | `drift_<hash>` | Rich diff, metadata, user attribution |
| Cron Jobs | `check_cron_jobs` | `ENABLE_CRON_CHECK` | `false` | `stat` | `cron_<name>` | `max_age_minutes` per job |
| Fleet | `check_fleet_heartbeats` | `ENABLE_FLEET_CHECK` | `false` | heartbeat files | `fleet_<label>` | `FLEET_STALE_THRESHOLD_MIN=15` |
| Predictive | `check_prediction` | `ENABLE_PREDICTIVE_ALERTS` | `false` | awk | `predict_*` | `PREDICT_HORIZON_HOURS=24` (hours to exhaustion) |
| Plugins | `check_plugins` | `ENABLE_PLUGINS` | `false` | executable scripts in `checks.d/` | `<plugin_key>` | Binary: OK/WARNING/CRITICAL |
| Database | `check_databases` | `ENABLE_DATABASE_CHECKS` | `false` | `mysql`/`psql`/`redis-cli`/`sqlite3` | `mysql_<host>`, `postgres_<host>`, `redis_<host>_<port>`, `sqlite_<hash>` | Binary: connected or not |

</details>

### Deployment Options
- **Cron** — Default: every 5 minutes via crontab
- **Systemd Timer** — Alternative scheduler with journal integration
- **Docker** — Alpine-based container with compose support and host `/proc` mounting
- **One-Line Install** — `curl | bash` installer downloads, configures, and sets up Telemon in one step
- **Local Install** — `bash install.sh` handles dependencies, permissions, cron, logrotate, and test message

## Quick Install (One-Liner)

### Interactive Install (Recommended for First Time)

Install Telemon with a single command. The installer will guide you through configuration:

```bash
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash
```

Or install to a custom directory:

```bash
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- /opt/telemon
```

### Silent/Automated Install (CI/CD, Ansible, Cloud Init)

For automated deployments, use silent mode with environment variables:

```bash
# Basic silent install (auto-detects Docker/PM2)
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrSTUvwxyz" \
TELEGRAM_CHAT_ID="123456789" \
  curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --silent
```

```bash
# Advanced silent install with all options
TELEGRAM_BOT_TOKEN="xxx" \
TELEGRAM_CHAT_ID="yyy" \
SERVER_LABEL="web-prod-01" \
ENABLE_DOCKER=true \
ENABLE_PM2=true \
ENABLE_SITES=true \
SITE_URLS="https://example.com https://api.example.com" \
  curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --silent
```

**Silent Mode Features:**
- ✅ No interactive prompts — perfect for automation
- ✅ Auto-detects Docker and PM2 (enables if found)
- ✅ Uses sensible defaults for all settings
- ✅ Merges with existing `.env` if present (safe for updates)
- ✅ Fails gracefully with error codes for CI/CD
- ✅ Supports both cron and systemd scheduling

**Silent Mode Environment Variables:**

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TELEGRAM_BOT_TOKEN` | Yes | — | Your Telegram bot token |
| `TELEGRAM_CHAT_ID` | Yes | — | Your Telegram chat ID |
| `SERVER_LABEL` | No | `hostname` | Server name in alerts |
| `ENABLE_DOCKER` | No | `auto` | `auto`/`true`/`false` — auto detects docker command |
| `ENABLE_PM2` | No | `auto` | `auto`/`true`/`false` — auto detects pm2 + python3 |
| `ENABLE_SITES` | No | `false` | `true`/`false` — enable website monitoring |
| `SITE_URLS` | No | — | Space-separated URLs (if ENABLE_SITES=true) |
| `TELEMON_SILENT` | No | `false` | Alternative to `--silent` flag |
| `TELEMON_SYSTEMD` | No | `false` | Alternative to `--systemd` flag |

### Systemd Timer Install (Alternative to Cron)

For systems without cron (common in containers and minimal systems), use systemd timer:

```bash
# Interactive install with systemd timer
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --systemd

# Silent install with systemd timer
TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="yyy" \
  curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --silent --systemd
```

**Systemd Features:**
- ✅ Works on systems without `crontab`
- ✅ Auto-detects user vs system install
- ✅ Uses user systemd by default (no root required)
- ✅ Journal integration for logging (`journalctl -u telemon`)

### What the Installer Does

1. **Downloads** the latest Telemon files from GitHub (or copies from local clone)
2. **Configures** your Telegram credentials (interactive or from env vars)
3. **Sets up** optional monitoring (Docker, PM2, websites — auto-detected in silent mode)
4. **Installs** a cron job or systemd timer (runs every 5 minutes)
5. **Validates** the configuration and sends a test alert

### Installer Options

```bash
bash install.sh [OPTIONS] [INSTALL_DIR]

Options:
  --silent      Non-interactive mode (uses env vars for config)
  --systemd     Use systemd timer instead of cron
  --skip-test   Skip the test notification at the end
  --help, -h    Show help message

Examples:
  bash install.sh                          # Interactive, default dir
  bash install.sh /opt/telemon             # Interactive, custom dir
  bash install.sh --silent                 # Silent mode
  bash install.sh --systemd                # Use systemd timer
  bash install.sh --silent --systemd       # Silent + systemd
```

### Requirements for One-Line Install

- Linux server with `curl`, `bash`, and `awk`
- Your Telegram bot token and chat ID ([see below for how to get these](#getting-telegram-credentials))

---

## Quick Start (Manual Install)

### Prerequisites

- Linux server (Ubuntu, Debian, CentOS/RHEL, Alpine)
- Bash 4.0+, curl
- A Telegram bot token and chat ID (see [Getting Telegram Credentials](#getting-telegram-credentials))

### Installation

```bash
# 1. Clone the repository
git clone https://github.com/SwordfishTrumpet/telemon.git
cd telemon

# 2. Copy the example config and edit it
cp .env.example .env
nano .env  # Add your Telegram bot token and chat ID

# 3. Run the installer
bash install.sh
```

**That's it.** Telemon sends you a test message and then monitors silently until something needs your attention.

## Configuration

All configuration lives in `.env`. Key principles:
- Every check has an `ENABLE_*` flag (core checks default `true`, extended checks default `false`)
- Thresholds follow `*_THRESHOLD_WARN` / `*_THRESHOLD_CRIT` pattern
- Lists are space-separated strings
- See `.env.example` for all options with documentation

### Minimal Config

```bash
# Telegram credentials (required)
TELEGRAM_BOT_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"
```

Everything else has sensible defaults. Core checks (CPU, memory, disk, swap, I/O wait, zombies, internet, processes, systemd) are enabled by default.

### Enable/Disable Checks

```bash
# Core checks (default: true)
ENABLE_CPU_CHECK=true
ENABLE_MEMORY_CHECK=true
ENABLE_DISK_CHECK=true
ENABLE_SWAP_CHECK=true
ENABLE_IOWAIT_CHECK=true
ENABLE_ZOMBIE_CHECK=true
ENABLE_INTERNET_CHECK=true
ENABLE_SYSTEM_PROCESSES=true
ENABLE_FAILED_SYSTEMD_SERVICES=true

# Service checks (default: false)
ENABLE_DOCKER_CONTAINERS=false
ENABLE_PM2_PROCESSES=false
ENABLE_SITE_MONITOR=false
ENABLE_NVME_CHECK=false

# Extended checks (default: false)
ENABLE_TCP_PORT_CHECK=false
ENABLE_TEMP_CHECK=false
ENABLE_DNS_CHECK=false
ENABLE_DNS_RECORD_CHECK=false      # Validate specific DNS records
ENABLE_GPU_CHECK=false
ENABLE_UPS_CHECK=false
ENABLE_NETWORK_CHECK=false
ENABLE_LOG_CHECK=false
ENABLE_INTEGRITY_CHECK=false
ENABLE_CRON_CHECK=false

# Fleet monitoring (default: false)
ENABLE_HEARTBEAT=false
ENABLE_FLEET_CHECK=false

# Predictive alerts (default: false)
ENABLE_PREDICTIVE_ALERTS=false

# Exports (default: false)
ENABLE_PROMETHEUS_EXPORT=false
ENABLE_JSON_STATUS=false

# Audit logging (default: false)
ENABLE_AUDIT_LOGGING=false
```

### Thresholds

```bash
# CPU: % of available cores (1-min load avg)
CPU_THRESHOLD_WARN=70
CPU_THRESHOLD_CRIT=80

# Memory: % free remaining (inverted — lower = worse)
MEM_THRESHOLD_WARN=15
MEM_THRESHOLD_CRIT=10

# Disk: % used
DISK_THRESHOLD_WARN=85
DISK_THRESHOLD_CRIT=90

# Swap: % used
SWAP_THRESHOLD_WARN=50
SWAP_THRESHOLD_CRIT=80

# I/O Wait: % CPU time
IOWAIT_THRESHOLD_WARN=30
IOWAIT_THRESHOLD_CRIT=50

# Zombies: process count
ZOMBIE_THRESHOLD_WARN=5
ZOMBIE_THRESHOLD_CRIT=20

# Internet connectivity
PING_TARGET="8.8.8.8"        # Host to ping
PING_FAIL_THRESHOLD=3         # Consecutive failures before alert

# CPU temperature (°C)
TEMP_THRESHOLD_WARN=75
TEMP_THRESHOLD_CRIT=90

# GPU temperature (°C) — NVIDIA only
GPU_TEMP_THRESHOLD_WARN=80
GPU_TEMP_THRESHOLD_CRIT=95

# Intel GPU thresholds (used when intel_gpu_top detected)
GPU_INTEL_UTIL_THRESHOLD_WARN=80   # Render engine utilization %
GPU_INTEL_UTIL_THRESHOLD_CRIT=95
GPU_INTEL_TEMP_THRESHOLD_WARN=80   # °C (if hwmon sensors available)
GPU_INTEL_TEMP_THRESHOLD_CRIT=95

# Network bandwidth (Mbit/s)
NETWORK_THRESHOLD_WARN=800
NETWORK_THRESHOLD_CRIT=950

# Battery/UPS charge (%) — inverted: lower = worse
UPS_THRESHOLD_WARN=30
UPS_THRESHOLD_CRIT=10
```

### Alert Channels

```bash
# Telegram (required)
TELEGRAM_BOT_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"

# Webhook — JSON POST to any URL (optional, requires python3)
WEBHOOK_URL="https://hooks.slack.com/services/xxx/yyy/zzz"

# Email — plain text via sendmail/msmtp (optional)
EMAIL_TO="admin@example.com"
EMAIL_FROM="telemon@myserver.com"  # defaults to telemon@$(hostname)

# Escalation — separate webhook for unresolved alerts (optional, requires python3)
ESCALATION_WEBHOOK_URL="https://hooks.slack.com/services/aaa/bbb/ccc"
ESCALATION_AFTER_MIN=30  # minutes before escalating
```

### Alert Tuning

```bash
# Consecutive checks required before alerting (default: 3)
# With 5-min cron, a spike must persist 15 min to trigger an alert
CONFIRMATION_COUNT=3

# Per-key cooldown between alerts (default: 900s = 15 min)
# Prevents floods from flapping checks. Set to 0 to disable.
ALERT_COOLDOWN_SEC=900

# Top processes included in CPU/memory alerts
TOP_PROCESS_COUNT=5

# Command timeout for external tools (seconds)
CHECK_TIMEOUT=30
```

### What to Monitor

```bash
# System processes (checked via pgrep/systemctl)
CRITICAL_SYSTEM_PROCESSES="sshd cron nginx"

# Docker containers (use names from: docker ps --format '{{.Names}}')
CRITICAL_CONTAINERS="redis nginx myapp"

# PM2 processes
CRITICAL_PM2_PROCESSES="api worker scheduler"

# Websites / endpoints
CRITICAL_SITES="https://example.com https://api.example.com|max_response_ms=3000|check_ssl=true"

# TCP ports
CRITICAL_PORTS="localhost:22 db-server:5432 192.168.1.1:443"

# DNS check domain
DNS_CHECK_DOMAIN="example.com"

# Network interface (auto-detected if empty)
NETWORK_INTERFACE=""

# Log pattern matching
LOG_WATCH_FILES="/var/log/syslog /var/log/auth.log"
LOG_WATCH_PATTERNS="OOM|error|panic"
LOG_WATCH_LINES=100

# File integrity monitoring (sha256sum checksums)
# NOTE: Files must be readable by the user running telemon.
# Running as non-root? Remove /etc/shadow or add sudoers rules.
INTEGRITY_WATCH_FILES="/etc/passwd /etc/ssh/sshd_config"

# Configuration drift detection (rich change tracking with diffs)
ENABLE_DRIFT_DETECTION=true
DRIFT_WATCH_FILES="/etc/nginx/nginx.conf /etc/ssh/sshd_config"
DRIFT_IGNORE_PATTERN="^[+-]?\s*#"  # Ignore comment-only changes
DRIFT_MAX_DIFF_LINES=20             # Limit diff output in alerts
DRIFT_SENSITIVE_FILES="/etc/shadow /etc/gshadow"  # Redact diff for these

# Cron heartbeat tracking (name:touchfile:max_age_minutes)
CRON_WATCH_JOBS="backup:/tmp/backup_heartbeat:1440 report:/tmp/report_heartbeat:60"

# NVMe device
NVME_DEVICE="/dev/nvme0n1"
NVME_TEMP_THRESHOLD_WARN=70    # °C warning
NVME_TEMP_THRESHOLD_CRIT=80    # °C critical

# Auto-restart failed systemd services
AUTO_RESTART_SERVICES="nginx sshd"
```

### Maintenance Windows

```bash
# Flag file — touch to silence, rm when done
MAINT_FLAG_FILE="/tmp/telemon_maint"

# Scheduled recurring windows (semicolon-separated)
# Format: "Day HH:MM-HH:MM"
MAINT_SCHEDULE="Sun 02:00-04:00;Sat 03:00-05:00"
```

### Exports

```bash
# Prometheus textfile export (for node_exporter --collector.textfile)
# NOTE: The directory must be writable by the user running telemon.
# If using node_exporter's default path, run: sudo mkdir -p /var/lib/node_exporter/textfile_collector && sudo chmod 777 /var/lib/node_exporter/textfile_collector
ENABLE_PROMETHEUS_EXPORT=true
PROMETHEUS_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# JSON status file (serve with nginx/caddy for a status API)
ENABLE_JSON_STATUS=true
JSON_STATUS_FILE="/opt/telemon/status.json"
```

### Predictive Resource Exhaustion

```bash
# Enable predictive alerts (disk, memory, swap, inodes)
ENABLE_PREDICTIVE_ALERTS=true

# Alert when exhaustion is projected within this many hours
PREDICT_HORIZON_HOURS=24

# Maximum datapoints to retain per metric (one per run)
PREDICT_DATAPOINTS=48

# Minimum datapoints required before making predictions
PREDICT_MIN_DATAPOINTS=12
```

Telemon uses linear regression on historical datapoints to predict when a resource will reach 100%. For example, with 5-minute cron intervals, 48 datapoints covers 4 hours of history. If the trend line projects exhaustion within 24 hours, a WARNING alert fires.

### Fleet Monitoring

```bash
# Server identity — used in alert headers and heartbeat files
# Defaults to $(hostname) if empty
SERVER_LABEL="web-prod-01"

# --- Heartbeat sender (all instances) ---
# Proves this Telemon instance is alive (dead man's switch)
ENABLE_HEARTBEAT=true
HEARTBEAT_MODE="file"                           # "file" or "webhook"
HEARTBEAT_DIR="/shared/telemon/heartbeats"      # file mode: shared dir (NFS/mount)
# HEARTBEAT_URL="https://hc-ping.com/your-uuid" # webhook mode: Healthchecks.io, etc.

# --- Fleet monitor (one designated instance) ---
# Scans heartbeat directory and alerts on stale/missing servers
ENABLE_FLEET_CHECK=true
FLEET_HEARTBEAT_DIR="/shared/telemon/heartbeats"
FLEET_STALE_THRESHOLD_MIN=15                    # WARNING after 15 min
FLEET_CRITICAL_MULTIPLIER=2                     # CRITICAL at 15*2 = 30 min
FLEET_EXPECTED_SERVERS="web-prod-01 db-prod-01 api-staging"  # alert if never seen
```

**How fleet monitoring works:**

1. Every Telemon instance writes a heartbeat file to a shared directory after each run
2. One (or more) instances have `ENABLE_FLEET_CHECK=true` and scan that directory
3. If a server's heartbeat goes stale → WARNING/CRITICAL alert
4. If an expected server has never written a heartbeat → CRITICAL alert
5. The fleet check automatically skips its own heartbeat file

**Heartbeat file format** (tab-separated, single line):
```
server_label  timestamp  status  check_count  warn_count  crit_count  uptime_seconds
```

**Two deployment patterns:**

| Pattern | Use case |
|---------|----------|
| **File-based** (NFS/shared mount) | Multiple servers on same network; one monitors all |
| **Webhook** (Healthchecks.io, UptimeRobot) | External dead-man's-switch; no fleet directory needed |

> **Note:** Webhook mode only pings an external URL — it does not write files. Fleet monitoring (`ENABLE_FLEET_CHECK`) requires file mode on the sender nodes.

### Plugin System

Enable the plugin system to run custom checks from executable scripts in the `checks.d/` directory:

```bash
# Enable plugin system
ENABLE_PLUGINS=true

# Optional: custom plugin directory (default: ./checks.d)
# CHECKS_DIR="/opt/telemon/custom-checks"
```

**Plugin Output Format:**

Plugins must output a single line in the format: `STATE|KEY|DETAIL`

```
OK|my_custom_check|Everything is working
WARNING|my_custom_check|Resource at 85% threshold
CRITICAL|my_custom_check|Service not responding
```

| Field | Description | Valid Values |
|-------|-------------|--------------|
| `STATE` | Check result | `OK`, `WARNING`, `CRITICAL` |
| `KEY` | State tracking key | Alphanumeric, underscore, hyphen, dot |
| `DETAIL` | Human-readable message | Any text (HTML-escaped by Telemon) |

**Example Plugin:**

```bash
#!/usr/bin/env bash
# checks.d/custom-disk-check.sh

USAGE=$(df /data 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')

if [[ -z "$USAGE" ]]; then
    echo "CRITICAL|data_disk|Mount /data not found"
elif [[ "$USAGE" -ge 90 ]]; then
    echo "CRITICAL|data_disk|Disk /data at ${USAGE}%"
elif [[ "$USAGE" -ge 80 ]]; then
    echo "WARNING|data_disk|Disk /data at ${USAGE}%"
else
    echo "OK|data_disk|Disk /data at ${USAGE}%"
fi
```

**Security Notes:**
- Plugins run with the same permissions as telemon.sh
- Plugins are subject to `CHECK_TIMEOUT` (default: 30s)
- Symlinks in `checks.d/` are skipped (security)
- Invalid output (bad state or key format) is rejected with a warning

### Database Health Checks

Monitor MySQL/MariaDB, PostgreSQL, Redis, and SQLite3 connectivity and health:

```bash
# Enable database checks
ENABLE_DATABASE_CHECKS=true

# MySQL/MariaDB
DB_MYSQL_HOST="localhost"
DB_MYSQL_PORT="3306"
DB_MYSQL_USER="telemon"
DB_MYSQL_PASS="secret"
DB_MYSQL_NAME="mysql"           # Database to connect to

# PostgreSQL
DB_POSTGRES_HOST="localhost"
DB_POSTGRES_PORT="5432"
DB_POSTGRES_USER="telemon"
DB_POSTGRES_PASS="secret"
DB_POSTGRES_NAME="postgres"       # Database to connect to

# Redis
DB_REDIS_HOST="localhost"
DB_REDIS_PORT="6379"
DB_REDIS_PASS=""                  # Leave empty if no password
DB_REDIS_TIMEOUT_SEC=5            # Shorter timeout for Redis (usually fast)

# SQLite3
DB_SQLITE_PATHS="/var/lib/app/data.db /opt/plex/db.sqlite"
DB_SQLITE_SIZE_THRESHOLD_WARN=500   # MB (0 = disabled)
DB_SQLITE_SIZE_THRESHOLD_CRIT=1000  # MB (0 = disabled)
```

**Requirements:**
- MySQL: `mysql` or `mariadb` client package
- PostgreSQL: `psql` client package
- Redis: `redis-cli` client package
- SQLite3: `sqlite3` client package

**Alerts:**
- **CRITICAL**: Connection failure, authentication error, replication lag > 5 minutes, or database corruption (SQLite3)
- **WARNING**: Replication lag > 1 minute (for MySQL/PostgreSQL replica) or size threshold exceeded (SQLite3)
- **State Keys**: `mysql_<host>`, `postgres_<host>`, `redis_<host>_<port>`, `sqlite_<hash>`

### DNS Record Monitoring

Validate specific DNS records (A, AAAA, MX, TXT, CNAME, NS, SOA, PTR, SRV, CAA) against expected values:

```bash
# Enable DNS record monitoring
ENABLE_DNS_RECORD_CHECK=true

# DNS records to validate (comma-separated)
# Format: domain:record_type:expected_value
# Use * as wildcard to check only resolution (not specific value)
# Use * suffix for partial matching (e.g., v=DMARC1*)
DNS_CHECK_RECORDS="example.com:A:93.184.216.34,_dmarc.example.com:TXT:v=DMARC1*,example.com:MX:*"

# Optional: specify nameserver to use (empty = use system default)
DNS_CHECK_NAMESERVER=""
```

**Common Use Cases:**
- **Email Security**: Monitor DMARC (`_dmarc.example.com:TXT:v=DMARC1*`), SPF, and DKIM records
- **DNS Validation**: Ensure A/AAAA records match expected IPs
- **MX Monitoring**: Verify mail servers are correctly configured
- **CAA Records**: Monitor certificate authority authorization

**Alert Conditions:**
- **CRITICAL**: Record not found, value mismatch, or resolution failure
- **OK**: Record exists and matches expected value
- **State Keys**: `dnsrecord_<domain>_<type>`

**Requirements:** `dig` command (install `bind-utils` or `dnsutils`)

### Enhanced Audit Logging

Structured JSON audit logs for compliance, security analysis, and troubleshooting:

```bash
# Enable audit logging
ENABLE_AUDIT_LOGGING=true

# Audit log file path
AUDIT_LOG_FILE="/var/log/telemon_audit.log"

# Events to log: all, or comma-separated list
# Options: all, alert, state_change, check_run, escalation
AUDIT_EVENTS="all"
```

**JSON Log Format:**
```json
{
  "timestamp": "2026-04-16T12:00:00+0000",
  "hostname": "web-prod-01",
  "server_label": "web-prod-01",
  "event_type": "state_change",
  "details": "Key: cpu, State: CRITICAL, Previous: OK"
}
```

**Logged Events:**
- **state_change**: When a check transitions between OK/WARNING/CRITICAL
- **alert**: When an alert is dispatched (or queued for retry)
- **escalation**: When an unresolved alert triggers escalation
- **check_run**: When each monitoring cycle completes

**Use Cases:**
- Compliance audits (PCI-DSS, SOC 2)
- Security incident investigation
- Alert history analysis
- Troubleshooting notification delivery issues

**Log Rotation:** Audit logs are not automatically rotated. Use `logrotate` or similar for production deployments.

### Paths

```bash
# State file for alert deduplication
STATE_FILE="/tmp/telemon_sys_alert_state"

# Log file
LOG_FILE="/opt/telemon/telemon.log"
LOG_LEVEL="INFO"       # Levels: DEBUG, INFO, WARN, ERROR

# Log rotation
LOG_MAX_SIZE_MB=10     # Max log file size before rotation
LOG_MAX_BACKUPS=5      # Number of rotated backups to keep

# Backup retention (for telemon-admin.sh backup command)
# Set to 0 or leave empty to keep all backups
BACKUP_KEEP_COUNT=5
```

> **Tip:** For production, move `STATE_FILE` out of `/tmp` (cleared on reboot) to a persistent path like `/var/lib/telemon/state`.

### Common Configurations

Copy-paste these `.env` snippets as starting points:

<details>
<summary><strong>Docker Host</strong> (Proxmox, NAS, home server)</summary>

```bash
ENABLE_DOCKER_CONTAINERS=true
CRITICAL_SYSTEM_PROCESSES="sshd dockerd"
CRITICAL_CONTAINERS="redis nginx myapp"
```

</details>

<details>
<summary><strong>Web Server</strong> (Nginx/Apache + SSL)</summary>

```bash
ENABLE_SITE_MONITOR=true
SITE_CHECK_SSL=true
SITE_SSL_WARN_DAYS=14
CRITICAL_SYSTEM_PROCESSES="sshd nginx"
CRITICAL_SITES="https://example.com|max_response_ms=5000 https://api.example.com|expected_status=200"
```

</details>

<details>
<summary><strong>Node.js App Server</strong> (PM2-managed)</summary>

```bash
ENABLE_PM2_PROCESSES=true
ENABLE_SITE_MONITOR=true
CRITICAL_SYSTEM_PROCESSES="sshd"
CRITICAL_PM2_PROCESSES="api worker scheduler"
CRITICAL_SITES="https://api.example.com|max_response_ms=3000"
```

</details>

<details>
<summary><strong>Bare Metal / VPS</strong> (no Docker, no PM2)</summary>

```bash
ENABLE_DOCKER_CONTAINERS=false
ENABLE_PM2_PROCESSES=false
CRITICAL_SYSTEM_PROCESSES="sshd cron"
```

</details>

<details>
<summary><strong>Full-Stack Server</strong> (everything enabled)</summary>

```bash
ENABLE_DOCKER_CONTAINERS=true
ENABLE_SITE_MONITOR=true
ENABLE_TCP_PORT_CHECK=true
ENABLE_TEMP_CHECK=true
ENABLE_DNS_CHECK=true
ENABLE_NETWORK_CHECK=true
ENABLE_INTEGRITY_CHECK=true
ENABLE_CRON_CHECK=true
ENABLE_PROMETHEUS_EXPORT=true
ENABLE_JSON_STATUS=true
ENABLE_HEARTBEAT=true
ENABLE_FLEET_CHECK=true
ENABLE_PREDICTIVE_ALERTS=true

SERVER_LABEL="prod-01"
CRITICAL_SYSTEM_PROCESSES="sshd cron nginx"
CRITICAL_CONTAINERS="redis postgres myapp"
CRITICAL_SITES="https://example.com|check_ssl=true|max_response_ms=5000"
CRITICAL_PORTS="localhost:5432 localhost:6379"
INTEGRITY_WATCH_FILES="/etc/passwd /etc/ssh/sshd_config"
CRON_WATCH_JOBS="backup:/tmp/backup_heartbeat:1440"
AUTO_RESTART_SERVICES="nginx"
FLEET_HEARTBEAT_DIR="/shared/telemon/heartbeats"
FLEET_EXPECTED_SERVERS="prod-01 prod-02 db-01"

WEBHOOK_URL="https://hooks.slack.com/services/xxx/yyy/zzz"
ESCALATION_WEBHOOK_URL="https://hooks.slack.com/services/aaa/bbb/ccc"
ESCALATION_AFTER_MIN=30
```

</details>

<details>
<summary><strong>Media Server</strong> (Plex/Jellyfin + rclone/mergerfs)</summary>

```bash
ENABLE_DOCKER_CONTAINERS=true
ENABLE_SITE_MONITOR=true
ENABLE_GPU_CHECK=true              # Monitor Intel iGPU for hardware transcoding
CRITICAL_SYSTEM_PROCESSES="sshd cron"
CRITICAL_CONTAINERS="plex zurg"
CRITICAL_SITES="http://localhost:32400/identity http://localhost:9999/dav/version.txt"
SITE_EXPECTED_STATUS=200
DISK_THRESHOLD_WARN=85
DISK_THRESHOLD_CRIT=90

# Intel iGPU thresholds (for Intel Quick Sync transcoding)
GPU_INTEL_UTIL_THRESHOLD_WARN=80
GPU_INTEL_UTIL_THRESHOLD_CRIT=95
```

</details>

<details>
<summary><strong>NVMe Storage Server</strong></summary>

```bash
ENABLE_NVME_CHECK=true
NVME_DEVICE="/dev/nvme0n1"
CRITICAL_SYSTEM_PROCESSES="sshd"
```

</details>

### Website Monitoring

```bash
# Enable site monitoring
ENABLE_SITE_MONITOR=true

# Global defaults (can be overridden per-site)
SITE_EXPECTED_STATUS=200       # Expected HTTP status code
SITE_MAX_RESPONSE_MS=10000     # Response time threshold (ms)
SITE_CHECK_SSL=false           # Enable SSL certificate expiry checks
SITE_SSL_WARN_DAYS=7           # Days before expiry to warn

# Basic — space-separated URLs
CRITICAL_SITES="https://example.com https://api.example.com"

# Advanced — per-site overrides via pipe-separated parameters
CRITICAL_SITES="
  https://example.com|max_response_ms=5000|check_ssl=true
  https://api.example.com|expected_status=200|max_response_ms=3000
  https://status.example.com|expected_status=204
"
```

Per-site parameters:
| Parameter | Default | Description |
|-----------|---------|-------------|
| `expected_status` | 200 | Expected HTTP status code |
| `max_response_ms` | 10000 | Response time threshold (ms) |
| `check_ssl` | false | Enable SSL certificate expiry checking |
| `ssl_warn_days` | 7 | Days before expiry to warn |

Alert conditions:
- **CRITICAL**: Unreachable, wrong HTTP status, or SSL expired
- **WARNING**: Slow response, SSL expires soon, or SSL verification issues
- **RESOLVED**: Site healthy again

### Getting Telegram Credentials

#### Step 1: Create a Bot

1. Open Telegram and message [@BotFather](https://t.me/botfather)
2. Send `/newbot`
3. Follow prompts — pick a name and username (must end in `bot`)
4. Copy the token (e.g., `123456789:ABCdefGHIjklMNOpqrSTUvwxyz`)

#### Step 2: Get Your Chat ID

**Option A (Fastest):**
1. Message [@userinfobot](https://t.me/userinfobot)
2. Copy the number it replies with — that's your `TELEGRAM_CHAT_ID`

**Option B:**
1. Message your bot (send anything)
2. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates`
3. Find `"chat":{"id":123456789` — that number is your chat ID

#### Step 3: Test

```bash
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>" -d "text=Test from Telemon"
```

## How It Works

### Confirmation Count

Alerts only fire after a problem persists for the full confirmation window:

```
Check 1: CPU=85% (CRITICAL) → count=1/3, no alert
Check 2: CPU=88% (CRITICAL) → count=2/3, no alert
Check 3: CPU=87% (CRITICAL) → count=3/3, ALERT SENT
Check 4: CPU=87% (CRITICAL) → count=3/3, silent (already alerted)
Check 5: CPU=40% (OK)       → RESOLVED
```

Set `CONFIRMATION_COUNT=1` for immediate alerts.

### Alert Rate Limiting

Per-key cooldown prevents alert floods from flapping checks:

```
12:00 — CPU goes CRITICAL → alert sent
12:05 — CPU resolves to OK → resolution sent
12:10 — CPU goes CRITICAL again → cooldown active, no alert
12:15 — CPU still CRITICAL → cooldown expired, alert sent
```

Controlled by `ALERT_COOLDOWN_SEC` (default: 900s / 15 min). Set to 0 to disable.

### Alert Dispatch Chain

```
Normal cycle:     dispatch_with_retry() → Telegram (queue on fail) + Webhook + Email
Digest mode:      dispatch_alert()      → Telegram + Webhook + Email (no retry)
Escalation:       check_escalation()    → Escalation webhook only
```

- If Telegram fails, the message is queued to `${STATE_FILE}.queue` and retried next cycle
- Webhook and email are still attempted even if Telegram fails

### Auto-Remediation

When `AUTO_RESTART_SERVICES` is configured, Telemon automatically runs `systemctl restart <service>` for any listed service detected as CRITICAL. Remediation runs after checks but before alert dispatch, so the alert message notes whether the restart succeeded or failed.

### Alert Escalation

If `ESCALATION_WEBHOOK_URL` is set, alerts that remain unresolved for `ESCALATION_AFTER_MIN` minutes trigger a separate webhook. Escalation fires once per key and auto-clears when the check resolves.

### Webhook Payload Format

Both the alert webhook and escalation webhook send a JSON POST with `Content-Type: application/json`:

**Alert webhook** (`WEBHOOK_URL`):
```json
{
  "hostname": "my-server",
  "server_label": "web-prod-01",
  "timestamp": "2025-01-15T12:00:00Z",
  "message": "Plain-text alert content (HTML stripped)"
}
```

**Escalation webhook** (`ESCALATION_WEBHOOK_URL`):
```json
{
  "hostname": "my-server",
  "server_label": "web-prod-01",
  "type": "escalation",
  "timestamp": "2025-01-15T12:00:00Z",
  "message": "Plain-text escalation content (HTML stripped)"
}
```

Both payloads automatically strip HTML tags and decode entities from the Telegram-formatted message into plain text.

### Prometheus Metrics

When `ENABLE_PROMETHEUS_EXPORT=true`, Telemon writes a textfile to `PROMETHEUS_TEXTFILE_DIR` for [node_exporter's textfile collector](https://prometheus.io/docs/guides/node-exporter/#textfile-collector). No HTTP server or persistent process required.

**Exported metrics:**

| Metric | Type | Description |
|--------|------|-------------|
| `telemon_check_state{check="..."}` | gauge | Per-check state: 0=OK, 1=WARNING, 2=CRITICAL |
| `telemon_checks_total` | gauge | Total number of checks in this run |
| `telemon_last_run_timestamp` | gauge | Unix timestamp of last run |

**Example output** (`telemon.prom`):
```
# HELP telemon_check_state Telemon check state (0=OK, 1=WARNING, 2=CRITICAL)
# TYPE telemon_check_state gauge
telemon_check_state{check="cpu"} 0
telemon_check_state{check="mem"} 1
telemon_check_state{check="disk_root"} 0
# HELP telemon_checks_total Total number of checks in this run
# TYPE telemon_checks_total gauge
telemon_checks_total 12
# HELP telemon_last_run_timestamp Unix timestamp of last run
# TYPE telemon_last_run_timestamp gauge
telemon_last_run_timestamp 1705312800
```

**Grafana integration:** Import the textfile metrics with standard Prometheus/Grafana dashboards. Example query: `telemon_check_state{check=~"disk_.*"} > 0` to alert on disk issues.

### JSON Status Format

When `ENABLE_JSON_STATUS=true`, Telemon writes a JSON file after each run (requires `python3`):

```json
{
  "hostname": "my-server",
  "timestamp": "2025-01-15T12:00:00Z",
  "checks": {
    "cpu": "OK",
    "mem": "WARNING",
    "disk_root": "OK",
    "container_redis": "CRITICAL"
  },
  "summary": {
    "critical": 1,
    "warning": 1,
    "ok": 2
  }
}
```

Serve with nginx/caddy for a lightweight status API endpoint:

```nginx
location /status {
    alias /tmp/telemon_status.json;
    default_type application/json;
}
```

### Static HTML Status Page

Generate a self-contained HTML status page with `--generate-status-page`:

```bash
# Generate status page to default location (STATUS_PAGE_FILE)
bash telemon.sh --generate-status-page

# Generate to specific path
bash telemon.sh --generate-status-page /var/www/html/status.html
```

**Features:**
- **Visual dashboard** — Color-coded status indicators (🔴 Critical / 🟡 Warning / 🟢 OK)
- **Summary cards** — Quick overview of check counts by status
- **Filterable table** — Click filters to show only Critical, Warning, OK, or all checks
- **Responsive design** — Works on desktop and mobile
- **Auto-refresh** — Optional meta-refresh (configure with `STATUS_PAGE_AUTO_REFRESH` and `STATUS_PAGE_REFRESH_SEC`)
- **Self-contained** — No external dependencies, single HTML file

**Configuration:**

```bash
# Output file path
STATUS_PAGE_FILE="/opt/telemon/status.html"

# Enable auto-refresh (browser will reload page every 60 seconds)
STATUS_PAGE_AUTO_REFRESH=true
STATUS_PAGE_REFRESH_SEC=60
```

**nginx example:**

```nginx
server {
    listen 80;
    root /var/www/html;
    
    location /status {
        alias /opt/telemon/status.html;
    }
}
```

**Cron schedule** (generate status page every 5 minutes):

```bash
*/5 * * * * /opt/telemon/telemon.sh --generate-status-page >> /var/log/telemon_cron.log 2>&1
```

**GitHub Pages workflow** (auto-publish status):

```yaml
# .github/workflows/status.yml
name: Update Status Page
on:
  schedule:
    - cron: '*/5 * * * *'
jobs:
  update:
    runs-on: self-hosted
    steps:
      - run: telemon.sh --generate-status-page /docs/status.html
      - uses: actions/upload-artifact@v3
        with:
          name: status
          path: docs/status.html
```

### First-Run Bootstrap

On first run (no state file), Telemon sends a single bootstrap message summarizing all check results with immediate alerts (confirmation temporarily set to 1). Subsequent runs use the configured confirmation count.

### Maintenance Windows

Two mechanisms to silence alerts during planned work:

1. **Flag file**: `touch /tmp/telemon_maint` → Telemon exits immediately. Remove when done.
2. **Scheduled windows**: `MAINT_SCHEDULE="Sun 02:00-04:00"` → Telemon auto-skips during the window.

Both can be used together. The flag file takes priority (checked before schedule).

### Fleet Monitoring

Telemon can detect when sibling servers go silent — a dead man's switch for your fleet:

```
Server A: writes heartbeat → /shared/heartbeats/web-prod-01  (every 5 min)
Server B: writes heartbeat → /shared/heartbeats/db-prod-01   (every 5 min)
Server C: monitors fleet   → reads /shared/heartbeats/*       (every 5 min)

If Server A stops writing:
  +15 min: Server C alerts WARNING  — "web-prod-01 stale for 15m"
  +30 min: Server C alerts CRITICAL — "web-prod-01 SILENT for 30m"
  Resumed: Server C alerts RESOLVED — "web-prod-01 last seen 2m ago"
```

Any instance can be both a sender and a monitor. The fleet check automatically skips its own heartbeat file. Use `FLEET_EXPECTED_SERVERS` to get CRITICAL alerts for servers that have never checked in.

### State File

Default location: `/tmp/telemon_sys_alert_state`

Format: `key=STATE:count`
```
cpu=CRITICAL:3
mem=OK:0
disk_root=WARNING:2
container_redis=OK:0
port_localhost_22=OK:0
```

Related files:
| File | Purpose |
|------|---------|
| `${STATE_FILE}` | Current check states and confirmation counts |
| `${STATE_FILE}.detail` | State detail text (HTML) for digest reporting |
| `${STATE_FILE}.queue` | Queued alerts from failed Telegram sends |
| `${STATE_FILE}.cooldown` | Per-key alert rate limiting timestamps |
| `${STATE_FILE}.escalation` | Escalation tracking (first-seen timestamps) |
| `${STATE_FILE}.integrity` | File integrity SHA256 checksums |
| `${STATE_FILE}.net` | Network bandwidth previous counters (rx/tx/timestamp) |
| `${STATE_FILE}.trend` | Predictive trend data (epoch:value pairs per metric) |
| `${STATE_FILE}.lock` | Lock file for mutual exclusion |
| `${HEARTBEAT_DIR}/<label>` | Heartbeat files per server (fleet monitoring) |

### Alert Behavior

| Scenario | Action |
|----------|--------|
| First run | Bootstrap message with current status |
| State unchanged, below confirmation count | Silent (still counting) |
| State unchanged, at/above confirmation count | Silent (already alerted) |
| OK → WARNING/CRITICAL | Alert after confirmation count reached |
| WARNING ↔ CRITICAL | Alert after confirmation count reached |
| Confirmed non-OK → OK | Resolution alert (immediate) |
| Unconfirmed non-OK → OK | Silent (transient spike, never alerted) |

## CLI Reference

```bash
# Run a full monitoring check cycle
bash telemon.sh

# Validate configuration (checks credentials, permissions, dependencies, thresholds)
bash telemon.sh --validate

# Validate + send test Telegram message
bash telemon.sh --test

# Send health digest summary (even if everything is OK)
bash telemon.sh --digest

# Generate static HTML status page
bash telemon.sh --generate-status-page
bash telemon.sh --generate-status-page /var/www/html/status.html

# Show help
bash telemon.sh --help
```

### Admin Utility

```bash
bash telemon-admin.sh status          # Show installation status and health
bash telemon-admin.sh validate        # Validate configuration
bash telemon-admin.sh backup          # Create backup of config, state, and logs
bash telemon-admin.sh backup /path    # Backup to specific directory
bash telemon-admin.sh restore <path>  # Restore from backup
bash telemon-admin.sh reset-state     # Reset alert state (forces fresh alerts)
bash telemon-admin.sh digest          # Send health digest summary
bash telemon-admin.sh fleet-status    # Show fleet overview (heartbeat ages, statuses)
bash telemon-admin.sh logs            # View last 50 log lines
bash telemon-admin.sh logs 100        # View last 100 log lines
bash telemon-admin.sh discover        # Auto-discover services and suggest config
```

### Auto-Discovery

Quickly generate a `.env` configuration based on what's running on your server:

```bash
bash telemon-admin.sh discover

```bash
bash update.sh           # Update to latest version (with backup)
bash update.sh --check   # Check for updates without applying
bash uninstall.sh        # Remove cron/systemd, keep config and logs
bash uninstall.sh --full # Remove everything
```

### Maintenance Mode

```bash
# Enter maintenance (silences all alerts)
touch /tmp/telemon_maint

# Exit maintenance
rm /tmp/telemon_maint
```

### Health Digest via Cron

Schedule a daily or weekly summary by adding to crontab:

```bash
# Daily digest at 8 AM
0 8 * * * /path/to/telemon/telemon.sh --digest >> /path/to/telemon/telemon_cron.log 2>&1

# Weekly digest on Monday at 8 AM
0 8 * * 1 /path/to/telemon/telemon.sh --digest >> /path/to/telemon/telemon_cron.log 2>&1
```

## Alternative Deployment

### Systemd Timer

```bash
# Enable systemd timer (created by install.sh)
sudo systemctl enable telemon.timer
sudo systemctl start telemon.timer

# Check status
systemctl status telemon.timer
journalctl -u telemon -f
```

See [systemd/README.md](systemd/README.md) for detailed setup and switching between cron and systemd.

### Docker

```bash
# Build and run with docker-compose
docker-compose up -d

# Or build and run manually
docker build -t telemon .
docker run -v $(pwd)/.env:/opt/telemon/.env:ro telemon
```

The Docker setup mounts host `/proc` for system metrics and optionally the Docker socket for container monitoring. See [docker-compose.yml](docker-compose.yml) for full configuration.

## Requirements

### Software

| Required | Notes |
|----------|-------|
| Bash 4.0+ | Standard on all modern Linux |
| curl | Telegram API, site monitoring |

| Optional | Required for |
|----------|-------------|
| python3 | PM2 monitoring, webhooks, escalation, JSON status export |
| docker | Container monitoring |
| pm2 | PM2 process monitoring |
| smartctl | NVMe/SMART health checks |
| openssl | SSL certificate expiry checks |
| sensors (lm-sensors) | CPU temperature monitoring |
| nvidia-smi / intel_gpu_top | GPU monitoring (NVIDIA or Intel) |
| upower / apcaccess | UPS/battery monitoring |
| dig / nslookup / host | DNS resolution checks |
| dig (bind-utils) | DNS record validation |
| mysql / mariadb | MySQL/MariaDB health checks |
| psql | PostgreSQL health checks |
| redis-cli | Redis health checks |
| sqlite3 | SQLite3 database checks |
| sha256sum | File integrity monitoring |
| sendmail / msmtp | Email alerts |
| flock (util-linux) | Atomic file locking (falls back to PID file) |
| logrotate | System-level log rotation integration |

### Operating System

| Distribution | Status | Notes |
|--------------|--------|-------|
| Ubuntu 20.04+ | Fully supported | Primary development target |
| Debian 11+ | Fully supported | |
| CentOS/RHEL 8+ | Supported | May need EPEL for some tools |
| Alpine Linux | Partial | BusyBox tools may differ |
| macOS | Not supported | Requires Linux `/proc` filesystem |
| Windows WSL | Partial | Some `/proc` metrics may differ |

### Why Linux Only?

Telemon reads from Linux-specific interfaces: `/proc/loadavg`, `/proc/meminfo`, `/proc/swaps`, `/proc/stat`, `/proc/net/dev`.

## File Structure

```
telemon/
├── telemon.sh              # Main monitoring script (~5674 lines)
├── telemon-admin.sh        # Admin CLI (backup, restore, status, validate, logs)
├── checks.d/               # Plugin directory (optional custom checks)
│   └── example-plugin.sh   # Example plugin showing output format
├── lib/
│   └── common.sh           # Shared helpers for auxiliary scripts
├── install.sh              # Setup (cron, permissions, dependencies)
├── uninstall.sh            # Clean removal (--full for everything)
├── update.sh               # Update with backup and rollback
├── .env.example            # Configuration template (all options documented)
├── .env                    # Your config (gitignored, chmod 600)
├── telemon-logrotate.conf  # Logrotate configuration
├── systemd/
│   ├── telemon@.service    # Systemd service unit
│   ├── telemon.timer       # Systemd timer unit
│   └── README.md           # Systemd setup guide
├── Dockerfile              # Alpine-based container image
├── docker-compose.yml      # Docker Compose with scheduler option
├── docs/
│   ├── QUICKREF.md         # Quick reference card
│   ├── TROUBLESHOOTING.md  # Troubleshooting guide
│   └── man/
│       └── telemon.1       # Man page
├── AGENTS.md               # Coding agent guidelines
├── CHANGELOG.md            # Version history
├── CONTRIBUTING.md         # Contribution guidelines
├── LICENSE                 # MIT License
└── README.md               # This file
```

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed troubleshooting.

**Quick fixes:**

| Problem | Solution |
|---------|----------|
| No alerts received | `bash telemon.sh --validate` |
| Telegram not working | `bash telemon.sh --test` |
| False alarms | Increase `CONFIRMATION_COUNT` |
| Too many alerts (flapping) | Increase `ALERT_COOLDOWN_SEC` |
| Docker checks failing | `sudo usermod -aG docker $USER` |
| State stuck | `bash telemon-admin.sh reset-state` |
| Webhook not sending | Check `python3` is installed |
| PM2 checks failing | Check `pm2` and `python3` are installed |
| NVMe checks failing | Check `smartctl` is installed, may need sudo |
| GPU checks failing (Intel) | `intel_gpu_top` requires `CAP_PERFMON` capability or root. Try: `sudo setcap cap_perfmon=ep $(which intel_gpu_top)` |
| Fleet check not working | Verify `FLEET_HEARTBEAT_DIR` exists and is readable |
| No heartbeat files | Check `ENABLE_HEARTBEAT=true` and `HEARTBEAT_MODE=file` on sender |
| Database checks failing | Check client tools installed (mysql/psql/redis-cli) |
| Plugin not running | Ensure plugin is executable (`chmod +x checks.d/my-plugin.sh`) |
| Plugin output rejected | Verify format: `OK|my_key|Detail message` |
| Need quick config | `bash telemon-admin.sh discover` to scan and suggest settings |
| Need to update | `bash update.sh` |

**Common diagnostics:**

```bash
# Validate everything
bash telemon.sh --validate

# Run manually and watch output
bash telemon.sh

# View recent logs
bash telemon-admin.sh logs 100

# Check cron job is installed
crontab -l | grep telemon

# Check state file
cat /tmp/telemon_sys_alert_state

# Syntax check (no execution)
bash -n telemon.sh
```

## Set & Forget

Telemon is designed to run indefinitely without maintenance:

| Concern | How It's Handled |
|---------|-----------------|
| Disk space | Self-rotating logs (configurable size/count) |
| Reboots | Cron job persists, state file survives |
| False alarms | Confirmation count filters transient spikes |
| Alert floods | Per-key rate limiting prevents spam |
| Silent failures | First-run bootstrap confirms Telegram works |
| Hung commands | Timeout wrapper prevents blocking |
| Overlapping runs | Lock file prevents concurrent execution |
| Unresolved alerts | Escalation webhook after N minutes |
| Planned maintenance | Flag file or scheduled windows silence alerts |
| Server goes dark | Fleet heartbeat detects silent servers |

**Expected maintenance:** None. Just watch for Telegram alerts.

## Documentation

- [README.md](README.md) — Setup and usage (this file)
- [docs/QUICKREF.md](docs/QUICKREF.md) — Quick reference card
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — Troubleshooting guide
- [docs/man/telemon.1](docs/man/telemon.1) — Man page
- [systemd/README.md](systemd/README.md) — Systemd setup guide
- [CONTRIBUTING.md](CONTRIBUTING.md) — Contribution guidelines
- [CHANGELOG.md](CHANGELOG.md) — Version history
- [SECURITY.md](SECURITY.md) — Security policy and vulnerability reporting

## License

MIT License — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

```bash
# Quick start
git clone https://github.com/SwordfishTrumpet/telemon.git
cd telemon
# Make changes
bash -n telemon.sh                # Syntax check
bash telemon.sh --validate        # Config check
# Submit a pull request
```

---

Made with code for headless servers everywhere.
