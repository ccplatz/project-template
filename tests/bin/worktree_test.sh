#!/bin/bash

set -euo pipefail

repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT

mkdir -p "$repo/.worktrees"
mkdir -p "$repo/.template"
mkdir -p "$repo/bin"
printf '%s\n' \
    'PROJECT_NAME=test-project' \
    'WORKTREE_PORT_PROFILE="http=8080,frontend=5173,database=3306,cache=6379"' \
    'WORKTREE_PORT_STRIDE=10' \
    'WORKTREE_ENV_TEMPLATE=.env.template' > "$repo/.template/project.conf"

cat > "$repo/bin/consumer" <<'CONSUMER_EOF'
#!/bin/bash
set -euo pipefail

hook=${1:-}
if [ "$#" -ne 1 ]; then
    printf 'BAD_ARG_COUNT=%s\n' "$#" >> "$WORKTREE_ROOT/consumer.log"
    exit 97
fi
log="$WORKTREE_ROOT/consumer.log"
marker_dir="$WORKTREE_ROOT/consumer-state"
instance=${WORKTREE_INSTANCE_NAME:?}

expected_environment_keys=(
    WORKTREE_NAME
    WORKTREE_PATH
    WORKTREE_ROOT
    WORKTREE_STATE_FILE
    WORKTREE_ENV_FILE
    WORKTREE_INSTANCE_NAME
)
[ "${PATH+x}" = x ] && expected_environment_keys+=(PATH)
[ "${HOME+x}" = x ] && expected_environment_keys+=(HOME)
while IFS='=' read -r state_key state_value; do
    case "$state_key" in
        WORKTREE_PORT_*) expected_environment_keys+=("$state_key") ;;
    esac
done < "$WORKTREE_STATE_FILE"

actual_environment_keys=()
while IFS='=' read -r environment_name environment_value; do
    actual_environment_keys+=("$environment_name")
done < <(tr '\0' '\n' < "/proc/$$/environ")

environment_mismatch=
for environment_name in "${actual_environment_keys[@]}"; do
    environment_found=0
    for expected_name in "${expected_environment_keys[@]}"; do
        if [ "$environment_name" = "$expected_name" ]; then
            environment_found=1
            break
        fi
    done
    if [ "$environment_found" -eq 0 ]; then
        environment_mismatch="$environment_mismatch unexpected:$environment_name"
    fi
done
for expected_name in "${expected_environment_keys[@]}"; do
    environment_found=0
    for environment_name in "${actual_environment_keys[@]}"; do
        if [ "$expected_name" = "$environment_name" ]; then
            environment_found=1
            break
        fi
    done
    if [ "$environment_found" -eq 0 ]; then
        environment_mismatch="$environment_mismatch missing:$expected_name"
    fi
done
if [ -n "$environment_mismatch" ]; then
    printf 'UNEXPECTED_ENV=%s\n' "$environment_mismatch" >> "$log"
    exit 98
fi

{
    printf 'HOOK=%s\n' "$hook"
    printf 'PWD=%s\n' "$PWD"
    env | LC_ALL=C sort | LC_ALL=C grep '^WORKTREE_'
    printf 'SAIL_SET=%s COMPOSE_SET=%s APP_SET=%s VITE_SET=%s DB_SET=%s REDIS_SET=%s\n' \
        "${SAIL_BIN+y}" "${COMPOSE_PROJECT_NAME+y}" "${APP_PORT+y}" \
        "${VITE_PORT+y}" "${FORWARD_DB_PORT+y}" "${FORWARD_REDIS_PORT+y}"
} >> "$log"

case "$hook" in
    bootstrap)
        : ;;
    start)
        mkdir -p "$marker_dir"
        : > "$marker_dir/$instance"
        ;;
    stop)
        rm -f "$marker_dir/$instance"
        ;;
    status)
        if [ -f "$marker_dir/$instance" ]; then
            printf 'status: running\n'
        else
            printf 'status: stopped\n'
        fi
        ;;
    reset)
        if [ -f "$WORKTREE_ROOT/.consumer-no-reset" ]; then
            printf 'reset not supported\n' >&2
            printf 'reset not supported\n' >> "$log"
            exit 2
        fi
        ;;
    *)
        exit 1
        ;;
esac

if [ -f "$WORKTREE_ROOT/.consumer-fail-$hook" ]; then
    exit 1
fi
exit 0
CONSUMER_EOF
chmod +x "$repo/bin/consumer"

git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name 'Worktree Test'
touch "$repo/README"
printf 'APP_KEY=\n' > "$repo/.env.template"
printf 'APP_KEY=base64:from-example\n' > "$repo/.env.example"
git -C "$repo" add README
git -C "$repo" add .env.template
git -C "$repo" add .env.example
git -C "$repo" add bin/consumer
git -C "$repo" commit -q -m initial
git -C "$repo" checkout -q -b existing-source
printf 'APP_KEY=base64:already-set\n' > "$repo/.env.template"
git -C "$repo" add .env.template
git -C "$repo" commit -q -m existing-env
git -C "$repo" checkout -q main
git -C "$repo" worktree add -q -b feature-x "$repo/.worktrees/feature-x"
printf 'APP_KEY=base64:feature-x\n' > "$repo/.worktrees/feature-x/.env"

export WORKTREE_TEST_ROOT="$repo"
worktree_lib_script="$(dirname "$0")/../../bin/worktree-lib.sh"
# shellcheck source=../../bin/worktree-lib.sh
# shellcheck disable=SC1091
source "$worktree_lib_script"

consumer_log="$repo/consumer.log"
consumer_state="$repo/consumer-state"
: > "$consumer_log"
mkdir -p "$consumer_state"

failures=0

