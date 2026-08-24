# Changelog

All notable changes to Telemon will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1] — 2026-08-24

### Removed
- **Docker deployment (deprecated)** — removed `docker-compose.yml` and `Dockerfile`. The compose file was already marked "reference only — not deployed" (see v1.2.0-era changelog); Telemon runs as a host cron job or systemd timer. Docker deployment required mounting the Docker socket (privilege-escalation vector) and duplicated the scheduler. The README "Alternative Deployment → Docker" section was removed and replaced with a deprecation note.
- **Site-specific Time Machine maintenance script (`timemachine-maintenance.sh`)** — moved out of the repo to `/opt/timemachine/` on the host (not part of Telemon; a CT-101-specific cron job). Root's crontab repointed to the new path. It was tracked in git but never shipped in release archives.
- **Stale man page (`docs/man/telemon.1`)** — documented "Telemon 1.0" (Jan 2025) with a minimal feature list; unreferenced by code, install scripts, README, or CI, and never installed to `man` dirs — yet it shipped stale in every release archive (`release.yml` copies `docs/` wholesale).

### Fixed
- **LXC first-run CPU fallback broken by float `/proc/uptime`** — `calculate_lxc_cpu_percent()` compared the raw float (e.g. `174757.74`) with `[[ -gt ]]`, producing `invalid arithmetic operator` on the first run (no baseline state file) and silently skipping the boot-average CPU estimate. `uptime_sec` is now truncated with `${uptime_sec%.*}` before the comparison, so the fallback fires correctly. Regression tests: `test_lxc_cpu_float_uptime`.
- **Unguarded `source` of `lib/common.sh`** — under `set -euo pipefail`, a missing `lib/common.sh` (partial deploy) killed the run at startup with only a bare stderr line: no log, no state update, no alert (silent monitoring gap). The source is now guarded and exits with an actionable `FATAL: lib/common.sh not found at <path>` message. Regression tests: `test_common_sh_source_guard`.
- **Proxmox storage capacity alerts never fired** — `check_proxmox_storage()` parsed `pvesm`'s percentage column (`45.52%`, a float) against an integer-only regex, so every decimal pool fell into the "OK active" skip branch and the warn/crit comparison was unreachable. The line is now parsed with a single `read` and the float is rounded via `awk 'BEGIN {printf "%.0f", u}'`. Regression test: `test_regression_proxmox_storage_float`.
- **MySQL replication-lag check dropped the password** — the `SHOW SLAVE STATUS` query ran plain `mysql` without `MYSQL_PWD` (the connection test exported it), so password-protected servers failed auth and lag was never detected. The query now uses the same `bash -c 'export MYSQL_PWD="$1"…'` pattern. Regression test: `test_regression_mysql_replication_password`.
- **`checks.d/timemachine-ct101.sh` crashed when `Results.plist` was missing** — `IS_RUNNING`/`HOURS_SINCE_WRITE` were only assigned inside the Results.plist-exists branch but referenced unconditionally in Check 7, hitting `unbound variable` under `set -u` (silently dropping ALL Time Machine monitoring for that run). Both are now initialized up front. Regression test: `test_regression_timemachine_missing_results` (stubbed `pct`, verified live on pve).
- **Heartbeat lookup failed for mixed-case labels** — `telemon-admin.sh` `cmd_status`/`cmd_backup` sanitized labels with inline `tr` (no lowercase), while `send_heartbeat` uses `sanitize_state_key` (lowercases) — so `SERVER_LABEL="Web-Prod-01"` heartbeat files were never found by admin. `sanitize_state_key` (and `html_escape`) moved to `lib/common.sh`; admin now calls the shared function.
- **Numeric emoji entities leaked to webhook/email/escalation** — `&#128308;` etc. rendered fine in Telegram (HTML mode) but appeared as literal text in plain-text channels. New shared `strip_html_for_plain_text()` (python3 `html.unescape`, named-only sed fallback) replaces the triplicated sed pipeline in `send_webhook`/`send_email`/`check_escalation`. Regression test: `test_regression_strip_html_entities`.
- **`PROXMOX_TASK_MINUTES` was dead config** — `check_proxmox_tasks()` counted every historical failure in the full `pvesh /cluster/tasks` log. The python filter now receives the window via env and counts only FAILED/ERROR tasks whose `starttime` is within it (missing `starttime` counts fail-safe). Regression test: `test_regression_proxmox_tasks_filter`.
- **File deletion was silently ignored by integrity & drift checks** — both `check_file_integrity` and `check_drift_detection` skipped missing files with no alert. Previously-tracked files that vanish now emit `CRITICAL` "DELETED" states (config removals excluded via the current-watch-list set). Regression tests: `test_regression_file_integrity_deletion`, `test_regression_drift_deletion`.
- **Stale `.cooldown`/`.detail` sidecars never cleared** — `save_state()` skipped writing empty sidecars, leaving stale cooldowns/details on disk that re-applied when a check was re-enabled. Both sidecars are now always written (empty clears stale entries). Regression test: `test_regression_save_state_sidecars`.
- **Queued alerts only retried when a new alert fired** — the queue-retry block lived inside `dispatch_with_retry`, which is only called on state changes. Extracted as `retry_alert_queue()` and invoked unconditionally every cycle. Regression test: `test_regression_alert_queue_retry`.
- **GNU-only `date '%-H'`/`'%-M'` in maintenance windows** — fails on BusyBox/macOS. `is_in_maintenance_window()` now uses padded `%H`/`%M` with `10#` base-10. Regression test: `test_regression_maintenance_window_portable`.
- **`check_sites` curl `--max-time` could exceed `CHECK_TIMEOUT`** — now capped at `CHECK_TIMEOUT`. Guard: `test_regression_sites_max_time_cap`.
- **Recovery alerts suppressed by `ALERT_COOLDOWN_SEC` (GH #2)** — `check_state_change` rate-limited OK-transitions too (900s cooldown vs 5-min cron), so an outage resolving <15 min after its alert never notified. Resolutions (`new_state == OK`) are now exempt from the cooldown gate; non-OK alerts remain rate-limited. Regression: `test_regression_recovery_alert_cooldown` (real function, 5 simulated cycles).
- **SMTP password percent-encoding broke auth (GH #3)** — `send_email_native_smtp` encoded `% @ # & = ?` in the password, but curl does **not** percent-decode `--user`, so any password containing those chars silently failed auth. Credentials now travel via a curl `--config` file carrying the raw password (same pattern as `send_telegram`'s bot token); the config file is removed and the trap cleared after curl. Regression: `test_regression_smtp_password_raw`.
- **Multi-line plugin stdout silently dropped (GH #4)** — `check_plugins` parsed all captured output, so a banner line produced a newline-containing STATE/KEY and the plugin was skipped entirely. It now parses the FIRST line whose leading field is a valid state. Regression: `test_regression_plugin_multiline_output`.
- **`.detail` state file corrupted by real newlines (GH #5)** — `save_state` now encodes backslash → `\\` and newline → `\\n`; `load_state` decodes via a `\\x1f` placeholder first (reversible for literal backslash-n). Regression: `test_regression_detail_newline_roundtrip`.
- **SSL expiry check hardcoded port 443 (GH #6)** — `check_sites` now extracts the port from the URL (default 443) and passes it to `openssl -connect host:port`; `-servername` keeps the bare host. Regression: `test_regression_sites_ssl_port`.
- **SSRF gap: `is_internal_ip` missed half of IPv6 ULA space (GH #7)** — matched only `fd00::/8`; now covers the full `fc00::/7` range, case-insensitive. Tests: fc00/fd00/fdff/uppercase internal, 2001:db8 external.
- **JSON status export never surfaced the Python error (SC2327/SC2328)** — `py_err=$(… > "$tmp_file" 2>&1)` redirected ALL output (stdout + stderr) to the file, so the command-substitution capture was always empty and the failure WARN carried no detail. Redirection order is now `2>&1 > "$tmp_file"` (stderr → `py_err`, stdout → file), so the actual traceback is logged on failure.
- **CI ShellCheck gate (v0.11) clean (SC2218)** — `check_cpu_mock` in the integration test was redefined per sub-test with hardcoded loads; it is now defined once, parameterized by load (the Test-5 variant already was), satisfying shellcheck's "function only defined later" check without behavior change.

### Changed
- **`_cmd_exists` moved to `lib/common.sh`** — was only defined in `telemon-admin.sh` but referenced by `telemon.sh`'s `run_validate` (dead half of an `||`, latent crash if `set -e` re-enabled). `run_validate` now relies solely on `command -v`; the stale `grep -v "Monitor run"` filter was removed.
- **Heartbeat parsing unified** — new `parse_heartbeat_line()` in `lib/common.sh` is the single source of truth for the 7-field tab-separated format, used by both `check_fleet_heartbeats` (telemon.sh) and `cmd_fleet_status` (admin) to prevent field-count drift.
- **Dead code removed** — `THRESHOLD_DETAIL`, `intercept`, `params`, `redirect_url` (incl. the `-w` format field), `resolved_values`, `priority`.
- **Performance** — `check_disk` takes one `df -P -i` snapshot up front; `get_top_processes` caches a single `ps -eo pid,pcpu,pmem,comm` snapshot per run; `check_proxmox_storage` reads each line once instead of 4× `awk`.
- **Network bandwidth keys unified** on `sanitize_state_key` (was inline `tr -c 'a-zA-Z0-9_' '_'`, different char class).
- **`discover` emits `NETWORK_INTERFACE` (singular) (GH #8)** — the generated `NETWORK_INTERFACES` (plural) was never read by any check; the default-route interface is now suggested as `NETWORK_INTERFACE`.
- **Dead `record_count` removed from `check_dns_records` (GH #9)** — write-only counter; the `run_validate` copy is kept.
- **`PREDICT_HYSTERESIS_HOURS` implemented as a real deadband (GH #10)** — `check_prediction` now holds a WARNING until hours-to-full exceeds the horizon + hysteresis (was dead config); slope<=0 recoveries still resolve immediately. Regression: `test_regression_predict_hysteresis`.
- **`test_check_state_change` rewritten on the REAL function (GH #11)** — the old test used a divergent inline copy (updates PREV_STATE in-run, cooldown disabled) — the exact reason GH #2 shipped green. Now extracts and runs the production function with state persisted between simulated runs; covers cooldown + resolution + delimiter-key rejection.
- **`run_digest` fleet summary uses shared `parse_heartbeat_line` (GH #12)** — no raw tab reads remain in telemon.sh/telemon-admin.sh; the 7-field heartbeat format is parsed only via the shared helper.
- **Shellcheck clean (SC2319 suppressed in `assert_false`)** — the test helper's `local result=$?` capture was flagged by shellcheck; documented as intentional (expansion precedes `local`) via a line-scoped disable, matching the project's suppression convention. Full `--severity=warning` run now exits 0.

### Tests
- **594 → 702 tests** — functional regression suite for the 2026-08-16 audit (extract-real-function + mock pattern), covering storage float %, MySQL replication password, timemachine unbound vars, entity decode, task window filter, integrity/drift deletion, sidecar clearing, portable date, max-time cap, alert queue retry, and dead-code guards. Coverage note added documenting functional vs grep-only coverage.
- **645 → 702 (GH #13)** — functional coverage added for previously-untested paths: `check_escalation` (brace-counting awk extractor — the function embeds a python dict whose closing `}` sits at column 0), `check_cron_jobs`, network bandwidth, Telegram truncation/tag-closing; SMTP/plugins/detail covered by the GH #3/#4/#5 regressions. Plus regressions for GH #2/#6/#7/#10.
- **CI portability — timemachine regression skips when the site plugin is absent** — `checks.d/timemachine-ct101.sh` is gitignored (deployment-local), so fresh CI checkouts lack it and the suite failed 2 assertions (``timemachine: emits valid STATE|KEY|DETAIL`` / ``plugin exits 0``). The test now emits a skip note and returns cleanly when the file is missing, matching the suite's existing skip pattern (root/unreadable-file, missing-client cases).
## [1.2.0] — 2026-08-05

### Fixed
- **`--generate-status-page` crash** — `declare -A CURR_STATE` without assignment triggered "unbound variable" under `set -u` (bash 5.2) because `load_state()` only populated `PREV_STATE`, never `CURR_STATE`. The status page both crashed and showed zero checks. `load_state()` now initializes and populates `CURR_STATE` from the persisted state file; `run_digest()` resets per-run globals to prevent stale keys.
- **Digest message truncation** — the daily digest included `STATE_DETAIL` for every check; with 60+ OK entries it routinely exceeded Telegram's 4096-char limit and was truncated (losing uptime + trailing entries). OK entries now show key-name only; CRITICAL/WARNING entries keep details.
- **Stale-lock detection dead code** — `exec 200>"$LOCK_FILE"` truncated the file, wiping the PID write on the line above it, so `lock_info` was always empty and stale-lock recovery never fired on the `flock` path. Holder PID/timestamp now live in a `${LOCK_FILE}.pid` sidecar written after acquiring the lock; `release_lock()` cleans it up.

### Added
- **`PROXMOX_GUESTS_IGNORE`** — space-separated list (accepts `ct:203` or bare `203`) of guests to exclude from `check_proxmox_guests()`, mirroring `PROXMOX_STORAGE_IGNORE`. Prevents perpetual CRITICAL alerts for intentionally-stopped guests (`onboot=0`).

### Removed
- **Site-specific plugins from tracking** — `checks.d/legalize-daemons.sh` and `checks.d/timemachine-ct101.sh` are deployment-local plugins referencing internal hostnames/container names. Removed from the git history entirely (filter-branch) and added to `.gitignore`.

## [1.1.1] — 2026-07-16

### Fixed
- **Unbound variable crash in check_internet()** — bare `${PING_FAIL_THRESHOLD}` expansion crashed under `set -u` when `.env` did not define the variable. Guests with `ENABLE_INTERNET_CHECK=true` but no `PING_FAIL_THRESHOLD` died mid-run (CT 209: 2451 runs started, 0 finished; CT 211: 2450 started, 0 finished). Fixed by capturing `${PING_FAIL_THRESHOLD:-3}` into a local `fail_threshold` at function entry and using it throughout. The validation at line 655 already had a default and was not affected.

## [1.1.0] — 2026-07-16

### Changed
- **Compact top-process lists in alerts** — `get_top_processes()` rewritten to keep alerts within Telegram's 4096-char limit (alerts were reaching ~19 KB and being truncated):
  - Now takes a mode argument (`cpu` | `mem`) and emits a **single** list instead of both CPU and memory tables — CPU alerts show top CPU consumers, memory alerts show top memory consumers
  - Shows process **name** only (`comm`) instead of the full command line (a single `kvm` entry carried ~3 KB of arguments)
  - Default count reduced from 5 to 3 (`TOP_PROCESS_COUNT` still configurable)
  - Filters out the `ps` sampling process itself (reported spurious ~100% CPU due to lifetime-average accounting over its tiny elapsed time)

### Documentation
- **docker-compose.yml** — marked as reference-only/deprecated; documented that Telemon runs via host cron and why the Docker socket mount was removed (privilege escalation vector)

### Tests
- Added integration tests for the full check→state→alert pipeline with mock data (+560 lines in `tests/run_tests.sh`)

## [1.0.1] — 2026-07-12

### Fixed
- **is_valid_number regex bug** — regex `^([1-9][0-9]*|0)$` rejected numbers with leading zeros (e.g., `"00"`, `"01"`), breaking `MAINT_SCHEDULE` entries with midnight start times like `Sun 00:30-02:30`. The `is_in_maintenance_window()` function logged `WARN` every 5-minute run (~288 warnings/day). Fixed by changing regex to `^[0-9]+$` — all callers already use `10#` prefix for octal safety.

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

- **ODBC String Concatenation Bug** — fixed connection string building:
  - Fixed missing `=` sign in `conn_str+"UID=${conn_user};"` and `conn_str+"PWD=${conn_pass};"`
  - Changed to `conn_str+="UID=${conn_user};"` and `conn_str+="PWD=${conn_pass};"`
  - Added test coverage to catch similar string concatenation issues
  - Bug prevented UID and PWD from being added to ODBC connection strings

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

[Unreleased]: https://github.com/SwordfishTrumpet/telemon/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/SwordfishTrumpet/telemon/releases/tag/v1.0.1
[1.0.0]: https://github.com/SwordfishTrumpet/telemon/releases/tag/v1.0.0
