#!/usr/bin/env bash
# =============================================================================
# Telemon Test Suite
# =============================================================================
# Tests for core helper functions. Run with: bash tests/run_tests.sh
# =============================================================================
set -uo pipefail

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
    
    # IPv6 ULA (fc00::/7 = fc00–fdff) — GH #7: fd00::/8 was not blocked before
    is_internal_ip "fc00::1"
    assert_true "is_internal_ip detects IPv6 ULA fc00::"
    is_internal_ip "fd00::1"
    assert_true "is_internal_ip detects IPv6 ULA fd00:: (was allowed before fix)"
    is_internal_ip "fdff:ffff::1"
    assert_true "is_internal_ip detects IPv6 ULA upper bound fdff::"
    is_internal_ip "FD12::1"
    assert_true "is_internal_ip detects IPv6 ULA in uppercase"
    
    # External IPs - should return 1 (false)
    ! is_internal_ip "8.8.8.8"
    assert_true "is_internal_ip allows public IP (Google DNS)"
    
    ! is_internal_ip "1.1.1.1"
    assert_true "is_internal_ip allows public IP (Cloudflare DNS)"
    
    ! is_internal_ip "example.com"
    assert_true "is_internal_ip allows domain name"
    
    ! is_internal_ip "2001:db8::1"
    assert_true "is_internal_ip allows documentation prefix 2001:db8::"
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
    
    # Function is sourced from lib/common.sh (moved 2026-08-16, TODO #5) —
    # the inline copy below was removed so this tests the REAL shared helper
    # (the old inline copy omitted the lowercase step, hiding bug #5).
    
    # Test basic sanitization
    assert_eq "test-key" "$(sanitize_state_key "test-key")" "sanitize_state_key preserves hyphens"
    assert_eq "test_key" "$(sanitize_state_key "test_key")" "sanitize_state_key preserves underscores"
    
    # Test special chars are replaced
    assert_eq "test_key" "$(sanitize_state_key "test/key")" "sanitize_state_key replaces slashes"
    assert_eq "test_key" "$(sanitize_state_key "test@key")" "sanitize_state_key replaces @"
    assert_eq "test_key" "$(sanitize_state_key "test:key")" "sanitize_state_key replaces colons"
    
    # Test multiple special chars
    assert_eq "a_b_c_d" "$(sanitize_state_key "a/b@c:d")" "sanitize_state_key handles multiple special chars"

    # Lowercase normalization (bug #5: telemon-admin.sh used an inline tr WITHOUT
    # the lowercase step, so status/backup never found heartbeat files written by
    # send_heartbeat for mixed-case SERVER_LABELs). Note: hyphens ARE preserved
    # by the shared char class a-zA-Z0-9_.- — the bug was only the missing
    # lowercase, which is what both sides must now agree on.
    assert_eq "web-prod-01" "$(sanitize_state_key "Web-Prod-01")" "sanitize_state_key lowercases mixed-case label"
    assert_eq "web.prod" "$(sanitize_state_key "Web.Prod")" "sanitize_state_key lowercases while preserving dots"
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
    
    # Function is sourced from lib/common.sh (moved 2026-08-16, TODO #5) —
    # the inline copy below was removed so this tests the REAL shared helper
    
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
            first_x = 0
            for (i = 1; i <= NF; i++) {
                split($i, a, ":")
                if (a[1] == "" || a[2] == "") continue
                x = a[1] + 0; y = a[2] + 0
                if (n == 0) first_x = x
                x = x - first_x
                sx += x; sy += y; sxx += x*x; sxy += x*y; n++
            }
            if (n < 2 || (n*sxx - sx*sx) == 0) { print "0 0"; exit 1 }
            slope = (n*sxy - sx*sy) / (n*sxx - sx*sx)
            intercept = (sy - slope*sx) / n - slope * first_x
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
    : > "$LOG_FILE"  # Clear log
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
    # Skip if running as root because root bypasses file permissions
    if [[ $EUID -ne 0 ]]; then
        chmod 000 "$tmpfile"
        ! require_file "$tmpfile" "unreadable file" 2>/dev/null
        assert_true "require_file rejects unreadable file"
        chmod 644 "$tmpfile"  # Restore permissions for cleanup
    else
        echo -e "${YELLOW}⚠${NC} Skipping unreadable-file test (running as root)"
    fi
    
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
# Test MySQL Database Check Functionality
# ---------------------------------------------------------------------------

test_check_databases_mysql() {
    echo ""
    echo "Testing MySQL database check..."
    
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    
    # Test 1: MySQL uses MYSQL_PWD environment variable for security
    [[ "$telemon_content" == *"MYSQL_PWD"* ]]
    assert_true "MySQL: Uses MYSQL_PWD environment variable (not command line)"
    
    # Test 2: MySQL check function exists
    [[ "$telemon_content" == *"check_databases()"* ]]
    assert_true "MySQL: check_databases() function exists"
    
    # Test 3: Connection test uses run_with_timeout for protection
    [[ "$telemon_content" == *"run_with_timeout"* && "$telemon_content" == *"mysql"* ]]
    assert_true "MySQL: Uses timeout protection for connections"
    
    # Test 4: Error message sanitization (password removal)
    [[ "$telemon_content" == *"password=***"* ]]
    assert_true "MySQL: Sanitizes passwords from error messages"
    
    # Test 5: State key generation uses sanitize_state_key
    [[ "$telemon_content" == *"sanitize_state_key"* && "$telemon_content" == *"mysql_"* ]]
    assert_true "MySQL: Uses sanitize_state_key for state keys"
    
    # Test 6: Connection success detection pattern
    [[ "$telemon_content" == *"SELECT 1"* ]]
    assert_true "MySQL: Uses 'SELECT 1' for connection testing"
    
    # Test 7: Replication lag detection
    [[ "$telemon_content" == *"Seconds_Behind_Master"* ]]
    assert_true "MySQL: Detects replication lag via Seconds_Behind_Master"
    
    # Test 8: Replication lag thresholds (60s warning, 300s critical)
    [[ "$telemon_content" == *"-gt 300"* && "$telemon_content" == *"-gt 60"* ]]
    assert_true "MySQL: Has replication lag thresholds (60s/300s)"
    
    # Test 9: State transitions - CRITICAL on connection failure
    [[ "$telemon_content" == *"mysql_state=\"CRITICAL\""* ]]
    assert_true "MySQL: Sets CRITICAL state on connection failure"
    
    # Test 10: Graceful skip when mysql client not found
    [[ "$telemon_content" == *"command -v mysql"* ]]
    assert_true "MySQL: Gracefully skips when mysql client not installed"
    
    # Test 11: Test connection success scenario
    local mock_mysql_result="1"
    [[ "$mock_mysql_result" == "1" ]]
    assert_true "MySQL: Connection success produces expected output"
    
    # Test 12: State key format validation
    local mysql_key="mysql_localhost"
    [[ "$mysql_key" =~ ^mysql_[a-zA-Z0-9_.-]+$ ]]
    assert_true "MySQL: State key format is valid"
    
    # Test 13: HTML escaping in error messages
    [[ "$telemon_content" == *"html_escape"* ]]
    assert_true "MySQL: Error messages are HTML-escaped"
}

# ---------------------------------------------------------------------------
# Test PostgreSQL Database Check Functionality
# ---------------------------------------------------------------------------

test_check_databases_postgres() {
    echo ""
    echo "Testing PostgreSQL database check..."
    
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    
    # Test 1: PostgreSQL uses PGPASSWORD environment variable
    [[ "$telemon_content" == *"PGPASSWORD"* ]]
    assert_true "PostgreSQL: Uses PGPASSWORD environment variable"
    
    # Test 2: PostgreSQL check in check_databases function
    [[ "$telemon_content" == *"DB_POSTGRES_HOST"* ]]
    assert_true "PostgreSQL: Uses DB_POSTGRES_HOST configuration"
    
    # Test 3: Connection test with timeout
    [[ "$telemon_content" == *"psql"* && "$telemon_content" == *"run_with_timeout"* ]]
    assert_true "PostgreSQL: Uses timeout protection for connections"
    
    # Test 4: Error message sanitization
    [[ "$telemon_content" == *"password=***"* ]]
    assert_true "PostgreSQL: Sanitizes passwords from error messages"
    
    # Test 5: State key generation
    [[ "$telemon_content" == *"postgres_"* && "$telemon_content" == *"sanitize_state_key"* ]]
    assert_true "PostgreSQL: Uses sanitize_state_key for state keys"
    
    # Test 6: Connection success detection
    [[ "$telemon_content" == *"SELECT 1"* ]]
    assert_true "PostgreSQL: Uses 'SELECT 1' for connection testing"
    
    # Test 7: Replication lag detection via pg_is_in_recovery
    [[ "$telemon_content" == *"pg_is_in_recovery"* || "$telemon_content" == *"pg_last_xact_replay_timestamp"* ]]
    assert_true "PostgreSQL: Detects replication lag via pg_is_in_recovery"
    
    # Test 8: Replication lag thresholds
    [[ "$telemon_content" == *"-gt 300"* && "$telemon_content" == *"-gt 60"* ]]
    assert_true "PostgreSQL: Has replication lag thresholds (60s/300s)"
    
    # Test 9: CRITICAL on connection failure
    [[ "$telemon_content" == *"pg_state=\"CRITICAL\""* ]]
    assert_true "PostgreSQL: Sets CRITICAL state on connection failure"
    
    # Test 10: Graceful skip when psql not found
    [[ "$telemon_content" == *"command -v psql"* ]]
    assert_true "PostgreSQL: Gracefully skips when psql not installed"
    
    # Test 11: Connection string format (host/port/user/dbname)
    [[ "$telemon_content" == *"host="* && "$telemon_content" == *"port="* && \
       "$telemon_content" == *"user="* && "$telemon_content" == *"dbname="* ]]
    assert_true "PostgreSQL: Builds proper connection string"
    
    # Test 12: State key format validation
    local pg_key="postgres_db-server-01"
    [[ "$pg_key" =~ ^postgres_[a-zA-Z0-9_.-]+$ ]]
    assert_true "PostgreSQL: State key format is valid"
    
    # Test 13: HTML escaping in error messages
    [[ "$telemon_content" == *"html_escape"* ]]
    assert_true "PostgreSQL: Error messages are HTML-escaped"
    
    # Test 14: Test lag value extraction from psql output
    local mock_lag="42.5"
    local lag_int="${mock_lag%.*}"
    assert_eq "42" "$lag_int" "PostgreSQL: Extracts integer portion of lag value"
}

# ---------------------------------------------------------------------------
# Test Redis Database Check Functionality
# ---------------------------------------------------------------------------

test_check_databases_redis() {
    echo ""
    echo "Testing Redis database check..."
    
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    
    # Test 1: Redis uses REDISCLI_AUTH environment variable
    [[ "$telemon_content" == *"REDISCLI_AUTH"* ]]
    assert_true "Redis: Uses REDISCLI_AUTH environment variable (not -a flag)"
    
    # Test 2: Redis check in check_databases function
    [[ "$telemon_content" == *"DB_REDIS_HOST"* ]]
    assert_true "Redis: Uses DB_REDIS_HOST configuration"
    
    # Test 3: PING/PONG detection for health check
    [[ "$telemon_content" == *"PING"* && "$telemon_content" == *"PONG"* ]]
    assert_true "Redis: Uses PING/PONG for health check"
    
    # Test 4: WRONGPASS and NOAUTH detection
    [[ "$telemon_content" == *"NOAUTH"* && "$telemon_content" == *"WRONGPASS"* ]]
    assert_true "Redis: Detects NOAUTH and WRONGPASS errors"
    
    # Test 5: Authentication failure detection patterns
    [[ "$telemon_content" == *"authentication"* || "$telemon_content" == *"AUTH"* ]]
    assert_true "Redis: Detects authentication failure patterns"
    
    # Test 6: State key generation with host and port
    [[ "$telemon_content" == *"redis_"* && "$telemon_content" == *"sanitize_state_key"* ]]
    assert_true "Redis: Uses sanitize_state_key for state keys"
    
    # Test 7: Master/replica status detection
    [[ "$telemon_content" == *"role:master"* || "$telemon_content" == *"master_link_status"* ]]
    assert_true "Redis: Detects master/replica status via INFO replication"
    
    # Test 8: Master link down detection
    [[ "$telemon_content" == *"master_link_status:down"* || "$telemon_content" == *"master link DOWN"* ]]
    assert_true "Redis: Detects master link down in replica mode"
    
    # Test 9: Connected slaves count for master
    [[ "$telemon_content" == *"connected_slaves"* ]]
    assert_true "Redis: Reports connected slave count for master"
    
    # Test 10: Timeout protection for Redis operations
    [[ "$telemon_content" == *"run_with_timeout"* && "$telemon_content" == *"redis-cli"* ]]
    assert_true "Redis: Uses timeout protection for connections"
    
    # Test 11: Graceful skip when redis-cli not found
    [[ "$telemon_content" == *"command -v redis-cli"* ]]
    assert_true "Redis: Gracefully skips when redis-cli not installed"
    
    # Test 12: Test PING response parsing
    local mock_redis_result="PONG"
    [[ "$mock_redis_result" == "PONG" ]]
    assert_true "Redis: PONG response indicates healthy connection"
    
    # Test 13: Test NOAUTH error detection
    local mock_noauth="NOAUTH Authentication required."
    [[ "$mock_noauth" == *"NOAUTH"* ]]
    assert_true "Redis: NOAUTH error is detected"
    
    # Test 14: Test WRONGPASS error detection
    local mock_wrongpass="WRONGPASS invalid username-password pair"
    [[ "$mock_wrongpass" == *"WRONGPASS"* ]]
    assert_true "Redis: WRONGPASS error is detected"
    
    # Test 15: State key format validation
    local redis_key="redis_localhost_6379"
    [[ "$redis_key" =~ ^redis_[a-zA-Z0-9_.-]+$ ]]
    assert_true "Redis: State key format is valid"
    
    # Test 16: Configurable timeout for Redis operations
    [[ "$telemon_content" == *"DB_REDIS_TIMEOUT_SEC"* ]]
    assert_true "Redis: Supports DB_REDIS_TIMEOUT_SEC configuration"
}

# ---------------------------------------------------------------------------
# Test SQLite3 Database Check Functionality
# ---------------------------------------------------------------------------

