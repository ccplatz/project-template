# Runtime Hooks

The template is an **Orchestrator**. It manages Git Worktrees, named host-port
allocation, persisted state, environment preparation, and lifecycle dispatch.
Every project-specific runtime — Laravel, Sail, Compose, Composer, npm, Vite,
workers — belongs to a consumer-owned **Adapter**. This is the
**Orchestrator/Adapter boundary**: the Orchestrator never owns or invokes a
project runtime, and the Adapter never owns worktrees, state, ports, or
dispatch.

Each Worktree must provide an executable `bin/consumer` at its root. The
Worktree helper invokes it from the target directory with exactly one
positional argument, the hook name:

```text
bin/consumer bootstrap
bin/consumer start
bin/consumer stop
bin/consumer status
bin/consumer reset
```

The Adapter owns all project-specific setup, startup, shutdown, status, and
reset behavior. The Orchestrator does not inspect the project's runtime,
service names, dependency artifacts, or application files. It never invokes a
framework command directly.

## Hook Contract

| Hook        | Required | Purpose                                        |
|-------------|----------|------------------------------------------------|
| `bootstrap` | yes      | Prepare dependencies and the target environment |
| `start`     | yes      | Start the project's runtime in the target       |
| `stop`      | yes      | Stop the project's runtime cleanly              |
| `status`    | optional | Report runtime status for `bin/worktree status`  |
| `reset`     | optional | Reset the project to a clean, runnable state    |

The adapter exits `0` on success. Required hooks must exit non-zero on any
failure. An optional hook that is not supported must exit with status `2` and
print an explanation; the CLI preserves that result. For `reset`, the CLI
additionally prints a pointer to this contract when the hook returns `2`.
Other optional hooks, such as `status`, pass their own explanation through
because the CLI appends their output verbatim. Any other non-zero exit from an
optional hook is treated as a failure. A missing adapter makes the Orchestrator
fail with a diagnostic that identifies the Worktree and this contract.

## Context Variables

The Orchestrator runs `bin/consumer <hook>` in the target Worktree with a
controlled environment. Only the following variables are exported:

```text
WORKTREE_NAME          the Worktree name
WORKTREE_INSTANCE_NAME the isolated instance name (consumer's project identity)
WORKTREE_PATH          absolute path of the target Worktree
WORKTREE_ROOT          absolute path of the main checkout
WORKTREE_STATE_FILE    absolute path of the persisted Worktree state file
WORKTREE_ENV_FILE      absolute path of the prepared target `.env`
WORKTREE_PORT_<PROFILE> one variable per configured port profile entry
```

`PATH` and `HOME` are preserved when set. No other environment variables are
passed. The adapter must not rely on variables inherited from the caller.

## Port Profiles

Port profiles are generic, semantic names defined by the consumer in
`.template/project.conf`:

```sh
WORKTREE_PORT_PROFILE="http=8080,frontend=5173,database=3306,cache=6379"
WORKTREE_PORT_STRIDE=10
```

For group index `n`, each configured port uses its profile base plus
`n * WORKTREE_PORT_STRIDE`. The Orchestrator validates the profile, reserves
every declared host port as one group, and exports each value as
`WORKTREE_PORT_<PROFILE>`. The consumer maps these generic names to its own
configuration. Ports are only allocated and tracked by the Orchestrator; the
consumer decides how to use them.

## Environment Template

The consumer configures an environment template:

```sh
WORKTREE_ENV_TEMPLATE=.env.template   # or .env.example
```

Before the first hook dispatch, the Orchestrator copies the configured
template (relative to the target) to `.env` only when `.env` is absent and the
template exists. If no template exists, `.env` is left absent and the consumer
decides whether it is required. The Orchestrator never rewrites unknown
application variables.

## Target Isolation And Idempotence

Every hook runs in the target Worktree directory with the target's own state
and port group. Commands never affect another Worktree, never use a shared PID
file, and never stop another Worktree's processes. `switch` starts its target
without stopping any other Worktree.

Hooks must be idempotent: running `bootstrap` or `start` on an already prepared
or running target must succeed without corrupting state. `reset` restores a
clean, runnable state and is safe to run on a stopped or unstarted target.

## Laravel/Sail Example

A Laravel consumer maps the generic context to Sail:

```sh
export COMPOSE_PROJECT_NAME=$WORKTREE_INSTANCE_NAME
export APP_PORT=$WORKTREE_PORT_HTTP
export VITE_PORT=$WORKTREE_PORT_FRONTEND
export FORWARD_DB_PORT=$WORKTREE_PORT_DATABASE
export FORWARD_REDIS_PORT=$WORKTREE_PORT_CACHE

start) ./vendor/bin/sail up -d ;;
stop)  ./vendor/bin/sail down ;;
```

`bootstrap` runs `composer install`, `npm install`, and `php artisan
key:generate` through Sail. `reset` stops the Sail stack, resets the database,
and reruns `bootstrap`. `status` reports the Sail stack and its mapped ports.

## Laravel/Compose Example

A consumer without Sail uses plain Docker Compose:

```sh
export COMPOSE_PROJECT_NAME=$WORKTREE_INSTANCE_NAME

start) docker compose up -d ;;
stop)  docker compose down ;;
```

The same isolation and idempotence rules apply. The Orchestrator provides the
generic context; the consumer owns the Compose project identity and command
mapping.

## Persistent Compose Resources

Consumer Compose stacks pin their project identity to the isolated Worktree
instance:

```sh
export COMPOSE_PROJECT_NAME=$WORKTREE_INSTANCE_NAME
```

`WORKTREE_INSTANCE_NAME` derives from `PROJECT_NAME` in
`.template/project.conf`, which is independent of the directory or repository
name. For every unnamed persistent resource, Compose derives the runtime name
from the project name as `<project>_<resource>`. When the pinned project name
differs from the one used when the stack was first created — for example after
a rename or a fresh `.template/project.conf` — `up` silently creates empty new
volumes and private networks while `down` no longer matches the running
containers: data appears to be gone, and cleanup silently does nothing.

**Rule:** persistent resources in consumer Compose files — named volumes and
private networks — MUST be pinned with `name:`. The `name:` is a fixed,
project-independent identifier and must never be derived from the project
name:

```yaml
# Wrong: Compose creates "<project>_db_data". Renaming the project orphans the
# data and a new, empty volume appears.
volumes:
  db_data: {}

# Right: the volume is always "consumption_db_data", regardless of the project.
volumes:
  db_data:
    name: consumption_db_data
```

## Recommended Compose Guards

The same project-identity pinning enables silent failures: `start` may create
a fresh, empty stack next to an existing one, and `stop` may match nothing
while the stack is still running. The adapter should guard both directions and
give services fixed, project-independent container names:

```yaml
services:
  app:
    container_name: consumption_app
```

- **Before `start`:** verify that every declared named volume exists
  (`docker volume inspect <name>`). If a volume is missing while the
  project-prefixed equivalent exists (for example `<old_project>_db_data`),
  warn explicitly — do not let Compose create an empty volume silently.
- **Before `start`:** check that no container with the expected fixed
  `container_name:` values is already running. If the stack is running, do not
  start a second, empty one; print a diagnostic that names the running
  containers and the identity mismatch instead.
- **Before `stop`/`down`:** if no container with the expected names is running
  but other Compose containers exist, warn that no stack was found under the
  pinned project identity instead of exiting silently.

These guards fail loudly with a message that identifies the mismatch and the
fix (check `COMPOSE_PROJECT_NAME` and `.template/project.conf`).
