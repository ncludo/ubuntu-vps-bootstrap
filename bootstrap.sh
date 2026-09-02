#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME="ubuntu-vps-bootstrap"
readonly PROGRAM_VERSION="0.1.0-dev"
readonly REQUIRED_OS_ID="ubuntu"
readonly REQUIRED_OS_VERSION="24.04"
readonly DEFAULT_LOCAL_CONFIG="./bootstrap.local.conf"

readonly SYSTEM_UPGRADE=true
readonly APT_LOCK_TIMEOUT_SECONDS=600
readonly APT_UPDATE_LOCK_RETRY_SECONDS=5
readonly CLOUD_INIT_WAIT_TIMEOUT_SECONDS=600
readonly SWAP_FILE_PATH="/swapfile"
readonly SWAP_DISK_RESERVE_MIB=1024
readonly IPV6_SYSCTL_FILE="/etc/sysctl.d/99-ubuntu-vps-bootstrap-ipv6.conf"

readonly -a BASE_PACKAGES=(
    ca-certificates
    curl
    dnsutils
    git
    htop
    iputils-ping
    jq
    lsof
    mtr-tiny
    netcat-openbsd
    openssl
    psmisc
    rsync
    traceroute
    ufw
    unattended-upgrades
    unzip
)

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
declare -a EXTRA_PACKAGES=()

declare -a RESOLVED_EXTRA_PACKAGES=()
declare -a CURRENT_MISSING_BASE_PACKAGES=()
declare -a CURRENT_MISSING_EXTRA_PACKAGES=()
CURRENT_UPGRADEABLE_COUNT="unknown"

CURRENT_OS_PRETTY=""
CURRENT_KERNEL=""
CURRENT_UPTIME_SECONDS=0

CURRENT_RAM_TOTAL_MIB=0
CURRENT_SWAP_TOTAL_MIB=0
CURRENT_SWAP_USED_MIB=0
CURRENT_SWAP_DEVICE_COUNT=0

CURRENT_ROOT_SOURCE=""
CURRENT_ROOT_FSTYPE=""
CURRENT_ROOT_TOTAL_MIB=0
CURRENT_ROOT_USED_MIB=0
CURRENT_ROOT_AVAIL_MIB=0
CURRENT_ROOT_USE_PERCENT=""

CURRENT_TIMEZONE=""
CURRENT_NTP_ENABLED="unknown"
CURRENT_NTP_SYNCHRONIZED="unknown"

CURRENT_REBOOT_REQUIRED=false
declare -a CURRENT_FAILED_UNITS=()

CURRENT_IPV6_SYSCTL_AVAILABLE=false
declare -a CURRENT_IPV6_DISABLE_STATE=()
declare -a CURRENT_IPV6_ADDRESSES=()
declare -a CURRENT_IPV6_GLOBAL_ADDRESSES=()
declare -a CURRENT_IPV6_ROUTES=()

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

  Apply mode currently configures packages/system updates, timezone/NTP, swap, and IPv6 disable.
  Other baseline modules remain under development.
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
        df
        dpkg
        dpkg-query
        findmnt
        flock
        grep
        ip
        mktemp
        sleep
        systemctl
        tee
        timedatectl
        timeout
        uname
        chmod
        cp
        dd
        mkswap
        rm
        stat
        swapoff
        swapon
        mv
        sysctl
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
    EXTRA_PACKAGES=()
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

validate_extra_packages() {
    local declaration=""

    declaration=$(declare -p EXTRA_PACKAGES 2>/dev/null) ||
        die "Missing configuration array: EXTRA_PACKAGES"

    [[ $declaration == "declare -a "* ]] ||
        die "EXTRA_PACKAGES must be a Bash indexed array."

    RESOLVED_EXTRA_PACKAGES=()

    local -A seen=()
    local package=""

    for package in "${BASE_PACKAGES[@]}"; do
        seen[$package]=1
    done

    for package in "${EXTRA_PACKAGES[@]}"; do
        if ! dpkg --validate-pkgname "$package" >/dev/null 2>&1; then
            die "Invalid package name in EXTRA_PACKAGES: '$package'."
        fi

        if [[ -z ${seen[$package]+x} ]]; then
            RESOLVED_EXTRA_PACKAGES+=("$package")
            seen[$package]=1
        fi
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
    validate_extra_packages

    info "Configuration validation passed."
}

