#!/bin/bash
set -euo pipefail

worktree_root=${WORKTREE_TEST_ROOT:-$(git rev-parse --show-toplevel)}
active_state_file="$worktree_root/.worktree-active"

project_config_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=project-config.sh
# shellcheck disable=SC1091
source "$project_config_script_dir/project-config.sh"
load_project_config "$worktree_root"

worktree_path() {
    printf '%s/.worktrees/%s\n' "$worktree_root" "$1"
}

validate_worktree_name() {
    case "$1" in
        ''|.|..|.*|[-.]*|*[!A-Za-z0-9_.-]*)
            printf 'invalid worktree name: %s\n' "$1" >&2
            return 1
            ;;
    esac
}

run_git() {
    git "$@"
}

run_sail() {
    "${SAIL_BIN:-./vendor/bin/sail}" "$@"
}

stack_is_running() {
    local path=${1:-.}
    local sail_bin=${2:-${SAIL_BIN:-$path/vendor/bin/sail}}
    local mysql_init_script=${3:-}
    local container_id
    local output_file

    output_file=$(mktemp) || return 1

    if [ "$path" = "." ] && [ "$#" -eq 0 ]; then
        if ! COMPOSE_PROJECT_NAME="$PROJECT_NAME" SAIL_MYSQL_INIT_SCRIPT="$mysql_init_script" \
            run_sail ps -q laravel.test >"$output_file" 2>/dev/null; then
            rm -f "$output_file"
            return 1
        fi
    else
        if ! (cd "$path" && COMPOSE_PROJECT_NAME="$PROJECT_NAME" SAIL_SOURCE_PATH="$path" \
            SAIL_MYSQL_INIT_SCRIPT="$mysql_init_script" SAIL_BIN="$sail_bin" \
            run_sail ps -q laravel.test) >"$output_file" 2>/dev/null; then
            rm -f "$output_file"
            return 1
        fi
    fi
    container_id=$(<"$output_file")
    rm -f "$output_file"
    [ -n "$container_id" ]
}

stack_is_running_for_worktree() {
    local path=$1
    local sail_bin=${SAIL_BIN:-$path/vendor/bin/sail}
    local mysql_init_script=

    if [ ! -d "$path/vendor/laravel/sail" ]; then
        sail_bin="$worktree_root/vendor/bin/sail"
        mysql_init_script="$worktree_root/vendor/laravel/sail/database/mysql/create-testing-database.sh"
    fi
    stack_is_running "$path" "$sail_bin" "$mysql_init_script"
}

