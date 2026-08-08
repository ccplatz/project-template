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

worktree_state_dir() {
    printf '%s/.worktrees/.state\n' "$worktree_root"
}

worktree_state_path() {
    validate_worktree_name "$1" || return 1
    printf '%s/%s.env\n' "$(worktree_state_dir)" "$1"
}

compose_project_name_for_worktree() {
    local name=$1
    local compose_project="${PROJECT_NAME}-${name}"
    if printf '%s\n' "$compose_project" | LC_ALL=C grep -qE '^[a-z0-9][a-z0-9_-]*$'; then
        printf '%s\n' "$compose_project"
        return 0
    fi
    printf 'ungültiger Compose-Projektname: %s (abgeleitet aus PROJECT_NAME=%s)\n' \
        "$compose_project" "$PROJECT_NAME" >&2
    return 1
}

value_is_decimal() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
}

write_worktree_state() {
    local name=$1
    local compose_project=$2
    local app_port=$3
    local vite_port=$4
    local db_port=$5
    local redis_port=$6
    local state_dir
    local state_file
    local temporary_file

    state_dir=$(worktree_state_dir)
    state_file=$(worktree_state_path "$name")
    mkdir -p "$state_dir"
    temporary_file="$state_file.tmp.$$"
    {
        printf 'WORKTREE_NAME=%s\n' "$name"
        printf 'COMPOSE_PROJECT_NAME=%s\n' "$compose_project"
        printf 'APP_PORT=%s\n' "$app_port"
        printf 'VITE_PORT=%s\n' "$vite_port"
        printf 'FORWARD_DB_PORT=%s\n' "$db_port"
        printf 'FORWARD_REDIS_PORT=%s\n' "$redis_port"
    } > "$temporary_file"
    mv "$temporary_file" "$state_file"
}

load_worktree_state() {
    local name=$1
    local state_file
    local expected_compose_project
    local line
    local key
    local value
    local state_name=
    local state_compose_project=
    local state_app_port=
    local state_vite_port=
    local state_db_port=
    local state_redis_port=

    state_file=$(worktree_state_path "$name") || return 1
    expected_compose_project=$(compose_project_name_for_worktree "$name") || return 1
    if [ ! -f "$state_file" ]; then
        die "Worktree-Zustand fehlt für $name: $state_file"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            *=*)
                key=${line%%=*}
                value=${line#*=}
                case "$key" in
                    WORKTREE_NAME)
                        if [ -n "$state_name" ]; then
                            die "ungültiger Worktree-Zustand: doppelter Schlüssel $key in $state_file"
                            return 1
                        fi
                        state_name=$value
                        ;;
                    COMPOSE_PROJECT_NAME)
                        if [ -n "$state_compose_project" ]; then
                            die "ungültiger Worktree-Zustand: doppelter Schlüssel $key in $state_file"
                            return 1
                        fi
                        state_compose_project=$value
                        ;;
                    APP_PORT)
                        if [ -n "$state_app_port" ]; then
                            die "ungültiger Worktree-Zustand: doppelter Schlüssel $key in $state_file"
                            return 1
                        fi
                        state_app_port=$value
                        ;;
                    VITE_PORT)
                        if [ -n "$state_vite_port" ]; then
                            die "ungültiger Worktree-Zustand: doppelter Schlüssel $key in $state_file"
                            return 1
                        fi
                        state_vite_port=$value
                        ;;
                    FORWARD_DB_PORT)
                        if [ -n "$state_db_port" ]; then
                            die "ungültiger Worktree-Zustand: doppelter Schlüssel $key in $state_file"
                            return 1
                        fi
                        state_db_port=$value
                        ;;
                    FORWARD_REDIS_PORT)
                        if [ -n "$state_redis_port" ]; then
                            die "ungültiger Worktree-Zustand: doppelter Schlüssel $key in $state_file"
                            return 1
                        fi
                        state_redis_port=$value
                        ;;
                    *)
                        die "ungültiger Worktree-Zustand: unbekannter Schlüssel $key in $state_file"
                        return 1
                        ;;
                esac
                ;;
            *)
                die "ungültiger Worktree-Zustand: unerwartete Zeile in $state_file"
                return 1
                ;;
        esac
    done < "$state_file"

    if [ -z "$state_name" ] || [ -z "$state_compose_project" ] || [ -z "$state_app_port" ] \
        || [ -z "$state_vite_port" ] || [ -z "$state_db_port" ] || [ -z "$state_redis_port" ]; then
        die "ungültiger Worktree-Zustand: unvollständiger Datensatz in $state_file"
        return 1
    fi
    if [ "$state_name" != "$name" ]; then
        die "ungültiger Worktree-Zustand: Worktree-Name weicht ab in $state_file"
        return 1
    fi
    if ! value_is_decimal "$state_app_port" || ! value_is_decimal "$state_vite_port" \
        || ! value_is_decimal "$state_db_port" || ! value_is_decimal "$state_redis_port"; then
        die "ungültiger Worktree-Zustand: Ports müssen dezimal sein in $state_file"
        return 1
    fi
    if [ "$state_app_port" -lt 8080 ]; then
        die "ungültiger Worktree-Zustand: APP_PORT muss mindestens 8080 sein in $state_file"
        return 1
    fi
    if [ "$state_compose_project" != "$expected_compose_project" ]; then
        die "ungültiger Worktree-Zustand: COMPOSE_PROJECT_NAME weicht ab in $state_file"
        return 1
    fi

    WORKTREE_STATE_NAME=$name
    WORKTREE_STATE_COMPOSE_PROJECT_NAME=$state_compose_project
    WORKTREE_STATE_APP_PORT=$state_app_port
    WORKTREE_STATE_VITE_PORT=$state_vite_port
    WORKTREE_STATE_DB_PORT=$state_db_port
    WORKTREE_STATE_REDIS_PORT=$state_redis_port
    export WORKTREE_STATE_NAME WORKTREE_STATE_COMPOSE_PROJECT_NAME WORKTREE_STATE_APP_PORT \
        WORKTREE_STATE_VITE_PORT WORKTREE_STATE_DB_PORT WORKTREE_STATE_REDIS_PORT
}

