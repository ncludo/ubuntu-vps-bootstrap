#!/usr/bin/env bash
# Optional global Git commit identity for the current bootstrap user (root).
set -Eeuo pipefail

mode=${1:---audit}
enabled=${2:-false}
name=${3:-}
email=${4:-}

fail() {
    printf 'FAIL: Git identity: %s\n' "$*" >&2
    exit 1
}

case "$mode" in
    --audit | --apply) ;;
    *) fail 'expected --audit or --apply' ;;
esac
case "$enabled" in
    true | false) ;;
    *) fail 'enable must be true or false' ;;
esac

if [[ $enabled == false ]]; then
    printf 'Git identity: SKIP (unmanaged)\n'
    exit 0
fi

[[ -n $name && $name != *[$'\r\n']* && $name != -* ]] ||
    fail 'invalid user.name'
[[ $email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] ||
    fail 'invalid user.email'
command -v git >/dev/null 2>&1 || fail 'git missing'

read_single() {
    local key=$1 output='' rc=0
    if output=$(git config --global --get-all "$key" 2>/dev/null); then
        [[ $output != *$'\n'* ]] || fail "multiple values for $key"
    else
        rc=$?
        ((rc == 1)) || fail "cannot read $key (exit $rc)"
    fi
    printf '%s' "$output"
}

current_name=$(read_single user.name)
current_email=$(read_single user.email)

# Protect pre-existing identities rather than silently replacing them.
[[ -z $current_name || $current_name == "$name" ]] ||
    fail 'existing global user.name conflicts (unchanged)'
[[ -z $current_email || $current_email == "$email" ]] ||
    fail 'existing global user.email conflicts (unchanged)'

if [[ $mode == --audit ]]; then
    [[ $current_name == "$name" && $current_email == "$email" ]] ||
        fail 'requested global identity is missing'
    printf 'Git identity: PASS (global)\n'
    exit 0
fi

if [[ $current_name == "$name" && $current_email == "$email" ]]; then
    printf 'Git identity: NO-OP (global)\n'
    exit 0
fi

git config --global --replace-all user.name "$name"
git config --global --replace-all user.email "$email"
[[ $(read_single user.name) == "$name" && $(read_single user.email) == "$email" ]] ||
    fail 'post-apply verification failed'
printf 'Git identity: APPLIED (global)\n'
