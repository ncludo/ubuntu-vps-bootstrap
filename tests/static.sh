#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

cd "$PROJECT_ROOT"

declare -a shell_files=()

while IFS= read -r -d '' file; do
    shell_files+=("$file")
done < <(
    find . \
        -type f \
        -name '*.sh' \
        -not -path './.git/*' \
        -print0
)

if ((${#shell_files[@]} == 0)); then
    printf 'ERROR: no shell files found.\n' >&2
    exit 1
fi

printf '=== BASH SYNTAX ===\n'

for file in "${shell_files[@]}"; do
    printf 'Checking: %s\n' "$file"
    bash -n "$file"
done

printf 'bash -n: OK\n'

printf '\n=== SHELLCHECK ===\n'
shellcheck "${shell_files[@]}"
printf 'shellcheck: OK\n'

printf '\n=== SHFMT ===\n'
shfmt -d "${shell_files[@]}"
printf 'shfmt: OK\n'

printf '\n=== GIT DIFF CHECK ===\n'
git diff --check
printf 'git diff --check: OK\n'

printf '\nSTATIC CHECKS: PASS\n'
