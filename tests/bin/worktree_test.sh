#!/bin/bash

set -euo pipefail

repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT

mkdir -p "$repo/.worktrees"
mkdir -p "$repo/.template"
printf 'PROJECT_NAME=test-project\n' > "$repo/.template/project.conf"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name 'Worktree Test'
touch "$repo/README"
printf 'APP_KEY=\n' > "$repo/.env.template"
printf 'services: {}\n' > "$repo/compose.yaml"
git -C "$repo" add README
git -C "$repo" add .env.template
git -C "$repo" add compose.yaml
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

assert_not_executable() {
    local path=$1
    if [ -x "$path" ]; then
        printf 'not ok - %s is executable unexpectedly\n' "$path"
        failures=$((failures + 1))
    else
        printf 'ok - %s is not executable\n' "$path"
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

mkdir -p "$repo/vendor/bin" "$repo/vendor/laravel/sail/runtimes/8.5" \
    "$repo/vendor/laravel/sail/database/mysql" \
    "$repo/.worktrees/feature-x/vendor/bin"
touch "$repo/vendor/bin/sail"
touch "$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh"
chmod +x "$repo/vendor/bin/sail"
touch "$repo/.worktrees/feature-x/vendor/bin/sail"
chmod +x "$repo/.worktrees/feature-x/vendor/bin/sail"
MOCK_SAIL_LOG="$repo/sail.log"
stack_state_dir="$repo/stack-running"
mkdir -p "$stack_state_dir"
export STACK_STATE_DIR="$stack_state_dir"
run_sail_calls_log="$repo/run-sail-calls"
: > "$run_sail_calls_log"
run_sail() {
    printf 'x\n' >> "$run_sail_calls_log"
    printf 'PWD=%s COMPOSE_PROJECT_NAME=%s SAIL_SOURCE_PATH=%s SAIL_BIN=%s SAIL_BUILD_CONTEXT=%s SAIL_BUILD_DOCKERFILE=%s SAIL_MYSQL_INIT_SCRIPT=%s ARGS=%s PROJECT=%s APP=%s VITE=%s DB=%s REDIS=%s\n' \
        "$PWD" "${COMPOSE_PROJECT_NAME:-}" "${SAIL_SOURCE_PATH:-}" \
        "${SAIL_BIN:-}" "${SAIL_BUILD_CONTEXT:-}" "${SAIL_BUILD_DOCKERFILE:-}" \
        "${SAIL_MYSQL_INIT_SCRIPT:-}" "$*" "${COMPOSE_PROJECT_NAME:-}" \
        "${APP_PORT:-}" "${VITE_PORT:-}" "${FORWARD_DB_PORT:-}" \
        "${FORWARD_REDIS_PORT:-}" >> "$MOCK_SAIL_LOG"
    case "$*" in
        'ps -q laravel.test')
            if [ -f "${STACK_STATE_DIR:?}/${COMPOSE_PROJECT_NAME:?}" ]; then
                printf 'app-container-%s\n' "${COMPOSE_PROJECT_NAME:?}"
            fi
            ;;
        'up -d --remove-orphans')
            touch "${STACK_STATE_DIR:?}/${COMPOSE_PROJECT_NAME:?}"
            ;;
        'down --remove-orphans')
            rm -f "${STACK_STATE_DIR:?}/${COMPOSE_PROJECT_NAME:?}"
            ;;
    esac
}

mkdir -p "$repo/bin"
git -C "$repo" worktree add -q -b feature-y "$repo/.worktrees/feature-y"
printf 'APP_KEY=base64:feature-y\n' > "$repo/.worktrees/feature-y/.env"
cp "$repo/compose.yaml" "$repo/.worktrees/feature-y/compose.yaml"

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
assert_eq feature-x "$WORKTREE_STATE_NAME" 'state stores the Worktree name'
assert_eq test-project-feature-x "$WORKTREE_STATE_COMPOSE_PROJECT_NAME" \
    'state derives an isolated Compose project name'
assert_eq 8080 "$WORKTREE_STATE_APP_PORT" 'first group uses the canonical HTTP port'
assert_eq 5173 "$WORKTREE_STATE_VITE_PORT" 'first group uses the Vite offset'
assert_eq 3306 "$WORKTREE_STATE_DB_PORT" 'first group uses the database offset'
assert_eq 6379 "$WORKTREE_STATE_REDIS_PORT" 'first group uses the Redis offset'
assert_contains "$state_dir/feature-x.env" \
    'COMPOSE_PROJECT_NAME=test-project-feature-x'

