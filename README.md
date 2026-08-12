# project-template

Bootstrap repository for new projects. Contains reusable infrastructure scripts,
configuration files, and OpenCode setup.

## What's included

### OpenCode setup
- `opencode.json` — OpenCode configuration with Superpowers plugin
- `AGENTS.md` — Agent Guide (to be filled in per project)
- `.opencode/plugins/guardrails.ts` — Automated guardrails plugin (file-edited, tool-execute-before, session-idle hooks)

### Worktree management (`bin/worktree`)

Git worktrees for parallel feature development. The helper manages worktree
creation, selection, persisted state, named host-port allocation, and lifecycle
dispatch. It is stack-independent: all project-specific runtime behavior
(Laravel, Sail, Compose, Composer, npm, Vite, workers) lives in a
consumer-owned `bin/consumer` adapter in each worktree.

```sh
./bin/worktree create <name> [--existing]   # new worktree + bootstrap from main
./bin/worktree bootstrap <name>             # run the consumer bootstrap hook
./bin/worktree start [<name>] [--fresh]     # start a named or active worktree
./bin/worktree stop [<name>]                # stop a named or active worktree
./bin/worktree switch <name> [--fresh]      # select and start a worktree
./bin/worktree status [<name>]              # show worktree metadata and status
./bin/worktree status --all                 # show all worktrees and assignments
./bin/worktree reset [<name>]               # reset a named or active worktree
./bin/worktree prune                        # remove orphaned state files
```

`--fresh` is a deprecated alias for `reset`. Multiple worktrees can run at the
same time; each uses an isolated state record and a reserved group of generic
host ports defined by `WORKTREE_PORT_PROFILE` in `.template/project.conf`. The
canonical access URL and port semantics are decided by the consumer adapter,
not by the template.

### Consumer adapter (`bin/consumer`)

Every worktree must provide an executable `bin/consumer` adapter that handles
the generic lifecycle hooks `bootstrap`, `start`, `stop` (required) and
`status`, `reset` (optional). The adapter receives the generic context through
exported `WORKTREE_*` environment variables, including `WORKTREE_PORT_<PROFILE>`
for each configured port profile entry.

The Orchestrator/Adapter boundary: the template owns worktrees, state, ports,
and dispatch; the consumer owns the runtime. See `docs/runtime-hooks.md` for
the full hook contract, environment preparation (`.env.example` /
`.env.template`), and Laravel/Sail and Laravel/Compose examples. Agent guidance
for building a consumer adapter lives in
`.opencode/skills/consumer-runtime-adapter/SKILL.md`.

### Configuration files
- `.editorconfig` — consistent editor settings (UTF-8, LF, 4-space indent)
- `.gitignore` / `.gitattributes` — Git configuration
- `.prettierrc` — Prettier with PHP plugin
- `.shellcheckrc` — ShellCheck configuration
- `.dockerignore` — Docker build exclusions
- `.env.template` — environment variable template

### Project instructions (`docs/instructions/`)

Stub files for project-specific AI instructions. Fill these in to give the coding
agent context about your project:

- `guardrails.instructions.md` — hard constraints, anti-patterns, learned rules. The most
  important file: loaded before every code change. Starts with generic best practices;
  grows with project-specific rules from actual problems encountered.
- `domain.instructions.md` — domain model, business rules, entities
- `testing.instructions.md` — test conventions and frameworks
- `laravel.instructions.md` — Laravel conventions (if applicable)
- `react.instructions.md` — frontend conventions (if applicable)
- `tailwind.instructions.md` — styling conventions (if applicable)
- `design-system.instructions.md` — design tokens and system
- `environments.instructions.md` — dev, staging, and production setup

Delete any that don't apply to your project and update `AGENTS.md` accordingly.

### Superpowers docs (`docs/superpowers/`)

Permanent documentation for design rationale and implementation history:

- `specs/` — Design specs with rationale for features. Create before implementation;
  consult when modifying existing features.
