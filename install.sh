#!/usr/bin/env bash
# =============================================================================
# Telemon -- One-Line Installer
# =============================================================================
# Install Telemon with a single command:
#   curl -fsSL https://raw.githubusercontent.com/SwordfishTrumpet/telemon/main/install.sh | bash
#
# Or with custom install directory:
#   curl -fsSL ... | bash -s -- /opt/telemon
#
# Features:
#   - Downloads latest release from GitHub
#   - Interactive .env configuration
#   - Automatic dependency checking
#   - Cron job setup
#   - Initial test run
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_OWNER="SwordfishTrumpet"
REPO_NAME="telemon"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

# Installation directory (can be overridden via first argument)
INSTALL_DIR="${1:-$HOME/telemon}"
CRON_SCHEDULE="*/5 * * * *"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if we're running from local repo or need to download
is_local_install() {
    [[ -f "${BASH_SOURCE[0]:-$0}" && "$(dirname "${BASH_SOURCE[0]:-$0}")" != "." ]] && \
    [[ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/telemon.sh" ]]
}

# Download a file from GitHub
download_file() {
    local file="$1"
    local dest="$2"
    local url="${RAW_URL}/${file}"
    
    if ! curl -fsSL --max-time 30 "$url" -o "$dest" 2>/dev/null; then
        log_error "Failed to download ${file}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Installation Steps
# ---------------------------------------------------------------------------

step_1_check_dependencies() {
    echo ""
    log_info "Step 1/8: Checking dependencies..."
    
    local missing=()
    local required=(curl bash awk)
    
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Please install them and re-run the installer."
        exit 1
    fi
    
    log_success "All required dependencies found (curl, bash, awk)"
    
    # Note optional dependencies
    local optional=()
    command -v ping &>/dev/null || optional+=("ping (for internet checks)")
    command -v nproc &>/dev/null || optional+=("nproc (for CPU detection)")
    command -v pgrep &>/dev/null || optional+=("pgrep (for process monitoring)")
    command -v docker &>/dev/null || optional+=("docker (for container monitoring)")
    command -v python3 &>/dev/null || optional+=("python3 (for PM2 & webhook support)")
    
    if (( ${#optional[@]} > 0 )); then
        echo ""
        echo "Optional dependencies (install if needed):"
        for note in "${optional[@]}"; do
            echo "  - $note"
        done
    fi
}

step_2_create_directory() {
    echo ""
    log_info "Step 2/8: Creating installation directory..."
    
    if [[ -d "$INSTALL_DIR" ]]; then
        log_warn "Directory ${INSTALL_DIR} already exists"
        read -rp "  Continue and update files? [Y/n] " answer
        answer="${answer:-Y}"
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
    else
        mkdir -p "$INSTALL_DIR"
    fi
    
    log_success "Installation directory ready: ${INSTALL_DIR}"
}

step_3_download_files() {
    echo ""
    log_info "Step 3/8: Downloading Telemon files..."
    
    # Create subdirectories
    mkdir -p "${INSTALL_DIR}/lib"
    mkdir -p "${INSTALL_DIR}/checks.d"
    
    # Core files to download
    local files=(
        "telemon.sh"
        "telemon-admin.sh"
        "lib/common.sh"
        "uninstall.sh"
        "update.sh"
        "telemon-logrotate.conf"
        "checks.d/example-plugin.sh"
    )
    
    local failed=0
    for file in "${files[@]}"; do
        local dest="${INSTALL_DIR}/${file}"
        echo -n "  Downloading ${file}... "
        if download_file "$file" "$dest"; then
            chmod +x "$dest" 2>/dev/null || true
            echo "OK"
        else
            echo "FAILED"
            ((failed++))
        fi
    done
    
    if (( failed > 0 )); then
        log_error "Failed to download ${failed} file(s)"
        exit 1
    fi
    
    log_success "All files downloaded successfully"
}

step_4_copy_local_files() {
    echo ""
    log_info "Step 3/8: Copying local files..."
    
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Create subdirectories
    mkdir -p "${INSTALL_DIR}/lib"
    mkdir -p "${INSTALL_DIR}/checks.d"
    
    # Copy core files
    cp "${script_dir}/telemon.sh" "${INSTALL_DIR}/"
    cp "${script_dir}/telemon-admin.sh" "${INSTALL_DIR}/"
    cp "${script_dir}/lib/common.sh" "${INSTALL_DIR}/lib/"
    cp "${script_dir}/uninstall.sh" "${INSTALL_DIR}/"
    cp "${script_dir}/update.sh" "${INSTALL_DIR}/" 2>/dev/null || true
    cp "${script_dir}/telemon-logrotate.conf" "${INSTALL_DIR}/"
    cp "${script_dir}/checks.d/example-plugin.sh" "${INSTALL_DIR}/checks.d/" 2>/dev/null || true
    
    # Make scripts executable
    chmod +x "${INSTALL_DIR}/"*.sh 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/lib/"*.sh 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/checks.d/"*.sh 2>/dev/null || true
    
    log_success "Local files copied to ${INSTALL_DIR}"
}

step_5_configure_env() {
    echo ""
    log_info "Step 4/8: Configuration setup..."
    
    local env_file="${INSTALL_DIR}/.env"
    local env_example="${INSTALL_DIR}/.env.example"
    
    # Download .env.example if not present locally
    if [[ ! -f "$env_example" ]]; then
        echo -n "  Downloading .env.example... "
        download_file ".env.example" "$env_example" || {
            log_error "Failed to download .env.example"
            exit 1
        }
        echo "OK"
    fi
    
    # Check if .env already exists
    if [[ -f "$env_file" ]]; then
        log_warn ".env already exists at ${env_file}"
        read -rp "  Keep existing configuration? [Y/n] " answer
        answer="${answer:-Y}"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            log_success "Using existing configuration"
            return 0
        fi
    fi
    
    echo ""
    echo "=============================================="
    echo "  Telegram Bot Configuration (REQUIRED)"
    echo "=============================================="
    echo ""
    echo "To get your Telegram credentials:"
    echo "  1. Message @BotFather on Telegram"
    echo "  2. Send /newbot and follow instructions"
    echo "  3. Copy the bot token (looks like: 123456789:ABC...)"
    echo "  4. Message @userinfobot to get your chat ID"
    echo ""
    
    local bot_token=""
    local chat_id=""
    local server_label=""
    
    # Prompt for bot token
    while [[ -z "$bot_token" ]]; do
        read -rp "Telegram Bot Token: " bot_token
        if [[ -z "$bot_token" ]]; then
            log_error "Bot token is required"
        fi
    done
    
    # Prompt for chat ID
    while [[ -z "$chat_id" ]]; do
        read -rp "Telegram Chat ID: " chat_id
        if [[ -z "$chat_id" ]]; then
            log_error "Chat ID is required"
        fi
    done
    
    # Prompt for server label (optional but recommended)
    read -rp "Server Label [$(hostname)]: " server_label
    server_label="${server_label:-$(hostname)}"
    
    echo ""
    echo "=============================================="
    echo "  Check Configuration (Optional)"
    echo "=============================================="
    echo ""
    
    # Docker
    local enable_docker="false"
    if command -v docker &>/dev/null; then
        read -rp "Enable Docker container monitoring? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] && enable_docker="true"
    fi
    
    # PM2
    local enable_pm2="false"
    if command -v pm2 &>/dev/null && command -v python3 &>/dev/null; then
        read -rp "Enable PM2 process monitoring? [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]] && enable_pm2="true"
    fi
    
    # Site monitoring
    local enable_sites="false"
    local site_urls=""
    read -rp "Enable website monitoring? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        enable_sites="true"
        read -rp "  URLs to monitor (space-separated): " site_urls
    fi
    
    # Create .env file
    cp "$env_example" "$env_file"
    
    # Update configuration values
    sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=\"${bot_token}\"/" "$env_file"
    sed -i "s/^TELEGRAM_CHAT_ID=.*/TELEGRAM_CHAT_ID=\"${chat_id}\"/" "$env_file"
    sed -i "s/^SERVER_LABEL=.*/SERVER_LABEL=\"${server_label}\"/" "$env_file"
    sed -i "s/^ENABLE_DOCKER_CONTAINERS=.*/ENABLE_DOCKER_CONTAINERS=${enable_docker}/" "$env_file"
    sed -i "s/^ENABLE_PM2_PROCESSES=.*/ENABLE_PM2_PROCESSES=${enable_pm2}/" "$env_file"
    sed -i "s/^ENABLE_SITE_MONITOR=.*/ENABLE_SITE_MONITOR=${enable_sites}/" "$env_file"
    
    # Add site URLs if provided
    if [[ -n "$site_urls" && "$enable_sites" == "true" ]]; then
        # Check if SITE_URLS line exists
        if grep -q "^SITE_URLS=" "$env_file"; then
            sed -i "s/^SITE_URLS=.*/SITE_URLS=\"${site_urls}\"/" "$env_file"
        else
            echo "" >> "$env_file"
            echo "# Monitored websites (space-separated URLs)" >> "$env_file"
            echo "SITE_URLS=\"${site_urls}\"" >> "$env_file"
        fi
    fi
    
    # Secure the .env file
    chmod 600 "$env_file"
    
    log_success "Configuration saved to ${env_file}"
}

step_6_setup_cron() {
    echo ""
    log_info "Step 5/8: Setting up cron job..."
    
    local monitor_script="${INSTALL_DIR}/telemon.sh"
    local cron_line="${CRON_SCHEDULE} ${monitor_script} >> ${INSTALL_DIR}/telemon_cron.log 2>&1"
    
    # Check if cron line already exists
    if crontab -l 2>/dev/null | grep -qF "$monitor_script"; then
        log_warn "Cron job already exists"
        read -rp "  Reinstall cron job? [y/N] " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            log_info "Keeping existing cron job"
            return 0
        fi
        # Remove old entry
        crontab -l 2>/dev/null | grep -vF "$monitor_script" | crontab -
    fi
    
    # Add new cron job
    (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
    
    log_success "Cron job installed (runs every 5 minutes)"
    echo "  Schedule: ${CRON_SCHEDULE}"
}

step_7_setup_logrotate() {
    echo ""
    log_info "Step 6/8: Setting up log rotation..."
    
    if ! command -v logrotate &>/dev/null; then
        log_warn "logrotate not found - using self-rotation (10MB limit)"
        return 0
    fi
    
    # Check if we can install system-wide config
    if [[ -d /etc/logrotate.d ]] && [[ -w /etc/logrotate.d ]]; then
        # Generate logrotate config
        cat > /etc/logrotate.d/telemon << EOF
${INSTALL_DIR}/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0600 $(id -un) $(id -gn)
}
EOF
        log_success "System logrotate config installed"
    else
        log_info "No write access to /etc/logrotate.d - using self-rotation"
        echo "  (Self-rotation: 10MB limit, 5 backups)"
    fi
}

step_8_run_test() {
    echo ""
    log_info "Step 7/8: Running validation..."
    
    cd "$INSTALL_DIR"
    
    # Syntax check
    echo -n "  Syntax check... "
    if bash -n "${INSTALL_DIR}/telemon.sh"; then
        echo "OK"
    else
        echo "FAILED"
        log_error "telemon.sh has syntax errors"
        return 1
    fi
    
    # Config validation
    echo -n "  Configuration validation... "
    if bash "${INSTALL_DIR}/telemon.sh" --validate 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
        log_warn "Configuration validation failed - check your .env file"
    fi
    
    echo ""
    log_info "Step 8/8: Sending test notification..."
    echo ""
    echo "This will run Telemon and send a test message to Telegram."
    echo "On first run, you'll receive a summary of all system metrics."
    echo ""
    
    read -rp "Run test now? [Y/n] " answer
    answer="${answer:-Y}"
    
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo ""
        echo "--- Running Telemon ---"
        bash "${INSTALL_DIR}/telemon.sh" || true
        echo "--- Test complete ---"
        echo ""
        log_success "Test notification sent! Check your Telegram."
    else
        log_info "Skipped test run"
    fi
}

print_summary() {
    echo ""
    echo "=============================================="
    echo "  Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Installation directory: ${INSTALL_DIR}"
    echo "Configuration file:     ${INSTALL_DIR}/.env"
    echo "Main script:            ${INSTALL_DIR}/telemon.sh"
    echo "Admin script:           ${INSTALL_DIR}/telemon-admin.sh"
    echo "Log file:               ${INSTALL_DIR}/telemon.log"
    echo "Cron schedule:          Every 5 minutes"
    echo ""
    echo "Quick Commands:"
    echo "  Run manually:       bash ${INSTALL_DIR}/telemon.sh"
    echo "  View logs:            tail -f ${INSTALL_DIR}/telemon.log"
    echo "  Admin tools:          bash ${INSTALL_DIR}/telemon-admin.sh --help"
    echo "  Update:               bash ${INSTALL_DIR}/update.sh"
    echo "  Uninstall:            bash ${INSTALL_DIR}/uninstall.sh"
    echo "  Send test alert:      bash ${INSTALL_DIR}/telemon.sh --test"
    echo "  Generate status:      bash ${INSTALL_DIR}/telemon.sh --digest"
    echo ""
    echo "Useful Admin Commands:"
    echo "  Backup config:        bash ${INSTALL_DIR}/telemon-admin.sh backup"
    echo "  Restore config:       bash ${INSTALL_DIR}/telemon-admin.sh restore <file>"
    echo "  Check fleet status:   bash ${INSTALL_DIR}/telemon-admin.sh fleet-status"
    echo "  Auto-discovery:       bash ${INSTALL_DIR}/telemon-admin.sh discover"
    echo ""
    echo "Documentation: https://github.com/${REPO_OWNER}/${REPO_NAME}"
    echo ""
    echo "=============================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "=============================================="
    echo "  Telemon - One-Line Installer"
    echo "=============================================="
    
    # Handle install directory argument if passed via command line
    if [[ -n "${1:-}" && ! "$1" =~ ^- ]]; then
        INSTALL_DIR="$1"
        shift
    fi
    
    log_info "Installation directory: ${INSTALL_DIR}"
    
    # Run installation steps
    step_1_check_dependencies
    step_2_create_directory
    
    # Determine if local or remote install
    if is_local_install; then
        step_4_copy_local_files
    else
        step_3_download_files
    fi
    
    step_5_configure_env
    step_6_setup_cron
    step_7_setup_logrotate
    step_8_run_test
    
    print_summary
}

# Run main function
main "$@"