detect_os_state() {
    # /etc/os-release was already validated by require_supported_os().
    # shellcheck disable=SC1091
    source /etc/os-release

    CURRENT_OS_PRETTY=${PRETTY_NAME:-Ubuntu}
    CURRENT_KERNEL=$(uname -r)

    local uptime_raw=""

    read -r uptime_raw _ </proc/uptime ||
        die "Unable to read /proc/uptime."

    CURRENT_UPTIME_SECONDS=${uptime_raw%%.*}
}

detect_resource_state() {
    local mem_total_kib=0
    local swap_total_kib=0
    local swap_free_kib=0
    local key=""
    local value=""

    while read -r key value _; do
        case "$key" in
            MemTotal:)
                mem_total_kib=$value
                ;;
            SwapTotal:)
                swap_total_kib=$value
                ;;
            SwapFree:)
                swap_free_kib=$value
                ;;
        esac
    done </proc/meminfo

    [[ $mem_total_kib =~ ^[0-9]+$ ]] ||
        die "Unable to detect total RAM."

    [[ $swap_total_kib =~ ^[0-9]+$ ]] ||
        die "Unable to detect total swap."

    [[ $swap_free_kib =~ ^[0-9]+$ ]] ||
        die "Unable to detect free swap."

    CURRENT_RAM_TOTAL_MIB=$((mem_total_kib / 1024))
    CURRENT_SWAP_TOTAL_MIB=$((swap_total_kib / 1024))
    CURRENT_SWAP_USED_MIB=$(((swap_total_kib - swap_free_kib) / 1024))

    CURRENT_SWAP_DEVICE_COUNT=0

    if [[ -r /proc/swaps ]]; then
        local line=""
        local line_number=0

        while IFS= read -r line; do
            if ((line_number == 0)); then
                line_number=1
                continue
            fi

            if [[ -n $line ]]; then
                CURRENT_SWAP_DEVICE_COUNT=$((CURRENT_SWAP_DEVICE_COUNT + 1))
            fi
        done </proc/swaps
    fi

    read -r CURRENT_ROOT_SOURCE CURRENT_ROOT_FSTYPE < <(
        findmnt -n -o SOURCE,FSTYPE /
    ) || die "Unable to detect root filesystem."

    local -a df_lines=()
    mapfile -t df_lines < <(
        df -B1 --output=size,used,avail,pcent /
    )

    ((${#df_lines[@]} >= 2)) ||
        die "Unable to detect root filesystem usage."

    local root_size_bytes=0
    local root_used_bytes=0
    local root_avail_bytes=0

    read -r \
        root_size_bytes \
        root_used_bytes \
        root_avail_bytes \
        CURRENT_ROOT_USE_PERCENT \
        <<<"${df_lines[1]}"

    [[ $root_size_bytes =~ ^[0-9]+$ ]] ||
        die "Invalid root filesystem size."

    [[ $root_used_bytes =~ ^[0-9]+$ ]] ||
        die "Invalid root filesystem used size."

    [[ $root_avail_bytes =~ ^[0-9]+$ ]] ||
        die "Invalid root filesystem available size."

    CURRENT_ROOT_TOTAL_MIB=$((root_size_bytes / 1024 / 1024))
    CURRENT_ROOT_USED_MIB=$((root_used_bytes / 1024 / 1024))
    CURRENT_ROOT_AVAIL_MIB=$((root_avail_bytes / 1024 / 1024))
}

detect_time_state() {
    CURRENT_TIMEZONE=$(
        timedatectl show \
            --property=Timezone \
            --value 2>/dev/null || true
    )

    CURRENT_NTP_ENABLED=$(
        timedatectl show \
            --property=NTP \
            --value 2>/dev/null || true
    )

    CURRENT_NTP_SYNCHRONIZED=$(
        timedatectl show \
            --property=NTPSynchronized \
            --value 2>/dev/null || true
    )

    [[ -n $CURRENT_TIMEZONE ]] ||
        CURRENT_TIMEZONE="unknown"

    [[ -n $CURRENT_NTP_ENABLED ]] ||
        CURRENT_NTP_ENABLED="unknown"

    [[ -n $CURRENT_NTP_SYNCHRONIZED ]] ||
        CURRENT_NTP_SYNCHRONIZED="unknown"
}

detect_systemd_state() {
    if [[ -e /var/run/reboot-required ]]; then
        CURRENT_REBOOT_REQUIRED=true
    else
        CURRENT_REBOOT_REQUIRED=false
    fi

    CURRENT_FAILED_UNITS=()

    mapfile -t CURRENT_FAILED_UNITS < <(
        systemctl \
            --failed \
            --no-legend \
            --plain 2>/dev/null || true
    )
}

detect_ipv6_state() {
    CURRENT_IPV6_SYSCTL_AVAILABLE=false
    CURRENT_IPV6_DISABLE_STATE=()
    CURRENT_IPV6_ADDRESSES=()
    CURRENT_IPV6_GLOBAL_ADDRESSES=()
    CURRENT_IPV6_ROUTES=()

    if [[ -d /proc/sys/net/ipv6/conf ]]; then
        CURRENT_IPV6_SYSCTL_AVAILABLE=true

        local path=""
        local interface_name=""
        local value=""

        for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
            [[ -r $path ]] || continue

            read -r value <"$path" ||
                die "Unable to read IPv6 sysctl state: $path"

            interface_name=${path%/disable_ipv6}
            interface_name=${interface_name##*/}

            CURRENT_IPV6_DISABLE_STATE+=(
                "${interface_name}=${value}"
            )
        done
    fi

    mapfile -t CURRENT_IPV6_ADDRESSES < <(
        ip -6 -o address show 2>/dev/null || true
    )

    mapfile -t CURRENT_IPV6_GLOBAL_ADDRESSES < <(
        ip -6 -o address show scope global 2>/dev/null || true
    )

    mapfile -t CURRENT_IPV6_ROUTES < <(
        ip -6 route show 2>/dev/null || true
    )
}

is_package_installed() {
    local package=$1
    local status=""

    status=$(
        dpkg-query \
            --show \
            --showformat='${Status}' \
            -- "$package" 2>/dev/null || true
    )

    [[ $status == "install ok installed" ]]
}

detect_package_state() {
    CURRENT_MISSING_BASE_PACKAGES=()
    CURRENT_MISSING_EXTRA_PACKAGES=()
    CURRENT_UPGRADEABLE_COUNT="unknown"

    local package=""

    for package in "${BASE_PACKAGES[@]}"; do
        if ! is_package_installed "$package"; then
            CURRENT_MISSING_BASE_PACKAGES+=("$package")
        fi
    done

    for package in "${RESOLVED_EXTRA_PACKAGES[@]}"; do
        if ! is_package_installed "$package"; then
            CURRENT_MISSING_EXTRA_PACKAGES+=("$package")
        fi
    done

    local simulation=""

    if simulation=$(
        env \
            DEBIAN_FRONTEND=noninteractive \
            LC_ALL=C \
            apt-get \
            --simulate \
            -o Debug::NoLocking=1 \
            upgrade \
            --with-new-pkgs 2>/dev/null
    ); then
        CURRENT_UPGRADEABLE_COUNT=$(
            grep -c '^Inst ' <<<"$simulation" || true
        )
    fi
}

detect_system_state() {
    info "Detecting current system state."

    detect_os_state
    detect_resource_state
    detect_time_state
    detect_systemd_state
    detect_ipv6_state
    detect_package_state

    info "Current system state detection completed."
}

print_current_state() {
    printf '\n'
    printf '=== CURRENT STATE ===\n'

    printf 'OS:                      %s\n' "$CURRENT_OS_PRETTY"
    printf 'Kernel:                  %s\n' "$CURRENT_KERNEL"
    printf 'Uptime:                  %s seconds\n' "$CURRENT_UPTIME_SECONDS"

    printf 'RAM total:               %s MiB\n' "$CURRENT_RAM_TOTAL_MIB"
    printf 'Swap total:              %s MiB\n' "$CURRENT_SWAP_TOTAL_MIB"
    printf 'Swap used:               %s MiB\n' "$CURRENT_SWAP_USED_MIB"
    printf 'Active swap devices:     %s\n' "$CURRENT_SWAP_DEVICE_COUNT"

    printf 'Root filesystem:         %s (%s)\n' \
        "$CURRENT_ROOT_SOURCE" \
        "$CURRENT_ROOT_FSTYPE"

    printf 'Root total:              %s MiB\n' "$CURRENT_ROOT_TOTAL_MIB"
    printf 'Root used:               %s MiB\n' "$CURRENT_ROOT_USED_MIB"
    printf 'Root available:          %s MiB\n' "$CURRENT_ROOT_AVAIL_MIB"
    printf 'Root usage:              %s\n' "$CURRENT_ROOT_USE_PERCENT"

    printf 'Current timezone:        %s\n' "$CURRENT_TIMEZONE"
    printf 'NTP enabled:             %s\n' "$CURRENT_NTP_ENABLED"
    printf 'NTP synchronized:        %s\n' "$CURRENT_NTP_SYNCHRONIZED"

    printf 'Reboot required:         %s\n' "$CURRENT_REBOOT_REQUIRED"
    printf 'Failed systemd units:    %s\n' "${#CURRENT_FAILED_UNITS[@]}"

    local unit=""

    for unit in "${CURRENT_FAILED_UNITS[@]}"; do
        printf '  failed: %s\n' "$unit"
    done

    printf 'IPv6 sysctl available:   %s\n' "$CURRENT_IPV6_SYSCTL_AVAILABLE"

    printf 'IPv6 disable state:      '

    if ((${#CURRENT_IPV6_DISABLE_STATE[@]} == 0)); then
        printf '<none>\n'
    else
        printf '%s\n' "${CURRENT_IPV6_DISABLE_STATE[*]}"
    fi

    printf 'IPv6 addresses:          %s\n' "${#CURRENT_IPV6_ADDRESSES[@]}"

    local item=""

    for item in "${CURRENT_IPV6_ADDRESSES[@]}"; do
        printf '  addr: %s\n' "$item"
    done

    printf 'IPv6 global addresses:   %s\n' \
        "${#CURRENT_IPV6_GLOBAL_ADDRESSES[@]}"

    for item in "${CURRENT_IPV6_GLOBAL_ADDRESSES[@]}"; do
        printf '  global: %s\n' "$item"
    done

    printf 'IPv6 routes:             %s\n' "${#CURRENT_IPV6_ROUTES[@]}"

    for item in "${CURRENT_IPV6_ROUTES[@]}"; do
        printf '  route: %s\n' "$item"
    done
}

print_package_list() {
    local label=$1
    shift

    printf '%-25s' "$label"

    if (($# == 0)); then
        printf '<none>\n'
    else
        printf '%s\n' "$*"
    fi
}

print_package_state() {
    printf '\n'
    printf '=== PACKAGES / UPDATES ===\n'

    printf 'System upgrade:          mandatory\n'
    printf 'Release upgrade:         never\n'
    printf 'APT frontend:            apt-get\n'
    printf 'APT environment:         DEBIAN_FRONTEND=noninteractive\n'
    printf 'Upgrade strategy:        upgrade --with-new-pkgs\n'
    printf 'Package removals:        not allowed by upgrade strategy\n'
    printf 'Phased updates:          respected\n'
    printf 'Package holds:           respected\n'
    printf 'APT lock wait:           %s seconds\n' "$APT_LOCK_TIMEOUT_SECONDS"

    printf 'Base packages:           %s\n' "${#BASE_PACKAGES[@]}"
    printf 'Missing base packages:   %s\n' \
        "${#CURRENT_MISSING_BASE_PACKAGES[@]}"

    print_package_list \
        '  missing base:' \
        "${CURRENT_MISSING_BASE_PACKAGES[@]}"

    printf 'Extra packages:          %s\n' \
        "${#RESOLVED_EXTRA_PACKAGES[@]}"

    print_package_list \
        '  configured extra:' \
        "${RESOLVED_EXTRA_PACKAGES[@]}"

    printf 'Missing extra packages:  %s\n' \
        "${#CURRENT_MISSING_EXTRA_PACKAGES[@]}"

    print_package_list \
        '  missing extra:' \
        "${CURRENT_MISSING_EXTRA_PACKAGES[@]}"

    printf 'Upgradeable packages:    %s (current APT index)\n' \
        "$CURRENT_UPGRADEABLE_COUNT"
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

    printf 'Extra packages:          '
    if ((${#RESOLVED_EXTRA_PACKAGES[@]} == 0)); then
        printf '<none>\n'
    else
        printf '%s\n' "${RESOLVED_EXTRA_PACKAGES[*]}"
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

wait_for_cloud_init() {
    if ! command -v cloud-init >/dev/null 2>&1; then
        info "cloud-init is not installed; skipping cloud-init wait."
        return
    fi

    info "Waiting for cloud-init to finish."

    local exit_code=0

    if timeout \
        --foreground \
        "${CLOUD_INIT_WAIT_TIMEOUT_SECONDS}s" \
        cloud-init status --wait; then
        info "cloud-init completed successfully."
        return
    else
        exit_code=$?
    fi

    case "$exit_code" in
        2)
            warn "cloud-init completed with recoverable errors (exit=2); continuing."
            ;;
        124)
            die "Timed out waiting for cloud-init after ${CLOUD_INIT_WAIT_TIMEOUT_SECONDS} seconds."
            ;;
        1)
            die "cloud-init reported a critical failure (exit=1)."
            ;;
        *)
            die "cloud-init wait failed with unexpected exit code ${exit_code}."
            ;;
    esac
}

apt_get() {
    env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        apt-get \
        -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT_SECONDS}" \
        "$@"
}

apt_get_dpkg_safe() {
    apt_get \
        -o 'Dpkg::Options::=--force-confdef' \
        -o 'Dpkg::Options::=--force-confold' \
        "$@"
}

apt_update_with_lock_retry() {
    local output_file=""
    output_file=$(mktemp)

    local deadline=$((SECONDS + APT_LOCK_TIMEOUT_SECONDS))

    while true; do
        : >"$output_file"

        info "Refreshing APT package index."

        if apt_get \
            update \
            --error-on=any \
            2>&1 | tee "$output_file"; then
            rm -f -- "$output_file"
            info "APT package index refreshed successfully."
            return
        fi

        if grep -Eq \
            'Could not get lock|Unable to acquire.*lock|Could not open lock file' \
            "$output_file"; then

            if ((SECONDS >= deadline)); then
                rm -f -- "$output_file"
                die "Timed out waiting for APT package-index lock."
            fi

            warn "APT package index is locked by another process; retrying in ${APT_UPDATE_LOCK_RETRY_SECONDS}s."
            sleep "$APT_UPDATE_LOCK_RETRY_SECONDS"
            continue
        fi

        rm -f -- "$output_file"
        die "apt-get update failed."
    done
}

upgrade_system_packages() {
    [[ $SYSTEM_UPGRADE == true ]] ||
        die "Internal policy error: SYSTEM_UPGRADE must remain enabled."

    info "Applying safe Ubuntu 24.04 package upgrades."

    apt_get_dpkg_safe \
        upgrade \
        --with-new-pkgs \
        --assume-yes

    info "Safe package upgrade completed."
}

install_missing_packages() {
    detect_package_state

    local -a missing_packages=(
        "${CURRENT_MISSING_BASE_PACKAGES[@]}"
        "${CURRENT_MISSING_EXTRA_PACKAGES[@]}"
    )

    if ((${#missing_packages[@]} == 0)); then
        info "All configured base and extra packages are already installed."
        return
    fi

    info "Installing ${#missing_packages[@]} missing package(s): ${missing_packages[*]}"

    apt_get_dpkg_safe \
        install \
        --assume-yes \
        -- \
        "${missing_packages[@]}"

    info "Configured package installation completed."
}

verify_package_manager_health() {
    info "Checking APT dependency health."

    apt_get check

    local audit_output=""

    if ! audit_output=$(dpkg --audit 2>&1); then
        printf '%s\n' "$audit_output" >&2
        die "dpkg audit failed."
    fi

    if [[ -n ${audit_output//[[:space:]]/} ]]; then
        printf '%s\n' "$audit_output" >&2
        die "dpkg audit reported an inconsistent package state."
    fi

    info "APT/dpkg health checks passed."
}

apply_packages_and_updates() {
    info "Starting mandatory packages/system-update module."

    wait_for_cloud_init

    apt_update_with_lock_retry
    upgrade_system_packages
    install_missing_packages
    verify_package_manager_health

    detect_systemd_state
    detect_package_state

    printf '\n'
    printf '=== PACKAGES / UPDATES AFTER APPLY ===\n'
    print_package_state

    info "Packages/system-update module completed."
}

apply_timezone_and_ntp() {
    info "Starting timezone/NTP module."

    detect_time_state

    if [[ $CURRENT_TIMEZONE == "$TIMEZONE" ]]; then
        info "Timezone is already configured: $TIMEZONE"
    else
        info "Setting timezone: ${CURRENT_TIMEZONE} -> ${TIMEZONE}"
        timedatectl set-timezone "$TIMEZONE"
    fi

    detect_time_state

    if [[ $CURRENT_NTP_ENABLED == yes ]]; then
        info "Network time synchronization is already enabled."
    else
        info "Enabling network time synchronization."
        timedatectl set-ntp true
    fi

    detect_time_state

    [[ $CURRENT_TIMEZONE == "$TIMEZONE" ]] ||
        die "Timezone verification failed: expected '$TIMEZONE', got '$CURRENT_TIMEZONE'."

    [[ $CURRENT_NTP_ENABLED == yes ]] ||
        die "NTP verification failed: expected enabled, got '$CURRENT_NTP_ENABLED'."

    printf '\n'
    printf '=== TIME / NTP AFTER APPLY ===\n'
    printf 'Timezone:                %s\n' "$CURRENT_TIMEZONE"
    printf 'NTP enabled:             %s\n' "$CURRENT_NTP_ENABLED"
    printf 'NTP synchronized:        %s\n' "$CURRENT_NTP_SYNCHRONIZED"

    if [[ $CURRENT_NTP_SYNCHRONIZED == yes ]]; then
        info "System clock is synchronized."
    else
        warn "NTP is enabled but the system clock is not synchronized yet."
    fi

    info "Timezone/NTP module completed."
}

swap_size_to_kib() {
    local value=${1^^}
    local number=${value%?}
    local unit=${value: -1}

    case "$unit" in
        K)
            printf '%s\n' "$((10#$number))"
            ;;
        M)
            printf '%s\n' "$((10#$number * 1024))"
            ;;
        G)
            printf '%s\n' "$((10#$number * 1024 * 1024))"
            ;;
        T)
            printf '%s\n' "$((10#$number * 1024 * 1024 * 1024))"
            ;;
        P)
            printf '%s\n' "$((10#$number * 1024 * 1024 * 1024 * 1024))"
            ;;
        *)
            die "Unable to convert swap size '$1'."
            ;;
    esac
}

resolve_auto_swap_size() {
    local desired_mib=0
    local maximum_safe_mib=0
    local target_mib=0

    if ((CURRENT_RAM_TOTAL_MIB <= 4096)); then
        desired_mib=2048
    else
        desired_mib=4096
    fi

    if ((CURRENT_ROOT_AVAIL_MIB > SWAP_DISK_RESERVE_MIB)); then
        maximum_safe_mib=$((CURRENT_ROOT_AVAIL_MIB - SWAP_DISK_RESERVE_MIB))
    fi

    if ((maximum_safe_mib >= desired_mib)); then
        target_mib=$desired_mib
    elif ((maximum_safe_mib >= 1024)); then
        target_mib=1024
    elif ((maximum_safe_mib >= 512)); then
        target_mib=512
    else
        die \
            "Insufficient disk space for automatic swap while preserving ${SWAP_DISK_RESERVE_MIB} MiB free."
    fi

    case "$target_mib" in
        4096)
            printf '4G\n'
            ;;
        2048)
            printf '2G\n'
            ;;
        1024)
            printf '1G\n'
            ;;
        512)
            printf '512M\n'
            ;;
        *)
            die "Unexpected automatic swap size: ${target_mib} MiB."
            ;;
    esac
}

apply_swap() {
    info "Starting swap module."

    detect_resource_state

    if [[ $SWAP_MODE == disabled ]]; then
        info "Swap creation is disabled; existing swap is preserved."
        info "Swap module completed."
        return
    fi

    if ((CURRENT_SWAP_DEVICE_COUNT > 0 || CURRENT_SWAP_TOTAL_MIB > 0)); then
        info \
            "Existing active swap detected (${CURRENT_SWAP_TOTAL_MIB} MiB, ${CURRENT_SWAP_DEVICE_COUNT} device(s)); preserving it."
        info "Swap module completed."
        return
    fi

    if [[ -e $SWAP_FILE_PATH ]]; then
        die \
            "$SWAP_FILE_PATH already exists while no active swap was detected; refusing to overwrite it."
    fi

    if grep -Ev \
        '^[[:space:]]*(#|$)' \
        /etc/fstab |
        grep -Eq '[[:space:]]swap[[:space:]]'; then
        die \
            "/etc/fstab contains configured but inactive swap; refusing to create a second swap configuration."
    fi

    case "$CURRENT_ROOT_FSTYPE" in
        ext4 | xfs) ;;
        btrfs)
            die "Automatic swapfile creation on btrfs is outside this baseline."
            ;;
        *)
            die \
                "Unsupported root filesystem for managed swapfile: $CURRENT_ROOT_FSTYPE"
            ;;
    esac

    local target_size=""
    local target_kib=0
    local target_mib=0

    case "$SWAP_MODE" in
        auto)
            target_size=$(resolve_auto_swap_size)

            info \
                "Automatic swap target: ${target_size} (RAM ${CURRENT_RAM_TOTAL_MIB} MiB, root available ${CURRENT_ROOT_AVAIL_MIB} MiB)."
            ;;
        fixed)
            target_size=${SWAP_SIZE^^}
            info "Fixed swap target: $target_size."
            ;;
        *)
            die "Unexpected SWAP_MODE '$SWAP_MODE'."
            ;;
    esac

    target_kib=$(swap_size_to_kib "$target_size")
    target_mib=$(((target_kib + 1023) / 1024))

    if ((CURRENT_ROOT_AVAIL_MIB < target_mib + SWAP_DISK_RESERVE_MIB)); then
        die \
            "Insufficient disk space for ${target_size} swap while preserving ${SWAP_DISK_RESERVE_MIB} MiB free."
    fi

    local dd_bs=""
    local dd_count=0

    if ((target_kib % 1024 == 0)); then
        dd_bs="1M"
        dd_count=$((target_kib / 1024))
    else
        dd_bs="1K"
        dd_count=$target_kib
    fi

    info "Creating managed swapfile: $SWAP_FILE_PATH ($target_size)."

    if ! dd \
        if=/dev/zero \
        of="$SWAP_FILE_PATH" \
        bs="$dd_bs" \
        count="$dd_count" \
        conv=fsync \
        status=none; then
        rm -f "$SWAP_FILE_PATH"
        die "Failed to allocate $SWAP_FILE_PATH."
    fi

    chmod 600 "$SWAP_FILE_PATH"

    if ! mkswap "$SWAP_FILE_PATH" >/dev/null; then
        rm -f "$SWAP_FILE_PATH"
        die "Failed to initialize $SWAP_FILE_PATH."
    fi

    local fstab_backup=""
    local fstab_entry="$SWAP_FILE_PATH none swap sw 0 0"

    fstab_backup=$(mktemp /etc/fstab.bootstrap.swap.XXXXXX)

    if ! cp \
        --preserve=mode,ownership,timestamps \
        /etc/fstab \
        "$fstab_backup"; then
        rm -f "$fstab_backup" "$SWAP_FILE_PATH"
        die "Failed to back up /etc/fstab."
    fi

    if ! printf '%s\n' "$fstab_entry" >>/etc/fstab; then
        cp "$fstab_backup" /etc/fstab
        rm -f "$SWAP_FILE_PATH"
        die "Failed to update /etc/fstab."
    fi

    if ! swapon "$SWAP_FILE_PATH"; then
        cp "$fstab_backup" /etc/fstab
        rm -f "$SWAP_FILE_PATH"
        die "Failed to activate $SWAP_FILE_PATH."
    fi

    detect_resource_state

    local permission=""
    local fstab_entry_count=0

    permission=$(stat -c '%a' "$SWAP_FILE_PATH")

    fstab_entry_count=$(
        grep -Fxc "$fstab_entry" /etc/fstab || true
    )

    if ((CURRENT_SWAP_DEVICE_COUNT == 0 || CURRENT_SWAP_TOTAL_MIB == 0)) ||
        [[ $permission != 600 ]] ||
        [[ $fstab_entry_count -ne 1 ]]; then

        swapoff "$SWAP_FILE_PATH" 2>/dev/null || true
        cp "$fstab_backup" /etc/fstab
        rm -f "$SWAP_FILE_PATH"

        die "Swap post-apply verification failed; changes were rolled back."
    fi

    printf '\n'
    printf '=== SWAP AFTER APPLY ===\n'
    printf 'Swap total:              %s MiB\n' "$CURRENT_SWAP_TOTAL_MIB"
    printf 'Swap used:               %s MiB\n' "$CURRENT_SWAP_USED_MIB"
    printf 'Active swap devices:     %s\n' "$CURRENT_SWAP_DEVICE_COUNT"
    printf 'Managed swapfile:        %s\n' "$SWAP_FILE_PATH"
    printf 'Swapfile permissions:    %s\n' "$permission"
    printf 'fstab entry count:       %s\n' "$fstab_entry_count"
    printf 'fstab backup:            %s\n' "$fstab_backup"

    info "Swap module completed."
}