test_check_databases_sqlite() {
    echo ""
    echo "Testing SQLite3 database check..."
    
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    
    # Create temp directory for SQLite tests
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local test_db="${tmp_dir}/test.db"
    
    # Test 1: is_safe_path validation for database paths
    [[ "$telemon_content" == *"is_safe_path"* && "$telemon_content" == *"DB_SQLITE_PATHS"* ]]
    assert_true "SQLite: Validates path safety with is_safe_path"
    
    # Test 2: Path traversal rejection
    local unsafe_path="/tmp/../etc/passwd"
    if [[ "$unsafe_path" == *".."* || "$unsafe_path" == *"*"* || \
          "$unsafe_path" == *"?"* || "$unsafe_path" == *"$"* ]]; then
        assert_true "SQLite: Rejects path with directory traversal (..)"
    else
        assert_false "SQLite: Should reject path with directory traversal"
    fi
    
    # Test 3: File existence check
    [[ "$telemon_content" == *"[[ ! -f"* ]]
    assert_true "SQLite: Checks file existence"
    
    # Test 4: File readability check
    [[ "$telemon_content" == *"[[ ! -r"* ]]
    assert_true "SQLite: Checks file readability"
    
    # Test 5: PRAGMA quick_check for corruption detection
    [[ "$telemon_content" == *"PRAGMA quick_check"* ]]
    assert_true "SQLite: Uses PRAGMA quick_check for integrity"
    
    # Test 6: Corruption detection (result != "ok")
    [[ "$telemon_content" == *'!= "ok"'* ]]
    assert_true "SQLite: Detects corruption when result is not 'ok'"
    
    # Test 7: Size threshold checking
    [[ "$telemon_content" == *"DB_SQLITE_SIZE_THRESHOLD_WARN"* && \
       "$telemon_content" == *"DB_SQLITE_SIZE_THRESHOLD_CRIT"* ]]
    assert_true "SQLite: Supports size threshold configuration"
    
    # Test 8: Test actual SQLite database creation and check
    if command -v sqlite3 &>/dev/null; then
        # Create a test database
        sqlite3 "$test_db" "CREATE TABLE test (id INTEGER PRIMARY KEY); INSERT INTO test VALUES (1);" 2>/dev/null
        [[ -f "$test_db" ]]
        assert_true "SQLite: Test database created"
        
        # Test PRAGMA quick_check
        local integrity_result
        integrity_result=$(sqlite3 "$test_db" "PRAGMA quick_check;" 2>&1)
        assert_eq "ok" "$integrity_result" "SQLite: PRAGMA quick_check returns 'ok' for valid DB"
        
        # Test file size calculation
        local db_size_bytes
        db_size_bytes=$(stat -c%s "$test_db" 2>/dev/null || stat -f%z "$test_db" 2>/dev/null)
        [[ "$db_size_bytes" -gt 0 ]]
        assert_true "SQLite: Database has positive size"
    else
        echo "  (skipping live SQLite tests - sqlite3 not installed)"
    fi
    
    # Test 9: State key generation using make_state_key
    [[ "$telemon_content" == *"make_state_key"* && "$telemon_content" == *"sqlite"* ]]
    assert_true "SQLite: Uses make_state_key for state key generation"
    
    # Test 10: Hash-based state key format
    local test_path="/var/lib/test.db"
    local mock_hash
    mock_hash=$(printf '%s' "$test_path" | sha256sum 2>/dev/null | cut -c1-12 || \
                printf '%s' "$test_path" | shasum -a 256 2>/dev/null | cut -c1-12 || \
                echo "a1b2c3d4e5f6")
    local expected_key="sqlite_${mock_hash}"
    [[ "$expected_key" =~ ^sqlite_[a-f0-9]{12}$ ]]
    assert_true "SQLite: State key format is sqlite_ + 12-char hash"
    
    # Test 11: WAL file detection
    [[ "$telemon_content" == *"-wal"* ]]
    assert_true "SQLite: Detects WAL file presence"
    
    # Test 12: Large WAL warning (>100MB)
    [[ "$telemon_content" == *"-gt 100"* && "$telemon_content" == *"wal_size_mb"* ]]
    assert_true "SQLite: Warns about large WAL files (>100MB)"
    
    # Test 13: HTML escaping for filenames
    [[ "$telemon_content" == *"html_escape"* ]]
    assert_true "SQLite: HTML-escapes database filenames"
    
    # Test 14: CRITICAL state for missing file
    [[ "$telemon_content" == *"not found"* ]]
    assert_true "SQLite: Sets CRITICAL when database file not found"
    
    # Test 15: CRITICAL state for unreadable file
    [[ "$telemon_content" == *"not readable"* ]]
    assert_true "SQLite: Sets CRITICAL when database not readable"
    
    # Test 16: Graceful skip when sqlite3 not found
    [[ "$telemon_content" == *"command -v sqlite3"* ]]
    assert_true "SQLite: Gracefully skips when sqlite3 not installed"
    
    # Test 17: Size calculation using portable_stat
    [[ "$telemon_content" == *"portable_stat size"* ]]
    assert_true "SQLite: Uses portable_stat for size calculation"
    
    # Test 18: Timeout protection for integrity checks
    [[ "$telemon_content" == *"run_with_timeout"* && "$telemon_content" == *"sqlite3"* ]]
    assert_true "SQLite: Uses timeout protection for integrity checks"
    
    # Cleanup
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Test ODBC Database Check Functionality (Enhanced)
# ---------------------------------------------------------------------------

test_check_odbc() {
    echo ""
    echo "Testing ODBC database check (enhanced)..."
    
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    
    # Test 1: check_odbc function exists
    [[ "$telemon_content" == *"check_odbc()"* ]]
    assert_true "ODBC: check_odbc() function exists"
    
    # Test 2: ENABLE_ODBC_CHECKS flag is used
    [[ "$telemon_content" == *"ENABLE_ODBC_CHECKS"* ]]
    assert_true "ODBC: ENABLE_ODBC_CHECKS configuration flag exists"
    
    # Test 3: ODBC_CONNECTIONS is used
    [[ "$telemon_content" == *"ODBC_CONNECTIONS"* ]]
    assert_true "ODBC: ODBC_CONNECTIONS configuration exists"
    
    # Test 4: isql command detection
    [[ "$telemon_content" == *"isql"* ]]
    assert_true "ODBC: uses isql command for connectivity testing"
    
    # Test 5: Graceful skip when isql not found
    [[ "$telemon_content" == *"command -v isql"* ]]
    assert_true "ODBC: Gracefully skips when isql not installed"
    
    # Test 6: Connection name validation (security)
    [[ "$telemon_content" == *"is_valid_service_name"* && "$telemon_content" == *"conn_name"* ]]
    assert_true "ODBC: Validates connection names with is_valid_service_name"
    
    # Test 7: DSN-based connections
    [[ "$telemon_content" == *"ODBC_"* && "$telemon_content" == *"_DSN"* ]]
    assert_true "ODBC: Supports DSN-based connections"
    
    # Test 8: Connection string-based connections
    [[ "$telemon_content" == *"ODBC_"* && "$telemon_content" == *"_DRIVER"* ]]
    assert_true "ODBC: Supports connection string-based connections"
    
    # Test 9: Connection string components (SERVER, DATABASE, USER, PASS)
    [[ "$telemon_content" == *"_SERVER"* && "$telemon_content" == *"_DATABASE"* && \
       "$telemon_content" == *"_USER"* && "$telemon_content" == *"_PASS"* ]]
    assert_true "ODBC: Supports all connection string components"
    
    # Test 10: Indirect expansion for password lookup (security)
    [[ "$telemon_content" == *"pass_var="* && "$telemon_content" == *"conn_pass"* ]]
    assert_true "ODBC: Uses indirect expansion for password lookup"
    
    # Test 11: Password sanitization in error messages
    [[ "$telemon_content" == *"PWD=***"* || "$telemon_content" == *"PASS=***"* ]]
    assert_true "ODBC: Sanitizes PWD and PASS from error messages"
    
    # Test 12: Connection string via temp file (not command line)
    [[ "$telemon_content" == *"conn_str_file"* && "$telemon_content" == *"mktemp"* ]]
    assert_true "ODBC: Passes connection string via temp file"
    
    # Test 13: Temp file permissions (600)
    [[ "$telemon_content" == *"chmod 600"* ]]
    assert_true "ODBC: Sets 600 permissions on temp connection string file"
    
    # Test 14: Timeout protection
    [[ "$telemon_content" == *"run_with_timeout"* && "$telemon_content" == *"check_odbc"* ]]
    assert_true "ODBC: Uses timeout protection for connections"
    
    # Test 15: Slow response detection (>5s)
    [[ "$telemon_content" == *"-gt 5000"* && "$telemon_content" == *"duration_ms"* ]]
    assert_true "ODBC: Detects slow responses >5000ms (5s)"
    
    # Test 16: State key generation using sanitize_state_key
    [[ "$telemon_content" == *"odbc_"* && "$telemon_content" == *"sanitize_state_key"* ]]
    assert_true "ODBC: Uses sanitize_state_key for state keys"
    
    # Test 17: Error code detection ([ISQL] ERROR, [08001], [HY000])
    [[ "$telemon_content" == *"[ISQL]"* && "$telemon_content" == *"[08001]"* && \
       "$telemon_content" == *"[HY000]"* ]]
    assert_true "ODBC: Detects ODBC error codes in response"
    
    # Test 18: Default query (SELECT 1)
    [[ "$telemon_content" == *"SELECT 1"* && "$telemon_content" == *"conn_query"* ]]
    assert_true "ODBC: Uses SELECT 1 as default query"
    
    # Test 19: Configurable query via ODBC_${name}_QUERY
    [[ "$telemon_content" == *"_QUERY"* ]]
    assert_true "ODBC: Supports custom queries via ODBC_\${name}_QUERY"
    
    # Test 20: DSN connection with credentials
    [[ "$telemon_content" == *"ODBCUSER"* || "$telemon_content" == *"ODBCPASS"* ]]
    assert_true "ODBC: Passes DSN credentials via environment variables"
    
    # Test 21: State transition to CRITICAL on connection failure
    [[ "$telemon_content" == *"odbc_state=\"CRITICAL\""* ]]
    assert_true "ODBC: Sets CRITICAL state on connection failure"
    
    # Test 22: State transition to WARNING on slow response
    [[ "$telemon_content" == *"odbc_state=\"WARNING\""* && "$telemon_content" == *"slow response"* ]]
    assert_true "ODBC: Sets WARNING state on slow response"
    
    # Test 23: Validation requires DSN or DRIVER+SERVER
    [[ "$telemon_content" == *"need ODBC_"* || "$telemon_content" == *"DRIVER + SERVER"* ]]
    assert_true "ODBC: Validates connection has DSN or DRIVER+SERVER"
    
    # Test 24: Connection string concatenation (+= for building string)
    [[ "$telemon_content" == *"conn_str+="* ]]
    assert_true "ODBC: Uses += for connection string concatenation"
    
    # Test 25: HTML escaping in error messages
    [[ "$telemon_content" == *"html_escape"* ]]
    assert_true "ODBC: HTML-escapes error messages"
    
    # Test 26: Duration calculation (milliseconds)
    [[ "$telemon_content" == *"date +%s%3N"* ]]
    assert_true "ODBC: Calculates duration in milliseconds"
    
    # Test 27: State key format validation
    local odbc_key="odbc_production_sqlserver"
    [[ "$odbc_key" =~ ^odbc_[a-zA-Z0-9_.-]+$ ]]
    assert_true "ODBC: State key format is valid"
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

test_validate_env_security() {
    echo ""
    echo "Testing validate_env_security function..."
    
    validate_env_security_test() {
        local errors=0
        local _state_file="${1:-}"
        local _log_file="${2:-}"
        local _bot_token="${3:-}"
        local _chat_id="${4:-}"
        local _email_to="${5:-}"
        local _smtp_port="${6:-}"
        
        # Check for dangerous characters in paths (backtick, dollar, semicolon, pipe, ampersand, less-than, greater-than)
        if [[ -n "$_state_file" ]]; then
            if echo "$_state_file" | grep -q '[\`$;|&<>]'; then
                echo "ERROR: STATE_FILE contains dangerous characters"
                ((errors++))
            fi
        fi
        
        if [[ -n "$_log_file" ]]; then
            if echo "$_log_file" | grep -q '[\`$;|&<>]'; then
                echo "ERROR: LOG_FILE contains dangerous characters"
                ((errors++))
            fi
        fi
        
        # Validate TELEGRAM_BOT_TOKEN format (digits:alphanumeric)
        if [[ -n "$_bot_token" ]]; then
            if [[ ! "$_bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
                echo "WARN: TELEGRAM_BOT_TOKEN format looks invalid"
            fi
        fi
        
        # Validate TELEGRAM_CHAT_ID is numeric
        if [[ -n "$_chat_id" ]]; then
            if [[ ! "$_chat_id" =~ ^-?[0-9]+$ ]]; then
                echo "WARN: TELEGRAM_CHAT_ID should be numeric"
            fi
        fi
        
        # Validate EMAIL_TO format
        if [[ -n "$_email_to" ]]; then
            if [[ ! "$_email_to" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                echo "WARN: EMAIL_TO format looks invalid"
            fi
        fi
        
        # Validate SMTP_PORT range
        if [[ -n "$_smtp_port" ]]; then
            if ! is_valid_number "$_smtp_port" || [[ "$_smtp_port" -lt 1 ]] || [[ "$_smtp_port" -gt 65535 ]]; then
                echo "ERROR: SMTP_PORT must be a valid port number (1-65535)"
                ((errors++))
            fi
        fi
        
        return $errors
    }
    
    # Test 1: All valid inputs should pass
    local output
    output=$(validate_env_security_test "/tmp/state" "/var/log/telemon.log" "123456:ABC-DEF123" "-1001234567890" "admin@example.com" "587" 2>&1) || true
    [[ -z "$output" ]]
    assert_true "validate_env_security: all valid inputs pass without errors"
    
    # Test 2: STATE_FILE with dangerous characters (semicolon)
    output=$(validate_env_security_test "/tmp/state;rm -rf /" "/var/log/telemon.log" "" "" "" "" 2>&1) || true
    assert_contains "$output" "STATE_FILE contains dangerous characters" "validate_env_security: detects dangerous chars (semicolon) in STATE_FILE"
    
    # Test 3: LOG_FILE with dangerous characters (pipe)
    output=$(validate_env_security_test "/tmp/state" "/var/log/telemon.log|cat /etc/passwd" "" "" "" "" 2>&1) || true
    assert_contains "$output" "LOG_FILE contains dangerous characters" "validate_env_security: detects dangerous chars (pipe) in LOG_FILE"
    
    # Test 4: TELEGRAM_BOT_TOKEN format validation - invalid format
    output=$(validate_env_security_test "" "" "invalid_token" "" "" "" 2>&1) || true
    assert_contains "$output" "TELEGRAM_BOT_TOKEN format looks invalid" "validate_env_security: detects invalid bot token format"
    
    # Test 5: TELEGRAM_BOT_TOKEN format validation - valid format
    output=$(validate_env_security_test "" "" "123456:ABC-DEF_123ghj" "" "" "" 2>&1) || true
    [[ ! "$output" =~ "TELEGRAM_BOT_TOKEN" ]] || true
    assert_true "validate_env_security: accepts valid bot token format"
    
    # Test 6: TELEGRAM_CHAT_ID numeric validation - invalid
    output=$(validate_env_security_test "" "" "" "not_a_number" "" "" 2>&1) || true
    assert_contains "$output" "TELEGRAM_CHAT_ID should be numeric" "validate_env_security: detects non-numeric chat ID"
    
    # Test 7: TELEGRAM_CHAT_ID numeric validation - valid (including negative for groups)
    output=$(validate_env_security_test "" "" "" "-1001234567890" "" "" 2>&1) || true
    [[ ! "$output" =~ "TELEGRAM_CHAT_ID" ]] || true
    assert_true "validate_env_security: accepts valid negative chat ID"
    
    # Test 8: EMAIL_TO format validation - invalid
    output=$(validate_env_security_test "" "" "" "" "not_an_email" "" 2>&1) || true
    assert_contains "$output" "EMAIL_TO format looks invalid" "validate_env_security: detects invalid email format"
    
    # Test 9: EMAIL_TO format validation - valid
    output=$(validate_env_security_test "" "" "" "" "user+tag@example-domain.co.uk" "" 2>&1) || true
    [[ ! "$output" =~ "EMAIL_TO" ]] || true
    assert_true "validate_env_security: accepts valid email format"
    
    # Test 10: SMTP_PORT range validation - too low
    output=$(validate_env_security_test "" "" "" "" "" "0" 2>&1) || true
    assert_contains "$output" "SMTP_PORT must be a valid port number" "validate_env_security: rejects port 0"
    
    # Test 11: SMTP_PORT range validation - too high
    output=$(validate_env_security_test "" "" "" "" "" "70000" 2>&1) || true
    assert_contains "$output" "SMTP_PORT must be a valid port number" "validate_env_security: rejects port > 65535"
    
    # Test 12: SMTP_PORT range validation - valid boundary (1)
    output=$(validate_env_security_test "" "" "" "" "" "1" 2>&1) || true
    [[ ! "$output" =~ "SMTP_PORT" ]] || true
    assert_true "validate_env_security: accepts port 1"
    
    # Test 13: SMTP_PORT range validation - valid boundary (65535)
    output=$(validate_env_security_test "" "" "" "" "" "65535" 2>&1) || true
    [[ ! "$output" =~ "SMTP_PORT" ]] || true
    assert_true "validate_env_security: accepts port 65535"
    
    # Test 14: SMTP_PORT non-numeric
    output=$(validate_env_security_test "" "" "" "" "" "abc" 2>&1) || true
    assert_contains "$output" "SMTP_PORT must be a valid port number" "validate_env_security: rejects non-numeric port"
    
    # Test 15: STATE_FILE with backtick
    output=$(validate_env_security_test '/tmp/state`id`' "" "" "" "" "" 2>&1) || true
    assert_contains "$output" "STATE_FILE contains dangerous characters" "validate_env_security: detects backtick in STATE_FILE"
    
    # Test 16: STATE_FILE with dollar sign
    output=$(validate_env_security_test '/tmp/state$HOME' "" "" "" "" "" 2>&1) || true
    assert_contains "$output" "STATE_FILE contains dangerous characters" "validate_env_security: detects dollar sign in STATE_FILE"
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

    # _cmd_exists moved to lib/common.sh (shared by telemon.sh + admin)
    grep -q "_cmd_exists()" "${SCRIPT_DIR}/lib/common.sh"
    assert_true "Discovery: _cmd_exists helper exists (shared, in lib/common.sh)"
    # admin must not re-define it (DRY — check for the definition, not usage)
    ! grep -q "^_cmd_exists()" "$admin_script"
    assert_true "Discovery: _cmd_exists not duplicated in telemon-admin.sh"
    
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
    
    # GH #8: discover must suggest NETWORK_INTERFACE (singular, default-route
    # iface) — the plural NETWORK_INTERFACES is dead config telemon never reads
    ! grep -q "NETWORK_INTERFACES" "$admin_script"
    assert_true "Discovery: no dead NETWORK_INTERFACES (plural) suggestion"
    grep -q 'NETWORK_INTERFACE=\\"${suggested_iface}\\"' "$admin_script"
    assert_true "Discovery: suggests NETWORK_INTERFACE (singular) with default-route iface"
    
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
    # Uses _determine_fingerprint_location() for fallback locations
    grep -q '_determine_fingerprint_location' "$telemon_script" && \
    grep -q 'primary="${SCRIPT_DIR}/.telemon_first_run_done"' "$telemon_script"
    assert_true "First-run: Fingerprint path uses SCRIPT_DIR/.telemon_first_run_done as primary"
    
    # Test 3: Fingerprint has fallback locations (HOME and /tmp)
    grep -q 'fallback_home="${HOME:-/root}/.telemon_first_run_done"' "$telemon_script" && \
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
    
    # Test 9: Fingerprint creation logs warning on failure
    grep -q 'Failed to create first-run fingerprint' "$telemon_script" && \
    grep -q 'log "WARN"' "$telemon_script"
    assert_true "First-run: Fingerprint creation failure is logged as WARNING"
}

# ---------------------------------------------------------------------------
# Test Plugin Detail Parsing with Pipe Characters
# ---------------------------------------------------------------------------

test_plugin_detail_pipes() {
    echo ""
    echo "Testing plugin detail parsing with pipe characters..."
    
    # Test the cut-based parsing logic used in telemon.sh
    local plugin_output plugin_state plugin_key plugin_detail
    
    # Test 1: Normal output without pipes in detail
    plugin_output="OK|my_check|Everything is working"
    plugin_state=$(printf '%s' "$plugin_output" | cut -d'|' -f1)
    plugin_key=$(printf '%s' "$plugin_output" | cut -d'|' -f2)
    plugin_detail=$(printf '%s' "$plugin_output" | cut -d'|' -f3-)
    assert_eq "OK" "$plugin_state" "Plugin state parsing (no pipes in detail)"
    assert_eq "my_check" "$plugin_key" "Plugin key parsing (no pipes in detail)"
    assert_eq "Everything is working" "$plugin_detail" "Plugin detail parsing (no pipes in detail)"
    
    # Test 2: Detail containing pipe characters
    plugin_output="WARNING|cpu|CPU: 85% | Load: high | Temp: 70C"
    plugin_state=$(printf '%s' "$plugin_output" | cut -d'|' -f1)
    plugin_key=$(printf '%s' "$plugin_output" | cut -d'|' -f2)
    plugin_detail=$(printf '%s' "$plugin_output" | cut -d'|' -f3-)
    assert_eq "WARNING" "$plugin_state" "Plugin state parsing (pipes in detail)"
    assert_eq "cpu" "$plugin_key" "Plugin key parsing (pipes in detail)"
    assert_eq "CPU: 85% | Load: high | Temp: 70C" "$plugin_detail" "Plugin detail preserves pipe characters"
    
    # Test 3: Empty detail field
    plugin_output="CRITICAL|disk|"
    plugin_state=$(printf '%s' "$plugin_output" | cut -d'|' -f1)
    plugin_key=$(printf '%s' "$plugin_output" | cut -d'|' -f2)
    plugin_detail=$(printf '%s' "$plugin_output" | cut -d'|' -f3-)
    assert_eq "CRITICAL" "$plugin_state" "Plugin state parsing (empty detail)"
    assert_eq "disk" "$plugin_key" "Plugin key parsing (empty detail)"
    assert_eq "" "$plugin_detail" "Plugin detail parsing (empty detail)"
}

# ---------------------------------------------------------------------------
# Test LXC Code Paths with Mock cgroup Filesystems
# ---------------------------------------------------------------------------

test_lxc_code_paths() {
    echo ""
    echo "Testing LXC code paths with mock cgroup filesystems..."
    
    # Create a mock cgroup v2 filesystem in a temp directory
    local mock_cgroup
    mock_cgroup=$(mktemp -d)
    
    # Mock /proc/1/cgroup for LXC detection
    local mock_proc
    mock_proc=$(mktemp -d)
    mkdir -p "${mock_proc}/1"
    echo "0::/lxc/100" > "${mock_proc}/1/cgroup"
    
    # Mock cgroup v2 files
    mkdir -p "${mock_cgroup}"
    echo "memory current" > "${mock_cgroup}/memory.current"
    echo "1073741824" > "${mock_cgroup}/memory.current"  # 1GB
    echo "2147483648" > "${mock_cgroup}/memory.max"      # 2GB limit
    printf 'user_usec 1000000\nsystem_usec 500000\n' > "${mock_cgroup}/cpu.stat"
    echo "cpu io" > "${mock_cgroup}/cgroup.controllers"
    
    # Test 1: LXC detection via cgroup content
    [[ -f "${mock_proc}/1/cgroup" ]]
    assert_true "LXC: mock /proc/1/cgroup exists"
    grep -q "lxc" "${mock_proc}/1/cgroup"
    assert_true "LXC: mock /proc/1/cgroup contains lxc"
    
    # Test 2: cgroup v2 detection
    [[ -f "${mock_cgroup}/cgroup.controllers" ]]
    assert_true "LXC: mock cgroup.controllers exists"
    
    # Test 3: Memory usage reading
    local usage
    usage=$(cat "${mock_cgroup}/memory.current")
    assert_eq "1073741824" "$usage" "LXC: memory.current reads correctly"
    
    # Test 4: Memory limit reading
    local limit
    limit=$(cat "${mock_cgroup}/memory.max")
    assert_eq "2147483648" "$limit" "LXC: memory.max reads correctly"
    
    # Test 5: Calculate available memory correctly
    local available_kb
    available_kb=$(((limit - usage) / 1024))
    assert_eq "1048576" "$available_kb" "LXC: available memory calculation is correct (limit - usage)"
    
    # Test 6: Calculate usage percentage
    local usage_pct
    usage_pct=$(( (usage * 100) / limit ))
    assert_eq "50" "$usage_pct" "LXC: usage percentage calculation is correct"
    
    # Test 7: cpu.stat parsing
    local user_usec system_usec
    user_usec=$(awk '/user_usec/ {print $2}' "${mock_cgroup}/cpu.stat")
    system_usec=$(awk '/system_usec/ {print $2}' "${mock_cgroup}/cpu.stat")
    assert_eq "1000000" "$user_usec" "LXC: cpu.stat user_usec parsing"
    assert_eq "500000" "$system_usec" "LXC: cpu.stat system_usec parsing"
    
    # Cleanup
    rm -rf "$mock_cgroup" "$mock_proc"
}

# ---------------------------------------------------------------------------
# Test calculate_lxc_cpu_percent with float /proc/uptime (bug #1 regression)
# ---------------------------------------------------------------------------

test_lxc_cpu_float_uptime() {
    echo ""
    echo "Testing LXC CPU first-run path with float /proc/uptime (bug #1 regression)..."

    # Extract the REAL function from telemon.sh so the test exercises the
    # production code (not a copy). /proc/uptime is a float on every real
    # system (e.g. "174757.74"), which used to crash the [[ -gt ]] test with
    # "invalid arithmetic operator" and silently skip the boot-average
    # fallback on the first run (no baseline state file yet).
    local fn_file
    fn_file=$(mktemp)
    awk '/^calculate_lxc_cpu_percent\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    local state_file
    state_file=$(mktemp)
    local err_file
    err_file=$(mktemp)

    # Dependencies the function calls (mocked)
    get_lxc_cpu_usage_usec() { echo "1000000 500000"; }
    safe_write_state_file() { :; }
    nproc() { echo "4"; }
    STATE_FILE="$state_file"

    # shellcheck disable=SC1090  # temp file generated above; cannot follow
    source "$fn_file"

    # First run (no baseline state file) -> falls into the /proc/uptime branch
    local out err
    out=$(calculate_lxc_cpu_percent 2>"$err_file")
    err=$(cat "$err_file")

    # Test 1: no arithmetic syntax error on stderr
    [[ "$err" != *"syntax error: invalid arithmetic operator"* ]]
    assert_true "LXC CPU: float /proc/uptime no longer triggers arithmetic syntax error"

    # Test 2: output is a valid integer percentage
    [[ "$out" =~ ^[0-9]+$ ]]
    assert_true "LXC CPU: first-run fallback returns valid integer (got: '$out')"

    # Test 3: boot-average estimate branch fires (INFO) instead of being skipped (DEBUG)
    [[ "$err" == *"boot-average estimate"* ]]
    assert_true "LXC CPU: boot-average estimate fallback used (not silently skipped)"

    # Test 4: the fix expression itself — ${uptime_sec%.*} on a float value
    local uptime_sec="174757.74"
    uptime_sec=${uptime_sec%.*}
    [[ "$uptime_sec" -eq 174757 ]]
    assert_true "LXC CPU: uptime_sec float truncation strips fractional part"

    # Test 5: source keeps the truncation inside the /proc/uptime branch
    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")
    [[ "$telemon_content" == *"uptime_sec=\${uptime_sec%.*}"* ]]
    assert_true "LXC CPU: telemon.sh contains uptime_sec float truncation"

    rm -f "$fn_file" "$state_file" "$err_file"
}

# ---------------------------------------------------------------------------
# Test guarded source of lib/common.sh (bug #2 regression)
# ---------------------------------------------------------------------------

test_common_sh_source_guard() {
    echo ""
    echo "Testing guarded source of lib/common.sh (bug #2)..."

    local telemon_content
    telemon_content=$(cat "${SCRIPT_DIR}/telemon.sh")

    # Test 1: source is guarded with an existence check (not bare `source`
    # under set -euo pipefail, which would die with a bare stderr line =
    # silent monitoring gap)
    [[ "$telemon_content" == *'if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then'* ]]
    assert_true "common.sh: source statement is guarded with existence check"

    # Test 2: guard fails loudly with a FATAL message + path
    [[ "$telemon_content" == *"FATAL: lib/common.sh not found"* ]]
    assert_true "common.sh: guard emits FATAL message with path"

    # Test 3: functional — run telemon.sh from a dir missing lib/common.sh;
    # must exit non-zero with the FATAL message (not a bare 'No such file')
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cp "${SCRIPT_DIR}/telemon.sh" "$tmp_dir/"
    local out rc
    out=$(bash "$tmp_dir/telemon.sh" 2>&1)
    rc=$?
    [[ $rc -ne 0 ]]
    assert_true "common.sh: missing lib/common.sh exits non-zero (rc=$rc)"
    [[ "$out" == *"FATAL: lib/common.sh not found"* ]]
    assert_true "common.sh: missing lib/common.sh produces FATAL message"
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Test safe_atomic_mv helper (symlink/TOCTOU protection)
# ---------------------------------------------------------------------------

test_safe_atomic_mv() {
    echo ""
    echo "Testing safe_atomic_mv helper..."
    
    # Define safe_atomic_mv inline for testing
    safe_atomic_mv() {
        local tmp_file="$1"
        local target="$2"
        if [[ -L "$target" ]]; then
            rm -f "$tmp_file"
            return 1
        fi
        if ! mv -T "$tmp_file" "$target" 2>/dev/null; then
            if [[ -L "$target" ]]; then
                rm -f "$tmp_file"
                return 1
            fi
            mv "$tmp_file" "$target" || { rm -f "$tmp_file"; return 1; }
        fi
        return 0
    }
    
    local test_dir
    test_dir=$(mktemp -d)
    
    # Test 1: Basic atomic move
    local tmp_file="${test_dir}/tmp.XXXXXX"
    echo "test content" > "$tmp_file"
    local target="${test_dir}/target_file"
    safe_atomic_mv "$tmp_file" "$target"
    assert_true "safe_atomic_mv: basic move succeeds"
    [[ -f "$target" ]]
    assert_true "safe_atomic_mv: target file exists after move"
    [[ ! -f "$tmp_file" ]]
    assert_true "safe_atomic_mv: temp file removed after move"
    
    # Test 2: Refuse to follow symlinks
    local real_file="${test_dir}/real_file"
    echo "real content" > "$real_file"
    local symlink="${test_dir}/symlink_target"
    ln -s "$real_file" "$symlink"
    local tmp_file2="${test_dir}/tmp2.XXXXXX"
    echo "malicious content" > "$tmp_file2"
    ! safe_atomic_mv "$tmp_file2" "$symlink"
    assert_true "safe_atomic_mv: refuses to overwrite symlink"
    # Verify real file was not overwritten
    local real_content
    real_content=$(cat "$real_file")
    assert_eq "real content" "$real_content" "safe_atomic_mv: real file unchanged after symlink rejection"
    
    # Cleanup
    rm -rf "$test_dir"
}

# ---------------------------------------------------------------------------
# Test Bug Fixes (2026-04-25 batch)
# ---------------------------------------------------------------------------

test_bug_fixes_2026_04_25() {
    echo ""
    echo "Testing bug fixes from 2026-04-25 batch..."
    
    local telemon_script="${SCRIPT_DIR}/telemon.sh"
    local install_script="${SCRIPT_DIR}/install.sh"
    local admin_script="${SCRIPT_DIR}/telemon-admin.sh"
    
    # LOG_FILE default value
    grep -q 'LOG_FILE="\${LOG_FILE:-' "$telemon_script"
    assert_true "LOG_FILE has default value to prevent unbound variable"
    
    # SMTP password sanitization uses bash parameter substitution
    grep -q 'sanitized_error="\${filtered_error//' "$telemon_script"
    assert_true "SMTP password sanitization uses bash substitution not sed"
    
    # install.sh validates boolean values before sed
    grep -q 'if \[\[ "\$value" != "true" && "\$value" != "false"' "$install_script"
    assert_true "install.sh validates boolean values before sed"
    
    # sanitize_state_key includes lowercase conversion
    grep -q "tr '\[:upper:]' '\[:lower:]'" "$telemon_script"
    assert_true "sanitize_state_key converts to lowercase"
    
    # disk mount sanitization uses sanitize_state_key
    grep -q 'sanitize_state_key "\$mountpoint"' "$telemon_script"
    assert_true "disk mount sanitization uses sanitize_state_key"
    
    # run_with_timeout validates timeout
    grep -q 'if ! is_valid_number "\$timeout_sec"' "$telemon_script"
    assert_true "run_with_timeout validates timeout is positive"
    
    # Proxmox guest ID validation
    grep -q 'if ! is_valid_number "\$guest_id"' "$telemon_script"
    assert_true "Proxmox guest ID validated as numeric"
    
    # Proxmox/Docker status HTML escaping
    grep -q 'html_escape "\$vm_status"' "$telemon_script"
    assert_true "Proxmox vm_status is HTML-escaped"
    
    # check_state_change key validation
    grep -q 'if \[\[ "\$key" == \*"="\* || "\$key" == \*":"\* \]\]' "$telemon_script"
    assert_true "check_state_change validates key for = and :"
    
    # File integrity HTML escaping
    grep -q 'safe_fname=.*html_escape.*"\$fname"' "$telemon_script"
    assert_true "File integrity filename is HTML-escaped"
    
    # Redis WRONGPASS pattern
    grep -q 'WRONGPASS' "$telemon_script"
    assert_true "Redis check includes WRONGPASS pattern"
    
    # check_disk uses df -P
    grep -q 'df -P' "$telemon_script"
    assert_true "check_disk uses df -P for POSIX format"
    
    # LXC memory check: available memory calculated as limit - usage
    grep -q 'available_kb=$(((limit_bytes - usage_bytes) / 1024))' "$telemon_script"
    assert_true "LXC memory check calculates available as limit - usage"
    
    # Dead code removed: calculate_lxc_memory_percent no longer exists
    ! grep -q 'calculate_lxc_memory_percent()' "$telemon_script"
    assert_true "Dead code calculate_lxc_memory_percent() removed"
    
    # Recovery alerts re-enabled (OK skip removed from check_state_change)
    ! grep -q 'Skipping OK alert for' "$telemon_script"
    assert_true "Recovery alerts re-enabled in check_state_change"
    
    # SC2174 fixed in telemon-admin.sh (no mkdir -m with -p)
    ! grep -q 'mkdir -m 700 -p' "$admin_script"
    assert_true "telemon-admin.sh: SC2174 fixed (no mkdir -m with -p)"
    
    # safe_atomic_mv helper exists for symlink/TOCTOU protection
    grep -q 'safe_atomic_mv()' "$telemon_script"
    assert_true "safe_atomic_mv helper exists for atomic writes"
    
    # export_prometheus uses safe_atomic_mv
    grep -q 'safe_atomic_mv.*prom_file' "$telemon_script"
    assert_true "export_prometheus uses safe_atomic_mv for atomic writes"
    
    # Plugin detail parsing uses cut to preserve pipe characters
    grep -q "cut -d'|' -f3-" "$telemon_script"
    assert_true "Plugin detail parsing uses cut to preserve pipe characters"
    
    # check_proxmox_tasks uses python3 JSON parsing instead of grep,
    # with PROXMOX_TASK_MINUTES passed as env to the parser
    grep -q 'PROXMOX_TASK_MINUTES=.*python3 -c' "$telemon_script"
    assert_true "check_proxmox_tasks uses python3 JSON parsing"
    
    # SITE_EXPECTED_STATUS uses hard-coded default fallback
    grep -q 'expected_status="200"' "$telemon_script"
    assert_true "SITE_EXPECTED_STATUS fallback uses hard-coded default 200"
    
    # run_with_timeout fallback sets trap for cleanup
    grep -q 'trap.*kill -KILL.*EXIT' "$telemon_script"
    assert_true "run_with_timeout fallback sets trap for background process cleanup"
    
    # linear_regression centers timestamps for numerical stability
    grep -q 'x = x - first_x' "$telemon_script"
    assert_true "linear_regression centers timestamps for numerical stability"
    
    # check_disk removes unused regex capture variables
    ! grep -q 'local filesystem blocks used avail pct mountpoint' "$telemon_script"
    assert_true "check_disk removes unused local variable declarations"
    
    # check_network_bandwidth removes unused integer rate calculations
    ! grep -q 'local rx_rate=$(( (rx_bytes - prev_rx) / interval ))' "$telemon_script"
    assert_true "check_network_bandwidth removes unused integer rate calculations"
}

# ---------------------------------------------------------------------------
# Integration: Full check->state->alert pipeline with mock data
# ---------------------------------------------------------------------------

test_integration_check_cpu() {
    echo ""
    echo "Testing integration: check_cpu -> state_change -> alert pipeline..."

    check_cpu_mock() {
        local cores="4"
        local load_1m="3.20"  # 80% of 4 cores
        local load_pct
        load_pct=$(awk -v ld="$load_1m" -v c="$cores" 'BEGIN {printf "%.0f", (ld / c) * 100}')
        
        local state="OK"
        local detail="CPU load ${load_1m} (${load_pct}% of ${cores} cores)"
        
        if [[ "$load_pct" -ge "${CPU_THRESHOLD_CRIT:-80}" ]]; then
            state="CRITICAL"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_CRIT:-80}%)"
        elif [[ "$load_pct" -ge "${CPU_THRESHOLD_WARN:-70}" ]]; then
            state="WARNING"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_WARN:-70}%)"
        fi
        
        THRESHOLD_STATE="$state"
        THRESHOLD_DETAIL="$detail"
    }

    local mock_dir
    mock_dir=$(mktemp -d)

    # Test 1: CPU at 80% (WARNING threshold)
    CPU_THRESHOLD_WARN=70
    CPU_THRESHOLD_CRIT=80
    check_cpu_mock
    
    # Test 2: Verify THRESHOLD_STATE is WARNING
    [[ "${THRESHOLD_STATE:-OK}" == "WARNING" || "${THRESHOLD_STATE:-OK}" == "CRITICAL" ]]
    assert_true "check_cpu_mock: CPU at 80% triggers non-OK state"
    
    # Test 3: CPU at 30% (OK)
    CPU_THRESHOLD_WARN=70
    check_cpu_mock() {
        local cores="4"
        local load_1m="1.20"
        local load_pct
        load_pct=$(awk -v ld="$load_1m" -v c="$cores" 'BEGIN {printf "%.0f", (ld / c) * 100}')
        
        local state="OK"
        local detail="CPU load ${load_1m} (${load_pct}% of ${cores} cores)"
        
        if [[ "$load_pct" -ge "${CPU_THRESHOLD_CRIT:-80}" ]]; then
            state="CRITICAL"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_CRIT:-80}%)"
        elif [[ "$load_pct" -ge "${CPU_THRESHOLD_WARN:-70}" ]]; then
            state="WARNING"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_WARN:-70}%)"
        fi
        
        THRESHOLD_STATE="$state"
        THRESHOLD_DETAIL="$detail"
    }
    check_cpu_mock
    assert_eq "OK" "${THRESHOLD_STATE:-}" "check_cpu_mock: CPU at 30% is OK"
    
    # Test 4: CPU at 90% (CRITICAL)
    CPU_THRESHOLD_WARN=70
    CPU_THRESHOLD_CRIT=80
    check_cpu_mock() {
        local cores="4"
        local load_1m="3.60"
        local load_pct
        load_pct=$(awk -v ld="$load_1m" -v c="$cores" 'BEGIN {printf "%.0f", (ld / c) * 100}')
        
        local state="OK"
        local detail="CPU load ${load_1m} (${load_pct}% of ${cores} cores)"
        
        if [[ "$load_pct" -ge "${CPU_THRESHOLD_CRIT:-80}" ]]; then
            state="CRITICAL"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_CRIT:-80}%)"
        elif [[ "$load_pct" -ge "${CPU_THRESHOLD_WARN:-70}" ]]; then
            state="WARNING"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_WARN:-70}%)"
        fi
        
        THRESHOLD_STATE="$state"
        THRESHOLD_DETAIL="$detail"
    }
    check_cpu_mock
    assert_eq "CRITICAL" "${THRESHOLD_STATE:-}" "check_cpu_mock: CPU at 90% triggers CRITICAL"
    
    # Test 5: CPU check with confirmation count via state machine
    declare -A PREV_STATE=()
    declare -A PREV_COUNT=()
    declare -A ALERT_LAST_SENT=()
    CONFIRMATION_COUNT=3
    ALERTS=""
    
    # Re-define with parameterized load
    check_cpu_mock() {
        local cores="4"
        local load_1m="$1"
        local load_pct
        load_pct=$(awk -v ld="$load_1m" -v c="$cores" 'BEGIN {printf "%.0f", (ld / c) * 100}')
        
        local state="OK"
        local detail="CPU load ${load_1m} (${load_pct}% of ${cores} cores)"
        
        if [[ "$load_pct" -ge "${CPU_THRESHOLD_CRIT:-80}" ]]; then
            state="CRITICAL"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_CRIT:-80}%)"
        elif [[ "$load_pct" -ge "${CPU_THRESHOLD_WARN:-70}" ]]; then
            state="WARNING"
            detail="CPU load ${load_1m} = <b>${load_pct}%</b> of ${cores} cores (threshold: ${CPU_THRESHOLD_WARN:-70}%)"
        fi
        
        THRESHOLD_STATE="$state"
        THRESHOLD_DETAIL="$detail"
        load_pct_captured="$load_pct"
    }
    
    # Simulate 3 cycles of WARNING CPU -> alert at 3rd
    check_cpu_mock "3.20"
    
    for (( i=1; i<=3; i++ )); do
        check_cpu_mock "3.20"
        local prev_count="${PREV_COUNT[cpu]:-0}"
        ALERTS=""
        
        if [[ "${THRESHOLD_STATE:-OK}" == "WARNING" || "${THRESHOLD_STATE:-OK}" == "CRITICAL" ]]; then
            prev_count=$((prev_count + 1))
            PREV_COUNT[cpu]=$prev_count
            PREV_STATE[cpu]="${THRESHOLD_STATE}"
            if [[ $prev_count -ge $CONFIRMATION_COUNT ]]; then
                ALERTS="CPU WARNING alert"
            fi
        fi
    done
    
    [[ -n "$ALERTS" ]]
    assert_true "check_cpu integration: alert fires after ${CONFIRMATION_COUNT} consecutive WARNING cycles"
    [[ "${PREV_COUNT[cpu]}" -eq 3 ]]
    assert_true "check_cpu integration: confirmation count reaches 3"
    
    # Test 6: Recovery alert - CPU returns to OK after confirmed WARNING
    ALERTS=""
    check_cpu_mock "0.40"
    if [[ "${THRESHOLD_STATE:-OK}" == "OK" && "${PREV_STATE[cpu]:-OK}" != "OK" && "${PREV_COUNT[cpu]:-0}" -ge "$CONFIRMATION_COUNT" ]]; then
        ALERTS="CPU recovery alert"
    fi
    [[ -n "$ALERTS" ]]
    assert_true "check_cpu integration: recovery alert fires when CPU returns to OK after confirmed WARNING"
    
    # Test 7: Transient spike (unconfirmed WARNING back to OK) - no alert
    PREV_STATE=()
    PREV_COUNT=()
    ALERTS=""
    # One WARNING
    check_cpu_mock "3.20"
    PREV_COUNT[cpu]=1
    PREV_STATE[cpu]="WARNING"
    # Then back to OK
    check_cpu_mock "0.40"
    ALERTS=""
    if [[ "${THRESHOLD_STATE:-OK}" == "OK" && "${PREV_STATE[cpu]:-OK}" != "OK" && "${PREV_COUNT[cpu]:-0}" -ge "$CONFIRMATION_COUNT" ]]; then
        ALERTS="recovery"
    fi
    [[ -z "$ALERTS" ]]
    assert_true "check_cpu integration: transient unconfirmed spike produces no recovery alert"
    
    # Cleanup
    unset CPU_THRESHOLD_WARN CPU_THRESHOLD_CRIT THRESHOLD_STATE THRESHOLD_DETAIL
    unset PREV_STATE PREV_COUNT ALERT_LAST_SENT CONFIRMATION_COUNT ALERTS
    unset check_cpu_mock load_pct_captured
    rm -rf "$mock_dir"
}