assert_eq() {
    local expected=$1
    local actual=$2
    local message=${3:-values differ}
    if [ "$expected" != "$actual" ]; then
        printf 'not ok - %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual"
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$message"
    fi
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

assert_failure_contains() {
    local expected=$1
    shift
    local output
    local actual
    if output=$("$@" 2>&1 >/dev/null); then
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

assert_failure_contains_input() {
    local input=$1
    local expected=$2
    shift 2
    local output
    local actual
    if output=$(printf '%s\n' "$input" | "$@" 2>&1 >/dev/null); then
        actual=0
    else
        actual=$?
    fi
    assert_eq 1 "$actual" "status of $* with input $input"
    case "$output" in
        *"$expected"*) printf 'ok - diagnostic of %s with input %s\n' "$*" "$input" ;;
        *)
            printf 'not ok - diagnostic of %s with input %s\nexpected to contain: %s\nactual: %s\n' \
                "$*" "$input" "$expected" "$output"
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

assert_strict_mode "$worktree_lib_script"

assert_contains() {
    local file=$1
    local expected=$2
    local content
    if [ ! -f "$file" ]; then
        printf 'not ok - %s does not exist, expected %s\n' "$file" "$expected"
        failures=$((failures + 1))
        return
    fi
    content=$(<"$file")
    case "$content" in
        *"$expected"*) printf 'ok - %s contains %s\n' "$file" "$expected" ;;
        *)
            printf 'not ok - %s does not contain %s\n' "$file" "$expected"
            failures=$((failures + 1))
            ;;
    esac
}

assert_output_contains() {
    local expected=$1
    shift
    local output
    local actual
    if output=$("$@" 2>&1); then
        actual=0
    else
        actual=$?
    fi
    assert_eq 0 "$actual" "status of $*"
    case "$output" in
        *"$expected"*) printf 'ok - output of %s contains %s\n' "$*" "$expected" ;;
        *)
            printf 'not ok - output of %s does not contain %s\n' "$*" "$expected"
            failures=$((failures + 1))
            ;;
    esac
}

assert_not_contains() {
    local file=$1
    local unexpected=$2
    local content
    if [ ! -f "$file" ]; then
        printf 'ok - %s does not exist and does not contain %s\n' "$file" "$unexpected"
        return
    fi
    content=$(<"$file")
    case "$content" in
        *"$unexpected"*)
            printf 'not ok - %s contains %s\n' "$file" "$unexpected"
            failures=$((failures + 1))
            ;;
        *) printf 'ok - %s does not contain %s\n' "$file" "$unexpected" ;;
    esac
}

assert_not_exists() {
    local path=$1
    if [ -e "$path" ]; then
        printf 'not ok - %s exists unexpectedly\n' "$path"
        failures=$((failures + 1))
    else
        printf 'ok - %s does not exist\n' "$path"
    fi
}

assert_exists() {
    local path=$1
    if [ -e "$path" ]; then
        printf 'ok - %s exists\n' "$path"
    else
        printf 'not ok - %s does not exist\n' "$path"
        failures=$((failures + 1))
    fi
}

assert_not_executable() {
    local path=$1
    if [ -x "$path" ]; then
        printf 'not ok - %s is executable unexpectedly\n' "$path"
        failures=$((failures + 1))
    else
        printf 'ok - %s is not executable\n' "$path"
    fi
}

assert_executable() {
    local path=$1
    if [ -x "$path" ]; then
        printf 'ok - %s is executable\n' "$path"
    else
        printf 'not ok - %s is not executable\n' "$path"
        failures=$((failures + 1))
    fi
}

assert_eq "$repo/.worktrees/feature-x" "$(resolve_worktree feature-x)" \
    'resolve an existing worktree'
assert_failure_contains 'invalid worktree name' resolve_worktree ../outside
assert_failure_contains 'invalid worktree name' resolve_worktree 'bad/name'
assert_failure_contains 'invalid worktree name' resolve_worktree 'bad name'
assert_failure_contains 'invalid worktree name' resolve_worktree "bad\$name"
assert_failure_contains 'invalid worktree name' resolve_worktree .hidden
assert_failure_contains 'worktree not found' resolve_worktree missing
# shellcheck disable=SC2218 # sourced write_active_worktree from worktree-lib.sh is active here; the local test double below replaces it for later assertions
write_active_worktree feature-x
assert_eq feature-x "$(cat "$repo/.worktree-active")" \
    'write the active worktree state file'
assert_eq feature-x "$(read_active_worktree)" \
    'read the active worktree state file'
assert_eq "$repo/.worktrees/feature-x" "$(active_worktree)" \
    'resolve the active worktree'

state_before=$(cat "$repo/.worktree-active")
assert_failure_contains 'worktree not found' validate_worktree missing
assert_eq "$state_before" "$(cat "$repo/.worktree-active")" \
    'validation does not change active state'

run_git() {
    case "$*" in
        -C\ *\ rev-parse\ --is-inside-work-tree)
            if [ "${RUN_GIT_RESOLVE_FAILURE:-0}" -eq 1 ]; then
                return 1
            fi
            return 0
            ;;
        show-ref\ --verify\ --quiet\ refs/heads/missing-branch)
            return 1
            ;;
        show-ref\ --verify\ --quiet\ refs/heads/feature-x)
            return 0
            ;;
        show-ref\ --verify\ --quiet\ refs/heads/enumeration-failure)
            return 0
            ;;
        worktree\ list\ --porcelain)
            if [ "${RUN_GIT_ENUMERATION_FAILURE:-0}" -eq 1 ]; then
                return 1
            fi
            printf 'worktree %s\nbranch refs/heads/feature-x\n\n' \
                "$repo/.worktrees/feature-x"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

export RUN_GIT_RESOLVE_FAILURE=1
assert_failure_contains 'invalid Git worktree' resolve_worktree feature-x
unset RUN_GIT_RESOLVE_FAILURE

assert_failure_contains 'branch does not exist' validate_existing_branch missing-branch
assert_failure_contains 'already checked out' validate_existing_branch feature-x
export RUN_GIT_ENUMERATION_FAILURE=1
assert_failure_contains 'unable to enumerate Git worktrees' \
    validate_existing_branch enumeration-failure
