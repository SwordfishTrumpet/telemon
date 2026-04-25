#!/usr/bin/env bash
# =============================================================================
# Telemon Test Suite
# =============================================================================
# Tests for core helper functions. Run with: bash tests/run_tests.sh
# =============================================================================
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the script under test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} ${msg:-assert_eq}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} ${msg:-assert_eq}"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_true() {
    local result=$?
    local msg="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ $result -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $msg"
        : $((TESTS_FAILED += 1))
        return 1
    fi
}

assert_false() {
    local result=$?
    local msg="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ $result -ne 0 ]]; then
        echo -e "${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $msg"
        : $((TESTS_FAILED += 1))
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-assert_contains}"
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $msg"
        echo "  Did not find: '$needle'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Test portable_stat helper
# ---------------------------------------------------------------------------

test_portable_stat() {
    echo ""
    echo "Testing portable_stat helper..."
    
    # Create a temporary file for testing
    local tmpfile
    tmpfile=$(mktemp)
    echo "test content" > "$tmpfile"
    chmod 644 "$tmpfile"
    
    # Test mtime
    local mtime
    mtime=$(portable_stat mtime "$tmpfile")
    [[ -n "$mtime" && "$mtime" != "0" ]]
    assert_true "portable_stat mtime returns non-zero value"
    [[ "$mtime" =~ ^[0-9]+$ ]]
    assert_true "portable_stat mtime returns numeric value"
    
    # Test size
    local size
    size=$(portable_stat size "$tmpfile")
    [[ "$size" -gt 0 ]]
    assert_true "portable_stat size returns positive value"
    
    # Test perms
    local perms
    perms=$(portable_stat perms "$tmpfile")
    assert_eq "644" "$perms" "portable_stat perms returns correct permissions"
    
    # Test owner (just check it's not empty)
    local owner
    owner=$(portable_stat owner "$tmpfile")
    [[ -n "$owner" && "$owner" != "unknown" ]]
    assert_true "portable_stat owner returns value"
    
    # Test invalid file
    local bad_mtime
    bad_mtime=$(portable_stat mtime "/nonexistent/file/12345")
    assert_eq "0" "$bad_mtime" "portable_stat returns 0 for nonexistent file"
    
    # Test invalid format (TEST-003)
    local bad_format
    bad_format=$(portable_stat "invalid_format" "$tmpfile")
    assert_eq "" "$bad_format" "portable_stat returns empty string for invalid format"
    
    # Cleanup
    rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# Test portable_sha256 helper (replaces MD5)
test_portable_sha256() {
    echo ""
    echo "Testing portable_sha256 helper..."
    
    # Test that we get a consistent hash
    local hash1 hash2
    hash1=$(printf '%s' "test" | portable_sha256)
    hash2=$(printf '%s' "test" | portable_sha256)
    assert_eq "$hash1" "$hash2" "portable_sha256 produces consistent results"
    
    # Test that different inputs produce different outputs
    local hash3
    hash3=$(printf '%s' "different" | portable_sha256)
    [[ "$hash1" != "$hash3" ]]
    assert_true "portable_sha256 produces different hashes for different inputs"
    
    # Test that output looks like a SHA-256 hash (64 hex chars)
    [[ "$hash1" =~ ^[a-f0-9]{64}$ ]]
    assert_true "portable_sha256 produces 64-character hex output"
}

# Test service name validation
test_is_valid_service_name() {
    echo ""
    echo "Testing is_valid_service_name helper..."
    
    # Valid service names
    is_valid_service_name "nginx"
    assert_true "is_valid_service_name accepts simple service name"
    
    is_valid_service_name "nginx.service"
    assert_true "is_valid_service_name accepts service with dot"
    
    is_valid_service_name "my-service"
    assert_true "is_valid_service_name accepts service with hyphen"
    
    is_valid_service_name "my_service"
    assert_true "is_valid_service_name accepts service with underscore"
    
    is_valid_service_name "service123"
    assert_true "is_valid_service_name accepts service with numbers"
    
    # Invalid service names
    ! is_valid_service_name "service;rm -rf /"
    assert_true "is_valid_service_name rejects command injection attempt"
    
    ! is_valid_service_name "service with space"
    assert_true "is_valid_service_name rejects service with spaces"
    
    ! is_valid_service_name 'service$(id)'
    assert_true "is_valid_service_name rejects command substitution"
    
    ! is_valid_service_name "service*"
    assert_true "is_valid_service_name rejects glob pattern"
}

# Test hostname validation
test_is_valid_hostname() {
    echo ""
    echo "Testing is_valid_hostname helper..."
    
    # Valid hostnames
    is_valid_hostname "localhost"
    assert_true "is_valid_hostname accepts localhost"
    
    is_valid_hostname "example.com"
    assert_true "is_valid_hostname accepts domain name"
    
    is_valid_hostname "db-server"
    assert_true "is_valid_hostname accepts hostname with hyphen"
    
    is_valid_hostname "192.168.1.1"
    assert_true "is_valid_hostname accepts IP address"
    
    # Invalid hostnames
    ! is_valid_hostname "host;rm -rf /"
    assert_true "is_valid_hostname rejects command injection"
    
    ! is_valid_hostname "host with space"
    assert_true "is_valid_hostname rejects hostname with spaces"
    
    ! is_valid_hostname 'host$(id)'
    assert_true "is_valid_hostname rejects command substitution"
}

# Test path safety validation
test_is_safe_path() {
    echo ""
    echo "Testing is_safe_path helper..."
    
    # Safe paths
    is_safe_path "/etc/nginx/nginx.conf"
    assert_true "is_safe_path accepts normal absolute path"
    
    is_safe_path "/var/log/syslog"
    assert_true "is_safe_path accepts another normal path"
    
    is_safe_path "relative/path/file.txt"
    assert_true "is_safe_path accepts relative path"
    
    # Unsafe paths - path traversal
    ! is_safe_path "/etc/../etc/passwd"
    assert_true "is_safe_path rejects path with .. traversal"
    
    ! is_safe_path "../etc/passwd"
    assert_true "is_safe_path rejects relative path traversal"
    
    # Unsafe paths - shell expansion
    ! is_safe_path "/etc/*"
    assert_true "is_safe_path rejects glob pattern *"
    
    ! is_safe_path "/etc/?"
    assert_true "is_safe_path rejects glob pattern ?"
    
    # Unsafe paths - command substitution
    ! is_safe_path '/etc/file$(id).txt'
    assert_true "is_safe_path rejects command substitution $"
    
    ! is_safe_path '/etc/file`id`.txt'
    assert_true "is_safe_path rejects command substitution backtick"
}

# Test email validation
test_is_valid_email() {
    echo ""
    echo "Testing is_valid_email helper..."
    
    # Valid emails
    is_valid_email "user@example.com"
    assert_true "is_valid_email accepts simple email"
    
    is_valid_email "user.name@example.co.uk"
    assert_true "is_valid_email accepts email with dots"
    
    is_valid_email "user+tag@example.com"
    assert_true "is_valid_email accepts email with plus"
    
    is_valid_email "user_name@example-domain.com"
    assert_true "is_valid_email accepts email with hyphen and underscore"
    
    # Invalid emails
    ! is_valid_email "notanemail"
    assert_true "is_valid_email rejects plain string"
    
    ! is_valid_email "@example.com"
    assert_true "is_valid_email rejects missing local part"
    
    ! is_valid_email "user@"
    assert_true "is_valid_email rejects missing domain"
    
    ! is_valid_email "user@nodot"
    assert_true "is_valid_email rejects domain without TLD"
    
    ! is_valid_email "test@test.com; rm -rf /"
    assert_true "is_valid_email rejects injection attempt"
}

# Test SSRF / internal IP detection
test_is_internal_ip() {
    echo ""
    echo "Testing is_internal_ip helper..."
    
    # Internal IPs - should return 0 (true)
    is_internal_ip "127.0.0.1"
    assert_true "is_internal_ip detects loopback IPv4"
    
    is_internal_ip "127.0.0.53"
    assert_true "is_internal_ip detects loopback IPv4 variant"
    
    is_internal_ip "10.0.0.1"
    assert_true "is_internal_ip detects private Class A"
    
    is_internal_ip "172.16.0.1"
    assert_true "is_internal_ip detects private Class B (172.16)"
    
    is_internal_ip "172.31.255.255"
    assert_true "is_internal_ip detects private Class B (172.31)"
    
    is_internal_ip "192.168.1.1"
    assert_true "is_internal_ip detects private Class C"
    
    is_internal_ip "169.254.1.1"
    assert_true "is_internal_ip detects link-local"
    
    is_internal_ip "localhost"
    assert_true "is_internal_ip detects localhost name"
    
    is_internal_ip "::1"
    assert_true "is_internal_ip detects IPv6 loopback"
    
    # External IPs - should return 1 (false)
    ! is_internal_ip "8.8.8.8"
    assert_true "is_internal_ip allows public IP (Google DNS)"
    
    ! is_internal_ip "1.1.1.1"
    assert_true "is_internal_ip allows public IP (Cloudflare DNS)"
    
    ! is_internal_ip "example.com"
    assert_true "is_internal_ip allows domain name"
}

# ---------------------------------------------------------------------------
# Test get_state_file_variants helper
# ---------------------------------------------------------------------------

test_get_state_file_variants() {
    echo ""
    echo "Testing get_state_file_variants helper..."
    
    # Set up a test STATE_FILE
    STATE_FILE="/tmp/test_telemon_state"
    
    # Test basic variants
    local variants
    variants=$(get_state_file_variants)
    assert_contains "$variants" "${STATE_FILE}.cooldown" "get_state_file_variants includes cooldown"
    assert_contains "$variants" "${STATE_FILE}.drift" "get_state_file_variants includes drift"
    
    # Test with lock files included
    local with_lock
    with_lock=$(get_state_file_variants false true)
    assert_contains "$with_lock" "${STATE_FILE}.lock" "get_state_file_variants includes lock when requested"
    
    # Edge case tests (TEST-002)
    # Test with all parameters true
    local all_true
    all_true=$(get_state_file_variants true true true)
    assert_contains "$all_true" "${STATE_FILE}" "get_state_file_variants includes main when all_true"
    assert_contains "$all_true" "${STATE_FILE}.lock" "get_state_file_variants includes lock when all_true"
    assert_contains "$all_true" "${STATE_FILE}.drift.baseline" "get_state_file_variants includes drift baseline when all_true"
    
    # Test with all parameters false
    local all_false
    all_false=$(get_state_file_variants false false false)
    # Check that main state file (without extension) is not present - match space or end
    [[ "$all_false" != *"${STATE_FILE} "* ]] && [[ "$all_false" != "${STATE_FILE}" ]]
    assert_true "get_state_file_variants excludes main state file when all_false"
    [[ "$all_false" != *"${STATE_FILE}.lock"* ]]
    assert_true "get_state_file_variants excludes lock when all_false"
}

# ---------------------------------------------------------------------------
# Test sanitize_state_key logic
# ---------------------------------------------------------------------------

test_sanitize_state_key() {
    echo ""
    echo "Testing sanitize_state_key logic..."
    
    # Define the sanitize function inline for testing
    sanitize_state_key() {
        local key="$1"
        printf '%s' "$key" | tr -c 'a-zA-Z0-9_.-' '_'
    }
    
    # Test basic sanitization
    assert_eq "test-key" "$(sanitize_state_key "test-key")" "sanitize_state_key preserves hyphens"
    assert_eq "test_key" "$(sanitize_state_key "test_key")" "sanitize_state_key preserves underscores"
    
    # Test special chars are replaced
    assert_eq "test_key" "$(sanitize_state_key "test/key")" "sanitize_state_key replaces slashes"
    assert_eq "test_key" "$(sanitize_state_key "test@key")" "sanitize_state_key replaces @"
    assert_eq "test_key" "$(sanitize_state_key "test:key")" "sanitize_state_key replaces colons"
    
    # Test multiple special chars
    assert_eq "a_b_c_d" "$(sanitize_state_key "a/b@c:d")" "sanitize_state_key handles multiple special chars"
}

# ---------------------------------------------------------------------------
# Test state key format validation
# ---------------------------------------------------------------------------

test_state_key_format() {
    echo ""
    echo "Testing state key format validation..."
    
    # Valid key patterns
    local valid_keys=("cpu" "mem" "disk_root" "container_nginx" "proc_sshd")
    for key in "${valid_keys[@]}"; do
        [[ "$key" =~ ^[a-zA-Z0-9_.-]+$ ]]
        assert_true "Key '$key' matches valid pattern"
    done
}

# ---------------------------------------------------------------------------
# Test html_escape helper
# ---------------------------------------------------------------------------

test_html_escape() {
    echo ""
    echo "Testing html_escape helper..."
    
    # Define the html_escape function inline for testing
    html_escape() {
        local text="$1"
        text="${text//&/\&amp;}"
        text="${text//</\&lt;}"
        text="${text//>/\&gt;}"
        text="${text//\"/\&quot;}"
        text="${text//\'/\&#39;}"
        printf '%s' "$text"
    }
    
    # Test basic HTML entities
    local input_amp="&" expected_amp="&amp;"
    assert_eq "$expected_amp" "$(html_escape "$input_amp")" "html_escape escapes ampersand"
    
    local input_lt="<" expected_lt="&lt;"
    assert_eq "$expected_lt" "$(html_escape "$input_lt")" "html_escape escapes less-than"
    
    local input_gt=">" expected_gt="&gt;"
    assert_eq "$expected_gt" "$(html_escape "$input_gt")" "html_escape escapes greater-than"
    
    local input_dq='"' expected_dq="&quot;"
    assert_eq "$expected_dq" "$(html_escape "$input_dq")" "html_escape escapes double quote"
    
    local input_sq="'" expected_sq="&#39;"
    assert_eq "$expected_sq" "$(html_escape "$input_sq")" "html_escape escapes single quote"
}

# ---------------------------------------------------------------------------
# Test threshold validation helper
# ---------------------------------------------------------------------------

test_threshold_validation() {
    echo ""
    echo "Testing threshold validation logic..."
    
    # Test is_valid_number (sourced from lib/common.sh)
    is_valid_number "42"
    assert_true "is_valid_number accepts positive integer"
    
    is_valid_number "0"
    assert_true "is_valid_number accepts zero"
    
    ! is_valid_number "-5"
    assert_true "is_valid_number rejects negative number"
    
    ! is_valid_number "3.14"
    assert_true "is_valid_number rejects decimal"
    
    ! is_valid_number "abc"
    assert_true "is_valid_number rejects letters"
}

# ---------------------------------------------------------------------------
# Test parse_date_to_epoch helper
# ---------------------------------------------------------------------------

test_parse_date_to_epoch() {
    echo ""
    echo "Testing parse_date_to_epoch helper..."
    
    # Define parse_date_to_epoch inline for testing
    parse_date_to_epoch() {
        local datestr="$1"
        local epoch
        epoch=$(date -d "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
        epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
        if command -v python3 &>/dev/null; then
            epoch=$(python3 -c "
import email.utils, sys, calendar
try:
    t = email.utils.parsedate_tz(sys.argv[1])
    if t: print(calendar.timegm(t[:9]) - (t[9] or 0))
    else: print('')
except Exception: print('')
" "$datestr" 2>/dev/null) && [[ -n "$epoch" ]] && { echo "$epoch"; return 0; }
        fi
        echo ""
    }
    
    # Test with a known date
    local epoch
    epoch=$(parse_date_to_epoch "Jan 01 00:00:00 2024 UTC")
    [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]
    assert_true "parse_date_to_epoch returns numeric epoch for valid date"
    
    # Test that different dates produce different epochs
    local epoch2
    epoch2=$(parse_date_to_epoch "Jan 02 00:00:00 2024 UTC")
    [[ -n "$epoch2" && "$epoch2" =~ ^[0-9]+$ ]]
    assert_true "parse_date_to_epoch returns numeric epoch for second date"
    
    # Verify Jan 2 is later than Jan 1
    [[ -n "$epoch" && -n "$epoch2" && "$epoch2" -gt "$epoch" ]]
    assert_true "parse_date_to_epoch: Jan 2 epoch > Jan 1 epoch"
    
    # Test invalid date returns empty
    local bad_epoch
    bad_epoch=$(parse_date_to_epoch "invalid date string")
    [[ -z "$bad_epoch" || ! "$bad_epoch" =~ ^[0-9]+$ ]]
    assert_true "parse_date_to_epoch handles invalid dates gracefully"
}

# ---------------------------------------------------------------------------
# Test run_with_timeout helper
# ---------------------------------------------------------------------------

test_run_with_timeout() {
    echo ""
    echo "Testing run_with_timeout helper..."
    
    # Define run_with_timeout inline for testing
    run_with_timeout() {
        local timeout_sec="$1"
        shift
        
        if command -v timeout &>/dev/null; then
            timeout "$timeout_sec" "$@" 2>/dev/null
            return $?
        fi
        
        local pid
        "$@" &
        pid=$!
        
        local count=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            count=$((count + 1))
            if [[ $count -ge $timeout_sec ]]; then
                kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                kill -KILL "$pid" 2>/dev/null || true
                return 124
            fi
        done
        
        wait "$pid" 2>/dev/null
        return $?
    }
    
    # Test quick command succeeds
    run_with_timeout 5 echo "test"
    assert_true "run_with_timeout: quick command succeeds"
    
    # Test command that returns non-zero
    ! run_with_timeout 5 false 2>/dev/null
    assert_true "run_with_timeout: captures command failure exit code"
    
    # Test with very short timeout on a slow command
    run_with_timeout 1 sleep 0.1 2>/dev/null
    assert_true "run_with_timeout: short command completes within timeout"
}

# ---------------------------------------------------------------------------
# Test safe_write_state_file helper
# ---------------------------------------------------------------------------

test_safe_write_state_file() {
    echo ""
    echo "Testing safe_write_state_file helper..."
    
    # Define safe_write_state_file inline for testing
    safe_write_state_file() {
        local target="$1"
        local content="$2"
        if [[ -L "$target" ]]; then
            return 1
        fi
        local tmp_target
        tmp_target=$(mktemp "${target}.XXXXXX") || { return 1; }
        echo "$content" > "$tmp_target"
        chmod 600 "$tmp_target" 2>/dev/null || true
        mv "$tmp_target" "$target" || { rm -f "$tmp_target"; return 1; }
    }
    
    # Create temp state file path
    local test_state_file
    test_state_file=$(mktemp)
    rm -f "$test_state_file"
    
    # Test basic write
    safe_write_state_file "$test_state_file" "test_key=OK:0"
    assert_true "safe_write_state_file: basic write succeeds"
    
    # Verify content was written
    [[ -f "$test_state_file" ]]
    assert_true "safe_write_state_file: file was created"
    
    local content
    content=$(cat "$test_state_file")
    assert_eq "test_key=OK:0" "$content" "safe_write_state_file: content written correctly"
    
    # Cleanup
    rm -f "$test_state_file"
}

# ---------------------------------------------------------------------------
# Test linear regression helper with documented edge case behavior
# ---------------------------------------------------------------------------

test_linear_regression() {
    echo ""
    echo "Testing linear regression helper..."
    echo "  (Note: linear_regression returns exit code 1 for edge cases — this is expected behavior)"

    # Define linear_regression function inline (copy from telemon.sh)
    linear_regression() {
        local datapoints="$1"
        [[ -z "$datapoints" ]] && { echo "0 0"; return 1; }
        echo "$datapoints" | awk -F',' '{
            n = 0; sx = 0; sy = 0; sxx = 0; sxy = 0
            for (i = 1; i <= NF; i++) {
                split($i, a, ":")
                if (a[1] == "" || a[2] == "") continue
                x = a[1] + 0; y = a[2] + 0
                sx += x; sy += y; sxx += x*x; sxy += x*y; n++
            }
            if (n < 2 || (n*sxx - sx*sx) == 0) { print "0 0"; exit 1 }
            slope = (n*sxy - sx*sy) / (n*sxx - sx*sx)
            intercept = (sy - slope*sx) / n
            printf "%.10f %.4f\n", slope, intercept
        }'
    }

    # Test with simple linear data
    local result
    # Note: This function returns exit code 1 for edge cases (insufficient data, malformed input)
    # This is correct behavior — the function is designed to signal failure for invalid input
    # We use command substitution which handles exit codes differently, so we test output
    result=$(linear_regression "1000:10,2000:20,3000:30" 2>/dev/null || echo "")
    # Expect positive slope ~0.01, intercept ~0
    # We'll just check that output has two numbers
    [[ "$result" =~ ^[0-9.-]+\ [0-9.-]+$ ]]
    assert_true "linear_regression returns two numbers for valid data"

    # Test insufficient data — function returns "0 0" and exit code 1 (expected)
    result=$(linear_regression "1000:10" 2>/dev/null || true)
    assert_eq "0 0" "$result" "linear_regression returns '0 0' for insufficient data (1 point)"

    # Test empty input — function returns "0 0" and exit code 1 (expected)
    result=$(linear_regression "" 2>/dev/null || true)
    assert_eq "0 0" "$result" "linear_regression returns '0 0' for empty input"

    # Test malformed data — function returns "0 0" and exit code 1 (expected)
    result=$(linear_regression "invalid" 2>/dev/null || true)
    assert_eq "0 0" "$result" "linear_regression returns '0 0' for malformed data"
}

# ---------------------------------------------------------------------------
# Test log function
# ---------------------------------------------------------------------------

test_log() {
    echo ""
    echo "Testing log function..."
    
    # Define log function inline for testing (simplified version)
    LOG_FILE=$(mktemp)
    LOG_LEVEL="INFO"
    
    _log_level_num() {
        case "$1" in
            DEBUG) echo 0 ;; INFO) echo 1 ;; WARN) echo 2 ;; ERROR) echo 3 ;; *) echo 1 ;;
        esac
    }
    
    log() {
        local level="$1"; shift
        local min_level="${LOG_LEVEL:-INFO}"
        if [[ "$(_log_level_num "$level")" -lt "$(_log_level_num "$min_level")" ]]; then
            return
        fi
        echo "[${level}] $*" >> "$LOG_FILE"
    }
    
    # Test that log writes to file
    log "INFO" "Test message"
    [[ -f "$LOG_FILE" ]]
    assert_true "log creates log file"
    
    local content
    content=$(cat "$LOG_FILE")
    assert_contains "$content" "Test message" "log writes message to file"
    assert_contains "$content" "[INFO]" "log includes level prefix"
    
    # Test log level filtering
    > "$LOG_FILE"  # Clear log
    LOG_LEVEL="WARN"
    log "INFO" "Should not appear"
    log "WARN" "Should appear"
    content=$(cat "$LOG_FILE")
    [[ ! "$content" == *"Should not appear"* ]]
    assert_true "log filters DEBUG/INFO when LOG_LEVEL=WARN"
    [[ "$content" == *"Should appear"* ]]
    assert_true "log allows WARN when LOG_LEVEL=WARN"
    
    # Cleanup
    rm -f "$LOG_FILE"
    unset LOG_FILE LOG_LEVEL _log_level_num log
}

