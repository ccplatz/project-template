# Parallel Worktree Stacks

The Worktree helper gives every named Worktree its own Docker Compose project. A
unique project name keeps containers, networks, and volumes isolated, while a
reserved port group keeps host access isolated as well.

## Commands

```sh
./bin/worktree create <name> [--existing]
./bin/worktree bootstrap <name>
./bin/worktree start [<name>] [--fresh]
./bin/worktree stop [<name>]
./bin/worktree switch <name> [--fresh]
./bin/worktree status [<name>]
./bin/worktree status --all
./bin/worktree prune
```

`switch` selects and starts its target without stopping any other running
Worktree stack. The `.worktree-active` file is only a convenience pointer for
commands without an explicit name; it is never used to choose an unrelated
stack to stop.

## Bootstrap

`bootstrap <name>` is a resumable, safe operation. It skips valid artifacts and
can be rerun with the same command after a failed dependency or key step. Its
sequence is:

1. Create `.env` from `.env.template` when `.env` is missing.
2. Validate a supported Compose filename before starting anything.
3. Load the existing Worktree state or allocate it when it does not exist.
4. Start only the target stack.
5. Install Composer dependencies when valid Composer/Sail artifacts are absent.
6. Verify the target Sail executable.
7. Install npm dependencies when `node_modules` is absent.
8. Generate `APP_KEY` only when it is empty.

The supported Compose filenames are exactly:

```text
compose.yaml
compose.yml
docker-compose.yml
docker-compose.yaml
```

Bootstrap does not generate or symlink a Compose file. A missing supported
Compose file fails during preflight, before `up` runs. If starting the target
fails, cleanup stops only that target stack and does not affect other running
stacks. Composer, npm, and `APP_KEY` failures leave the target stack running;
rerun `./bin/worktree bootstrap <name>` to retry, with already valid artifacts
skipped.

An explicit `bootstrap <name>` does not change `.worktree-active`. `create`
updates `.worktree-active` only after the complete bootstrap succeeds.

## State And Ports

The selected Worktree state is persisted in
`.worktrees/.state/<name>.env`. It records the Worktree name, the Compose
project name `<PROJECT_NAME>-<name>`, and the managed `APP_PORT`, `VITE_PORT`,
`FORWARD_DB_PORT`, and `FORWARD_REDIS_PORT` values. State files are local
metadata and must not be committed.

For group index `n`, ports are allocated as follows:

```text
APP_PORT            = 8080 + (n * 10)
VITE_PORT           = 5173 + (n * 10)
FORWARD_DB_PORT     = 3306 + (n * 10)
FORWARD_REDIS_PORT  = 6379 + (n * 10)
```

The allocator checks persisted reservations and host availability while holding
an atomic PID lock. A live lock is rejected; a stale lock left by a crashed
allocator is removed and recovered. The canonical HTTP URL is
`http://127.0.0.1:<APP_PORT>`. Port 80 is never an implicit Worktree fallback.

## Running Multiple Stacks

Start each named Worktree independently and inspect all assignments with
`status --all`:

```sh
./bin/worktree start readings-filters
./bin/worktree start bulk-reading-entry
./bin/worktree status --all
./bin/worktree stop readings-filters
./bin/worktree prune
```

`status` reports the Compose project, URL, managed ports, and whether the stack
is running. A valid Worktree without state is reported as `unconfigured`.
Stale active state is diagnosed instead of selecting another Worktree. `prune`
removes only state files whose Worktree is no longer registered with Git; it
does not stop containers, remove Worktrees, or prune Docker resources.

## Compose Contract

Named Sail operations explicitly pass `COMPOSE_PROJECT_NAME`, `APP_PORT`,
`VITE_PORT`, `FORWARD_DB_PORT`, and `FORWARD_REDIS_PORT`. Consumer-owned Compose
files must map these variables to their service and host-port definitions.
Root ownership, `user:` mappings, extra forwarded ports, and Playwright URLs
remain consumer-owned and are not changed by the template Worktree helper.

Stop legacy stacks using the old shared Compose project name before the first
state allocation. Then use `status --all` to verify the new project and port
assignments.