worktree_state_lock_dir() {
    printf '%s/.allocation-lock\n' "$(worktree_state_dir)"
}

acquire_worktree_state_lock() {
    local lock_dir
    local pid
    local attempt
    lock_dir=$(worktree_state_lock_dir)
    mkdir -p "$(dirname "$lock_dir")"
    for attempt in 1 2; do
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            return 0
        fi
        if [ -f "$lock_dir/pid" ]; then
            IFS= read -r pid < "$lock_dir/pid"
            case "$pid" in
                ''|*[!0-9]*)
                    rm -rf "$lock_dir"
                    ;;
                *)
                    if kill -0 "$pid" 2>/dev/null; then
                        die "Portzuweisung läuft bereits (Prozess $pid). Warte und versuche es erneut."
                        return 1
                    fi
                    rm -rf "$lock_dir"
                    ;;
            esac
        else
            rm -rf "$lock_dir"
        fi
    done
    die "Portzuweisungs-Sperre konnte nicht erworben werden: $lock_dir"
    return 1
}

release_worktree_state_lock() {
    local lock_dir
    local pid
    lock_dir=$(worktree_state_lock_dir)
    if [ -f "$lock_dir/pid" ]; then
        IFS= read -r pid < "$lock_dir/pid"
        if [ "$pid" = "$$" ]; then
            rm -rf "$lock_dir"
        fi
    fi
}

worktree_state_port_available() {
    local name=$1
    local app_port=$2
    local vite_port=$3
    local db_port=$4
    local redis_port=$5
    local own_state_file
    local state_file
    local state_dir

    state_dir=$(worktree_state_dir)
    own_state_file=$(worktree_state_path "$name")
    for state_file in "$state_dir"/*.env; do
        [ -f "$state_file" ] || continue
        [ "$state_file" = "$own_state_file" ] && continue
        if grep -Eq "=(${app_port}|${vite_port}|${db_port}|${redis_port})$" "$state_file"; then
            return 1
        fi
    done
    port_is_available "$app_port" || return 1
    port_is_available "$vite_port" || return 1
    port_is_available "$db_port" || return 1
    port_is_available "$redis_port" || return 1
}

ensure_worktree_state() {
    local name=$1
    local path=$2
    local state_file
    local compose_project
    local app_port
    local vite_port
    local db_port
    local redis_port
    local dot_env_app=
    local dot_env_vite=
    local dot_env_db=
    local dot_env_redis=
    local env_line
    local index

    state_file=$(worktree_state_path "$name") || return 1

    if [ -f "$state_file" ]; then
        load_worktree_state "$name" || return 1
        return 0
    fi

    compose_project=$(compose_project_name_for_worktree "$name") || return 1

    if ! acquire_worktree_state_lock; then
        return 1
    fi
    trap 'release_worktree_state_lock' EXIT

    if [ -f "$path/.env" ]; then
        while IFS= read -r env_line || [ -n "$env_line" ]; do
            case "$env_line" in
                APP_PORT=*) dot_env_app=${env_line#APP_PORT=} ;;
                VITE_PORT=*) dot_env_vite=${env_line#VITE_PORT=} ;;
                FORWARD_DB_PORT=*) dot_env_db=${env_line#FORWARD_DB_PORT=} ;;
                FORWARD_REDIS_PORT=*) dot_env_redis=${env_line#FORWARD_REDIS_PORT=} ;;
            esac
        done < "$path/.env"
    fi

    if value_is_decimal "$dot_env_app" && value_is_decimal "$dot_env_vite" \
        && value_is_decimal "$dot_env_db" && value_is_decimal "$dot_env_redis" \
        && [ -n "$dot_env_app" ] && [ -n "$dot_env_vite" ] \
        && [ -n "$dot_env_db" ] && [ -n "$dot_env_redis" ] \
        && [ "$dot_env_app" -ge 8080 ] \
        && worktree_state_port_available "$name" "$dot_env_app" "$dot_env_vite" "$dot_env_db" "$dot_env_redis"; then
        app_port=$dot_env_app
        vite_port=$dot_env_vite
        db_port=$dot_env_db
        redis_port=$dot_env_redis
    else
        for ((index = 0; index < 100; index++)); do
            app_port=$((8080 + index * 10))
            vite_port=$((5173 + index * 10))
            db_port=$((3306 + index * 10))
            redis_port=$((6379 + index * 10))
            if worktree_state_port_available "$name" "$app_port" "$vite_port" "$db_port" "$redis_port"; then
                break
            fi
        done
        if [ "$index" -ge 100 ]; then
            die "Kein freier Port-Bereich für Worktree $name verfügbar."
            release_worktree_state_lock
            trap - EXIT
            return 1
        fi
    fi

    write_worktree_state "$name" "$compose_project" "$app_port" "$vite_port" "$db_port" "$redis_port"
    release_worktree_state_lock
    trap - EXIT
    load_worktree_state "$name" || return 1
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
    local name=$1
    local path=${2:-$1}
    local sail_bin
    local build_context=
    local build_dockerfile=
    local mysql_init_script=

    if [ "$#" -lt 2 ]; then
        name=$(basename "$1")
    fi
    sail_bin=${SAIL_BIN:-$path/vendor/bin/sail}
    load_worktree_state "$name" || return 1

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