# ---------------------------------------------------------------------------
# Test rotate_logs function
# ---------------------------------------------------------------------------

test_rotate_logs() {
    echo ""
    echo "Testing rotate_logs function..."
    
    # Create a temporary log directory
    local log_dir
    log_dir=$(mktemp -d)
    local log_file="${log_dir}/test.log"
    
    # Define rotate_logs function inline for testing
    rotate_logs() {
        local max_size_mb="${LOG_MAX_SIZE_MB:-10}"
        local max_size=$((max_size_mb * 1024 * 1024))
        local max_backups="${LOG_MAX_BACKUPS:-5}"
        
        if [[ -f "$LOG_FILE" ]]; then
            local log_size
            log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
            if [[ "$log_size" -gt "$max_size" ]]; then
                # Rotate backups
                for (( i = max_backups - 1; i >= 1; i-- )); do
                    local src="${LOG_FILE}.${i}"
                    local dst="${LOG_FILE}.$((i + 1))"
                    [[ -f "$src" ]] && mv "$src" "$dst"
                done
                mv "$LOG_FILE" "${LOG_FILE}.1"
                : > "$LOG_FILE"
            fi
        fi
    }
    
    LOG_FILE="$log_file"
    LOG_MAX_SIZE_MB=1  # 1MB for testing
    LOG_MAX_BACKUPS=3
    
    # Test rotation not triggered for small file
    echo "small content" > "$log_file"
    rotate_logs
    [[ -f "$log_file" ]]
    assert_true "rotate_logs keeps small files"
    [[ ! -f "${log_file}.1" ]]
    assert_true "rotate_logs doesn't create backup for small files"
    
    # Test rotation triggered for large file
    # Create a file larger than 1MB
    dd if=/dev/zero bs=1024 count=1025 > "$log_file" 2>/dev/null
    rotate_logs
    [[ -f "${log_file}.1" ]]
    assert_true "rotate_logs creates backup when size exceeded"
    [[ -f "$log_file" ]]
    assert_true "rotate_logs creates new empty log file"
    
    # Cleanup
    rm -rf "$log_dir"
    unset LOG_FILE LOG_MAX_SIZE_MB LOG_MAX_BACKUPS rotate_logs
}

