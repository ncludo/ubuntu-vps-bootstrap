#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="ubuntu-vps-bootstrap"
readonly PROGRAM_VERSION="0.1.0-dev"
readonly REQUIRED_OS_ID="ubuntu"
readonly REQUIRED_OS_VERSION="24.04"
readonly DEFAULT_LOCAL_CONFIG="./bootstrap.local.conf"

RUN_MODE="apply"
RUN_MODE_EXPLICIT=false
CONFIG_PATH=""
CONFIG_SOURCE="built-in defaults"

TIMEZONE=""
SWAP_MODE=""
SWAP_SIZE=""
AUTO_REBOOT=""
AUTO_REBOOT_TIME=""
REBOOT_AFTER_BOOTSTRAP=""
JOURNAL_MAX_USE=""
JOURNAL_MAX_RETENTION=""
declare -a ALLOW_TCP_PORTS=()
declare -a ALLOW_UDP_PORTS=()

log() {
    local level=$1
    shift

    printf '%s [%s] %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "$level" \
        "$*" >&2
}

info() {
    log "INFO" "$@"
}

warn() {
    log "WARN" "$@"
}

die() {
    log "ERROR" "$@"
    exit 1
}

on_error() {
    local exit_code=$1
    local line_number=$2
    local function_name=${FUNCNAME[1]:-main}

    log "ERROR" \
        "Unexpected failure: exit=${exit_code}, line=${line_number}, function=${function_name}"
}

install_error_trap() {
    trap 'on_error "$?" "$LINENO"' ERR
}

usage() {
    cat <<EOF
Usage:
  ${PROGRAM_NAME} [MODE] [OPTIONS]

Modes:
  apply               Apply the desired configuration (default)
  --apply             Same as "apply"
  --plan              Show resolved configuration and planned mode
  --audit             Run audit mode
  --help, -h          Show this help
  --version           Show program version

Options:
  --config FILE       Load configuration from FILE

Default configuration:
  If --config is not supplied and bootstrap.local.conf exists in the
  current directory, it is loaded automatically.

Notes:
  Configuration files are trusted Bash configuration and are sourced
  with root privileges.

  This development revision implements only the bootstrap foundation.
  It does not yet modify system configuration.
EOF
}

print_version() {
    printf '%s %s\n' "$PROGRAM_NAME" "$PROGRAM_VERSION"
}

set_run_mode() {
    local requested_mode=$1

    if [[ $RUN_MODE_EXPLICIT == true && $RUN_MODE != "$requested_mode" ]]; then
        die "Conflicting run modes: '$RUN_MODE' and '$requested_mode'."
    fi

    RUN_MODE=$requested_mode
    RUN_MODE_EXPLICIT=true
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            apply | --apply)
                set_run_mode "apply"
                shift
                ;;

            --plan)
                set_run_mode "plan"
                shift
                ;;

            --audit)
                set_run_mode "audit"
                shift
                ;;

            --config)
                (($# >= 2)) || die "--config requires a file path."
                [[ -z $CONFIG_PATH ]] || die "--config may only be specified once."

                CONFIG_PATH=$2
                shift 2
                ;;

            --config=*)
                [[ -z $CONFIG_PATH ]] || die "--config may only be specified once."

                CONFIG_PATH=${1#*=}
                [[ -n $CONFIG_PATH ]] || die "--config requires a non-empty file path."
                shift
                ;;

            --help | -h)
                usage
                exit 0
                ;;

            --version)
                print_version
                exit 0
                ;;

            --)
                shift
                (($# == 0)) || die "Unexpected positional argument: '$1'."
                ;;

            *)
                die "Unknown argument: '$1'. Use --help for usage."
                ;;
        esac
    done
}

require_root() {
    if ((EUID != 0)); then
        die "Root privileges are required. Run with sudo or as root."
    fi
}

