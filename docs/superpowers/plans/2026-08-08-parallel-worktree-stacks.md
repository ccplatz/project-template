# Parallel Worktree Stacks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shared Worktree tooling run multiple isolated Sail stacks by default with persisted per-Worktree state, allocated ports, and non-destructive lifecycle commands.

**Architecture:** Keep `.worktree-active` as a convenience selection pointer, but store the actual Compose project name and standard host-port group in `.worktrees/.state/<name>.env`. All named Sail operations load that state and pass its values explicitly. The CLI will address Worktrees by name, `switch` will no longer stop the previous stack, and `status --all`/`prune` will expose and clean stale metadata without touching unrelated Docker resources.

**Tech Stack:** Bash with `set -euo pipefail`, Docker Compose through Laravel Sail, Git worktree CLI, existing shell-based regression tests.

## Global Constraints

- Run multiple Worktree stacks concurrently without cross-stack container, volume, network, or port interference.
- `.worktree-active` is only a selection pointer and must never determine which unrelated stack is stopped.
- Per-Worktree state is stored at `.worktrees/.state/<name>.env` and is not committed.
- Each named Worktree uses the Compose project name `<PROJECT_NAME>-<worktree-name>`.
- Standard managed ports are `APP_PORT`, `VITE_PORT`, `FORWARD_DB_PORT`, and `FORWARD_REDIS_PORT`.
- Port allocation uses `APP_PORT = 8080 + (n * 10)`, `VITE_PORT = 5173 + (n * 10)`, `FORWARD_DB_PORT = 3306 + (n * 10)`, and `FORWARD_REDIS_PORT = 6379 + (n * 10)` for group index `n`.
- Port allocation checks both persisted reservations and actual host availability and uses an atomic allocation lock.
- Port `80` is never an implicit fallback for Worktree-managed HTTP access.
- `--remove-orphans` is allowed only with the target Worktree's unique Compose project name.
- `switch` selects and starts the target without stopping any other Worktree.
- A failed dependency step may still use the current bootstrap rollback behavior in this session, but it must not restart or stop the previous Worktree. Resumable bootstrap is Session 2.
- Do not add or generate consumer-owned Compose files.
- Do not change consumer-owned Compose service definitions, container user mappings, root-owned files, or Playwright configuration.
- Do not add runtime dependencies or require YAML/JSON parsers.
- Keep Bash scripts ShellCheck-compatible and preserve the existing test seams.
- Validate the derived Compose project name with Docker Compose's accepted
  project-name character rules before invoking Compose.

---

## File Map

- Modify: `bin/worktree-lib.sh` — per-Worktree state, port allocation, Compose environment propagation, state listing, and orphan pruning.
- Modify: `bin/worktree` — named command parsing, non-destructive switching, explicit target resolution, and status output.
- Modify: `tests/bin/worktree_test.sh` — red/green regression coverage using the mock Sail command and isolated mock stack state.
- Modify: `tests/bin/template_sync_test.sh` — verify the shared Worktree documentation is registered and contains the required contract.
- Create: `docs/worktree.md` — template-owned operational documentation for the new Worktree model.
- Modify: `template-manifest.tsv` — register `docs/worktree.md` as `template-owned`.
- Modify: `AGENTS.md` — update this template checkout's command and parallel-stack guidance; it remains `project-owned` and is not synchronized into consumers.
- Modify: `VERSION` — bump the template release to `0.2.0` for the public lifecycle change.
- Modify: `CHANGELOG.md` — record the parallel Worktree stack behavior and migration note.

The first implementation session does not modify consumer-owned `README.md`, Compose files, or E2E configuration. `AGENTS.md` is updated only in this template checkout and is not a synchronized consumer path. Session 2 will use the interfaces created here but has its own plan.

## Interfaces Introduced In This Plan

The following Bash functions are the stable seams between the library and CLI:

```bash
worktree_state_dir
worktree_state_path <name>
load_worktree_state <name>
write_worktree_state <name> <compose_project> <app_port> <vite_port> <db_port> <redis_port>
ensure_worktree_state <name> <path>
worktree_state_port_available <name> <app_port> <vite_port> <db_port> <redis_port>
run_worktree_sail <name> <path> <sail_bin> <mysql_init_script> <build_context> <build_dockerfile> <command> [args...]
stack_is_running_for_worktree <name> <path>
start_for_worktree <name> <path>
stop_for_worktree <name> <path>
run_fresh <name> <path>
list_worktree_state_names
prune_worktree_state
```

