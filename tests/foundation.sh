#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_NAME="foundation"
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
readonly BOOTSTRAP="${PROJECT_ROOT}/bootstrap.sh"

PASS=0
FAIL=0
TMP_DIR=""

cleanup() {
    if [[ -n ${TMP_DIR:-} && -d $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT

pass() {
    printf '[PASS] %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf '[FAIL] %s\n' "$1"
    FAIL=$((FAIL + 1))
}

require_test_environment() {
    if ((EUID != 0)); then
        printf 'ERROR: %s tests must run as root.\n' "$TEST_NAME" >&2
        printf 'Run: sudo ./tests/foundation.sh\n' >&2
        exit 1
    fi

    local command_name
    local -a required_commands=(
        flock
        grep
        mktemp
        runuser
    )

    for command_name in "${required_commands[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'ERROR: required test command not found: %s\n' "$command_name" >&2
            exit 1
        fi
    done

    [[ -x $BOOTSTRAP ]] || {
        printf 'ERROR: bootstrap script is not executable: %s\n' "$BOOTSTRAP" >&2
        exit 1
    }

    TMP_DIR="$(mktemp -d)"
}

run_capture() {
    local output_file=$1
    shift

    (
        cd "$TMP_DIR"
        "$@"
    ) >"$output_file" 2>&1
}

expect_ok() {
    local name=$1
    shift

    local output_file="$TMP_DIR/output"

    if run_capture "$output_file" "$@"; then
        pass "$name"
    else
        fail "$name"
        sed 's/^/       /' "$output_file"
    fi
}

expect_fail() {
    local name=$1
    shift

    local output_file="$TMP_DIR/output"

    if run_capture "$output_file" "$@"; then
        fail "$name (unexpected success)"
        sed 's/^/       /' "$output_file"
    else
        pass "$name"
    fi
}

expect_fail_contains() {
    local name=$1
    local expected_text=$2
    shift 2

    local output_file="$TMP_DIR/output"

    if run_capture "$output_file" "$@"; then
        fail "$name (unexpected success)"
        sed 's/^/       /' "$output_file"
        return
    fi

    if grep -Fq -- "$expected_text" "$output_file"; then
        pass "$name"
    else
        fail "$name (failed for an unexpected reason)"
        sed 's/^/       /' "$output_file"
    fi
}

test_basic_cli() {
    echo "=== BASIC CLI ==="

    expect_ok "--help" \
        "$BOOTSTRAP" --help

    expect_ok "--version" \
        "$BOOTSTRAP" --version

    expect_ok "default apply mode" \
        "$BOOTSTRAP"

    expect_ok "--plan" \
        "$BOOTSTRAP" --plan

    expect_ok "--audit" \
        "$BOOTSTRAP" --audit
}

test_argument_validation() {
    echo
    echo "=== ARGUMENT VALIDATION ==="

    expect_fail_contains \
        "unknown argument rejected" \
        "Unknown argument" \
        "$BOOTSTRAP" --definitely-invalid

    expect_fail_contains \
        "conflicting modes rejected" \
        "Conflicting run modes" \
        "$BOOTSTRAP" --plan --audit

    expect_fail_contains \
        "missing --config value rejected" \
        "--config requires a file path" \
        "$BOOTSTRAP" --config

    expect_fail_contains \
        "missing config file rejected" \
        "Configuration file does not exist" \
        "$BOOTSTRAP" --config "$TMP_DIR/does-not-exist.conf"
}

test_config_validation() {
    echo
    echo "=== CONFIG VALIDATION ==="

    cat >"$TMP_DIR/valid.conf" <<'EOF'
TIMEZONE="UTC"
SWAP_MODE="fixed"
SWAP_SIZE="2G"

AUTO_REBOOT=true
AUTO_REBOOT_TIME="04:15"
REBOOT_AFTER_BOOTSTRAP=false

JOURNAL_MAX_USE="300M"
JOURNAL_MAX_RETENTION="21day"

ALLOW_TCP_PORTS=(80 443)
ALLOW_UDP_PORTS=(53)
EOF

    expect_ok \
        "valid custom config accepted" \
        "$BOOTSTRAP" --plan --config "$TMP_DIR/valid.conf"

    local output_file="$TMP_DIR/resolved-output"

    if run_capture \
        "$output_file" \
        "$BOOTSTRAP" --plan --config "$TMP_DIR/valid.conf" &&
        grep -q 'Timezone:.*UTC' "$output_file" &&
        grep -q 'Swap mode:.*fixed' "$output_file" &&
        grep -q 'Swap size:.*2G' "$output_file" &&
        grep -q 'Allowed TCP ports:.*80 443' "$output_file"; then
        pass "custom config reflected in resolved configuration"
    else
        fail "custom config reflected in resolved configuration"
        sed 's/^/       /' "$output_file"
    fi

    cat >"$TMP_DIR/invalid-swap.conf" <<'EOF'
SWAP_MODE="potato"
EOF

    expect_fail_contains \
        "invalid SWAP_MODE rejected" \
        "SWAP_MODE must be auto, fixed, or disabled" \
        "$BOOTSTRAP" --plan --config "$TMP_DIR/invalid-swap.conf"

    cat >"$TMP_DIR/invalid-port.conf" <<'EOF'
ALLOW_TCP_PORTS=(443 70000)
EOF

    expect_fail_contains \
        "out-of-range TCP port rejected" \
        "out-of-range port" \
        "$BOOTSTRAP" --plan --config "$TMP_DIR/invalid-port.conf"

    cat >"$TMP_DIR/duplicate-port.conf" <<'EOF'
ALLOW_TCP_PORTS=(443 443)
EOF

    expect_fail_contains \
        "duplicate TCP port rejected" \
        "duplicate port" \
        "$BOOTSTRAP" --plan --config "$TMP_DIR/duplicate-port.conf"

    cat >"$TMP_DIR/invalid-time.conf" <<'EOF'
AUTO_REBOOT_TIME="25:99"
EOF

    expect_fail_contains \
        "invalid reboot time rejected" \
        "AUTO_REBOOT_TIME must use HH:MM" \
        "$BOOTSTRAP" --plan --config "$TMP_DIR/invalid-time.conf"
}

test_root_check() {
    echo
    echo "=== ROOT CHECK ==="

    local nonroot_script="$TMP_DIR/bootstrap-nonroot.sh"

    cp "$BOOTSTRAP" "$nonroot_script"
    chmod 755 "$TMP_DIR"
    chmod 755 "$nonroot_script"

    expect_fail_contains \
        "non-root execution rejected for correct reason" \
        "Root privileges are required" \
        runuser -u nobody -- "$nonroot_script" --plan
}

test_process_lock() {
    echo
    echo "=== PROCESS LOCK ==="

    local lock_file="/run/lock/ubuntu-vps-bootstrap.lock"
    local output_file="$TMP_DIR/lock-output"

    exec 9>"$lock_file"

    if ! flock -n 9; then
        fail "unable to acquire test lock"
        exec 9>&-
        return
    fi

    if run_capture "$output_file" "$BOOTSTRAP" --plan; then
        fail "second instance rejected by flock (unexpected success)"
    elif grep -Fq \
        "Another ubuntu-vps-bootstrap instance is already running" \
        "$output_file"; then
        pass "second instance rejected by flock"
    else
        fail "second instance rejected, but not for expected lock reason"
        sed 's/^/       /' "$output_file"
    fi

    flock -u 9
    exec 9>&-
}

print_summary() {
    echo
    echo "=== SUMMARY ==="
    printf 'PASS: %d\n' "$PASS"
    printf 'FAIL: %d\n' "$FAIL"

    if ((FAIL == 0)); then
        echo
        echo "FOUNDATION REGRESSION TEST: PASS"
        return 0
    fi

    echo
    echo "FOUNDATION REGRESSION TEST: FAIL"
    return 1
}

main() {
    require_test_environment

    test_basic_cli
    test_argument_validation
    test_config_validation
    test_root_check
    test_process_lock

    print_summary
}

main "$@"
