---
name: consumer-runtime-adapter
description: Create or modify a consumer-owned bin/consumer runtime adapter for a project that uses the template Worktree Orchestrator. Use when a consumer must integrate Laravel, Sail, Compose, PHP, Composer, npm, Vite, Livewire, or worker lifecycle behavior with the generic template contract.
---

# Consumer Runtime Adapter

The template is a stack-independent Worktree **Orchestrator**. It manages Git
Worktrees, generic named host-port allocation, persisted state, environment
preparation, and lifecycle dispatch. All project-specific runtime behavior is
owned by a consumer **Adapter**: an executable `bin/consumer` in the target
Worktree root.

Read `docs/runtime-hooks.md` for the exact hook, environment, and exit-code
contract before writing any code. The adapter must never modify the
template-owned Worktree implementation.

## Contract Summary

The Orchestrator invokes `bin/consumer <hook>` in the target Worktree with a
controlled environment:

- Required hooks: `bootstrap`, `start`, `stop`.
- Optional hooks: `status`, `reset`. Unsupported optional hooks exit `2`.
- The adapter receives `WORKTREE_NAME`, `WORKTREE_INSTANCE_NAME`,
  `WORKTREE_PATH`, `WORKTREE_ROOT`, `WORKTREE_STATE_FILE`, `WORKTREE_ENV_FILE`,
  and one `WORKTREE_PORT_<PROFILE>` variable per configured port profile entry.
  Only `PATH` and `HOME` are preserved from the caller.
- The adapter owns Composer, Artisan, Sail, Compose, npm, Vite, Livewire, and
  worker behavior. The Orchestrator never invokes a framework command.

## Workflow

1. **Inspect the Laravel consumer.** Read the consumer's `composer.json`,
   `package.json`, `vite.config.*`, `docker-compose.yml` (or `compose.yaml`),
   `resources/js`, and `.env.example`/`.env.template`. Note every runtime
   command currently owned by the template or the consumer's shell scripts.

2. **Identify what must move into `bin/consumer`.** Move Composer dependency
   installation, Artisan key generation and reset logic, Sail/Compose startup
   and shutdown, npm/Vite build and dev-server behavior, Livewire asset
   handling, and worker processes into the adapter. Do not copy stack logic
   into the template.

3. **Map the generic context.** Map `WORKTREE_INSTANCE_NAME` to the consumer's
   Compose project identity and each `WORKTREE_PORT_<PROFILE>` to the consumer's
   environment variables (for example Sail's `APP_PORT`, `VITE_PORT`,
   `FORWARD_DB_PORT`, `FORWARD_REDIS_PORT`). Validate required variables and
   reject missing context with a clear diagnostic.

4. **Keep hooks idempotent and isolated.** Hooks must succeed when rerun on an
   already prepared or running target, must affect only the addressed
   Worktree, and must never use a shared PID file or stop another Worktree's
   processes.

5. **Test the adapter with mocked external commands.** Write shell tests that
   replace `sail`, `composer`, `npm`, `artisan`, and `docker` with mock
   executables. Assert the exact command lines, the exported environment, the
   working directory, exit-code propagation, unsupported-optional-hook status
   `2`, idempotence, and isolation between Worktrees. Never invoke the real
   framework toolchain in tests.

## Acceptance Criteria

- `bin/consumer` is executable and handles `bootstrap`, `start`, and `stop`;
  `status` and `reset` are implemented or exit `2`.
- Every framework command (Composer, Artisan, Sail, Compose, npm, Vite,
  Livewire, workers) runs only through the adapter.
- The adapter reads only the documented `WORKTREE_*` context and never assumes
  variables from the caller's environment.
- All adapter tests pass with mocked external commands.
- The template-owned Worktree implementation and `docs/runtime-hooks.md` are
  not modified by the adapter work.