printf '8090\n' > "$busy_ports"
assert_status 0 ensure_worktree_state feature-y "$repo/.worktrees/feature-y"
assert_status 0 load_worktree_state feature-y
assert_eq 8100 "$WORKTREE_STATE_APP_PORT" 'allocator skips a busy second HTTP group'
assert_eq 5193 "$WORKTREE_STATE_VITE_PORT" 'allocator keeps the group offsets aligned'
assert_eq 3326 "$WORKTREE_STATE_DB_PORT" 'allocator keeps the database group aligned'
assert_eq 6399 "$WORKTREE_STATE_REDIS_PORT" 'allocator keeps the Redis group aligned'

assert_status 0 load_worktree_state feature-x
assert_eq 8080 "$WORKTREE_STATE_APP_PORT" 'state reuses the first group after another allocation'

: > "$MOCK_SAIL_LOG"
touch "$stack_state_dir/test-project-feature-x"
assert_status 0 stack_is_running_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_eq 1 "$(wc -l < "$run_sail_calls_log")" 'stack status uses the Sail command seam'
assert_contains "$MOCK_SAIL_LOG" 'COMPOSE_PROJECT_NAME=test-project-feature-x'
assert_contains "$MOCK_SAIL_LOG" 'PROJECT=test-project-feature-x APP=8080 VITE=5173 DB=3306 REDIS=6379'
assert_contains "$MOCK_SAIL_LOG" 'ARGS=ps -q laravel.test'
rm -f "$stack_state_dir/test-project-feature-x"

: > "$MOCK_SAIL_LOG"
assert_status 0 start_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_status 0 start_for_worktree feature-y "$repo/.worktrees/feature-y"
assert_contains "$MOCK_SAIL_LOG" 'PROJECT=test-project-feature-x APP=8080 VITE=5173 DB=3306 REDIS=6379'
assert_contains "$MOCK_SAIL_LOG" 'PROJECT=test-project-feature-y APP=8100 VITE=5193 DB=3326 REDIS=6399'

assert_status 0 stop_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_not_exists "$stack_state_dir/test-project-feature-x"
if [ -f "$stack_state_dir/test-project-feature-y" ]; then
    printf 'ok - stopping feature-x keeps feature-y running\n'
else
    printf 'not ok - stopping feature-x removed feature-y\n'
    failures=$((failures + 1))
fi

printf '8080\n' > "$busy_ports"
assert_status 0 start_for_worktree feature-x "$repo/.worktrees/feature-x"
: > "$busy_ports"

git -C "$repo" worktree add -q -b malformed-state "$repo/.worktrees/malformed-state"
printf 'APP_KEY=base64:malformed-state\n' > "$repo/.worktrees/malformed-state/.env"
cp "$repo/compose.yaml" "$repo/.worktrees/malformed-state/compose.yaml"
printf '%s\n' \
    'WORKTREE_NAME=malformed-state' \
    'COMPOSE_PROJECT_NAME=test-project-malformed-state' \
    'APP_PORT=8080' \
    'VITE_PORT=5173' \
    'FORWARD_DB_PORT=3306' \
    'FORWARD_REDIS_PORT=6379' \
    'UNEXPECTED=reject-me' > "$state_dir/malformed-state.env"
: > "$MOCK_SAIL_LOG"
assert_failure_contains 'ungültiger Worktree-Zustand' \
    start_for_worktree malformed-state "$repo/.worktrees/malformed-state"
assert_not_contains "$MOCK_SAIL_LOG" 'ARGS=up -d --remove-orphans'
git -C "$repo" worktree remove -f "$repo/.worktrees/malformed-state"
rm -f "$state_dir/malformed-state.env"

PROJECT_NAME=Bad.Name
assert_failure_contains 'ungültiger Compose-Projektname' \
    ensure_worktree_state bad-project "$repo/.worktrees/feature-x"
PROJECT_NAME=test-project
assert_not_exists "$repo/.worktrees/.state/bad-project.env"
assert_not_exists "$state_dir/.allocation-lock"

git -C "$repo" worktree add -q -b lock-test "$repo/.worktrees/lock-test"
printf 'APP_KEY=base64:lock-test\n' > "$repo/.worktrees/lock-test/.env"
cp "$repo/compose.yaml" "$repo/.worktrees/lock-test/compose.yaml"
lock_dir="$state_dir/.allocation-lock"
mkdir -p "$lock_dir"
printf '%s\n' "$$" > "$lock_dir/pid"
assert_failure_contains 'Portzuweisung läuft bereits' \
    ensure_worktree_state lock-test "$repo/.worktrees/lock-test"
