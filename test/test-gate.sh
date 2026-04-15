#!/usr/bin/env bash
# test-gate.sh — Tests for the handoff gate (permission enforcement)
# Runs without actual SSH — mocks SSH_ORIGINAL_COMMAND and calls gate directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test setup
TEST_HOME="/tmp/handoff_test_$$"
PASS=0
FAIL=0
TOTAL=0

setup() {
    rm -rf "$TEST_HOME"
    mkdir -p "$TEST_HOME/.handoff/keys" "$TEST_HOME/.ssh"
    export HOME="$TEST_HOME"
    source "$PROJECT_DIR/lib/handoff-common.sh"
    echo '{"version":1,"devices":[]}' > "$HANDOFF_DEVICES"
    touch "$HANDOFF_ACCESS_LOG"
}

cleanup() {
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT

run_gate() {
    local fp="$1" cmd="$2"
    HOME="$TEST_HOME" SSH_ORIGINAL_COMMAND="$cmd" \
        /bin/bash "$PROJECT_DIR/bin/handoff" gate "$fp" 2>/dev/null || true
}

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$actual" == *"$expected"* ]]; then
        printf "  \033[0;32m PASS\033[0m %s\n" "$test_name"
        PASS=$((PASS + 1))
    else
        printf "  \033[0;31m FAIL\033[0m %s\n" "$test_name"
        printf "         expected: %s\n" "$expected"
        printf "         actual:   %s\n" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local test_name="$1" unexpected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$actual" != *"$unexpected"* ]]; then
        printf "  \033[0;32m PASS\033[0m %s\n" "$test_name"
        PASS=$((PASS + 1))
    else
        printf "  \033[0;31m FAIL\033[0m %s (should NOT contain '%s')\n" "$test_name" "$unexpected"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Setup ────────────────────────────────────────────────────────

echo ""
echo "  Handoff Gate Tests"
echo "  ══════════════════"
echo ""

setup

# Create test devices
devices_json_add_device "ActiveRW" "SHA256:active_rw" "dev_rw" '["main", "work-*"]' "false" "nonce1" "2027-01-01T00:00:00Z" "2027-01-03T00:00:00Z"
devices_json_update_device "SHA256:active_rw" "status" "active"

devices_json_add_device "ActiveRO" "SHA256:active_ro" "dev_ro" '["main"]' "true" "nonce2" "2027-01-01T00:00:00Z" "2027-01-03T00:00:00Z"
devices_json_update_device "SHA256:active_ro" "status" "active"

devices_json_add_device "Pending" "SHA256:pending" "dev_pending" '["*"]' "false" "nonce3" "2027-01-01T00:00:00Z" "2027-01-03T00:00:00Z"

devices_json_add_device "Expired" "SHA256:expired" "dev_expired" '["*"]' "false" "nonce4" "2020-01-01T00:00:00Z" "2020-01-03T00:00:00Z"
devices_json_update_device "SHA256:expired" "status" "active"

# ─── Test: Device lookup ──────────────────────────────────────────

echo "  Device Lookup"
echo "  ─────────────"

result=$(run_gate "SHA256:nonexistent" "list")
assert_eq "unknown device returns error:not_found" "error:not_found" "$result"

# ─── Test: Status gating ──────────────────────────────────────────

echo ""
echo "  Status Gating"
echo "  ─────────────"

result=$(run_gate "SHA256:pending" "list")
assert_eq "pending device can't list" "error:pending" "$result"

result=$(run_gate "SHA256:pending" "pair")
assert_eq "pending device can pair" "verify:" "$result"

result=$(run_gate "SHA256:expired" "list")
assert_eq "expired device can't list" "error:soft_expired" "$result"

result=$(run_gate "SHA256:expired" "renew")
assert_eq "expired device can renew" "requested" "$result"

# ─── Test: Session filtering ─────────────────────────────────────

echo ""
echo "  Session Filtering"
echo "  ─────────────────"

result=$(run_gate "SHA256:active_rw" "list")
assert_eq "list includes permissions header" "#permissions:" "$result"
assert_eq "list includes main session" "main:" "$result"

result=$(run_gate "SHA256:active_rw" "windows main")
# Should succeed (no error) — output depends on tmux state
assert_not_contains "windows for allowed session succeeds" "error:" "$result"

result=$(run_gate "SHA256:active_rw" "attach secret")
assert_eq "attach denied session returns error:denied" "error:denied" "$result"

result=$(run_gate "SHA256:active_ro" "windows secret")
assert_eq "windows denied session returns error:denied" "error:denied" "$result"

# ─── Test: Read-only enforcement ──────────────────────────────────

echo ""
echo "  Read-Only Enforcement"
echo "  ─────────────────────"

result=$(run_gate "SHA256:active_ro" "create-session test")
assert_eq "read-only can't create session" "error:read_only" "$result"

result=$(run_gate "SHA256:active_ro" "create-window main")
assert_eq "read-only can't create window" "error:read_only" "$result"

result=$(run_gate "SHA256:active_ro" "kill-session main")
assert_eq "read-only can't kill session" "error:read_only" "$result"

result=$(run_gate "SHA256:active_ro" "kill-window main 0")
assert_eq "read-only can't kill window" "error:read_only" "$result"

# ─── Test: Unknown commands ───────────────────────────────────────

echo ""
echo "  Command Validation"
echo "  ──────────────────"

result=$(run_gate "SHA256:active_rw" "ls -la")
assert_eq "arbitrary command rejected" "error:unknown_command" "$result"

result=$(run_gate "SHA256:active_rw" "rm -rf /")
assert_eq "dangerous command rejected" "error:unknown_command" "$result"

result=$(run_gate "SHA256:active_rw" "bash")
assert_eq "shell command rejected" "error:unknown_command" "$result"

# ─── Test: Access log ─────────────────────────────────────────────

echo ""
echo "  Access Logging"
echo "  ──────────────"

log_lines=$(wc -l < "$HANDOFF_ACCESS_LOG" | tr -d ' ')
TOTAL=$((TOTAL + 1))
if [[ "$log_lines" -gt 0 ]]; then
    printf "  \033[0;32m PASS\033[0m access log has %s entries\n" "$log_lines"
    PASS=$((PASS + 1))
else
    printf "  \033[0;31m FAIL\033[0m access log is empty\n"
    FAIL=$((FAIL + 1))
fi

# Check log contains JSON
first_line=$(head -1 "$HANDOFF_ACCESS_LOG")
TOTAL=$((TOTAL + 1))
if echo "$first_line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    printf "  \033[0;32m PASS\033[0m log entries are valid JSON\n"
    PASS=$((PASS + 1))
else
    printf "  \033[0;31m FAIL\033[0m log entries are not valid JSON\n"
    FAIL=$((FAIL + 1))
fi

# ─── Test: Verification code ─────────────────────────────────────

echo ""
echo "  Verification Code"
echo "  ─────────────────"

code1=$(source "$PROJECT_DIR/lib/handoff-common.sh" && derive_verification_code "SHA256:testfp" "abc123")
code2=$(source "$PROJECT_DIR/lib/handoff-common.sh" && derive_verification_code "SHA256:testfp" "abc123")
assert_eq "verification code is deterministic" "$code1" "$code2"

code3=$(source "$PROJECT_DIR/lib/handoff-common.sh" && derive_verification_code "SHA256:testfp" "xyz789")
TOTAL=$((TOTAL + 1))
if [[ "$code1" != "$code3" ]]; then
    printf "  \033[0;32m PASS\033[0m different nonce produces different code\n"
    PASS=$((PASS + 1))
else
    printf "  \033[0;31m FAIL\033[0m different nonce should produce different code\n"
    FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
if [[ ${#code1} -eq 6 ]]; then
    printf "  \033[0;32m PASS\033[0m code is 6 digits (got: %s)\n" "$code1"
    PASS=$((PASS + 1))
else
    printf "  \033[0;31m FAIL\033[0m code should be 6 digits (got: %s, length: %d)\n" "$code1" "${#code1}"
    FAIL=$((FAIL + 1))
fi

# ─── Test: Session pattern matching ──────────────────────────────

echo ""
echo "  Pattern Matching"
echo "  ────────────────"

source "$PROJECT_DIR/lib/handoff-common.sh"

session_matches_patterns "main" "main" "work-*" && r="match" || r="no"
assert_eq "exact match: main" "match" "$r"

session_matches_patterns "work-frontend" "main" "work-*" && r="match" || r="no"
assert_eq "glob match: work-frontend" "match" "$r"

session_matches_patterns "work-backend" "main" "work-*" && r="match" || r="no"
assert_eq "glob match: work-backend" "match" "$r"

session_matches_patterns "secret" "main" "work-*" && r="match" || r="no"
assert_eq "no match: secret" "no" "$r"

session_matches_patterns "anything" "*" && r="match" || r="no"
assert_eq "wildcard * matches anything" "match" "$r"

# ─── Summary ─────────────────────────────────────────────────────

echo ""
echo "  ══════════════════"
if [[ $FAIL -eq 0 ]]; then
    printf "  \033[0;32m ALL %d TESTS PASSED\033[0m\n" "$TOTAL"
else
    printf "  \033[0;31m %d/%d FAILED\033[0m\n" "$FAIL" "$TOTAL"
fi
echo ""

exit $FAIL