port_is_available() {
    if ! command -v nc >/dev/null 2>&1; then
        return 0
    fi
    ! nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

die() {
    printf '%s\n' "$1" >&2
    return 1
}

ensure_main_sail_setup() {
    if [ ! -x "$worktree_root/vendor/bin/sail" ]; then
        die 'Haupt-Checkout benötigt eine Sail-Installation: vendor/bin/sail fehlt.'
        return 1
    fi
    if [ ! -d "$worktree_root/vendor/laravel/sail/runtimes/8.5" ]; then
        die 'Sail-Runtime fehlt im Haupt-Checkout: vendor/laravel/sail/runtimes/8.5.'
        return 1
    fi
    if [ ! -f "$worktree_root/vendor/laravel/sail/database/mysql/create-testing-database.sh" ]; then
        die 'Sail-Bootstrap-Datei fehlt im Haupt-Checkout: create-testing-database.sh.'
        return 1
    fi
}

validate_worktree_prerequisites() {
    local path=$1

    if [ ! -f "$path/.env" ]; then
        die "Worktree-Prüfung fehlgeschlagen: $path/.env fehlt."
        return 1
    fi
    if [ ! -f "$path/compose.yaml" ]; then
        die "Worktree-Prüfung fehlgeschlagen: $path/compose.yaml fehlt."
        return 1
    fi

    if [ -d "$path/vendor/laravel/sail" ]; then
        if [ ! -x "$path/vendor/bin/sail" ]; then
            die "Worktree-Prüfung fehlgeschlagen: Sail fehlt in $path/vendor/bin/sail."
            return 1
        fi
        if [ ! -d "$path/vendor/laravel/sail/runtimes/8.5" ]; then
            die "Worktree-Prüfung fehlgeschlagen: Sail-Runtime fehlt in $path/vendor/laravel/sail/runtimes/8.5."
            return 1
        fi
        if [ ! -f "$path/vendor/laravel/sail/database/mysql/create-testing-database.sh" ]; then
            die "Worktree-Prüfung fehlgeschlagen: Sail-Bootstrap-Datei fehlt in $path/vendor/laravel/sail."
            return 1
        fi
        return 0
    fi

    ensure_main_sail_setup
}

start_stack() {
    local path=$1
    local sail_bin=${2:-${SAIL_BIN:-$path/vendor/bin/sail}}
    [ -x "$sail_bin" ] || die "Sail fehlt in $path/vendor/bin/sail" || return 1
    if ! stack_is_running "$path" "$sail_bin"; then
        port_is_available 8080 || die 'Port 8080 ist bereits belegt' || return 1
    fi
    (
        cd "$path" || exit 1
        COMPOSE_PROJECT_NAME="$PROJECT_NAME" SAIL_SOURCE_PATH="$path" \
            SAIL_BUILD_CONTEXT='' SAIL_BUILD_DOCKERFILE='' SAIL_MYSQL_INIT_SCRIPT='' \
            SAIL_BIN="$sail_bin" \
            run_sail up -d --remove-orphans
    )
}

stop_stack() {
    local path=$1
    local sail_bin=${2:-${SAIL_BIN:-$path/vendor/bin/sail}}
    local mysql_init_script=${3:-}
    [ -x "$sail_bin" ] || die "Sail fehlt in $path/vendor/bin/sail" || return 1
    (
        cd "$path" || exit 1
        COMPOSE_PROJECT_NAME="$PROJECT_NAME" SAIL_SOURCE_PATH="$path" \
            SAIL_BUILD_CONTEXT='' SAIL_BUILD_DOCKERFILE='' SAIL_BIN="$sail_bin" \
            SAIL_MYSQL_INIT_SCRIPT="$mysql_init_script" run_sail down --remove-orphans
    )
}

run_fresh() {
    local path=$1
    local answer
    local sail_bin=${2:-${SAIL_BIN:-$path/vendor/bin/sail}}
    [ -x "$sail_bin" ] || die "Sail fehlt in $path/vendor/bin/sail" || return 1
    printf 'WARNUNG: Datenbank von Worktree "%s" wird vollständig zurückgesetzt. Fortfahren? [y/N] ' \
        "$(basename "$path")" >&2
    read -r answer
    [ "$answer" = y ] || [ "$answer" = Y ] || die 'Datenbank-Reset abgebrochen' || return 1
    (
        cd "$path" || exit 1
        COMPOSE_PROJECT_NAME="$PROJECT_NAME" SAIL_SOURCE_PATH="$path" \
            SAIL_BUILD_CONTEXT='' SAIL_BUILD_DOCKERFILE='' SAIL_MYSQL_INIT_SCRIPT='' \
            SAIL_BIN="$sail_bin" \
            run_sail artisan migrate:fresh --seed
    )
}

start_for_worktree() {
    local path=$1
    local sail_bin=${SAIL_BIN:-$path/vendor/bin/sail}
    local build_context=
    local build_dockerfile=
    local mysql_init_script=

    if [ ! -d "$path/vendor/laravel/sail" ]; then
        sail_bin="$worktree_root/vendor/bin/sail"
        build_context="$worktree_root/vendor/laravel/sail/runtimes/8.5"
        build_dockerfile=Dockerfile
        mysql_init_script="$worktree_root/vendor/laravel/sail/database/mysql/create-testing-database.sh"
    fi
    [ -x "$sail_bin" ] || die "Sail fehlt in $path/vendor/bin/sail" || return 1
    if ! stack_is_running "$path" "$sail_bin" "$mysql_init_script"; then
        port_is_available 8080 || die 'Port 8080 ist bereits belegt' || return 1
    fi
    if [ -n "$build_context" ]; then
        (
            cd "$path" || exit 1
            COMPOSE_PROJECT_NAME="$PROJECT_NAME" SAIL_SOURCE_PATH="$path" \
                SAIL_BUILD_CONTEXT="$build_context" SAIL_BUILD_DOCKERFILE="$build_dockerfile" \
                SAIL_MYSQL_INIT_SCRIPT="$mysql_init_script" \
                SAIL_BIN="$sail_bin" run_sail up -d --remove-orphans
        )
    else
        start_stack "$path" "$sail_bin"
    fi
}

stop_for_worktree() {
    local path=$1
    local sail_bin=${SAIL_BIN:-$path/vendor/bin/sail}
    local mysql_init_script=

    if [ ! -d "$path/vendor/laravel/sail" ]; then
        sail_bin="$worktree_root/vendor/bin/sail"
        mysql_init_script="$worktree_root/vendor/laravel/sail/database/mysql/create-testing-database.sh"
    fi
    stop_stack "$path" "$sail_bin" "$mysql_init_script"
}

resolve_worktree() {
    validate_worktree_name "$1" || return 1

    local path
    path=$(worktree_path "$1")
    if [ ! -d "$path" ]; then
        printf 'worktree not found: %s\n' "$path" >&2
        return 1
    fi
    if ! run_git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'invalid Git worktree: %s\n' "$path" >&2
        return 1
    fi
    printf '%s\n' "$path"
}

active_worktree() {
    local active_name
    if ! active_name=$(read_active_worktree); then
        printf 'no active worktree is recorded\n' >&2
        return 1
    fi
    resolve_worktree "$active_name"
}

validate_worktree() {
    resolve_worktree "$1" >/dev/null
}

validate_existing_branch() {
    local branch=$1
    local worktree

    validate_worktree_name "$branch" || return 1

    if ! run_git show-ref --verify --quiet "refs/heads/$branch"; then
        printf 'branch does not exist: %s\n' "$branch" >&2
        return 1
    fi

    local worktree_listing
    if ! worktree_listing=$(run_git worktree list --porcelain 2>&1); then
        printf 'unable to enumerate Git worktrees: %s\n' "$worktree_listing" >&2
        return 1
    fi

    while IFS= read -r worktree; do
        case "$worktree" in
            branch\ refs/heads/"$branch")
                printf 'branch already checked out in a worktree: %s\n' "$branch" >&2
                return 1
                ;;
        esac
    done <<< "$worktree_listing"
}

read_active_worktree() {
    [ -f "$active_state_file" ] || return 1
    local active_name
    IFS= read -r active_name < "$active_state_file"
    [ -n "$active_name" ] || return 1
    printf '%s\n' "$active_name"
}

write_active_worktree() {
    printf '%s\n' "$1" > "$active_state_file"
}
