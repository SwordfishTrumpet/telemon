# AGENTS.md — Telemon Coding Agent Guidelines

## Project Overview

Telemon is a single-file Bash monitoring script (`telemon.sh`) that tracks system health and sends alerts via Telegram, webhooks, and email. It runs via cron (typically every 5 minutes) and uses stateful deduplication to avoid alert spam.

## Architecture

```
telemon.sh          — Main script (~3500 lines), all checks + dispatch
lib/common.sh       — Shared helpers for admin utilities
telemon-admin.sh    — Admin CLI (backup, restore, status, reset, fleet-status)
.env                — Configuration (NEVER commit — contains secrets)
.env.example        — Configuration template with all options documented
/tmp/telemon_heartbeats/ — Heartbeat files (fleet monitoring, shared via NFS/mount)
```

## Key Patterns

### Adding a New Check

1. Create a function following this template:
```bash
check_myfeature() {
    # Graceful skip if dependency missing
    if ! command -v mytool &>/dev/null; then
        log "INFO" "myfeature check: mytool not installed — skipping"
        return
    fi

    local value=$(...)
    local state="OK"
    local detail="..."

    if (( value >= MYTHRESHOLD_CRIT )); then
        state="CRITICAL"
        detail="... <b>${value}</b> ..."
    elif (( value >= MYTHRESHOLD_WARN )); then
        state="WARNING"
        detail="... <b>${value}</b> ..."
    fi

    check_state_change "myfeature_key" "$state" "$detail"
}
```

2. Add to `run_all_checks()`:
```bash
[[ "${ENABLE_MYFEATURE_CHECK:-false}" == "true" ]] && check_myfeature
```

3. Add to `.env.example` with documentation and defaults.

4. Add to `run_validate()` for config validation. If the check has configurable thresholds, add `check_threshold_pair()` validation in `validate_thresholds()`.

5. No separate digest step needed — `run_digest()` calls `run_all_checks()` automatically.

### State Keys
- Must be deterministic, unique, and stable across runs
- Format: `category_identifier` (e.g., `disk_root`, `container_redis`, `port_localhost_22`)
- Sanitize special characters — state file uses `key=STATE:count` format
- Key patterns used in checks:
  - `cpu` — CPU load
  - `mem` — Memory usage
  - `disk_<mount>` — Disk space (mount sanitized: `/` → `root`, `/home` → `_home`)
  - `swap` — Swap usage
  - `iowait` — I/O wait
  - `zombies` — Zombie processes
  - `inet` — Internet connectivity
  - `proc_<name>` — System process (name sanitized via `sanitize_state_key`)
  - `systemd_failed` — Failed systemd services
  - `docker_engine` — Docker engine availability
  - `container_<name>` — Docker container (name sanitized)
  - `pm2_engine` — PM2 engine availability
  - `pm2_<name>` — PM2 process (name sanitized)
  - `nvme_health` — NVMe drive health
  - `site_<hash>` — Site monitoring (URL SHA-256 hash, first 12 chars)
  - `port_<hash>` — TCP port check (host:port SHA-256 hash, first 12 chars)
  - `cpu_temp` — CPU temperature
  - `dns` — DNS resolution
  - `gpu_<idx>` — GPU stats (from nvidia-smi, e.g., `gpu_0`, `gpu_1`)
  - `battery` / `ups` — UPS/battery status
  - `net_<iface>` — Network bandwidth (interface sanitized, e.g., `net_eth0`, `net_ens160`)
  - `log_<hash>` — Log pattern matches (file+pattern SHA-256 hash)
  - `integrity_<hash>` — File integrity (filepath SHA-256 hash)
  - `drift_<hash>` — Configuration drift detection (filepath SHA-256 hash)
  - `cron_<name>` — Cron job heartbeat (job name sanitized)
  - `fleet_<label>` — Fleet server heartbeat (server label sanitized)
  - `predict_*` — Predictive exhaustion (prefixed version of parent key, e.g., `predict_disk_root`)

### State File Variants
```
${STATE_FILE}              — Main state (key=STATE:count)
${STATE_FILE}.cooldown     — Alert rate-limit timestamps (key=epoch)
${STATE_FILE}.detail       — State detail text (key=detail_html)
${STATE_FILE}.queue        — Queued alerts on Telegram failure
${STATE_FILE}.escalation   — Escalation tracking (key=epoch, key_escalated=1)
${STATE_FILE}.integrity    — File integrity checksums (filepath=sha256)
${STATE_FILE}.drift       — Drift detection metadata (filepath=checksum|mtime|size|owner|perms)
${STATE_FILE}.drift.baseline/ — Baseline file copies for diff comparison (700 perms)
${STATE_FILE}.net          — Network bandwidth previous counters (rx tx timestamp)
${STATE_FILE}.iowait       — I/O wait previous counters (cpu_total iowait timestamp)
${STATE_FILE}.trend        — Predictive trend data (key=epoch:value,epoch:value,...)
```

