# Changelog

All notable changes to this template are documented here.

## [Unreleased]

### Added

- Document the Compose project-identity rule for consumer adapters in
  `docs/runtime-hooks.md` and the `consumer-runtime-adapter` skill: persistent
  resources (named volumes, private networks) must be pinned with `name:` and
  services with `container_name:`, and `start`/`stop` must warn about
  project-identity mismatches (missing volumes, running containers under
  another identity) instead of failing silently.
- Extend `tests/bin/template_sync_test.sh` with assertions that the pinned
  resource and guard rules stay documented.

## [0.4.7] - 2026-08-13

### Fixed

- Fix all ShellCheck error- and warning-level findings in `bin/` and `tests/bin/`
  (`export "${port_key?}"`, retry loop without unused variable, `: >` truncation,
  SC2218/SC2034 false positives documented with disable directives).
- Configure `.shellcheckrc` to disable intentional info-level patterns
  (SC2015, SC2016, SC2086, SC2094, SC2251) so ShellCheck passes cleanly.

## [0.4.6] - 2026-08-13

### Fixed

- Make `tests/bin/release_test.sh` executable so the CI workflow can run it.

### Added

- GitHub Actions CI workflow (`.github/workflows/ci.yml`) running ShellCheck,
  `bin/guardrails-check`, and all shell test suites on push to `main` and pull
  requests.

## [0.4.5] - 2026-08-13

### Changed

- Translate all German user-facing output, comments, and documentation to
  English; all scripts, tests, and docs are now fully English.
- Remove `docs/superpowers/plans/` and `docs/superpowers/specs/` from the
  template repository; the directories stay Git-ignored so no new plan or spec
  files can enter the template.
- Rename `<PROJEKTNAME>` and `<PROJEKTNAME_ANZEIGE>` placeholders to
  `<PROJECT_NAME>` and `<PROJECT_DISPLAY_NAME>`.

## [0.4.4] - 2026-08-13

### Added

- MIT license for template redistribution; `LICENSE` is now synchronized to
  consumers as a template-owned file.
- Document the English-only convention in `AGENTS.md` and translate the legacy
  German changelog entries.

## [0.4.3] - 2026-08-13

### Fixed

- `bin/release` verifies consistency before tagging and rolls back the release
  commit on failure; the tag is only created afterwards.
- The Unreleased gate in `bin/release` uses exact line matching.
- The dirty-tree check in `bin/release` also detects untracked files.
- Version synchronization in `bin/release` is scoped to
  `tests/bin/template_sync_test.sh` so the fixtures in `tests/bin/release_test.sh`
  stay stable.

### Added

- Tests for `bin/release` covering rollback, `major` bumps, VERSION formatting,
  and untracked-file detection.

## [0.4.2] - 2026-08-13

### Added

- `bin/release` creates new template releases in one step: `VERSION` bump,
  CHANGELOG header, commit, annotated `vX.Y.Z` tag, and consistency check via
  `bin/template-release-check`.
- Tests for `bin/release` in `tests/bin/release_test.sh`.
- Release workflow documented in `AGENTS.md`.

## [0.4.1] - 2026-08-12

### Fixed

- Port availability checks no longer silently report every port as free when
  `nc` is missing; the probe falls back to a bash `/dev/tcp` connection check.

## [0.4.0] - 2026-08-12

### Changed

- Make Worktree orchestration stack-independent through the consumer-owned
  `bin/consumer` lifecycle adapter.
- Replace fixed Laravel/Sail port variables with consumer-defined named port
  profiles and generic `WORKTREE_*` context variables.
- Move Docker container management out of the template core; consumers own their
  runtime services and stack-specific hooks.
- Add synchronized runtime-hook documentation and the consumer adapter skill.

### Migration

- Add `bin/consumer bootstrap`, `start`, and `stop` to each consumer. Implement
  optional `status` and `reset` hooks where applicable.
- Configure `WORKTREE_PORT_PROFILE`, `WORKTREE_PORT_STRIDE`, and
  `WORKTREE_ENV_TEMPLATE` in `.template/project.conf`.
- Synchronize template-owned files before using the new generic Worktree
  lifecycle in an existing consumer.

## [0.3.2] - 2026-08-11

### Added

- Start a consumer's `npm run dev` frontend automatically with the Worktree
  stack when frontend artifacts and a `dev` script are available.

## [0.3.1] - 2026-08-10

### Fixed

- Synchronize Worktree Compose project and port values into the target `.env`
  before Sail loads it.

### Added

- Add `bin/template-release-check` to detect template changes without a matching
  version and changelog update.

## [0.3.0] - 2026-08-09

### Added

- Resumable `bin/worktree bootstrap <name>` with artifact-aware Composer, npm,
  and application-key setup.
- Compose preflight discovery for `compose.yaml`, `compose.yml`,
  `docker-compose.yml`, and `docker-compose.yaml`.

### Changed

- Failed dependency and key-generation steps leave the target stack running for
  retry, while failed target startup cleans only that target project.
- `start`, `switch`, `status`, and `stop` recover safely when a target has
  incomplete Sail artifacts by using the main checkout Sail fallback where
  appropriate.

### Migration

- Synchronize each consumer separately with `bin/template-sync`, update its
  Compose mappings for `APP_PORT`, `VITE_PORT`, `FORWARD_DB_PORT`, and
  `FORWARD_REDIS_PORT`, then stop legacy containers before the first new state
  allocation.
- Retry incomplete consumer bootstraps with `bin/worktree bootstrap <name>`;
  valid dependency artifacts are preserved and reused.

## [0.2.0] - 2026-08-08

### Added

- Parallel Worktree Sail stacks with isolated Compose project names and persisted port groups.
- Named lifecycle commands, stale-state reporting, and orphaned-state pruning.

### Changed

- `switch` starts the selected Worktree without stopping other running stacks.
- Worktree-managed HTTP access uses explicit `APP_PORT` values instead of an implicit port 80 fallback.

### Migration

- Stop legacy single-stack containers before the first state allocation, then use `bin/worktree status --all` to verify the new project and port assignments.

## [0.1.1] - 2026-08-08

### Fixed

- Do not require `project-owned` files to exist in the template source during sync.
- Keep sync tests independent of project-owned README and instruction files.

## [0.1.0] - 2026-08-08

### Added

- Versioned template releases through `VERSION`.
- Manifest-driven synchronization with `bin/template-sync`.
- Consumer locks containing the template source, release version, and Git commit.
- Ownership rules and migration guidance in `docs/template-sync.md`.

### Migration

- New projects should copy `.template/project.conf.example` to
  `.template/project.conf`, set `PROJECT_NAME`, and follow the bootstrap steps in
  `README.md`.
- Existing projects should follow the baseline initialization procedure in
  `docs/template-sync.md` before their first synchronization.