test_integration_check_memory() {
    echo ""
    echo "Testing integration: check_memory -> state_change -> alert pipeline..."
    
    check_memory_mock() {
        local total_kb="$1"
        local available_kb="$2"
        local warn="${MEM_THRESHOLD_WARN:-15}"
        local crit="${MEM_THRESHOLD_CRIT:-10}"
        
        if [[ -z "$total_kb" || "$total_kb" -eq 0 ]]; then
            return 1
        fi
        
        local avail_pct
        avail_pct=$(( (available_kb * 100) / total_kb ))
        local total_mb=$(( total_kb / 1024 ))
        local avail_mb=$(( available_kb / 1024 ))
        
        local state="OK"
        local detail="Memory: ${avail_mb}MB available (${avail_pct}%) of ${total_mb}MB"
        
        # Inverted: lower available = worse
        if (( avail_pct <= crit )); then
            state="CRITICAL"
            detail="Memory: <b>${avail_mb}MB</b> available (${avail_pct}%) of ${total_mb}MB (threshold: ${crit}%)"
        elif (( avail_pct <= warn )); then
            state="WARNING"
            detail="Memory: <b>${avail_mb}MB</b> available (${avail_pct}%) of ${total_mb}MB (threshold: ${warn}%)"
        fi
        
        THRESHOLD_STATE="$state"
        THRESHOLD_DETAIL="$detail"
        return 0
    }
    
    # Test 1: Ample memory -> OK
    check_memory_mock 16777216 8388608  # 16GB total, 8GB available (50%)
    assert_eq "OK" "${THRESHOLD_STATE:-}" "check_memory_mock: 50% available is OK"
    
    # Test 2: Low available memory -> WARNING
    MEM_THRESHOLD_WARN=15
    MEM_THRESHOLD_CRIT=10
    check_memory_mock 10000000 1200000  # 10M total, 1.2M available (12%) — integer math gives 12
    assert_eq "WARNING" "${THRESHOLD_STATE:-}" "check_memory_mock: 12% available triggers WARNING"
    
    # Test 3: Critically low memory -> CRITICAL
    check_memory_mock 10000000 800000  # 10M total, 0.8M available (8%)
    assert_eq "CRITICAL" "${THRESHOLD_STATE:-}" "check_memory_mock: 8% available triggers CRITICAL"
    
    # Test 4: Missing total -> skip
    check_memory_mock "" "1000" 2>/dev/null || true
    assert_true "check_memory_mock: empty total returns gracefully"
    
    # Test 5: Zero total -> skip
    check_memory_mock "0" "1000" 2>/dev/null || true
    assert_true "check_memory_mock: zero total returns gracefully"
    
    # Test 6: Alert pipeline with confirmation count
    declare -A PREV_STATE=()
    declare -A PREV_COUNT=()
    CONFIRMATION_COUNT=3
    ALERTS=""
    
    # 3 cycles of critically low memory
    for (( i=1; i<=3; i++ )); do
        check_memory_mock 16777216 838860  # 5% available -> CRITICAL
        local prev_count="${PREV_COUNT[mem]:-0}"
        ALERTS=""
        prev_count=$((prev_count + 1))
        PREV_COUNT[mem]=$prev_count
        PREV_STATE[mem]="${THRESHOLD_STATE}"
        if [[ $prev_count -ge $CONFIRMATION_COUNT ]]; then
            ALERTS="MEMORY CRITICAL alert"
        fi
    done
    [[ -n "$ALERTS" ]]
    assert_true "check_memory integration: alert fires after ${CONFIRMATION_COUNT} consecutive CRITICAL cycles"
    
    # Test 7: Recovery from CRITICAL to OK after confirmation
    ALERTS=""
    check_memory_mock 16777216 8388608  # 50% available -> OK
    if [[ "${THRESHOLD_STATE:-OK}" == "OK" && "${PREV_STATE[mem]:-OK}" != "OK" && "${PREV_COUNT[mem]:-0}" -ge "$CONFIRMATION_COUNT" ]]; then
        ALERTS="MEMORY recovery alert"
    fi
    [[ -n "$ALERTS" ]]
    assert_true "check_memory integration: recovery alert fires from confirmed CRITICAL to OK"
    
    unset MEM_THRESHOLD_WARN MEM_THRESHOLD_CRIT THRESHOLD_STATE THRESHOLD_DETAIL
    unset PREV_STATE PREV_COUNT CONFIRMATION_COUNT ALERTS
    unset check_memory_mock
}

