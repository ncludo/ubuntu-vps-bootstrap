#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROGRAM_NAME="ubuntu-vps-bootstrap"
readonly PROGRAM_VERSION="0.1.0-dev"

main() {
    printf '%s %s\n' "$PROGRAM_NAME" "$PROGRAM_VERSION"
}

main "$@"