require_supported_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing or unreadable."

    local os_id=""
    local os_version=""

    # /etc/os-release is trusted operating-system metadata.
    # shellcheck disable=SC1091
    source /etc/os-release

    os_id=${ID:-}
    os_version=${VERSION_ID:-}

    [[ $os_id == "$REQUIRED_OS_ID" ]] ||
        die "Unsupported OS: ID='${os_id:-unknown}'. Ubuntu is required."

    [[ $os_version == "$REQUIRED_OS_VERSION" ]] ||
        die "Unsupported Ubuntu version: '${os_version:-unknown}'. Ubuntu 24.04 is required."
}

require_commands() {
    local -a required_commands=(
        apt-get
        date
        flock
        systemctl
        uname
    )

    local command_name

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required command not found: $command_name"
    done
}

acquire_lock() {
    local lock_file="/run/lock/${PROGRAM_NAME}.lock"

    exec {BOOTSTRAP_LOCK_FD}>"$lock_file" ||
        die "Unable to open lock file: $lock_file"

    if ! flock -n "$BOOTSTRAP_LOCK_FD"; then
        die "Another ${PROGRAM_NAME} instance is already running."
    fi

    info "Acquired process lock: $lock_file"
}

set_default_config() {
    TIMEZONE="UTC"

    SWAP_MODE="auto"
    SWAP_SIZE=""

    AUTO_REBOOT=false
    AUTO_REBOOT_TIME="05:30"

    REBOOT_AFTER_BOOTSTRAP=false

    JOURNAL_MAX_USE="200M"
    JOURNAL_MAX_RETENTION="14day"

    ALLOW_TCP_PORTS=()
    ALLOW_UDP_PORTS=()
}

load_config() {
    set_default_config

    local config_file=""

    if [[ -n $CONFIG_PATH ]]; then
        config_file=$CONFIG_PATH

        [[ -f $config_file ]] ||
            die "Configuration file does not exist: $config_file"

        [[ -r $config_file ]] ||
            die "Configuration file is not readable: $config_file"
    elif [[ -f $DEFAULT_LOCAL_CONFIG ]]; then
        config_file=$DEFAULT_LOCAL_CONFIG
    fi

    if [[ -n $config_file ]]; then
        info "Loading configuration: $config_file"

        # Configuration is intentionally trusted Bash syntax.
        # shellcheck disable=SC1090
        source "$config_file"

        CONFIG_SOURCE=$config_file
    else
        info "No local configuration file found; using built-in defaults."
    fi
}

validate_boolean() {
    local name=$1
    local value=$2

    case "$value" in
        true | false) ;;
        *)
            die "$name must be 'true' or 'false'; got '$value'."
            ;;
    esac
}