assert_contains "$lock_dir/pid" "$$"

printf '%s\n' 99999999 > "$lock_dir/pid"
assert_status 0 ensure_worktree_state lock-test "$repo/.worktrees/lock-test"
assert_not_exists "$lock_dir"
rm -f "$state_dir/lock-test.env"
git -C "$repo" worktree remove -f "$repo/.worktrees/lock-test"

git -C "$repo" worktree add -q -b busy-8080 "$repo/.worktrees/busy-8080"
printf 'APP_KEY=base64:busy-8080\n' > "$repo/.worktrees/busy-8080/.env"
cp "$repo/compose.yaml" "$repo/.worktrees/busy-8080/compose.yaml"
printf '8080\n' > "$busy_ports"
assert_status 0 ensure_worktree_state busy-8080 "$repo/.worktrees/busy-8080"
assert_status 0 load_worktree_state busy-8080
assert_eq 8090 "$WORKTREE_STATE_APP_PORT" 'a busy 8080 selects the next complete HTTP group'
assert_eq 5183 "$WORKTREE_STATE_VITE_PORT" 'a busy 8080 keeps the Vite offset within the group'
assert_eq 3316 "$WORKTREE_STATE_DB_PORT" 'a busy 8080 keeps the database offset within the group'
assert_eq 6389 "$WORKTREE_STATE_REDIS_PORT" 'a busy 8080 keeps the Redis offset within the group'
git -C "$repo" worktree remove -f "$repo/.worktrees/busy-8080"
rm -f "$state_dir/busy-8080.env"

git -C "$repo" worktree add -q -b no-state-start "$repo/.worktrees/no-state-start"
printf 'APP_KEY=base64:no-state-start\n' > "$repo/.worktrees/no-state-start/.env"
cp "$repo/compose.yaml" "$repo/.worktrees/no-state-start/compose.yaml"
: > "$MOCK_SAIL_LOG"
: > "$busy_ports"
assert_status 0 start_for_worktree no-state-start "$repo/.worktrees/no-state-start"
assert_contains "$MOCK_SAIL_LOG" 'COMPOSE_PROJECT_NAME=test-project-no-state-start'
assert_contains "$MOCK_SAIL_LOG" 'PROJECT=test-project-no-state-start APP=8090 VITE=5183 DB=3316 REDIS=6389'
assert_contains "$MOCK_SAIL_LOG" "SAIL_SOURCE_PATH=$repo/.worktrees/no-state-start"
assert_contains "$MOCK_SAIL_LOG" 'ARGS=up -d --remove-orphans'
git -C "$repo" worktree remove -f "$repo/.worktrees/no-state-start"
rm -f "$state_dir/no-state-start.env"

: > "$MOCK_SAIL_LOG"
assert_status 0 start_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_contains "$MOCK_SAIL_LOG" 'ARGS=up -d --remove-orphans'
assert_contains "$MOCK_SAIL_LOG" "SAIL_SOURCE_PATH=$repo/.worktrees/feature-x"
assert_contains "$MOCK_SAIL_LOG" "SAIL_BIN=$repo/vendor/bin/sail"
assert_contains "$MOCK_SAIL_LOG" "SAIL_MYSQL_INIT_SCRIPT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh"
assert_contains "$MOCK_SAIL_LOG" "SAIL_BUILD_CONTEXT=$repo/vendor/laravel/sail/runtimes/8.5"
assert_contains "$MOCK_SAIL_LOG" 'SAIL_BUILD_DOCKERFILE=Dockerfile'
assert_not_contains "$MOCK_SAIL_LOG" 'migrate:fresh'

mkdir -p "$repo/.worktrees/feature-x/vendor/laravel/sail"
: > "$MOCK_SAIL_LOG"
assert_status 0 start_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_contains "$MOCK_SAIL_LOG" "SAIL_BIN=$repo/.worktrees/feature-x/vendor/bin/sail"
assert_contains "$MOCK_SAIL_LOG" "SAIL_SOURCE_PATH=$repo/.worktrees/feature-x"
assert_contains "$MOCK_SAIL_LOG" 'SAIL_BUILD_CONTEXT= SAIL_BUILD_DOCKERFILE= SAIL_MYSQL_INIT_SCRIPT='

: > "$MOCK_SAIL_LOG"
assert_status 0 stop_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_contains "$MOCK_SAIL_LOG" 'ARGS=down --remove-orphans'
assert_not_contains "$MOCK_SAIL_LOG" '--volumes'

