#!/usr/bin/env bash
# Telemon Plugin: SMART Health for SATA SSD (Samsung 870 EVO)
# Monitors /dev/sda which contains Proxmox OS
# Output format: STATE|KEY|DETAIL

# Source shared helpers for is_valid_number and other validation functions
source /opt/telemon/lib/common.sh

DEVICE="/dev/sda"

# Check if smartctl is available
if ! command -v smartctl &>/dev/null; then
    echo "OK|smart_sda|smartctl not available - skipping SMART check"
    exit 0
fi

# Check if device exists
if [[ ! -b "$DEVICE" ]]; then
    echo "OK|smart_sda|Device $DEVICE not found"
    exit 0
fi

# Get SMART health status
health=$(smartctl -H "$DEVICE" 2>/dev/null | grep -oP 'SMART overall-health self-assessment test result: \K\w+' || echo "UNKNOWN")

# Get temperature
temp=$(smartctl -A "$DEVICE" 2>/dev/null | grep -i temperature | awk '{print $10}' | head -1 || echo "")

# Get power-on hours
hours=$(smartctl -A "$DEVICE" 2>/dev/null | grep -i "power_on_hours\|power-on hours" | awk '{print $10}' | head -1 || echo "unknown")

# Get reallocated sector count
realloc=$(smartctl -A "$DEVICE" 2>/dev/null | grep -i "reallocated_sector\|reallocated sector" | awk '{print $10}' | head -1 || echo "0")

# Get pending sectors
pending=$(smartctl -A "$DEVICE" 2>/dev/null | grep -i "current_pending_sector\|pending sector" | awk '{print $10}' | head -1 || echo "0")

# Determine state
if [[ "$health" != "PASSED" ]]; then
    echo "CRITICAL|smart_sda|Samsung 870 EVO health: $health (Temp: ${temp}°C, Hours: $hours, Realloc: $realloc, Pending: $pending)"
elif [[ "$realloc" -gt 0 || "$pending" -gt 0 ]]; then
    echo "WARNING|smart_sda|Samsung 870 EVO has errors (Realloc: $realloc, Pending: $pending, Temp: ${temp}°C, Hours: $hours)"
elif [[ -n "$temp" ]] && is_valid_number "$temp" && [[ "$temp" -gt 60 ]]; then
    echo "WARNING|smart_sda|Samsung 870 EVO hot at ${temp}°C (Hours: $hours)"
else
    echo "OK|smart_sda|Samsung 870 EVO healthy (Health: $health, Temp: ${temp}°C, Hours: $hours, Realloc: $realloc)"
fi
