#!/usr/bin/env bats
# Tests for lib/common.sh — shared validation and utility functions

setup() {
    # Source common.sh functions directly with absolute path
    source "/opt/telemon/lib/common.sh"
}

# ---------------------------------------------------------------------------
# is_valid_number
# ---------------------------------------------------------------------------
@test "is_valid_number: accepts positive integers" {
    is_valid_number 1
    is_valid_number 42
    is_valid_number 0
    is_valid_number 999999
}

@test "is_valid_number: rejects non-numeric values" {
    ! is_valid_number "abc"
    ! is_valid_number ""
    ! is_valid_number "12.5"
    ! is_valid_number "-5"
    ! is_valid_number "12 34"
}

# ---------------------------------------------------------------------------
# is_valid_service_name
# ---------------------------------------------------------------------------
@test "is_valid_service_name: accepts valid service names" {
    is_valid_service_name "sshd"
    is_valid_service_name "pveproxy"
    is_valid_service_name "my-app"
    is_valid_service_name "test_service"
}

@test "is_valid_service_name: rejects unsafe names" {
    ! is_valid_service_name "rm -rf /"
    ! is_valid_service_name "service;id"
    ! is_valid_service_name ""
    ! is_valid_service_name "service name"
}

# ---------------------------------------------------------------------------
# is_valid_hostname
# ---------------------------------------------------------------------------
@test "is_valid_hostname: accepts valid hostnames" {
    is_valid_hostname "localhost"
    is_valid_hostname "example.com"
    is_valid_hostname "192.168.1.1"
    is_valid_hostname "my-host"
    is_valid_hostname "some_service"
}

@test "is_valid_hostname: rejects unsafe hostnames" {
    ! is_valid_hostname "host;rm"
    ! is_valid_hostname ""
    ! is_valid_hostname "host port"
}

# ---------------------------------------------------------------------------
# is_safe_path
# ---------------------------------------------------------------------------
@test "is_safe_path: accepts safe paths" {
    is_safe_path "/etc/pve/storage.cfg"
    is_safe_path "/var/log/syslog"
    is_safe_path "/opt/my-app/config.json"
    is_safe_path "/mnt/storage/file"
}

@test "is_safe_path: rejects path traversal" {
    ! is_safe_path "/etc/../shadow"
    ! is_safe_path "../../etc/passwd"
}

@test "is_safe_path: rejects shell expansion characters" {
    ! is_safe_path "/etc/*"
    ! is_safe_path "/etc/???"
}

@test "is_safe_path: rejects command substitution" {
    ! is_safe_path '/etc/$(whoami)'
}

# ---------------------------------------------------------------------------
# is_valid_email
# ---------------------------------------------------------------------------
@test "is_valid_email: accepts valid emails" {
    is_valid_email "user@example.com"
    is_valid_email "test.user@sub.example.org"
    is_valid_email "user+tag@domain.com"
}

@test "is_valid_email: rejects invalid emails" {
    ! is_valid_email ""
    ! is_valid_email "not-an-email"
    ! is_valid_email "@domain.com"
}

# ---------------------------------------------------------------------------
# is_internal_ip
# ---------------------------------------------------------------------------
@test "is_internal_ip: detects private IPs" {
    is_internal_ip "127.0.0.1"
    is_internal_ip "10.0.0.1"
    is_internal_ip "172.16.0.1"
    is_internal_ip "192.168.1.1"
    is_internal_ip "169.254.1.1"
    is_internal_ip "localhost"
}

@test "is_internal_ip: passes public IPs" {
    ! is_internal_ip "8.8.8.8"
    ! is_internal_ip "1.1.1.1"
}

# ---------------------------------------------------------------------------
# portable_stat
# ---------------------------------------------------------------------------
@test "portable_stat: returns positive size for existing file" {
    result=$(portable_stat size "/etc/hostname")
    [ -n "$result" ]
    [ "$result" -gt 0 ]
}

@test "portable_stat: returns 0 for nonexistent file" {
    result=$(portable_stat size "/nonexistent/file/path")
    [ "$result" = "0" ]
}

# ---------------------------------------------------------------------------
# portable_sha256
# ---------------------------------------------------------------------------
@test "portable_sha256: produces consistent 64-char hash" {
    h1=$(echo "hello" | portable_sha256)
    h2=$(echo "hello" | portable_sha256)
    [ "$h1" = "$h2" ]
    [ "${#h1}" -eq 64 ]
}

@test "portable_sha256: produces different hashes for different inputs" {
    h1=$(echo "foo" | portable_sha256)
    h2=$(echo "bar" | portable_sha256)
    [ "$h1" != "$h2" ]
}

# ---------------------------------------------------------------------------
# make_state_key
# ---------------------------------------------------------------------------
@test "make_state_key: produces prefix_hash format" {
    result=$(make_state_key "test" "value")
    [[ "$result" =~ ^test_[a-f0-9]{12}$ ]]
}

@test "make_state_key: same value produces same key" {
    k1=$(make_state_key "test" "same")
    k2=$(make_state_key "test" "same")
    [ "$k1" = "$k2" ]
}

# ---------------------------------------------------------------------------
# require_file
# ---------------------------------------------------------------------------
@test "require_file: returns 0 for existing readable file" {
    touch "${BATS_TEST_TMPDIR}/testfile"
    require_file "${BATS_TEST_TMPDIR}/testfile" "test file"
}