`load_worktree_state` exports these validated variables for its caller:

```text
WORKTREE_STATE_NAME
WORKTREE_STATE_COMPOSE_PROJECT_NAME
WORKTREE_STATE_APP_PORT
WORKTREE_STATE_VITE_PORT
WORKTREE_STATE_DB_PORT
WORKTREE_STATE_REDIS_PORT
```

The library must not source arbitrary state-file shell code. Parse generated
`KEY=value` records, reject unknown keys, require decimal port values, and
validate the project/name relationship before exporting the variables.

## Task 1: Add Per-Worktree State And Port Allocation

**Files:**
- Modify: `bin/worktree-lib.sh:13-130`
- Test: `tests/bin/worktree_test.sh:247-342`

**Interfaces:**
- Consumes: existing `worktree_root`, `PROJECT_NAME`, `validate_worktree_name`, and `port_is_available`.
- Produces: the state and allocation functions listed above; later tasks use their `WORKTREE_STATE_*` exports without reading state files directly.

- [ ] **Step 1: Write failing state and allocation tests**

Extend the temporary repository setup with the ignored state directory, create
the second test Worktree before the state assertions, and add these assertions
after the existing Sail setup:

```bash
git -C "$repo" worktree add -q -b feature-y "$repo/.worktrees/feature-y"
printf 'APP_KEY=base64:feature-y\n' > "$repo/.worktrees/feature-y/.env"
cp "$repo/compose.yaml" "$repo/.worktrees/feature-y/compose.yaml"

mkdir -p "$repo/bin"
busy_ports="$repo/busy-ports"
printf '%s\n' '#!/bin/bash' \
    'while IFS= read -r busy_port; do' \
    '    [ "$busy_port" = "$2" ] && exit 0' \
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
```

The fake `nc` above now handles each requested port independently. Use
`printf '8080\n' > "$busy_ports"` for a single busy HTTP port and
`printf '8080\n8090\n' > "$busy_ports"` for two busy groups. The allocator test
must verify that a busy `8080` causes the next complete group to be selected,
not that every port is treated as occupied. Add a malformed-state case that
expects failure and verifies that no Sail command is invoked:

Remove the old global fake-`nc` setup and every `port_in_use` reference from
the existing test body. Remove the later duplicate `git worktree add` for
`feature-y` at current lines 345-347 because the setup above creates that
Worktree once. Keep `PATH=$old_path` only after the new state and Sail
environment tests have completed.

```bash
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
```

Add an output assertion helper beside `assert_contains`; the existing helper
accepts a file path and must not be used with command substitution:

```bash
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
```

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run:

```sh
./tests/bin/worktree_test.sh
```

Expected: FAIL because the state functions and state directory do not exist yet.

- [ ] **Step 3: Implement validated state paths and records**

Add the state helpers immediately after `worktree_path` in `bin/worktree-lib.sh`:

```bash
worktree_state_dir() {
    printf '%s/.worktrees/.state\n' "$worktree_root"
}

worktree_state_path() {
    validate_worktree_name "$1" || return 1
    printf '%s/%s.env\n' "$(worktree_state_dir)" "$1"
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
```

Implement `load_worktree_state` as a line parser rather than `source`. Require exactly the six generated keys, reject unknown keys and duplicate keys, require decimal ports, require `APP_PORT` to be at least `8080`, and require `COMPOSE_PROJECT_NAME` to equal `PROJECT_NAME-<name>`. Export the six `WORKTREE_STATE_*` variables only after all validation succeeds.

Add a `compose_project_name_for_worktree` helper that constructs
`$PROJECT_NAME-$name` and validates the result against Docker Compose's
accepted project-name pattern: it must begin with a lowercase letter or digit
and contain only lowercase letters, digits, `_`, or `-`. Return a diagnostic
that names both the derived value and the source `PROJECT_NAME` when this
check fails. Use this helper in both state creation and state loading. Add a
test that temporarily sets `PROJECT_NAME=Bad.Name`, expects state creation to
fail, and then restores `PROJECT_NAME=test-project` for the remaining tests.

