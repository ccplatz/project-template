# Template Ownership

This repository is either the project template itself or a consumer project
that contains synchronized template files. Template files and project files
live side by side, so never infer ownership or project capabilities from a
file's location or from what the template contains.

## Source of truth

- `template-manifest.tsv` assigns every template-managed path exactly one
  strategy. It is the only source of truth for ownership.
- In a consumer, `.template/template.lock` records the synchronized template
  version and commit.
- A path that is not listed in the manifest is project-owned.

## Strategies

| Strategy | Exists in a consumer? | Who changes it |
| --- | --- | --- |
| `template-owned` | Yes, synchronized | The template. Generic fixes go back to the template. |
| `template-internal` | **No** | The template only. Never assume a consumer has it. |
| `template-retired` | No (removed by sync) | Nobody. Do not recreate it. |
| `project-config` | Yes, configured locally | The consumer. |
| `project-owned` | Yes | The consumer. |

## Rules

- Before making a claim about a file's ownership, look it up in
  `template-manifest.tsv` instead of guessing.
- Never assume a consumer has a capability (CI pipeline, release workflow,
  deployment, tests, framework) because the template has it. Verify it in the
  consumer's own files. Example: `.github/workflows/ci.yml` is
  `template-internal`; it tests the template and is never synchronized.
- In a consumer, do not make project-specific changes to `template-owned`
  files. They are overwritten or cause conflicts on the next
  `bin/template-sync`. Propose generic fixes as template changes instead.
- Sections marked "Template-only" in shared instructions do not apply in a
  consumer.
- In the template repository, every tracked file must be listed in the
  manifest; `bin/template-release-check` fails otherwise.
