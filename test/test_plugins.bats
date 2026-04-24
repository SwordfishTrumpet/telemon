#!/usr/bin/env bats
# Tests for plugin system and checks.d scripts

setup() {
    source "/opt/telemon/lib/common.sh"

    log() { :; }
    export -f log
}

# ---------------------------------------------------------------------------
# Plugin output format parsing
# ---------------------------------------------------------------------------
@test "plugin output: accepts valid STATE|KEY|DETAIL format" {
    # Create a test plugin
    local tmp_plugin="${BATS_TEST_TMPDIR}/test_plugin.sh"
    cat > "$tmp_plugin" << 'EOF'
#!/usr/bin/env bash
echo "OK|test_plugin_check|Plugin test passed"
EOF
    chmod +x "$tmp_plugin"

    local output
    output=$("$tmp_plugin" 2>/dev/null)

    local plugin_state="${output%%|*}"
    local rest="${output#*|}"
    local plugin_key="${rest%%|*}"
    local plugin_detail="${rest#*|}"

    [ "$plugin_state" = "OK" ]
    [ "$plugin_key" = "test_plugin_check" ]
    [ "$plugin_detail" = "Plugin test passed" ]
}

@test "plugin output: detects invalid state" {
    local output="INVALID|test_key|some detail"
    local plugin_state="${output%%|*}"

    case "$plugin_state" in
        OK|WARNING|CRITICAL) false ;;
        *) true ;;
    esac
}

@test "plugin output: validates key format" {
    local valid_key="my_check_123"
    [[ "$valid_key" =~ ^[a-zA-Z0-9_.-]+$ ]]

    local invalid_key="key with spaces"
    ! [[ "$invalid_key" =~ ^[a-zA-Z0-9_.-]+$ ]]
}

# ---------------------------------------------------------------------------
# UPS check plugin (ups-check.sh)
# ---------------------------------------------------------------------------
@test "ups-check plugin: outputs valid format" {
    if [[ -f "/opt/telemon/checks.d/ups-check.sh" ]]; then
        local output
        output=$(bash "/opt/telemon/checks.d/ups-check.sh" 2>/dev/null)
        [[ "$output" =~ ^(OK|WARNING|CRITICAL)\|[a-zA-Z0-9_.-]+\| ]]
    else
        skip "ups-check.sh not found"
    fi
}

# ---------------------------------------------------------------------------
# SATA SMART check plugin (smart-sda.sh)
# ---------------------------------------------------------------------------
@test "smart-sda plugin: handles missing device gracefully" {
    if [[ -f "/opt/telemon/checks.d/smart-sda.sh" ]]; then
        local output
        output=$(bash "/opt/telemon/checks.d/smart-sda.sh" 2>/dev/null)
        [[ "$output" =~ ^(OK|WARNING|CRITICAL)\|[a-zA-Z0-9_.-]+\| ]]
    else
        skip "smart-sda.sh not found"
    fi
}

# ---------------------------------------------------------------------------
# Proxmox services check plugin
# ---------------------------------------------------------------------------
@test "proxmox-services plugin: outputs valid format with OK lines" {
    if [[ -f "/opt/telemon/checks.d/proxmox-services.sh" ]]; then
        local output
        output=$(bash "/opt/telemon/checks.d/proxmox-services.sh" 2>/dev/null)
        echo "$output" | grep -q "^OK|"
    else
        skip "proxmox-services.sh not found"
    fi
}
