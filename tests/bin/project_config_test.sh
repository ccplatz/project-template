#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
project_config_script="$script_dir/../../bin/project-config.sh"
if [ -f "$project_config_script" ]; then
    # shellcheck source=../../bin/project-config.sh
    # shellcheck disable=SC1091
    source "$project_config_script"
fi

failures=0

assert_eq() {
    local expected=$1 actual=$2 message=${3:-values differ}
    if [ "$expected" != "$actual" ]; then
        printf 'not ok - %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$message"
    fi
}

assert_status() {
    local expected=$1
    shift
    local actual
    if "$@" >/dev/null 2>&1; then actual=0; else actual=$?; fi
    assert_eq "$expected" "$actual" "status of $*"
}

assert_failure_contains() {
    local expected=$1
    shift
    local output actual
    if output=$("$@" 2>&1 >/dev/null); then actual=0; else actual=$?; fi
    assert_eq 1 "$actual" "status of $*"
    case "$output" in
        *"$expected"*) printf 'ok - diagnostic of %s\n' "$*" ;;
        *)
            printf 'not ok - diagnostic of %s\nexpected to contain: %s\nactual: %s\n' \
                "$*" "$expected" "$output" >&2
            failures=$((failures + 1))
            ;;
    esac
}

assert_strict_mode() {
    local script=$1
    assert_status 0 bash -c '
        source "$1"
        case "$-" in *e*) ;; *) exit 1 ;; esac
        case "$-" in *u*) ;; *) exit 1 ;; esac
        shopt -po pipefail >/dev/null
    ' _ "$script"
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/.template"

assert_strict_mode "$project_config_script"

assert_status 1 load_project_config "$root"
printf 'PROJECT_NAME=finance\n' > "$root/.template/project.conf"
assert_status 0 load_project_config "$root"
assert_eq finance "$(project_config_name)" 'loads project name'
assert_eq '' "$WORKTREE_PORT_PROFILE" 'defaults the worktree port profile'
assert_eq 10 "$WORKTREE_PORT_STRIDE" 'defaults the worktree port stride'
assert_eq .env.template "$WORKTREE_ENV_TEMPLATE" 'defaults the worktree environment template'

cat > "$root/.template/project.conf" <<'CONFIG'
PROJECT_NAME=finance
WORKTREE_PORT_PROFILE="http=8080,frontend=5173,database=3306,cache=6379"
WORKTREE_PORT_STRIDE=10
WORKTREE_ENV_TEMPLATE=.env.example
CONFIG
assert_status 0 load_project_config "$root"
assert_eq 'http=8080,frontend=5173,database=3306,cache=6379' "$WORKTREE_PORT_PROFILE" \
    'loads the worktree port profile'
assert_eq 10 "$WORKTREE_PORT_STRIDE" 'loads the worktree port stride'
assert_eq .env.example "$WORKTREE_ENV_TEMPLATE" 'loads the worktree environment template'
assert_eq 'finance|http=8080,frontend=5173,database=3306,cache=6379|10|.env.example' \
    "$(bash -c 'printf "%s|%s|%s|%s" "$PROJECT_NAME" "$WORKTREE_PORT_PROFILE" "$WORKTREE_PORT_STRIDE" "$WORKTREE_ENV_TEMPLATE"')" \
    'exports the validated configuration'

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=bad-name=8080\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=8080,http=9090\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=8080,broken\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=0\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=8080,,cache=6379\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=HTTP=8080\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=8080,HTTP=9090\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=08080\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=65536\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=99999999999999999999\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_PROFILE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_PROFILE=http=65535\n' > "$root/.template/project.conf"
assert_status 0 load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_STRIDE=0\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_STRIDE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_STRIDE=010\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_STRIDE' load_project_config "$root"

printf 'PROJECT_NAME=finance\nWORKTREE_PORT_STRIDE=-1\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid WORKTREE_PORT_STRIDE' load_project_config "$root"

printf 'PROJECT_NAME=_finance\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid PROJECT_NAME' load_project_config "$root"

printf 'PROJECT_NAME=bad/name\n' > "$root/.template/project.conf"
assert_failure_contains 'Invalid PROJECT_NAME' load_project_config "$root"

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all tests passed\n'
