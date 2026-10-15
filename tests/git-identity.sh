#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
module="$root/modules/git-identity.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

fail() {
    printf 'FAIL: git identity test: %s\n' "$*" >&2
    exit 1
}

name=ncludo
email=109440419+ncludo@users.noreply.github.com

[[ ! -e $GIT_CONFIG_GLOBAL ]] || fail 'unexpected config'
[[ $(bash "$module" --audit false) == 'Git identity: SKIP (unmanaged)' ]] || fail 'disabled audit'
[[ ! -e $GIT_CONFIG_GLOBAL ]] || fail 'disabled audit wrote config'

if bash "$module" --audit true "$name" "$email" >/dev/null 2>&1; then
    fail 'missing identity unexpectedly passed audit'
fi
[[ $(bash "$module" --apply true "$name" "$email") == 'Git identity: APPLIED (global)' ]] || fail 'first apply'
[[ $(git config --global --get user.name) == "$name" ]] || fail 'user.name'
[[ $(git config --global --get user.email) == "$email" ]] || fail 'user.email'
[[ $(bash "$module" --apply true "$name" "$email") == 'Git identity: NO-OP (global)' ]] || fail 'second apply'
[[ $(bash "$module" --audit true "$name" "$email") == 'Git identity: PASS (global)' ]] || fail 'post-apply audit'

before=$(sha256sum "$GIT_CONFIG_GLOBAL")
if bash "$module" --apply true another "$email" >/dev/null 2>&1; then
    fail 'foreign identity overwritten'
fi
[[ $(sha256sum "$GIT_CONFIG_GLOBAL") == "$before" ]] || fail 'foreign identity modified'
if bash "$module" --apply true "$name" invalid-email >/dev/null 2>&1; then
    fail 'invalid email accepted'
fi
[[ $(sha256sum "$GIT_CONFIG_GLOBAL") == "$before" ]] || fail 'invalid email modified config'

printf 'GIT IDENTITY MODULE TESTS: PASS\n'