unset RUN_GIT_ENUMERATION_FAILURE
assert_eq "$state_before" "$(cat "$repo/.worktree-active")" \
    'branch validation does not change active state'

write_active_calls=0
write_active_worktree() {
    write_active_calls=$((write_active_calls + 1))
}
assert_status 1 validate_worktree missing
assert_status 1 validate_existing_branch missing-branch
assert_eq 0 "$write_active_calls" \
    'validation does not write active worktree state'

git -C "$repo" worktree add -q -b feature-y "$repo/.worktrees/feature-y"
printf 'APP_KEY=base64:feature-y\n' > "$repo/.worktrees/feature-y/.env"

busy_ports="$repo/busy-ports"
printf '%s\n' '#!/bin/bash' \
    'while IFS= read -r busy_port; do' \
    '    [ "$busy_port" = "$3" ] && exit 0' \
    'done < "${BUSY_PORTS:?}"' \
    'exit 1' > "$repo/bin/nc"
chmod +x "$repo/bin/nc"
export BUSY_PORTS="$busy_ports"
old_path=$PATH
PATH="$repo/bin:$PATH"
: > "$busy_ports"

state_dir="$repo/.worktrees/.state"
mkdir -p "$state_dir"

rm -f "$state_dir/feature-x.env"
assert_status 0 ensure_worktree_state feature-x "$repo/.worktrees/feature-x"
assert_status 0 load_worktree_state feature-x
assert_eq feature-x "$WORKTREE_NAME" 'state stores the Worktree name'
assert_eq test-project-feature-x "$WORKTREE_INSTANCE_NAME" \
    'state derives an isolated instance name'
assert_eq 8080 "$WORKTREE_PORT_HTTP" 'first group uses the configured HTTP port'
assert_eq 5173 "$WORKTREE_PORT_FRONTEND" 'first group uses the configured frontend port'
assert_eq 3306 "$WORKTREE_PORT_DATABASE" 'first group uses the configured database port'
assert_eq 6379 "$WORKTREE_PORT_CACHE" 'first group uses the configured cache port'
assert_contains "$state_dir/feature-x.env" \
    'WORKTREE_INSTANCE_NAME=test-project-feature-x'
assert_contains "$state_dir/feature-x.env" 'WORKTREE_PORT_HTTP=8080'
assert_contains "$state_dir/feature-x.env" 'WORKTREE_PORT_FRONTEND=5173'
assert_contains "$state_dir/feature-x.env" 'WORKTREE_PORT_DATABASE=3306'
assert_contains "$state_dir/feature-x.env" 'WORKTREE_PORT_CACHE=6379'
assert_not_contains "$state_dir/feature-x.env" 'COMPOSE_PROJECT_NAME='
assert_not_contains "$state_dir/feature-x.env" 'APP_PORT='
assert_not_contains "$state_dir/feature-x.env" 'VITE_PORT='
assert_not_contains "$state_dir/feature-x.env" 'FORWARD_DB_PORT='
assert_not_contains "$state_dir/feature-x.env" 'FORWARD_REDIS_PORT='

: > "$busy_ports"
assert_status 0 ensure_worktree_state stride-test "$repo/.worktrees/feature-x"
assert_status 0 load_worktree_state stride-test
assert_eq 8090 "$WORKTREE_PORT_HTTP" 'second group uses the configured HTTP stride'
assert_eq 5183 "$WORKTREE_PORT_FRONTEND" 'second group uses the configured frontend stride'
assert_eq 3316 "$WORKTREE_PORT_DATABASE" 'second group uses the configured database stride'
assert_eq 6389 "$WORKTREE_PORT_CACHE" 'second group uses the configured cache stride'
rm -f "$state_dir/stride-test.env"

rm -f "$repo/.worktrees/feature-y/.env"
printf '%s\n' 'APP_KEY=base64:from-template' 'UNTOUCHED_APPLICATION_VALUE=keep' \
    > "$repo/.worktrees/feature-y/.env.template"
printf '8090\n' > "$busy_ports"
assert_status 0 ensure_worktree_state feature-y "$repo/.worktrees/feature-y"
assert_status 0 load_worktree_state feature-y
assert_eq 8100 "$WORKTREE_PORT_HTTP" 'allocator skips a busy second HTTP group'
assert_eq 5193 "$WORKTREE_PORT_FRONTEND" 'allocator keeps the group offsets aligned'
assert_eq 3326 "$WORKTREE_PORT_DATABASE" 'allocator keeps the database group aligned'
assert_eq 6399 "$WORKTREE_PORT_CACHE" 'allocator keeps the cache group aligned'

assert_status 0 load_worktree_state feature-x
assert_eq 8080 "$WORKTREE_PORT_HTTP" 'state reuses the first group after another allocation'
assert_eq 5173 "$WORKTREE_PORT_FRONTEND" 'persisted state retains every profile port'
assert_contains "$repo/.worktrees/feature-y/.env" 'APP_KEY=base64:from-template'
assert_contains "$repo/.worktrees/feature-y/.env" 'UNTOUCHED_APPLICATION_VALUE=keep'
assert_not_contains "$repo/.worktrees/feature-y/.env" 'COMPOSE_PROJECT_NAME='
assert_not_contains "$repo/.worktrees/feature-y/.env" 'APP_PORT='
assert_not_contains "$repo/.worktrees/feature-y/.env" 'VITE_PORT='
assert_not_contains "$repo/.worktrees/feature-y/.env" 'FORWARD_DB_PORT='
assert_not_contains "$repo/.worktrees/feature-y/.env" 'FORWARD_REDIS_PORT='

# --- Port probe fallback without nc: bash /dev/tcp ---
if command -v python3 >/dev/null 2>&1; then
    probe_out="$repo/probe.out"
    python3 -c 'import socket, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