- `plans/` — Step-by-step implementation plans. Artifacts of completed or in-progress work.

### Tests
- `tests/bin/worktree_test.sh` — unit tests for the worktree orchestration script
- `tests/bin/project_config_test.sh` — unit tests for project configuration

### Guardrails (`bin/guardrails-check`)

Automated code quality and security checks for Laravel/Tailwind/TypeScript projects.
Runs 6 checks on every validation:

- **security_functions** — blocks `eval()`, `exec()`, `shell_exec()` etc. in `app/`
- **mass_assignment** — blocks `$guarded = []` in `app/Models/`
- **raw_sql** — warns on `DB::raw()` (verify input validation)
- **response_helpers** — blocks `response()->json()` in controllers (use API Resources)
- **typescript_any** — blocks `: any` / `as any` in TypeScript (use `unknown`)
- **phpstan_ignored** — warns on `@phpstan-ignore` (verify justification)

```sh
./bin/guardrails-check               # default: color output, exit 1 on failures
./bin/guardrails-check --ci          # machine-readable: FILE:LINE:CHECK:VIOLATION
./bin/guardrails-check --warn        # always exit 0 (warnings only)
```

Each check can be toggled on/off in the CONFIG block at the top of the script.
Works with an OpenCode plugin (`.opencode/plugins/guardrails.ts`) that runs checks
on file edits, blocks dangerous shell commands, and runs a full scan at session end.

## Usage

### 1. Create a new project

```sh
cp -r project-template my-new-project
cd my-new-project
```

### 2. Set the project name

Copy the project configuration example and set `PROJECT_NAME` to the project slug
(e.g. `my-project`):

```sh
cp .template/project.conf.example .template/project.conf
sed -i 's/^PROJECT_NAME=.*/PROJECT_NAME=my-project/' .template/project.conf
```

Read `docs/template-sync.md` before making future template updates.

### 3. Fill in AGENTS.md

Replace all `<!-- TODO -->` comments and `<PROJEKTNAME_ANZEIGE>` placeholders
with project-specific content. Fill in the architecture, frontend conventions,
and references sections. Remove any `docs/instructions/*` entries that don't apply.

`AGENTS.md` and `docs/instructions/*` are project-owned documentation. Their
placeholders are intentionally project-specific and must be filled in by the
new project; `bin/template-sync` does not rewrite them.

### 4. Fill in guardrails and project instructions

Start with `docs/instructions/guardrails.instructions.md` — add project-specific
hard constraints, code patterns, and domain invariants. This file grows with every
agent mistake: each time the agent does something wrong, add a rule so it doesn't
happen again.

Then edit the remaining stub files under `docs/instructions/` with your project's
conventions, domain model, testing setup, etc. Remove files that don't apply.

**For an existing project,** you can use an AI coding agent to populate the
instructions automatically. Copy the files to your project, then use a prompt like:

> Read the entire codebase thoroughly. Then fill in each file under
> `docs/instructions/` with project-specific conventions, architecture
> patterns, domain model, design system, testing setup, and deployment
> environments. Start with `guardrails.instructions.md` — extract all
> hard constraints, code patterns, and domain invariants from the existing
> code. Then populate the remaining instruction files. Base everything on
> what actually exists in the code — do not invent or assume conventions.
> Delete any instruction files that don't apply to this project.

### 5. Initialize the repository

```sh
git init
git add -A
git commit -m "Initial commit from project-template"
```

### 6. Run the tests

```sh
./tests/bin/project_config_test.sh
./tests/bin/worktree_test.sh
```

The worktree test requires a Git repository and a `bin/consumer` fixture.

## What this template does NOT include

- Framework code (Laravel, React, etc.)
- A consumer-owned `bin/consumer` adapter (the project must provide one)
- `compose.yaml` / `docker-compose.*.yml`
- `.env` (copied from the configured environment template)
- `vendor/`, `node_modules/`
- Project-specific content in `docs/instructions/` (stubs only)
