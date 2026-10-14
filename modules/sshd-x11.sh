#!/usr/bin/env bash
# Optional IPv4-only SSHD / X11 forwarding; no SSH port/auth/UFW changes.
set -Eeuo pipefail

mode=${1:---audit}
enabled=${2:-false}
managed=/etc/ssh/sshd_config.d/00-00-ubuntu-vps-bootstrap-x11.conf
legacy=/etc/ssh/sshd_config.d/00-00-extravm-ipv4.conf

case "$mode" in
    --audit | --apply) ;;
    *)
        printf 'FAIL: expected --audit or --apply\n' >&2
        exit 2
        ;;
esac
case "$enabled" in
    true | false) ;;
    *)
        printf 'FAIL: SSHD_X11_IPV4 must be true or false\n' >&2
        exit 2
        ;;
esac

if [[ $enabled == false ]]; then
    printf 'SSHD X11 IPv4: SKIP (unmanaged)\n'
    exit 0
fi

[[ -x /usr/sbin/sshd && -x /usr/bin/xauth ]] || {
    printf 'FAIL: sshd/xauth missing (use EXTRA_PACKAGES for xauth)\n' >&2
    exit 1
}
[[ -d /etc/ssh/sshd_config.d && ! -L $managed && ! -L $legacy ]] || {
    printf 'FAIL: missing drop-in directory or symlink\n' >&2
    exit 1
}

/usr/sbin/sshd -t

settings() {
    /usr/sbin/sshd -T -C 'user=root,host=localhost,addr=127.0.0.1'
}

check_effective() {
    local effective
    effective=$(settings) || return 1

    local line
    for line in 'addressfamily inet' 'x11forwarding yes' 'x11uselocalhost yes' \
        'xauthlocation /usr/bin/xauth' 'disableforwarding no'; do
        grep -Fxq -- "$line" <<<"$effective" || return 1
    done
}

# Preserve the operator's already working manual fix.
if [[ -e $legacy ]]; then
    [[ ! -e $managed && -f $legacy && $(cat "$legacy") == 'AddressFamily inet' ]] || {
        printf 'FAIL: conflicting/unrecognized legacy SSHD drop-in\n' >&2
        exit 1
    }

    check_effective || {
        printf 'FAIL: legacy drop-in is not effective; no changes made\n' >&2
        exit 1
    }

    printf 'SSHD X11 IPv4: %s (existing manual drop-in; unchanged)\n' \
        "$([[ $mode == --audit ]] && printf PASS || printf NO-OP)"
    exit 0
fi

expected='# Managed by ubuntu-vps-bootstrap (opt-in).
AddressFamily inet
X11Forwarding yes
X11UseLocalhost yes
XAuthLocation /usr/bin/xauth'

if [[ -e $managed ]]; then
    [[ -f $managed && $(cat "$managed") == "$expected" ]] || {
        printf 'FAIL: foreign/drifted SSHD drop-in; refusing overwrite\n' >&2
        exit 1
    }

    check_effective || {
        printf 'FAIL: managed SSHD drop-in is not effective\n' >&2
        exit 1
    }

    printf 'SSHD X11 IPv4: %s (managed)\n' \
        "$([[ $mode == --audit ]] && printf PASS || printf NO-OP)"
    exit 0
fi

if [[ $mode == --audit ]]; then
    printf 'FAIL: requested SSHD drop-in missing\n' >&2
    exit 1
fi

if [[ ${SSH_CONNECTION:-} != '' ]]; then
    read -r _ _ local_address _ <<<"$SSH_CONNECTION"
    [[ $local_address != *:* ]] || {
        printf 'FAIL: refusing IPv4-only change over IPv6 SSH session\n' >&2
        exit 1
    }
fi

before=$(settings)
created=false

rollback() {
    if [[ $created == true ]]; then
        rm -f -- "$managed"
        /usr/sbin/sshd -t || true

        if systemctl is-active --quiet ssh.service; then
            systemctl reload ssh.service >/dev/null 2>&1 || true
        fi
    fi
}

trap 'rollback' EXIT

candidate=$(mktemp /etc/ssh/sshd_config.d/.ubuntu-vps-bootstrap-x11.XXXXXX)
trap 'rm -f -- "$candidate"; rollback' EXIT

printf '%s\n' "$expected" >"$candidate"
chmod 644 "$candidate"
chown root:root "$candidate"

ln -- "$candidate" "$managed"
rm -f -- "$candidate"

[[ -f $managed && $(cat "$managed") == "$expected" ]]
created=true

/usr/sbin/sshd -t
check_effective

# All unrelated effective SSHD settings must remain unchanged.
after=$(settings)
filtered() {
    awk '$1 !~ /^(addressfamily|x11forwarding|x11uselocalhost|xauthlocation)$/ { print }'
}
[[ $(filtered <<<"$before") == "$(filtered <<<"$after")" ]]

if systemctl is-active --quiet ssh.service; then
    systemctl reload ssh.service
    systemctl is-active --quiet ssh.service
elif ! systemctl is-active --quiet ssh.socket; then
    printf 'FAIL: neither ssh.service nor ssh.socket active\n' >&2
    exit 1
fi

check_effective
created=false
trap - EXIT

printf 'SSHD X11 IPv4: APPLIED (fresh SSH login required)\n'