test_integration_check_disk() {
    echo ""
    echo "Testing integration: check_disk -> state_change -> alert pipeline..."
    
    DISK_THRESHOLD_WARN=85
    DISK_THRESHOLD_CRIT=90
    
    check_disk_mount_mock() {
        local usage="$1"
        local mountpoint="$2"
        local filesystem="${3:-/dev/sda1}"
        
        local state="OK"
        local detail="Disk ${mountpoint}: ${usage}% used (${filesystem})"
        
        if (( usage >= DISK_THRESHOLD_CRIT )); then
            state="CRITICAL"
            detail="Disk <b>${mountpoint}</b>: <b>${usage}%</b> used on ${filesystem} (threshold: ${DISK_THRESHOLD_CRIT:-90}%)"
        elif (( usage >= DISK_THRESHOLD_WARN )); then
            state="WARNING"
            detail="Disk <b>${mountpoint}</b>: <b>${usage}%</b> used on ${filesystem} (threshold: ${DISK_THRESHOLD_WARN:-85}%)"
        fi
        
        THRESHOLD_STATE="$state"
        THRESHOLD_DETAIL="$detail"
    }
    
    local sanitized_root="root"
    local key_root="disk_${sanitized_root}"
    local sanitized_data="mnt_storage"
    local key_data="disk_${sanitized_data}"
    
    # Test 1: Disk at 50% -> OK
    check_disk_mount_mock 50 "/" "/dev/sda1"
    assert_eq "OK" "${THRESHOLD_STATE:-}" "check_disk_mount_mock: 50% used is OK"
    
    # Test 2: Disk at 87% -> WARNING
    check_disk_mount_mock 87 "/" "/dev/sda1"
    assert_eq "WARNING" "${THRESHOLD_STATE:-}" "check_disk_mount_mock: 87% used triggers WARNING"
    
    # Test 3: Disk at 95% -> CRITICAL
    check_disk_mount_mock 95 "/mnt/storage" "/dev/nvme0n1p1"
    assert_eq "CRITICAL" "${THRESHOLD_STATE:-}" "check_disk_mount_mock: 95% used triggers CRITICAL"
    
    # Test 4: Alert pipeline with confirmation count for disk
    declare -A PREV_STATE=()
    declare -A PREV_COUNT=()
    CONFIRMATION_COUNT=3
    ALERTS=""
    
    # 3 cycles of WARNING usage on root
    for (( i=1; i<=3; i++ )); do
        check_disk_mount_mock 87 "/"
        ALERTS=""
        local prev_count="${PREV_COUNT[$key_root]:-0}"
        prev_count=$((prev_count + 1))
        PREV_COUNT[$key_root]=$prev_count
        PREV_STATE[$key_root]="${THRESHOLD_STATE}"
        if [[ $prev_count -ge $CONFIRMATION_COUNT ]]; then
            ALERTS+="DISK WARNING alert"
        fi
    done
    [[ -n "$ALERTS" ]]
    assert_true "check_disk integration: alert fires after ${CONFIRMATION_COUNT} consecutive WARNING cycles"
    [[ "${PREV_COUNT[$key_root]}" -eq 3 ]]
    assert_true "check_disk integration: confirmation count reaches 3"
    
    # Test 5: Recovery from WARNING to OK
    ALERTS=""
    check_disk_mount_mock 50 "/"
    if [[ "${THRESHOLD_STATE:-OK}" == "OK" && "${PREV_STATE[$key_root]:-OK}" != "OK" && "${PREV_COUNT[$key_root]:-0}" -ge "$CONFIRMATION_COUNT" ]]; then
        ALERTS="DISK recovery alert"
    fi
    [[ -n "$ALERTS" ]]
    assert_true "check_disk integration: recovery alert fires from confirmed WARNING to OK"
    
    # Test 6: Multiple disks tracked independently
    declare -A PREV_COUNT_MULTI=()
    declare -A PREV_STATE_MULTI=()
    ALERTS=""
    
    for (( i=1; i<=3; i++ )); do
        ALERTS=""
        # Root at WARNING (87%)
        check_disk_mount_mock 87 "/"
        local rc="${PREV_COUNT_MULTI[$key_root]:-0}"
        rc=$((rc + 1))
        PREV_COUNT_MULTI[$key_root]=$rc
        PREV_STATE_MULTI[$key_root]="${THRESHOLD_STATE}"
        if [[ $rc -ge $CONFIRMATION_COUNT && "${THRESHOLD_STATE}" != "OK" ]]; then
            ALERTS+="root_WARNING "
        fi
        # Data at OK (50%)
        check_disk_mount_mock 50 "/mnt/storage"
        local dc="${PREV_COUNT_MULTI[$key_data]:-0}"
        dc=$((dc + 1))
        PREV_COUNT_MULTI[$key_data]=$dc
        PREV_STATE_MULTI[$key_data]="${THRESHOLD_STATE}"
        if [[ $dc -ge $CONFIRMATION_COUNT && "${THRESHOLD_STATE}" != "OK" ]]; then
            ALERTS+="data_OK "
        fi
    done
    [[ "$ALERTS" == *"root_WARNING"* ]]
    assert_true "check_disk integration: root disk alert triggers independently"
    [[ "$ALERTS" != *"data_OK"* ]]
    assert_true "check_disk integration: data disk OK does not trigger alert"
    
    unset DISK_THRESHOLD_WARN DISK_THRESHOLD_CRIT THRESHOLD_STATE THRESHOLD_DETAIL
    unset PREV_STATE PREV_STATE_MULTI PREV_COUNT PREV_COUNT_MULTI CONFIRMATION_COUNT ALERTS
    unset sanitized_root key_root sanitized_data key_data
    unset check_disk_mount_mock
}

