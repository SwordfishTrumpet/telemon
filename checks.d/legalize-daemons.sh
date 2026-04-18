#!/usr/bin/env bash
# =============================================================================
# Telemon Plugin: Legalize NL Services Monitor
# Monitors individual daemons inside the legalize-nl-services container
# =============================================================================

# Check the health endpoint for individual services
HEALTH_OUTPUT=$(curl -s --max-time 5 http://localhost:8000/health 2>/dev/null)

if [[ -z "$HEALTH_OUTPUT" ]]; then
    echo "CRITICAL|legalize_health|Health endpoint unreachable - container may be down"
    exit 0
fi

# Parse health status for each service
RECHTSPRAAK_STATUS=$(echo "$HEALTH_OUTPUT" | grep -o '"rechtspraak_db":"[^"]*"' | cut -d'"' -f4 | cut -d' ' -f1)
LAWS_STATUS=$(echo "$HEALTH_OUTPUT" | grep -o '"law_files":"[^"]*"' | cut -d'"' -f4 | cut -d' ' -f1)
INDEX_STATUS=$(echo "$HEALTH_OUTPUT" | grep -o '"law_index":"[^"]*"' | cut -d'"' -f4 | cut -d' ' -f1)

# Check if daemons are running inside the container (using docker top)
BRIDGE_RUNNING=$(docker top legalize-nl-services 2>/dev/null | grep -c "bridge.py.*--daemon" || echo "0")
RECHTSPRAAK_RUNNING=$(docker top legalize-nl-services 2>/dev/null | grep -c "rechtspraak.py.*--daemon" || echo "0")
LAWS_RUNNING=$(docker top legalize-nl-services 2>/dev/null | grep -c "cli.py daemon" || echo "0")

# Determine overall state and create detailed message
CRITICAL_COUNT=0
WARNING_COUNT=0
DETAIL_PARTS=()

# Check Rechtspraak DB (from health endpoint)
if [[ "$RECHTSPRAAK_STATUS" == "ok" && "$RECHTSPRAAK_RUNNING" -gt 0 ]]; then
    DETAIL_PARTS+=("✓ rechtspraak_db: ok")
else
    DETAIL_PARTS+=("✗ rechtspraak_db: ${RECHTSPRAAK_STATUS:-unknown} (process: $RECHTSPRAAK_RUNNING)")
    ((CRITICAL_COUNT++))
fi

# Check Law Files (laws daemon - from health endpoint)
if [[ "$LAWS_STATUS" == "ok" && "$LAWS_RUNNING" -gt 0 ]]; then
    DETAIL_PARTS+=("✓ law_files: ok")
else
    DETAIL_PARTS+=("✗ law_files: ${LAWS_STATUS:-unknown} (process: $LAWS_RUNNING)")
    ((CRITICAL_COUNT++))
fi

# Check Law Index
if [[ "$INDEX_STATUS" == "ok" ]]; then
    DETAIL_PARTS+=("✓ law_index: ok")
else
    DETAIL_PARTS+=("✗ law_index: ${INDEX_STATUS:-unknown}")
    ((WARNING_COUNT++))
fi

# Check Bridge daemon (process-based since not in health endpoint)
if [[ "$BRIDGE_RUNNING" -gt 0 ]]; then
    DETAIL_PARTS+=("✓ bridge_daemon: running ($BRIDGE_RUNNING processes)")
else
    DETAIL_PARTS+=("✗ bridge_daemon: NOT RUNNING")
    ((CRITICAL_COUNT++))
fi

# Format the detail message
DETAIL=$(IFS=' | '; echo "${DETAIL_PARTS[*]}")

# Output result
if [[ $CRITICAL_COUNT -gt 0 ]]; then
    echo "CRITICAL|legalize_daemons|$DETAIL"
elif [[ $WARNING_COUNT -gt 0 ]]; then
    echo "WARNING|legalize_daemons|$DETAIL"
else
    echo "OK|legalize_daemons|$DETAIL"
fi
