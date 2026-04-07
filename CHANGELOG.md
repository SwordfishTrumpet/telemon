# Changelog

All notable changes to Telemon will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Changed
- Anonymized project - removed hardcoded user paths
- Fixed install.sh step numbering (was 4/6, 5/6, 6/6 → now 4/7, 5/7, 6/7, 7/7)
- Updated telemon-logrotate.conf to use environment variables

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
