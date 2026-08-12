# Parallel Worktrees

The Worktree helper gives every named Worktree an isolated state record and a
reserved group of host ports. Project-specific lifecycle behavior belongs to
the executable `bin/consumer` adapter in each Worktree.

## Commands

```sh
./bin/worktree create <name> [--existing]
./bin/worktree bootstrap <name>
./bin/worktree start [<name>] [--fresh]
./bin/worktree stop [<name>]
./bin/worktree switch <name> [--fresh]
./bin/worktree status [<name>]
./bin/worktree status --all
./bin/worktree reset [<name>]
./bin/worktree prune
```

`--fresh` is a deprecated alias for the reset operation on `start` and
`switch`. Explicit names always address only the requested Worktree. Commands
without a name use `.worktree-active`; `switch` starts its target without
stopping any other Worktree.

## Consumer Hooks

`bootstrap`, `start`, `stop`, `status`, and `reset` dispatch to the target's
`bin/consumer` executable. The adapter receives one positional argument, the
hook name, and receives the generic `WORKTREE_*` context through its
environment. See [runtime-hooks.md](runtime-hooks.md) for the hook contract.

An explicit `bootstrap` does not change `.worktree-active`. `create` updates the
active pointer only after the target has bootstrapped successfully. A failed
target operation leaves the active pointer unchanged.

## State And Ports

The selected Worktree state is persisted in
`.worktrees/.state/<name>.env`. It records the Worktree name, an isolated
instance name, and the configured generic port profiles. State files are local
metadata and must not be committed. The source configuration uses
`WORKTREE_PORT_PROFILE` and `WORKTREE_PORT_STRIDE` to define those profiles.

For group index `n`, each configured port uses its profile base plus
`n * WORKTREE_PORT_STRIDE`. The allocator checks persisted reservations and
host availability while holding an atomic PID lock. A live lock is rejected; a
stale lock left by a crashed allocator is removed and recovered.

## Running Multiple Worktrees

Start each named Worktree independently and inspect all assignments with
`status --all`:

```sh
./bin/worktree start readings-filters
./bin/worktree start bulk-reading-entry
./bin/worktree status --all
./bin/worktree stop readings-filters
./bin/worktree prune
```

`status` always reports generic Worktree metadata and appends the consumer's
status output when state is configured. It does not infer generic state from
consumer output. A valid Worktree without state is reported as `unconfigured`.
Stale active state is diagnosed instead of selecting another Worktree.
`prune` removes only state files whose Worktree is no longer registered with
Git.