f = socket.socket(); f.bind(("127.0.0.1", 0))
print(s.getsockname()[1], f.getsockname()[1], flush=True)
time.sleep(30)' > "$probe_out" 2>/dev/null &
    probe_pid=$!
    for _ in 1 2 3 4 5; do
        [ -s "$probe_out" ] && break
        sleep 0.2
    done
    probe_busy=
    probe_free=
    IFS=' ' read -r probe_busy probe_free < "$probe_out" || true
    PATH="$old_path"
    if [ -n "$probe_busy" ] && [ -n "$probe_free" ]; then
        assert_status 1 port_is_available "$probe_busy"
        assert_status 0 port_is_available "$probe_free"
    else
        printf 'not ok - python3 probe did not bind its sockets\n' >&2
        failures=$((failures + 1))
    fi
    kill "$probe_pid" 2>/dev/null || true
    PATH="$repo/bin:$old_path"
fi

printf '%s\n' \
    'WORKTREE_NAME=cross-member' \
    'WORKTREE_INSTANCE_NAME=test-project-cross-member' \
    'WORKTREE_PORT_HTTP=9001' \
    'WORKTREE_PORT_FRONTEND=9002' \
    'WORKTREE_PORT_DATABASE=9003' \
    'WORKTREE_PORT_CACHE=9004' > "$state_dir/cross-member.env"
assert_status 1 worktree_state_port_available cross-candidate \
    9000 9001 9005 9006
rm -f "$state_dir/cross-member.env"

printf '%s\n' \
    'WORKTREE_NAME=leading-zero' \
    'WORKTREE_INSTANCE_NAME=test-project-leading-zero' \
    'WORKTREE_PORT_HTTP=09000' \
    'WORKTREE_PORT_FRONTEND=19001' \
    'WORKTREE_PORT_DATABASE=19002' \
    'WORKTREE_PORT_CACHE=19003' > "$state_dir/leading-zero.env"
assert_failure_contains 'decimal and valid' load_worktree_state leading-zero
rm -f "$state_dir/leading-zero.env"

custom_root=$(mktemp -d)
mkdir -p "$custom_root/.template" "$custom_root/.worktrees/custom" \
    "$custom_root/bin" "$custom_root/.worktrees/custom/bin"
printf '%s\n' \
    'PROJECT_NAME=custom-project' \
    'WORKTREE_PORT_PROFILE="web=9100,queue=9200"' \
    'WORKTREE_PORT_STRIDE=7' \
    'WORKTREE_ENV_TEMPLATE=.env.example' > "$custom_root/.template/project.conf"
printf 'CUSTOM_VALUE=preserve\n' > "$custom_root/.worktrees/custom/.env.example"
cp "$repo/bin/consumer" "$custom_root/bin/consumer"
chmod +x "$custom_root/bin/consumer"
cp "$repo/bin/consumer" "$custom_root/.worktrees/custom/bin/consumer"
chmod +x "$custom_root/.worktrees/custom/bin/consumer"
custom_run_log="$custom_root/consumer.log"
(
    export WORKTREE_TEST_ROOT="$custom_root"
    # shellcheck source=../../bin/worktree-lib.sh
    # shellcheck disable=SC1091
    source "$worktree_lib_script"
    unset APP_PORT VITE_PORT FORWARD_DB_PORT FORWARD_REDIS_PORT COMPOSE_PROJECT_NAME SAIL_BIN
    start_for_worktree custom "$custom_root/.worktrees/custom"
)
assert_contains "$custom_run_log" 'WORKTREE_INSTANCE_NAME=custom-project-custom'
assert_contains "$custom_run_log" 'WORKTREE_PORT_WEB=9100'
assert_contains "$custom_run_log" 'WORKTREE_PORT_QUEUE=9200'
assert_contains "$custom_run_log" \
    'SAIL_SET= COMPOSE_SET= APP_SET= VITE_SET= DB_SET= REDIS_SET='
assert_exists "$custom_root/.worktrees/custom/.env"
rm -rf "$custom_root"

custom_command_root=$(mktemp -d)
mkdir -p "$custom_command_root/.template" "$custom_command_root/.worktrees" \
    "$custom_command_root/bin"
printf '%s\n' \
    'PROJECT_NAME=custom-command' \
    'WORKTREE_PORT_PROFILE="web=9300,queue=9400"' \
    'WORKTREE_PORT_STRIDE=7' \
    'WORKTREE_ENV_TEMPLATE=.env.example' > "$custom_command_root/.template/project.conf"
printf 'README\n' > "$custom_command_root/README"
printf 'CUSTOM_VALUE=preserve\n' > "$custom_command_root/.env.example"
cp "$repo/bin/consumer" "$custom_command_root/bin/consumer"
chmod +x "$custom_command_root/bin/consumer"
git -C "$custom_command_root" init -q -b main
git -C "$custom_command_root" config user.email test@example.com
git -C "$custom_command_root" config user.name 'Worktree Test'
git -C "$custom_command_root" add README .env.example bin/consumer
git -C "$custom_command_root" commit -q -m initial
git -C "$custom_command_root" worktree add -q -b custom \
    "$custom_command_root/.worktrees/custom"
custom_command_log="$custom_command_root/consumer.log"
command_script=$(cd "$(dirname "$0")/../.." && pwd)/bin/worktree
env -u APP_PORT -u VITE_PORT -u FORWARD_DB_PORT -u FORWARD_REDIS_PORT \
    -u COMPOSE_PROJECT_NAME -u SAIL_BIN WORKTREE_TEST_ROOT="$custom_command_root" \
    "$command_script" start custom
assert_contains "$custom_command_log" 'WORKTREE_INSTANCE_NAME=custom-command-custom'
assert_contains "$custom_command_log" 'WORKTREE_PORT_WEB=9300'
assert_contains "$custom_command_log" 'WORKTREE_PORT_QUEUE=9400'
assert_contains "$custom_command_log" \
    'SAIL_SET= COMPOSE_SET= APP_SET= VITE_SET= DB_SET= REDIS_SET='
