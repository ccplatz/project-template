#!/bin/bash
set -euo pipefail

load_project_config() {
    local project_root=$1
    local config_file="$project_root/.template/project.conf"

    PROJECT_CONFIG_LOADED=0
    unset PROJECT_NAME WORKTREE_PORT_PROFILE WORKTREE_PORT_STRIDE WORKTREE_ENV_TEMPLATE

    if [ ! -f "$config_file" ]; then
        printf 'Project configuration missing: %s\n' "$config_file" >&2
        return 1
    fi

    # Project-local configuration is trusted shell code by design.
    # shellcheck source=/dev/null
    if ! source "$config_file"; then
        printf 'Could not load project configuration: %s\n' "$config_file" >&2
        return 1
    fi

    case "${PROJECT_NAME:-}" in
        ''|[!A-Za-z0-9]*|*[!A-Za-z0-9_.-]*)
            printf 'Invalid PROJECT_NAME in %s. Only alphanumeric characters plus ., _ and - are allowed.\n' \
                "$config_file" >&2
            return 1
            ;;
    esac

    local configured_profile=${WORKTREE_PORT_PROFILE-}
    local configured_stride=${WORKTREE_PORT_STRIDE-10}
    local configured_env_template=${WORKTREE_ENV_TEMPLATE-.env.template}
    local profile_entry profile_name profile_base remaining last_entry
    local seen_names='|'

    if [ -n "$configured_profile" ]; then
        remaining=$configured_profile
        while :; do
            last_entry=0
            case "$remaining" in
                *,*)
                    profile_entry=${remaining%%,*}
                    remaining=${remaining#*,}
                    ;;
                *)
                    profile_entry=$remaining
                    remaining=
                    last_entry=1
                    ;;
            esac

            case "$profile_entry" in
                ''|*'=')
                    printf 'Invalid WORKTREE_PORT_PROFILE in %s.\n' "$config_file" >&2
                    return 1
                    ;;
                *=*)
                    profile_name=${profile_entry%%=*}
                    profile_base=${profile_entry#*=}
                    ;;
                *)
                    printf 'Invalid WORKTREE_PORT_PROFILE in %s.\n' "$config_file" >&2
                    return 1
                    ;;
            esac

            case "$profile_name" in
                ''|*[!a-z0-9_]*)
                    printf 'Invalid WORKTREE_PORT_PROFILE in %s.\n' "$config_file" >&2
                    return 1
                    ;;
            esac

            case "$profile_base" in
                ''|*[!0-9]*)
                    printf 'Invalid WORKTREE_PORT_PROFILE in %s.\n' "$config_file" >&2
                    return 1
                    ;;
                [1-9]*)
                    if [ "${#profile_base}" -gt 5 ] || [ "$profile_base" -gt 65535 ]; then
                        printf 'Invalid WORKTREE_PORT_PROFILE in %s.\n' "$config_file" >&2
                        return 1
                    fi
                    ;;
                *)
                    printf 'Invalid WORKTREE_PORT_PROFILE in %s.\n' "$config_file" >&2
                    return 1
                    ;;
            esac

            case "$seen_names" in
                *"|${profile_name}|"*)
                    printf 'Invalid WORKTREE_PORT_PROFILE in %s.\n' "$config_file" >&2
                    return 1
                    ;;
            esac
            seen_names=$seen_names$profile_name'|'

            [ "$last_entry" -eq 1 ] && break
        done
    fi

    case "$configured_stride" in
        ''|*[!0-9]*)
            printf 'Invalid WORKTREE_PORT_STRIDE in %s.\n' "$config_file" >&2
            return 1
            ;;
        [1-9]*) ;;
        *)
            printf 'Invalid WORKTREE_PORT_STRIDE in %s.\n' "$config_file" >&2
            return 1
            ;;
    esac

    WORKTREE_PORT_PROFILE=$configured_profile
    WORKTREE_PORT_STRIDE=$configured_stride
    WORKTREE_ENV_TEMPLATE=$configured_env_template
    export PROJECT_NAME
    export WORKTREE_PORT_PROFILE WORKTREE_PORT_STRIDE WORKTREE_ENV_TEMPLATE
    PROJECT_CONFIG_LOADED=1
}

project_config_name() {
    if [ "${PROJECT_CONFIG_LOADED:-0}" -ne 1 ]; then
        printf 'Project configuration was not loaded.\n' >&2
        return 1
    fi
    printf '%s\n' "$PROJECT_NAME"
}
