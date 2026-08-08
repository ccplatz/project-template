# Template Synchronization

This document is the authoritative process for releasing this template and
synchronizing its shared files into consumer projects.

## Ownership

Every path in `template-manifest.tsv` has one of three ownership strategies:

| Strategy | Meaning |
| --- | --- |
| `template-owned` | The template is the source of truth. `bin/template-sync` copies updates into consumers and detects local conflicts. |
| `project-config` | The file is required by shared tooling but is configured by each consumer. Synchronization reports it and never overwrites it. |
| `project-owned` | The consumer is the source of truth. Project-specific documentation, configuration, and application code stay in the consumer. |

Project-specific changes stay in the project. Generic fixes that should benefit
all consumers return to the template as changes to a `template-owned` file.
Do not make a local project customization in a template-owned file and expect it
to survive a future synchronization without a conflict.

## Consumer Configuration

New projects initialize their local configuration from the example:

```sh
cp .template/project.conf.example .template/project.conf
${EDITOR:-vi} .template/project.conf
```

The file contains a single project identifier:

```sh
PROJECT_NAME=my-project
```

`PROJECT_NAME` is used as the Docker Compose project name. It must start with a
letter or number and contain only letters, numbers, `.`, `_`, or `-`.

## Synchronization Lock

After a successful synchronization, the consumer contains
`.template/template.lock`. It records the exact template state used for the
files, not just a release label:

```text
source=project-template
version=0.1.0
commit=0123456789abcdef0123456789abcdef01234567
```

`source` is the template checkout name, `version` is read from `VERSION`, and
`commit` is the 40-character Git commit used as the previous synchronization
baseline. The lock is written only after all file checks and copies succeed.

## Consumer Updates

Run the command from the current template checkout and provide the consumer Git
worktree as the target:

```sh
./bin/template-sync --target /path/to/my-project --dry-run
./bin/template-sync --target /path/to/my-project
```

The first command reports planned copies, lock changes, and conflicts without
writing files. Conflicts cause a failure status without `--force`; use
`--force --dry-run` to show the planned overwrites without making changes.
Use the second command after reviewing the dry-run output.
The target must be a Git worktree. The command copies only `template-owned`
paths; `project-config` and `project-owned` paths are reported and left alone.

The template source checkout must be clean before synchronization. The command
rejects uncommitted or staged changes and non-ignored untracked files, because
the lock records `HEAD` while synchronization reads the current checkout. Run
`git status --porcelain --untracked-files=normal` in the template checkout and
resolve any reported entries before retrying. Ignored untracked files do not
prevent synchronization. The check runs before any target file or lock change.

If a consumer file differs from both the current template and the content at
the locked commit, synchronization stops with a conflict and leaves that file
and the lock unchanged. Resolve the change in the project or template, then
retry. `--force` is an explicit exception for an intentional overwrite:

```sh
./bin/template-sync --target /path/to/my-project --force
```

`--force` does not disable path or source validation, and symlink or directory
conflicts remain non-overwritable.

## Template Releases

A release follows this order:

1. Change the template and update `CHANGELOG.md`.
2. Run the complete test and static-check commands.
3. Bump `VERSION` to the next semantic version.
4. Commit the release and create an annotated tag.
5. Synchronize consumer projects and review their conflicts.

For example:

```sh
./tests/bin/project_config_test.sh
./tests/bin/template_sync_test.sh
./tests/bin/container_test.sh
./tests/bin/worktree_test.sh
shellcheck bin/container bin/container-lib.sh bin/project-config.sh \
  bin/template-sync bin/worktree bin/worktree-lib.sh tests/bin/*.sh
printf '1.1.0\n' > VERSION
git diff --check
git add -A
git diff --cached --name-status  # Review all intended docs, scripts, tests, and metadata
git commit -m 'Release template 1.1.0'
git tag -a v1.1.0 -m 'Template 1.1.0'
./bin/template-sync --target /path/to/my-project --dry-run
./bin/template-sync --target /path/to/my-project
```

The release tag and the lock commit make it possible to identify the exact
template baseline used by every consumer.

## Major-Version Migrations

A major-version release may change ownership, file formats, script interfaces,
or migration rules. Read the matching `CHANGELOG.md` entry before syncing. Do
not use `--force` as a substitute for a major-version migration: classify each
local difference, apply the documented migration, and then run a dry-run and a
normal synchronization.

## First Migration of Existing Consumers

The first migration of the existing `finance` and `consumption` consumers is a
separate follow-up step. Updating or releasing the template does not
automatically change either consumer. Run and review each migration
independently; do not combine them in an unattended loop.

For each consumer without a `.template/template.lock`, first create its local
configuration and set its project name. Do this before starting the dry-run or
the actual synchronization.

For `finance`:

```sh
template_checkout=/path/to/project-template
finance_checkout=/path/to/finance
cp "$template_checkout/.template/project.conf.example" "$finance_checkout/.template/project.conf"
printf 'PROJECT_NAME=finance\n' > "$finance_checkout/.template/project.conf"
"$template_checkout/bin/template-sync" --target "$finance_checkout" --dry-run
```

For `consumption`:

```sh
template_checkout=/path/to/project-template
consumption_checkout=/path/to/consumption
cp "$template_checkout/.template/project.conf.example" "$consumption_checkout/.template/project.conf"
printf 'PROJECT_NAME=consumption\n' > "$consumption_checkout/.template/project.conf"
"$template_checkout/bin/template-sync" --target "$consumption_checkout" --dry-run
```

After reviewing the dry-run, run the actual synchronization separately for
each consumer:

```sh
./bin/template-sync --target /path/to/finance
./bin/template-sync --target /path/to/consumption
```

Treat these as two separate operations, and review every reported conflict in
each output individually. Classify every local difference as one of:

- keep the consumer change and move it out of a `template-owned` path or merge
  it manually;
- move a generic improvement back into the template; or
- intentionally overwrite the consumer file with the reviewed template version.

Do not create `.template/template.lock` manually or initialize it while any
conflict is still unreviewed. A dry-run never writes the lock. Resolve or
document the chosen action for every conflict before synchronizing. For a
reviewed migration, run the sync separately for the selected consumer; use
`--force` only when the reviewed conflicts are intentional overwrites:

```sh
./bin/template-sync --target /path/to/finance --force
./bin/template-sync --target /path/to/consumption --force
```

Do not run the `--force` command for a consumer until all of that consumer's
conflicts have been reviewed. The successful synchronization creates that
consumer's initial `.template/template.lock`; it does not alter the other
consumer or make future consumer changes automatically.

## Required Checks

Run all four template tests and the shell checks before a release or after a
sync implementation change:

```sh
./tests/bin/project_config_test.sh
./tests/bin/template_sync_test.sh
./tests/bin/container_test.sh
./tests/bin/worktree_test.sh
shellcheck bin/container bin/container-lib.sh bin/project-config.sh \
  bin/template-sync bin/worktree bin/worktree-lib.sh tests/bin/*.sh
git diff --check
```