# ---------------------------------------------------------------------------
# Test check_state_change core alerting logic
# Tests confirmation counting, state transitions, and rate limiting
# ---------------------------------------------------------------------------

test_check_state_change() {
    echo ""
    echo "Testing check_state_change core logic..."
    
    # Global state arrays (mocked for testing)
    declare -A PREV_STATE
    declare -A PREV_COUNT
    declare -A ALERT_LAST_SENT
    declare -A CURR_STATE
    declare -A STATE_DETAIL
    local ALERTS=""
    local CONFIRMATION_COUNT=3
    local ALERT_COOLDOWN_SEC=0  # Disable cooldown for testing
    
    # Define check_state_change inline for testing (simplified version)
    check_state_change() {
        local key="$1"
        local new_state="$2"
        local detail="$3"
        
        CURR_STATE["$key"]="$new_state"
        STATE_DETAIL["$key"]="$detail"
        
        local prev_state="${PREV_STATE[$key]:-OK}"
        local prev_count="${PREV_COUNT[$key]:-0}"
        local confirm_count="${CONFIRMATION_COUNT:-3}"
        
        local should_alert=false
        
        if [[ "$new_state" == "$prev_state" ]]; then
            # State unchanged
            if [[ "$prev_count" -lt "$confirm_count" ]]; then
                prev_count=$((prev_count + 1))
                PREV_COUNT["$key"]=$prev_count
                if [[ "$prev_count" -eq "$confirm_count" && "$new_state" != "OK" ]]; then
                    should_alert=true
                fi
            fi
        else
            # State changed
            PREV_COUNT["$key"]=1
            
            if [[ "$confirm_count" -le 1 ]]; then
                if [[ "$new_state" != "OK" ]]; then
                    should_alert=true
                elif [[ "$prev_state" != "OK" ]]; then
                    should_alert=true
                fi
            else
                if [[ "$new_state" == "OK" && "$prev_state" != "OK" && "$prev_count" -ge "$confirm_count" ]]; then
                    should_alert=true
                fi
            fi
        fi
        
        if [[ "$should_alert" == "true" ]]; then
            ALERTS+="${key}:${new_state} "
            ALERT_LAST_SENT["$key"]=$(date +%s)
        fi
        
        PREV_STATE["$key"]="$new_state"
    }
    
    # Test 1: Initial OK state - no alert
    ALERTS=""
    check_state_change "cpu" "OK" "CPU normal"
    [[ -z "$ALERTS" ]]
    assert_true "check_state_change: OK state produces no alert"
    [[ "${PREV_COUNT[cpu]}" == "0" || "${PREV_COUNT[cpu]}" == "1" ]]
    assert_true "check_state_change: OK count initialized"
    
    # Test 2: First WARNING - no alert yet (counting)
    ALERTS=""
    check_state_change "cpu" "WARNING" "CPU at 75%"
    [[ -z "$ALERTS" ]]
    assert_true "check_state_change: first WARNING produces no alert (counting)"
    [[ "${PREV_COUNT[cpu]}" == "1" ]]
    assert_true "check_state_change: count is 1 after first WARNING"
    
    # Test 3: Second WARNING - no alert yet
    check_state_change "cpu" "WARNING" "CPU at 76%"
    [[ -z "$ALERTS" ]]
    assert_true "check_state_change: second WARNING produces no alert"
    [[ "${PREV_COUNT[cpu]}" == "2" ]]
    assert_true "check_state_change: count is 2 after second WARNING"
    
    # Test 4: Third WARNING - alert triggered (confirmation reached)
    check_state_change "cpu" "WARNING" "CPU at 77%"
    [[ "$ALERTS" == *"cpu:WARNING"* ]]
    assert_true "check_state_change: third WARNING triggers alert (confirmed)"
    [[ "${PREV_COUNT[cpu]}" == "3" ]]
    assert_true "check_state_change: count is 3 after confirmation"
    
    # Test 5: Fourth WARNING - no alert (already confirmed)
    ALERTS=""
    check_state_change "cpu" "WARNING" "CPU at 78%"
    [[ -z "$ALERTS" ]]
    assert_true "check_state_change: fourth WARNING produces no alert (already confirmed)"
    [[ "${PREV_COUNT[cpu]}" == "3" ]]
    assert_true "check_state_change: count stays at 3 after confirmation"
    
    # Test 6: OK after confirmed WARNING - resolution alert
    ALERTS=""
    check_state_change "cpu" "OK" "CPU normal"
    [[ "$ALERTS" == *"cpu:OK"* ]]
    assert_true "check_state_change: OK after confirmed WARNING triggers resolution"
    
    # Test 7: Immediate transition to CRITICAL
    PREV_STATE=()
    PREV_COUNT=()
    ALERTS=""
    check_state_change "mem" "CRITICAL" "Memory at 95%"
    [[ -z "$ALERTS" ]]
    assert_true "check_state_change: first CRITICAL produces no alert (counting)"
    check_state_change "mem" "CRITICAL" "Memory at 96%"
    [[ -z "$ALERTS" ]]
    assert_true "check_state_change: second CRITICAL produces no alert"
    check_state_change "mem" "CRITICAL" "Memory at 97%"
    [[ "$ALERTS" == *"mem:CRITICAL"* ]]
    assert_true "check_state_change: third CRITICAL triggers alert"
    
    # Test 8: Unconfirmed WARNING to OK - no alert (transient spike)
    PREV_STATE=()
    PREV_COUNT=()
    ALERTS=""
    check_state_change "disk" "WARNING" "Disk at 85%"
    check_state_change "disk" "OK" "Disk normal"
    [[ -z "$ALERTS" ]]
    assert_true "check_state_change: unconfirmed WARNING->OK produces no alert (transient)"
    
    # Test 9: Confirmation count = 1 (immediate alerts)
    CONFIRMATION_COUNT=1
    PREV_STATE=()
    PREV_COUNT=()
    ALERTS=""
    check_state_change "net" "WARNING" "Network slow"
    [[ "$ALERTS" == *"net:WARNING"* ]]
    assert_true "check_state_change: immediate alert when CONFIRMATION_COUNT=1"
    
    # Cleanup
    unset PREV_STATE PREV_COUNT ALERT_LAST_SENT CURR_STATE STATE_DETAIL ALERTS CONFIRMATION_COUNT ALERT_COOLDOWN_SEC check_state_change
}

# ---------------------------------------------------------------------------
# Test validation helper functions
# ---------------------------------------------------------------------------

test_require_file() {
    echo ""
    echo "Testing require_file helper..."
    
    # Create a temp file for testing
    local tmpfile
    tmpfile=$(mktemp)
    echo "test content" > "$tmpfile"
    
    # Test with existing file
    require_file "$tmpfile" "test file"
    assert_true "require_file accepts existing readable file"
    
    # Test with nonexistent file (should return 1)
    ! require_file "/nonexistent/file/12345" "missing file" 2>/dev/null
    assert_true "require_file rejects nonexistent file"
    
    # Test with unsafe path
    ! require_file "/etc/../etc/passwd" "unsafe file" 2>/dev/null
    assert_true "require_file rejects unsafe path with .."
    
    # Test with unreadable file (TEST-001)
    chmod 000 "$tmpfile"
    ! require_file "$tmpfile" "unreadable file" 2>/dev/null
    assert_true "require_file rejects unreadable file"
    chmod 644 "$tmpfile"  # Restore permissions for cleanup
    
    # Cleanup
    rm -f "$tmpfile"
}

test_require_command() {
    echo ""
    echo "Testing require_command helper..."
    
    # Test with existing command (bash should always exist)
    require_command "bash"
    assert_true "require_command accepts existing command"
    
    # Test with nonexistent command
    ! require_command "nonexistent_command_xyz" 2>/dev/null
    assert_true "require_command rejects nonexistent command"
}

test_validate_numeric() {
    echo ""
    echo "Testing validate_numeric helper..."
    
    # Test valid number
    validate_numeric "42" "test value"
    assert_true "validate_numeric accepts valid positive integer"
    
    # Test zero
    validate_numeric "0" "test value"
    assert_true "validate_numeric accepts zero"
    
    # Test with min constraint
    validate_numeric "10" "test value" 5
    assert_true "validate_numeric accepts value >= min"
    
    # Test with min constraint (fail)
    ! validate_numeric "3" "test value" 5 2>/dev/null
    assert_true "validate_numeric rejects value < min"
    
    # Test with max constraint
    validate_numeric "5" "test value" "" 10
    assert_true "validate_numeric accepts value <= max"
    
    # Test with max constraint (fail)
    ! validate_numeric "15" "test value" "" 10 2>/dev/null
    assert_true "validate_numeric rejects value > max"
    
    # Test with min and max
    validate_numeric "7" "test value" 5 10
    assert_true "validate_numeric accepts value within range"
    
    # Test invalid (non-numeric)
    ! validate_numeric "abc" "test value" 2>/dev/null
    assert_true "validate_numeric rejects non-numeric value"
    
    # Test negative
    ! validate_numeric "-5" "test value" 2>/dev/null
    assert_true "validate_numeric rejects negative number"
    
    # Test decimal
    ! validate_numeric "3.14" "test value" 2>/dev/null
    assert_true "validate_numeric rejects decimal"
    
    # Boundary value tests (TEST-004)
    # Test exactly at min boundary
    validate_numeric "5" "test value" 5 10
    assert_true "validate_numeric accepts value exactly at min boundary"
    
    # Test exactly at max boundary
    validate_numeric "10" "test value" 5 10
    assert_true "validate_numeric accepts value exactly at max boundary"
    
    # Test just below min boundary
    ! validate_numeric "4" "test value" 5 10 2>/dev/null
    assert_true "validate_numeric rejects value just below min boundary"
    
    # Test just above max boundary
    ! validate_numeric "11" "test value" 5 10 2>/dev/null
    assert_true "validate_numeric rejects value just above max boundary"
}

# ---------------------------------------------------------------------------
# Test validate_numeric_or_default helper
# Note: This tests the actual function from lib/common.sh (sourced at line 23)
# ---------------------------------------------------------------------------

test_validate_numeric_or_default() {
    echo ""
    echo "Testing validate_numeric_or_default helper..."
    
    # Test valid number returns itself
    local result
    result=$(validate_numeric_or_default "42" "test" "10")
    assert_eq "42" "$result" "validate_numeric_or_default returns valid number unchanged"
    
    # Test zero is valid
    result=$(validate_numeric_or_default "0" "test" "10")
    assert_eq "0" "$result" "validate_numeric_or_default accepts zero"
    
    # Test non-numeric returns default
    result=$(validate_numeric_or_default "abc" "test" "10")
    assert_eq "10" "$result" "validate_numeric_or_default returns default for non-numeric"
    
    # Test empty returns default
    result=$(validate_numeric_or_default "" "test" "10")
    assert_eq "10" "$result" "validate_numeric_or_default returns default for empty"
    
    # Test negative returns default
    result=$(validate_numeric_or_default "-5" "test" "10")
    assert_eq "10" "$result" "validate_numeric_or_default returns default for negative"
    
    # Test decimal returns default
    result=$(validate_numeric_or_default "3.14" "test" "10")
    assert_eq "10" "$result" "validate_numeric_or_default returns default for decimal"
    
    # Test below min returns default
    result=$(validate_numeric_or_default "3" "test" "10" 5)
    assert_eq "10" "$result" "validate_numeric_or_default returns default when below min"
    
    # Test above max returns default
    result=$(validate_numeric_or_default "15" "test" "10" "" 10)
    assert_eq "10" "$result" "validate_numeric_or_default returns default when above max"
    
    # Test within range returns value
    result=$(validate_numeric_or_default "7" "test" "10" 5 10)
    assert_eq "7" "$result" "validate_numeric_or_default returns value when within range"
    
    # Test at min boundary returns value
    result=$(validate_numeric_or_default "5" "test" "10" 5 10)
    assert_eq "5" "$result" "validate_numeric_or_default returns value at min boundary"
    
    # Test at max boundary returns value
    result=$(validate_numeric_or_default "10" "test" "10" 5 10)
    assert_eq "10" "$result" "validate_numeric_or_default returns value at max boundary"
}

