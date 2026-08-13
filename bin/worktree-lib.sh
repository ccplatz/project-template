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

worktree_instance_name_for_worktree() {
    local name=$1
    local instance_name="${PROJECT_NAME}-${name}"
    if printf '%s\n' "$instance_name" | LC_ALL=C grep -qE '^[a-z0-9][a-z0-9_-]*$'; then
        printf '%s\n' "$instance_name"
        return 0
    fi
    printf 'invalid worktree instance name: %s (derived from PROJECT_NAME=%s)\n' \
        "$instance_name" "$PROJECT_NAME" >&2
    return 1
}

value_is_decimal() {
    case "$1" in
        0|[1-9][0-9]*) ;;
        *) return 1 ;;
    esac
}

worktree_port_is_valid() {
    value_is_decimal "$1" || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

worktree_profile_entries() {
    local remaining=${WORKTREE_PORT_PROFILE:-}
    local entry
    local profile_name
    local profile_base

    [ -n "$remaining" ] || return 0
    while :; do
        case "$remaining" in
            *,*)
                entry=${remaining%%,*}
                remaining=${remaining#*,}
                ;;
            *)
                entry=$remaining
                remaining=
                ;;
        esac
        profile_name=${entry%%=*}
        profile_base=${entry#*=}
        printf '%s=%s\n' "$profile_name" "$profile_base"
        [ -n "$remaining" ] || break
    done
}

worktree_profile_name_for_key() {
    local expected_key=$1
    local profile_name
    local profile_base
    local matched_name=

    while IFS='=' read -r profile_name profile_base; do
        if [ "$expected_key" = "WORKTREE_PORT_${profile_name^^}" ]; then
            matched_name=$profile_name
        fi
    done < <(worktree_profile_entries)
    [ -n "$matched_name" ] || return 1
    printf '%s\n' "$matched_name"
}

write_worktree_state() {
    local name=$1
    local instance_name=$2
    local profile_name
    local profile_base
    local port
    local state_dir
    local state_file
    local temporary_file

    shift 2
    state_dir=$(worktree_state_dir)
    state_file=$(worktree_state_path "$name")
    mkdir -p "$state_dir"
    temporary_file="$state_file.tmp.$$"
    {
        printf 'WORKTREE_NAME=%s\n' "$name"
        printf 'WORKTREE_INSTANCE_NAME=%s\n' "$instance_name"
        while IFS='=' read -r profile_name profile_base; do
            if [ "$#" -lt 1 ]; then
                rm -f "$temporary_file"
                die "invalid worktree state: incomplete port profile for $name"
                return 1
            fi
            port=$1
            shift
            if ! worktree_port_is_valid "$port"; then
                rm -f "$temporary_file"
                die "invalid worktree state: invalid port for $profile_name"
                return 1
            fi
            printf 'WORKTREE_PORT_%s=%s\n' "${profile_name^^}" "$port"
        done < <(worktree_profile_entries)
        if [ "$#" -ne 0 ]; then
            rm -f "$temporary_file"
            die "invalid worktree state: too many ports for $name"
            return 1
        fi
    } > "$temporary_file"
    mv "$temporary_file" "$state_file"
}

load_worktree_state() {
    local name=$1
    local state_file
    local expected_instance_name
    local line
    local key
    local value
    local state_name=
    local state_instance_name=
    local profile_name
    local profile_base
    local state_port
    local port_key
    declare -A state_ports=()
    declare -A seen_keys=()

    state_file=$(worktree_state_path "$name") || return 1
    expected_instance_name=$(worktree_instance_name_for_worktree "$name") || return 1
    if [ ! -f "$state_file" ]; then
        die "worktree state missing for $name: $state_file"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            *=*)
                key=${line%%=*}
                value=${line#*=}
                if [ -n "${seen_keys[$key]+set}" ]; then
                    die "invalid worktree state: duplicate key $key in $state_file"
                    return 1
                fi
                seen_keys[$key]=1
                case "$key" in
                    WORKTREE_NAME) state_name=$value ;;
                    WORKTREE_INSTANCE_NAME) state_instance_name=$value ;;
                    WORKTREE_PORT_*)
                        if ! profile_name=$(worktree_profile_name_for_key "$key"); then
                            die "invalid worktree state: unknown key $key in $state_file"
                            return 1
                        fi
                        state_ports[$profile_name]=$value
                        ;;
                    *)
                        die "invalid worktree state: unknown key $key in $state_file"
                        return 1
                        ;;
                esac
                ;;
            *)
                die "invalid worktree state: unexpected line in $state_file"
                return 1
                ;;
        esac
    done < "$state_file"

    if [ -z "${seen_keys[WORKTREE_NAME]+set}" ] || [ -z "${seen_keys[WORKTREE_INSTANCE_NAME]+set}" ]; then
        die "invalid worktree state: incomplete record in $state_file"
        return 1
    fi
    if [ "$state_name" != "$name" ]; then
        die "invalid worktree state: worktree name mismatch in $state_file"
        return 1
    fi
    if [ "$state_instance_name" != "$expected_instance_name" ]; then
        die "invalid worktree state: worktree instance name mismatch in $state_file"
        return 1
    fi
    while IFS='=' read -r profile_name profile_base; do
        port_key=WORKTREE_PORT_${profile_name^^}
        if [ -z "${seen_keys[$port_key]+set}" ]; then
            die "invalid worktree state: incomplete record in $state_file"
            return 1
        fi
        state_port=${state_ports[$profile_name]}
        if ! worktree_port_is_valid "$state_port"; then
            die "invalid worktree state: port WORKTREE_PORT_$profile_name must be decimal and valid in $state_file"
            return 1
        fi
    done < <(worktree_profile_entries)

    unset WORKTREE_NAME WORKTREE_INSTANCE_NAME
    while IFS='=' read -r profile_name profile_base; do
        port_key=WORKTREE_PORT_${profile_name^^}
        printf -v "$port_key" '%s' "${state_ports[$profile_name]}"
        export "${port_key?}"
    done < <(worktree_profile_entries)
    WORKTREE_NAME=$name
    WORKTREE_INSTANCE_NAME=$state_instance_name
    export WORKTREE_NAME WORKTREE_INSTANCE_NAME
}