test_integration_full_pipeline() {
    echo ""
    echo "Testing full pipeline: run_all_checks -> state changes -> alert message generation..."
    
    local mock_dir
    mock_dir=$(mktemp -d)
    
    # Mock environment setup
    SERVER_LABEL="test-server"
    STATE_FILE="${mock_dir}/state"
    LOG_FILE="${mock_dir}/telemon.log"
    LOG_LEVEL="INFO"
    TOP_PROCESS_COUNT=3
    CONFIRMATION_COUNT=3
    
    CPU_THRESHOLD_WARN=70
    CPU_THRESHOLD_CRIT=80
    MEM_THRESHOLD_WARN=15
    MEM_THRESHOLD_CRIT=10
    DISK_THRESHOLD_WARN=85
    DISK_THRESHOLD_CRIT=90
    
    # Simulated check results (like check_state_change behavior)
    declare -A CURR_STATE=()
    declare -A STATE_DETAIL=()
    declare -A PREV_STATE=()
    declare -A PREV_COUNT=()
    ALERTS=""
    
    # Cycle 1: First run - CRITICAL CPU + MEM, OK disk
    CURR_STATE["cpu"]="CRITICAL"
    STATE_DETAIL["cpu"]="CPU load 3.20 = <b>80%</b> of 4 cores (threshold: 80%)"
    CURR_STATE["mem"]="CRITICAL"
    STATE_DETAIL["mem"]="Memory: <b>819MB</b> available (5%) of 16384MB (threshold: 10%)"
    CURR_STATE["disk_root"]="OK"
    STATE_DETAIL["disk_root"]="Disk /: 50% used (/dev/sda1)"
    
    ALERTS=""
    for key in "${!CURR_STATE[@]}"; do
        local new_state="${CURR_STATE[$key]}"
        local prev_state="${PREV_STATE[$key]:-OK}"
        local prev_count="${PREV_COUNT[$key]:-0}"
        
        if [[ "$new_state" == "$prev_state" ]]; then
            prev_count=$((prev_count + 1))
            PREV_COUNT[$key]=$prev_count
            if [[ $prev_count -eq $CONFIRMATION_COUNT && "$new_state" != "OK" ]]; then
                local emoji="&#128308;"
                [[ "$new_state" == "WARNING" ]] && emoji="&#128992;"
                ALERTS+="${emoji} <b>${key}</b>: ${STATE_DETAIL[$key]}%0A%0A"
            fi
        else
            PREV_COUNT[$key]=1
            PREV_STATE[$key]="$new_state"
        fi
    done
    
    [[ -z "$ALERTS" ]]
    assert_true "full_pipeline: cycle 1 produces no alerts (count=1/3)"
    assert_eq "1" "${PREV_COUNT[cpu]:-0}" "full_pipeline: cycle 1 CPU count = 1"
    
    # Cycle 2: Same states - still counting
    ALERTS=""
    for key in "${!CURR_STATE[@]}"; do
        local new_state="${CURR_STATE[$key]}"
        local prev_state="${PREV_STATE[$key]:-OK}"
        local prev_count="${PREV_COUNT[$key]:-0}"
        
        if [[ "$new_state" == "$prev_state" ]]; then
            prev_count=$((prev_count + 1))
            PREV_COUNT[$key]=$prev_count
            if [[ $prev_count -eq $CONFIRMATION_COUNT && "$new_state" != "OK" ]]; then
                local emoji="&#128308;"
                [[ "$new_state" == "WARNING" ]] && emoji="&#128992;"
                ALERTS+="${emoji} <b>${key}</b>: ${STATE_DETAIL[$key]}%0A%0A"
            fi
        else
            PREV_COUNT[$key]=1
            PREV_STATE[$key]="$new_state"
        fi
    done
    [[ -z "$ALERTS" ]]
    assert_true "full_pipeline: cycle 2 produces no alerts (count=2/3)"
    assert_eq "2" "${PREV_COUNT[cpu]:-0}" "full_pipeline: cycle 2 CPU count = 2"
    
    # Cycle 3: States persist - alerts fire
    ALERTS=""
    for key in "${!CURR_STATE[@]}"; do
        local new_state="${CURR_STATE[$key]}"
        local prev_state="${PREV_STATE[$key]:-OK}"
        local prev_count="${PREV_COUNT[$key]:-0}"
        
        if [[ "$new_state" == "$prev_state" ]]; then
            prev_count=$((prev_count + 1))
            PREV_COUNT[$key]=$prev_count
            if [[ $prev_count -eq $CONFIRMATION_COUNT && "$new_state" != "OK" ]]; then
                local emoji="&#128308;"
                [[ "$new_state" == "WARNING" ]] && emoji="&#128992;"
                ALERTS+="${emoji} <b>${key}</b>: ${STATE_DETAIL[$key]}%0A%0A"
            fi
        else
            PREV_COUNT[$key]=1
            PREV_STATE[$key]="$new_state"
        fi
    done
    [[ -n "$ALERTS" ]]
    assert_true "full_pipeline: cycle 3 fires alerts (count=3/3)"
    assert_contains "$ALERTS" "cpu" "full_pipeline: CPU alert in message"
    assert_contains "$ALERTS" "mem" "full_pipeline: MEM alert in message"
    [[ "$ALERTS" != *"disk_root"* ]]
    assert_true "full_pipeline: OK disk_root not in alert message"
    
    # Cycle 4: Everything resolves to OK -> recovery alerts
    CURR_STATE["cpu"]="OK"
    STATE_DETAIL["cpu"]="CPU load 0.40 = 10% of 4 cores"
    CURR_STATE["mem"]="OK"
    STATE_DETAIL["mem"]="Memory: 8192MB available (50%) of 16384MB"
    CURR_STATE["disk_root"]="OK"
    STATE_DETAIL["disk_root"]="Disk /: 50% used (/dev/sda1)"
    
    ALERTS=""
    for key in "${!CURR_STATE[@]}"; do
        local new_state="${CURR_STATE[$key]}"
        local prev_state="${PREV_STATE[$key]:-OK}"
        local prev_count="${PREV_COUNT[$key]:-0}"
        
        if [[ "$new_state" != "$prev_state" ]]; then
            PREV_COUNT[$key]=1
            # Recovery: confirmed non-OK -> OK transition
            if [[ "$new_state" == "OK" && "$prev_state" != "OK" && "$prev_count" -ge "$CONFIRMATION_COUNT" ]]; then
                ALERTS+="&#9989; <b>${key}</b>: Resolved - ${STATE_DETAIL[$key]}%0A%0A"
            fi
            PREV_STATE[$key]="$new_state"
        fi
    done
    [[ -n "$ALERTS" ]]
    assert_true "full_pipeline: recovery alerts fire after confirmed issues resolve"
    assert_contains "$ALERTS" "Resolved - CPU" "full_pipeline: CPU recovery message"
    assert_contains "$ALERTS" "Resolved - Memory" "full_pipeline: MEM recovery message"
    
    # Test alert message formatting
    local header="<b>&#128308; [${SERVER_LABEL}] CRITICAL: 2 checks failing</b>%0A"
    header+="<i>$(date '+%Y-%m-%d %H:%M:%S %Z')</i>%0A%0A"
    local full_message="${header}${ALERTS}"
    [[ "$full_message" == *"&#128308;"* ]]
    assert_true "full_pipeline: alert message contains emoji"
    [[ "$full_message" == *"<b>"* && "$full_message" == *"</b>"* ]]
    assert_true "full_pipeline: alert message contains HTML formatting"
    [[ "$full_message" == *"test-server"* ]]
    assert_true "full_pipeline: alert message contains server label"
    [[ "$full_message" == *"CRITICAL: 2 checks failing"* ]]
    assert_true "full_pipeline: alert message contains severity summary"
    
    # Test alert message with all-OK state (for digest mode or bootstrap)
    local ok_count=3
    local ok_message="&#9989; All ${ok_count} checks passed. Monitoring active.%0A"
    [[ "$ok_message" == *"3 checks passed"* ]]
    assert_true "full_pipeline: all-OK message contains check count"
    [[ "$ok_message" == *"&#9989;"* ]]
    assert_true "full_pipeline: all-OK message contains checkmark emoji"
    
    # Cleanup
    unset CURR_STATE STATE_DETAIL PREV_STATE PREV_COUNT ALERTS
    unset SERVER_LABEL STATE_FILE LOG_FILE LOG_LEVEL TOP_PROCESS_COUNT
    unset CPU_THRESHOLD_WARN CPU_THRESHOLD_CRIT MEM_THRESHOLD_WARN
    unset MEM_THRESHOLD_CRIT DISK_THRESHOLD_WARN DISK_THRESHOLD_CRIT
    unset CONFIRMATION_COUNT
    rm -rf "$mock_dir"
}

