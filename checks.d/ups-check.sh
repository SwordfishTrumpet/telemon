#!/usr/bin/env bash
# Telemon Plugin: UPS/Battery Status Check
# Checks for UPS via apcaccess or upower
# Output format: STATE|KEY|DETAIL

# Check apcupsd (APC UPS)
if command -v apcaccess &>/dev/null && systemctl is-active --quiet apcupsd 2>/dev/null; then
    status=$(apcaccess status 2>/dev/null | grep -i "status" | awk -F':[ \t]+' '{print $2}' | tr -d ' ' || echo "UNKNOWN")
    charge=$(apcaccess status 2>/dev/null | grep -i "bcharge" | awk -F':[ \t]+' '{print $2}' | tr -d ' %' | cut -d'.' -f1 || echo "0")
    load=$(apcaccess status 2>/dev/null | grep -i "loadpct" | awk -F':[ \t]+' '{print $2}' | tr -d ' %' | cut -d'.' -f1 || echo "0")
    timeleft=$(apcaccess status 2>/dev/null | grep -i "timeleft" | awk -F':[ \t]+' '{print $2}' | tr -d ' ' || echo "unknown")
    
    if [[ "$status" == "ONBATT" ]]; then
        echo "CRITICAL|ups_status|UPS on BATTERY! Charge: ${charge}%, Load: ${load}%, Time left: $timeleft"
    elif [[ "$status" == "ONLINE" ]]; then
        if [[ "$charge" -lt 50 ]]; then
            echo "WARNING|ups_status|UPS online but low charge: ${charge}%"
        else
            echo "OK|ups_status|UPS online, Charge: ${charge}%, Load: ${load}%"
        fi
    else
        echo "WARNING|ups_status|UPS status: $status, Charge: ${charge}%"
    fi
    exit 0
fi

# Check NUT (Network UPS Tools)
if command -v upsc &>/dev/null; then
    ups_name=$(upsc -l 2>/dev/null | head -1)
    if [[ -n "$ups_name" ]]; then
        status=$(upsc "$ups_name" battery.charge 2>/dev/null || echo "0")
        charge=$(upsc "$ups_name" battery.charge 2>/dev/null | cut -d'.' -f1 || echo "0")
        
        if [[ "$charge" -lt 20 ]]; then
            echo "CRITICAL|ups_status|UPS battery critical: ${charge}%"
        elif [[ "$charge" -lt 50 ]]; then
            echo "WARNING|ups_status|UPS battery low: ${charge}%"
        else
            echo "OK|ups_status|UPS battery: ${charge}%"
        fi
        exit 0
    fi
fi

# Check laptop battery via upower
if command -v upower &>/dev/null; then
    battery_path=$(upower -e 2>/dev/null | grep -i battery | head -1)
    if [[ -n "$battery_path" ]]; then
        state=$(upower -i "$battery_path" 2>/dev/null | grep -i "state:" | awk '{print $2}' || echo "unknown")
        percentage=$(upower -i "$battery_path" 2>/dev/null | grep -i "percentage:" | tr -d '%' | awk '{print $2}' | cut -d'.' -f1 || echo "0")
        
        if [[ "$state" == "discharging" ]]; then
            if [[ "$percentage" -lt 20 ]]; then
                echo "CRITICAL|ups_status|Battery discharging at ${percentage}%!"
            elif [[ "$percentage" -lt 30 ]]; then
                echo "WARNING|ups_status|Battery discharging at ${percentage}%"
            else
                echo "OK|ups_status|Battery discharging at ${percentage}%"
            fi
        else
            echo "OK|ups_status|Battery $state at ${percentage}%"
        fi
        exit 0
    fi
fi

# No UPS detected
echo "OK|ups_status|No UPS/battery detected on this system"