assert_not_contains "$custom_command_log" 'UNEXPECTED_ENV='
git -C "$custom_command_root" worktree remove -f "$custom_command_root/.worktrees/custom"
rm -rf "$custom_command_root"

: > "$consumer_log"
assert_status 98 env -i \
    PATH="$PATH" HOME="$HOME" \
    WORKTREE_NAME=feature-x \
    WORKTREE_PATH="$repo/.worktrees/feature-x" \
    WORKTREE_ROOT="$repo" \
    WORKTREE_STATE_FILE="$state_dir/feature-x.env" \
    WORKTREE_ENV_FILE="$repo/.worktrees/feature-x/.env" \
    WORKTREE_INSTANCE_NAME=test-project-feature-x \
    WORKTREE_PORT_HTTP=8080 \
    WORKTREE_PORT_FRONTEND=5173 \
    WORKTREE_PORT_DATABASE=3306 \
    WORKTREE_PORT_CACHE=6379 \
    WORKTREE_PORT_PROFILE=leaked \
    WORKTREE_PORT_EXTRA=leaked \
    "$repo/bin/consumer" start
: > "$consumer_log"
export WORKTREE_EXTRA=must-not-reach-consumer
assert_status 0 run_consumer_hook feature-x "$repo/.worktrees/feature-x" start
unset WORKTREE_EXTRA
assert_contains "$consumer_log" 'HOOK=start'
assert_contains "$consumer_log" "PWD=$repo/.worktrees/feature-x"
assert_contains "$consumer_log" 'WORKTREE_NAME=feature-x'
assert_contains "$consumer_log" 'WORKTREE_INSTANCE_NAME=test-project-feature-x'
assert_contains "$consumer_log" "WORKTREE_PATH=$repo/.worktrees/feature-x"
assert_contains "$consumer_log" "WORKTREE_ROOT=$repo"
assert_contains "$consumer_log" "WORKTREE_STATE_FILE=$repo/.worktrees/.state/feature-x.env"
assert_contains "$consumer_log" "WORKTREE_ENV_FILE=$repo/.worktrees/feature-x/.env"
assert_contains "$consumer_log" 'WORKTREE_PORT_HTTP=8080'
assert_contains "$consumer_log" 'WORKTREE_PORT_FRONTEND=5173'
assert_contains "$consumer_log" 'WORKTREE_PORT_DATABASE=3306'
assert_contains "$consumer_log" 'WORKTREE_PORT_CACHE=6379'
assert_contains "$consumer_log" \
    'SAIL_SET= COMPOSE_SET= APP_SET= VITE_SET= DB_SET= REDIS_SET='
assert_not_contains "$consumer_log" 'UNEXPECTED_ENV='
assert_exists "$consumer_state/test-project-feature-x"

git -C "$repo" worktree add -q -b no-consumer "$repo/.worktrees/no-consumer"
printf 'APP_KEY=base64:no-consumer\n' > "$repo/.worktrees/no-consumer/.env"
rm -rf "$repo/.worktrees/no-consumer/bin"
assert_status 0 ensure_worktree_state no-consumer "$repo/.worktrees/no-consumer"
: > "$consumer_log"
assert_failure_contains 'no-consumer' \
    run_consumer_hook no-consumer "$repo/.worktrees/no-consumer" start
assert_failure_contains 'docs/runtime-hooks.md' \
    run_consumer_hook no-consumer "$repo/.worktrees/no-consumer" start
assert_not_contains "$consumer_log" 'HOOK=start'
git -C "$repo" worktree remove -f "$repo/.worktrees/no-consumer"
rm -f "$state_dir/no-consumer.env"

: > "$consumer_log"
touch "$repo/.consumer-fail-start"
assert_status 1 run_consumer_hook feature-x "$repo/.worktrees/feature-x" start
rm -f "$repo/.consumer-fail-start"
assert_contains "$consumer_log" 'HOOK=start'

: > "$consumer_log"
assert_status 0 bootstrap_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_contains "$consumer_log" 'HOOK=bootstrap'

: > "$consumer_log"
assert_status 0 run_consumer_hook feature-x "$repo/.worktrees/feature-x" reset
assert_contains "$consumer_log" 'HOOK=reset'

: > "$consumer_log"
touch "$repo/.consumer-no-reset"
assert_status 2 run_consumer_hook feature-x "$repo/.worktrees/feature-x" reset
rm -f "$repo/.consumer-no-reset"
assert_contains "$consumer_log" 'HOOK=reset'
assert_contains "$consumer_log" 'reset not supported'

: > "$consumer_log"
assert_status 0 run_consumer_hook feature-x "$repo/.worktrees/feature-x" status
assert_contains "$consumer_log" 'HOOK=status'
assert_output_contains 'status: running' \
    run_consumer_hook feature-x "$repo/.worktrees/feature-x" status

: > "$consumer_log"
assert_status 0 run_consumer_hook feature-x "$repo/.worktrees/feature-x" stop
assert_not_exists "$consumer_state/test-project-feature-x"

: > "$consumer_log"
assert_status 0 start_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_status 0 start_for_worktree feature-y "$repo/.worktrees/feature-y"
assert_contains "$consumer_log" 'WORKTREE_INSTANCE_NAME=test-project-feature-x'
assert_contains "$consumer_log" 'WORKTREE_INSTANCE_NAME=test-project-feature-y'
: > "$consumer_log"
assert_status 0 stop_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_not_exists "$consumer_state/test-project-feature-x"
if [ -f "$consumer_state/test-project-feature-y" ]; then
    printf 'ok - stopping feature-x keeps feature-y running\n'
else
    printf 'not ok - stopping feature-x removed feature-y\n'
    failures=$((failures + 1))
fi

