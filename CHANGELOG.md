# Changelog

All notable changes to Telemon will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
- **Input Validation** — critical `.env` security hardening:
  - Added `validate_env_security()` function to sanitize critical variables after sourcing
  - Validates `STATE_FILE` for dangerous characters (prevents command injection via malicious path)
  - Validates `TELEGRAM_BOT_TOKEN` format (expected `123456:ABC...` pattern)
  - Validates `TELEGRAM_CHAT_ID` is numeric (prevents injection)
  - Validates `EMAIL_TO` email format
  - Validates `SMTP_PORT` is valid port number (1-65535)
  - Validates `MAX_ALERT_QUEUE_*` settings are numeric
  - FATAL exit on security validation failures (prevents running with dangerous config)

### Fixed
- **State File Persistence** — fixes critical re-alert spam on reboots:
  - Changed default `STATE_FILE` from `/tmp/telemon_sys_alert_state` to `${SCRIPT_DIR}/.telemon_state`
  - `/tmp` is cleared on reboot → state lost → confirmation counts reset → false re-alerts
  - Added auto-migration: on first run, migrates existing state from `/tmp` to persistent location
  - Logs warning if state detected in `/tmp` with instructions to update `.env`
  - For production, use `/var/lib/telemon/state` or `~/.local/share/telemon/state`
  
- **Bounded Alert Queue** — prevents unbounded disk growth from failed alerts:
  - Added `MAX_ALERT_QUEUE_SIZE` (default: 1MB) — truncates oldest alerts if exceeded
  - Added `MAX_ALERT_QUEUE_AGE` (default: 24h) — clears entire queue if older than threshold
  - Queue is now bounded: cannot grow indefinitely from persistent Telegram failures
  - Logs warnings when queue is truncated or cleared

- **Partial Alert Delivery** — fixed inconsistent reliability across channels:
  - All channels (Telegram, webhook, email) now attempted independently
  - Track individual channel success/failure separately
  - Log warnings when secondary channels (webhook/email) fail even if Telegram succeeds
  - Only queue for retry when primary channel (Telegram) fails
  - Previously: if Telegram succeeded but email failed, email failure was silent

- **Silent Check Failures** — now warns when enabled checks cannot run:
  - Changed log level from DEBUG to WARN for missing critical dependencies
  - Affected checks: ping, lm-sensors, GPU tools (nvidia-smi/intel_gpu_top), database clients, DNS tools
  - Added helpful installation hints in warning messages
  - Previously: checks silently skipped, users didn't know monitoring wasn't working

- **Code Quality** — fixed inconsistent state key generation in database checks:
  - MySQL, PostgreSQL, and Redis checks now use centralized `sanitize_state_key()` function
  - Previously used inline pattern substitution which violated DRY principle

- **State Key Consistency** — fixed inconsistent `internet` state key:
  - Changed `check_internet()` state key from `inet` to `internet` to match function name
  - Updated AGENTS.md documentation to reflect the correct key name

### Added
- **ODBC Database Monitoring** — universal database connectivity support:
  - New `check_odbc()` function for monitoring any ODBC-compatible database
  - Supports SQL Server, Oracle, IBM DB2, Informix, Sybase, and more
  - DSN-based and connection string-based configuration options
  - Timeout support via `ODBC_CHECK_TIMEOUT` parameter
  - Configuration validation in `run_validate()`
  - State key pattern: `odbc_<connection_name>`
  - Improves maintainability and ensures consistent state key format

### Added
- **ODBC Database Monitoring** — monitor any database via unixODBC:
  - New function `check_odbc()` monitors Microsoft SQL Server, Oracle, DB2, and more
  - Config: `ENABLE_ODBC_CHECKS`, `ODBC_CONNECTIONS` (space-separated names)
  - Per-connection config: `ODBC_<name>_DSN` or `ODBC_<name>_DRIVER` + `SERVER` + `DATABASE`
  - Authentication: `ODBC_<name>_USER`, `ODBC_<name>_PASS` (passed securely via env vars)
  - Custom test query: `ODBC_<name>_QUERY` (default: "SELECT 1")
  - Supports DSN-based or connection string-based configurations
  - Generates state keys: `odbc_<connection_name>`
  - Dependencies: `unixodbc` package + database-specific ODBC drivers

