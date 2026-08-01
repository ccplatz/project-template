#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../../bin/container-lib.sh
# shellcheck disable=SC1091
source "$script_dir/../../bin/container-lib.sh"

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

assert_eq 'docker-compose.staging.yml' "$(resolve_compose_file staging)" \
    'resolve_compose_file for staging'
assert_eq 'docker-compose.prod.yml' "$(resolve_compose_file prod)" \
    'resolve_compose_file for prod'

assert_status 0 validate_environment staging
assert_status 0 validate_environment prod
assert_failure_contains 'Ungültige ENVIRONMENT' validate_environment dev
assert_failure_contains 'Ungültige ENVIRONMENT' validate_environment ''

assert_eq '' "$(list_external_networks '')" 'empty input yields no networks'
assert_eq 'traefik' "$(list_external_networks 'traefik')" 'single network'
assert_eq $'traefik\npma' "$(list_external_networks 'traefik,pma')" 'two networks'
assert_eq $'traefik\npma' "$(list_external_networks ' traefik , pma ')" 'trims whitespace'
assert_eq 'a' "$(list_external_networks ',a,')" 'skips empty segments'

docker_log=$(mktemp)
run_docker() {
    printf '%s\n' "$*" >>"$docker_log"
    if [ "$1" = network ] && [ "$2" = inspect ]; then
        [ "${MOCK_NET_EXISTS:-0}" -eq 1 ] || return 1
        case "$*" in
            *'--format'*)
                [ "${MOCK_NET_CONTAINERS:-0}" -eq 1 ] && printf '2\n' || printf '0\n'
                ;;
            *) printf '{"Containers":{}}\n' ;;
        esac
        return 0
    fi
    case "$1 $2" in
        'ps --format')
            [ "${MOCK_CONTAINER_RUNNING:-0}" -eq 1 ] || return 0
            printf '%s\n' "${MOCK_CONTAINER_NAME:-myhost-app}"
            return 0
            ;;
        'exec '*)
            [ "${MOCK_SHELL_OK:-0}" -eq 1 ] || return 1
            return 0
            ;;
        *) return 0 ;;
    esac
}

HOSTNAME=myhost

MOCK_NET_EXISTS=0
assert_status 1 network_exists traefik
MOCK_NET_EXISTS=1
assert_status 0 network_exists traefik

MOCK_NET_EXISTS=1 MOCK_NET_CONTAINERS=0
assert_status 1 network_has_containers traefik
MOCK_NET_EXISTS=1 MOCK_NET_CONTAINERS=1
assert_status 0 network_has_containers traefik
MOCK_NET_EXISTS=0
assert_status 0 network_has_containers traefik  # error → safe default "has containers"

assert_eq 'myhost-app' "$(container_full_name app)" 'container_full_name joins HOSTNAME and short'

MOCK_CONTAINER_RUNNING=0
assert_status 1 container_is_running myhost-app
MOCK_CONTAINER_RUNNING=1 MOCK_CONTAINER_NAME=myhost-app
assert_status 0 container_is_running myhost-app
MOCK_CONTAINER_RUNNING=1 MOCK_CONTAINER_NAME=myhost-app-v2
assert_status 1 container_is_running myhost-app  # exact match, no substring

MOCK_SHELL_OK=1
assert_status 0 shell_available myhost-app /bin/bash
MOCK_SHELL_OK=0
assert_status 1 shell_available myhost-app /bin/bash

# ---- CLI tests ----
container_script="$script_dir/../../bin/container"
cli_root=$(mktemp -d)
trap 'rm -rf "$docker_log" "$cli_root"' EXIT
mkdir -p "$cli_root/bin"

