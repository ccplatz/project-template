# project-template

Bootstrap repository for new projects. Contains reusable infrastructure scripts,
configuration files, and OpenCode setup.

## What's included

### OpenCode setup
- `opencode.json` — OpenCode configuration with Superpowers plugin
- `AGENTS.md` — Agent Guide (to be filled in per project)
- `.opencode/plugins/guardrails.ts` — Automated guardrails plugin (file-edited, tool-execute-before, session-idle hooks)

### Container management (`bin/container`)

Manage your staging/production Docker stack.

```sh
./bin/container start [--build]        # start the stack
./bin/container stop                   # stop the stack
./bin/container restart [--build]      # stop then start
./bin/container attach <short_name>    # shell into a running container
./bin/container status                 # show environment, compose file, services, networks
./bin/container ps                     # list project containers (docker ps with label filter)
./bin/container logs [service] [-f]    # tail logs for a service (or all)
```

**Recommended:** Add a shell alias so you can run `container` from anywhere in the project:

```sh
alias container='./bin/container'
```

Configuration is read from `.env` — set `ENVIRONMENT=staging` or `ENVIRONMENT=prod` to
pick the matching `docker-compose.{env}.yml`. External Docker networks listed in
`EXTERNAL_NETWORKS` (comma-separated) are created automatically on `start` and
cleaned up on `stop` if unused.

### Worktree management (`bin/worktree`)

Git worktrees for parallel feature development with Laravel Sail.
Bootstraps new worktrees (composer install, npm install, key:generate).

```sh
./bin/worktree create <name> [--existing]   # new worktree + bootstrap from main
./bin/worktree switch <name> [--fresh]      # switch active worktree
./bin/worktree start [--fresh]              # start the active worktree stack
./bin/worktree stop                         # stop the active worktree stack
./bin/worktree status                       # show active worktree name, path, branch, status
```

Only one worktree stack can run at a time (shared port `:8080`).

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
- `tests/bin/container_test.sh` — unit tests for the container script
- `tests/bin/worktree_test.sh` — unit tests for the worktree script

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

Replace every occurrence of `<PROJEKTNAME>` with the actual project slug (e.g. `my-project`):

```sh
PROJECT=my-project
sed -i "s/<PROJEKTNAME>/$PROJECT/g" \
    AGENTS.md \
    bin/container \
    bin/worktree \
    bin/worktree-lib.sh \
    .env.template \
    tests/bin/container_test.sh \
    tests/bin/worktree_test.sh
```

### 3. Fill in AGENTS.md

Replace all `<!-- TODO -->` comments and `<PROJEKTNAME_ANZEIGE>` placeholders
with project-specific content. Fill in the architecture, frontend conventions,
and references sections. Remove any `docs/instructions/*` entries that don't apply.

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
./tests/bin/container_test.sh
./tests/bin/worktree_test.sh
```

The worktree test requires a Git repository and a `compose.yaml` in the root.

## What this template does NOT include

- Framework code (Laravel, React, etc.)
- `compose.yaml` / `docker-compose.*.yml`
- `.env` (copied from template)
- `vendor/`, `node_modules/`
- Project-specific content in `docs/instructions/` (stubs only)
