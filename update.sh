#!/usr/bin/env bash
# =============================================================================
# Telemon -- Update Script
# =============================================================================
# Updates Telemon to the latest version while preserving configuration.
# Usage: bash update.sh [--check]
#   --check  Only check for updates, don't apply them
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/SwordfishTrumpet/telemon.git"
TEMP_DIR=""
BACKUP_DIR=""
CHECK_ONLY=false

# Load shared helpers
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --check)
            CHECK_ONLY=true
            ;;
        --help|-h)
            echo "Usage: bash update.sh [--check]"
            echo "  --check  Only check for updates, don't apply"
            exit 0
            ;;
    esac
done

echo "============================================="
echo " Telemon - Update Manager"
echo "============================================="
echo ""

# ---------------------------------------------------------------------------
# Get current version (uses shared helper)
# ---------------------------------------------------------------------------
get_current_version() {
    get_telemon_version
}

# ---------------------------------------------------------------------------
# Check for updates
# ---------------------------------------------------------------------------
check_for_updates() {
    echo "[1/3] Checking for updates..."
    
    if [[ ! -d "${SCRIPT_DIR}/.git" ]]; then
        echo -e "${RED}ERROR: Not a git repository.${NC}"
        echo "  This installation was not cloned from git."
        echo "  To update, backup your .env and re-clone:"
        echo "    cp .env ~/telemon.env.backup"
        echo "    cd .. && rm -rf telemon"
        echo "    git clone ${REPO_URL}"
        echo "    cd telemon && cp ~/telemon.env.backup .env"
        return 1
    fi
    
    cd "$SCRIPT_DIR"
    
    # Fetch latest from remote
    if ! git fetch origin --quiet 2>/dev/null; then
        echo -e "${RED}ERROR: Cannot fetch from remote.${NC}"
        echo "  Check your internet connection and repository access."
        return 1
    fi
    
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null || echo "")
    
    if [[ -z "$REMOTE" ]]; then
        echo -e "${YELLOW}WARNING: Cannot determine remote version.${NC}"
        return 1
    fi
    
    if [[ "$LOCAL" == "$REMOTE" ]]; then
        echo -e "${GREEN}You are running the latest version.${NC}"
        echo "  Current: $(get_current_version)"
        return 0
    else
        echo -e "${YELLOW}Update available!${NC}"
        echo "  Current:  $(get_current_version) ($(git rev-parse --short HEAD))"
        echo "  Latest:   $(git rev-parse --short origin/main 2>/dev/null || git rev-parse --short origin/master)"
        
        # Show changelog preview
        echo ""
        echo "Recent changes:"
        git log --oneline HEAD..origin/main 2>/dev/null | head -5 || \
        git log --oneline HEAD..origin/master 2>/dev/null | head -5 || \
        echo "  (changelog unavailable)"
        
        return 2  # Exit code 2 means update available
    fi
}

# ---------------------------------------------------------------------------
# Create backup
# ---------------------------------------------------------------------------
create_backup() {
    echo "[2/3] Creating backup..."
    
    BACKUP_DIR="${SCRIPT_DIR}/.backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Backup critical files
    cp "${SCRIPT_DIR}/.env" "$BACKUP_DIR/" 2>/dev/null || true
    cp "${SCRIPT_DIR}/telemon.log" "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup state file
    load_telemon_env
    if [[ -f "$STATE_FILE" ]]; then
        cp "$STATE_FILE" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    echo "  Backup created: ${BACKUP_DIR}"
}

# ---------------------------------------------------------------------------
# Apply update
# ---------------------------------------------------------------------------
apply_update() {
    echo "[3/3] Applying update..."
    
    cd "$SCRIPT_DIR"
    
    # Stash any local changes (shouldn't happen, but just in case)
    git stash --quiet 2>/dev/null || true
    
    # Pull latest
    if git pull --quiet origin main 2>/dev/null || git pull --quiet origin master 2>/dev/null; then
        echo -e "${GREEN}Update successful!${NC}"
        echo "  New version: $(get_current_version)"
        
        # Re-run installer to update cron/systemd if needed
        echo ""
        echo "Re-running installer to update system integration..."
        bash "${SCRIPT_DIR}/install.sh" --yes
        
        return 0
    else
        echo -e "${RED}ERROR: Update failed.${NC}"
        echo "  Your backup is at: ${BACKUP_DIR}"
        echo "  To restore: cp ${BACKUP_DIR}/.env ${SCRIPT_DIR}/"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    CURRENT=$(get_current_version)
    echo "Current version: $CURRENT"
    echo ""
    
    check_for_updates && local exit_code=0 || local exit_code=$?
    
    if [[ $exit_code -eq 2 ]]; then
        # Update available
        if [[ "$CHECK_ONLY" == "true" ]]; then
            echo ""
            echo "Run without --check to apply the update."
            exit 0
        fi
        
        echo ""
        read -rp "Apply update? [Y/n] " answer
        answer="${answer:-Y}"
        
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            create_backup
            apply_update
        else
            echo "Update cancelled."
        fi
    elif [[ $exit_code -eq 0 ]]; then
        # Already up to date
        exit 0
    else
        # Error occurred
        exit 1
    fi
}

main "$@"