@test "require_file: returns 1 for nonexistent file" {
    ! require_file "${BATS_TEST_TMPDIR}/nonexistent" "test file"
}

@test "require_file: returns 1 for unsafe path" {
    ! require_file "/etc/../shadow" "unsafe path"
}

@test "require_file: returns 1 for path with command substitution" {
    ! require_file '/etc/$(whoami)' "unsafe path"
}

# ---------------------------------------------------------------------------
# require_command
# ---------------------------------------------------------------------------
@test "require_command: returns 0 for available command" {
    require_command "bash"
    require_command "cat"
    require_command "grep"
}

@test "require_command: returns 1 for nonexistent command" {
    ! require_command "this_command_does_not_exist_12345"
}

# ---------------------------------------------------------------------------
# validate_numeric
# ---------------------------------------------------------------------------
@test "validate_numeric: accepts valid positive integers" {
    validate_numeric 42 "test value"
    validate_numeric 0 "test value"
    validate_numeric 999999 "test value"
}

@test "validate_numeric: rejects non-numeric values" {
    ! validate_numeric "abc" "test value"
    ! validate_numeric "" "test value"
    ! validate_numeric "12.5" "test value"
}

@test "validate_numeric: enforces minimum value" {
    validate_numeric 10 "test value" 5
    ! validate_numeric 3 "test value" 5
}

@test "validate_numeric: enforces maximum value" {
    validate_numeric 50 "test value" "" 100
    ! validate_numeric 150 "test value" "" 100
}

@test "validate_numeric: enforces min and max range" {
    validate_numeric 50 "test value" 10 100
    validate_numeric 10 "test value" 10 100
    validate_numeric 100 "test value" 10 100
    ! validate_numeric 5 "test value" 10 100
    ! validate_numeric 105 "test value" 10 100
}

# ---------------------------------------------------------------------------
# validate_numeric_or_default
# ---------------------------------------------------------------------------
@test "validate_numeric_or_default: returns valid number unchanged" {
    result=$(validate_numeric_or_default 42 "test" 0)
    [ "$result" = "42" ]
}

@test "validate_numeric_or_default: returns default for invalid input" {
    result=$(validate_numeric_or_default "abc" "test" 99)
    [ "$result" = "99" ]
}

@test "validate_numeric_or_default: returns default for empty input" {
    result=$(validate_numeric_or_default "" "test" 0)
    [ "$result" = "0" ]
}

@test "validate_numeric_or_default: respects minimum and returns default if below" {
    result=$(validate_numeric_or_default 5 "test" 100 10)
    [ "$result" = "100" ]
}

@test "validate_numeric_or_default: respects maximum and returns default if above" {
    result=$(validate_numeric_or_default 200 "test" 50 0 100)
    [ "$result" = "50" ]
}

@test "validate_numeric_or_default: returns input when within range" {
    result=$(validate_numeric_or_default 50 "test" 0 10 100)
    [ "$result" = "50" ]
}

# ---------------------------------------------------------------------------
# is_path_in_allowed_dirs
# ---------------------------------------------------------------------------
@test "is_path_in_allowed_dirs: accepts path in allowed dir" {
    is_path_in_allowed_dirs "/etc/passwd" "/etc /var /opt"
    is_path_in_allowed_dirs "/var/log/syslog" "/etc /var /opt"
    is_path_in_allowed_dirs "/opt/app/config" "/etc /var /opt"
}

@test "is_path_in_allowed_dirs: rejects path outside allowed dirs" {
    ! is_path_in_allowed_dirs "/usr/bin/sh" "/etc /var /opt"
    ! is_path_in_allowed_dirs "/tmp/file" "/etc /var /opt"
}

@test "is_path_in_allowed_dirs: rejects empty allowed list" {
    ! is_path_in_allowed_dirs "/etc/passwd" ""
}

# ---------------------------------------------------------------------------
# get_state_file_variants
# ---------------------------------------------------------------------------
@test "get_state_file_variants: returns main state file by default" {
    export STATE_FILE="/tmp/test_state"
    result=$(get_state_file_variants)
    [[ "$result" == *"/tmp/test_state"* ]]
}

@test "get_state_file_variants: excludes main state file when requested" {
    export STATE_FILE="/tmp/test_state"
    result=$(get_state_file_variants false)
    [[ "$result" != *"/tmp/test_state "* ]]
}

@test "get_state_file_variants: includes lock files when requested" {
    export STATE_FILE="/tmp/test_state"
    result=$(get_state_file_variants true true)
    [[ "$result" == *".lock"* ]]
}

@test "get_state_file_variants: includes drift baseline when requested" {
    export STATE_FILE="/tmp/test_state"
    result=$(get_state_file_variants true false true)
    [[ "$result" == *".drift.baseline"* ]]
}

# ---------------------------------------------------------------------------
# load_telemon_env (simplified test - checks default values)
# ---------------------------------------------------------------------------
@test "load_telemon_env: requires SCRIPT_DIR to be set" {
    unset SCRIPT_DIR
    ! load_telemon_env
}

@test "load_telemon_env: succeeds when SCRIPT_DIR is set" {
    export SCRIPT_DIR="/opt/telemon"
    load_telemon_env
}
