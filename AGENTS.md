# AGENTS.md

## Telemon - Telegram Health Monitor Agent System

### Overview

Telemon is an automated health monitoring system that sends alerts via Telegram. It acts as a "silent agent" watching system vitals and notifying you only when things change state (OK → WARNING, WARNING → CRITICAL, or back to OK).

---

## Agent Architecture

### Core Agent: `telemon.sh`

The main monitoring agent runs every 5 minutes via cron. It performs stateful checks with deduplication — alerts only fire on state changes, not on every check.

**Capabilities:**
- CPU load monitoring (% of available cores)
- Memory availability tracking
- Disk space monitoring (all partitions)
- Internet connectivity (ping to 8.8.8.8)
- System process health (sshd, docker)
- Docker container status (postgres, zilean)
- PM2 process monitoring (hound)

**State Management:**
- State file: `/tmp/telemon_sys_alert_state`
- Format: `key=STATE:count` (e.g., `cpu=CRITICAL:3`)
- Tracks last known state and consecutive occurrence count
- Only alerts when state is confirmed (prevents false alarms)

---

## Configuration Agent: `.env`

The configuration agent defines thresholds and targets:

```bash
# Telegram credentials
TELEGRAM_BOT_TOKEN="<your-bot-token>"
TELEGRAM_CHAT_ID="<your-chat-id>"

# Thresholds
CPU_THRESHOLD_WARN=70        # % of cores
CPU_THRESHOLD_CRIT=80
MEM_THRESHOLD_WARN=15          # % free memory
MEM_THRESHOLD_CRIT=10
DISK_THRESHOLD_WARN=85         # % used
DISK_THRESHOLD_CRIT=90
PING_FAIL_THRESHOLD=3          # consecutive failures

# Confirmation Count
CONFIRMATION_COUNT=3           # consecutive matches before alerting

# Monitored entities
CRITICAL_SYSTEM_PROCESSES="sshd docker"
CRITICAL_CONTAINERS="postgres zilean"
CRITICAL_PM2_PROCESSES="hound"
```

---

## Confirmation Count Feature

Telemon uses a **confirmation count** mechanism to prevent false alarms from transient spikes. Before an alert is sent, a state must persist for `CONFIRMATION_COUNT` consecutive checks.

**How it works:**
- With `CONFIRMATION_COUNT=3` (default), a CPU spike must last 15 minutes (3 checks × 5 min) before alerting
- Set `CONFIRMATION_COUNT=1` for immediate alerts (no confirmation required)
- State file tracks consecutive occurrences: `cpu=CRITICAL:2` means CRITICAL seen 2x in a row

**Example with confirmation count=5:**
```
Check 1: CPU=85% (CRITICAL) → count=1/5, no alert
Check 2: CPU=88% (CRITICAL) → count=2/5, no alert 
Check 3: CPU=87% (CRITICAL) → count=3/5, no alert
Check 4: CPU=87% (CRITICAL) → count=4/5, no alert
Check 5: CPU=87% (CRITICAL) → count=5/5, 🚨 ALERT!
```

The alert only fires after the state has been consistent for exactly `CONFIRMATION_COUNT` consecutive checks. This filters out brief spikes while ensuring real problems are reported.

**First run behavior:** On first execution, confirmation is bypassed (count=1) so you get immediate system status. Subsequent runs use the configured `CONFIRMATION_COUNT`.

---

## Deployment Agent: `install.sh`

Automated setup agent that:
1. Checks dependencies (curl, docker, python3, etc.)
2. Verifies .env configuration
3. Sets executable permissions
4. Installs cron job (idempotent)
5. Runs initial test

**Usage:**
```bash
bash $HOME/telemon/install.sh
```

---

## Alert Format

Telegram messages use HTML formatting with emoji indicators:

- 🚨 CRITICAL — Red alert, immediate attention needed
- ⚠️ WARNING — Yellow alert, monitor closely
- ✅ RESOLVED — Green, issue cleared

**Example Alert:**
```
💻 [hostname] System Vital Alert
2025-01-15 14:30:00 UTC

Summary: 🔴 1 critical | 🟠 0 warning | 🟢 6 healthy
-----------------------------

🚨 CRITICAL: CPU load 8.5 = 85% of 8 cores (threshold: 80%)
```

---

## Agent Logs

| Log File | Purpose |
|----------|---------|
| `telemon.log` | Detailed check results and state changes |
| `telemon_cron.log` | Cron execution output |

**View logs:**
```bash
tail -f $HOME/telemon/telemon.log
tail -f $HOME/telemon/telemon_cron.log
```

---

## Manual Operations

**Run check manually:**
```bash
bash $HOME/telemon/telemon.sh
```

**Reset state (forces fresh alerts):**
```bash
rm /tmp/telemon_sys_alert_state
```

**Remove cron job:**
```bash
crontab -e  # delete the telemon line
```

---

## Integration Notes

### Operating System

- **Target OS**: Linux (Ubuntu, Debian, CentOS/RHEL, Alpine)
- **Not supported**: macOS, Windows (uses Linux-specific /proc filesystem)
- **Tested on**: Ubuntu 20.04+, Debian 11+, CentOS 8+

### Requirements

- Designed for headless servers/VPS
- Requires Telegram bot (create via @BotFather)
- Get chat ID via @userinfobot or by messaging bot and checking:
  `https://api.telegram.org/bot<TOKEN>/getUpdates`
- Docker checks require user in docker group or sudo
- PM2 checks require PM2 to be installed globally
- **Zero maintenance**: Self-rotating logs, persistent state, cron-scheduled

### Linux Dependencies

Telemon reads from these Linux-specific interfaces:
- `/proc/loadavg` — CPU load
- `/proc/meminfo` — Memory stats
- `/proc/swaps` — Swap usage
- `/proc/stat` — I/O wait
- `/proc/[pid]/stat` — Process states

---

## Set & Forget Philosophy

Telemon is built for hands-off operation:

1. **Install once** — Run `install.sh`, done
2. **Self-managing** — Log rotation, state persistence, error handling built-in
3. **Silent when healthy** — No "ping" messages, only real alerts
4. **Survives reboots** — Cron persists, state file remembers
5. **No babysitting** — Handles its own disk usage, validates config

**You should only hear from Telemon when something needs your attention.**

---

## Agent Behavior Summary

| Trigger | Action |
|---------|--------|
| First run | Sends bootstrap summary of all checks |
| State unchanged | Silent (no Telegram message) |
| OK → WARNING | Sends warning alert |
| OK → CRITICAL | Sends critical alert |
| WARNING → CRITICAL | Escalates to critical alert |
| CRITICAL → OK | Sends resolution alert |
| WARNING → OK | Sends resolution alert |

This design ensures you're only notified when something actually changes, not bombarded with repetitive "still broken" messages.