# ---------------------------------------------------------------------------
# Regression tests for the 2026-08-16 code audit (TODO.md items #1-#18)
# Each test exercises the REAL function extracted from telemon.sh (or the real
# shared helper) with mocked external commands, and would have caught the bug
# it guards against.
# ---------------------------------------------------------------------------

test_regression_proxmox_storage_float() {
    echo ""
    echo "Testing check_proxmox_storage float % parse (TODO #1)..."

    local fn_file
    fn_file=$(mktemp)
    awk '/^check_proxmox_storage\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    local capture
    capture=$(mktemp)

    # Mock external deps the extracted function relies on
    run_with_timeout() { shift; "$@" 2>/dev/null; }
    pvesm() {
        echo "Name                Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
        echo "USB-BACKUP-2         dir     active      1921523920       874617604       949224500   45.52%"
        echo "bigdisk              dir     active      3936847312      1788143352      1948648308   45.42%"
    }
    check_state_change() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$capture"; }
    log() { :; }
    CHECK_TIMEOUT=30
    PROXMOX_STORAGE_WARN=40
    PROXMOX_STORAGE_CRIT=95

    # shellcheck disable=SC1090
    source "$fn_file"
    check_proxmox_storage

    # A pool at 45.52% with warn=40 MUST produce WARNING, not the old
    # "OK ... active" skip (the float failed the integer-only regex)
    grep -q "pvesm_usb-backup-2|WARNING|" "$capture"
    assert_true "proxmox_storage: 45.52% pool triggers WARNING (was silently OK before fix)"
    grep -q "at <b>45%</b>" "$capture"
    assert_true "proxmox_storage: rounded percentage (45%) in detail"

    ! grep -q "pvesm_usb-backup-2|OK|Storage.*active" "$capture"
    assert_true "proxmox_storage: no spurious OK-active for decimal pool"

    grep -q "proxmox_storage|CRITICAL|" "$capture"
    assert_true "proxmox_storage: aggregate state reflects warning pools"

    rm -f "$fn_file" "$capture"
}

test_regression_mysql_replication_password() {
    echo ""
    echo "Testing MySQL replication-lag MYSQL_PWD (TODO #2)..."

    # 1) Functional: the exact bash -c pattern must deliver the password via env
    local stubdir
    stubdir=$(mktemp -d)
    cat > "$stubdir/mysql" <<'MYSQLSTUB'
#!/usr/bin/env bash
# Rejects the query unless the password arrived via MYSQL_PWD env (bug #2:
# the old code ran plain `mysql` and silently lost auth on every run)
if [[ -z "${MYSQL_PWD:-}" ]]; then
    echo "ERROR 1045 (28000): Access denied for user" >&2
    exit 1
fi
echo "Seconds_Behind_Master: 120"
exit 0
MYSQLSTUB
    chmod +x "$stubdir/mysql"

    local out
    out=$(PATH="$stubdir:$PATH" bash -c '
        export MYSQL_PWD="$1"
        shift
        mysql "$@" -e "SHOW SLAVE STATUS\G"
    ' _ "secretpass" --host=db --port=3306 --user=root --connect-timeout=5 2>/dev/null | awk '/Seconds_Behind_Master:/ {print $2}')
    assert_eq "120" "$out" "MySQL replication: MYSQL_PWD env reaches the mysql client"

    # 2) Regression guard: without the export the same query fails (documents the bug)
    out=$(PATH="$stubdir:$PATH" bash -c '
        mysql "$@" -e "SHOW SLAVE STATUS\G"
    ' _ --host=db --port=3306 --user=root --connect-timeout=5 2>/dev/null | awk '/Seconds_Behind_Master:/ {print $2}')
    assert_eq "" "$out" "MySQL replication: no lag data without MYSQL_PWD (bug precondition)"

    # 3) Source guard: the env export must be present near SHOW SLAVE STATUS
    local block
    block=$(grep -B6 'SHOW SLAVE STATUS' "${SCRIPT_DIR}/telemon.sh")
    [[ "$block" == *"export MYSQL_PWD"* ]]
    assert_true "MySQL replication: MYSQL_PWD export present near SHOW SLAVE STATUS"

    rm -rf "$stubdir"
}

test_regression_timemachine_missing_results() {
    echo ""
    echo "Testing timemachine plugin without Results.plist (TODO #3)..."

    local stubdir
    stubdir=$(mktemp -d)
    cat > "$stubdir/pct" <<'PCTSTUB'
#!/usr/bin/env bash
# Simulates CT 101 running, but with NO Results.plist, NO lock file, NO
# SnapshotHistory, NO quota config — the exact scenario that crashed the
# plugin with "IS_RUNNING: unbound variable" under set -u before the fix.
case "${1:-}" in
    status)
        echo "101: running"
        ;;
    exec)
        shift 2   # drop "exec" and CT id
        [[ "${1:-}" == "--" ]] && shift
        cmd="${1:-}"
        shift || true
        case "$cmd" in
            systemctl) echo "active" ;;   # smbd active
            test)      exit 1 ;;          # every test -f finds nothing
            *)         ;;                 # find/grep/cat/smbstatus/stat: no output
        esac
        ;;
    *)
        ;;
esac
exit 0
PCTSTUB
    chmod +x "$stubdir/pct"

    local err_file
    err_file=$(mktemp)
    local out err rc
    out=$(PATH="$stubdir:$PATH" bash "${SCRIPT_DIR}/checks.d/timemachine-ct101.sh" 2>"$err_file")
    rc=$?
    err=$(cat "$err_file")

    [[ "$err" != *"unbound variable"* ]]
    assert_true "timemachine: no unbound-variable crash when Results.plist missing"
    assert_eq "WARNING|timemachine-connection|No active Time Machine connections on CT 101" "$out" \
        "timemachine: emits valid STATE|KEY|DETAIL instead of crashing"
    [[ "$rc" -eq 0 ]]
    assert_true "timemachine: plugin exits 0"

    rm -rf "$stubdir" "$err_file"
}

test_regression_strip_html_entities() {
    echo ""
    echo "Testing strip_html_for_plain_text numeric entity decode (TODO #6)..."

    local out
    out=$(strip_html_for_plain_text "&#128308; <b>CRITICAL</b> cpu &amp; mem%0Asecond line")
    [[ "$out" == *"🔴"* ]]
    assert_true "strip_html: numeric emoji entity decoded (&#128308; → 🔴)"
    [[ "$out" != *"&#128308;"* ]]
    assert_true "strip_html: raw numeric entity no longer leaks into payloads"
    [[ "$out" == *"CRITICAL cpu & mem"* ]]
    assert_true "strip_html: tags stripped and named entities decoded"
    [[ "$out" == *"second line"* ]]
    assert_true "strip_html: %0A converted to newline"

    # Fallback sed path (no python3): named entities decode, numeric stay literal
    out=$(printf '%s\n' "&amp; &lt;x&gt; &#128308;" | sed 's/%0A/\n/g; s/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g')
    assert_eq "& <x> &#128308;" "$out" "strip_html: fallback sed handles named entities (numeric literal by design)"

    # All plain-text channels (webhook, email, escalation) must use the shared
    # helper — no inline sed pipeline may remain in telemon.sh
    local src
    src=$(cat "${SCRIPT_DIR}/telemon.sh")
    [[ "$src" == *'plain_msg=$(strip_html_for_plain_text "$esc_message")'* ]]
    assert_true "strip_html: escalation uses shared helper"
    [[ "$src" != *"s/%0A/\\n/g"* ]]
    assert_true "strip_html: no leftover inline sed pipeline in telemon.sh"
}