git -C "$repo" worktree add -q -b malformed-state "$repo/.worktrees/malformed-state"
printf 'APP_KEY=base64:malformed-state\n' > "$repo/.worktrees/malformed-state/.env"
printf '%s\n' \
    'WORKTREE_NAME=malformed-state' \
    'WORKTREE_INSTANCE_NAME=test-project-malformed-state' \
    'WORKTREE_PORT_HTTP=8080' \
    'WORKTREE_PORT_FRONTEND=5173' \
    'WORKTREE_PORT_DATABASE=3306' \
    'WORKTREE_PORT_CACHE=6379' \
    'UNEXPECTED=reject-me' > "$state_dir/malformed-state.env"
: > "$consumer_log"
assert_failure_contains 'invalid worktree state' \
    start_for_worktree malformed-state "$repo/.worktrees/malformed-state"
assert_not_contains "$consumer_log" 'HOOK=start'
git -C "$repo" worktree remove -f "$repo/.worktrees/malformed-state"
rm -f "$state_dir/malformed-state.env"

printf '%s\n' \
    'WORKTREE_NAME=duplicate-state' \
    'WORKTREE_INSTANCE_NAME=test-project-duplicate-state' \
    'WORKTREE_PORT_HTTP=8080' \
    'WORKTREE_PORT_HTTP=8090' \
    'WORKTREE_PORT_FRONTEND=5173' \
    'WORKTREE_PORT_DATABASE=3306' \
    'WORKTREE_PORT_CACHE=6379' > "$state_dir/duplicate-state.env"
assert_failure_contains 'duplicate key WORKTREE_PORT_HTTP' \
    load_worktree_state duplicate-state
rm -f "$state_dir/duplicate-state.env"

PROJECT_NAME=Bad.Name
assert_failure_contains 'invalid worktree instance name' \
    ensure_worktree_state bad-project "$repo/.worktrees/feature-x"
# shellcheck disable=SC2034 # read by ensure_worktree_state and worktree-lib.sh functions during later assertions
PROJECT_NAME=test-project
assert_not_exists "$repo/.worktrees/.state/bad-project.env"
assert_not_exists "$state_dir/.allocation-lock"

git -C "$repo" worktree add -q -b lock-test "$repo/.worktrees/lock-test"
printf 'APP_KEY=base64:lock-test\n' > "$repo/.worktrees/lock-test/.env"
rm -f "$repo/.worktrees/lock-test/.env" "$repo/.worktrees/lock-test/.env.template"
lock_dir="$state_dir/.allocation-lock"
mkdir -p "$lock_dir"
printf '%s\n' "$$" > "$lock_dir/pid"
assert_failure_contains 'Port allocation is already running' \
    ensure_worktree_state lock-test "$repo/.worktrees/lock-test"
assert_contains "$lock_dir/pid" "$$"

printf '%s\n' 99999999 > "$lock_dir/pid"
assert_status 0 ensure_worktree_state lock-test "$repo/.worktrees/lock-test"
assert_not_exists "$lock_dir"
assert_not_exists "$repo/.worktrees/lock-test/.env"
rm -f "$state_dir/lock-test.env"
git -C "$repo" worktree remove -f "$repo/.worktrees/lock-test"

git -C "$repo" worktree add -q -b busy-8080 "$repo/.worktrees/busy-8080"
printf 'APP_KEY=base64:busy-8080\n' > "$repo/.worktrees/busy-8080/.env"
printf '8080\n' > "$busy_ports"
assert_status 0 ensure_worktree_state busy-8080 "$repo/.worktrees/busy-8080"
assert_status 0 load_worktree_state busy-8080
assert_eq 8090 "$WORKTREE_PORT_HTTP" 'a busy 8080 selects the next complete HTTP group'
assert_eq 5183 "$WORKTREE_PORT_FRONTEND" 'a busy 8080 keeps the frontend offset within the group'
assert_eq 3316 "$WORKTREE_PORT_DATABASE" 'a busy 8080 keeps the database offset within the group'
assert_eq 6389 "$WORKTREE_PORT_CACHE" 'a busy 8080 keeps the cache offset within the group'
git -C "$repo" worktree remove -f "$repo/.worktrees/busy-8080"
rm -f "$state_dir/busy-8080.env"

git -C "$repo" worktree add -q -b no-state-start "$repo/.worktrees/no-state-start"
printf 'APP_KEY=base64:no-state-start\n' > "$repo/.worktrees/no-state-start/.env"
: > "$consumer_log"
: > "$busy_ports"
assert_status 0 start_for_worktree no-state-start "$repo/.worktrees/no-state-start"
assert_contains "$consumer_log" 'HOOK=start'
assert_contains "$consumer_log" 'WORKTREE_INSTANCE_NAME=test-project-no-state-start'
assert_contains "$consumer_log" 'WORKTREE_PORT_HTTP=8090'
assert_contains "$consumer_log" 'WORKTREE_PORT_FRONTEND=5183'
assert_contains "$consumer_log" 'WORKTREE_PORT_DATABASE=3316'
assert_contains "$consumer_log" 'WORKTREE_PORT_CACHE=6389'
git -C "$repo" worktree remove -f "$repo/.worktrees/no-state-start"
rm -f "$state_dir/no-state-start.env"

PATH=$old_path

: > "$busy_ports"
PATH="$repo/bin:$old_path"

run_command() {
    WORKTREE_TEST_ROOT="$repo" "$command_script" "$@"
}

printf '%s\n' \
    'PROJECT_NAME=test-project' \
    'WORKTREE_PORT_PROFILE="http=8080,frontend=5173,database=3306,cache=6379"' \
    'WORKTREE_PORT_STRIDE=10' \
    'WORKTREE_ENV_TEMPLATE=.env.example' > "$repo/.template/project.conf"
: > "$consumer_log"
assert_status 0 run_command create example-create
assert_exists "$repo/.worktrees/example-create/.env"
assert_contains "$repo/.worktrees/example-create/.env" 'APP_KEY=base64:from-example'
assert_contains "$consumer_log" 'HOOK=bootstrap'
git -C "$repo" worktree remove -f "$repo/.worktrees/example-create"
rm -f "$repo/.worktrees/.state/example-create.env"

