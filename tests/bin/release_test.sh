#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
release="$script_dir/../../bin/release"
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

mkdir -p "$root/bin" "$root/tests/bin"
git -C "$root" init -q -b main
git -C "$root" config user.email test@example.com
git -C "$root" config user.name 'Release Test'
printf '0.4.1\n' > "$root/VERSION"
printf '%s\n' \
    '# Changelog' '' \
    '## [Unreleased]' '' \
    '### Fixed' '' \
    '- something' '' \
    '## [0.4.1] - 2026-08-12' > "$root/CHANGELOG.md"
printf '#!/bin/bash\n' > "$root/bin/worktree-lib.sh"
cp "$script_dir/../../bin/template-release-check" "$root/bin/template-release-check"
chmod +x "$root/bin/template-release-check"
printf '%s\n' \
    $'template-owned\tVERSION' \
    $'template-owned\tCHANGELOG.md' \
    $'template-owned\tbin/worktree-lib.sh' \
    $'template-owned\ttests/bin/template_sync_test.sh' > "$root/template-manifest.tsv"
printf '%s\n' \
    '#!/bin/bash' \
    "assert_eq '0.4.1' \"\$(<\"\$script_dir/../../VERSION\")\" \\" \
    "    'VERSION gesynct'" > "$root/tests/bin/template_sync_test.sh"
git -C "$root" add .
git -C "$root" commit -q -m baseline
baseline=$(git -C "$root" rev-parse HEAD)

cd "$root"

assert_failure_contains 'Ungültiger Bump-Typ' "$release" --bogus

printf 'abc\n' > "$root/VERSION"
assert_failure_contains 'major.minor.patch' "$release"
git -C "$root" checkout -- VERSION

printf '0.9.9\n' > "$root/VERSION"
assert_failure_contains 'nicht sauber' "$release"
git -C "$root" checkout -- VERSION

printf 'untracked\n' > "$root/untracked.txt"
assert_failure_contains 'nicht sauber' "$release"
rm "$root/untracked.txt"

sed -i '/^## \[Unreleased\]/,+3d' "$root/CHANGELOG.md"
git -C "$root" add CHANGELOG.md
git -C "$root" commit -q -m 'drop unreleased'
assert_failure_contains 'Unreleased' "$release"
git -C "$root" checkout "$baseline" -- CHANGELOG.md
git -C "$root" commit -q -m 'restore unreleased'

backup_check=$(mktemp)
trap 'rm -rf "$root" "$backup_check"' EXIT
cp "$root/bin/template-release-check" "$backup_check"
printf '#!/bin/bash\nprintf "stubbed check failure\\n" >&2\nexit 1\n' \
    > "$root/bin/template-release-check"
chmod +x "$root/bin/template-release-check"
git -C "$root" add bin/template-release-check
git -C "$root" commit -q -m 'stub release check'
assert_failure_contains 'Konsistenzprüfung fehlgeschlagen' "$release" patch
assert_eq 'stub release check' "$(git -C "$root" log -1 --format=%s)" \
    'Rollback: Release-Commit zurückgesetzt'
assert_eq '0.4.1' "$(<"$root/VERSION")" 'VERSION nach Rollback'
assert_eq 0 "$(git -C "$root" tag -l 'v0.4.2' | wc -l)" \
    'kein Tag nach Rollback'
cp "$backup_check" "$root/bin/template-release-check"
chmod +x "$root/bin/template-release-check"
git -C "$root" add bin/template-release-check
git -C "$root" commit -q -m 'restore release check'

assert_status 0 "$release" patch
assert_eq '0.4.2' "$(<"$root/VERSION")" 'VERSION nach patch-Bump'
assert_eq "## [0.4.2] - $(date +%F)" \
    "$(grep -m1 '^## \[' "$root/CHANGELOG.md")" 'CHANGELOG-Header nach patch-Bump'
assert_status 0 "$release_check" "$root"
assert_eq 'release: bump template to 0.4.2' \
    "$(git -C "$root" log -1 --format=%s)" 'Release-Commit-Message'
assert_eq 'tag' "$(git -C "$root" cat-file -t v0.4.2)" 'annotierter Tag v0.4.2'
assert_eq "$(git -C "$root" rev-parse HEAD)" \
    "$(git -C "$root" rev-parse 'v0.4.2^{commit}')" 'Tag zeigt auf Release-Commit'
assert_eq 0 "$(grep -c '0\.4\.1' "$root/tests/bin/template_sync_test.sh" || true)" \
    'alte Version aus Tests entfernt'

printf '%s\n' \
    '# Changelog' '' \
    '## [Unreleased]' '' \
    '### Changed' '' \
    '- feature x' '' \
    "## [0.4.2] - $(date +%F)" '' \
    '### Fixed' '' \
    '- something' '' \
    '## [0.4.1] - 2026-08-12' > "$root/CHANGELOG.md"
git -C "$root" add CHANGELOG.md
git -C "$root" commit -q -m 'feature notes'

assert_status 0 "$release" minor
assert_eq '0.5.0' "$(<"$root/VERSION")" 'VERSION nach minor-Bump'
assert_eq "## [0.5.0] - $(date +%F)" \
    "$(grep -m1 '^## \[' "$root/CHANGELOG.md")" 'CHANGELOG-Header nach minor-Bump'
assert_eq "$(git -C "$root" rev-parse HEAD)" \
    "$(git -C "$root" rev-parse 'v0.5.0^{commit}')" 'minor-Tag zeigt auf Release-Commit'
assert_status 0 "$release_check" "$root"

printf '%s\n' \
    '# Changelog' '' \
    '## [Unreleased]' '' \
    '### Changed' '' \
    '- breaking api' '' \
    "## [0.5.0] - $(date +%F)" '' \
    '### Changed' '' \
    '- feature x' '' \
    "## [0.4.2] - $(date +%F)" '' \
    '### Fixed' '' \
    '- something' '' \
    '## [0.4.1] - 2026-08-12' > "$root/CHANGELOG.md"
git -C "$root" add CHANGELOG.md
git -C "$root" commit -q -m 'breaking change notes'

assert_status 0 "$release" major
assert_eq '1.0.0' "$(<"$root/VERSION")" 'VERSION nach major-Bump'
assert_eq "## [1.0.0] - $(date +%F)" \
    "$(grep -m1 '^## \[' "$root/CHANGELOG.md")" 'CHANGELOG-Header nach major-Bump'
assert_eq "$(git -C "$root" rev-parse HEAD)" \
    "$(git -C "$root" rev-parse 'v1.0.0^{commit}')" 'major-Tag zeigt auf Release-Commit'
assert_status 0 "$release_check" "$root"

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all tests passed\n'