prepare_worktree_env() {
    local path=$1
    local template_path="$path/$WORKTREE_ENV_TEMPLATE"

    [ -f "$path/.env" ] && return 0
    [ -f "$template_path" ] || return 0
    cp "$template_path" "$path/.env"
}

worktree_state_lock_dir() {
    printf '%s/.allocation-lock\n' "$(worktree_state_dir)"
}

acquire_worktree_state_lock() {
    local lock_dir
    local pid
    lock_dir=$(worktree_state_lock_dir)
    mkdir -p "$(dirname "$lock_dir")"
    for _ in 1 2; do
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
                        die "Port allocation is already running (process $pid). Wait and try again."
                        return 1
                    fi
                    rm -rf "$lock_dir"
                    ;;
            esac
        else
            rm -rf "$lock_dir"
        fi
    done
    die "Could not acquire the port allocation lock: $lock_dir"
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
    local profile_name
    local profile_base
    local state_name
    local state_port
    local candidate_port
    local own_state_file
    local state_file
    local state_dir
    local state_port_key
    local -a candidate_ports=("${@:2}")
    local expected_port_count=0

    state_dir=$(worktree_state_dir)
    own_state_file=$(worktree_state_path "$name")
    while IFS='=' read -r profile_name profile_base; do
        expected_port_count=$((expected_port_count + 1))
    done < <(worktree_profile_entries)
    [ "${#candidate_ports[@]}" -eq "$expected_port_count" ] || return 1
    for candidate_port in "${candidate_ports[@]}"; do
        worktree_port_is_valid "$candidate_port" || return 1
    done
    for state_file in "$state_dir"/*.env; do
        [ -f "$state_file" ] || continue
        [ "$state_file" = "$own_state_file" ] && continue
        state_name=${state_file##*/}
        state_name=${state_name%.env}
        validate_worktree_name "$state_name" || return 1
        load_worktree_state "$state_name" || return 1
        for candidate_port in "${candidate_ports[@]}"; do
            while IFS='=' read -r profile_name profile_base; do
                state_port_key=WORKTREE_PORT_${profile_name^^}
                state_port=${!state_port_key}
                [ "$candidate_port" != "$state_port" ] || return 1
            done < <(worktree_profile_entries)
        done
    done
    for candidate_port in "${candidate_ports[@]}"; do
        port_is_available "$candidate_port" || return 1
    done
}

ensure_worktree_state() {
    local name=$1
    local path=$2
    local state_file
    local instance_name
    local profile_name
    local profile_base
    local own_state_file
    local state_name
    local index
    local -a candidate_ports=()

    state_file=$(worktree_state_path "$name") || return 1

    if [ -f "$state_file" ]; then
        load_worktree_state "$name" || return 1
        prepare_worktree_env "$path" || return 1
        return 0
    fi

    instance_name=$(worktree_instance_name_for_worktree "$name") || return 1

    if ! acquire_worktree_state_lock; then
        return 1
    fi
    trap 'release_worktree_state_lock' EXIT

    own_state_file=$(worktree_state_path "$name")
    for state_file in "$(worktree_state_dir)"/*.env; do
        [ -f "$state_file" ] || continue
        [ "$state_file" = "$own_state_file" ] && continue
        state_name=${state_file##*/}
        state_name=${state_name%.env}
        if ! validate_worktree_name "$state_name" || ! load_worktree_state "$state_name" >/dev/null 2>&1; then
            die "invalid worktree state blocks port allocation: $state_file"
            release_worktree_state_lock
            trap - EXIT
            return 1
        fi
    done

    for ((index = 0; index < 100; index++)); do
        candidate_ports=()
        while IFS='=' read -r profile_name profile_base; do
            candidate_ports+=("$((profile_base + index * WORKTREE_PORT_STRIDE))")
        done < <(worktree_profile_entries)
        if worktree_state_port_available "$name" "${candidate_ports[@]}"; then
            break
        fi
    done
    if [ "$index" -ge 100 ]; then
        die "No free port range available for worktree $name."
        release_worktree_state_lock
        trap - EXIT
        return 1
    fi

    write_worktree_state "$name" "$instance_name" "${candidate_ports[@]}"
    release_worktree_state_lock
    trap - EXIT
    load_worktree_state "$name" || return 1
    prepare_worktree_env "$path" || return 1
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

