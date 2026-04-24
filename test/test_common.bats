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