export SAIL_BUILD_CONTEXT=/foreign/context
export SAIL_BUILD_DOCKERFILE=/foreign/Dockerfile
export SAIL_MYSQL_INIT_SCRIPT=/foreign/init.sh
: > "$MOCK_SAIL_LOG"
assert_status 0 stop_stack feature-x "$repo/.worktrees/feature-x" "$repo/.worktrees/feature-x/vendor/bin/sail" ''
assert_contains "$MOCK_SAIL_LOG" 'SAIL_BUILD_CONTEXT= SAIL_BUILD_DOCKERFILE= SAIL_MYSQL_INIT_SCRIPT='

rm -rf "$repo/.worktrees/feature-x/vendor/laravel/sail"
: > "$MOCK_SAIL_LOG"
assert_status 0 stop_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_contains "$MOCK_SAIL_LOG" "SAIL_BIN=$repo/vendor/bin/sail"
assert_contains "$MOCK_SAIL_LOG" "SAIL_MYSQL_INIT_SCRIPT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh"

: > "$MOCK_SAIL_LOG"
printf 'y\n' | assert_status 0 run_fresh feature-x "$repo/.worktrees/feature-x"
assert_contains "$MOCK_SAIL_LOG" 'ARGS=artisan migrate:fresh --seed'
assert_contains "$MOCK_SAIL_LOG" 'SAIL_BUILD_CONTEXT= SAIL_BUILD_DOCKERFILE= SAIL_MYSQL_INIT_SCRIPT='

PATH=$old_path

command_script=$(cd "$(dirname "$0")/../.." && pwd)/bin/worktree
command_log="$repo/command.log"
stack_state="$repo/stack-running"
mkdir -p "$stack_state"
cat > "$repo/vendor/bin/sail" <<'EOF'
#!/bin/bash

state_marker="${STACK_STATE_DIR:?}/${COMPOSE_PROJECT_NAME:?}"

printf 'PWD=%s SOURCE=%s BIN=%s BUILD_CONTEXT=%s BUILD_DOCKERFILE=%s MYSQL_INIT=%s ARGS=%s PROJECT=%s APP=%s VITE=%s DB=%s REDIS=%s\n' \
    "$PWD" "${SAIL_SOURCE_PATH:-}" "${SAIL_BIN:-}" "${SAIL_BUILD_CONTEXT:-}" \
    "${SAIL_BUILD_DOCKERFILE:-}" "${SAIL_MYSQL_INIT_SCRIPT:-}" "$*" "${COMPOSE_PROJECT_NAME:-}" \
    "${APP_PORT:-}" "${VITE_PORT:-}" "${FORWARD_DB_PORT:-}" \
    "${FORWARD_REDIS_PORT:-}" >> "${COMMAND_LOG:?}"
case "$*" in
    'ps -q laravel.test')
        if [ -f "$state_marker" ]; then
            printf 'container-%s\n' "${COMPOSE_PROJECT_NAME:?}"
        fi
        ;;
    'up -d --remove-orphans')
        if [ "${FAIL_BOOTSTRAP_STEP:-}" = up ]; then exit 1; fi
        case "${SAIL_SOURCE_PATH:-}" in
            "${FAIL_UP_PATH:-}")
                if [ -n "${FAIL_UP_PATH:-}" ]; then exit 1; fi
                ;;
        esac
        touch "$state_marker"
        ;;
    'down --remove-orphans')
        rm -f "$state_marker"
        : > "${BUSY_PORTS:?}"
        ;;
    'composer install')
        if [ "${FAIL_BOOTSTRAP_STEP:-}" = composer ]; then exit 1; fi
        if [ "${PARTIAL_COMPOSER_INSTALL:-0}" -eq 1 ]; then
            mkdir -p "$SAIL_SOURCE_PATH/vendor/laravel/sail" "$SAIL_SOURCE_PATH/vendor/bin"
            touch "$SAIL_SOURCE_PATH/vendor/bin/sail"
            chmod 644 "$SAIL_SOURCE_PATH/vendor/bin/sail"
            exit 0
        fi
        mkdir -p "$SAIL_SOURCE_PATH/vendor/bin"
        cp "$ROOT_SAIL" "$SAIL_SOURCE_PATH/vendor/bin/sail"
        chmod +x "$SAIL_SOURCE_PATH/vendor/bin/sail"
        ;;
    'npm install')
        if [ "${FAIL_BOOTSTRAP_STEP:-}" = npm ]; then exit 1; fi
        ;;
    'artisan key:generate')
        if [ "${FAIL_BOOTSTRAP_STEP:-}" = key ]; then exit 1; fi
        ;;
    'artisan migrate:fresh --seed')
        if [ "${FAIL_FRESH:-0}" -eq 1 ]; then exit 1; fi
        ;;