### Alert Dispatch Chain
```
dispatch_with_retry() → send_telegram() + send_webhook() + send_email()
dispatch_alert()      → send_telegram() + send_webhook() + send_email()  (no retry)
```
- `dispatch_with_retry()`: used for normal alert cycles — if Telegram fails, queues to `${STATE_FILE}.queue` and retries next cycle. Webhook/email still attempted on Telegram failure.
- `dispatch_alert()`: used for digest mode — fire-and-forget to all channels, no queuing.
- Telegram: primary channel, queued on failure for retry next cycle
- Webhook: JSON POST to WEBHOOK_URL (Slack, Discord, ntfy, etc.) — requires python3
- Email: plain-text via sendmail/msmtp

### Alert Rate Limiting
- Per-key cooldown tracked in `${STATE_FILE}.cooldown`
- `ALERT_COOLDOWN_SEC` (default: 900s / 15min) prevents alert floods from flapping checks
- Cooldown applies per state key, not globally — different checks can alert independently

### First-Run Bootstrap
- On first run (no state file), `CONFIRMATION_COUNT` is temporarily set to 1
- A single bootstrap message is sent summarizing all check results
- Subsequent runs revert to configured confirmation count
- In digest mode (`--digest`), `CONFIRMATION_COUNT` is also temporarily set to 1 to report all current states immediately

### Lock File
- Uses `flock` (util-linux) if available for reliable mutual exclusion
- Falls back to PID file mechanism on systems without flock
- Prevents overlapping runs when checks take longer than cron interval

### Heartbeat File Format
- Tab-separated single line: `label\ttimestamp\tstatus\tcheck_count\twarn_count\tcrit_count\tuptime_sec`
- Written atomically via temp file + mv (NFS-safe, symlink-safe)
- Only aggregate counts are written (no key names) to avoid leaking infrastructure details to shared storage
- Directory uses sticky bit (1755) to prevent file replacement by other users

### Log Rotation
- Self-rotating: configurable via `LOG_MAX_SIZE_MB` (default: 10) and `LOG_MAX_BACKUPS` (default: 5)
- Runs at startup before any checks
- Pattern: `telemon.log` → `telemon.log.1` → ... → `telemon.log.N`

### Escalation
- If `ESCALATION_WEBHOOK_URL` is set, alerts that remain unresolved for `ESCALATION_AFTER_MIN` minutes trigger a separate escalation webhook
- Escalation fires once per key (tracked via `${STATE_FILE}.escalation`)
- Auto-clears when the check resolves to OK

### Top Processes
- When CPU or Memory is in WARNING/CRITICAL, top processes by CPU and memory usage are captured
- Appended to alert messages as `<pre>` block (HTML-escaped to prevent parse errors from process names)
- Count configurable via `TOP_PROCESS_COUNT` (default: 5)

### HTML Formatting
- Alerts use Telegram HTML mode: `<b>`, `<i>`, `<code>`, `<pre>`
- Always escape user-supplied strings with `html_escape()`
- Use `%0A` for newlines in message strings
- Emoji via HTML entities: `&#128308;` (red), `&#128992;` (orange), `&#128994;` (green)

### Security Rules
- **Never** pass secrets in command-line arguments (use process substitution)
- **Never** log raw API responses (may contain tokens)
- All files created with `umask 077` (owner-only)
- State file: symlink check before write, atomic mv
- User input: always HTML-escape before Telegram send
- PM2 process names: pass via environment variable, not shell interpolation

### External Commands
- Always wrap in `run_with_timeout "$CHECK_TIMEOUT" command args`
- Gracefully handle missing tools (`command -v ... || return`)
- Use `2>/dev/null` on commands that may emit noise to stderr
- `CHECK_TIMEOUT` (default: 30s) applies to each `run_with_timeout` call individually, not the total run

### Portable Helpers
The following helper functions provide cross-platform compatibility (GNU Linux and BSD/macOS):

**portable_stat <format> <file>** — Returns file metadata in a GNU-compatible format:
- `portable_stat mtime <file>` — Modification time (seconds since epoch)
- `portable_stat size <file>` — File size in bytes
- `portable_stat owner <file>` — File owner (e.g., `user(uid=1000)`)
- `portable_stat perms <file>` — Permissions as 3-digit octal (e.g., `644`, `755`)

