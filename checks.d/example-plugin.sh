#!/usr/bin/env bash
# =============================================================================
# Telemon Plugin Example: HTTP Service Health Check
# =============================================================================
# This is an example plugin showing how to extend Telemon with custom checks.
# 
# Plugin output format: STATE|KEY|DETAIL
#   STATE: OK, WARNING, or CRITICAL
#   KEY:   Unique identifier for this check (alphanumeric, underscore, hyphen)
#   DETAIL: Human-readable message (HTML-escaped automatically by Telemon)
#
# Place this file in checks.d/ directory (or set CHECKS_DIR in .env)
# Enable with: ENABLE_PLUGINS=true in .env
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration (customize for your service)
# -----------------------------------------------------------------------------
SERVICE_NAME="my-api"
SERVICE_URL="http://localhost:8080/health"
MAX_RESPONSE_TIME=2  # seconds

# -----------------------------------------------------------------------------
# Check Logic
# -----------------------------------------------------------------------------

# Check if curl is available
if ! command -v curl &>/dev/null; then
    echo "WARNING|${SERVICE_NAME}|curl not installed - cannot check ${SERVICE_NAME}"
    exit 0
fi

# Perform health check with timeout
RESPONSE=$(curl -s --max-time "$MAX_RESPONSE_TIME" -w "\n%{http_code}" "$SERVICE_URL" 2>/dev/null)

# Check if request succeeded
if [[ -z "$RESPONSE" ]]; then
    echo "CRITICAL|${SERVICE_NAME}|${SERVICE_NAME} is unreachable - no response"
    exit 0
fi

# Parse HTTP status code
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

# Determine state based on HTTP code
case "$HTTP_CODE" in
    200)
        echo "OK|${SERVICE_NAME}|${SERVICE_NAME} healthy (HTTP ${HTTP_CODE})"
        ;;
    429)
        echo "WARNING|${SERVICE_NAME}|${SERVICE_NAME} rate limited (HTTP ${HTTP_CODE})"
        ;;
    500|502|503|504)
        echo "CRITICAL|${SERVICE_NAME}|${SERVICE_NAME} error (HTTP ${HTTP_CODE})"
        ;;
    *)
        echo "WARNING|${SERVICE_NAME}|${SERVICE_NAME} unexpected status (HTTP ${HTTP_CODE})"
        ;;
esac
