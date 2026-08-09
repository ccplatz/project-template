# Changelog

All notable changes to this template are documented here.

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