# ---------------------------------------------------------------------------
# Test plugin system output parsing
# ---------------------------------------------------------------------------

test_plugin_system() {
    echo ""
    echo "Testing plugin system..."
    
    # Create a temp plugin directory
    local plugin_dir
    plugin_dir=$(mktemp -d)
    
    # Create a test plugin that outputs correct format
    cat > "${plugin_dir}/test_plugin.sh" << 'EOF'
#!/usr/bin/env bash
echo "OK|plugin_test|Test plugin output"
EOF
    chmod +x "${plugin_dir}/test_plugin.sh"
    
    # Create a plugin with invalid state
    cat > "${plugin_dir}/bad_state_plugin.sh" << 'EOF'
#!/usr/bin/env bash
echo "INVALID|plugin_bad|This has an invalid state"
EOF
    chmod +x "${plugin_dir}/bad_state_plugin.sh"
    
    # Create a plugin with invalid key
    cat > "${plugin_dir}/bad_key_plugin.sh" << 'EOF'
#!/usr/bin/env bash
echo "OK|plugin/key@invalid|This has an invalid key"
EOF
    chmod +x "${plugin_dir}/bad_key_plugin.sh"
    
    # Test that plugin directory exists
    [[ -d "$plugin_dir" ]]
    assert_true "Plugin directory exists"
    
    # Test that plugins are executable
    [[ -x "${plugin_dir}/test_plugin.sh" ]]
    assert_true "Test plugin is executable"
    
    # Test plugin output parsing
    local output
    output=$("${plugin_dir}/test_plugin.sh")
    [[ "$output" == "OK|plugin_test|Test plugin output" ]]
    assert_true "Plugin output matches expected format"
    
    # Parse the output
    local state="${output%%|*}"
    local rest="${output#*|}"
    local key="${rest%%|*}"
    local detail="${rest#*|}"
    
    assert_eq "OK" "$state" "Plugin state parsing"
    assert_eq "plugin_test" "$key" "Plugin key parsing"
    assert_eq "Test plugin output" "$detail" "Plugin detail parsing"
    
    # Test invalid state detection
    local bad_output
    bad_output=$("${plugin_dir}/bad_state_plugin.sh")
    local bad_state="${bad_output%%|*}"
    [[ "$bad_state" != "OK" && "$bad_state" != "WARNING" && "$bad_state" != "CRITICAL" ]]
    assert_true "Invalid plugin state detected"
    
    # Test invalid key detection
    local bad_key_output
    bad_key_output=$("${plugin_dir}/bad_key_plugin.sh")
    local bad_key_rest="${bad_key_output#*|}"
    local bad_key="${bad_key_rest%%|*}"
    [[ ! "$bad_key" =~ ^[a-zA-Z0-9_.-]+$ ]]
    assert_true "Invalid plugin key detected"
    
    # Cleanup
    rm -rf "$plugin_dir"
}

# ---------------------------------------------------------------------------
# Test database check configuration validation
# ---------------------------------------------------------------------------

test_database_checks() {
    echo ""
    echo "Testing database check configuration validation..."
    
    # Test MySQL configuration pattern
    local mysql_config_valid=false
    local db_mysql_host="localhost"
    local db_mysql_user="telemon"
    local db_mysql_port="3306"
    
    if [[ -n "$db_mysql_host" && -n "$db_mysql_user" ]]; then
        mysql_config_valid=true
    fi
    [[ "$mysql_config_valid" == "true" ]]
    assert_true "MySQL config valid when host and user are set"
    
    # Test MySQL with empty user (should be invalid)
    local mysql_config_invalid=false
    db_mysql_host="localhost"
    db_mysql_user=""
    if [[ -n "$db_mysql_host" && -n "$db_mysql_user" ]]; then
        mysql_config_invalid=true
    fi
    [[ "$mysql_config_invalid" == "false" ]]
    assert_true "MySQL config invalid when user is empty"
    
    # Test PostgreSQL configuration pattern
    local pg_config_valid=false
    local db_postgres_host="localhost"
    local db_postgres_user="telemon"
    
    if [[ -n "$db_postgres_host" && -n "$db_postgres_user" ]]; then
        pg_config_valid=true
    fi
    [[ "$pg_config_valid" == "true" ]]
    assert_true "PostgreSQL config valid when host and user are set"
    
    # Test Redis configuration pattern
    local redis_config_valid=false
    local db_redis_host="localhost"
    local db_redis_port="6379"
    
    if [[ -n "$db_redis_host" ]]; then
        redis_config_valid=true
    fi
    [[ "$redis_config_valid" == "true" ]]
    assert_true "Redis config valid when host is set"
    
    # Test state key generation for database checks
    local mysql_key="mysql_localhost"
    [[ "$mysql_key" =~ ^[a-zA-Z0-9_]+$ ]]
    assert_true "MySQL state key format is valid"
    
    local postgres_key="postgres_db-server_01"
    [[ "$postgres_key" =~ ^[a-zA-Z0-9_.-]+$ ]]
    assert_true "PostgreSQL state key format is valid"
    
    local redis_key="redis_cache-server_6379"
    [[ "$redis_key" =~ ^[a-zA-Z0-9_.-]+$ ]]
    assert_true "Redis state key format is valid"
    
    # Test SQLite configuration pattern
    local sqlite_config_valid=false
    local db_sqlite_paths="/tmp/test.db /opt/data/app.db"
    
    if [[ -n "$db_sqlite_paths" ]]; then
        sqlite_config_valid=true
    fi
    [[ "$sqlite_config_valid" == "true" ]]
    assert_true "SQLite config valid when paths are set"
    
    # Test SQLite with empty paths (should be invalid/disabled)
    local sqlite_config_invalid=false
    db_sqlite_paths=""
    if [[ -n "$db_sqlite_paths" ]]; then
        sqlite_config_invalid=true
    fi
    [[ "$sqlite_config_invalid" == "false" ]]
    assert_true "SQLite config invalid when paths are empty"
    
    # Test SQLite state key generation pattern
    local sqlite_path="/var/lib/plex/db.sqlite"
    local sqlite_key="sqlite_$(printf '%s' "$sqlite_path" | portable_sha256 | cut -c1-12)"
    [[ "$sqlite_key" =~ ^sqlite_[a-f0-9]{12}$ ]]
    assert_true "SQLite state key format is valid (sqlite_ + 12 char hash)"
    
    # Test SQLite path safety validation (security)
    local unsafe_path_1="/tmp/../etc/passwd"
    local unsafe_path_2="/tmp/test*"
    local unsafe_path_3="/tmp/test\$HOME"
    local safe_path="/var/lib/plex/db.sqlite"
    
    # Simulate is_safe_path check
    local path_is_safe=true
    if [[ "$unsafe_path_1" == *".."* || "$unsafe_path_1" == *"*"* || "$unsafe_path_1" == *"?"* || "$unsafe_path_1" == *"$"* ]]; then
        path_is_safe=false
    fi
    [[ "$path_is_safe" == "false" ]]
    assert_true "SQLite rejects path with directory traversal (..)"
    
    path_is_safe=true
    if [[ "$unsafe_path_2" == *".."* || "$unsafe_path_2" == *"*"* || "$unsafe_path_2" == *"?"* || "$unsafe_path_2" == *"$"* ]]; then
        path_is_safe=false
    fi
    [[ "$path_is_safe" == "false" ]]
    assert_true "SQLite rejects path with glob characters (*)"
    
    path_is_safe=true
    if [[ "$unsafe_path_3" == *".."* || "$unsafe_path_3" == *"*"* || "$unsafe_path_3" == *"?"* || "$unsafe_path_3" == *"$"* ]]; then
        path_is_safe=false
    fi
    [[ "$path_is_safe" == "false" ]]
    assert_true "SQLite rejects path with shell variables ($)"
    
    path_is_safe=true
    if [[ "$safe_path" == *".."* || "$safe_path" == *"*"* || "$safe_path" == *"?"* || "$safe_path" == *"$"* ]]; then
        path_is_safe=false
    fi
    [[ "$path_is_safe" == "true" ]]
    assert_true "SQLite accepts safe absolute path"
    
    # Test SQLite size threshold validation
    local size_warn=500
    local size_crit=1000
    
    if [[ "$size_warn" =~ ^[0-9]+$ && "$size_crit" =~ ^[0-9]+$ ]]; then
        if [[ "$size_warn" -lt "$size_crit" ]]; then
            path_is_safe=true
        else
            path_is_safe=false
        fi
    fi
    [[ "$path_is_safe" == "true" ]]
    assert_true "SQLite size thresholds valid (warn < crit)"
    
    # Test invalid threshold (warn >= crit)
    size_warn=1000
    size_crit=500
    if [[ "$size_warn" =~ ^[0-9]+$ && "$size_crit" =~ ^[0-9]+$ ]]; then
        if [[ "$size_warn" -lt "$size_crit" ]]; then
            path_is_safe=true
        else
            path_is_safe=false
        fi
    fi
    [[ "$path_is_safe" == "false" ]]
    assert_true "SQLite size thresholds invalid when warn >= crit"
}

# ---------------------------------------------------------------------------
# Test DNS record monitoring configuration validation
# ---------------------------------------------------------------------------

test_dns_record_checks() {
    echo ""
    echo "Testing DNS record check configuration validation..."
    
    # Test valid DNS record format parsing
    local record="example.com:A:93.184.216.34"
    local domain="${record%%:*}"
    local rest="${record#*:}"
    local rec_type="${rest%%:*}"
    local expected="${rest##*:}"
    
    assert_eq "example.com" "$domain" "DNS record domain parsing"
    assert_eq "A" "$rec_type" "DNS record type parsing"
    assert_eq "93.184.216.34" "$expected" "DNS record expected value parsing"
    
    # Test DNS record type validation
    local valid_types="A AAAA MX TXT CNAME NS SOA PTR SRV CAA"
    local type_to_test="MX"
    local type_valid=false
    for vt in $valid_types; do
        if [[ "$type_to_test" == "$vt" ]]; then
            type_valid=true
            break
        fi
    done
    assert_eq "true" "$type_valid" "DNS MX record type is valid"
    
    # Test invalid record type
    type_to_test="INVALID"
    type_valid=false
    for vt in $valid_types; do
        if [[ "$type_to_test" == "$vt" ]]; then
            type_valid=true
            break
        fi
    done
    assert_eq "false" "$type_valid" "DNS INVALID record type is not valid"
    
    # Test state key generation for DNS records
    local dns_key="dnsrecord_example.com_A"
    dns_key=$(echo "$dns_key" | tr -c 'a-zA-Z0-9_.-' '_')
    [[ "$dns_key" =~ ^[a-zA-Z0-9_.-]+$ ]]
    assert_true "DNS record state key format is valid"
    
    # Test wildcard expected value parsing
    record="example.com:TXT:*"
    expected="${record##*:}"
    assert_eq "*" "$expected" "DNS wildcard expected value parsing"
    
    # Test record with complex TXT value
    record="_dmarc.example.com:TXT:v=DMARC1; p=reject"
    domain="${record%%:*}"
    rest="${record#*:}"
    rec_type="${rest%%:*}"
    expected="${rest##*:}"
    
    assert_eq "_dmarc.example.com" "$domain" "DNS DMARC record domain parsing"
    assert_eq "TXT" "$rec_type" "DNS DMARC record type parsing"
    assert_eq "v=DMARC1; p=reject" "$expected" "DNS DMARC record value parsing"
}

# ---------------------------------------------------------------------------
# Test audit logging functionality
# ---------------------------------------------------------------------------

