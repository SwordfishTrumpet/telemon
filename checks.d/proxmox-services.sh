#!/usr/bin/env bash
# Telemon Plugin: Proxmox Cluster & Services Health
# Checks corosync, cluster status, and key Proxmox services
# Output format: STATE|KEY|DETAIL

# Check critical Proxmox services
SERVICES=("pveproxy" "pvedaemon" "pvestatd" "pve-firewall" "pve-ha-lrm" "pve-ha-crm")

for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "OK|pve_svc_${service}|Service $service is running"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        # Service is enabled but not running
        echo "CRITICAL|pve_svc_${service}|Service $service is NOT RUNNING (but enabled)"
    else
        # Service not enabled, skip
        echo "OK|pve_svc_${service}|Service $service not enabled"
    fi
done

# Check corosync if cluster is configured
if [[ -f "/etc/corosync/corosync.conf" ]]; then
    if systemctl is-active --quiet corosync 2>/dev/null; then
        # Get cluster status
        nodes=$(pvecm status 2>/dev/null | grep -c "Node name" || echo "0")
        if [[ "$nodes" -gt 1 ]]; then
            echo "OK|pve_cluster|Corosync running with $nodes nodes"
        else
            echo "OK|pve_cluster|Corosync running (single node cluster)"
        fi
    else
        echo "WARNING|pve_cluster|Corosync not running but configured"
    fi
else
    echo "OK|pve_cluster|No cluster configuration (standalone node)"
fi

# Check for failed systemd services (Proxmox-related)
# Use --state=failed for reliable output, skip header
failed_count=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | wc -l || echo "0")
if [[ "$failed_count" -gt 0 ]]; then
    failed_list=$(systemctl --failed --no-pager --plain 2>/dev/null | grep "failed" | awk '{print $2}' | head -5 | tr '\n' ', ')
    echo "WARNING|pve_failed_services|$failed_count failed services: $failed_list"
else
    echo "OK|pve_failed_services|No failed systemd services"
fi

# Check backup status (look for recent vzdump backups)
backup_dir="/mnt/usb1/dump"
if [[ -d "$backup_dir" ]]; then
    latest_backup=$(find "$backup_dir" -name "*.vma.zst" -o -name "*.tar.zst" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
        backup_age_hours=$(( ($(date +%s) - $(stat -c %Y "$latest_backup" 2>/dev/null)) / 3600 ))
        if [[ "$backup_age_hours" -lt 48 ]]; then
            echo "OK|pve_backups|Latest backup $backup_age_hours hours old"
        elif [[ "$backup_age_hours" -lt 168 ]]; then
            echo "WARNING|pve_backups|Latest backup $backup_age_hours hours old (expected within 48h)"
        else
            echo "CRITICAL|pve_backups|Latest backup $backup_age_hours hours old - BACKUP STALE!"
        fi
    else
        echo "WARNING|pve_backups|No backup files found in $backup_dir"
    fi
else
    echo "OK|pve_backups|Backup directory not mounted"
fi

# Check for VM locks (indicates hung operations)
lock_count=$(find /var/lock -name "*qemu*" -o -name "*lxc*" 2>/dev/null | wc -l)
if [[ "$lock_count" -gt 5 ]]; then
    echo "WARNING|pve_locks|$lock_count VM/container locks found - possible hung operations"
else
    echo "OK|pve_locks|Lock count normal ($lock_count)"
fi

echo "OK|pve_services_summary|Proxmox services checked"
