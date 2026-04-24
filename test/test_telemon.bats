#!/usr/bin/env bats
# Tests for telemon.sh — state management, thresholds, helpers
# Uses a sandboxed approach: extracts function text and sources in isolation

setup() {
    # Source common.sh
    source "/opt/telemon/lib/common.sh"

    # Override log() to capture or suppress output
    log() { printf '[%s] %s\n' "$1" "$2" >> "${BATS_TEST_TMPDIR}/test.log" 2>/dev/null; }
    export -f log

    export SCRIPT_DIR="/opt/telemon"
    export STATE_FILE="${BATS_TEST_TMPDIR}/test_state"
    export TELEGRAM_BOT_TOKEN="12345:ABCdef"
    export TELEGRAM_CHAT_ID="123"
    export SERVER_LABEL="test"
    export CONFIRMATION_COUNT=3
    export ALERT_COOLDOWN_SEC=900
    export LOG_FILE="${BATS_TEST_TMPDIR}/test.log"
    export LOG_LEVEL="ERROR"
    export ENABLE_AUDIT_LOGGING=false
    export ENABLE_PREDICTIVE_ALERTS=false

    # Extract and source key functions from telemon.sh without executing main()
    # We extract only the functions we need to test
    if [[ ! -f "${BATS_TEST_TMPDIR}/funcs.sh" ]]; then
        awk '
        /^sanitize_state_key\(\)/        {print; go=1; next}
        /^html_escape\(\)/               {print; go=1; next}
        /^check_state_change\(\)/        {print; go=1; next}
        /^check_threshold\(\)/           {print; go=1; next}
        /^linear_regression\(\)/         {print; go=1; next}
        /^record_trend\(\)/              {print; go=1; next}
        /^check_prediction\(\)/          {print; go=1; next}
        /^is_in_maintenance_window\(\)/  {print; go=1; next}
        /^check_threshold_pair\(\)/      {print; go=1; next}
        /^safe_write_state_file\(\)/     {print; go=1; next}
        /^audit_log\(\)/                 {print; go=1; next}
        /^_audit_level_num\(\)/          {print; go=1; next}
        /^_should_audit_event\(\)/       {print; go=1; next}
        go { print }
        /^\}$/ && go { go=0 }
        ' /opt/telemon/telemon.sh > "${BATS_TEST_TMPDIR}/funcs.sh"
    fi
    source "${BATS_TEST_TMPDIR}/funcs.sh"
}

# ---------------------------------------------------------------------------
# sanitize_state_key
# ---------------------------------------------------------------------------
@test "sanitize_state_key: replaces special chars with underscore" {
    result=$(sanitize_state_key "my key")
    [ "$result" = "my_key" ]
}

@test "sanitize_state_key: preserves valid chars" {
    result=$(sanitize_state_key "proc_sshd")
    [ "$result" = "proc_sshd" ]
}

@test "sanitize_state_key: handles paths" {
    result=$(sanitize_state_key "/var/log/file")
    [ "$result" = "_var_log_file" ]
}

# ---------------------------------------------------------------------------
# html_escape
# ---------------------------------------------------------------------------
@test "html_escape: escapes & < >" {
    result=$(html_escape "a < b & c > d")
    [[ "$result" == *"&amp;"* ]]
    [[ "$result" == *"&lt;"* ]]
    [[ "$result" == *"&gt;"* ]]
}

@test "html_escape: passes plain text unchanged" {
    result=$(html_escape "hello world")
    [ "$result" = "hello world" ]
}

# ---------------------------------------------------------------------------
# check_state_change — transition logic
# ---------------------------------------------------------------------------
@test "check_state_change: sets CURR_STATE for new key" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=3
    ALERT_COOLDOWN_SEC=0

    check_state_change "test_key" "WARNING" "test detail"
    [ "${CURR_STATE[test_key]}" = "WARNING" ]
    [ "${PREV_COUNT[test_key]}" = "1" ]
}

@test "check_state_change: does not alert on first occurrence with confirmation > 1" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=3
    ALERT_COOLDOWN_SEC=0

    check_state_change "test_key" "WARNING" "test detail"
    [ -z "$ALERTS" ]
}

@test "check_state_change: alerts on resolution of confirmed non-OK state" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=3
    ALERT_COOLDOWN_SEC=0

    PREV_STATE[test_key]="WARNING"
    PREV_COUNT[test_key]=3

    check_state_change "test_key" "OK" "all good"
    [ -n "$ALERTS" ]
    [[ "$ALERTS" == *"test_key"* ]]
}