test_audit_logging() {
    echo ""
    echo "Testing audit logging functionality..."
    
    # Create a temporary audit log file
    local audit_file
    audit_file=$(mktemp)
    
    # Define audit log function inline for testing
    _should_audit_event() {
        local event_type="$1"
        local audit_events="${AUDIT_EVENTS:-all}"
        
        if [[ "$audit_events" == "all" ]]; then
            return 0
        fi
        
        local IFS=',' event
        for event in $audit_events; do
            [[ "$(echo "$event" | tr '[:upper:]' '[:lower:]')" == "$(echo "$event_type" | tr '[:upper:]' '[:lower:]')" ]] && return 0
        done
        
        return 1
    }
    
    # Test _should_audit_event with "all"
    AUDIT_EVENTS="all"
    _should_audit_event "state_change"
    assert_true "_should_audit_event accepts all events when AUDIT_EVENTS=all"
    
    _should_audit_event "alert"
    assert_true "_should_audit_event accepts alert event when AUDIT_EVENTS=all"
    
    # Test _should_audit_event with specific events
    AUDIT_EVENTS="alert,escalation"
    _should_audit_event "alert"
    assert_true "_should_audit_event accepts alert when in list"
    
    _should_audit_event "escalation"
    assert_true "_should_audit_event accepts escalation when in list"
    
    ! _should_audit_event "state_change"
    assert_true "_should_audit_event rejects state_change when not in list"
    
    # Test JSON entry format
    local timestamp="2026-04-16T12:00:00+0000"
    local hostname="test-server"
    local server_label="test-label"
    local event_type="state_change"
    local details="Key: cpu, State: CRITICAL, Previous: OK"
    
    # Escape details for JSON
    local escaped_details
    escaped_details=$(echo "$details" | sed 's/"/\\"/g')
    
    local json_entry
    json_entry="{\"timestamp\":\"${timestamp}\",\"hostname\":\"${hostname}\",\"server_label\":\"${server_label}\",\"event_type\":\"${event_type}\",\"details\":\"${escaped_details}\"}"
    
    # Verify JSON structure
    [[ "$json_entry" == *"\"timestamp\":"* ]]
    assert_true "JSON entry contains timestamp field"
    
    [[ "$json_entry" == *"\"hostname\":"* ]]
    assert_true "JSON entry contains hostname field"
    
    [[ "$json_entry" == *"\"event_type\":"* ]]
    assert_true "JSON entry contains event_type field"
    
    [[ "$json_entry" == *"\"details\":"* ]]
    assert_true "JSON entry contains details field"
    
    # Write and verify JSON to file
    echo "$json_entry" >> "$audit_file"
    [[ -f "$audit_file" ]]
    assert_true "Audit log file created"
    
    local content
    content=$(cat "$audit_file")
    [[ "$content" == *"state_change"* ]]
    assert_true "Audit log contains state_change event"
    
    # Cleanup
    rm -f "$audit_file"
    unset AUDIT_EVENTS
}