- [ ] **Step 4: Implement the allocation lock and port-group selection**

Add an atomic lock directory at `.worktrees/.state/.allocation-lock`. Store the allocating shell PID in `.allocation-lock/pid`. Acquire it with `mkdir`; if the directory already exists, read the PID and use `kill -0` to distinguish a live allocator from a stale lock. A live PID returns a clear retryable error. A missing, malformed, or non-running PID is stale and may be removed before retrying. Remove the current process's lock with a `trap`; never remove a lock owned by a live process.

Implement the exact group calculation:

```bash
app_port=$((8080 + index * 10))
vite_port=$((5173 + index * 10))
db_port=$((3306 + index * 10))
redis_port=$((6379 + index * 10))
```

`worktree_state_port_available` must reject a port if any other `*.env` state file contains it or if `port_is_available` reports it occupied. Check all four ports before accepting a group. Scan indexes `0` through `99`; if none is available, fail before invoking Sail.

`ensure_worktree_state` must load and validate an existing state file without changing it. If no state exists, it must acquire the lock, rescan reservations and host ports, write the first available group, release the lock, and load the result. It may adopt a complete valid four-variable group from the target `.env` only if `APP_PORT >= 8080`, all values are decimal, and every port is unreserved and available; otherwise it must allocate from the formula above.

Add lock regression cases using the current shell PID for a live lock and a
large non-running PID such as `99999999` for a stale lock:

```bash
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
```

The live case must fail without removing the lock; the stale case must remove
the lock and allow allocation to continue.

- [ ] **Step 5: Run the state tests and verify they pass**

Run:

```sh
./tests/bin/worktree_test.sh
```

Expected: all state, allocation, persistence, collision, malformed-state, and lock-recovery assertions pass. Existing stack behavior remains unchanged until Task 2 changes the Sail environment propagation.

- [ ] **Step 6: Commit the state foundation**

```sh
git add bin/worktree-lib.sh tests/bin/worktree_test.sh
git commit -m "feat: add per-worktree state and port allocation"
```

## Task 2: Propagate Isolated Compose Environment To Sail

**Files:**
- Modify: `bin/worktree:65-142`
- Modify: `bin/worktree-lib.sh:30-60,62-72,131-219`
- Test: `tests/bin/worktree_test.sh:255-342`

**Interfaces:**
- Consumes: `load_worktree_state` and the `WORKTREE_STATE_*` variables from Task 1.
- Produces: `run_worktree_sail <name> <path> <sail_bin> <mysql_init_script> <build_context> <build_dockerfile> <command> [args...]` and state-aware stack lifecycle functions.

- [ ] **Step 1: Write failing isolation tests**

Update the mock Sail log to include all Compose and port environment values:

```bash
printf 'PROJECT=%s APP=%s VITE=%s DB=%s REDIS=%s SOURCE=%s ARGS=%s\n' \
    "${COMPOSE_PROJECT_NAME:-}" "${APP_PORT:-}" "${VITE_PORT:-}" \
    "${FORWARD_DB_PORT:-}" "${FORWARD_REDIS_PORT:-}" \
    "${SAIL_SOURCE_PATH:-}" "$*" >> "$MOCK_SAIL_LOG"
```

Replace the single `STACK_STATE` marker in the mock with a directory keyed by
Compose project name and update every `up`, `down`, and `ps` branch to use the
computed marker:

```bash
stack_state_dir="$repo/stack-running"
mkdir -p "$stack_state_dir"
state_marker="$stack_state_dir/${COMPOSE_PROJECT_NAME:?}"

case "$*" in
    'ps -q laravel.test')
        if [ -f "$state_marker" ]; then
            printf 'container-%s\n' "${COMPOSE_PROJECT_NAME:?}"
        fi
        ;;
    'up -d --remove-orphans')
        touch "$state_marker"
        ;;
    'down --remove-orphans')
        rm -f "$state_marker"
        ;;
esac
```

Add tests that start `feature-x` and `feature-y`, then assert the exact
recorded environment values:

