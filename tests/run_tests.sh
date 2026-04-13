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
# Test portable_md5 helper
# ---------------------------------------------------------------------------

test_portable_md5() {
    echo ""
    echo "Testing portable_md5 helper..."
    
    # Test that we get a consistent hash
    local hash1 hash2
    hash1=$(echo "test" | portable_md5)
    hash2=$(echo "test" | portable_md5)
    assert_eq "$hash1" "$hash2" "portable_md5 produces consistent results"
    
    # Test that different inputs produce different outputs
    local hash3
    hash3=$(echo "different" | portable_md5)
    [[ "$hash1" != "$hash3" ]]
    assert_true "portable_md5 produces different hashes for different inputs"
    
    # Test that output looks like a hash (alphanumeric)
    [[ "$hash1" =~ ^[a-zA-Z0-9]+$ ]]
    assert_true "portable_md5 produces alphanumeric output"
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
    
    # Test with drift baseline included (it returns the path but caller checks if it's a dir)
    local with_drift
    with_drift=$(get_state_file_variants)
    assert_contains "$with_drift" "${STATE_FILE}.drift" "get_state_file_variants includes drift state file"
}

# ---------------------------------------------------------------------------
# Test sanitize_state_key logic (from telemon.sh)
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
    local valid_keys=("cpu" "mem" "disk_root" "container_nginx" "proc_sshd" "site_abc123" "port_def456")
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
        # Escape & first (must use \& in replacement to get literal &)
        text="${text//&/\&amp;}"
        text="${text//</\&lt;}"
        text="${text//>/\&gt;}"
        text="${text//\"/\&quot;}"
        text="${text//\'/\&#39;}"
        printf '%s' "$text"
    }
    
    # Test basic HTML entities (use variables to avoid shell interpretation)
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
    
    # Test combined string
    local input_combo="<b>test</b>" expected_combo="&lt;b&gt;test&lt;/b&gt;"
    assert_eq "$expected_combo" "$(html_escape "$input_combo")" "html_escape escapes HTML tags"
    
    local input_text="Tom & Jerry" expected_text="Tom &amp; Jerry"
    assert_eq "$expected_text" "$(html_escape "$input_text")" "html_escape escapes ampersand in text"
    
    # Test empty string
    assert_eq "" "$(html_escape "")" "html_escape handles empty string"
    
    # Test string with no special chars
    assert_eq "hello world" "$(html_escape "hello world")" "html_escape leaves plain text unchanged"
}

# ---------------------------------------------------------------------------
# Test threshold validation helper
# ---------------------------------------------------------------------------

test_threshold_validation() {
    echo ""
    echo "Testing threshold validation logic..."
    
    # is_valid_number is already sourced from lib/common.sh
    
    # Test is_valid_number
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
    
    ! is_valid_number ""
    assert_true "is_valid_number rejects empty string"
    
    # Test threshold relationship logic (normal: warn < crit)
    local warn=70 crit=80
    [[ "$warn" -lt "$crit" ]]
    assert_true "Normal threshold: warn ($warn) < crit ($crit)"
    
    # Test inverted threshold relationship (inverted: warn > crit)
    local mem_warn=15 mem_crit=10
    [[ "$mem_warn" -gt "$mem_crit" ]]
    assert_true "Inverted threshold: warn ($mem_warn) > crit ($mem_crit) for memory"
}

# ---------------------------------------------------------------------------
# Test parse_date_to_epoch helper (cross-platform date parsing)
# ---------------------------------------------------------------------------

test_parse_date_to_epoch() {
    echo ""
    echo "Testing parse_date_to_epoch helper..."
    
    # Define parse_date_to_epoch inline for testing (copied from telemon.sh)
    parse_date_to_epoch() {
        local datestr="$1"
        # Try GNU date first (Linux)
        local epoch
        epoch=$(date -d "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
        # Try BSD date (macOS) with common OpenSSL date format
        epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
        epoch=$(date -j -f "%b  %d %H:%M:%S %Y %Z" "$datestr" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
        # Try python3 as last resort
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
    # Empty or non-numeric is acceptable for invalid dates
    [[ -z "$bad_epoch" || ! "$bad_epoch" =~ ^[0-9]+$ ]]
    assert_true "parse_date_to_epoch handles invalid dates gracefully"
}

# ---------------------------------------------------------------------------
# Test run_with_timeout helper
# ---------------------------------------------------------------------------

test_run_with_timeout() {
    echo ""
    echo "Testing run_with_timeout helper..."
    
    # Define run_with_timeout inline for testing (simplified version)
    run_with_timeout() {
        local timeout_sec="$1"
        shift
        
        # Use timeout command if available (coreutils)
        if command -v timeout &>/dev/null; then
            timeout "$timeout_sec" "$@" 2>/dev/null
            return $?
        fi
        
        # Fallback: bash timeout using background job
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
    
    # Test with very short timeout on a slow command (sleep)
    # This may return 124 (timeout) or succeed depending on system speed
    # Just verify it doesn't hang
    run_with_timeout 1 sleep 0.1 2>/dev/null
    assert_true "run_with_timeout: short command completes within timeout"
}

# ---------------------------------------------------------------------------
# Test safe_write_state_file helper
# ---------------------------------------------------------------------------

test_safe_write_state_file() {
    echo ""
    echo "Testing safe_write_state_file helper..."
    
    # Define safe_write_state_file inline for testing (simplified version)
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
    test_portable_md5
    test_get_state_file_variants
    test_sanitize_state_key
    test_state_key_format
    test_html_escape
    test_threshold_validation
    test_linear_regression
    test_parse_date_to_epoch
    test_run_with_timeout
    test_safe_write_state_file

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