git -C "$repo" worktree add -q -b example-bootstrap "$repo/.worktrees/example-bootstrap"
rm -f "$repo/.worktrees/example-bootstrap/.env"
: > "$consumer_log"
assert_status 0 run_command bootstrap example-bootstrap
assert_exists "$repo/.worktrees/example-bootstrap/.env"
assert_contains "$repo/.worktrees/example-bootstrap/.env" 'APP_KEY=base64:from-example'
assert_contains "$consumer_log" 'HOOK=bootstrap'
git -C "$repo" worktree remove -f "$repo/.worktrees/example-bootstrap"
rm -f "$repo/.worktrees/.state/example-bootstrap.env"

git -C "$repo" worktree add -q -b example-start "$repo/.worktrees/example-start"
rm -f "$repo/.worktrees/example-start/.env"
: > "$consumer_log"
assert_status 0 run_command start example-start
assert_exists "$repo/.worktrees/example-start/.env"
assert_contains "$repo/.worktrees/example-start/.env" 'APP_KEY=base64:from-example'
assert_contains "$consumer_log" 'HOOK=start'
git -C "$repo" worktree remove -f "$repo/.worktrees/example-start"
rm -f "$repo/.worktrees/.state/example-start.env"

printf '%s\n' \
    'PROJECT_NAME=test-project' \
    'WORKTREE_PORT_PROFILE="http=8080,frontend=5173,database=3306,cache=6379"' \
    'WORKTREE_PORT_STRIDE=10' \
    'WORKTREE_ENV_TEMPLATE=.env.template' > "$repo/.template/project.conf"

rm -rf "$repo/.worktree-active" "$consumer_state" "$consumer_log"
printf '%s\n' feature-x > "$repo/.worktree-active"
mkdir -p "$consumer_state"
: > "$consumer_log"
expected_status=$(printf 'active: feature-x\npath: %s/.worktrees/feature-x\nbranch: feature-x\ninstance: test-project-feature-x\nports: HTTP=8080 FRONTEND=5173 DATABASE=3306 CACHE=6379\nstatus: stopped' "$repo")
assert_eq "$expected_status" "$(run_command status)" \
    'status prints instance, ports, and consumer stopped output'
touch "$consumer_state/test-project-feature-x"
expected_running_status=$(printf 'active: feature-x\npath: %s/.worktrees/feature-x\nbranch: feature-x\ninstance: test-project-feature-x\nports: HTTP=8080 FRONTEND=5173 DATABASE=3306 CACHE=6379\nstatus: running' "$repo")
assert_eq "$expected_running_status" "$(run_command status)" \
    'status prints instance, ports, and consumer running output'
rm -f "$consumer_state/test-project-feature-x"

rm -f "$consumer_log"
assert_status 0 run_command start feature-x
assert_contains "$consumer_log" 'HOOK=start'
assert_contains "$consumer_log" 'WORKTREE_NAME=feature-x'
assert_eq feature-x "$(cat "$repo/.worktree-active")" \
    'start preserves active worktree after startup'

rm -f "$consumer_log"
assert_status 0 run_command start feature-x --fresh
assert_contains "$consumer_log" 'HOOK=start'
assert_contains "$consumer_log" 'HOOK=reset'

rm -f "$consumer_log"
assert_status 0 run_command stop feature-x
assert_contains "$consumer_log" 'HOOK=stop'
assert_not_exists "$consumer_state/test-project-feature-x"
assert_eq "$expected_status" "$(run_command status)" 'status reports a stopped stack'

rm -f "$consumer_log"
assert_failure_contains 'worktree not found' run_command switch missing
assert_not_contains "$consumer_log" 'HOOK=stop'
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'failed target validation preserves active worktree'

rm -rf "$consumer_state"
mkdir -p "$consumer_state"
touch "$consumer_state/test-project-feature-x"
touch "$repo/.consumer-fail-start"
assert_failure_contains 'feature-y' run_command switch feature-y
rm -f "$repo/.consumer-fail-start"
assert_contains "$consumer_log" 'HOOK=start'
assert_contains "$consumer_log" 'WORKTREE_NAME=feature-y'
assert_not_contains "$consumer_log" 'HOOK=stop'
assert_exists "$consumer_state/test-project-feature-x"
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'failed target startup preserves active worktree'

rm -rf "$consumer_state"
mkdir -p "$consumer_state"
touch "$consumer_state/test-project-feature-x"
: > "$consumer_log"
assert_status 0 run_command switch feature-y
assert_eq feature-y "$(cat "$repo/.worktree-active")" \
    'successful switch writes target active worktree'
if ! grep -q 'HOOK=stop' "$consumer_log"; then
    printf 'ok - switch keeps the previous stack running\n'
else
    printf 'not ok - switch stopped the previous stack\n'
    failures=$((failures + 1))
fi
assert_exists "$consumer_state/test-project-feature-x"
assert_exists "$consumer_state/test-project-feature-y"

rm -f "$consumer_log"
assert_status 0 run_command reset feature-y
assert_contains "$consumer_log" 'HOOK=reset'

rm -f "$consumer_log"
assert_status 0 run_command reset
assert_contains "$consumer_log" 'HOOK=reset'

rm -f "$consumer_log"
touch "$repo/.consumer-no-reset"
if output=$(run_command reset feature-y 2>&1); then
    reset_exit=0
else
    reset_exit=$?
fi
rm -f "$repo/.consumer-no-reset"
assert_eq 2 "$reset_exit" 'unsupported reset hook exits 2'
assert_contains "$consumer_log" 'HOOK=reset'
case "$output" in
    *'docs/runtime-hooks.md'*)
        printf 'ok - unsupported reset diagnostic points to the hook contract\n' ;;
    *)
        printf 'not ok - unsupported reset diagnostic missing contract\n'
        failures=$((failures + 1))
        ;;
