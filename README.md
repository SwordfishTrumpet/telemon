# Telemon

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub release](https://img.shields.io/github/v/release/SwordfishTrumpet/telemon)](https://github.com/SwordfishTrumpet/telemon/releases)

> **Lightweight, self-managing system health monitor with intelligent alerts. Zero maintenance. Zero spam.**

Telemon is a single-file Bash script that monitors your Linux server — CPU, memory, disk, containers, services, ports, SSL certs, hardware health, databases, and more — and **only alerts when something actually changes**. No spam, just signal. It runs via cron every 5 minutes and requires zero ongoing maintenance.

## 🚀 One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash
```

**That's it.** The installer prompts for Telegram credentials and configures everything automatically.

For **silent/CI/CD installs** (no prompts):

```bash
TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="yyy" \
  curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --silent
```

[📖 Full installation options](#quick-install-one-liner) | [🔧 Manual install](#quick-start-manual-install)

---

## Why Telemon?

### Key Strengths

| Strength | Description |
|----------|-------------|
| **Zero Dependencies** | Core monitoring works with just `bash` + `curl`. All optional features auto-detect and gracefully skip if tools are missing. |
| **Stateful Alert Tracking** | Only alerts on *state changes* (OK→WARNING→CRITICAL). Confirmation count + per-key cooldowns prevent false alarms and spam. |
| **Self-Managing** | Self-rotating logs, automatic stale lock cleanup, retry queues for failed alerts. Runs indefinitely without maintenance. |
| **Security-First** | Secrets never passed on command lines, input validation, SSRF protection, atomic file writes with symlink protection, HTML escaping. |
| **Battle-Tested** | Portable across GNU Linux and BSD, handles edge cases (hung commands, overlapping runs, flapping checks). |
| **Auto-Discovery** | Scans your system and suggests configuration for detected hardware, services, databases, and applications. |
| **Enterprise Features** | Fleet monitoring (multi-server), predictive resource exhaustion, config drift detection, audit logging, auto-remediation, maintenance windows. |

### How Alerting Works

Telemon uses **stateful tracking** — it remembers the previous state of each check and only notifies on *transitions*. This eliminates false alarms and alert spam:

```
Check 1: CPU=85% → count=1/3, silent (collecting evidence)
Check 2: CPU=88% → count=2/3, silent (still collecting)
Check 3: CPU=87% → count=3/3, ALERT SENT (confirmed problem)
Check 4: CPU=87% → silent (already alerted)
Check 5: CPU=40% → RESOLVED alert (immediate)
```

- **Confirmation count**: Problem must persist N consecutive checks (default: 3 = 15 min)
- **Rate limiting**: Per-key cooldown prevents flapping floods (default: 15 min)
- **Resolution alerts**: Immediate notification when problems clear
- **Retry queue**: Failed Telegram alerts retry next cycle

---

## Dependencies

### Core (Always Required)

| Dependency | Purpose | Can Skip? |
|------------|---------|-----------|
| `bash` 4.0+ | Script execution | No |
| `curl` | Telegram API, HTTP checks | No |
| `/proc/*` | CPU, memory, I/O, network metrics | No (Linux-specific) |

### Alert Channels (At least one recommended)

| Channel | Dependency | Required For |
|---------|------------|--------------|
| Telegram | `curl` | Primary alerts |
| Webhook | `python3` | Slack/Discord/ntfy/n8n integration |
| Email | `curl` (SMTP) or `sendmail`/`msmtp` | Email alerts |

### Optional Checks (Auto-Detect, Gracefully Skip)

| Check | Dependency | Detection |
|-------|------------|-----------|
| Docker containers | `docker` | Auto-enabled if command found |
| PM2 processes | `pm2`, `python3` | Auto-enabled if both found |
| NVMe/SMART health | `smartctl` | Auto-detected via `telemon-admin.sh discover` |
| CPU temperature | `sensors` (lm-sensors) | Auto-detected via discover |
| GPU (NVIDIA) | `nvidia-smi` | Auto-detected via discover |
| GPU (Intel) | `intel_gpu_top` | Auto-detected via discover |
| UPS/Battery | `upower` or `apcaccess` | Auto-detected via discover |
| DNS | `dig`/`nslookup`/`host` | First available used |
| MySQL/MariaDB | `mysql`/`mariadb` | Auto-detected via discover |
| PostgreSQL | `psql` | Auto-detected via discover |
| Redis | `redis-cli` | Auto-detected via discover |
| SQLite3 | `sqlite3` | Config-driven |
| ODBC | `isql` (unixODBC) | Config-driven |
| File integrity | `sha256sum`/`shasum`/`openssl` | Any available |

### Administrative (Optional)

| Tool | Purpose | Fallback |
|------|---------|----------|
| `flock` (util-linux) | Atomic lock file | PID file mechanism |
| `python3` | Webhooks, JSON export, escalation | Features disabled |
| `awk` | Predictive alerts | Pure Bash math |
| `logrotate` | Log rotation | Self-rotating logs |

### Design Philosophy

> **"Graceful skip if dependency missing"**

Every optional check follows this pattern:

```bash
if ! command -v mytool &>/dev/null; then
    log "INFO" "myfeature check: mytool not installed — skipping"
    return
fi
```

**Bottom line**: Telemon runs on virtually any Linux system with just `bash` and `curl`. All advanced features are opt-in and auto-detect available tools.

---

## Features

### Core System Monitoring
- **CPU Load** — 1-minute load average as percentage of available cores
- **Memory** — Available memory percentage (inverted thresholds: lower = worse)
- **Disk Space** — Per-partition monitoring, auto-filters tmpfs/overlay/snap
- **Swap Usage** — Swap partition monitoring, gracefully skips if no swap
- **I/O Wait** — CPU time spent waiting for disk I/O (stateful differential sampling)
- **Zombie Processes** — Detects processes stuck in Z state
- **Internet Connectivity** — Ping-based reachability with configurable target

### Process & Service Monitoring
- **System Processes** — Monitors via `pgrep` with `systemctl` fallback
- **Failed Systemd Services** — System-wide scan for failed units
- **Docker Containers** — Status and health checks (gracefully skips if unavailable)
- **PM2 Processes** — Node.js process monitoring via `pm2 jlist`

### Website & Endpoint Monitoring
- **HTTP/HTTPS Health** — Availability, HTTP status codes, response times
- **SSL Certificate Expiry** — Cross-platform via `openssl` with date parsing fallback
- **TCP Port Checks** — Reachability testing via `/dev/tcp`
- **DNS Resolution** — Health checking via `dig`, `nslookup`, or `host`
- **DNS Record Validation** — Verify A, AAAA, MX, TXT, CNAME, NS, SOA, PTR, SRV, CAA records

### Extended Monitoring
- **CPU Temperature** — Thermal monitoring via `lm-sensors`
- **GPU Monitoring** — NVIDIA via `nvidia-smi` or Intel via `intel_gpu_top`
- **UPS / Battery** — Charge level monitoring via `upower` or `apcaccess`
- **Network Bandwidth** — Interface throughput monitoring
- **NVMe / SMART Health** — Critical warning byte, endurance wear, temperature, media errors
- **Log Pattern Matching** — Watch log files for regex patterns
- **File Integrity** — SHA256 checksum monitoring for critical files
- **Config Drift Detection** — Rich change tracking with unified diffs
- **Cron Job Heartbeats** — Detect stale cron jobs via heartbeat file age

### Predictive & Fleet Features
- **Predictive Resource Exhaustion** — Linear regression to alert *before* disk/memory runs out
- **Fleet Monitoring** — Multi-server heartbeat aggregation via shared directory
- **Auto-Remediation** — Automatically restart failed systemd services
- **Maintenance Windows** — Flag file or scheduled recurring windows

### Plugin System
- **Directory-Based Plugins** — Place executable scripts in `checks.d/`
- **Simple Output Format** — Plugins output `STATE|KEY|DETAIL`
- **Security-First** — Timeout protection, symlinks skipped, output validated

### Database Health Checks
- **MySQL/MariaDB** — Connection check and replication lag monitoring
- **PostgreSQL** — Connection check and streaming replication lag
- **Redis** — Connection check, authentication, master/replica status
- **SQLite3** — File integrity, size thresholds, corruption detection
- **ODBC** — Universal support for SQL Server, Oracle, DB2, etc.

### Alert Channels & Intelligence
- **Multi-Channel** — Telegram (primary), webhooks (Slack/Discord/ntfy), email
- **Retry/Queue** — Failed Telegram alerts queue to disk and retry
- **Rate Limiting** — Per-key cooldown prevents alert floods
- **Escalation** — Separate webhook for unresolved alerts after N minutes
- **Top Processes** — Auto-capture CPU/memory hogs in alerts

### Exports & Integrations
- **Prometheus** — Textfile export for `node_exporter`
- **JSON Status** — Machine-readable status API
- **Static HTML Status Page** — Self-contained dashboard
- **Health Digest** — Scheduled full health summaries
- **Audit Logging** — Structured JSON logs for compliance

---

## Quick Install (One-Liner)

### Interactive Install (Recommended for First Time)

```bash
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash
```

Or install to a custom directory:

```bash
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- /opt/telemon
```

### Silent/Automated Install (CI/CD, Ansible, Cloud Init)

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

**Silent Mode Environment Variables:**

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `TELEGRAM_BOT_TOKEN` | Yes | — | Your Telegram bot token |
| `TELEGRAM_CHAT_ID` | Yes | — | Your Telegram chat ID |
| `SERVER_LABEL` | No | `hostname` | Server name in alerts |
| `ENABLE_DOCKER` | No | `auto` | `auto`/`true`/`false` |
| `ENABLE_PM2` | No | `auto` | `auto`/`true`/`false` |
| `ENABLE_SITES` | No | `false` | Enable website monitoring |
| `SITE_URLS` | No | — | Space-separated URLs |
| `TELEMON_SILENT` | No | `false` | Alternative to `--silent` flag |
| `TELEMON_SYSTEMD` | No | `false` | Alternative to `--systemd` flag |

### Systemd Timer Install (Alternative to Cron)

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

1. **Downloads** the latest Telemon files from GitHub
2. **Configures** your Telegram credentials
3. **Sets up** optional monitoring (Docker, PM2, websites — auto-detected)
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

- Linux server with `curl`, `bash`, and standard `/proc` filesystem
- Your Telegram bot token and chat ID ([see below](#getting-telegram-credentials))

---

## Quick Start (Manual Install)

### Prerequisites

- Linux server (Ubuntu, Debian, CentOS/RHEL, Alpine)
- Bash 4.0+, curl
- Telegram bot token and chat ID ([see below](#getting-telegram-credentials))

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

---

## Auto-Discovery

Telemon can automatically detect services, hardware, and infrastructure and suggest configuration:

```bash
bash telemon-admin.sh discover
```

Scans your system and generates `.env` suggestions for:

| Category | Detected Items |
|----------|----------------|
| **Hardware** | NVMe drives, NVIDIA/Intel GPUs, UPS (APC/NUT/upower), lm-sensors, RAID (mdadm, ZFS, LVM) |
| **Infrastructure** | Docker Swarm, Kubernetes, Proxmox VE, KVM/QEMU, NFS/SMB mounts, WireGuard, Tailscale, HAProxy |
| **Databases** | MySQL/MariaDB, PostgreSQL, Redis (only if servers are running, not just clients) |
| **Applications** | RabbitMQ, Mosquitto (MQTT), Fail2ban, CrowdSec |
| **Core Services** | Docker containers, PM2 processes, Nginx, Apache, Systemd services |
| **Smart Thresholds** | CPU and memory thresholds based on your actual hardware specs |

### Discovery Output Example

```
=== Hardware ===
✓ NVMe drives detected (2): /dev/nvme0n1, /dev/nvme1n1
✓ NVIDIA GPU detected: NVIDIA GeForce RTX 3080
✓ lm-sensors configured

=== Infrastructure ===
✓ Docker Swarm (manager node)
✓ ZFS pools detected: tank, rpool

=== Databases ===
✓ MySQL/MariaDB server running
✓ Redis server running

=== Smart Thresholds ===
✓ Thresholds suggested based on system specs: 64GB RAM, 16 cores

===============================================
Suggested Configuration
===============================================

# NVMe health monitoring
ENABLE_NVME_CHECK=true

# NVIDIA GPU monitoring  
ENABLE_GPU_CHECK=true

# CPU temperature monitoring
ENABLE_TEMP_CHECK=true

# Smart Thresholds (based on system specs: 64GB RAM, 16 cores)
MEM_THRESHOLD_WARN=10
MEM_THRESHOLD_CRIT=5
CPU_THRESHOLD_WARN=80
CPU_THRESHOLD_CRIT=90

# MySQL/MariaDB (detected running)
DB_MYSQL_HOST="localhost"
DB_MYSQL_PORT="3306"
...
```

Simply copy the suggested lines into your `.env` file, customize as needed, and validate with `bash telemon.sh --validate`.

---

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
ENABLE_DNS_RECORD_CHECK=false
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
PING_TARGET="8.8.8.8"
PING_FAIL_THRESHOLD=3

# CPU temperature (°C)
TEMP_THRESHOLD_WARN=75
TEMP_THRESHOLD_CRIT=90

# GPU temperature (°C) — NVIDIA only
GPU_TEMP_THRESHOLD_WARN=80
GPU_TEMP_THRESHOLD_CRIT=95

# Intel GPU thresholds
GPU_INTEL_UTIL_THRESHOLD_WARN=80
GPU_INTEL_UTIL_THRESHOLD_CRIT=95
GPU_INTEL_TEMP_THRESHOLD_WARN=80
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
EMAIL_FROM="telemon@myserver.com"

# Escalation — separate webhook for unresolved alerts (optional, requires python3)
ESCALATION_WEBHOOK_URL="https://hooks.slack.com/services/aaa/bbb/ccc"
ESCALATION_AFTER_MIN=30
```

### Alert Tuning

```bash
# Consecutive checks required before alerting (default: 3)
CONFIRMATION_COUNT=3

# Per-key cooldown between alerts (default: 900s = 15 min)
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
CRITICAL_SITES="https://example.com https://api.example.com|max_response_ms=3000"

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

# File integrity monitoring
INTEGRITY_WATCH_FILES="/etc/passwd /etc/ssh/sshd_config"

# Configuration drift detection
ENABLE_DRIFT_DETECTION=true
DRIFT_WATCH_FILES="/etc/nginx/nginx.conf /etc/ssh/sshd_config"
DRIFT_IGNORE_PATTERN="^[+-]?\s*#"
DRIFT_MAX_DIFF_LINES=20
DRIFT_SENSITIVE_FILES="/etc/shadow /etc/gshadow"

# Cron heartbeat tracking (name:touchfile:max_age_minutes)
CRON_WATCH_JOBS="backup:/tmp/backup_heartbeat:1440 report:/tmp/report_heartbeat:60"

# NVMe device
NVME_DEVICE="/dev/nvme0n1"
NVME_TEMP_THRESHOLD_WARN=70
NVME_TEMP_THRESHOLD_CRIT=80

# Auto-restart failed systemd services
AUTO_RESTART_SERVICES="nginx sshd"
```

### Maintenance Windows

```bash
# Flag file — touch to silence, rm when done
MAINT_FLAG_FILE="/tmp/telemon_maint"

# Scheduled recurring windows (semicolon-separated)
MAINT_SCHEDULE="Sun 02:00-04:00;Sat 03:00-05:00"
```

### Exports

```bash
# Prometheus textfile export
ENABLE_PROMETHEUS_EXPORT=true
PROMETHEUS_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# JSON status file
ENABLE_JSON_STATUS=true
JSON_STATUS_FILE="/opt/telemon/status.json"
```

### Predictive Resource Exhaustion

```bash
ENABLE_PREDICTIVE_ALERTS=true
PREDICT_HORIZON_HOURS=24
PREDICT_DATAPOINTS=48
PREDICT_MIN_DATAPOINTS=12
```

Telemon uses linear regression on historical datapoints to predict when a resource will reach 100%. If the trend line projects exhaustion within 24 hours, a WARNING alert fires.

### Fleet Monitoring

```bash
# Server identity — used in alert headers and heartbeat files
SERVER_LABEL="web-prod-01"

# Heartbeat sender (all instances)
ENABLE_HEARTBEAT=true
HEARTBEAT_MODE="file"
HEARTBEAT_DIR="/shared/telemon/heartbeats"

# Fleet monitor (one designated instance)
ENABLE_FLEET_CHECK=true
FLEET_HEARTBEAT_DIR="/shared/telemon/heartbeats"
FLEET_STALE_THRESHOLD_MIN=15
FLEET_CRITICAL_MULTIPLIER=2
FLEET_EXPECTED_SERVERS="web-prod-01 db-prod-01 api-staging"
```

**How it works:**
1. Every instance writes a heartbeat file after each run
2. One instance monitors the directory and alerts on stale/missing servers
3. If a server's heartbeat goes stale → WARNING/CRITICAL alert

### Plugin System

```bash
# Enable plugin system
ENABLE_PLUGINS=true
# CHECKS_DIR="/opt/telemon/custom-checks"
```

Plugins output `STATE|KEY|DETAIL`:
```
OK|my_check|Everything is working
WARNING|my_check|Resource at 85%
CRITICAL|my_check|Service not responding
```

See [Plugin Examples](#plugin-examples) below.

### Database Health Checks

```bash
ENABLE_DATABASE_CHECKS=true

# MySQL/MariaDB
DB_MYSQL_HOST="localhost"
DB_MYSQL_PORT="3306"
DB_MYSQL_USER="telemon"
DB_MYSQL_PASS="secret"
DB_MYSQL_NAME="mysql"

# PostgreSQL
DB_POSTGRES_HOST="localhost"
DB_POSTGRES_PORT="5432"
DB_POSTGRES_USER="telemon"
DB_POSTGRES_PASS="secret"
DB_POSTGRES_NAME="postgres"

# Redis
DB_REDIS_HOST="localhost"
DB_REDIS_PORT="6379"
DB_REDIS_PASS=""

# SQLite3
DB_SQLITE_PATHS="/var/lib/app/data.db"
DB_SQLITE_SIZE_THRESHOLD_WARN=500
DB_SQLITE_SIZE_THRESHOLD_CRIT=1000
```

### ODBC Database Connections

```bash
ENABLE_ODBC_CHECKS=true
ODBC_CONNECTIONS="mssql_prod oracle_dw"

# DSN-based
ODBC_MSSQL_PROD_DSN="MSSQL-Production-DSN"
ODBC_MSSQL_PROD_USER="telemon"
ODBC_MSSQL_PROD_PASS="secure_password"
ODBC_MSSQL_PROD_QUERY="SELECT 1"

# Connection string-based
ODBC_ORACLE_DW_DRIVER="Oracle ODBC Driver"
ODBC_ORACLE_DW_SERVER="oracle-dw.example.com:1521/ORCLDW"
ODBC_ORACLE_DW_USER="monitor"
ODBC_ORACLE_DW_PASS="secure_password"
ODBC_ORACLE_DW_QUERY="SELECT 1 FROM DUAL"
```

### DNS Record Monitoring

```bash
ENABLE_DNS_RECORD_CHECK=true
DNS_CHECK_RECORDS="example.com:A:93.184.216.34,_dmarc.example.com:TXT:v=DMARC1*,example.com:MX:*"
DNS_CHECK_NAMESERVER=""
```

### Enhanced Audit Logging

```bash
ENABLE_AUDIT_LOGGING=true
AUDIT_LOG_FILE="/var/log/telemon_audit.log"
AUDIT_EVENTS="all"
```

### Paths

```bash
STATE_FILE="/tmp/telemon_sys_alert_state"
LOG_FILE="/opt/telemon/telemon.log"
LOG_LEVEL="INFO"
LOG_MAX_SIZE_MB=10
LOG_MAX_BACKUPS=5
BACKUP_KEEP_COUNT=5
```

> **Tip:** For production, move `STATE_FILE` out of `/tmp` to a persistent path like `/var/lib/telemon/state`.

### Common Configurations

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
CRITICAL_SITES="https://example.com|max_response_ms=5000"
```
</details>

<details>
<summary><strong>Node.js App Server</strong> (PM2-managed)</summary>

```bash
ENABLE_PM2_PROCESSES=true
ENABLE_SITE_MONITOR=true
CRITICAL_SYSTEM_PROCESSES="sshd"
CRITICAL_PM2_PROCESSES="api worker scheduler"
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
AUTO_RESTART_SERVICES="nginx"
FLEET_HEARTBEAT_DIR="/shared/telemon/heartbeats"
```
</details>

---

## How It Works

### Confirmation Count

Alerts only fire after a problem persists:

```
Check 1: CPU=85% (CRITICAL) → count=1/3, no alert
Check 2: CPU=88% (CRITICAL) → count=2/3, no alert
Check 3: CPU=87% (CRITICAL) → count=3/3, ALERT SENT
Check 4: CPU=87% (CRITICAL) → count=3/3, silent
Check 5: CPU=40% (OK)       → RESOLVED
```

Set `CONFIRMATION_COUNT=1` for immediate alerts.

### Alert Rate Limiting

Per-key cooldown prevents alert floods:

```
12:00 — CPU goes CRITICAL → alert sent
12:05 — CPU resolves to OK → resolution sent
12:10 — CPU goes CRITICAL again → cooldown active, no alert
12:15 — CPU still CRITICAL → cooldown expired, alert sent
```

Controlled by `ALERT_COOLDOWN_SEC` (default: 900s). Set to 0 to disable.

### Alert Dispatch Chain

```
Normal cycle:     dispatch_with_retry() → Telegram (queue on fail) + Webhook + Email
Digest mode:      dispatch_alert()      → Telegram + Webhook + Email (no retry)
Escalation:       check_escalation()    → Escalation webhook only
```

### State File

Default: `/tmp/telemon_sys_alert_state`

Format: `key=STATE:count`
```
cpu=CRITICAL:3
mem=OK:0
disk_root=WARNING:2
container_redis=OK:0
```

Related files:
| File | Purpose |
|------|---------|
| `${STATE_FILE}` | Current check states |
| `${STATE_FILE}.detail` | State detail text (HTML) |
| `${STATE_FILE}.queue` | Queued alerts from failed Telegram sends |
| `${STATE_FILE}.cooldown` | Per-key alert rate limiting |
| `${STATE_FILE}.escalation` | Escalation tracking |
| `${STATE_FILE}.trend` | Predictive trend data |

---

## CLI Reference

```bash
# Run a full monitoring check cycle
bash telemon.sh

# Validate configuration
bash telemon.sh --validate

# Validate + send test Telegram message
bash telemon.sh --test

# Send health digest summary
bash telemon.sh --digest

# Generate static HTML status page
bash telemon.sh --generate-status-page

# Show help
bash telemon.sh --help
```

### Admin Utility

```bash
bash telemon-admin.sh status          # Show installation status
bash telemon-admin.sh validate        # Validate configuration
bash telemon-admin.sh backup          # Create backup
bash telemon-admin.sh restore <path>  # Restore from backup
bash telemon-admin.sh reset-state     # Reset alert state
bash telemon-admin.sh digest          # Send health digest
bash telemon-admin.sh fleet-status    # Show fleet overview
bash telemon-admin.sh logs            # View last 50 log lines
bash telemon-admin.sh logs 100        # View last 100 lines
bash telemon-admin.sh discover        # Auto-discover services
```

### Update & Uninstall

```bash
bash update.sh           # Update to latest version
bash update.sh --check   # Check for updates
bash uninstall.sh        # Remove cron/systemd, keep config
bash uninstall.sh --full # Remove everything
```

---

## Alternative Deployment

### Systemd Timer

```bash
# Install with systemd timer
curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash -s -- --systemd

# Manual setup (user systemd)
mkdir -p ~/.config/systemd/user/
cp systemd/telemon.timer ~/.config/systemd/user/
cp systemd/telemon@.service ~/.config/systemd/user/telemon.service
systemctl --user daemon-reload
systemctl --user enable telemon.timer
systemctl --user start telemon.timer
```

See [systemd/README.md](systemd/README.md) for detailed reference.

### Docker

```bash
# Build and run with docker-compose
docker-compose up -d

# Or build manually
docker build -t telemon .
docker run -v $(pwd)/.env:/opt/telemon/.env:ro telemon
```

---

## Plugin Examples

### Disk Usage Check

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

### HTTP Service Health

```bash
#!/usr/bin/env bash
# checks.d/api-health.sh

HEALTH=$(curl -s --max-time 5 http://localhost:8080/health 2>/dev/null)

if [[ -z "$HEALTH" ]]; then
    echo "CRITICAL|api_health|API not responding"
elif echo "$HEALTH" | grep -q '"status":"ok"'; then
    echo "OK|api_health|API healthy"
else
    echo "WARNING|api_health|API degraded"
fi
```

**Plugin tips:**
1. Make it executable: `chmod +x checks.d/my-plugin.sh`
2. Handle missing dependencies
3. Keep checks under `CHECK_TIMEOUT` (default 30s)
4. Output exactly: `STATE|KEY|DETAIL`

---

## Testing & Debugging

### Validation

```bash
bash telemon.sh --validate
bash telemon.sh --test  # Send test alerts
```

### Debug Logging

```bash
# Edit .env:
LOG_LEVEL="DEBUG"

# Run manually
bash telemon.sh 2>&1 | tee /tmp/telemon-debug.log
```

### Understanding Log Files

Telemon produces two log files with different purposes:

| Log File | Purpose | Rotation | Level Control |
|----------|---------|----------|---------------|
| `telemon.log` | Main monitoring activity, check results, alerts | Self-rotating (`LOG_MAX_SIZE_MB`) | Respects `LOG_LEVEL` setting |
| `telemon_cron.log` | Cron stderr output, lock contention messages | **Not rotated** — managed by cron | Only WARN/ERROR from lock mechanism |

**Why two log files?**
- `telemon.log` is written via the `log()` function with level filtering and rotation
- `telemon_cron.log` captures stderr from cron, including early-stage messages before the `log()` function is available (e.g., lock contention)

**Managing log growth:**
```bash
# Check log sizes
ls -lh telemon*.log

# Truncate cron log if it grows too large
> telemon_cron.log

# Enable logrotate (system-level)
sudo cp telemon-logrotate.conf /etc/logrotate.d/telemon
```

### Reset State

```bash
bash telemon-admin.sh reset-state
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Telegram not sending | Check bot token, chat ID, internet connectivity |
| SMTP auth fails | Verify password, check if 2FA requires app password |
| Docker not detected | Ensure user is in `docker` group |
| Plugin not loading | Check file is executable, check output format |
| State file errors | Ensure `/tmp` is writable, check disk space |

---

## Getting Telegram Credentials

### Step 1: Create a Bot

1. Open Telegram and message [@BotFather](https://t.me/botfather)
2. Send `/newbot`
3. Follow prompts — pick a name and username (must end in `bot`)
4. Copy the token (e.g., `123456789:ABCdefGHIjklMNOpqrSTUvwxyz`)

### Step 2: Get Your Chat ID

**Option A (Fastest):**
1. Message [@userinfobot](https://t.me/userinfobot)
2. Copy the number it replies with

**Option B:**
1. Message your bot (send anything)
2. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates`
3. Find `"chat":{"id":123456789`

### Step 3: Test

```bash
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>" -d "text=Test from Telemon"
```

---

## Operating System Support

| Distribution | Status | Notes |
|--------------|--------|-------|
| Ubuntu 20.04+ | ✅ Fully supported | Primary development target |
| Debian 11+ | ✅ Fully supported | |
| CentOS/RHEL 8+ | ✅ Supported | May need EPEL |
| Alpine Linux | ⚠️ Partial | BusyBox tools may differ |
| macOS | ❌ Not supported | Requires Linux `/proc` |
| Windows WSL | ⚠️ Partial | Some `/proc` metrics may differ |

**Why Linux only?** Telemon reads from Linux-specific interfaces: `/proc/loadavg`, `/proc/meminfo`, `/proc/stat`, `/proc/net/dev`.

---

## Documentation

- [Quick Reference](docs/QUICKREF.md) — Command cheat sheet
- [Troubleshooting Guide](docs/TROUBLESHOOTING.md) — Common issues and solutions
- [Systemd Setup](systemd/README.md) — Running with systemd instead of cron

---

## License

MIT License — see [LICENSE](LICENSE).

---

Made with code for headless servers everywhere.
