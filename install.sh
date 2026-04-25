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
# Silent/Automated install (CI/CD, no prompts):
#   TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="yyy" \
#     curl -fsSL ... | bash -s -- --silent
#
# With systemd instead of cron:
#   curl -fsSL ... | bash -s -- --systemd
#
# Features:
#   - Downloads latest release from GitHub (or uses local files if cloned)
#   - Interactive or silent .env configuration
#   - Automatic dependency checking
#   - Cron or systemd timer setup
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

# Default installation directory
DEFAULT_INSTALL_DIR="${HOME}/telemon"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CRON_SCHEDULE="*/5 * * * *"

# Flags
SILENT_MODE="${TELEMON_SILENT:-false}"
SYSTEMD_MODE="${TELEMON_SYSTEMD:-false}"
SKIP_TEST="${TELEMON_SKIP_TEST:-false}"

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

# ---------------------------------------------------------------------------
# Safe Config Value Writer
# ---------------------------------------------------------------------------
# Writes a value to a KEY="value" line in an env file safely.
# Handles special characters (& / \ $ etc.) without sed injection vulnerabilities.
# Usage: set_env_value <file> <key> <value>
set_env_value() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        # Key exists - update it using awk with proper quoting
        # Use \x27 to avoid quote escaping issues in awk
        awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1 == k {
            # Escape any " in the value for proper quoting
            gsub(/"/, "\\\"", v)
            print k, "\"" v "\""
            next
        } 1' "$env_file" > "${env_file}.tmp" && mv "${env_file}.tmp" "$env_file"
    else
        # Key does not exist - append it
        echo "${key}=\"${value}\"" >> "$env_file"
    fi
}

# Set a plain value (for booleans/simple values without quotes)
set_env_value_plain() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        # Key exists - update it
        sed -i "s/^${key}=.*/${key}=${value}/" "$env_file"
    else
        # Key does not exist - append it
        echo "${key}=${value}" >> "$env_file"
    fi
}

# Check if we're running from local repo or need to download
is_local_install() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || return 1
    [[ -f "${script_dir}/telemon.sh" ]]
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

# Parse command line arguments
parse_arguments() {
    local args=()
    
    for arg in "$@"; do
        case "$arg" in
            --silent)
                SILENT_MODE="true"
                ;;
            --systemd)
                SYSTEMD_MODE="true"
                ;;
            --skip-test)
                SKIP_TEST="true"
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_warn "Unknown option: $arg"
                ;;
            *)
                # Non-flag argument is the install directory
                if [[ "$arg" != "" && "$INSTALL_DIR" == "$DEFAULT_INSTALL_DIR" ]]; then
                    INSTALL_DIR="$arg"
                fi
                ;;
        esac
    done
    
    # Also check environment variables for backward compatibility
    [[ "${TELEMON_SILENT:-}" == "true" ]] && SILENT_MODE="true"
    [[ "${TELEMON_SYSTEMD:-}" == "true" ]] && SYSTEMD_MODE="true"
}