esac
EOF
chmod +x "$repo/vendor/bin/sail"
cp "$repo/vendor/bin/sail" "$repo/.worktrees/feature-x/vendor/bin/sail"
chmod +x "$repo/.worktrees/feature-x/vendor/bin/sail"
mkdir -p "$repo/.worktrees/feature-y/vendor/bin"
cp "$repo/vendor/bin/sail" "$repo/.worktrees/feature-y/vendor/bin/sail"
chmod +x "$repo/.worktrees/feature-y/vendor/bin/sail"
export COMMAND_LOG="$command_log" STACK_STATE_DIR="$stack_state" ROOT_SAIL="$repo/vendor/bin/sail" \
    ROOT_MYSQL_INIT="$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh"
PATH="$repo/bin:$old_path"
: > "$busy_ports"

run_command() {
    WORKTREE_TEST_ROOT="$repo" "$command_script" "$@"
}

rm -rf "$repo/.worktree-active" "$stack_state" "$command_log"
printf '%s\n' feature-x > "$repo/.worktree-active"
rm -rf "$repo/.worktrees/feature-x/vendor"
assert_status 0 run_command status
assert_contains "$command_log" 'ARGS=ps -q laravel.test'
assert_contains "$command_log" "BIN=$repo/vendor/bin/sail"
assert_contains "$command_log" "MYSQL_INIT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh"
expected_status=$(printf 'active: feature-x\npath: %s/.worktrees/feature-x\nbranch: feature-x\nproject: test-project-feature-x\nurl: http://127.0.0.1:8080\nports: app=8080 vite=5173 db=3306 redis=6379\nstatus: stopped' "$repo")
assert_eq "$expected_status" "$(run_command status)" 'status prints project, URL, ports, and stopped state'

mkdir -p "$stack_state"
touch "$stack_state/test-project-feature-x"
expected_running_status=$(printf 'active: feature-x\npath: %s/.worktrees/feature-x\nbranch: feature-x\nproject: test-project-feature-x\nurl: http://127.0.0.1:8080\nports: app=8080 vite=5173 db=3306 redis=6379\nstatus: running' "$repo")
assert_eq "$expected_running_status" "$(run_command status)" \
    'status detects a running stack without local Sail support files'
rm -f "$stack_state/test-project-feature-x"
mkdir -p "$repo/.worktrees/feature-x/vendor/bin"
cp "$repo/vendor/bin/sail" "$repo/.worktrees/feature-x/vendor/bin/sail"
chmod +x "$repo/.worktrees/feature-x/vendor/bin/sail"

rm -f "$command_log"
assert_status 0 run_command start feature-x
assert_contains "$command_log" 'ARGS=up -d --remove-orphans'
assert_eq feature-x "$(cat "$repo/.worktree-active")" \
    'start preserves active worktree after startup'

rm -f "$command_log"
printf 'y\n' | assert_status 0 run_command start feature-x --fresh
assert_contains "$command_log" 'ARGS=artisan migrate:fresh --seed'

rm -f "$command_log"
assert_status 0 run_command stop feature-x
assert_contains "$command_log" 'ARGS=down --remove-orphans'
assert_not_contains "$command_log" '--volumes'
assert_eq "$expected_status" "$(run_command status)" 'status reports a stopped stack'

rm -f "$command_log"
assert_failure_contains 'worktree not found' run_command switch missing
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'failed target validation preserves active worktree'

rm -rf "$command_log" "$stack_state"
rm -rf "$repo/.worktrees/feature-x/vendor"
export FAIL_UP_PATH="$repo/.worktrees/feature-y"
assert_failure_contains 'feature-y' run_command switch feature-y
unset FAIL_UP_PATH
assert_contains "$command_log" "SOURCE=$repo/.worktrees/feature-y BIN=$repo/vendor/bin/sail BUILD_CONTEXT=$repo/vendor/laravel/sail/runtimes/8.5 BUILD_DOCKERFILE=Dockerfile MYSQL_INIT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh ARGS=up -d --remove-orphans"
assert_not_contains "$command_log" "SOURCE=$repo/.worktrees/feature-x BIN=$repo/vendor/bin/sail BUILD_CONTEXT=$repo/vendor/laravel/sail/runtimes/8.5 BUILD_DOCKERFILE=Dockerfile MYSQL_INIT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh ARGS=down --remove-orphans"
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'failed target startup preserves active worktree'

