# Telemon

System monitoring and alerting for Proxmox VE hosts and Linux servers. Tracks CPU, memory, disk, swap, I/O wait, zombie processes, internet connectivity, system processes, Docker containers, PM2, NVMe health, GPU, temperatures, network bandwidth, DNS, websites, TCP ports, log patterns, file integrity, config drift, and Proxmox-specific resources (VMs, LXCs, storage pools, cluster health, tasks).

Alerts are delivered via **Telegram** (primary), with optional webhook and email channels.

## Quick Start

```bash
# Clone
git clone https://github.com/SwordfishTrumpet/telemon.git /opt/telemon
cd /opt/telemon

# Configure
cp .env.example .env
chmod 600 .env
# Edit .env with your Telegram bot token, chat ID, and thresholds

# Validate
bash telemon.sh --validate

# Test Telegram delivery
bash telemon.sh --test

# Install cron job (runs every 5 minutes)
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/telemon/telemon.sh") | crontab -

# Optional: daily digest at 9am
(crontab -l 2>/dev/null; echo "0 9 * * * /opt/telemon/telemon.sh --digest") | crontab -
```

## Requirements

- **Bash 4.0+** (associative arrays)
- **curl** (Telegram API, webhooks, site checks)
- **python3** (JSON processing for webhooks, PM2, status export)
- Optional: `lm-sensors`, `smartmontools`, `docker`, `pm2`, `dig`, `nvme-cli`, `intel-gpu-tools`, `nvidia-smi`

## Usage

```
telemon.sh                  Run full monitoring cycle
telemon.sh --test           Validate config and send test message
telemon.sh --validate       Validate configuration only
telemon.sh --digest         Send daily health summary
telemon.sh --generate-status-page [file]  Generate HTML status page
telemon.sh --help           Show help

telemon-admin.sh backup     Backup config, state, and logs
telemon-admin.sh restore    Restore from backup
telemon-admin.sh status     Show current health status
telemon-admin.sh reset-state Reset all alert state
telemon-admin.sh validate   Validate configuration
telemon-admin.sh discover   Auto-discover hardware and services
```

## Configuration

All settings are in `.env`. See `.env.example` for the complete list of options.

Key sections:
- **Telegram credentials** (required)
- **Thresholds** for CPU, memory, disk, swap, I/O, zombies
- **Enable/disable flags** for each check module
- **Alert tuning**: confirmation count, cooldown period
- **Maintenance windows**: suppress alerts during backups

## Architecture

```
/opt/telemon/
├── telemon.sh             Main monitoring script (~6520 lines)
├── telemon-admin.sh       Administration utility
├── lib/common.sh          Shared helper functions
├── checks.d/              Plugin directory
│   ├── ups-check.sh       UPS/battery monitor
│   ├── proxmox-services.sh Proxmox service checker
│   └── smart-sda.sh      SATA SSD SMART monitor
├── .env                   Configuration (secrets - NOT committed)
└── .env.example           Configuration template
```

## Alert Deduplication

Telemon uses stateful alerting: it only notifies when a check's state **changes** (OK→WARNING, WARNING→OK, etc.) and confirms the new state over N consecutive runs (default: 3). This eliminates false alarms from transient spikes.

## License

MIT