show_help() {
    cat << EOF
Telemon Installer

Usage: bash install.sh [OPTIONS] [INSTALL_DIR]

Arguments:
  INSTALL_DIR           Target directory (default: ~/telemon)

Options:
  --silent              Non-interactive mode (uses env vars for config)
  --systemd             Use systemd timer instead of cron
  --skip-test           Skip the test notification at the end
  --help, -h            Show this help message

Environment Variables (for --silent mode):
  TELEGRAM_BOT_TOKEN    Telegram bot token (required)
  TELEGRAM_CHAT_ID      Telegram chat ID (required)
  SERVER_LABEL          Server name in alerts (default: hostname)
  ENABLE_DOCKER         Enable Docker monitoring (true/false/auto)
  ENABLE_PM2            Enable PM2 monitoring (true/false/auto)
  ENABLE_SITES          Enable site monitoring (true/false)
  SITE_URLS             Space-separated URLs to monitor
  TELEMON_SILENT        Same as --silent flag
  TELEMON_SYSTEMD       Same as --systemd flag

Examples:
  # Interactive install to default location
  bash install.sh

  # Silent install with Telegram credentials
  TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="yyy" bash install.sh --silent

  # Install with systemd timer instead of cron
  bash install.sh --systemd

  # Custom directory with silent mode
  TELEGRAM_BOT_TOKEN="xxx" TELEGRAM_CHAT_ID="yyy" bash install.sh --silent /opt/telemon

EOF
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
    command -v crontab &>/dev/null || optional+=("crontab (for cron scheduling - use --systemd if missing)")
    
    if (( ${#optional[@]} > 0 )); then
        echo ""
        echo "Optional dependencies (install if needed):"
        for note in "${optional[@]}"; do
            echo "  - $note"
        done
    fi
    
    # Warn if both cron and systemd are unavailable
    if ! command -v crontab &>/dev/null && ! command -v systemctl &>/dev/null; then
        log_warn "Neither crontab nor systemctl found - scheduling must be set up manually"
    elif ! command -v crontab &>/dev/null && [[ "$SYSTEMD_MODE" == "false" ]]; then
        log_warn "crontab not found - consider using --systemd flag for systemd timer"
    fi
}

step_2_create_directory() {
    echo ""
    log_info "Step 2/8: Creating installation directory..."
    
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ "$SILENT_MODE" == "true" ]]; then
            log_info "Directory ${INSTALL_DIR} already exists, continuing..."
        else
            log_warn "Directory ${INSTALL_DIR} already exists"
            read -rp "  Continue and update files? [Y/n] " answer
            answer="${answer:-Y}"
            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                log_info "Installation cancelled"
                exit 0
            fi
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
        if [[ "$SILENT_MODE" == "true" ]]; then
            log_info ".env already exists, merging with new values..."
            # In silent mode, we'll update specific values but keep the file
        else
            log_warn ".env already exists at ${env_file}"
            read -rp "  Keep existing configuration? [Y/n] " answer
            answer="${answer:-Y}"
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                log_success "Using existing configuration"
                return 0
            fi
        fi
    fi
    
    # Silent mode configuration
    if [[ "$SILENT_MODE" == "true" ]]; then
        step_5_configure_env_silent "$env_file" "$env_example"
    else
        step_5_configure_env_interactive "$env_file" "$env_example"
    fi
}

step_5_configure_env_silent() {
    local env_file="$1"
    local env_example="$2"
    
    # Check required environment variables
    local bot_token="${TELEGRAM_BOT_TOKEN:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"
    
    if [[ -z "$bot_token" || -z "$chat_id" ]]; then
        log_error "Silent mode requires TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID environment variables"
        log_error "Example: TELEGRAM_BOT_TOKEN='xxx' TELEGRAM_CHAT_ID='yyy' bash install.sh --silent"
        exit 1
    fi
    
    # Copy example if .env doesn't exist
    if [[ ! -f "$env_file" ]]; then
        cp "$env_example" "$env_file"
    fi
    
    # Server label
    local server_label="${SERVER_LABEL:-$(hostname)}"
    
    # Auto-detect Docker if ENABLE_DOCKER is "auto" or not set
    local enable_docker="${ENABLE_DOCKER:-auto}"
    if [[ "$enable_docker" == "auto" ]]; then
        if command -v docker &>/dev/null; then
            enable_docker="true"
            log_info "Auto-detected Docker - enabling container monitoring"
        else
            enable_docker="false"
        fi
    fi
    
    # Auto-detect PM2 if ENABLE_PM2 is "auto" or not set
    local enable_pm2="${ENABLE_PM2:-auto}"
    if [[ "$enable_pm2" == "auto" ]]; then
        if command -v pm2 &>/dev/null && command -v python3 &>/dev/null; then
            enable_pm2="true"
            log_info "Auto-detected PM2 - enabling process monitoring"
        else
            enable_pm2="false"
        fi
    fi
    
    # Site monitoring
    local enable_sites="${ENABLE_SITES:-false}"
    local site_urls="${SITE_URLS:-}"
    
    # Update configuration values using safe writer
    set_env_value "$env_file" "TELEGRAM_BOT_TOKEN" "$bot_token"
    set_env_value "$env_file" "TELEGRAM_CHAT_ID" "$chat_id"
    set_env_value "$env_file" "SERVER_LABEL" "$server_label"
    set_env_value_plain "$env_file" "ENABLE_DOCKER_CONTAINERS" "$enable_docker"
    set_env_value_plain "$env_file" "ENABLE_PM2_PROCESSES" "$enable_pm2"
    set_env_value_plain "$env_file" "ENABLE_SITE_MONITOR" "$enable_sites"
    
    # Add site URLs if provided
    if [[ -n "$site_urls" && "$enable_sites" == "true" ]]; then
        set_env_value "$env_file" "CRITICAL_SITES" "$site_urls"
    fi
    
    # Secure the .env file
    chmod 600 "$env_file"
    
    log_success "Configuration saved to ${env_file} (silent mode)"
}

step_5_configure_env_interactive() {
    local env_file="$1"
    local env_example="$2"
    
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
    
    # Update configuration values using safe writer
    set_env_value "$env_file" "TELEGRAM_BOT_TOKEN" "$bot_token"
    set_env_value "$env_file" "TELEGRAM_CHAT_ID" "$chat_id"
    set_env_value "$env_file" "SERVER_LABEL" "$server_label"
    set_env_value_plain "$env_file" "ENABLE_DOCKER_CONTAINERS" "$enable_docker"
    set_env_value_plain "$env_file" "ENABLE_PM2_PROCESSES" "$enable_pm2"
    set_env_value_plain "$env_file" "ENABLE_SITE_MONITOR" "$enable_sites"
    
    # Add site URLs if provided
    if [[ -n "$site_urls" && "$enable_sites" == "true" ]]; then
        set_env_value "$env_file" "CRITICAL_SITES" "$site_urls"
    fi
    
    # Secure the .env file
    chmod 600 "$env_file"
    
    log_success "Configuration saved to ${env_file}"
}

step_6_setup_cron() {
    echo ""
    log_info "Step 5/8: Setting up scheduler..."
    
    # Determine scheduling method
    if [[ "$SYSTEMD_MODE" == "true" ]]; then
        step_6_setup_systemd
    else
        step_6_setup_cron_legacy
    fi
}

step_6_setup_systemd() {
    log_info "Setting up systemd timer..."
    
    # Determine if we should use user or system systemd
    local use_user_systemd="true"
    if [[ "$EUID" -eq 0 ]] || [[ "$INSTALL_DIR" == /opt/* ]] || [[ "$INSTALL_DIR" == /usr/* ]]; then
        use_user_systemd="false"
    fi
    
    if [[ "$use_user_systemd" == "true" ]]; then
        # User systemd
        local user_dir="${HOME}/.config/systemd/user"
        mkdir -p "$user_dir"
        
        # Create service file
        cat > "${user_dir}/telemon.service" << EOF
[Unit]
Description=Telemon System Health Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/telemon.sh
StandardOutput=append:${INSTALL_DIR}/telemon_cron.log
StandardError=append:${INSTALL_DIR}/telemon_cron.log

[Install]
WantedBy=multi-user.target
EOF
        
        # Create timer file
        cat > "${user_dir}/telemon.timer" << EOF
[Unit]
Description=Run Telemon every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
        
        # Reload and enable
        systemctl --user daemon-reload
        systemctl --user enable telemon.timer
        systemctl --user start telemon.timer
        
        log_success "User systemd timer installed and started"
        echo "  Check status: systemctl --user status telemon.timer"
        echo "  View logs: journalctl --user -u telemon"
    else
        # System systemd (requires root)
        if [[ "$EUID" -ne 0 ]]; then
            log_warn "System-wide systemd install requires root - skipping timer setup"
            echo "  To set up manually, run as root or use --systemd with user install"
            return 0
        fi
        
        # Create system service
        cat > /etc/systemd/system/telemon.service << EOF
[Unit]
Description=Telemon System Health Monitor
After=network.target

[Service]
Type=oneshot
User=$(id -un)
ExecStart=${INSTALL_DIR}/telemon.sh
StandardOutput=append:${INSTALL_DIR}/telemon_cron.log
StandardError=append:${INSTALL_DIR}/telemon_cron.log

[Install]
WantedBy=multi-user.target
EOF
        
        # Create timer file
        cat > /etc/systemd/system/telemon.timer << EOF
[Unit]
Description=Run Telemon every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
        
        # Reload and enable
        systemctl daemon-reload
        systemctl enable telemon.timer
        systemctl start telemon.timer
        
        log_success "System systemd timer installed and started"
        echo "  Check status: systemctl status telemon.timer"
        echo "  View logs: journalctl -u telemon"
    fi
}

step_6_setup_cron_legacy() {
    log_info "Setting up cron job..."
    
    local monitor_script="${INSTALL_DIR}/telemon.sh"
    local cron_line="${CRON_SCHEDULE} cd ${INSTALL_DIR} && bash ${monitor_script} >> ${INSTALL_DIR}/telemon_cron.log 2>&1"
    
    # Check if crontab is available
    if ! command -v crontab &>/dev/null; then
        log_warn "crontab not found - skipping cron setup"
        echo "  Consider using --systemd flag for systemd timer instead"
        return 0
    fi
    
    # Check if cron line already exists
    if crontab -l 2>/dev/null | grep -qF "$monitor_script"; then
        log_warn "Cron job already exists"
        if [[ "$SILENT_MODE" != "true" ]]; then
            read -rp "  Reinstall cron job? [y/N] " answer
            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                log_info "Keeping existing cron job"
                return 0
            fi
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
    
    if [[ "$SKIP_TEST" == "true" || "$SILENT_MODE" == "true" ]]; then
        log_info "Step 8/8: Skipping test notification (--skip-test or --silent)"
        return 0
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
    
    if [[ "$SYSTEMD_MODE" == "true" ]]; then
        echo "Schedule:               Systemd timer (every 5 minutes)"
        if [[ "$EUID" -ne 0 ]] && [[ "$INSTALL_DIR" != /opt/* ]] && [[ "$INSTALL_DIR" != /usr/* ]]; then
            echo "Timer status:           systemctl --user status telemon.timer"
        else
            echo "Timer status:           systemctl status telemon.timer"
        fi
    else
        echo "Schedule:               Cron (every 5 minutes)"
    fi
    
    echo ""
    echo "Quick Commands:"
    echo "  Run manually:         bash ${INSTALL_DIR}/telemon.sh"
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
    # Parse command line arguments first
    parse_arguments "$@"
    
    echo "=============================================="
    echo "  Telemon - One-Line Installer"
    echo "=============================================="
    
    if [[ "$SILENT_MODE" == "true" ]]; then
        log_info "Running in SILENT mode (no interactive prompts)"
    fi
    
    if [[ "$SYSTEMD_MODE" == "true" ]]; then
        log_info "Using SYSTEMD timer instead of cron"
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