rm -rf "$command_log" "$stack_state"
mkdir -p "$stack_state"
touch "$stack_state/test-project-feature-x"
assert_status 0 run_command switch feature-y
assert_eq feature-y "$(cat "$repo/.worktree-active")" \
    'successful switch writes target active worktree'
if ! grep -q 'ARGS=down --remove-orphans' "$command_log"; then
    printf 'ok - switch keeps the previous stack running\n'
else
    printf 'not ok - switch stopped the previous stack\n'
    failures=$((failures + 1))
fi

rm -rf "$command_log" "$stack_state"
mkdir -p "$stack_state"
assert_failure_contains 'already exists' run_command create feature-x
assert_failure_contains 'branch does not exist' run_command create missing-branch --existing

printf '%s\n' feature-x > "$repo/.worktree-active"
printf '8080\n' > "$busy_ports"
rm -f "$command_log"
assert_status 0 run_command create port-allocation-fallback
assert_contains "$command_log" 'ARGS=up -d --remove-orphans'
assert_status 0 load_worktree_state port-allocation-fallback
case "$WORKTREE_STATE_APP_PORT" in
    8080)
        printf 'not ok - allocator reused a busy HTTP port\n'
        failures=$((failures + 1))
        ;;
    *) printf 'ok - allocator skipped the busy HTTP port\n' ;;
esac
git -C "$repo" worktree remove -f "$repo/.worktrees/port-allocation-fallback"
rm -f "$repo/.worktrees/.state/port-allocation-fallback.env"
printf '%s\n' feature-x > "$repo/.worktree-active"
: > "$busy_ports"

for missing_bootstrap_path in \
    "$repo/vendor/bin/sail" \
    "$repo/vendor/laravel/sail/runtimes/8.5" \
    "$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh"; do
    missing_bootstrap_name=$(basename "$missing_bootstrap_path")
    mv "$missing_bootstrap_path" "$missing_bootstrap_path.missing"
    : > "$command_log"
    touch "$stack_state/test-project-feature-x"
    case "$missing_bootstrap_name" in
        sail) missing_bootstrap_error='Haupt-Checkout benötigt eine Sail-Installation' ;;
        8.5) missing_bootstrap_error='Sail-Runtime fehlt' ;;
        create-testing-database.sh) missing_bootstrap_error='Sail-Bootstrap-Datei fehlt' ;;
    esac
    assert_failure_contains "$missing_bootstrap_error" \
        run_command create "missing-$missing_bootstrap_name"
    assert_not_contains "$command_log" 'ARGS=up -d --remove-orphans'
    assert_eq feature-x "$(<"$repo/.worktree-active")" \
        "missing $missing_bootstrap_name preserves active state"
    assert_not_exists "$repo/.worktrees/missing-$missing_bootstrap_name"
    mv "$missing_bootstrap_path.missing" "$missing_bootstrap_path"
done

rm -rf "$stack_state"
mkdir -p "$stack_state"
run_command create feature-z-unique
assert_contains "$command_log" 'ARGS=up -d --remove-orphans'
assert_contains "$command_log" 'ARGS=composer install'
assert_contains "$command_log" 'ARGS=npm install'
assert_contains "$command_log" 'ARGS=artisan key:generate'
assert_contains "$command_log" "SOURCE=$repo/.worktrees/feature-z-unique BIN=$repo/vendor/bin/sail BUILD_CONTEXT=$repo/vendor/laravel/sail/runtimes/8.5 BUILD_DOCKERFILE=Dockerfile MYSQL_INIT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh ARGS=up -d --remove-orphans"
assert_contains "$command_log" "SOURCE=$repo/.worktrees/feature-z-unique BIN=$repo/vendor/bin/sail BUILD_CONTEXT=$repo/vendor/laravel/sail/runtimes/8.5 BUILD_DOCKERFILE=Dockerfile MYSQL_INIT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh ARGS=composer install"
assert_contains "$command_log" "SOURCE=$repo/.worktrees/feature-z-unique BIN=$repo/.worktrees/feature-z-unique/vendor/bin/sail BUILD_CONTEXT= BUILD_DOCKERFILE=Dockerfile MYSQL_INIT= ARGS=npm install"
assert_contains "$command_log" "SOURCE=$repo/.worktrees/feature-z-unique BIN=$repo/.worktrees/feature-z-unique/vendor/bin/sail BUILD_CONTEXT= BUILD_DOCKERFILE=Dockerfile MYSQL_INIT= ARGS=artisan key:generate"
assert_not_contains "$command_log" 'migrate:fresh'
assert_eq feature-z-unique "$(<"$repo/.worktree-active")" \
    'successful create writes active state'
