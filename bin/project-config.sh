#!/bin/bash
set -euo pipefail

load_project_config() {
    local project_root=$1
    local config_file="$project_root/.template/project.conf"

    PROJECT_CONFIG_LOADED=0
    unset PROJECT_NAME

    if [ ! -f "$config_file" ]; then
        printf 'Projektkonfiguration fehlt: %s\n' "$config_file" >&2
        return 1
    fi

    # Project-local configuration is trusted shell code by design.
    # shellcheck source=/dev/null
    if ! source "$config_file"; then
        printf 'Projektkonfiguration konnte nicht geladen werden: %s\n' "$config_file" >&2
        return 1
    fi

    case "${PROJECT_NAME:-}" in
        ''|[!A-Za-z0-9]*|*[!A-Za-z0-9_.-]*)
            printf 'Ungültiger PROJECT_NAME in %s. Erlaubt sind nur alphanumerische Zeichen sowie ., _ und -.\n' \
                "$config_file" >&2
            return 1
            ;;
    esac

    export PROJECT_NAME
    PROJECT_CONFIG_LOADED=1
}

project_config_name() {
    if [ "${PROJECT_CONFIG_LOADED:-0}" -ne 1 ]; then
        printf 'Projektkonfiguration wurde nicht geladen.\n' >&2
        return 1
    fi
    printf '%s\n' "$PROJECT_NAME"
}
