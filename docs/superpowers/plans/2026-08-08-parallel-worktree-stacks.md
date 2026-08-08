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

---

## File Map

- Modify: `bin/worktree-lib.sh` — per-Worktree state, port allocation, Compose environment propagation, state listing, and orphan pruning.
- Modify: `bin/worktree` — named command parsing, non-destructive switching, explicit target resolution, and status output.
- Modify: `tests/bin/worktree_test.sh` — red/green regression coverage using the mock Sail command and isolated mock stack state.
- Modify: `tests/bin/template_sync_test.sh` — verify the shared Worktree documentation is registered and contains the required contract.
- Create: `docs/worktree.md` — template-owned operational documentation for the new Worktree model.
- Modify: `template-manifest.tsv` — register `docs/worktree.md` as `template-owned`.

The first implementation session does not modify consumer-owned `README.md`, `AGENTS.md`, Compose files, or E2E configuration. Session 2 will use the interfaces created here but has its own plan.

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
- Modify: `bin/worktree-lib.sh:13-79,132-146,148-219`
- Test: `tests/bin/worktree_test.sh:247-342`

**Interfaces:**
- Consumes: existing `worktree_root`, `PROJECT_NAME`, `validate_worktree_name`, and `port_is_available`.
- Produces: the state and allocation functions listed above; later tasks use their `WORKTREE_STATE_*` exports without reading state files directly.

- [ ] **Step 1: Write failing state and allocation tests**

Extend the temporary repository setup with the ignored state directory, create `feature-y` before the state assertions, and add these assertions after the existing Sail setup:

```bash
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

assert_status 0 ensure_worktree_state feature-y "$repo/.worktrees/feature-y"
assert_status 0 load_worktree_state feature-y
assert_eq 8090 "$WORKTREE_STATE_APP_PORT" 'second group uses the next HTTP range'
assert_eq 5183 "$WORKTREE_STATE_VITE_PORT" 'second group uses the next Vite range'
assert_eq 3316 "$WORKTREE_STATE_DB_PORT" 'second group uses the next database range'
assert_eq 6389 "$WORKTREE_STATE_REDIS_PORT" 'second group uses the next Redis range'

assert_status 0 load_worktree_state feature-x
assert_eq 8080 "$WORKTREE_STATE_APP_PORT" 'state reuses the first group after another allocation'
```

Add a busy-port case by creating the existing fake `nc` marker before allocating a new Worktree. The test must verify that the allocator skips the occupied group and writes the next available group. Add a malformed-state case that expects failure and verifies that no Sail command is invoked.

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

- [ ] **Step 4: Implement the allocation lock and port-group selection**

Add an atomic lock directory at `.worktrees/.state/.allocation-lock`. Acquire it with `mkdir`, return a clear retryable error if it already exists, and remove it with a `trap` in the allocating function. Do not remove another process's lock.

Implement the exact group calculation:

```bash
app_port=$((8080 + index * 10))
vite_port=$((5173 + index * 10))
db_port=$((3306 + index * 10))
redis_port=$((6379 + index * 10))
```

`worktree_state_port_available` must reject a port if any other `*.env` state file contains it or if `port_is_available` reports it occupied. Check all four ports before accepting a group. Scan indexes `0` through `99`; if none is available, fail before invoking Sail.

`ensure_worktree_state` must load and validate an existing state file without changing it. If no state exists, it must acquire the lock, rescan reservations and host ports, write the first available group, release the lock, and load the result. It may adopt a complete valid four-variable group from the target `.env` only if `APP_PORT >= 8080`, all values are decimal, and every port is unreserved and available; otherwise it must allocate from the formula above.

- [ ] **Step 5: Run the state tests and verify they pass**

Run:

```sh
./tests/bin/worktree_test.sh
```

Expected: all state, allocation, persistence, collision, and malformed-state assertions pass. Existing stack tests may still fail because the Sail calls do not yet load the state; those failures are fixed in Task 2.

- [ ] **Step 6: Commit the state foundation**

```sh
git add bin/worktree-lib.sh tests/bin/worktree_test.sh
git commit -m "feat: add per-worktree state and port allocation"
```

## Task 2: Propagate Isolated Compose Environment To Sail

**Files:**
- Modify: `bin/worktree:65-142`
- Modify: `bin/worktree-lib.sh:30-60,62-72,132-219`
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

Replace the single `STACK_STATE` marker in the mock with a directory keyed by Compose project name:

```bash
stack_state_dir="$repo/stack-running"
mkdir -p "$stack_state_dir"
state_marker="$stack_state_dir/${COMPOSE_PROJECT_NAME:?}"
```

Add tests that start `feature-x` and `feature-y`, assert both receive `up -d --remove-orphans`, assert their `PROJECT`, `APP`, `DB`, and `REDIS` values differ, then stop only `feature-x` and assert the `feature-y` marker remains.

Add a regression case where the fake `nc` reports port `8080` occupied but `start_for_worktree feature-x ...` still starts using the already persisted state. The state reservation is authoritative for an existing Worktree; the allocator only checks host availability when creating a new state.

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

Each function must call `ensure_worktree_state` before `up`, `ps`, `down`, or `artisan migrate:fresh`. `stack_is_running_for_worktree` may use the main checkout Sail fallback for incomplete bootstrap, but it must still load the target state and pass the target Compose project name and ports.

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
assert_contains "$(run_command status --all)" 'orphan'
assert_status 0 run_command prune
assert_not_exists "$repo/.worktrees/.state/orphan.env"
```

Update existing expectations so a failed `switch` never starts the previous Worktree as rollback. Add `stop feature-x` and `stop feature-y` assertions that verify only the named mock marker is removed.

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

For a valid Worktree without a state file, print `status: unconfigured` and the command needed to initialize it. For a stale active name, print the stale diagnostic and return failure only for implicit `status`; `status <valid-name>` remains usable.

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
- Modify: `template-manifest.tsv:8-19`
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

## Task 5: Full Session Verification

**Files:**
- Modify: none unless a verification failure identifies a defect in Tasks 1-4.

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
git diff HEAD~4..HEAD --stat
```

Confirm that the session changed only the shared Worktree library, CLI, Worktree tests, Worktree documentation, and manifest. Do not modify consumer-owned Compose, user mapping, root-owned files, or E2E configuration.

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