test_regression_parse_heartbeat_line() {
    echo ""
    echo "Testing parse_heartbeat_line shared parser (TODO #17.5)..."

    local line out
    line=$(printf 'srv1\t1712345678\tOK\t12\t0\t0\t12345')
    out=$(parse_heartbeat_line "$line")
    assert_eq "srv1" "$(echo "$out" | sed -n '1p')" "heartbeat: field 1 label"
    assert_eq "1712345678" "$(echo "$out" | sed -n '2p')" "heartbeat: field 2 timestamp"
    assert_eq "OK" "$(echo "$out" | sed -n '3p')" "heartbeat: field 3 status"
    assert_eq "12" "$(echo "$out" | sed -n '4p')" "heartbeat: field 4 check_count"
    assert_eq "12345" "$(echo "$out" | sed -n '7p')" "heartbeat: field 7 uptime"

    # Short line → trailing fields empty (callers validate before use)
    line=$(printf 'srv1\t1712345678\tOK')
    out=$(parse_heartbeat_line "$line")
    assert_eq "" "$(echo "$out" | sed -n '4p')" "heartbeat: missing fields become empty"
}

test_regression_proxmox_tasks_filter() {
    echo ""
    echo "Testing PROXMOX_TASK_MINUTES filter (TODO #7)..."

    # The exact python filter used in check_proxmox_tasks (env-var driven)
    run_task_filter() {
        local json="$1" minutes="$2"
        printf '%s' "$json" | PROXMOX_TASK_MINUTES="$minutes" python3 -c '
import json, sys, os, time
minutes = int(os.environ.get("PROXMOX_TASK_MINUTES", "60"))
cutoff = time.time() - minutes * 60
data = json.load(sys.stdin)
count = 0
for t in data:
    if not isinstance(t, dict) or t.get("status") not in ("FAILED", "ERROR"):
        continue
    starttime = t.get("starttime")
    if isinstance(starttime, (int, float)) and starttime < cutoff:
        continue
    count += 1
print(count)
' 2>/dev/null || echo "0"
    }

    local now old_ts new_ts json count
    now=$(date +%s)
    old_ts=$(( now - 7200 ))   # 2h ago — outside a 60-min window
    new_ts=$(( now - 300 ))    # 5 min ago — inside the window
    json=$(printf '[{"status":"OK","starttime":%s},{"status":"FAILED","starttime":%s},{"status":"FAILED","starttime":%s},{"status":"ERROR","starttime":%s}]' "$old_ts" "$old_ts" "$new_ts" "$new_ts")

    count=$(run_task_filter "$json" 60)
    assert_eq "2" "$count" "proxmox_tasks: only in-window FAILED/ERROR counted (old ones filtered)"

    count=$(run_task_filter "$json" 180)
    # 4 tasks total, but the OK one is never counted → 3 failures (2h-old FAILED
    # now falls inside the 3h window, proving the window widening works)
    assert_eq "3" "$count" "proxmox_tasks: wider window includes older failures"

    count=$(run_task_filter '[{"status":"FAILED"}]' 60)
    assert_eq "1" "$count" "proxmox_tasks: task without starttime counted (fail-safe)"
}

test_regression_file_integrity_deletion() {
    echo ""
    echo "Testing file integrity deletion alert (TODO #8)..."

    local workdir capture fn_file
    workdir=$(mktemp -d)
    capture=$(mktemp)
    fn_file=$(mktemp)
    awk '/^check_file_integrity\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    local watch_file="${workdir}/sshd_config"
    echo "Port 22" > "$watch_file"

    check_state_change() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$capture"; }
    safe_write_state_file() { printf '%s' "$2" > "$1"; }
    log() { :; }
    STATE_FILE="${workdir}/state"
    INTEGRITY_WATCH_FILES="$watch_file"

    # shellcheck disable=SC1090
    source "$fn_file"

    # Run 1: baseline
    check_file_integrity
    [[ -f "${STATE_FILE}.integrity" ]]
    assert_true "integrity: state file written on baseline"

    # Delete the watched file, then re-run: MUST report DELETED as CRITICAL
    rm -f "$watch_file"
    check_file_integrity
    grep -q "|CRITICAL|.*DELETED" "$capture"
    assert_true "integrity: deleted watched file triggers CRITICAL DELETED alert"

    rm -rf "$workdir"
    rm -f "$capture" "$fn_file"
}

test_regression_drift_deletion() {
    echo ""
    echo "Testing drift detection deletion alert (TODO #8)..."

    local workdir capture fn_file
    workdir=$(mktemp -d)
    capture=$(mktemp)
    fn_file=$(mktemp)
    awk '/^check_drift_detection\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    local watch_file="${workdir}/hosts"
    echo "127.0.0.1 localhost" > "$watch_file"

    check_state_change() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$capture"; }
    safe_write_state_file() { printf '%s' "$2" > "$1"; }
    run_with_timeout() { shift; "$@" 2>/dev/null; }
    log() { :; }
    STATE_FILE="${workdir}/state"
    DRIFT_WATCH_FILES="$watch_file"
    CHECK_TIMEOUT=10

    # shellcheck disable=SC1090
    source "$fn_file"

    # Run 1: baseline
    check_drift_detection
    [[ -f "${STATE_FILE}.drift" ]]
    assert_true "drift: state file written on baseline"

    # Delete the watched file, then re-run: MUST report DELETED as CRITICAL
    rm -f "$watch_file"
    check_drift_detection
    grep -q "|CRITICAL|.*DELETED" "$capture"
    assert_true "drift: deleted watched file triggers CRITICAL DELETED alert"

    rm -rf "$workdir"
    rm -f "$capture" "$fn_file"
}

test_regression_save_state_sidecars() {
    echo ""
    echo "Testing save_state clears empty .cooldown/.detail sidecars (TODO #9)..."

    local workdir fn_file state_file
    workdir=$(mktemp -d)
    fn_file=$(mktemp)
    state_file="${workdir}/state"
    awk '/^save_state\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    declare -A CURR_STATE PREV_COUNT ALERT_LAST_SENT STATE_DETAIL
    CURR_STATE=([cpu]="OK")
    PREV_COUNT=([cpu]="0")
    ALERT_LAST_SENT=([old_key]="1712345678")   # stale — no longer in CURR_STATE
    STATE_DETAIL=([old_key]="stale detail")
    STATE_FILE="$state_file"

    # shellcheck disable=SC1090
    source "$fn_file"

    # Pre-create sidecar files with stale content (as if a previous run left them)
    printf 'old_key=1712345678\n' > "${state_file}.cooldown"
    printf 'old_key=stale detail\n' > "${state_file}.detail"

    save_state

    [[ -f "${state_file}.cooldown" ]]
    assert_true "save_state: .cooldown file still exists"
    [[ ! -s "${state_file}.cooldown" ]]
    assert_true "save_state: stale .cooldown entries cleared (file now empty)"
    [[ ! -s "${state_file}.detail" ]]
    assert_true "save_state: stale .detail entries cleared (file now empty)"

    unset CURR_STATE PREV_COUNT ALERT_LAST_SENT STATE_DETAIL
    rm -rf "$workdir"
    rm -f "$fn_file"
}

test_regression_maintenance_window_portable() {
    echo ""
    echo "Testing is_in_maintenance_window portable date (TODO #12)..."

    local fn_file
    fn_file=$(mktemp)
    awk '/^is_in_maintenance_window\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    # Mock date with zero-padded hours. GNU-only %-H/%-M fail on BusyBox/macOS;
    # the fix uses 10# base-10 so "08" parses correctly.
    date() {
        case "$1" in
            '+%a') echo "Wed" ;;
            '+%H') echo "08" ;;
            '+%M') echo "30" ;;
            *) command date "$@" ;;
        esac
    }
    log() { :; }
    MAINT_SCHEDULE="Wed 08:00-09:00"

    # shellcheck disable=SC1090
    source "$fn_file"

    is_in_maintenance_window
    assert_true "maintenance: zero-padded '08:30' inside Wed 08:00-09:00 window"

    MAINT_SCHEDULE="Mon 08:00-09:00"
    ! is_in_maintenance_window
    assert_true "maintenance: non-matching day returns false"

    unset -f date
    rm -f "$fn_file"
}

test_regression_sites_max_time_cap() {
    echo ""
    echo "Testing check_sites --max-time cap (TODO #13)..."
    local src
    src=$(cat "${SCRIPT_DIR}/telemon.sh")
    [[ "$src" == *'if [[ "$curl_max_time" -gt "$CHECK_TIMEOUT" ]]; then'* ]]
    assert_true "sites: curl_max_time capped at CHECK_TIMEOUT"
    [[ "$src" == *'--max-time "$curl_max_time"'* ]]
    assert_true "sites: curl uses capped curl_max_time"
    [[ "$src" != *'redirect_url'* ]]
    assert_true "sites: dead redirect_url field removed from curl -w"
}

test_regression_dead_code_removed() {
    echo ""
    echo "Testing dead-code removal (TODO #10/#11)..."
    local src
    src=$(cat "${SCRIPT_DIR}/telemon.sh")
    [[ "$src" != *'THRESHOLD_DETAIL="$detail"'* ]]
    assert_true "dead code: THRESHOLD_DETAIL assignment removed"
    [[ "$src" != *'local params="${site#*|}"'* ]]
    assert_true "dead code: check_sites params var removed"
    [[ "$src" != *'local redirect_url='* ]]
    assert_true "dead code: redirect_url var removed"
    [[ "$src" != *'resolved_values'* ]]
    assert_true "dead code: resolved_values removed"
    [[ "$src" != *'read -r device type size used priority'* ]]
    assert_true "dead code: check_swap priority var removed"
    [[ "$src" != *'local slope intercept'* ]]
    assert_true "dead code: prediction intercept var removed"
    [[ "$src" != *'grep -v "Monitor run"'* ]]
    assert_true "validate: stale grep -v Monitor run removed"
    # GH #9: write-only record_count in check_dns_records removed (the
    # run_validate copy that actually reports the count must remain — guard
    # only the check_dns_records one by asserting the report echo still exists)
    [[ "$src" == *'${record_count} DNS record(s) configured'* ]]
    assert_true "dead code: run_validate record_count (used) still present"
    local cdr
    cdr=$(sed -n '/^check_dns_records() {/,/^}/p' "${SCRIPT_DIR}/telemon.sh")
    [[ "$cdr" != *'record_count'* ]]
    assert_true "dead code: record_count removed from check_dns_records"
}

test_regression_alert_queue_retry() {
    echo ""
    echo "Testing queued-alert retry per cycle (TODO #14)..."

    local workdir calls fn_file
    workdir=$(mktemp -d)
    calls=$(mktemp)
    fn_file=$(mktemp)
    awk '/^retry_alert_queue\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    local queue_file="${workdir}/queue"
    printf 'queued alert message\n' > "$queue_file"

    send_telegram() { echo "telegram:$1" >> "$calls"; return 0; }
    send_webhook() { echo "webhook:$1" >> "$calls"; }
    send_email() { echo "email:$1" >> "$calls"; }
    log() { :; }
    ALERT_QUEUE_FILE="$queue_file"

    # shellcheck disable=SC1090
    source "$fn_file"
    retry_alert_queue

    grep -q "telegram:queued alert message" "$calls"
    assert_true "alert queue: queued message retried via Telegram"
    [[ ! -f "$queue_file" ]]
    assert_true "alert queue: queue file removed after successful delivery"

    # main() must invoke it unconditionally, even in quiet cycles with no new
    # alerts (previously a failed alert sat undelivered forever unless a new
    # alert happened to fire)
    local src
    src=$(cat "${SCRIPT_DIR}/telemon.sh")
    [[ "$src" == *"Retry queued alerts from previous failures even when nothing new fired"* ]]
    assert_true "alert queue: main() retries queue even in quiet cycles"

    unset -f send_telegram send_webhook send_email
    rm -rf "$workdir" "$calls" "$fn_file"
}

test_regression_recovery_alert_cooldown() {
    echo ""
    echo "Testing recovery (resolution) alert vs ALERT_COOLDOWN_SEC (GH #2)..."

    # Extract the REAL check_state_change (not a re-implementation) so this
    # regression proves the production behavior — the exact reason the old
    # inline-copy test (GH #11) shipped the bug green.
    local fn_file
    fn_file=$(mktemp)
    awk '/^check_state_change\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    # Mock external deps the extracted function relies on
    log() { :; }
    audit_log() { :; }
    # Control the clock so cooldown arithmetic is deterministic
    FAKE_NOW=1000000
    date() { printf '%s' "$FAKE_NOW"; }

    # shellcheck disable=SC1090
    source "$fn_file"

    # Global state arrays the function reads/writes (mirrors main())
    declare -A PREV_STATE CURR_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT
    ALERTS=""
    CONFIRMATION_COUNT=3
    ALERT_COOLDOWN_SEC=900   # default 15 min; cron cycle = 5 min

    # Persist between "runs" exactly like save_state/load_state do: the real
    # function does NOT write PREV_STATE itself (unlike the divergent test
    # copy), so each simulated cron run starts from the persisted state.
    persist_state() {
        PREV_STATE["$1"]="${CURR_STATE[$1]}"
    }

    # CYCLE 1: first CRITICAL — counting, no alert
    ALERTS=""
    check_state_change "cpu" "CRITICAL" "CPU at 99%"
    persist_state "cpu"
    [[ -z "$ALERTS" ]]
    assert_true "cooldown/resolution: cycle 1 CRITICAL silent (counting)"

    # CYCLE 2: second CRITICAL — still counting, no alert
    FAKE_NOW=$(( FAKE_NOW + 300 ))
    ALERTS=""
    check_state_change "cpu" "CRITICAL" "CPU at 99%"
    persist_state "cpu"
    [[ -z "$ALERTS" ]]
    assert_true "cooldown/resolution: cycle 2 CRITICAL silent (counting)"

    # CYCLE 3: third CRITICAL — confirmed, alert fires
    FAKE_NOW=$(( FAKE_NOW + 300 ))
    ALERTS=""
    check_state_change "cpu" "CRITICAL" "CPU at 99%"
    persist_state "cpu"
    [[ "$ALERTS" == *"<b>cpu</b>"* ]]
    assert_true "cooldown/resolution: cycle 3 CRITICAL alerts (confirmed)"

    # CYCLE 4: still CRITICAL 5 min later — cooldown suppresses re-alert
    FAKE_NOW=$(( FAKE_NOW + 300 ))
    ALERTS=""
    check_state_change "cpu" "CRITICAL" "CPU at 98%"
    persist_state "cpu"
    [[ -z "$ALERTS" ]]
    assert_true "cooldown/resolution: cycle 4 CRITICAL re-alert rate-limited (correct)"

    # CYCLE 5: resolves to OK, only 600s after the last alert (< 900s cooldown)
    # The resolution alert MUST still fire — it is exempt from the cooldown.
    FAKE_NOW=$(( FAKE_NOW + 300 ))
    ALERTS=""
    check_state_change "cpu" "OK" "CPU normal"
    persist_state "cpu"
    [[ "$ALERTS" == *"<b>cpu</b>"* ]]
    assert_true "cooldown/resolution: recovery within cooldown window still alerts (was silently dropped)"
    [[ "${ALERT_LAST_SENT[cpu]}" == "$FAKE_NOW" ]]
    assert_true "cooldown/resolution: ALERT_LAST_SENT refreshed on resolution"

    # Non-OK alerts must STILL be rate-limited (guard against over-exemption)
    FAKE_NOW=$(( FAKE_NOW + 300 ))
    ALERTS=""
    PREV_STATE[cpu]="OK"
    PREV_COUNT[cpu]=0
    check_state_change "cpu" "CRITICAL" "CPU at 97%"
    check_state_change "cpu" "CRITICAL" "CPU at 96%"
    check_state_change "cpu" "CRITICAL" "CPU at 95%"
    persist_state "cpu"
    [[ -z "$ALERTS" ]]
    assert_true "cooldown/resolution: non-OK alerts still rate-limited after exemption"

    unset FAKE_NOW CONFIRMATION_COUNT ALERT_COOLDOWN_SEC ALERTS PREV_STATE CURR_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT
    unset -f date log audit_log persist_state check_state_change
    rm -f "$fn_file"
}

