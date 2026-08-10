#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
release_check="$script_dir/../../bin/template-release-check"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

failures=0

assert_eq() {
    local expected=$1 actual=$2 message=${3:-values differ}
    if [ "$expected" != "$actual" ]; then
        printf 'not ok - %s\nexpected: %s\nactual: %s\n' \
            "$message" "$expected" "$actual"
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$message"
    fi
}

assert_failure_contains() {
    local expected=$1
    shift
    local output actual
    if output=$("$@" 2>&1); then
        actual=0
    else
        actual=$?
    fi
    assert_eq 1 "$actual" "status of $*"
    case "$output" in
        *"$expected"*) printf 'ok - diagnostic of %s\n' "$*" ;;
        *)
            printf 'not ok - diagnostic of %s\nexpected to contain: %s\nactual: %s\n' \
                "$*" "$expected" "$output"
            failures=$((failures + 1))
            ;;
    esac
}

assert_status() {
    local expected=$1
    shift
    local actual
    if "$@" >/dev/null 2>&1; then
        actual=0
    else
        actual=$?
    fi
    assert_eq "$expected" "$actual" "status of $*"
}

mkdir -p "$root/bin"
git -C "$root" init -q -b main
git -C "$root" config user.email test@example.com
git -C "$root" config user.name 'Template Release Test'
printf '0.3.0\n' > "$root/VERSION"
printf '# Changelog\n\n## [0.3.0] - 2026-08-09\n' > "$root/CHANGELOG.md"
printf '#!/bin/bash\n' > "$root/bin/worktree-lib.sh"
printf '%s\n' \
    $'template-owned\tbin/worktree-lib.sh' \
    $'template-owned\tVERSION' \
    $'template-owned\tCHANGELOG.md' > "$root/template-manifest.tsv"
git -C "$root" add .
git -C "$root" commit -q -m baseline

printf '# changed without release metadata\n' > "$root/bin/worktree-lib.sh"
git -C "$root" add bin/worktree-lib.sh
git -C "$root" commit -q -m 'change without release'

assert_failure_contains 'Release-Version fehlt' "$release_check" "$root"

printf '0.3.1\n' > "$root/VERSION"
printf '# Changelog\n\n## [0.3.1] - 2026-08-10\n\n## [0.3.0] - 2026-08-09\n' > "$root/CHANGELOG.md"
git -C "$root" add VERSION CHANGELOG.md
git -C "$root" commit -q -m 'release metadata'

assert_status 0 "$release_check" "$root"

printf '# mismatched changelog\n\n## [0.3.0] - 2026-08-09\n' > "$root/CHANGELOG.md"
assert_failure_contains 'CHANGELOG-Version' "$release_check" "$root"

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all tests passed\n'
