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
`./bin/worktree create <name>` for a new worktree). Direct `./vendor/bin/sail`
startup is a raw-Sail reference for an already active worktree, not the normal
development entry point. All PHP, Composer, NPM, and Artisan commands still run
through `./vendor/bin/sail`; never invoke them directly on the host.

```sh
./bin/worktree start <name>                  # start one named stack
./bin/worktree start <name> --fresh          # start + migrate:fresh --seed
./bin/worktree create <name>                 # new worktree + bootstrap from main
./bin/worktree create <name> --existing      # worktree for existing branch
./bin/worktree switch <name>                 # select/start target, keep other stacks
./bin/worktree switch <name> --fresh         # switch + migrate:fresh --seed
./bin/worktree stop <name>                   # stop only the named stack
./bin/worktree status --all                  # show all stack states and ports
COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail npm run dev # Vite HMR
COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail artisan <cmd> # any artisan command
COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail artisan test # all PHP tests
COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail composer <script> # composer scripts
```

The normal `bin/worktree start`, `switch`, `create`, and `bootstrap` commands
start the consumer's `npm run dev` script automatically when the frontend
artifacts are present. Run the Sail command manually only to restart or debug
the frontend process.

Multiple worktree stacks can run at the same time. Each stack uses an isolated
Compose project and port group. `switch` is non-destructive: it selects and
starts the target without stopping another running stack. The canonical URL is
`http://127.0.0.1:<APP_PORT>`; use `status --all` to inspect assignments.

## Validation flow (run in order)

0. `./bin/guardrails-check` — automated code quality & security guardrails (see `.opencode/plugins/guardrails.ts`)
1. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail artisan test` — PHPUnit (feature + unit)
2. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail composer check` — PHPStan + Pint (format)
3. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail npm run test` — <!-- TODO: Frontend-Tests (Vitest o.ä.) -->
4. `COMPOSE_PROJECT_NAME=<PROJEKTNAME> ./vendor/bin/sail npm run check` — ESLint + TypeScript + Prettier
5. `npm run test:e2e` — <!-- TODO: E2E-Tests (Playwright o.ä.), nur auf dem Host -->

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