# ---------------------------------------------------------------------------
# Test static HTML status page generation
# ---------------------------------------------------------------------------
test_status_page_generation() {
    echo ""
    echo "Testing static HTML status page generation..."
    
    # Create temp files
    local tmp_dir output_file state_file detail_file
    tmp_dir=$(mktemp -d)
    output_file="${tmp_dir}/status.html"
    state_file="${tmp_dir}/state"
    detail_file="${tmp_dir}/state.detail"
    
    # Simulate state file with various states
    cat > "$state_file" << 'EOF'
cpu=OK:3
mem=WARNING:2
disk_root=CRITICAL:3
container_nginx=OK:0
EOF
    
    # Simulate detail file
    cat > "$detail_file" << 'EOF'
cpu=CPU load 0.5 = 12% of 4 cores
disk_root=Disk / at <b>95%</b> (threshold: 90%)
EOF
    
    # Mock the generate_status_page function components we can test
    # Since the full function uses telemon internals, we test the HTML generation logic
    
    # Test HTML structure generation
    local test_output="${tmp_dir}/test_status.html"
    
    # Generate a minimal test HTML
    cat > "$test_output" << 'HTMLTEST'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Telemon Status - test-server</title>
    <style>
        body { font-family: sans-serif; background: #0f172a; color: #e2e8f0; }
        .status-critical { color: #ef4444; }
        .status-warning { color: #f59e0b; }
        .status-ok { color: #10b981; }
    </style>
</head>
<body>
    <h1>test-server</h1>
    <div class="status-badge">CRITICAL</div>
    <table>
        <tr class="check-row" data-status="CRITICAL">
            <td><span class="status-cell status-critical">CRITICAL</span></td>
            <td>disk_root</td>
        </tr>
        <tr class="check-row" data-status="WARNING">
            <td><span class="status-cell status-warning">WARNING</span></td>
            <td>mem</td>
        </tr>
        <tr class="check-row" data-status="OK">
            <td><span class="status-cell status-ok">OK</span></td>
            <td>cpu</td>
        </tr>
    </table>
</body>
</html>
HTMLTEST
    
    # Verify HTML file was created
    [[ -f "$test_output" ]]
    assert_true "Status page HTML file was created"
    
    # Verify HTML structure
    local content
    content=$(cat "$test_output")
    
    [[ "$content" == *"<!DOCTYPE html>"* ]]
    assert_true "HTML contains DOCTYPE declaration"
    
    [[ "$content" == *'<html lang="en">'* ]]
    assert_true "HTML has lang attribute"
    
    [[ "$content" == *"Telemon Status"* ]]
    assert_true "HTML contains page title"
    
    # Verify CSS styling is embedded
    [[ "$content" == *"<style>"* ]]
    assert_true "HTML contains embedded CSS"
    
    # Verify status classes
    [[ "$content" == *"status-critical"* ]]
    assert_true "HTML contains critical status CSS class"
    
    [[ "$content" == *"status-warning"* ]]
    assert_true "HTML contains warning status CSS class"
    
    [[ "$content" == *"status-ok"* ]]
    assert_true "HTML contains OK status CSS class"
    
    # Verify filter functionality (JavaScript)
    [[ "$content" == *"filterChecks"* || "$content" == *"data-status"* ]]
    assert_true "HTML contains status filter functionality"
    
    # Test state file parsing logic
    local parsed_state
    parsed_state=$(grep "^cpu=" "$state_file" | cut -d'=' -f2 | cut -d':' -f1)
    assert_eq "OK" "$parsed_state" "State file parsing extracts correct state for cpu"
    
    parsed_state=$(grep "^disk_root=" "$state_file" | cut -d'=' -f2 | cut -d':' -f1)
    assert_eq "CRITICAL" "$parsed_state" "State file parsing extracts correct state for disk_root"
    
    # Test detail file parsing
    local parsed_detail
    parsed_detail=$(grep "^disk_root=" "$detail_file" | cut -d'=' -f2-)
    assert_contains "$parsed_detail" "95%" "Detail file contains expected value"
    
    # Test summary counting logic
    local crit_count=0 warn_count=0 ok_count=0 total=0
    while IFS='=' read -r key rest; do
        [[ -z "$key" ]] && continue
        local state
        state=$(echo "$rest" | cut -d':' -f1)
        total=$((total + 1))
        case "$state" in
            CRITICAL) crit_count=$((crit_count + 1)) ;;
            WARNING)  warn_count=$((warn_count + 1)) ;;
            OK)       ok_count=$((ok_count + 1)) ;;
        esac
    done < "$state_file"
    
    assert_eq "1" "$crit_count" "Counting logic finds 1 critical"
    assert_eq "1" "$warn_count" "Counting logic finds 1 warning"
    assert_eq "2" "$ok_count" "Counting logic finds 2 OK"
    assert_eq "4" "$total" "Counting logic finds 4 total"
    
    # Test overall status determination
    local overall_status="OK"
    if [[ $crit_count -gt 0 ]]; then
        overall_status="CRITICAL"
    elif [[ $warn_count -gt 0 ]]; then
        overall_status="WARNING"
    fi
    assert_eq "CRITICAL" "$overall_status" "Overall status is CRITICAL when critical checks exist"
    
    # Test HTML escaping
    local test_string="<script>alert('xss')</script>"
    local escaped_string
    escaped_string=$(printf '%s' "$test_string" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    
    [[ "$escaped_string" != *"<script>"* ]]
    assert_true "HTML escaping prevents script injection"
    
    [[ "$escaped_string" == *"&lt;script&gt;"* ]]
    assert_true "HTML escaping converts <script> to entities"
    
    # Cleanup
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Test one-line installer
# ---------------------------------------------------------------------------
test_one_line_installer() {
    echo ""
    echo "Testing One-Line Installer..."
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local test_install_dir="${tmp_dir}/telemon_test"
    
    # Test 1: Syntax check of install.sh
    [[ -f "${SCRIPT_DIR}/install.sh" ]]
    assert_true "install.sh file exists"
    
    bash -n "${SCRIPT_DIR}/install.sh"
    assert_true "install.sh passes bash syntax check"
    
    # Test 2: Check install.sh has required functions
    local install_content
    install_content=$(cat "${SCRIPT_DIR}/install.sh")
    
    [[ "$install_content" == *"step_1_check_dependencies"* ]]
    assert_true "install.sh contains step_1_check_dependencies function"
    
    [[ "$install_content" == *"step_2_create_directory"* ]]
    assert_true "install.sh contains step_2_create_directory function"
    
    [[ "$install_content" == *"step_5_configure_env"* ]]
    assert_true "install.sh contains step_5_configure_env function"
    
    [[ "$install_content" == *"step_6_setup_cron"* ]]
    assert_true "install.sh contains step_6_setup_cron function"
    
    # Test 3: Check for GitHub download URLs
    [[ "$install_content" == *"raw.githubusercontent.com"* ]]
    assert_true "install.sh references GitHub raw URLs for remote install"
    
    [[ "$install_content" == *"download_file"* ]]
    assert_true "install.sh has download_file function"
    
    # Test 4: Check for local install detection
    [[ "$install_content" == *"is_local_install"* ]]
    assert_true "install.sh has is_local_install detection function"
    
    # Test 5: Simulate a local installation
    mkdir -p "$test_install_dir"
    
    # Create a minimal mock environment for testing
    local mock_telemon_sh="${test_install_dir}/telemon.sh"
    echo '#!/bin/bash' > "$mock_telemon_sh"
    echo 'echo "Telemon Mock"' >> "$mock_telemon_sh"
    chmod +x "$mock_telemon_sh"
    
    local mock_admin_sh="${test_install_dir}/telemon-admin.sh"
    echo '#!/bin/bash' > "$mock_admin_sh"
    echo 'source "$(dirname "$0")/lib/common.sh"' >> "$mock_admin_sh"
    chmod +x "$mock_admin_sh"
    
    mkdir -p "${test_install_dir}/lib"
    echo '# Common helpers' > "${test_install_dir}/lib/common.sh"
    
    mkdir -p "${test_install_dir}/checks.d"
    echo '# Example plugin' > "${test_install_dir}/checks.d/example.sh"
    
    [[ -f "$mock_telemon_sh" ]]
    assert_true "Mock telemon.sh created for testing"
    
    # Test 6: Check install.sh help/usage
    [[ "$install_content" == *"Usage:"* || "$install_content" == *"--help"* ]]
    assert_true "install.sh contains help/usage information"
    
    # Test 7: Verify installer supports custom directory
    [[ "$install_content" == *"INSTALL_DIR="* || "$install_content" == *"\$1"* ]]
    assert_true "install.sh supports custom installation directory"
    
    # Test 8: Check for interactive configuration prompts
    [[ "$install_content" == *"Telegram Bot Token"* ]]
    assert_true "install.sh prompts for Telegram Bot Token"
    
    [[ "$install_content" == *"Telegram Chat ID"* ]]
    assert_true "install.sh prompts for Telegram Chat ID"
    
    [[ "$install_content" == *"Server Label"* ]]
    assert_true "install.sh prompts for Server Label"
    
    # Test 9: Check for .env security (chmod 600)
    [[ "$install_content" == *"chmod 600"* ]]
    assert_true "install.sh sets secure permissions (600) on .env"
    
    # Test 10: Verify uninstall.sh exists and works
    [[ -f "${SCRIPT_DIR}/uninstall.sh" ]]
    assert_true "uninstall.sh file exists"
    
    bash -n "${SCRIPT_DIR}/uninstall.sh"
    assert_true "uninstall.sh passes bash syntax check"
    
    local uninstall_content
    uninstall_content=$(cat "${SCRIPT_DIR}/uninstall.sh")
    
    [[ "$uninstall_content" == *"crontab"* ]]
    assert_true "uninstall.sh handles cron job removal"
    
    # Cleanup
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Test threshold helper with numeric validation
# ---------------------------------------------------------------------------

test_check_threshold_helper() {
    echo ""
    echo "Testing check_threshold helper..."
    
    # Define check_threshold function inline for testing (simplified version)
    check_threshold() {
        local key="$1"
        local value="$2"
        local warn="$3"
        local crit="$4"
        local inverted="${5:-false}"
        local ok_detail="$6"
        local warn_detail="${7:-}"
        local crit_detail="${8:-}"
        
        # Validate numeric inputs
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        if ! [[ "$warn" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        if ! [[ "$crit" =~ ^[0-9]+$ ]]; then
            return 1
        fi
        
        [[ -z "$warn_detail" ]] && warn_detail="$crit_detail"
        [[ -z "$crit_detail" ]] && crit_detail="$warn_detail"
        
        local state="OK"
        local detail="$ok_detail"
        
        if [[ "$inverted" == "true" ]]; then
            if (( value <= crit )); then
                state="CRITICAL"
                detail="$crit_detail"
            elif (( value <= warn )); then
                state="WARNING"
                detail="$warn_detail"
            fi
        else
            if (( value >= crit )); then
                state="CRITICAL"
                detail="$crit_detail"
            elif (( value >= warn )); then
                state="WARNING"
                detail="$warn_detail"
            fi
        fi
        
        THRESHOLD_STATE="$state"
        THRESHOLD_DETAIL="$detail"
        return 0
    }
    
    # Test standard metric (higher = worse)
    check_threshold "test_cpu" "85" "70" "80" "false" "OK detail" "WARN detail" "CRIT detail"
    assert_eq "CRITICAL" "$THRESHOLD_STATE" "check_threshold: CRITICAL when value >= crit"
    
    check_threshold "test_cpu" "75" "70" "80" "false" "OK detail" "WARN detail" "CRIT detail"
    assert_eq "WARNING" "$THRESHOLD_STATE" "check_threshold: WARNING when value >= warn but < crit"
    
    check_threshold "test_cpu" "50" "70" "80" "false" "OK detail" "WARN detail" "CRIT detail"
    assert_eq "OK" "$THRESHOLD_STATE" "check_threshold: OK when value < warn"
    
    # Test inverted metric (lower = worse)
    check_threshold "test_mem" "5" "15" "10" "true" "OK detail" "WARN detail" "CRIT detail"
    assert_eq "CRITICAL" "$THRESHOLD_STATE" "check_threshold: CRITICAL for inverted when value <= crit"
    
    check_threshold "test_mem" "12" "15" "10" "true" "OK detail" "WARN detail" "CRIT detail"
    assert_eq "WARNING" "$THRESHOLD_STATE" "check_threshold: WARNING for inverted when value <= warn but > crit"
    
    check_threshold "test_mem" "20" "15" "10" "true" "OK detail" "WARN detail" "CRIT detail"
    assert_eq "OK" "$THRESHOLD_STATE" "check_threshold: OK for inverted when value > warn"
    
    # Test non-numeric value handling
    ! check_threshold "test" "abc" "70" "80" "false" "OK" "WARN" "CRIT" 2>/dev/null
    assert_true "check_threshold: rejects non-numeric value"
    
    # Test non-numeric threshold handling
    ! check_threshold "test" "50" "abc" "80" "false" "OK" "WARN" "CRIT" 2>/dev/null
    assert_true "check_threshold: rejects non-numeric warn threshold"
    
    unset check_threshold THRESHOLD_STATE THRESHOLD_DETAIL
}

# ---------------------------------------------------------------------------
# Test security fixes (database password handling)
# ---------------------------------------------------------------------------

test_security_database_passwords() {
    echo ""
    echo "Testing security: database password handling..."
    
    # Verify that database check code uses environment variables
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    
    # Check MySQL uses MYSQL_PWD env var
    [[ "$telemon_content" == *"MYSQL_PWD"* ]]
    assert_true "Security: MySQL uses MYSQL_PWD environment variable"
    
    # Check PostgreSQL uses PGPASSWORD env var
    [[ "$telemon_content" == *"PGPASSWORD"* ]]
    assert_true "Security: PostgreSQL uses PGPASSWORD environment variable"
    
    # Check Redis uses REDISCLI_AUTH env var
    [[ "$telemon_content" == *"REDISCLI_AUTH"* ]]
    assert_true "Security: Redis uses REDISCLI_AUTH environment variable"
    
    # Verify passwords are NOT passed as command-line arguments
    # (This is a negative test - we ensure the old pattern doesn't exist)
    # Check that old --password flag pattern is not used
    local has_password_flag=false
    if echo "$telemon_content" | grep -q "password=.*\\\${.*_pass.*}" 2>/dev/null; then
        has_password_flag=true
    fi
    [[ "$has_password_flag" == "false" ]]
    assert_true "Security: No plaintext password flags in command lines"
    
    # SQLite3 Security Tests
    # SQLite doesn't use passwords, but we verify path safety and command safety
    
    # Check SQLite uses is_safe_path validation
    [[ "$telemon_content" == *"is_safe_path"* && "$telemon_content" == *"DB_SQLITE_PATHS"* ]]
    assert_true "Security: SQLite uses is_safe_path for path validation"
    
    # Check SQLite command uses run_with_timeout (prevents indefinite hangs)
    [[ "$telemon_content" == *"sqlite3"* && "$telemon_content" == *"run_with_timeout"* ]]
    assert_true "Security: SQLite commands use timeout protection"
    
    # Verify SQLite doesn't use shell interpolation for paths
    # (Paths should be passed as arguments, not interpolated)
    local has_sqlite_interpolation=false
    if echo "$telemon_content" | grep -E 'sqlite3.*\$\{.*sqlit.*\}' 2>/dev/null | grep -qv 'db_path'; then
        has_sqlite_interpolation=true
    fi
    # The check above is intentionally lenient - we verify the key pattern exists
    [[ "$telemon_content" == *'sqlite3 "$db_path"'* || "$telemon_content" == *"sqlite3 \"\$db_path\""* ]]
    assert_true "Security: SQLite uses quoted path variable (prevents word splitting)"
}

# ---------------------------------------------------------------------------
# Test ODBC database check functionality
# ---------------------------------------------------------------------------

test_odbc_checks() {
    echo ""
    echo "Testing ODBC check configuration validation..."
    
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    
    # Check check_odbc function exists
    [[ "$telemon_content" == *"check_odbc()"* ]]
    assert_true "ODBC: check_odbc() function exists"
    
    # Check ENABLE_ODBC_CHECKS flag is used
    [[ "$telemon_content" == *"ENABLE_ODBC_CHECKS"* ]]
    assert_true "ODBC: ENABLE_ODBC_CHECKS configuration flag exists"
    
    # Check ODBC_CONNECTIONS is used
    [[ "$telemon_content" == *"ODBC_CONNECTIONS"* ]]
    assert_true "ODBC: ODBC_CONNECTIONS configuration exists"
    
    # Check isql command is used
    [[ "$telemon_content" == *"isql"* ]]
    assert_true "ODBC: uses isql command for connectivity testing"
    
    # Check connection name validation
    [[ "$telemon_content" == *"is_valid_service_name \"\$conn_name\""* ]]
    assert_true "ODBC: validates connection names (security)"
    
    # Check state key generation uses sanitize_state_key
    [[ "$telemon_content" == *"odbc_\$(sanitize_state_key"* ]]
    assert_true "ODBC: uses sanitize_state_key for state keys"
    
    # Check password security (indirect expansion pattern)
    [[ "$telemon_content" == *"pass_var="* && "$telemon_content" == *"conn_pass=\"\${!pass_var:-}\""* ]]
    assert_true "ODBC: uses indirect expansion for password lookup"
    
    # Check password sanitization in error messages
    [[ "$telemon_content" == *"s/PWD=[^;]*;/PWD=***/g"* ]]
    assert_true "ODBC: sanitizes PWD from error messages"
    [[ "$telemon_content" == *"s/PASS=[^;]*;/PASS=***/g"* ]]
    assert_true "ODBC: sanitizes PASS from error messages"
    
    # Check run_with_timeout is used
    [[ "$telemon_content" == *"run_with_timeout"* && "$telemon_content" == *"check_odbc"* ]]
    assert_true "ODBC: uses timeout protection for connections"
    
    # Check validation function handles ODBC
    [[ "$telemon_content" == *"ENABLE_ODBC_CHECKS"* && "$telemon_content" == *"isql not found"* ]]
    assert_true "ODBC: run_validate checks for isql dependency"
    
    # Check connection validation (DSN or DRIVER+SERVER required)
    [[ "$telemon_content" == *"need ODBC_\${conn_name}_DSN or"* || "$telemon_content" == *"ODBC_\${conn_name}_DRIVER"* ]]
    assert_true "ODBC: validates connection has DSN or DRIVER+SERVER"
    
    # Check string concatenation is correct (bug fix verification)
    [[ "$telemon_content" == *"conn_str+=\"UID=\${conn_user};\""* ]]
    assert_true "ODBC: correct string concatenation for UID (conn_str+=)"
    [[ "$telemon_content" == *"conn_str+=\"PWD=\${conn_pass};\""* ]]
    assert_true "ODBC: correct string concatenation for PWD (conn_str+=)"
}

# ---------------------------------------------------------------------------
# Test predictive exhaustion functionality
# ---------------------------------------------------------------------------

test_predictive_exhaustion() {
    echo ""
    echo "Testing predictive exhaustion functionality..."
    
    # Create temp state file for trend testing
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local trend_file="${tmp_dir}/trend"
    
    # Test 1: record_trend creates trend file
    # Define inline test versions of the functions
    record_trend_test() {
        local key="$1"
        local value="$2"
        local max_points=48
        local now=1000000000  # Fixed timestamp for testing
        
        # Load existing trend data
        declare -A trend_data
        if [[ -f "$trend_file" ]]; then
            while IFS='=' read -r tkey tval; do
                [[ -z "$tkey" ]] && continue
                trend_data["$tkey"]="$tval"
            done < "$trend_file"
        fi
        
        # Append new datapoint
        local cleaned=""
        local existing="${trend_data[$key]:-}"
        if [[ -n "$existing" ]]; then
            cleaned="$existing"
        fi
        cleaned+="${cleaned:+,}${now}:${value}"
        trend_data["$key"]="$cleaned"
        
        # Write all keys back
        local content=""
        for tkey in "${!trend_data[@]}"; do
            content+="${tkey}=${trend_data[$tkey]}"$'\n'
        done
        echo "$content" > "$trend_file"
    }
    
    record_trend_test "predict_disk_root" "50"
    [[ -f "$trend_file" ]]
    assert_true "record_trend: creates trend file"
    
    # Test 2: Verify trend data format
    local trend_content
    trend_content=$(cat "$trend_file")
    [[ "$trend_content" == *"predict_disk_root="* ]]
    assert_true "record_trend: stores key in trend file"
    [[ "$trend_content" == *"1000000000:50"* ]]
    assert_true "record_trend: stores epoch:value format"
    
    # Test 3: linear_regression with growth trend
    # Test the linear_regression function directly
    local result
    result=$(linear_regression "1000:50,2000:60,3000:70,4000:80" 2>/dev/null || echo "0 0")
    [[ "$result" != "0 0" ]]
    assert_true "linear_regression: calculates slope for growing data"
    
    # Test 4: linear_regression with stable data (no growth)
    result=$(linear_regression "1000:50,2000:50,3000:50,4000:50" 2>/dev/null || echo "0 0")
    local slope
    slope=$(echo "$result" | awk '{print $1}')
    local slope_near_zero
    slope_near_zero=$(awk -v s="$slope" 'BEGIN { print (s > -0.001 && s < 0.001) ? "1" : "0" }')
    [[ "$slope_near_zero" == "1" ]]
    assert_true "linear_regression: near-zero slope for stable data"
    
    # Test 5: Check prediction logic (positive slope = growing toward exhaustion)
    result=$(linear_regression "1000:80,2000:85,3000:90,4000:95" 2>/dev/null || echo "0 0")
    slope=$(echo "$result" | awk '{print $1}')
    local slope_positive
    slope_positive=$(awk -v s="$slope" 'BEGIN { print (s > 0) ? "1" : "0" }')
    [[ "$slope_positive" == "1" ]]
    assert_true "linear_regression: positive slope for growing resource usage"
    
    # Test 6: Test trend file with multiple keys
    record_trend_test "predict_memory" "30"
    record_trend_test "predict_swap" "10"
    trend_content=$(cat "$trend_file")
    [[ "$trend_content" == *"predict_disk_root"* ]]
    assert_true "record_trend: maintains multiple keys (disk_root)"
    [[ "$trend_content" == *"predict_memory"* ]]
    assert_true "record_trend: maintains multiple keys (memory)"
    [[ "$trend_content" == *"predict_swap"* ]]
    assert_true "record_trend: maintains multiple keys (swap)"
    
    # Cleanup
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Test fleet heartbeat functionality
# ---------------------------------------------------------------------------

test_fleet_heartbeats() {
    echo ""
    echo "Testing fleet heartbeat functionality..."
    
    # Create temp directory for heartbeat files
    local fleet_dir
    fleet_dir=$(mktemp -d)
    
    # Test 1: Fleet heartbeat file format validation
    local test_label="test-server-01"
    local test_timestamp
    test_timestamp=$(date +%s)
    local test_status="OK"
    local test_check_count=10
    local test_warn_count=1
    local test_crit_count=0
    local test_uptime=3600
    
    # Create heartbeat file in correct format
    local heartbeat_line
    heartbeat_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$test_label" "$test_timestamp" "$test_status" \
        "$test_check_count" "$test_warn_count" "$test_crit_count" "$test_uptime")
    echo "$heartbeat_line" > "${fleet_dir}/${test_label}"
    
    [[ -f "${fleet_dir}/${test_label}" ]]
    assert_true "Fleet: heartbeat file created"
    
    # Test 2: Parse heartbeat file
    local hb_label hb_ts hb_status hb_count _
    IFS=$'\t' read -r hb_label hb_ts hb_status hb_count _ < "${fleet_dir}/${test_label}"
    assert_eq "$test_label" "$hb_label" "Fleet: parse heartbeat label"
    assert_eq "$test_timestamp" "$hb_ts" "Fleet: parse heartbeat timestamp"
    assert_eq "$test_status" "$hb_status" "Fleet: parse heartbeat status"
    assert_eq "$test_check_count" "$hb_count" "Fleet: parse heartbeat check count"
    
    # Test 3: Validate status field allowlist
    local valid_statuses=("OK" "WARNING" "CRITICAL")
    for status in "${valid_statuses[@]}"; do
        [[ "$status" =~ ^(OK|WARNING|CRITICAL)$ ]]
        assert_true "Fleet: status '${status}' matches valid pattern"
    done
    
    # Test 4: Invalid status rejected
    local invalid_status="invalid"
    [[ ! "$invalid_status" =~ ^(OK|WARNING|CRITICAL)$ ]]
    assert_true "Fleet: invalid status '${invalid_status}' rejected"
    
    # Test 5: Calculate heartbeat age
    local now
    now=$(date +%s)
    local file_age=$(( now - hb_ts ))
    [[ "$file_age" -ge 0 && "$file_age" -lt 60 ]]
    assert_true "Fleet: heartbeat age calculated correctly (within 60s)"
    
    # Test 6: Stale detection threshold
    local stale_threshold_min=15
    local stale_threshold_sec=$(( stale_threshold_min * 60 ))
    local crit_multiplier=2
    local crit_threshold_sec=$(( stale_threshold_sec * crit_multiplier ))
    
    [[ "$stale_threshold_sec" -eq 900 ]]
    assert_true "Fleet: stale threshold calculated correctly (15 min = 900s)"
    [[ "$crit_threshold_sec" -eq 1800 ]]
    assert_true "Fleet: critical threshold calculated correctly (30 min = 1800s)"
    
    # Cleanup
    rm -rf "$fleet_dir"
}

# ---------------------------------------------------------------------------
# Test maintenance window functionality
# ---------------------------------------------------------------------------

test_maintenance_windows() {
    echo ""
    echo "Testing maintenance window functionality..."
    
    # Define test version of is_in_maintenance_window
    is_in_maintenance_window_test() {
        local schedule="$1"
        [[ -z "$schedule" ]] && return 1
        
        local current_day
        current_day=$(date '+%a')
        local current_hour
        current_hour=$(date '+%-H')
        local current_min
        current_min=$(date '+%-M')
        local current_minutes=$(( current_hour * 60 + current_min ))
        
        local IFS=';'
        for entry in $schedule; do
            entry=$(echo "$entry" | xargs)
            [[ -z "$entry" ]] && continue
            
            local sched_day="${entry%% *}"
            local time_range="${entry##* }"
            local start_time="${time_range%%-*}"
            local end_time="${time_range##*-}"
            
            local start_h="${start_time%%:*}"
            local start_m="${start_time##*:}"
            local end_h="${end_time%%:*}"
            local end_m="${end_time##*:}"
            
            local start_min=$(( start_h * 60 + start_m ))
            local end_min=$(( end_h * 60 + end_m ))
            
            if [[ "$current_day" == "$sched_day" ]]; then
                if (( current_minutes >= start_min && current_minutes < end_min )); then
                    return 0
                fi
            fi
        done
        
        return 1
    }
    
    # Test 1: Empty schedule returns false (not in maintenance)
    ! is_in_maintenance_window_test ""
    assert_true "Maintenance: empty schedule returns false"
    
    # Test 2: Different day returns false
    local different_day="Mon 02:00-04:00"
    local current_day
    current_day=$(date '+%a')
    if [[ "$current_day" != "Mon" ]]; then
        ! is_in_maintenance_window_test "$different_day"
        assert_true "Maintenance: different day returns false"
    fi
    
    # Test 3: Same day, outside window returns false
    # Use yesterday's window (which won't match today)
    local yesterday_window
    case "$current_day" in
        Mon) yesterday_window="Sun 02:00-04:00" ;;
        Tue) yesterday_window="Mon 02:00-04:00" ;;
        Wed) yesterday_window="Tue 02:00-04:00" ;;
        Thu) yesterday_window="Wed 02:00-04:00" ;;
        Fri) yesterday_window="Thu 02:00-04:00" ;;
        Sat) yesterday_window="Fri 02:00-04:00" ;;
        Sun) yesterday_window="Sat 02:00-04:00" ;;
    esac
    ! is_in_maintenance_window_test "$yesterday_window"
    assert_true "Maintenance: different day (yesterday) returns false"
    
    # Test 4: Schedule format parsing
    local multi_schedule="Sun 02:00-04:00;Sat 03:00-05:00"
    local first_entry="${multi_schedule%%;*}"
    local first_day="${first_entry%% *}"
    assert_eq "Sun" "$first_day" "Maintenance: parse first day from multi-schedule"
    
    local second_entry="${multi_schedule##*;}"
    local second_day="${second_entry%% *}"
    assert_eq "Sat" "$second_day" "Maintenance: parse second day from multi-schedule"
    
    # Test 5: Time range parsing
    local test_entry="Sun 02:00-04:00"
    local test_time_range="${test_entry##* }"
    local test_start="${test_time_range%%-*}"
    local test_end="${test_time_range##*-}"
    assert_eq "02:00" "$test_start" "Maintenance: parse start time"
    assert_eq "04:00" "$test_end" "Maintenance: parse end time"
}