up_line=$(awk '/ARGS=up -d --remove-orphans/ { print NR; exit }' "$command_log")
composer_line=$(awk '/ARGS=composer install/ { print NR; exit }' "$command_log")
npm_line=$(awk '/ARGS=npm install/ { print NR; exit }' "$command_log")
key_line=$(awk '/ARGS=artisan key:generate/ { print NR; exit }' "$command_log")
if [ "$up_line" -lt "$composer_line" ] && [ "$composer_line" -lt "$npm_line" ] && [ "$npm_line" -lt "$key_line" ]; then
    printf 'ok - create bootstrap steps run in order\n'
else
    printf 'not ok - create bootstrap steps run in order\n'
    failures=$((failures + 1))
fi

assert_failure_contains 'invalid worktree name' run_command create '../escape'
assert_eq feature-z-unique "$(<"$repo/.worktree-active")" \
    'invalid create name preserves active state'

: > "$command_log"
run_command create existing-source --existing
assert_eq existing-source "$(<"$repo/.worktree-active")" \
    'successful create existing branch writes active state'
assert_not_contains "$command_log" 'ARGS=artisan key:generate'

remove_test_worktree() {
    git -C "$repo" worktree remove -f "$repo/.worktrees/$1" >/dev/null 2>&1 || true
}

rm -rf "$command_log" "$stack_state" "$repo/.worktree-active"
mkdir -p "$stack_state"
export PARTIAL_COMPOSER_INSTALL=1
assert_failure_contains 'Sail nach Composer-Installation nicht gefunden' \
    run_command create partial-composer-failure
assert_contains "$command_log" \
    "SOURCE=$repo/.worktrees/partial-composer-failure BIN=$repo/vendor/bin/sail BUILD_CONTEXT=$repo/vendor/laravel/sail/runtimes/8.5 BUILD_DOCKERFILE=Dockerfile MYSQL_INIT=$repo/vendor/laravel/sail/database/mysql/create-testing-database.sh ARGS=down --remove-orphans"
assert_not_executable "$repo/.worktrees/partial-composer-failure/vendor/bin/sail"
assert_not_exists "$stack_state/test-project-partial-composer-failure"
assert_not_exists "$repo/.worktree-active"
remove_test_worktree partial-composer-failure
unset PARTIAL_COMPOSER_INSTALL

printf '%s\n' existing-source > "$repo/.worktree-active"
export FAIL_BOOTSTRAP_STEP=up
assert_failure_contains 'Fehler bei Schritt: Stack starten' run_command create bootstrap-up-failure
assert_eq existing-source "$(<"$repo/.worktree-active")" \
    'failed create startup preserves active state'
assert_contains "$command_log" "SOURCE=$repo/.worktrees/bootstrap-up-failure"
assert_contains "$command_log" 'ARGS=down --remove-orphans'
remove_test_worktree bootstrap-up-failure
unset FAIL_BOOTSTRAP_STEP

printf '%s\n' feature-x > "$repo/.worktree-active"
touch "$stack_state/test-project-feature-x"
export FAIL_BOOTSTRAP_STEP=composer
rm -f "$command_log"
assert_failure_contains 'Fehler bei Schritt: Composer-Abhängigkeiten installieren' \
    run_command create bootstrap-composer-failure
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'failed create dependency install preserves active state'
assert_contains "$command_log" "SOURCE=$repo/.worktrees/bootstrap-composer-failure"
assert_contains "$command_log" 'ARGS=down --remove-orphans'
if ! grep -q "SOURCE=$repo/.worktrees/feature-x.*ARGS=down --remove-orphans" "$command_log"; then
    printf 'ok - create rollback does not stop the previous stack\n'
else
    printf 'not ok - create rollback stopped the previous stack\n'
    failures=$((failures + 1))
fi
assert_not_contains "$command_log" "SOURCE=$repo/.worktrees/feature-x"
remove_test_worktree bootstrap-composer-failure
unset FAIL_BOOTSTRAP_STEP

for bootstrap_failure in npm key; do
    rm -rf "$command_log" "$stack_state"
    printf '%s\n' feature-x > "$repo/.worktree-active"
    mkdir -p "$stack_state"
    touch "$stack_state/test-project-feature-x"
    export FAIL_BOOTSTRAP_STEP=$bootstrap_failure
    assert_failure_contains 'Fehler bei Schritt:' run_command create "bootstrap-$bootstrap_failure-failure"
    assert_eq feature-x "$(<"$repo/.worktree-active")" \
        "failed $bootstrap_failure bootstrap preserves active state"
    assert_contains "$command_log" "SOURCE=$repo/.worktrees/bootstrap-$bootstrap_failure-failure"
    assert_contains "$command_log" 'ARGS=down --remove-orphans'
    remove_test_worktree "bootstrap-$bootstrap_failure-failure"
    unset FAIL_BOOTSTRAP_STEP