validate_timezone() {
    [[ -n $TIMEZONE ]] || die "TIMEZONE must not be empty."

    [[ $TIMEZONE != /* ]] ||
        die "TIMEZONE must be a timezone name, not an absolute path."

    [[ $TIMEZONE != *".."* ]] ||
        die "TIMEZONE must not contain '..'."

    [[ $TIMEZONE != *[[:space:]]* ]] ||
        die "TIMEZONE must not contain whitespace."

    [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] ||
        die "Unknown timezone: '$TIMEZONE'."
}

validate_swap_config() {
    case "$SWAP_MODE" in
        auto | fixed | disabled) ;;
        *)
            die "SWAP_MODE must be auto, fixed, or disabled; got '$SWAP_MODE'."
            ;;
    esac

    if [[ $SWAP_MODE == fixed ]]; then
        [[ -n $SWAP_SIZE ]] ||
            die "SWAP_SIZE is required when SWAP_MODE=fixed."

        local normalized_size=${SWAP_SIZE^^}

        [[ $normalized_size =~ ^[1-9][0-9]*[KMGTP]$ ]] ||
            die "Invalid SWAP_SIZE '$SWAP_SIZE'. Example valid values: 512M, 2G."
    elif [[ -n $SWAP_SIZE ]]; then
        warn "SWAP_SIZE='$SWAP_SIZE' is ignored because SWAP_MODE='$SWAP_MODE'."
    fi
}

validate_reboot_time() {
    [[ $AUTO_REBOOT_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
        die "AUTO_REBOOT_TIME must use HH:MM (24-hour) format; got '$AUTO_REBOOT_TIME'."
}

validate_port_array() {
    local array_name=$1

    local declaration
    declaration=$(declare -p "$array_name" 2>/dev/null) ||
        die "Missing configuration array: $array_name"

    [[ $declaration == "declare -a "* ]] ||
        die "$array_name must be a Bash indexed array."

    local -n ports_ref=$array_name
    local -A seen=()
    local port

    for port in "${ports_ref[@]}"; do
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] ||
            die "$array_name contains invalid port: '$port'."

        ((10#$port <= 65535)) ||
            die "$array_name contains out-of-range port: '$port'."

        [[ -z ${seen[$port]+x} ]] ||
            die "$array_name contains duplicate port: '$port'."

        seen[$port]=1
    done
}

validate_config() {
    validate_timezone

    validate_swap_config

    validate_boolean "AUTO_REBOOT" "$AUTO_REBOOT"
    validate_boolean "REBOOT_AFTER_BOOTSTRAP" "$REBOOT_AFTER_BOOTSTRAP"

    validate_reboot_time

    [[ -n $JOURNAL_MAX_USE ]] ||
        die "JOURNAL_MAX_USE must not be empty."

    [[ -n $JOURNAL_MAX_RETENTION ]] ||
        die "JOURNAL_MAX_RETENTION must not be empty."

    validate_port_array "ALLOW_TCP_PORTS"
    validate_port_array "ALLOW_UDP_PORTS"

    info "Configuration validation passed."
}

print_resolved_config() {
    printf '\n'
    printf '=== RESOLVED CONFIGURATION ===\n'
    printf 'Mode:                    %s\n' "$RUN_MODE"
    printf 'Config source:           %s\n' "$CONFIG_SOURCE"
    printf 'Timezone:                %s\n' "$TIMEZONE"
    printf 'Swap mode:               %s\n' "$SWAP_MODE"
    printf 'Swap size:               %s\n' "${SWAP_SIZE:-<automatic/not set>}"
    printf 'Automatic reboot:        %s\n' "$AUTO_REBOOT"
    printf 'Automatic reboot time:   %s\n' "$AUTO_REBOOT_TIME"
    printf 'Final bootstrap reboot:  %s\n' "$REBOOT_AFTER_BOOTSTRAP"
    printf 'Journal max use:         %s\n' "$JOURNAL_MAX_USE"
    printf 'Journal retention:       %s\n' "$JOURNAL_MAX_RETENTION"

    printf 'Allowed TCP ports:       '
    if ((${#ALLOW_TCP_PORTS[@]} == 0)); then
        printf '<none>\n'
    else
        printf '%s\n' "${ALLOW_TCP_PORTS[*]}"
    fi

    printf 'Allowed UDP ports:       '
    if ((${#ALLOW_UDP_PORTS[@]} == 0)); then
        printf '<none>\n'
    else
        printf '%s\n' "${ALLOW_UDP_PORTS[*]}"
    fi
}

print_runtime_summary() {
    printf '\n'
    printf '=== RUNTIME ===\n'
    printf 'Program:                 %s %s\n' "$PROGRAM_NAME" "$PROGRAM_VERSION"
    printf 'Kernel:                  %s\n' "$(uname -r)"
    printf 'Required OS:             Ubuntu %s\n' "$REQUIRED_OS_VERSION"
    printf 'Effective UID:           %s\n' "$EUID"
}

run_current_mode() {
    case "$RUN_MODE" in
        apply)
            info "Apply mode selected."
            info "Foundation checks passed. No system-changing modules are implemented yet."
            ;;

        plan)
            info "Plan mode selected."
            info "Foundation checks passed. No system-changing modules are implemented yet."
            ;;

        audit)
            info "Audit mode selected."
            info "Foundation checks passed. Audit modules are not implemented yet."
            ;;

        *)
            die "Internal error: unknown run mode '$RUN_MODE'."
            ;;
    esac
}

main() {
    install_error_trap

    parse_args "$@"

    require_root
    require_supported_os
    require_commands
    acquire_lock

    load_config
    validate_config

    print_runtime_summary
    print_resolved_config

    run_current_mode
}

main "$@"
