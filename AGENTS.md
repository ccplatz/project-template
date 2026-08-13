# <PROJEKTNAME> — Agent Guide

## Further instructions

<!-- TODO: Entferne nicht benötigte instructions-Dateien aus der Liste unten. -->

Read the following files ONLY if your current task requires this information.
Use the read tool – only read a file when you absolutely need it.

- `docs/instructions/guardrails.instructions.md` — hard constraints, anti-patterns, learned rules (load when generating or modifying any code)
- `docs/instructions/domain.instructions.md` — <!-- TODO: Domänenmodell und Business-Logik -->
- `docs/instructions/testing.instructions.md` — <!-- TODO: Test-Konventionen -->
- `docs/instructions/laravel.instructions.md` — <!-- TODO: Laravel-Konventionen -->
- `docs/instructions/react.instructions.md` — <!-- TODO: Frontend-Konventionen (React, Vue, etc.) -->
- `docs/instructions/tailwind.instructions.md` — <!-- TODO: Styling-Konventionen -->
- `docs/instructions/design-system.instructions.md` — <!-- TODO: Design-Tokens und -System -->
- `docs/instructions/environments.instructions.md` — <!-- TODO: Dev/Staging/Prod-Setup -->
- `docs/superpowers/specs/` — design specs and rationale for existing features
  → consult when modifying an existing feature to understand prior design decisions
- `docs/superpowers/plans/` — implementation plans for completed work
  → consult when modifying an existing feature to understand prior design decisions

## Running commands

**Normal development entry point:** use `./bin/worktree start <name>` (or
`./bin/worktree create <name>` for a new worktree). The Worktree helper is a
stack-independent Orchestrator: it dispatches every lifecycle hook to the
consumer-owned `bin/consumer` adapter in the target worktree and never invokes
a framework command itself.

```sh
./bin/worktree create <name>                 # new worktree + bootstrap from main
./bin/worktree start <name>                  # start one named worktree
./bin/worktree start <name> --fresh          # start + reset the target
./bin/worktree switch <name>                 # select/start target, keep other stacks
./bin/worktree switch <name> --fresh         # switch + reset the target
./bin/worktree stop <name>                   # stop only the named worktree
./bin/worktree bootstrap <name>              # run the consumer bootstrap hook
./bin/worktree reset <name>                  # reset the named worktree
./bin/worktree status --all                  # show all stack states and ports
```

Each worktree provides its own executable `bin/consumer` adapter that owns the
project runtime (for example Laravel Sail or Compose). The adapter receives the
generic context through exported `WORKTREE_*` variables — `WORKTREE_NAME`,
`WORKTREE_INSTANCE_NAME`, `WORKTREE_PATH`, `WORKTREE_ROOT`,
`WORKTREE_STATE_FILE`, `WORKTREE_ENV_FILE`, and one `WORKTREE_PORT_<PROFILE>` per
configured port profile entry. See `docs/runtime-hooks.md` for the contract.

The `bin/worktree start`, `switch`, `create`, and `bootstrap` commands dispatch
to the target's consumer adapter. Run framework commands (`sail`, `composer`,
`artisan`, `npm`, Vite, workers) only through the consumer adapter, never
directly on the host and never through the Worktree helper.

Multiple worktree stacks can run at the same time. Each worktree uses an
isolated state record and a reserved group of generic host ports defined by
`WORKTREE_PORT_PROFILE` in `.template/project.conf`. `switch` is
non-destructive: it selects and starts the target without stopping another
running worktree. Ports and the canonical URL are owned by the consumer
adapter; use `status --all` to inspect assignments.

## Validation flow (run in order)

All framework commands below are examples for a Laravel/Sail consumer and run
through the consumer-owned `bin/consumer` adapter; the template never invokes
them directly. Adjust them to your consumer's runtime.

0. `./bin/guardrails-check` — automated code quality & security guardrails (see `.opencode/plugins/guardrails.ts`)
1. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail artisan test` — PHPUnit (feature + unit)
2. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail composer check` — PHPStan + Pint (format)
3. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail npm run test` — <!-- TODO: Frontend-Tests (Vitest o.ä.) -->
4. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail npm run check` — ESLint + TypeScript + Prettier
5. `npm run test:e2e` — <!-- TODO: E2E-Tests (Playwright o.ä.), nur auf dem Host -->
6. Release-Vorschlag vorlegen (Versionstyp + CHANGELOG-Zusammenfassung) und
   die Freigabe abwarten; erst nach expliziter Bestätigung
   `./bin/release <patch|minor|major>` ausführen (siehe Release-Workflow unten).

<!-- TODO: PHPStan-Level und andere Qualitätsregeln hier dokumentieren -->

## Key architecture

<!-- TODO: Architektur-Entscheidungen dokumentieren -->

- **Thin controllers** → Form Request → Service → API Resource. No business logic in controllers.
- **No Repository pattern.** Services use Eloquent directly.
- <!-- TODO: Datenmodell, Auth-Mechanismus, mehrschichtige Architektur -->

<!-- TODO: Frontend-Konventionen (Dark Mode, Framework, UI-Sprache, Formatierung) -->

## References

<!-- TODO: Zentrale Verzeichnisse und Dateien auflisten -->

- `app/Http/Controllers/` — thin controllers
- `app/Services/` — all business logic
- `app/Models/` — Eloquent models
- `resources/js/pages/` — page components
- `resources/js/services/` — API service modules
- `routes/api.php` — REST API

## Release-Workflow

Vor jedem Push wird eine neue Version angelegt, wenn template-owned Dateien
geändert wurden (siehe `template-manifest.tsv`). Der Release läuft über ein
Human Gate — er wird nie automatisch oder stillschweigend ausgelöst:

1. **Während der Feature-Arbeit:** Änderungen unter `## [Unreleased]` in
   `CHANGELOG.md` eintragen (die Sektion muss an der Spitze stehen).
2. **Nach bestandener Validierung (Human Gate):** Release-Vorschlag vorlegen
   — Versionstyp (`patch`/`minor`/`major`), Zielversion und CHANGELOG-Zusammen-
   fassung — und explizit auf Freigabe warten. Ohne ausdrückliche Bestätigung
   wird kein Release erstellt.
3. **Nach Freigabe:** `./bin/release <patch|minor|major>` ausführen. Das
   Skript bumpst `VERSION`, wandelt die `[Unreleased]`-Sektion in
   `## [X.Y.Z] - <Datum>` um, synchronisiert die Versionsreferenz in
   `tests/bin/template_sync_test.sh`, committet
   (`release: bump template to X.Y.Z`), prüft die Konsistenz mit
   `bin/template-release-check` (bei Fehler Rollback des Commits) und taggt
   anschließend annotiert (`vX.Y.Z`).
4. **Push (durch den Benutzer):** `git push --tags`.

Versionswahl: `patch` für Bugfixes, `minor` für neue Features, `major` für
Breaking Changes.
