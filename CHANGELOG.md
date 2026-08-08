# Changelog

All notable changes to this template are documented here.

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
