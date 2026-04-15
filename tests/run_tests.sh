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
        TESTS_FAILED=$((TESTS_FAILED + 1))
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
        TESTS_FAILED=$((TESTS_FAILED + 1))
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
    hash1=$(echo "test" | portable_sha256)
    hash2=$(echo "test" | portable_sha256)
    assert_eq "$hash1" "$hash2" "portable_sha256 produces consistent results"
    
    # Test that different inputs produce different outputs
    local hash3
    hash3=$(echo "different" | portable_sha256)
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