ipv6_runtime_disabled() {
    [[ $CURRENT_IPV6_SYSCTL_AVAILABLE == true ]] || return 1
    ((${#CURRENT_IPV6_DISABLE_STATE[@]} > 0)) || return 1

    local state=""

    for state in "${CURRENT_IPV6_DISABLE_STATE[@]}"; do
        [[ ${state##*=} == 1 ]] || return 1
    done

    ((${#CURRENT_IPV6_ADDRESSES[@]} == 0)) || return 1
    ((${#CURRENT_IPV6_ROUTES[@]} == 0)) || return 1

    return 0
}

ipv6_persistent_config_matches() {
    [[ -f $IPV6_SYSCTL_FILE ]] || return 1

    local expected=""
    local actual=""

    expected=$'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1'
    actual=$(<"$IPV6_SYSCTL_FILE")

    [[ $actual == "$expected" ]]
}

write_ipv6_sysctl_config() {
    [[ -d /etc/sysctl.d ]] ||
        die "/etc/sysctl.d does not exist."

    local temp_file=""

    temp_file=$(
        mktemp \
            /etc/sysctl.d/.ubuntu-vps-bootstrap-ipv6.XXXXXX
    )

    if ! printf '%s\n' \
        'net.ipv6.conf.all.disable_ipv6 = 1' \
        'net.ipv6.conf.default.disable_ipv6 = 1' \
        >"$temp_file"; then
        rm -f "$temp_file"
        die "Failed to write temporary IPv6 sysctl configuration."
    fi

    chmod 644 "$temp_file"

    if ! mv "$temp_file" "$IPV6_SYSCTL_FILE"; then
        rm -f "$temp_file"
        die "Failed to install IPv6 sysctl configuration."
    fi
}

apply_ipv6_disabled() {
    info "Starting mandatory IPv6-disable module."

    detect_ipv6_state

    if [[ $CURRENT_IPV6_SYSCTL_AVAILABLE != true ]]; then
        if ((${#CURRENT_IPV6_ADDRESSES[@]} == 0 && ${#CURRENT_IPV6_ROUTES[@]} == 0)); then
            info "IPv6 sysctl is unavailable and no IPv6 network state is present."
            info "IPv6-disable module completed."
            return
        fi

        die "IPv6 sysctl is unavailable while IPv6 network state is present."
    fi

    if [[ -n ${SSH_CONNECTION:-} ]]; then
        local -a ssh_parts=()
        local ssh_server_address=""

        read -r -a ssh_parts <<<"$SSH_CONNECTION"

        if ((${#ssh_parts[@]} >= 4)); then
            ssh_server_address=${ssh_parts[2]}

            if [[ $ssh_server_address == *:* ]]; then
                die \
                    "Current SSH session uses IPv6 (${ssh_server_address}); refusing to disable IPv6."
            fi
        fi
    fi

    if ipv6_persistent_config_matches; then
        info "Persistent IPv6-disable configuration is already correct."
    else
        info "Writing persistent IPv6-disable configuration: $IPV6_SYSCTL_FILE"
        write_ipv6_sysctl_config
    fi

    if ipv6_runtime_disabled; then
        info "IPv6 is already disabled at runtime."
    else
        info "Disabling IPv6 on current and future interfaces."

        sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
        sysctl -q -w net.ipv6.conf.default.disable_ipv6=1

        detect_ipv6_state

        if ! ipv6_runtime_disabled; then
            die "IPv6 runtime verification failed."
        fi
    fi

    detect_ipv6_state

    printf '\n'
    printf '=== IPv6 AFTER APPLY ===\n'
    printf 'IPv6 sysctl available:   %s\n' "$CURRENT_IPV6_SYSCTL_AVAILABLE"
    printf 'IPv6 disable state:      %s\n' "${CURRENT_IPV6_DISABLE_STATE[*]:-<none>}"
    printf 'IPv6 addresses:          %s\n' "${#CURRENT_IPV6_ADDRESSES[@]}"
    printf 'IPv6 global addresses:   %s\n' "${#CURRENT_IPV6_GLOBAL_ADDRESSES[@]}"
    printf 'IPv6 routes:             %s\n' "${#CURRENT_IPV6_ROUTES[@]}"
    printf 'Persistent config:       %s\n' "$IPV6_SYSCTL_FILE"

    info "IPv6-disable module completed."
}

run_current_mode() {
    case "$RUN_MODE" in
        apply)
            info "Apply mode selected."
            apply_packages_and_updates
            apply_timezone_and_ntp
            apply_swap
            apply_ipv6_disabled
            ;;

        plan)
            info "Plan mode selected."
            info "No system changes were made."
            ;;

        audit)
            info "Audit mode selected."
            info "System state was inspected read-only; no system changes were made."
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

    detect_system_state

    print_runtime_summary
    print_current_state
    print_resolved_config
    print_package_state

    run_current_mode
}

main "$@"