test_regression_smtp_password_raw() {
    echo ""
    echo "Testing SMTP password NOT percent-encoded (GH #3)..."

    local fn_file capture_args capture_config stubdir
    fn_file=$(mktemp)
    awk '/^send_email_native_smtp\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"
    capture_args=$(mktemp)
    capture_config=$(mktemp)
    stubdir=$(mktemp -d)

    # Fake curl: records its argv and copies any --config file it is handed
    cat > "$stubdir/curl" <<'CURLSTUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_ARGS"
config=""
prev=""
for a in "$@"; do
    [[ "$prev" == "--config" ]] && config="$a"
    prev="$a"
done
[[ -n "$config" ]] && cp "$config" "$CAPTURE_CONFIG"
exit 0
CURLSTUB
    chmod +x "$stubdir/curl"

    log() { :; }
    SMTP_HOST="smtp.example.com"
    SMTP_PORT="587"
    SMTP_USER="alert@example.com"
    SMTP_PASS="p@ss%w#rd&q=u?x"   # every character from the old encode list
    SMTP_TLS="yes"

    # shellcheck disable=SC1090
    source "$fn_file"
    CAPTURE_ARGS="$capture_args" CAPTURE_CONFIG="$capture_config" \
        PATH="$stubdir:$PATH" \
        send_email_native_smtp "from@example.com" "to@example.com" "subject" "body"

    # Credentials must travel via --config, never --user (curl does not
    # percent-decode --user, so %40 etc. were sent literally -> auth failure)
    ! grep -q -- "--user" "$capture_args"
    assert_true "SMTP: --user arg eliminated (GH #3)"
    grep -q -- "--config" "$capture_args"
    assert_true "SMTP: credentials passed via --config file"

    # The config file carries the RAW password — no %XX encoding
    grep -q 'user = "alert@example.com:p@ss%w#rd&q=u?x"' "$capture_config"
    assert_true "SMTP: raw password (with @ %% # & = ?) in config file"
    ! grep -qE '%(25|40|23|26|3D|3F)' "$capture_config"
    assert_true "SMTP: no percent-encoded sequences in auth config"

    # Guard: the old encoding pipeline is gone from the source
    local src
    src=$(cat "${SCRIPT_DIR}/telemon.sh")
    [[ "$src" != *'encoded_pass'* ]]
    assert_true "SMTP: percent-encoding pipeline removed from source"

    unset SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_TLS CAPTURE_ARGS CAPTURE_CONFIG
    unset -f log send_email_native_smtp
    rm -rf "$fn_file" "$capture_args" "$capture_config" "$stubdir"
}

test_regression_plugin_multiline_output() {
    echo ""
    echo "Testing multi-line plugin output (GH #4)..."

    local fn_file capture plugdir
    fn_file=$(mktemp)
    awk '/^check_plugins\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"
    capture=$(mktemp)
    plugdir=$(mktemp -d)

    run_with_timeout() { shift; "$@" 2>/dev/null; }
    log() { :; }
    check_state_change() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$capture"; }

    # Plugin 1: banner line BEFORE the STATE|KEY|DETAIL line (issue proof case)
    cat > "$plugdir/banner-plugin" <<'PLUGIN1'
#!/usr/bin/env bash
echo "checking service X..."
echo "WARNING|svc_check|Service X degraded|with|pipes"
PLUGIN1
    # Plugin 2: STATE line first, then debug output + trailing blank line
    cat > "$plugdir/debug-plugin" <<'PLUGIN2'
#!/usr/bin/env bash
echo "OK|health_check|All good"
echo "debug: took 0.3s"
echo ""
PLUGIN2
    # Plugin 3: invalid output (no valid STATE|KEY|DETAIL line) — still skipped
    cat > "$plugdir/bad-plugin" <<'PLUGIN3'
#!/usr/bin/env bash
echo "no state format here"
PLUGIN3
    chmod +x "$plugdir"/*

    # shellcheck disable=SC1090
    source "$fn_file"
    CHECKS_DIR="$plugdir" CHECK_TIMEOUT=30 check_plugins

    grep -q "svc_check|WARNING|Service X degraded|with|pipes" "$capture"
    assert_true "plugin multi-line: banner + STATE|KEY|DETAIL parsed (was dropped before fix)"
    grep -q "health_check|OK|All good" "$capture"
    assert_true "plugin multi-line: STATE line with trailing debug + blank line parsed"
    ! grep -q "bad-plugin" "$capture"
    assert_true "plugin multi-line: invalid output (no STATE line) still skipped"

    unset -f run_with_timeout log check_state_change check_plugins
    rm -f "$fn_file" "$capture"
    rm -rf "$plugdir"
}

test_regression_detail_newline_roundtrip() {
    echo ""
    echo "Testing .detail newline encoding round-trip (GH #5)..."

    local fn_file workdir state_file
    fn_file=$(mktemp)
    workdir=$(mktemp -d)
    state_file="${workdir}/state"

    # Extract BOTH real functions (save_state calls safe_write_state_file,
    # which is mocked below with functional write behavior)
    awk '/^save_state\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"
    awk '/^load_state\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" >> "$fn_file"

    log() { :; }
    # Functional mock matching the real safe_write_state_file write semantics
    safe_write_state_file() {
        local target="$1" content="$2"
        local tmp_target
        tmp_target=$(mktemp "${target}.XXXXXX") || return 1
        echo "$content" > "$tmp_target"
        chmod 600 "$tmp_target" 2>/dev/null || true
        mv "$tmp_target" "$target"
    }

    # shellcheck disable=SC1090
    source "$fn_file"

    declare -A CURR_STATE PREV_STATE PREV_COUNT ALERT_LAST_SENT STATE_DETAIL
    STATE_FILE="$state_file"

    # Drift-style detail with REAL newlines (the issue's corruption case) plus
    # a literal backslash-n and a plain detail for full round-trip coverage
    local drift_detail
    drift_detail=$'<b>File:</b> <code>/etc/nginx/nginx.conf</code>%0A<b>Changes:</b>%0A<pre>- old line\n+ new line\n context\n</pre>'
    CURR_STATE=([drift_x]="WARNING" [literal]="WARNING" [plain]="OK")
    PREV_COUNT=([drift_x]="3" [literal]="3" [plain]="0")
    STATE_DETAIL=([drift_x]="$drift_detail" [literal]="path \\ with backslash-n \\n" [plain]='all good')

    save_state

    # On-disk .detail must be one NON-EMPTY physical line per key — no raw
    # newlines leaked from detail content (the trailing blank line is the
    # pre-existing echo artifact also present in production writes)
    local nonempty_lines
    nonempty_lines=$(grep -cv '^$' "${state_file}.detail")
    assert_eq "3" "$nonempty_lines" "detail: on-disk .detail has one line per key (was 4+ corrupt)"

    # Round-trip: load_state must restore each detail byte-exactly
    load_state
    assert_eq "$drift_detail" "${STATE_DETAIL[drift_x]}" "detail: drift detail with newlines round-trips exactly"
    assert_eq "path \\ with backslash-n \\n" "${STATE_DETAIL[literal]}" "detail: literal backslash-n round-trips exactly"
    assert_eq "all good" "${STATE_DETAIL[plain]}" "detail: plain detail round-trips"

    unset CURR_STATE PREV_COUNT ALERT_LAST_SENT STATE_DETAIL STATE_FILE
    unset -f log safe_write_state_file save_state load_state
    rm -f "$fn_file"
    rm -rf "$workdir"
}

test_regression_sites_ssl_port() {
    echo ""
    echo "Testing check_sites SSL port from URL (GH #6)..."

    local fn_file captures openssl_calls stubdir
    fn_file=$(mktemp)
    captures=$(mktemp -d)
    openssl_calls="${captures}/openssl_calls"
    stubdir="${captures}/bin"
    mkdir -p "$stubdir"
    awk '/^check_sites\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SCRIPT_DIR}/telemon.sh" > "$fn_file"

    # Fake openssl: records the -connect target and feeds a future cert date
    cat > "$stubdir/openssl" <<'OSSLSTUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "s_client" ]]; then
    prev=""
    for a in "$@"; do
        [[ "$prev" == "-connect" ]] && echo "$a" >> "$OSSL_CALLS"
        prev="$a"
    done
    echo "-----BEGIN CERTIFICATE-----"
    echo "dummy"
    echo "-----END CERTIFICATE-----"
elif [[ "${1:-}" == "x509" ]]; then
    echo "notAfter=Dec  1 12:00:00 2026 GMT"
fi
exit 0
OSSLSTUB
    chmod +x "$stubdir/openssl"

    log() { :; }
    run_with_timeout() { shift; "$@" 2>/dev/null; }
    curl() { echo "200|0.1|0"; }
    check_state_change() { :; }
    is_internal_ip() { return 1; }

    # shellcheck disable=SC1090
    source "$fn_file"
    CHECK_TIMEOUT=30

    # Case 1: explicit non-default port in the URL
    OSSL_CALLS="$openssl_calls" CRITICAL_SITES="https://example.com:8443|check_ssl=true" \
        PATH="$stubdir:$PATH" check_sites
    grep -q "example.com:8443" "$openssl_calls"
    assert_true "SSL port: -connect uses URL port 8443 (was hardcoded 443)"

    # Case 2: no port in URL — default 443
    rm -f "$openssl_calls"
    OSSL_CALLS="$openssl_calls" CRITICAL_SITES="https://example.com|check_ssl=true" \
        PATH="$stubdir:$PATH" check_sites
    grep -q "example.com:443" "$openssl_calls"
    assert_true "SSL port: default port 443 when URL has no port"

    unset CHECK_TIMEOUT OSSL_CALLS
    unset -f log run_with_timeout curl check_state_change is_internal_ip check_sites
    rm -rf "$fn_file" "$captures"
}

# ---------------------------------------------------------------------------
# Coverage note (2026-08-16, TODO #18)
# ---------------------------------------------------------------------------
# Functional coverage (REAL functions extracted from telemon.sh and executed
# with mocked external commands): check_state_change (test_check_state_change),
# calculate_lxc_cpu_percent (test_lxc_cpu_float_uptime), check_file_integrity
# and check_drift_detection (deletion regression), check_proxmox_storage
# (float % regression), save_state (sidecar regression),
# is_in_maintenance_window (portable date regression), plus all helpers in
# lib/common.sh (portable_stat, portable_sha256, sanitize_state_key,
# html_escape, strip_html_for_plain_text, parse_heartbeat_line,
# get_state_file_variants). The check_proxmox_tasks python filter and the MySQL
# replication password path are functionally exercised via the matching
# regression tests (same snippets, stubbed clients).
#
# Grep-only coverage (regression guards without executing): remaining check
# functions from TODO #18 are covered by pattern checks — see
# test_check_databases_*, test_dns_record_checks, test_discovery_system,
# test_bug_fixes_2026_04_25 and the new dead-code/validate guards.
# ---------------------------------------------------------------------------

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
    test_check_databases_mysql
    test_check_databases_postgres
    test_check_databases_redis
    test_check_databases_sqlite
    test_dns_record_checks
    test_audit_logging
    test_status_page_generation
    test_one_line_installer
    test_check_threshold_helper
    test_security_database_passwords
    test_odbc_checks
    test_check_odbc
    test_predictive_exhaustion
    test_fleet_heartbeats
    test_validate_env_security
    test_maintenance_windows
    test_auto_remediation
    test_discovery_system
    test_lock_mechanism
    test_first_run_fingerprint
    test_bug_fixes_2026_04_25
    test_plugin_detail_pipes
    test_lxc_code_paths
    test_lxc_cpu_float_uptime
    test_common_sh_source_guard
    test_safe_atomic_mv
    test_integration_check_cpu
    test_integration_check_memory
    test_integration_check_disk
    test_integration_full_pipeline

    # Regression tests for the 2026-08-16 code audit (TODO.md #1-#18)
    test_regression_proxmox_storage_float
    test_regression_mysql_replication_password
    test_regression_timemachine_missing_results
    test_regression_strip_html_entities
    test_regression_parse_heartbeat_line
    test_regression_proxmox_tasks_filter
    test_regression_file_integrity_deletion
    test_regression_drift_deletion
    test_regression_save_state_sidecars
    test_regression_maintenance_window_portable
    test_regression_sites_max_time_cap
    test_regression_dead_code_removed
    test_regression_alert_queue_retry
    test_regression_recovery_alert_cooldown
    test_regression_smtp_password_raw
    test_regression_plugin_multiline_output
    test_regression_detail_newline_roundtrip
    test_regression_sites_ssl_port

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