```bash
: > "$MOCK_SAIL_LOG"
assert_status 0 start_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_status 0 start_for_worktree feature-y "$repo/.worktrees/feature-y"
assert_contains "$MOCK_SAIL_LOG" \
    'PROJECT=test-project-feature-x APP=8080 VITE=5173 DB=3306 REDIS=6379'
assert_contains "$MOCK_SAIL_LOG" \
    'PROJECT=test-project-feature-y APP=8100 VITE=5193 DB=3326 REDIS=6399'

assert_status 0 stop_for_worktree feature-x "$repo/.worktrees/feature-x"
assert_not_exists "$stack_state_dir/test-project-feature-x"
if [ -f "$stack_state_dir/test-project-feature-y" ]; then
    printf 'ok - stopping feature-x keeps feature-y running\n'
else
    printf 'not ok - stopping feature-x removed feature-y\n'
    failures=$((failures + 1))
fi
```

Add a regression case with `printf '8080\n' > "$busy_ports"` where
`start_for_worktree feature-x ...` still starts using the already persisted
state. The state reservation is authoritative for an existing Worktree; the
allocator only checks host availability when creating a new state.

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run:

```sh
./tests/bin/worktree_test.sh
```

Expected: FAIL because current calls still pass the shared `PROJECT_NAME` and do not export the state port variables.

- [ ] **Step 3: Add the shared Worktree Sail invocation seam**

Implement one function that loads state, changes to the target directory, and invokes the existing `run_sail` seam with all target-specific values:

```bash
run_worktree_sail() {
    local name=$1
    local path=$2
    local sail_bin=$3
    local mysql_init_script=$4
    local build_context=$5
    local build_dockerfile=$6
    shift 6

    load_worktree_state "$name" || return 1
    (
        cd "$path" || exit 1
        COMPOSE_PROJECT_NAME="$WORKTREE_STATE_COMPOSE_PROJECT_NAME" \
            APP_PORT="$WORKTREE_STATE_APP_PORT" \
            VITE_PORT="$WORKTREE_STATE_VITE_PORT" \
            FORWARD_DB_PORT="$WORKTREE_STATE_DB_PORT" \
            FORWARD_REDIS_PORT="$WORKTREE_STATE_REDIS_PORT" \
            SAIL_SOURCE_PATH="$path" SAIL_BIN="$sail_bin" \
            SAIL_MYSQL_INIT_SCRIPT="$mysql_init_script" \
            SAIL_BUILD_CONTEXT="$build_context" \
            SAIL_BUILD_DOCKERFILE="$build_dockerfile" \
            run_sail "$@"
    )
}
```

Pass empty build values for normal starts/stops and the main checkout runtime path plus `Dockerfile` for bootstrap. Do not let an exported caller value override the values selected by the target operation.

Update `run_bootstrap_command` in `bin/worktree` to accept the Worktree name as its first argument and delegate to `run_worktree_sail`:

```bash
run_bootstrap_command() {
    local name=$1
    local target=$2
    local build_context=$3
    local sail_bin=$4
    local mysql_init_script=$5
    local build_dockerfile=''
    shift 5

    if [ -n "$build_context" ]; then
        build_dockerfile=Dockerfile
    fi
    run_worktree_sail "$name" "$target" "$sail_bin" "$mysql_init_script" \
        "$build_context" "$build_dockerfile" "$@"
}
```

Update `bootstrap_worktree` to accept `<name> <target>` and pass that name on every Composer, npm, and Artisan call. The target bootstrap must therefore use the target project's Compose name and port group even while it uses the main checkout's Sail runtime files. Update `create_worktree` to call `ensure_worktree_state "$name" "$target"` before `bootstrap_worktree "$name" "$target"`.

- [ ] **Step 4: Route status, start, stop, and fresh operations through the seam**

Change the lifecycle signatures to receive the Worktree name explicitly:

```bash
stack_is_running_for_worktree <name> <path>
start_stack <name> <path> <sail_bin>
stop_stack <name> <path> <sail_bin> <mysql_init_script>
run_fresh <name> <path> [<sail_bin>]
start_for_worktree <name> <path>
stop_for_worktree <name> <path>
```