done

rm -rf "$command_log" "$stack_state"
printf '%s\n' feature-x > "$repo/.worktree-active"
mkdir -p "$stack_state"
touch "$stack_state/test-project-feature-x"
rm -f "$repo/.worktrees/feature-y/.env"
assert_failure_contains '.env fehlt' run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
printf 'APP_KEY=base64:feature-y\n' > "$repo/.worktrees/feature-y/.env"

mv "$repo/.worktrees/feature-y/compose.yaml" "$repo/.worktrees/feature-y/compose.yaml.missing"
assert_failure_contains 'compose.yaml fehlt' run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
mv "$repo/.worktrees/feature-y/compose.yaml.missing" "$repo/.worktrees/feature-y/compose.yaml"

mv "$repo/vendor/bin/sail" "$repo/vendor/bin/sail.missing"
assert_failure_contains 'Haupt-Checkout benötigt eine Sail-Installation' run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
mv "$repo/vendor/bin/sail.missing" "$repo/vendor/bin/sail"

mv "$repo/vendor/laravel/sail/runtimes/8.5" "$repo/vendor/laravel/sail/runtimes/8.5.missing"
assert_failure_contains 'Sail-Runtime fehlt' run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
mv "$repo/vendor/laravel/sail/runtimes/8.5.missing" "$repo/vendor/laravel/sail/runtimes/8.5"

rm -rf "$command_log" "$stack_state"
printf '%s\n' feature-x > "$repo/.worktree-active"
mkdir -p "$stack_state"
assert_failure_contains_input n 'Datenbank-Reset abgebrochen' run_command switch feature-y --fresh
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'fresh refusal preserves active state'

rm -rf "$command_log" "$stack_state"
mkdir -p "$stack_state"
export FAIL_FRESH=1
assert_failure_contains_input y 'Ziel-Stack läuft, aber der Datenbank-Reset wurde nicht abgeschlossen.' \
    run_command switch feature-y --fresh
unset FAIL_FRESH
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'fresh migration failure preserves active state'
assert_contains "$command_log" 'ARGS=artisan migrate:fresh --seed'

rm -rf "$command_log" "$repo/.worktree-active" "$stack_state"
mkdir -p "$stack_state"
touch "$stack_state/test-project-feature-y"
printf '8080\n' > "$busy_ports"
assert_status 0 run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
assert_eq feature-y "$(<"$repo/.worktree-active")" \
    'switch starts target without active state'
: > "$busy_ports"

printf '%s\n' '../invalid' > "$repo/.worktree-active"
rm -rf "$command_log" "$stack_state"
mkdir -p "$stack_state"
touch "$stack_state/test-project-feature-y"
assert_status 0 run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
assert_eq feature-y "$(<"$repo/.worktree-active")" \
    'switch ignores stale active pointer for explicit target'

printf '%s\n' removed-worktree > "$repo/.worktree-active"
assert_failure_contains 'stale active worktree' run_command status
assert_status 0 run_command status feature-y

mkdir -p "$repo/.worktrees/.state"
printf '%s\n' \
    'WORKTREE_NAME=orphan' \
    'COMPOSE_PROJECT_NAME=test-project-orphan' \
    'APP_PORT=8120' \
    'VITE_PORT=5213' \
    'FORWARD_DB_PORT=3346' \
    'FORWARD_REDIS_PORT=6419' \
    > "$repo/.worktrees/.state/orphan.env"
assert_output_contains 'orphan' run_command status --all
assert_status 0 run_command prune
assert_not_exists "$repo/.worktrees/.state/orphan.env"

git -C "$repo" worktree add -q -b registered-orphan "$repo/.worktrees/registered-orphan"
printf '%s\n' \
    'WORKTREE_NAME=registered-orphan' \
    'COMPOSE_PROJECT_NAME=test-project-registered-orphan' \
    'APP_PORT=8130' \
    'VITE_PORT=5223' \
    'FORWARD_DB_PORT=3356' \
    'FORWARD_REDIS_PORT=6429' \
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

assert_failure_contains 'Verwendung:' run_command create feature-z --fresh
assert_failure_contains 'Verwendung:' run_command status feature-y --all

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures"
    exit 1
fi

printf 'all tests passed\n'