# PATH-stub docker: records calls, behavior via MOCK_* flags
cat > "$cli_root/bin/docker" <<'STUB'
#!/bin/bash
set -euo pipefail
echo "docker $*" >>"${DOCKER_LOG:-/dev/null}"
if [ "$1" = network ] && [ "$2" = inspect ]; then
    [ "${MOCK_NET_EXISTS:-0}" -eq 1 ] || exit 1
    case "$*" in
        *'--format'*)
            [ "${MOCK_NET_CONTAINERS:-0}" -eq 1 ] && printf '2\n' || printf '0\n'
            ;;
        *) printf '{"Containers":{}}\n' ;;
    esac
    exit 0
fi
case "$1 $2" in
    'network create') exit 0 ;;
    'network rm') exit "${MOCK_NET_RM_EXIT:-0}" ;;
esac
if [ "$1" = compose ]; then
    exit "${MOCK_COMPOSE_EXIT:-0}"
fi
if [ "$1" = ps ] && [ "$2" = --format ]; then
    [ "${MOCK_CONTAINER_RUNNING:-0}" -eq 1 ] && printf '%s\n' "${MOCK_CONTAINER_NAME:-}"
    exit 0
fi
if [ "$1" = exec ]; then exit 0; fi
exit 0
STUB
chmod +x "$cli_root/bin/docker"
old_path=$PATH
PATH="$cli_root/bin:$PATH"
export PATH

write_env() {
    printf 'ENVIRONMENT=%s\nEXTERNAL_NETWORKS=%s\nHOSTNAME=%s\n' \
        "${1-}" "${2:-}" "${3:-myhost}" > "$cli_root/.env"
}

run_cli() {
    CONTAINER_TEST_ROOT="$cli_root" DOCKER_LOG="$cli_root/docker.log" "$container_script" "$@"
}

# help
assert_status 0 run_cli --help
assert_status 0 run_cli -h
help_out=$(run_cli --help 2>/dev/null)
case "$help_out" in
    *'Verwendung:'*) printf 'ok - --help prints usage to stdout\n' ;;
    *) printf 'not ok - --help stdout missing Verwendung:\n' >&2; failures=$((failures + 1)) ;;
esac
help_err=$(run_cli --help 2>&1 >/dev/null)
[ -z "$help_err" ] && printf 'ok - --help stderr is empty\n' || { printf 'not ok - --help wrote to stderr\n' >&2; failures=$((failures + 1)); }
help_out=$(run_cli -h 2>/dev/null)
case "$help_out" in
    *'Verwendung:'*) printf 'ok - -h prints usage to stdout\n' ;;
    *) printf 'not ok - -h stdout missing Verwendung:\n' >&2; failures=$((failures + 1)) ;;
esac
help_err=$(run_cli -h 2>&1 >/dev/null)
[ -z "$help_err" ] && printf 'ok - -h stderr is empty\n' || { printf 'not ok - -h wrote to stderr\n' >&2; failures=$((failures + 1)); }
# usage errors
assert_failure_contains 'Verwendung:' run_cli bogus
assert_failure_contains 'Verwendung:' run_cli start --buil
assert_failure_contains 'Verwendung:' run_cli start foo
assert_failure_contains 'Verwendung:' run_cli restart extra junk
assert_failure_contains 'Verwendung:' run_cli stop --build
assert_failure_contains 'Verwendung:' run_cli attach
assert_failure_contains 'Verwendung:' run_cli attach a b
assert_failure_contains 'Verwendung:' run_cli status extra
# env validation
write_env dev
assert_failure_contains 'Ungültige ENVIRONMENT' run_cli status
write_env ''
assert_failure_contains 'Ungültige ENVIRONMENT' run_cli status

# start creates missing networks
write_env prod 'traefik,pma'
: > "$cli_root/docker.log"
MOCK_NET_EXISTS=0 run_cli start
grep -q 'network create traefik' "$cli_root/docker.log"
grep -q 'compose -f docker-compose.prod.yml up -d --remove-orphans' "$cli_root/docker.log"
# start --build
: > "$cli_root/docker.log"
MOCK_NET_EXISTS=1 run_cli start --build
grep -q 'up --build -d --remove-orphans' "$cli_root/docker.log"