`start_for_worktree`, `run_fresh`, and bootstrap calls must call
`ensure_worktree_state` before `up` or `artisan migrate:fresh`. `stop_for_worktree`
and `stack_is_running_for_worktree` must only load an existing state; they must
not allocate a state as a side effect. An unconfigured Worktree therefore has
an unambiguous `status: unconfigured` result and `stop <name>` returns a clear
"state not initialized; start it first" diagnostic. `stack_is_running_for_worktree`
may use the main checkout Sail fallback for incomplete bootstrap, but it must
still load the target state and pass the target Compose project name and ports.

Update every direct unit-test invocation to the new signatures, for example:

```bash
start_stack feature-x "$repo/.worktrees/feature-x" "$repo/vendor/bin/sail"
stop_stack feature-x "$repo/.worktrees/feature-x" \
    "$repo/.worktrees/feature-x/vendor/bin/sail" ''
run_fresh feature-x "$repo/.worktrees/feature-x"
```

Replace the old root-level `stack_is_running` assertion with this named
assertion and a project-keyed mock marker:

```bash
touch "$stack_state_dir/test-project-feature-x"
assert_status 0 stack_is_running_for_worktree feature-x \
    "$repo/.worktrees/feature-x"
```

Keep `--remove-orphans` on `up` and `down`; the unique `COMPOSE_PROJECT_NAME` now makes the operation target-specific. Remove every remaining hard-coded `COMPOSE_PROJECT_NAME="$PROJECT_NAME"` and every global `port_is_available 8080` gate from named stack operations.

- [ ] **Step 5: Remove cross-Worktree rollback actions**

In `bootstrap_worktree`, remove `prior_path`, the previous-stack restart, and any rollback call that can invoke `start_for_worktree` for a different name. On a failed `up`, rollback may call `down` only for the target name and path. Leave the current dependency-failure cleanup behavior for Session 2 to change; this task only guarantees that no prior stack is stopped or restarted.

- [ ] **Step 6: Run the isolation tests and verify they pass**

Run:

```sh
./tests/bin/worktree_test.sh
```

Expected: all mock Sail calls contain the target Compose project and port group; stopping one mock project leaves the other running; no global 8080 preflight blocks a named stack with a persisted state.

- [ ] **Step 7: Commit isolated Sail propagation**

```sh
git add bin/worktree-lib.sh tests/bin/worktree_test.sh
git commit -m "feat: isolate sail environments per worktree"
```

## Task 3: Make The CLI Addressable And Non-Destructive

**Files:**
- Modify: `bin/worktree:9-36,81-231,233-306`
- Modify: `bin/worktree-lib.sh:221-287`
- Test: `tests/bin/worktree_test.sh:344-673`

**Interfaces:**
- Consumes: state-aware lifecycle functions from Tasks 1 and 2.
- Produces: the command forms `bootstrap <name>`, `start [<name>] [--fresh]`, `stop [<name>]`, `switch <name> [--fresh]`, `status [<name>]`, `status --all`, and `prune`.

- [ ] **Step 1: Write failing CLI regression tests**

Add these scenarios to the command-level test section:

```bash
rm -f "$repo/.worktree-active" "$command_log"
printf '%s\n' feature-x > "$repo/.worktree-active"
assert_status 0 run_command start feature-y
assert_contains "$command_log" \
    "SOURCE=$repo/.worktrees/feature-y ARGS=up -d --remove-orphans"
assert_not_contains "$command_log" "SOURCE=$repo/.worktrees/feature-x ARGS=down --remove-orphans"

rm -f "$command_log"
assert_status 0 run_command switch feature-x
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
assert_eq feature-x "$(<"$repo/.worktree-active")" \
    'switch selects the target without stopping another stack'

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
```

Replace the existing fixed-port preflight block at current test lines
485-494 with a successful allocation assertion:

```bash
printf '8080\n' > "$busy_ports"
rm -f "$command_log"
assert_status 0 run_command create port-allocation-fallback
assert_contains "$command_log" \
    'ARGS=up -d --remove-orphans'
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
rm -f "$busy_ports"
```

Before the Composer-failure scenario, clear the command log with
`rm -f "$command_log"`. Replace the current rollback expectation at lines 587-594 with an assertion
that the target is cleaned without restarting the previous Worktree:

```bash
assert_contains "$command_log" \
    "SOURCE=$repo/.worktrees/bootstrap-composer-failure"
assert_contains "$command_log" 'ARGS=down --remove-orphans'
assert_not_contains "$command_log" \
    "SOURCE=$repo/.worktrees/feature-x"
```

Replace the fixed-stack switch assertions at lines 650-664 with named,
non-destructive assertions:

```bash
rm -f "$command_log"
assert_status 0 run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
assert_eq feature-y "$(<"$repo/.worktree-active")" \
    'switch keeps the previous stack running'

printf '%s\n' '../invalid' > "$repo/.worktree-active"
rm -f "$command_log"
assert_status 0 run_command switch feature-y
assert_not_contains "$command_log" 'ARGS=down --remove-orphans'
assert_eq feature-y "$(<"$repo/.worktree-active")" \
    'switch ignores a stale active pointer when a target is explicit'
```

Add `stop feature-x` and `stop feature-y` assertions that verify only the
named mock marker is removed. Remove the old assertions that expect a global
`Port 8080 ist bereits belegt` failure or a down operation during `switch`.

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run:

```sh
./tests/bin/worktree_test.sh
```

Expected: FAIL because the current parser rejects names for `start`/`stop`, `switch` stops the prior stack, stale active names abort status, and `status --all`/`prune` are absent.

- [ ] **Step 3: Add explicit and active-name resolution helpers**

In `bin/worktree-lib.sh`, add:

```bash
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
```

Keep `resolve_worktree <name>` responsible for validating an explicitly named Git worktree. Do not make it mutate `.worktree-active`. Add a separate status-only path that prints `stale active worktree: <name>` when the active name no longer resolves, so `status` can report the condition without changing state.

- [ ] **Step 4: Replace switch logic with target-only lifecycle**

Replace `switch_worktree` with this sequence:

1. Resolve and validate the target.
2. Ensure or load target state.
3. Start only the target.
4. If `--fresh` is present, run the target reset.
5. Write `.worktree-active` only after all requested steps succeed.

Do not inspect or stop the previous active Worktree. On target start failure, print the target name and return failure without changing the active pointer. On fresh failure, leave the target running and preserve the prior active pointer.

- [ ] **Step 5: Add named start and stop behavior**

Implement:

```bash
start_named() {
    local name=$1
    local fresh=${2:-0}
    local path
    path=$(resolve_worktree "$name") || return 1
    start_for_worktree "$name" "$path" || return 1
    if [ "$fresh" -eq 1 ]; then
        run_fresh "$name" "$path" || return 1
    fi
}

stop_named() {
    local name=$1
    local path
    path=$(resolve_worktree "$name") || return 1
    stop_for_worktree "$name" "$path"
}
```

`start` and `stop` without a name call `active_worktree_name` first. They must never infer a different target after an active-state failure.

- [ ] **Step 6: Add status output and orphan pruning**

`status <name>` must print the existing active/path/branch fields plus:

```text
project: <Compose project name>
url: http://127.0.0.1:<APP_PORT>
ports: app=<APP_PORT> vite=<VITE_PORT> db=<FORWARD_DB_PORT> redis=<FORWARD_REDIS_PORT>
status: running|stopped
```

For a valid Worktree without a state file, print `status: unconfigured` and the
command needed to initialize it. Status must check for the state file and call
`load_worktree_state` only when it exists; it must never call
`ensure_worktree_state`. For a stale active name, print the stale diagnostic
and return failure only for implicit `status`; `status <valid-name>` remains
usable.

`status --all` must enumerate `.worktrees/*` directories except `.state`, show configured Worktrees and their runtime status, then show state files whose Worktree no longer resolves as `orphaned`. It must not invoke `down`.

`prune_worktree_state` must remove only orphaned `.env` files after confirming both that the corresponding Worktree path is absent or invalid and that Git no longer lists the Worktree. It must never call Sail, Docker, `git worktree remove`, or `git worktree prune`.

- [ ] **Step 7: Update argument parsing and help output**

Update `usage()` and the case statement in `bin/worktree` to reject ambiguous forms and accept only:

```text
create <name> [--existing]
bootstrap <name>
start [<name>] [--fresh]
stop [<name>]
switch <name> [--fresh]
status [<name>]
status --all
prune
```