port_is_available() {
    if command -v nc >/dev/null 2>&1; then
        ! nc -z 127.0.0.1 "$1" >/dev/null 2>&1
        return
    fi
    if (: 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
        return 1
    fi
    return 0
}

die() {
    printf '%s\n' "$1" >&2
    return 1
}

run_consumer_hook() {
    local name=$1
    local path=$2
    local hook=$3
    local state_file
    local consumer="$path/bin/consumer"
    local port_key
    local profile_name
    local profile_base
    local -a adapter_environment=(env -i)

    load_worktree_state "$name" || return 1
    if [ ! -x "$consumer" ]; then
        die "Worktree $name has no executable consumer adapter: $consumer (see docs/runtime-hooks.md)"
        return 1
    fi
    prepare_worktree_env "$path" || return 1
    state_file=$(worktree_state_path "$name") || return 1
    WORKTREE_PATH=$path
    WORKTREE_ROOT=$worktree_root
    WORKTREE_STATE_FILE=$state_file
    WORKTREE_ENV_FILE=$path/.env
    if [ "${PATH+x}" = x ]; then
        adapter_environment+=("PATH=$PATH")
    fi
    if [ "${HOME+x}" = x ]; then
        adapter_environment+=("HOME=$HOME")
    fi
    adapter_environment+=(
        "WORKTREE_NAME=$WORKTREE_NAME"
        "WORKTREE_PATH=$WORKTREE_PATH"
        "WORKTREE_ROOT=$WORKTREE_ROOT"
        "WORKTREE_STATE_FILE=$WORKTREE_STATE_FILE"
        "WORKTREE_ENV_FILE=$WORKTREE_ENV_FILE"
        "WORKTREE_INSTANCE_NAME=$WORKTREE_INSTANCE_NAME"
    )
    while IFS='=' read -r profile_name profile_base; do
        port_key=WORKTREE_PORT_${profile_name^^}
        adapter_environment+=("$port_key=${!port_key}")
    done < <(worktree_profile_entries)
    (
        cd "$path" || exit 1
        "${adapter_environment[@]}" ./bin/consumer "$hook"
    )
}

bootstrap_for_worktree() {
    local name=$1
    local path=$2

    ensure_worktree_state "$name" "$path" || return 1
    run_consumer_hook "$name" "$path" bootstrap
}

start_for_worktree() {
    local name=$1
    local path=$2

    ensure_worktree_state "$name" "$path" || return 1
    run_consumer_hook "$name" "$path" start
}

stop_for_worktree() {
    local name=$1
    local path=$2

    if [ ! -f "$(worktree_state_path "$name")" ]; then
        die "Worktree state is not initialized for $name; run bin/worktree bootstrap first"
        return 1
    fi
    run_consumer_hook "$name" "$path" stop
}

reset_for_worktree() {
    local name=$1
    local path=$2
    local status

    if run_consumer_hook "$name" "$path" reset; then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 2 ]; then
        printf 'Reset is not supported by Worktree %s; see docs/runtime-hooks.md\n' "$name" >&2
    fi
    return "$status"
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

active_worktree_name() {
    local name
    name=$(read_active_worktree) || {
        printf 'no active worktree is recorded; provide a worktree name\n' >&2
        return 1
    }
    validate_worktree_name "$name" || {
        printf 'stale active worktree: %s\n' "$name" >&2
        return 1
    }
    printf '%s\n' "$name"
}

list_worktree_state_names() {
    local state_file
    local name
    local state_dir
    state_dir=$(worktree_state_dir)
    for state_file in "$state_dir"/*.env; do
        [ -f "$state_file" ] || continue
        name=${state_file##*/}
        name=${name%.env}
        printf '%s\n' "$name"
    done
}

worktree_is_listed_by_git() {
    local path=$1
    local listing
    listing=$(run_git worktree list --porcelain 2>/dev/null) || return 1
    case "$listing" in
        *$'worktree '"$path"$'\n'*) return 0 ;;
        *$'worktree '"$path") return 0 ;;
        *) return 1 ;;
    esac
}

prune_worktree_state() {
    local name
    local path
    local state_file
    local listing_status
    for name in $(list_worktree_state_names); do
        state_file=$(worktree_state_path "$name") || continue
        path=$(worktree_path "$name")
        if [ ! -d "$path" ] || ! run_git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            if worktree_is_listed_by_git "$path"; then
                continue
            else
                listing_status=$?
            fi
            if [ "$listing_status" -eq 1 ]; then
                rm -f "$state_file"
                printf 'pruned: %s\n' "$name"
            fi
        fi
    done
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