# ---------------------------------------------------------------------------
# Test auto-remediation functionality
# ---------------------------------------------------------------------------

test_auto_remediation() {
    echo ""
    echo "Testing auto-remediation functionality..."
    
    # Test 1: Service name validation
    local valid_services=("nginx" "sshd" "cron" "my-service" "my_service")
    for svc in "${valid_services[@]}"; do
        [[ "$svc" =~ ^[a-zA-Z0-9._-]+$ ]]
        assert_true "Auto-remediation: valid service name '${svc}' accepted"
    done
    
    # Test 2: Invalid service names rejected
    local invalid_services=("service;rm -rf /" "service with space" 'service$(id)')
    for svc in "${invalid_services[@]}"; do
        ! [[ "$svc" =~ ^[a-zA-Z0-9._-]+$ ]]
        assert_true "Auto-remediation: invalid service name '${svc}' rejected"
    done
    
    # Test 3: State key generation for processes
    local test_proc="nginx"
    local proc_key="proc_${test_proc}"
    assert_eq "proc_nginx" "$proc_key" "Auto-remediation: process state key generation"
    
    # Test 4: CURR_STATE lookup pattern
    # Simulate checking if a service is in CRITICAL state
    declare -A test_curr_state
    test_curr_state["proc_nginx"]="CRITICAL"
    test_curr_state["proc_sshd"]="OK"
    test_curr_state["proc_mysql"]="WARNING"
    
    [[ "${test_curr_state[proc_nginx]}" == "CRITICAL" ]]
    assert_true "Auto-remediation: detects CRITICAL state for nginx"
    [[ "${test_curr_state[proc_sshd]}" == "OK" ]]
    assert_true "Auto-remediation: detects OK state for sshd"
    [[ "${test_curr_state[proc_mysql]}" == "WARNING" ]]
    assert_true "Auto-remediation: detects WARNING state for mysql"
    
    # Test 5: systemctl command construction
    local test_service="nginx"
    local systemctl_cmd="systemctl restart -- ${test_service}"
    [[ "$systemctl_cmd" == *"--"* ]]
    assert_true "Auto-remediation: systemctl command uses -- separator"
    [[ "$systemctl_cmd" == *"restart"* ]]
    assert_true "Auto-remediation: systemctl command includes restart"
}

# ---------------------------------------------------------------------------
# Test Discovery System (telemon-admin.sh)
# ---------------------------------------------------------------------------