For `start`, accept both `start <name>` and `start <name> --fresh`; preserve `start --fresh` as the active-target shorthand. Reject `create <name> --fresh`, `status <name> --all`, extra arguments, and unknown options with usage output and exit status 1.

The `bootstrap` command may continue to call the existing bootstrap implementation in Session 1, but it must resolve the explicit name and load its state. Session 2 will make its failure behavior resumable without changing this command shape.

- [ ] **Step 8: Run the complete Worktree test and verify it passes**

Run:

```sh
./tests/bin/worktree_test.sh
```

Expected: `all tests passed`, including named lifecycle, non-destructive switch, stale-state, status-all, and pruning assertions.

- [ ] **Step 9: Commit the CLI lifecycle**

```sh
git add bin/worktree bin/worktree-lib.sh tests/bin/worktree_test.sh
git commit -m "feat: make worktree lifecycle addressable"
```

## Task 4: Add Shared Worktree Documentation And Manifest Ownership

**Files:**
- Create: `docs/worktree.md`
- Modify: `template-manifest.tsv:20-23`
- Modify: `tests/bin/template_sync_test.sh`

**Interfaces:**
- Consumes: the command syntax, state schema, port formula, and recovery behavior implemented in Tasks 1-3.
- Produces: template-owned operational documentation that consumer projects can synchronize without overwriting project-owned README or instruction files.

- [ ] **Step 1: Write the documentation checks**

Add a small assertion block to `tests/bin/template_sync_test.sh` that checks the real manifest contains:

```text
template-owned	docs/worktree.md
```

and that `docs/worktree.md` contains `status --all`, `.worktrees/.state`, `APP_PORT`, and `http://127.0.0.1:<APP_PORT>`.

- [ ] **Step 2: Run the focused sync test and verify the expected failure**

Run:

```sh
./tests/bin/template_sync_test.sh
```

Expected: FAIL because the documentation file and manifest entry do not exist yet.

- [ ] **Step 3: Write `docs/worktree.md`**

Document, in English:

- Why every Worktree has a unique Compose project name.
- The exact command forms and the fact that `switch` no longer stops another stack.
- `.worktrees/.state/<name>.env` and `.worktree-active` semantics.
- The exact port formula and canonical URL format `http://127.0.0.1:<APP_PORT>`.
- How to run two stacks simultaneously with `start <name>` and inspect them with `status --all`.
- How stale active state is diagnosed and how `prune` reclaims orphaned metadata.
- How the allocation lock records a PID, rejects live locks, and recovers a stale lock after a crashed allocator.
- The standard Compose variable contract and the fact that consumer Compose files must map those variables.
- That root ownership, `user:` mappings, extra forwarded ports, and Playwright URLs remain consumer-owned.
- That legacy stacks using the old shared project name must be stopped before first state allocation.

Use these examples:

```sh
./bin/worktree start readings-filters
./bin/worktree start bulk-reading-entry
./bin/worktree status --all
./bin/worktree stop readings-filters
./bin/worktree prune
```

- [ ] **Step 4: Register the file as template-owned**

Add this exact row to `template-manifest.tsv` near the other shared documentation entries:

```text
template-owned	docs/worktree.md
```

- [ ] **Step 5: Run documentation and repository checks**

Run:

```sh
./tests/bin/template_sync_test.sh
git diff --check
```

Expected: `all tests passed` and no whitespace errors.

- [ ] **Step 6: Commit the documentation contract**

```sh
git add docs/worktree.md template-manifest.tsv tests/bin/template_sync_test.sh
git commit -m "docs: document parallel worktree stacks"
```

## Task 5: Update Template Guidance And Release Metadata

**Files:**
- Modify: `AGENTS.md`
- Modify: `VERSION`
- Modify: `CHANGELOG.md`
- Test: `tests/bin/template_sync_test.sh`

**Interfaces:**
- Consumes: the final command semantics and documentation contract from Tasks 1-4.
- Produces: an accurate template checkout guide and release metadata for the public lifecycle change.

- [ ] **Step 1: Add documentation assertions for the changed guidance**

