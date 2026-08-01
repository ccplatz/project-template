#!/bin/bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"

run_docker() {
    docker "$@"
}

run_compose() {
    docker compose "$@"
}

die() {
    printf '%s\n' "$1" >&2
    return 1
}

usage() {
    cat <<'EOF'
bin/container — Verwaltung des Staging/Prod-Docker-Stacks

Verwendung:
  bin/container start [--build]
  bin/container stop
  bin/container restart [--build]
  bin/container attach <container_short_name>
  bin/container status
  bin/container ps
  bin/container logs [service] [-f|--follow]
  bin/container --help | -h

Optionen:
  --build        Image vor dem Start neu bauen (nur bei start/restart)
  -f, --follow   Logs fortlaufend verfolgen (nur bei logs)
  --help, -h     Diese Hilfe anzeigen
EOF
}

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

validate_environment() {
    local env=$1
    case "$env" in
        staging|prod) return 0 ;;
        *)
            printf "Ungültige ENVIRONMENT '%s' in %s. Erlaubt: 'staging' oder 'prod'.\n" \
                "$env" "$ENV_FILE" >&2
            return 1
            ;;
    esac
}

resolve_compose_file() {
    printf 'docker-compose.%s.yml\n' "$1"
}

list_external_networks() {
    local raw=$1
    [ -n "$raw" ] || return 0
    local IFS=','
    local parts=()
    read -ra parts <<<"$raw"
    local n
    for n in "${parts[@]}"; do
        n=$(trim "$n")
        [ -n "$n" ] && printf '%s\n' "$n"
    done
}

network_exists() {
    run_docker network inspect "$1" >/dev/null 2>&1
}

network_has_containers() {
    local network=$1
    local count
    if ! count=$(run_docker network inspect "$network" \
        --format '{{len .Containers}}' 2>/dev/null); then
        return 0  # inspect failed → assume non-empty, safe (do not remove)
    fi
    [ "${count:-0}" -gt 0 ]
}

container_full_name() {
    printf '%s-%s\n' "${HOSTNAME:-}" "$1"
}

container_is_running() {
    local name=$1
    local found
    found=$(run_docker ps --format '{{.Names}}' 2>/dev/null | grep -Fx "$name") || return 1
    [ -n "$found" ]
}

shell_available() {
    local container=$1 shell=$2
    run_docker exec "$container" "$shell" -c 'echo' >/dev/null 2>&1
}