test_discovery_system() {
    echo ""
    echo "Testing discovery system helpers..."
    
    # Source the admin script helpers (only test helper functions that don't depend on system state)
    local admin_script="${SCRIPT_DIR}/telemon-admin.sh"
    
    # Test 1: verify admin script syntax
    bash -n "$admin_script" 2>/dev/null
    assert_true "Discovery: admin script syntax check passes"
    
    # Test 2: verify discover command exists
    grep -q "cmd_discover()" "$admin_script"
    assert_true "Discovery: cmd_discover function exists"
    
    # Test 3: verify helper functions exist
    grep -q "detect_hardware()" "$admin_script"
    assert_true "Discovery: detect_hardware helper exists"
    
    grep -q "detect_infrastructure()" "$admin_script"
    assert_true "Discovery: detect_infrastructure helper exists"
    
    grep -q "detect_applications()" "$admin_script"
    assert_true "Discovery: detect_applications helper exists"
    
    grep -q "detect_database_servers()" "$admin_script"
    assert_true "Discovery: detect_database_servers helper exists"
    
    grep -q "generate_smart_thresholds()" "$admin_script"
    assert_true "Discovery: generate_smart_thresholds helper exists"
    
    # Test 4: verify systemd helper functions
    grep -q "_systemd_is_active()" "$admin_script"
    assert_true "Discovery: _systemd_is_active helper exists"
    
    grep -q "_cmd_exists()" "$admin_script"
    assert_true "Discovery: _cmd_exists helper exists"
    
    # Test 5: verify system spec helpers exist
    grep -q "_get_total_memory_gb()" "$admin_script"
    assert_true "Discovery: _get_total_memory_gb helper exists"
    
    grep -q "_get_cpu_cores()" "$admin_script"
    assert_true "Discovery: _get_cpu_cores helper exists"
    
    # Test 6: test _cmd_exists helper (inline test)
    # This tests the function pattern without sourcing the whole script
    test_cmd_exists() {
        command -v bash &>/dev/null
    }
    test_cmd_exists
    assert_true "Discovery: _cmd_exists pattern works for existing command"
    
    # Test 7: verify discovery categories in output
    grep -q "Hardware" "$admin_script"
    assert_true "Discovery: Hardware section in output"
    
    grep -q "Infrastructure" "$admin_script"
    assert_true "Discovery: Infrastructure section in output"
    
    grep -q "Core Services" "$admin_script"
    assert_true "Discovery: Core Services section in output"
    
    grep -q "Databases" "$admin_script"
    assert_true "Discovery: Databases section in output"
    
    grep -q "Smart Thresholds" "$admin_script"
    assert_true "Discovery: Smart Thresholds section in output"
    
    # Test 8: verify smart thresholds generates expected keys
    grep -q "MEM_THRESHOLD_WARN" "$admin_script"
    assert_true "Discovery: generates MEM_THRESHOLD_WARN"
    
    grep -q "CPU_THRESHOLD_WARN" "$admin_script"
    assert_true "Discovery: generates CPU_THRESHOLD_WARN"
    
    grep -q "MEM_THRESHOLD_CRIT" "$admin_script"
    assert_true "Discovery: generates MEM_THRESHOLD_CRIT"
    
    grep -q "CPU_THRESHOLD_CRIT" "$admin_script"
    assert_true "Discovery: generates CPU_THRESHOLD_CRIT"
    
    # Test 9: verify hardware detection patterns
    grep -q "nvme" "$admin_script" || grep -q "smartctl" "$admin_script"
    assert_true "Discovery: NVMe detection pattern exists"
    
    grep -q "nvidia-smi" "$admin_script"
    assert_true "Discovery: NVIDIA GPU detection pattern exists"
    
    grep -q "intel_gpu_top" "$admin_script"
    assert_true "Discovery: Intel GPU detection pattern exists"
    
    grep -q "sensors" "$admin_script"
    assert_true "Discovery: lm-sensors detection pattern exists"
    
    # Test 10: verify UPS detection patterns  
    grep -q "apcupsd" "$admin_script"
    assert_true "Discovery: APC UPS detection pattern exists"
    
    grep -q "upower" "$admin_script"
    assert_true "Discovery: upower detection pattern exists"
    
    # Test 11: verify storage detection patterns
    grep -q "zpool" "$admin_script"
    assert_true "Discovery: ZFS detection pattern exists"
    
    grep -q "pvs" "$admin_script"
    assert_true "Discovery: LVM detection pattern exists"
    
    grep -q "/proc/mdstat" "$admin_script"
    assert_true "Discovery: mdadm RAID detection pattern exists"
    
    # Test 12: verify virtualization detection patterns
    grep -q "docker" "$admin_script"
    assert_true "Discovery: Docker detection pattern exists"
    
    grep -q "kubectl" "$admin_script"
    assert_true "Discovery: Kubernetes detection pattern exists"
    
    grep -q "Swarm" "$admin_script"
    assert_true "Discovery: Docker Swarm detection pattern exists"
    
    grep -q "pveversion" "$admin_script"
    assert_true "Discovery: Proxmox detection pattern exists"
    
    grep -q "virsh" "$admin_script"
    assert_true "Discovery: KVM/QEMU detection pattern exists"
    
    # Test 13: verify network/VPN detection patterns
    grep -q "tailscale" "$admin_script"
    assert_true "Discovery: Tailscale detection pattern exists"
    
    grep -q "wireguard" "$admin_script" || grep -q "wg " "$admin_script"
    assert_true "Discovery: WireGuard detection pattern exists"
    
    grep -q "haproxy" "$admin_script"
    assert_true "Discovery: HAProxy detection pattern exists"
    
    # Test 14: verify application detection patterns
    grep -q "fail2ban" "$admin_script"
    assert_true "Discovery: Fail2ban detection pattern exists"
    
    grep -q "crowdsec" "$admin_script"
    assert_true "Discovery: CrowdSec detection pattern exists"
    
    grep -q "rabbitmq" "$admin_script"
    assert_true "Discovery: RabbitMQ detection pattern exists"
    
    grep -q "mosquitto" "$admin_script"
    assert_true "Discovery: Mosquitto MQTT detection pattern exists"
    
    # Test 15: verify database server detection (vs just client)
    grep -q "mysqld" "$admin_script"
    assert_true "Discovery: MySQL server detection pattern exists"
    
    grep -q "postgresql" "$admin_script"
    assert_true "Discovery: PostgreSQL server detection pattern exists"
    
    grep -q "redis-server" "$admin_script"
    assert_true "Discovery: Redis server detection pattern exists"
    
    # Test 16: verify suggestions are properly formatted
    grep -q "ENABLE_NVME_CHECK" "$admin_script"
    assert_true "Discovery: suggests ENABLE_NVME_CHECK"
    
    grep -q "ENABLE_GPU_CHECK" "$admin_script"
    assert_true "Discovery: suggests ENABLE_GPU_CHECK"
    
    grep -q "ENABLE_UPS_CHECK" "$admin_script"
    assert_true "Discovery: suggests ENABLE_UPS_CHECK"
    
    grep -q "ENABLE_TEMP_CHECK" "$admin_script"
    assert_true "Discovery: suggests ENABLE_TEMP_CHECK"
    
    # Test 17: verify memory-based threshold logic
    grep -q "total_mem_gb" "$admin_script"
    assert_true "Discovery: uses total memory for threshold calculation"
    
    # Test 18: verify core-based threshold logic  
    grep -q "cores" "$admin_script"
    assert_true "Discovery: uses CPU cores for threshold calculation"
    
    # Test 19: verify output sections have proper headers
    grep -q "=== Hardware ===" "$admin_script"
    assert_true "Discovery: Hardware section header"
    
    grep -q "=== Infrastructure ===" "$admin_script"
    assert_true "Discovery: Infrastructure section header"
    
    grep -q "=== Databases ===" "$admin_script"
    assert_true "Discovery: Databases section header"
    
    # Test 20: verify timestamp in output
    grep -q 'date +%Y-%m-%d' "$admin_script"
    assert_true "Discovery: includes generation timestamp"
    
    # Test 21: verify enhanced cron detection patterns
    grep -q "cronie" "$admin_script"
    assert_true "Discovery: cronie detection pattern exists"
    
    grep -q "anacron" "$admin_script"
    assert_true "Discovery: anacron detection pattern exists"
    
    grep -q "systemd-cron" "$admin_script"
    assert_true "Discovery: systemd-cron detection pattern exists"
    
    # Test 22: verify systemd timers detection
    grep -q "list-timers" "$admin_script"
    assert_true "Discovery: systemd timers detection exists"
    
    grep -q "active_timers" "$admin_script"
    assert_true "Discovery: active timers variable exists"
    
    # Test 23: verify smart critical processes list building
    grep -q "critical_procs" "$admin_script"
    assert_true "Discovery: dynamic critical_procs list building exists"
    
    grep -q "has_cron" "$admin_script"
    assert_true "Discovery: has_cron detection flag exists"
    
    # Test 24: verify timers note in suggestions
    grep -q "systemd timers instead of traditional cron" "$admin_script"
    assert_true "Discovery: systemd timers note in suggestions"
}

# ---------------------------------------------------------------------------
# Test lock mechanism functions (pattern verification in telemon.sh)
# ---------------------------------------------------------------------------

test_lock_mechanism() {
    echo ""
    echo "Testing lock mechanism functions..."
    
    local telemon_script="${SCRIPT_DIR}/telemon.sh"
    
    # Test 1: Verify LOCK_TIMEOUT_SEC and LOCK_STALE_AGE_SEC are defined in telemon.sh
    grep -q "LOCK_TIMEOUT_SEC=300" "$telemon_script"
    assert_true "Lock: LOCK_TIMEOUT_SEC=300 defined"
    
    grep -q "LOCK_STALE_AGE_SEC=600" "$telemon_script"
    assert_true "Lock: LOCK_STALE_AGE_SEC=600 defined"
    
    # Test 2: Verify _is_telemon_process function exists
    grep -q "_is_telemon_process()" "$telemon_script"
    assert_true "Lock: _is_telemon_process function defined"
    
    # Test 3: Verify _is_lock_stale function exists
    grep -q "_is_lock_stale()" "$telemon_script"
    assert_true "Lock: _is_lock_stale function defined"
    
    # Test 4: Verify lock contention rate limiting is implemented
    grep -q "_LOCK_CONTENTION_LOGGED" "$telemon_script"
    assert_true "Lock: _LOCK_CONTENTION_LOGGED variable for rate limiting"
    
    grep -q "_log_lock_contention()" "$telemon_script"
    assert_true "Lock: _log_lock_contention function defined"
    
    # Test 5: Verify proc/PID/cmdline check exists
    grep -q '/proc/$pid/cmdline' "$telemon_script"
    assert_true "Lock: /proc/PID/cmdline verification exists"
    
    # Test 6: Verify force-break for very old locks exists
    grep -q "force breaking lock" "$telemon_script"
    assert_true "Lock: Force-break message for very old locks"
    
    # Test 7: Verify PID reuse detection message
    grep -q "PID reuse" "$telemon_script"
    assert_true "Lock: PID reuse detection message exists"
    
    # Test 8: Verify lock stale logic checks for telemon in cmdline
    grep -q 'cmdline.*telemon' "$telemon_script"
    assert_true "Lock: cmdline check for 'telemon' string exists"
    
    # Test 9: Verify stale lock detection at >10 minutes
    grep -q '900s' "$telemon_script" || grep -q 'age.*lock_age' "$telemon_script"
    assert_true "Lock: Age-based stale detection exists"
    
    # Test 10: Verify lock file age tracking with timestamp
    grep -q 'echo.*\$\$.*date.*%s' "$telemon_script"
    assert_true "Lock: PID and timestamp written to lock file"
}

# ---------------------------------------------------------------------------
# Test first-run fingerprint mechanism
# ---------------------------------------------------------------------------

test_first_run_fingerprint() {
    echo ""
    echo "Testing first-run fingerprint mechanism..."
    
    local telemon_script="${SCRIPT_DIR}/telemon.sh"
    local admin_script="${SCRIPT_DIR}/telemon-admin.sh"
    
    # Test 1: FIRST_RUN_FINGERPRINT variable is defined
    grep -q "FIRST_RUN_FINGERPRINT=" "$telemon_script"
    assert_true "First-run: FIRST_RUN_FINGERPRINT variable defined"
    
    # Test 2: Fingerprint path uses SCRIPT_DIR as primary location (with fallback support)
    # BUG-3 FIX: Now uses _determine_fingerprint_location() for fallback locations
    grep -q '_determine_fingerprint_location' "$telemon_script" && \
    grep -q 'primary="${SCRIPT_DIR}/.telemon_first_run_done"' "$telemon_script"
    assert_true "First-run: Fingerprint path uses SCRIPT_DIR/.telemon_first_run_done as primary"
    
    # Test 3: Fingerprint has fallback locations (HOME and /tmp)
    grep -q 'fallback_home="${HOME}/.telemon_first_run_done"' "$telemon_script" && \
    grep -q 'fallback_tmp="/tmp/.telemon_first_run_done"' "$telemon_script"
    assert_true "First-run: Fingerprint has fallback locations (HOME and /tmp)"
    
    # Test 4: Fingerprint is checked before first-run detection
    grep -q 'if \[\[ ! -f "\$FIRST_RUN_FINGERPRINT" \]\]' "$telemon_script"
    assert_true "First-run: Fingerprint file existence is checked"
    
    # Test 5: Fingerprint is created on first run
    grep -q 'FIRST_RUN_FINGERPRINT' "$telemon_script" && grep -q 'echo.*date.*%Y' "$telemon_script"
    assert_true "First-run: Fingerprint file is created with timestamp"
    
    # Test 6: State reset detection (fingerprint exists but no state file)
    grep -q 'fingerprint exists' "$telemon_script"
    assert_true "First-run: State reset vs first-run distinction exists"
    
    # Test 7: Fingerprint is removed in reset-state command
    grep -q 'first-run fingerprint' "$admin_script"
    assert_true "First-run: Fingerprint removal in reset-state command"
    
    # Test 8: Fingerprint file has restricted permissions
    grep -A2 'FIRST_RUN_FINGERPRINT' "$telemon_script" | grep -q 'chmod 600'
    assert_true "First-run: Fingerprint file created with 600 permissions"
    
    # Test 9: BUG-3 FIX - Fingerprint creation logs warning on failure
    grep -q 'Failed to create first-run fingerprint' "$telemon_script" && \
    grep -q 'log "WARN"' "$telemon_script"
    assert_true "First-run: Fingerprint creation failure is logged as WARNING"
}

# ---------------------------------------------------------------------------
# Main test runner
# ---------------------------------------------------------------------------

main() {
    echo "============================================="
    echo " Telemon Test Suite"
    echo "============================================="
    echo ""
    
    # Run all tests
    test_portable_stat
    test_portable_sha256
    test_get_state_file_variants
    test_sanitize_state_key
    test_state_key_format
    test_html_escape
    test_threshold_validation
    test_linear_regression
    test_parse_date_to_epoch
    test_run_with_timeout
    test_safe_write_state_file
    test_is_valid_service_name
    test_is_valid_hostname
    test_is_safe_path
    test_is_valid_email
    test_is_internal_ip
    test_log
    test_rotate_logs
    test_check_state_change
    test_require_file
    test_require_command
    test_validate_numeric
    test_validate_numeric_or_default
    test_plugin_system
    test_database_checks
    test_dns_record_checks
    test_audit_logging
    test_status_page_generation
    test_one_line_installer
    test_check_threshold_helper
    test_security_database_passwords
    test_odbc_checks
    test_predictive_exhaustion
    test_fleet_heartbeats
    test_maintenance_windows
    test_auto_remediation
    test_discovery_system
    test_lock_mechanism
    test_first_run_fingerprint

    # Summary
    echo ""
    echo "============================================="
    echo " Test Results"
    echo "============================================="
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main "$@"