Note: BSD `stat` returns permissions without leading zeros; `portable_stat perms` pads to 3 digits for consistent formatting across GNU Linux and BSD/macOS.

**portable_sha256** — Returns SHA-256 hash using available tool:
```bash
echo "text" | portable_sha256
```
Uses GNU `sha256sum`, BSD `shasum`, or `openssl` as fallback. Replaces the older MD5-based hashing for state key generation.

**is_valid_number** — Validates positive integers (thresholds, counts):
```bash
is_valid_number "$value" || log "ERROR" "Not a number"
```

**is_valid_service_name** — SECURITY: Validates systemd service names:
```bash
is_valid_service_name "$svc" || { log "WARN" "Invalid service name"; continue; }
```
Pattern: `^[a-zA-Z0-9._-]+$` — rejects shell metacharacters, spaces, command substitution.

**is_valid_hostname** — SECURITY: Validates hostnames for TCP checks:
```bash
is_valid_hostname "$host" || { log "WARN" "Invalid hostname"; continue; }
```
Pattern: `^[a-zA-Z0-9._-]+$` — rejects shell metacharacters.

**is_safe_path** — SECURITY: Validates file paths for drift/integrity checks:
```bash
is_safe_path "$filepath" || { log "WARN" "Unsafe path"; continue; }
```
Rejects: `..` (traversal), `*` `?` (glob), `$` `` ` `` (command substitution).

**is_valid_email** — SECURITY: Strict email validation (RFC 5322 simplified):
```bash
is_valid_email "$email" || { log "WARN" "Invalid email"; return 1; }
```
Pattern: `^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`

**is_internal_ip** — SECURITY: SSRF protection for site monitoring:
```bash
is_internal_ip "$host" && { log "WARN" "Internal IP blocked"; continue; }
```
Returns true for: 127.x.x.x, 10.x.x.x, 172.16-31.x.x, 192.168.x.x, 169.254.x.x, ::1, fc00:, fe80:

## Configuration

All configuration lives in `.env`. Key principles:
- Every check has an `ENABLE_*` flag (default `false` for optional checks)
- Thresholds follow `*_THRESHOLD_WARN` / `*_THRESHOLD_CRIT` pattern
- Lists are space-separated strings
- New features must add entries to `.env.example` with documentation

### Threshold Validation
- `check_threshold_pair(name, warn, crit, inverted?)` validates a warn/crit threshold pair:
  - Both values must be positive integers (via `is_valid_number()`)
  - Normal metrics: warn < crit (e.g., CPU 70% warn, 90% crit)
  - Inverted metrics: warn > crit (e.g., free memory 15% warn, 10% crit)
  - Pass `"true"` as 4th arg for inverted metrics
- `validate_thresholds()` calls `check_threshold_pair()` for all core thresholds at startup
- Extended check thresholds only validated when their `ENABLE_*` flag is `true`
- Validation logs errors/warnings but does NOT exit — thresholds have safe defaults

## Enabled Checks (all toggleable)

| Check | Function | Enable Flag | Dependencies |
|-------|----------|------------|-------------|
| CPU Load | `check_cpu` | `ENABLE_CPU_CHECK` | /proc/loadavg |
| Memory | `check_memory` | `ENABLE_MEMORY_CHECK` | /proc/meminfo |
| Disk Space | `check_disk` | `ENABLE_DISK_CHECK` | df |
| Swap | `check_swap` | `ENABLE_SWAP_CHECK` | /proc/swaps |
| I/O Wait | `check_iowait` | `ENABLE_IOWAIT_CHECK` | /proc/stat |
| Zombies | `check_zombies` | `ENABLE_ZOMBIE_CHECK` | ps |
| Internet | `check_internet` | `ENABLE_INTERNET_CHECK` | ping |
| System Processes | `check_system_processes` | `ENABLE_SYSTEM_PROCESSES` | pgrep; systemctl (optional, graceful skip) |
| Systemd Failed | `check_failed_systemd_services` | `ENABLE_FAILED_SYSTEMD_SERVICES` | systemctl (graceful skip if missing) |
| Docker | `check_docker_containers` | `ENABLE_DOCKER_CONTAINERS` | docker (skips silently if no containers configured) |
| PM2 | `check_pm2_processes` | `ENABLE_PM2_PROCESSES` | pm2, python3 |
| Sites | `check_sites` | `ENABLE_SITE_MONITOR` | curl, openssl (for SSL checks) |
| NVMe | `check_nvme_health` | `ENABLE_NVME_CHECK` | smartctl |
| TCP Ports | `check_tcp_ports` | `ENABLE_TCP_PORT_CHECK` | bash /dev/tcp |
| CPU Temp | `check_cpu_temp` | `ENABLE_TEMP_CHECK` | lm-sensors |
| DNS | `check_dns` | `ENABLE_DNS_CHECK` | dig/nslookup/host |
| GPU | `check_gpu` | `ENABLE_GPU_CHECK` | nvidia-smi |
| UPS/Battery | `check_ups` | `ENABLE_UPS_CHECK` | upower/apcaccess |
| Network BW | `check_network_bandwidth` | `ENABLE_NETWORK_CHECK` | /proc/net/dev |
| Log Patterns | `check_log_patterns` | `ENABLE_LOG_CHECK` | tail, grep |
| File Integrity | `check_file_integrity` | `ENABLE_INTEGRITY_CHECK` | sha256sum |
| Config Drift | `check_drift_detection` | `ENABLE_DRIFT_DETECTION` | diff, stat |
| Cron Jobs | `check_cron_jobs` | `ENABLE_CRON_CHECK` | stat |
| Fleet Heartbeats | `check_fleet_heartbeats` | `ENABLE_FLEET_CHECK` | heartbeat files |
| Predictive Exhaustion | `check_prediction` | `ENABLE_PREDICTIVE_ALERTS` | awk (built-in) |

## Alert Features

| Feature | Config |
|---------|--------|
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| Webhook | `WEBHOOK_URL` (requires python3) |
| Email | `EMAIL_TO`, `EMAIL_FROM` |
| Retry/Queue | Automatic — queues on Telegram failure (`${STATE_FILE}.queue`) |
| Rate Limiting | `ALERT_COOLDOWN_SEC` (default: 900s per key) |
| Escalation | `ESCALATION_WEBHOOK_URL`, `ESCALATION_AFTER_MIN` (requires python3) |
| Maintenance Flag | `MAINT_FLAG_FILE` (touch to silence) |
| Maintenance Schedule | `MAINT_SCHEDULE` (recurring windows, e.g. `"Sun 02:00-04:00"`) |
| Auto-Remediation | `AUTO_RESTART_SERVICES` (systemd services only, matches `proc_*` state keys) |
| Top Processes | `TOP_PROCESS_COUNT` (included in CPU/memory alerts) |
| Health Digest | `telemon.sh --digest` (daily/weekly via cron, bypasses confirmation count) |
| Prometheus | `ENABLE_PROMETHEUS_EXPORT`, `PROMETHEUS_TEXTFILE_DIR` |
| JSON Status | `ENABLE_JSON_STATUS`, `JSON_STATUS_FILE` (requires python3) |
| Heartbeat | `ENABLE_HEARTBEAT`, `HEARTBEAT_MODE`, `HEARTBEAT_URL` |
| Fleet Monitoring | `ENABLE_FLEET_CHECK`, `FLEET_HEARTBEAT_DIR`, `FLEET_EXPECTED_SERVERS`, `FLEET_STALE_THRESHOLD_MIN`, `FLEET_CRITICAL_MULTIPLIER` |
| Log Rotation | `LOG_MAX_SIZE_MB` (default: 10), `LOG_MAX_BACKUPS` (default: 5) |
| Predictive Alerts | `ENABLE_PREDICTIVE_ALERTS`, `PREDICT_HORIZON_HOURS`, `PREDICT_DATAPOINTS`, `PREDICT_MIN_DATAPOINTS` |
| Config Drift | `ENABLE_DRIFT_DETECTION`, `DRIFT_WATCH_FILES`, `DRIFT_IGNORE_PATTERN`, `DRIFT_MAX_DIFF_LINES`, `DRIFT_SENSITIVE_FILES` |

## Testing

```bash
bash telemon.sh --validate    # Check configuration
bash telemon.sh --test        # Validate + send test Telegram message
bash telemon.sh --digest      # Send health digest summary
bash telemon.sh --help        # Show usage and available flags
bash -n telemon.sh            # Syntax check (no execution)
```

## File Conventions
- Script: `set -euo pipefail`, `umask 077`
- State files: `/tmp/telemon_sys_alert_state*`
- Logs: self-rotating (configurable via `LOG_MAX_SIZE_MB` / `LOG_MAX_BACKUPS`)
- Config: `.env` with 600 permissions