Extend `tests/bin/template_sync_test.sh` with checks that the real `AGENTS.md`
contains `Multiple worktree stacks can run at the same time`,
`switch` is described as non-destructive, and `CHANGELOG.md` contains a
`[0.2.0]` heading. The test must also assert that `VERSION` contains exactly
`0.2.0`.

- [ ] **Step 2: Run the focused test and verify the expected failure**

Run:

```sh
./tests/bin/template_sync_test.sh
```

Expected: FAIL because the current guide still describes one shared stack and
the release metadata is still at `0.1.1`.

- [ ] **Step 3: Update `AGENTS.md` without changing its ownership**

Replace the current examples and lines 46-47 as follows:

```markdown
./bin/worktree start <name>                # start one named stack
./bin/worktree start <name> --fresh        # start + migrate:fresh --seed
./bin/worktree create <name>               # new worktree + bootstrap from main
./bin/worktree create <name> --existing    # worktree for existing branch
./bin/worktree switch <name>               # select/start target, keep other stacks
./bin/worktree stop <name>                 # stop only the named stack
./bin/worktree status --all                # show all stack states and ports
```

Document that multiple Worktree stacks may run simultaneously, every stack
uses an isolated Compose project and port group, and the canonical URL is
`http://127.0.0.1:<APP_PORT>`. Keep `AGENTS.md` out of `template-manifest.tsv`;
this update applies only to the template checkout's own operating guide.

- [ ] **Step 4: Record the release metadata**

Replace `VERSION` with:

```text
0.2.0
```

Add this entry at the top of `CHANGELOG.md`:

```markdown
## [0.2.0] - 2026-08-08

### Added

- Parallel Worktree Sail stacks with isolated Compose project names and persisted port groups.
- Named lifecycle commands, stale-state reporting, and orphaned-state pruning.

### Changed

- `switch` starts the selected Worktree without stopping other running stacks.
- Worktree-managed HTTP access uses explicit `APP_PORT` values instead of an implicit port 80 fallback.

### Migration

- Stop legacy single-stack containers before the first state allocation, then use `bin/worktree status --all` to verify the new project and port assignments.
```

- [ ] **Step 5: Run the metadata checks**

Run:

```sh
./tests/bin/template_sync_test.sh
git diff --check
```

Expected: `all tests passed` and no whitespace errors.

- [ ] **Step 6: Commit the guidance and release metadata**

```sh
git add AGENTS.md VERSION CHANGELOG.md tests/bin/template_sync_test.sh
git commit -m "docs: update worktree guidance for parallel stacks"
```

## Task 6: Full Session Verification

**Files:**
- Modify: none unless a verification failure identifies a defect in Tasks 1-5.

- [ ] **Step 1: Run all template shell tests**

```sh
./tests/bin/project_config_test.sh
./tests/bin/template_sync_test.sh
./tests/bin/container_test.sh
./tests/bin/worktree_test.sh
```

Expected: every script prints `all tests passed`.

- [ ] **Step 2: Run ShellCheck when available**

```sh
shellcheck bin/container bin/container-lib.sh bin/project-config.sh \
  bin/template-sync bin/worktree bin/worktree-lib.sh tests/bin/*.sh
```

Expected: exit status 0. If the command is unavailable, record that environment limitation; do not replace it with an unreviewed host installation.

- [ ] **Step 3: Review the complete diff and working tree**

```sh
git diff --check
git status --short
git log --oneline -10
git diff HEAD~5..HEAD --stat
```

Confirm that the session changed only the shared Worktree library, CLI, Worktree tests, Worktree documentation, manifest, this template checkout's `AGENTS.md`, `VERSION`, and `CHANGELOG.md`. Do not modify consumer-owned Compose, user mapping, root-owned files, or E2E configuration.

- [ ] **Step 4: Record the Session 2 handoff**

Before starting Session 2, confirm these Session 1 interfaces exist and are tested:

```text
load_worktree_state
ensure_worktree_state
run_worktree_sail
start_for_worktree <name> <path>
stop_for_worktree <name> <path>
bootstrap <name>
```

The Session 2 plan must then change bootstrap dependency failures to leave the target stack running, add supported Compose-file discovery, and add the partial-bootstrap regression tests described in the design spec. It must not reintroduce a global `8080` gate or cross-Worktree rollback.