- **Native SMTP Support** — send email alerts directly via curl without local mailer:
  - New config options: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_TLS`
  - Supports authenticated SMTP (Gmail, SendGrid, AWS SES, etc.)
  - STARTTLS on port 587, SMTPS (SSL) on port 465
  - Password URL-encoding for special characters (@, #, %, &, =, ?)
  - Falls back to local mailers (msmtp/sendmail) when SMTP_HOST not set
  - Warns if SMTP auth used without TLS (plaintext protection)
  - Credentials redacted from error logs
  - See [Email Alerts documentation](README.md#email-alerts) for setup guide

- **Enhanced Auto-Discovery** — comprehensive system scanning with smart defaults:
  - Run: `telemon-admin.sh discover` to scan hardware, services, and infrastructure
  - **Hardware Detection**: NVMe drives, NVIDIA/Intel GPUs, UPS (APC/NUT/upower), lm-sensors, RAID/ZFS/LVM
  - **Infrastructure Detection**: Docker Swarm, Kubernetes, Proxmox VE, KVM/QEMU, NFS/SMB mounts, WireGuard, Tailscale, HAProxy
  - **Database Detection**: MySQL/MariaDB, PostgreSQL, Redis (only if servers running, not just clients)
  - **Application Detection**: RabbitMQ, Mosquitto MQTT, Fail2ban, CrowdSec, Elasticsearch, MongoDB
  - **Smart Thresholds**: CPU/memory thresholds based on actual hardware specs (RAM size, core count)
  - **Enhanced Cron Detection**: Detects cron, crond, cronie, anacron, systemd-cron, and systemd timers
  - Generates ready-to-use `.env` configuration with helpful comments
  - Test coverage: 55+ new tests for discovery system (340 total tests)

- **Improved Installer** — better automation and container support:
  - `--silent` flag for non-interactive installs (CI/CD friendly)
  - `--systemd` flag for systemd timer instead of cron
  - Proper argument parsing (fixes --silent being interpreted as directory)
  - Auto-detects local clone vs remote install
  - Environment variables: `TELEMON_SILENT`, `TELEMON_SYSTEMD`
  - Warns when crontab missing and suggests `--systemd`

### Security
- **SMTP Password Protection** — URL-encoding prevents credential issues:
  - Special characters (@, #, %, &, =, ?) in passwords are URL-encoded
  - Prevents curl from misinterpreting @ in passwords as URL delimiter
  - Order-safe encoding (encodes % first to avoid double-encoding)
- **Database Password Security** — fixed credential exposure in process listings:
  - MySQL/MariaDB: Password now passed via `MYSQL_PWD` environment variable instead of `--password` flag
  - PostgreSQL: Password now passed via `PGPASSWORD` environment variable instead of connection string
  - Redis: Password now passed via `REDISCLI_AUTH` environment variable instead of `-a` flag
  - Prevents password exposure via `ps aux` during brief command execution windows

### Fixed
- **PING_TARGET Validation** — added strict input validation to prevent command injection via ping target
- **check_threshold() Numeric Validation** — added input validation to reject non-numeric values and provide safe defaults
- **Documentation** — corrected `check_threshold()` documentation in AGENTS.md with complete parameter reference

### Changed
- **DRY Refactoring** — migrated remaining check functions to use `check_threshold()` helper:
  - `check_cpu()` — now uses `check_threshold()` with `THRESHOLD_STATE` for top process capture
  - `check_swap()` — migrated from manual threshold logic to `check_threshold()`
  - `check_zombies()` — migrated from manual threshold logic to `check_threshold()`
  - `check_iowait()` — migrated from manual threshold logic to `check_threshold()`
  - Eliminated ~60 lines of duplicated threshold checking code
- **Test Coverage** — expanded test suite from 207 to 219 tests:
  - Added `test_check_threshold_helper()` — 8 tests for threshold helper validation
  - Added `test_security_database_passwords()` — 4 tests for credential security

### Security
- **Security Audit 2026-04-16**: Comprehensive white-box security review completed
  - VULN-001: Command injection protection in `auto_remediate()` via `is_valid_service_name()`
  - VULN-002: Path traversal protection in drift/integrity checks via `is_safe_path()`
  - VULN-003: Hostname validation in TCP port checks via `is_valid_hostname()` with port range validation
  - VULN-004: SSRF protection in site monitoring via `is_internal_ip()` blocking internal/reserved IPs
  - VULN-005: Regex injection protection in log pattern matching with validation
  - VULN-006: Email header injection protection via `is_valid_email()` RFC 5322 validation
  - VULN-007: Weak hash algorithm replaced — `portable_md5()` replaced with `portable_sha256()`
  - VULN-008: Docker socket security warning documented in docker-compose.yml
  - Added security validation helpers to `lib/common.sh`: `is_valid_service_name()`, `is_valid_hostname()`, `is_safe_path()`, `is_valid_email()`, `is_internal_ip()`

### Added
- **Stale Lock Detection** — automatic recovery from crashed/hung processes:
  - Lock files now store `PID timestamp` format for age detection
  - Locks older than 5 minutes (300s) are automatically broken if holder process is dead
  - Eliminates "Another instance is running" errors from zombie lock files
  - Both flock and mkdir-based fallback mechanisms include stale detection
- **Test Coverage** — expanded test suite from 93 to 118 tests:
  - `test_log()` — Log level filtering, file creation, message formatting (5 tests)
  - `test_rotate_logs()` — Rotation triggering, backup creation (4 tests)  
  - `test_check_state_change()` — Confirmation counting, state transitions, rate limiting (16 tests)
- **Fleet Heartbeat Monitoring** — multi-server dead man's switch with two backends:
  - `send_heartbeat()` writes timestamped heartbeat files (shared storage) or POSTs to a webhook URL
  - `check_fleet_heartbeats()` detects stale/missing servers from `FLEET_EXPECTED_SERVERS` list
  - File format: 7 tab-separated fields (label, timestamp, status, check count, warn count, crit count, uptime)
  - `SERVER_LABEL` config (defaults to hostname) used in alert headers and heartbeat identity
  - `server_label` field added to webhook and escalation JSON payloads
  - Fleet summary in `run_digest()` output (server count, stale/missing breakdown)
  - Fleet validation in `run_validate()` with cross-validation (webhook mode + fleet check warning)
- **Predictive Resource Exhaustion** — trend tracking and linear regression for disk, memory, swap, and inode metrics:
  - `linear_regression()` computes least-squares slope/intercept from historical datapoints (pure awk)
  - `record_trend()` appends timestamped values to `${STATE_FILE}.trend` with atomic writes via `safe_write_state_file()`
  - `check_prediction()` fires WARNING via `check_state_change()` when exhaustion projected within `PREDICT_HORIZON_HOURS`
  - Tracks disk space (`predict_disk_*`), inodes (`predict_inode_*`), memory (`predict_memory`), and swap (`predict_swap`)
  - Configurable via `PREDICT_HORIZON_HOURS`, `PREDICT_DATAPOINTS`, `PREDICT_MIN_DATAPOINTS`
  - Validation in `run_validate()` with cross-validation (DATAPOINTS >= MIN_DATAPOINTS)
- `telemon-admin.sh`: `fleet-status` command — color-coded table of all heartbeat files with age, status, and checks
- `telemon-admin.sh`: heartbeat file included in backup/restore; heartbeat info shown in `status` output
- `telemon-admin.sh`: `digest` command — proxy to `telemon.sh --digest` for CLI consistency
- `telemon.sh`: `--validate` now checks STATE_FILE directory writability, TOP_PROCESS_COUNT, SITE_EXPECTED_STATUS, SITE_MAX_RESPONSE_MS, SITE_SSL_WARN_DAYS, and LOG_WATCH_LINES
- `telemon.sh`: CPU temperature monitoring now reports max across all CPU packages (multi-socket support)
- `telemon.sh`: SSL certificate expiry and verification checks now run even when site returns unexpected HTTP status (previously only checked on OK)

### Fixed
- **CRITICAL**: `run_validate()` regex validation for LOG_WATCH_PATTERNS was broken — semicolon between `grep` and `[ $? -eq 2 ]` made them two independent commands, so invalid regexes were never detected
- **CRITICAL**: `telemon-admin.sh` `cmd_restore()` lacked symlink protection — could overwrite arbitrary files via symlink attack on STATE_FILE, ENV_FILE, or LOG_FILE
- **HIGH**: `is_in_maintenance_window()` crashed entire script on malformed MAINT_SCHEDULE — invalid time values caused arithmetic error under `set -e`; now validates components before arithmetic
- **HIGH**: `check_cpu()` crashed on empty/malformed `/proc/loadavg` — no null-check before awk arithmetic
- **HIGH**: Clock skew (NTP correction) broke alert rate limiting indefinitely — negative `now - last_sent` delta satisfied cooldown condition forever; now resets on negative delta
- **HIGH**: `telemon-admin.sh` `cmd_reset_state()` only removed main state file and lock — left `.cooldown`, `.queue`, `.escalation`, `.integrity`, `.net` orphaned, causing stale data on next run
- **MEDIUM**: `telemon-admin.sh` missing `umask 077` — backup files could be world-readable if shell had permissive umask, exposing `.env` secrets
- **MEDIUM**: `telemon-admin.sh` `cmd_backup()` only backed up main state file — missed 5 state file variants (cooldown, queue, escalation, integrity, net); restore lost operational context
- **MEDIUM**: `telemon-admin.sh` `cmd_backup()` had no error handling on `mkdir`/`cp` — silent backup failures reported success
- **MEDIUM**: `check_sites()` response time conversion crashed on non-numeric curl output — now validates with regex before awk
- **MEDIUM**: `run_digest()` word splitting in array iteration — `for key in $(echo ...)` broke on keys with spaces; replaced with `while read` from process substitution
- **MEDIUM**: `md5sum` output format differs between GNU and BSD — added `awk '{print $1}'` for portable hash extraction in site, log, and integrity state keys
- **LOW**: `html_escape()` used `echo` which could interpret escape sequences — replaced with `printf '%s'`
- **LOW**: Webhook, email, and escalation HTML-stripping used `echo` — replaced with `printf '%s\n'` to prevent escape interpretation
- **LOW**: Log pattern `<pre>` block used `echo` for already-escaped content — replaced with `printf '%s'`
- **LOW**: Unquoted `$$` in PID lock file write — now quoted for consistency
- **LOW**: `telemon-admin.sh` `cmd_status()` state file parsing could fail on malformed entries — added empty-value guard and `|| true` on read loop
- **LOW**: `lib/common.sh` missing POSIX trailing newline
- **HIGH** (fleet): Heartbeat files on shared storage validated against injection — `hb_status` checked against `^(OK|WARNING|CRITICAL)$` allowlist, `hb_check_count` against `^[0-9]+$` before embedding in HTML
- **MEDIUM** (fleet): TOCTOU symlink race on heartbeat file write — uses `mv -T` (won't follow symlinks) with fallback, sticky bit on heartbeat directory
- **MEDIUM** (fleet): Heartbeat files no longer expose internal state key names — replaced with numeric warn/crit counts only
- **LOW** (fleet): `telemon-admin.sh` sanitization mismatch — `sed 's/[^a-zA-Z0-9_]/_/g'` replaced with `tr -c 'a-zA-Z0-9_.-' '_'` to match `telemon.sh` pattern (preserves hyphens and dots in filenames)

### Changed
- `telemon-admin.sh` `cmd_restore()` now restores all state file variants (cooldown, queue, escalation, integrity, net)
- `telemon-admin.sh` `cmd_reset_state()` now removes all 7 state-related files

### Added
- CLI flags for `telemon.sh`: `--test` / `-t` (validate + send test Telegram message), `--validate` / `-v` (check config without sending), `--help` / `-h`
- `install.sh`: `--yes` / `-y` flag for non-interactive installs (CI, scripting, automation)
- `install.sh`: automatically sets `.env` to `chmod 600` (owner-only) to protect bot tokens
- `.env.example`: clarified that `CRITICAL_CONTAINERS` uses container names from `docker ps --format '{{.Names}}'`, not image names
- `README.md`: "Common Configurations" section with copy-paste `.env` quickstart profiles for Docker host, web server, media server, bare metal, and Node.js setups
- Uninstall script (`uninstall.sh`) for clean removal
- Update mechanism (`update.sh`) with git integration
- Administration utility (`telemon-admin.sh`) for backup/restore/status
- Systemd timer/service support as alternative to cron
- Docker support with Dockerfile and docker-compose.yml
- GitHub issue templates and PR template
- GitHub Actions CI workflow for shellcheck and testing
- GitHub Actions release workflow
- Man page (`docs/man/telemon.1`)
- Quick reference card (`docs/QUICKREF.md`)
- CONTRIBUTING.md guidelines
- Shared helper library (`lib/common.sh`) for auxiliary scripts

### Fixed
- **CRITICAL**: Double-flock deadlock — cron wrapped telemon.sh in `flock`, but telemon.sh also flocks internally, causing every cron run to exit immediately
- **CRITICAL**: Bot token visible in `ps aux` / `/proc/*/cmdline` — `send_telegram()` now uses `curl --config <(...)` process substitution
- **CRITICAL**: Bot token leaked in error logs — raw Telegram API response no longer logged, only the error description
- **HIGH**: Duplicate alerts — state change fired at count=1 AND again at confirmation threshold; now only alerts once at confirmation threshold
- **HIGH**: Dockerfile missing `COPY lib/ ./lib/` — admin scripts crashed in container
- **HIGH**: `df` in `check_disk()` had no timeout — NFS hangs could freeze telemon indefinitely
- **HIGH**: PM2 process names interpolated directly into Python string literal (code injection) — now passed via environment variable
- **HIGH**: State file in `/tmp` was world-readable (644) and vulnerable to symlink attacks — added symlink check and `umask 077`
- **HIGH**: Token prefix (first 10 chars) printed in `--validate` output — now shows character count only
- **MEDIUM**: `--insecure` flag on site check curl made SSL verification always succeed — removed, SSL checks now work
- **MEDIUM**: Site URL key collision — `https://foo-bar.com` and `https://foo.bar.com` produced same state key — now uses md5 hash
- **LOW**: Log files created world-readable (644) — added `umask 077` at script start
- **LOW**: Backup directory contained unencrypted `.env` copy with default permissions — now `chmod 700` dir, `chmod 600` files

### Changed
- Anonymized project - removed hardcoded user paths
- Fixed install.sh step numbering (was 4/6, 5/6, 6/6 → now 4/7, 5/7, 6/7, 7/7)
- Updated telemon-logrotate.conf to use environment variables
- Docker/PM2 enable flags now default to `false` consistently (matching `.env.example`)
- Alert deduplication rewritten: non-OK states require full confirmation count before alerting; resolution alerts only fire for previously confirmed states

## [1.0.0] - 2025-01-15

### Added
- Initial release of Telemon
- Core system monitoring: CPU, memory, disk, internet connectivity
- Process monitoring: system processes, Docker containers, PM2 processes
- Website monitoring: HTTP/HTTPS endpoints, SSL certificate expiry
- Stateful alert deduplication with confirmation count
- Self-rotating logs (10MB limit, 5 backups)
- Lock file mechanism to prevent overlapping runs
- Timeout wrapper for external commands
- HTML-formatted Telegram messages with emoji indicators
- Feature toggles (ENABLE_* variables) for all checks
- Comprehensive threshold validation
- First-run bootstrap message
- Installation script with dependency checking
- Logrotate integration
- State persistence across reboots

### System Checks
- CPU load monitoring (% of available cores)
- Memory availability tracking (% free)
- Disk space monitoring (all partitions)
- Internet connectivity (ping to 8.8.8.8)
- Swap usage monitoring
- I/O wait monitoring
- Zombie process detection
- System process health (sshd, docker, etc.)
- Failed systemd services detection
- Docker container status
- PM2 process monitoring
- Website/endpoint monitoring

### Documentation
- README.md with comprehensive setup guide
- AGENTS.md with architecture documentation
- .env.example with all configuration options
- MIT License

[Unreleased]: https://github.com/SwordfishTrumpet/telemon/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/SwordfishTrumpet/telemon/releases/tag/v1.0.0