esac

touch "$repo/.consumer-no-reset"
if output=$(run_command start feature-y --fresh 2>&1); then
    reset_exit=0
else
    reset_exit=$?
fi
assert_eq 2 "$reset_exit" 'start --fresh preserves unsupported reset exit 2'
case "$output" in
    *'docs/runtime-hooks.md'*)
        printf 'ok - start --fresh unsupported reset diagnostic points to the hook contract\n' ;;
    *)
        printf 'not ok - start --fresh unsupported reset diagnostic missing contract\n'
        failures=$((failures + 1))
        ;;
esac

if output=$(run_command switch feature-x --fresh 2>&1); then
    reset_exit=0
else
    reset_exit=$?
fi
rm -f "$repo/.consumer-no-reset"
assert_eq 2 "$reset_exit" 'switch --fresh preserves unsupported reset exit 2'
case "$output" in
    *'docs/runtime-hooks.md'*)
        printf 'ok - switch --fresh unsupported reset diagnostic points to the hook contract\n' ;;
    *)
        printf 'not ok - switch --fresh unsupported reset diagnostic missing contract\n'
        failures=$((failures + 1))
        ;;
esac

rm -rf "$repo/.worktree-active" "$consumer_state"
mkdir -p "$consumer_state"
printf '%s\n' feature-x > "$repo/.worktree-active"
touch "$consumer_state/test-project-feature-y"
printf '8080\n' > "$busy_ports"
: > "$consumer_log"
assert_status 0 run_command switch feature-y
assert_not_contains "$consumer_log" 'HOOK=stop'
assert_eq feature-y "$(<"$repo/.worktree-active")" \
    'switch starts target without active state'
: > "$busy_ports"

printf '%s\n' '../invalid' > "$repo/.worktree-active"
rm -f "$consumer_log"
mkdir -p "$consumer_state"
touch "$consumer_state/test-project-feature-y"
assert_status 0 run_command switch feature-y
assert_not_contains "$consumer_log" 'HOOK=stop'
assert_eq feature-y "$(<"$repo/.worktree-active")" \
    'switch ignores stale active pointer for explicit target'

printf '%s\n' removed-worktree > "$repo/.worktree-active"
assert_failure_contains 'stale active worktree' run_command status
assert_status 0 run_command status feature-y

git -C "$repo" worktree add -q -b a-status-fail "$repo/.worktrees/a-status-fail"
printf 'APP_KEY=base64:status-fail\n' > "$repo/.worktrees/a-status-fail/.env"
assert_status 0 ensure_worktree_state a-status-fail "$repo/.worktrees/a-status-fail"
cat > "$repo/.worktrees/a-status-fail/bin/consumer" <<'STATUS_FAIL_EOF'
#!/bin/bash
set -euo pipefail
printf 'consumer status failed\n' >&2
exit 1
STATUS_FAIL_EOF
chmod +x "$repo/.worktrees/a-status-fail/bin/consumer"
assert_output_contains 'active: feature-x' run_command status --all
assert_output_contains 'active: feature-y' run_command status --all
assert_output_contains 'active: a-status-fail' run_command status --all
assert_output_contains 'consumer status failed' run_command status --all
assert_status 1 run_command status a-status-fail
git -C "$repo" worktree remove -f "$repo/.worktrees/a-status-fail"
rm -f "$state_dir/a-status-fail.env"

git -C "$repo" worktree add -q -b block-target "$repo/.worktrees/block-target"
printf 'APP_KEY=base64:block-target\n' > "$repo/.worktrees/block-target/.env"
printf '%s\n' 'junk' > "$state_dir/bad name.env"
assert_failure_contains 'bad name.env' \
    ensure_worktree_state block-target "$repo/.worktrees/block-target"
rm -f "$state_dir/bad name.env"
git -C "$repo" worktree remove -f "$repo/.worktrees/block-target"
rm -f "$state_dir/block-target.env"

mkdir -p "$repo/.worktrees/.state"
printf '%s\n' \
    'WORKTREE_NAME=orphan' \
    'WORKTREE_INSTANCE_NAME=test-project-orphan' \
    'WORKTREE_PORT_HTTP=8120' \
    'WORKTREE_PORT_FRONTEND=5213' \
    'WORKTREE_PORT_DATABASE=3346' \
    'WORKTREE_PORT_CACHE=6419' \
    > "$repo/.worktrees/.state/orphan.env"
assert_output_contains 'orphan' run_command status --all
assert_status 0 run_command prune
assert_not_exists "$repo/.worktrees/.state/orphan.env"

git -C "$repo" worktree add -q -b registered-orphan "$repo/.worktrees/registered-orphan"
printf '%s\n' \
    'WORKTREE_NAME=registered-orphan' \
    'WORKTREE_INSTANCE_NAME=test-project-registered-orphan' \
    'WORKTREE_PORT_HTTP=8130' \
    'WORKTREE_PORT_FRONTEND=5223' \
    'WORKTREE_PORT_DATABASE=3356' \
    'WORKTREE_PORT_CACHE=6429' \
    > "$repo/.worktrees/.state/registered-orphan.env"
rm -rf "$repo/.worktrees/registered-orphan"
assert_status 0 run_command prune
if [ -f "$repo/.worktrees/.state/registered-orphan.env" ]; then
    printf 'ok - prune preserves state still listed by Git\n'
else
    printf 'not ok - prune removed state still listed by Git\n'
    failures=$((failures + 1))
fi
git -C "$repo" worktree prune
rm -f "$repo/.worktrees/.state/registered-orphan.env"

assert_failure_contains 'Usage:' run_command create feature-z --fresh
assert_failure_contains 'Usage:' run_command status feature-y --all
assert_failure_contains 'Usage:' run_command reset feature-y --fresh

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures"
    exit 1
fi

printf 'all tests passed\n'