# stop: compose down then remove empty networks, keep used ones
: > "$cli_root/docker.log"
MOCK_NET_EXISTS=1 MOCK_NET_CONTAINERS=0 run_cli stop
grep -q 'compose -f docker-compose.prod.yml down --remove-orphans' "$cli_root/docker.log"
grep -q 'network rm traefik' "$cli_root/docker.log"
grep -q 'network rm pma' "$cli_root/docker.log"
: > "$cli_root/docker.log"
MOCK_NET_EXISTS=1 MOCK_NET_CONTAINERS=1 run_cli stop
! grep -q 'network rm' "$cli_root/docker.log"

# stop reports a failed removal but continues siblings; exits 1
: > "$cli_root/docker.log"
MOCK_NET_EXISTS=1 MOCK_NET_CONTAINERS=0 MOCK_NET_RM_EXIT=1 assert_status 1 run_cli stop
grep -q 'network rm traefik' "$cli_root/docker.log"
grep -q 'network rm pma' "$cli_root/docker.log"
stop_err=$(MOCK_NET_EXISTS=1 MOCK_NET_CONTAINERS=0 MOCK_NET_RM_EXIT=1 run_cli stop 2>&1 >/dev/null) || true
case "$stop_err" in
    *'konnte nicht entfernt werden'*) printf 'ok - stop warns on failed network rm\n' ;;
    *) printf 'not ok - stop missing failed-rm warning\n' >&2; failures=$((failures + 1)) ;;
esac

# attach: running container, exact name
write_env prod '' myhost
: > "$cli_root/docker.log"
MOCK_CONTAINER_RUNNING=1 MOCK_CONTAINER_NAME=myhost-app run_cli attach app
grep -q 'exec -it myhost-app' "$cli_root/docker.log"
# attach: not running → clear failure, no exec
: > "$cli_root/docker.log"
MOCK_CONTAINER_RUNNING=0 assert_failure_contains 'läuft nicht' run_cli attach app
! grep -q 'exec -it' "$cli_root/docker.log"

PATH=$old_path

# ---- Diagnostic command CLI tests (status, ps, logs) ----
PATH="$cli_root/bin:$old_path"
write_env prod 'traefik,pma' myhost

# status
: > "$cli_root/docker.log"
MOCK_NET_EXISTS=1 MOCK_NET_CONTAINERS=1 run_cli status
out=$(CONTAINER_TEST_ROOT="$cli_root" DOCKER_LOG="$cli_root/docker.log" \
    MOCK_NET_EXISTS=1 run_cli status)
case "$out" in
    *'ENVIRONMENT: prod'*'Compose-Datei: docker-compose.prod.yml'*'Externe Netzwerke:'*'traefik: 0 Container'*) printf 'ok - status output fields\n' ;;
    *) printf 'not ok - status output fields\n%s\n' "$out" >&2; failures=$((failures + 1)) ;;
esac

# ps uses docker ps with the compose project label filter
: > "$cli_root/docker.log"
run_cli ps
grep -q 'ps --filter label=com.docker.compose.project=<PROJEKTNAME>' "$cli_root/docker.log"
grep -q '{{.ID}}' "$cli_root/docker.log"
grep -q '{{.Names}}' "$cli_root/docker.log"
grep -q '{{.Networks}}' "$cli_root/docker.log"

# logs without service
: > "$cli_root/docker.log"
run_cli logs
grep -q 'compose -f docker-compose.prod.yml logs --tail=200' "$cli_root/docker.log"
# logs with service and --follow
: > "$cli_root/docker.log"
run_cli logs app -f
grep -q 'logs -f --tail=200 app' "$cli_root/docker.log"
# logs --follow before service
: > "$cli_root/docker.log"
run_cli logs --follow mysql
grep -q 'logs -f --tail=200 mysql' "$cli_root/docker.log"
# logs rejects strict-arg violations
assert_failure_contains 'Verwendung:' run_cli logs a b
assert_failure_contains 'Verwendung:' run_cli logs --bogus

PATH=$old_path

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all tests passed\n'