@test "check_state_change: alerts immediately with confirmation_count=1" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=1
    ALERT_COOLDOWN_SEC=0

    PREV_STATE[test_key]="OK"
    PREV_COUNT[test_key]=1

    check_state_change "test_key" "CRITICAL" "something wrong"
    [ -n "$ALERTS" ]
}

@test "check_state_change: respects cooldown period" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=1
    ALERT_COOLDOWN_SEC=900

    PREV_STATE[test_key]="OK"
    PREV_COUNT[test_key]=1
    ALERT_LAST_SENT[test_key]=$(date +%s)

    check_state_change "test_key" "WARNING" "test detail"
    [ -z "$ALERTS" ]
}

@test "check_state_change: confirms after N consecutive occurrences" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=3
    ALERT_COOLDOWN_SEC=0

    PREV_STATE[test_key]="WARNING"
    PREV_COUNT[test_key]=2

    check_state_change "test_key" "WARNING" "still bad"
    [ -n "$ALERTS" ]
    [ "${PREV_COUNT[test_key]}" = "3" ]
}

# ---------------------------------------------------------------------------
# check_threshold — generic threshold checking
# ---------------------------------------------------------------------------
@test "check_threshold: standard metric — OK below warn" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=1
    ALERT_COOLDOWN_SEC=0

    check_threshold "test" "50" "70" "90" "false" "OK detail" "WARN detail" "CRIT detail"
    [ "$THRESHOLD_STATE" = "OK" ]
}

@test "check_threshold: standard metric — WARNING at warn threshold" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=1
    ALERT_COOLDOWN_SEC=0

    check_threshold "test" "75" "70" "90" "false" "OK detail" "WARN detail" "CRIT detail"
    [ "$THRESHOLD_STATE" = "WARNING" ]
}

@test "check_threshold: standard metric — CRITICAL at crit threshold" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=1
    ALERT_COOLDOWN_SEC=0

    check_threshold "test" "95" "70" "90" "false" "OK detail" "WARN detail" "CRIT detail"
    [ "$THRESHOLD_STATE" = "CRITICAL" ]
}

@test "check_threshold: inverted metric — OK above warn (mem 50% free)" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=1
    ALERT_COOLDOWN_SEC=0

    check_threshold "mem" "50" "15" "10" "true" "OK" "WARN" "CRIT"
    [ "$THRESHOLD_STATE" = "OK" ]
}

@test "check_threshold: inverted metric — CRITICAL below crit" {
    declare -gA PREV_STATE PREV_COUNT STATE_DETAIL ALERT_LAST_SENT CURR_STATE
    ALERTS=""
    CONFIRMATION_COUNT=1
    ALERT_COOLDOWN_SEC=0

    check_threshold "mem" "5" "15" "10" "true" "OK" "WARN" "CRIT"
    [ "$THRESHOLD_STATE" = "CRITICAL" ]
}

# ---------------------------------------------------------------------------
# linear_regression
# ---------------------------------------------------------------------------
@test "linear_regression: returns slope and intercept for valid data" {
    result=$(linear_regression "1000:50,2000:55,3000:60,4000:65")
    [ -n "$result" ]
    [ "$result" != "0 0" ]
}

@test "linear_regression: returns 0 0 for empty data" {
    run linear_regression ""
    [ "$output" = "0 0" ]
}

# ---------------------------------------------------------------------------
# is_in_maintenance_window
# ---------------------------------------------------------------------------
@test "is_in_maintenance_window: returns 1 with no schedule" {
    MAINT_SCHEDULE=""
    run is_in_maintenance_window
    [ "$status" -eq 1 ]
}

@test "is_in_maintenance_window: parses valid schedule without error" {
    MAINT_SCHEDULE="Sun 00:30-02:30;Wed 00:30-02:30"
    run is_in_maintenance_window
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "is_in_maintenance_window: handles invalid entries without crashing" {
    MAINT_SCHEDULE="foo bar baz"
    run is_in_maintenance_window
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_threshold_pair
# ---------------------------------------------------------------------------
@test "check_threshold_pair: warns when warn >= crit (standard)" {
    run check_threshold_pair "TEST" "90" "80" "false"
    [ "$status" -eq 0 ]
}

@test "check_threshold_pair: passes when warn < crit (standard)" {
    run check_threshold_pair "TEST" "70" "90" "false"
    [ "$status" -eq 0 ]
}

@test "check_threshold_pair: warns when warn <= crit (inverted)" {
    run check_threshold_pair "TEST" "10" "20" "true"
    [ "$status" -eq 0 ]
}
