#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
sync_script="$script_dir/../../bin/template-sync"
manifest="$script_dir/../../template-manifest.tsv"
failures=0

assert_eq() {
    local expected=$1 actual=$2 message=${3:-values differ}
    if [ "$expected" != "$actual" ]; then
        printf 'not ok - %s\nexpected: %s\nactual: %s\n' "$message" "$expected" "$actual" >&2
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$message"
    fi
}

assert_contains() {
    local expected=$1 actual=$2 message=${3:-output contains expected text}
    case "$actual" in
        *"$expected"*) printf 'ok - %s\n' "$message" ;;
        *)
            printf 'not ok - %s\nexpected to contain: %s\nactual: %s\n' \
                "$message" "$expected" "$actual" >&2
            failures=$((failures + 1))
            ;;
    esac
}

assert_file_contains() {
    local file=$1 expected=$2 message=${3:-file contains expected text}
    if [ ! -f "$file" ]; then
        printf 'not ok - %s\nfile missing: %s\n' "$message" "$file" >&2
        failures=$((failures + 1))
        return
    fi
    assert_contains "$expected" "$(<"$file")" "$message"
}

assert_file_order() {
    local file=$1 message=$2 remaining needle
    shift 2
    remaining=$(<"$file")
    for needle in "$@"; do
        case "$remaining" in
            *"$needle"*) remaining=${remaining#*"$needle"} ;;
            *)
                printf 'not ok - %s\nmissing or out of order: %s\n' \
                    "$message" "$needle" >&2
                failures=$((failures + 1))
                return
                ;;
        esac
    done
    printf 'ok - %s\n' "$message"
}

assert_failure_contains() {
    local expected=$1
    shift
    local output actual
    if output=$("$@" 2>&1); then actual=0; else actual=$?; fi
    assert_eq 1 "$actual" "status of $*"
    assert_contains "$expected" "$output" "diagnostic of $*"
}

if [ ! -x "$sync_script" ] || [ ! -f "$manifest" ]; then
    printf 'not ok - sync command and manifest exist\n' >&2
    exit 1
fi

if release_output=$("$script_dir/../../bin/template-release-check" 2>&1); then
    release_status=0
else
    release_status=$?
fi
assert_eq 0 "$release_status" 'template release metadata is consistent'
assert_contains 'Template-Release' "$release_output" \
    'template release check reports the current release'

real_manifest_version=0
real_manifest_changelog=0
real_manifest_sync_docs=0
real_manifest_worktree_docs=0
real_manifest_project_config=0
real_manifest_readme=0
real_manifest_runtime_hooks=0
real_manifest_consumer_skill=0
real_manifest_container=0
real_manifest_container_lib=0
while IFS=$'\t' read -r strategy path || [ -n "${strategy:-}" ]; do
    [[ -z "${strategy:-}" || "$strategy" == \#* ]] && continue
    if [ "$path" = VERSION ]; then
        real_manifest_version=1
    fi
    if [ "$path" = CHANGELOG.md ]; then
        [ "$strategy" = template-owned ] && real_manifest_changelog=1
    fi
    if [ "$path" = docs/template-sync.md ]; then
        [ "$strategy" = template-owned ] && real_manifest_sync_docs=1
    fi
    if [ "$path" = docs/worktree.md ]; then
        [ "$strategy" = template-owned ] && real_manifest_worktree_docs=1
    fi
    if [ "$path" = .template/project.conf ]; then
        [ "$strategy" = project-config ] && real_manifest_project_config=1
    fi
    if [ "$path" = README.md ]; then
        [ "$strategy" = project-owned ] && real_manifest_readme=1
    fi
    if [ "$path" = docs/runtime-hooks.md ]; then
        [ "$strategy" = template-owned ] && real_manifest_runtime_hooks=1
    fi
    if [ "$path" = .opencode/skills/consumer-runtime-adapter/SKILL.md ]; then
        [ "$strategy" = template-owned ] && real_manifest_consumer_skill=1
    fi
    if [ "$path" = bin/container ] && [ "$strategy" = template-owned ]; then
        real_manifest_container=1
    fi
    if [ "$path" = bin/container-lib.sh ] && [ "$strategy" = template-owned ]; then
        real_manifest_container_lib=1
    fi
    if [ "$strategy" = template-owned ] \
        && { [ ! -f "$script_dir/../../$path" ] || [ -L "$script_dir/../../$path" ]; }; then
        printf 'not ok - real manifest path exists: %s\n' "$path" >&2
        failures=$((failures + 1))
    fi
done < "$manifest"
assert_eq 1 "$real_manifest_version" 'real manifest includes VERSION'
assert_eq 1 "$real_manifest_changelog" 'real manifest includes template-owned CHANGELOG.md'
assert_eq 1 "$real_manifest_sync_docs" \
    'real manifest includes template-owned docs/template-sync.md'
assert_eq 1 "$real_manifest_worktree_docs" \
    'real manifest includes template-owned docs/worktree.md'
assert_eq 1 "$real_manifest_project_config" \
    'real manifest includes project-config .template/project.conf'
assert_eq 1 "$real_manifest_readme" \
    'real manifest keeps README.md project-owned'
assert_eq 1 "$real_manifest_runtime_hooks" \
    'real manifest includes template-owned docs/runtime-hooks.md'
assert_eq 1 "$real_manifest_consumer_skill" \
    'real manifest includes the consumer runtime adapter skill'
assert_eq 0 "$real_manifest_container" \
    'real manifest removes bin/container'
assert_eq 0 "$real_manifest_container_lib" \
    'real manifest removes bin/container-lib.sh'
assert_file_contains "$script_dir/../../CHANGELOG.md" '[0.1.1]' \
    'changelog records the initial release'
assert_file_contains "$script_dir/../../docs/template-sync.md" 'template-owned' \
    'sync documentation defines template ownership'
assert_file_contains "$script_dir/../../docs/worktree.md" 'status --all' \
    'worktree documentation defines status-all inspection'
assert_file_contains "$script_dir/../../docs/worktree.md" '.worktrees/.state' \
    'worktree documentation defines persisted state'
assert_file_contains "$script_dir/../../docs/worktree.md" 'WORKTREE_PORT_PROFILE' \
    'worktree documentation defines generic managed ports'
assert_file_contains "$script_dir/../../docs/runtime-hooks.md" 'WORKTREE_PORT_<PROFILE>' \
    'runtime hook documentation defines generic port context'
for contract_file in README.md docs/runtime-hooks.md; do
    assert_file_contains "$script_dir/../../$contract_file" 'bin/consumer' \
        "$contract_file documents the consumer adapter"
    assert_file_contains "$script_dir/../../$contract_file" 'WORKTREE_PORT_PROFILE' \
        "$contract_file documents generic port profiles"
    assert_file_contains "$script_dir/../../$contract_file" '.env.example' \
        "$contract_file documents .env.example handling"
    assert_file_contains "$script_dir/../../$contract_file" '.env.template' \
        "$contract_file documents .env.template handling"
    assert_file_contains "$script_dir/../../$contract_file" 'Orchestrator/Adapter boundary' \
        "$contract_file documents the Orchestrator/Adapter boundary"
done
assert_file_contains "$script_dir/../../AGENTS.md" \
    'Multiple worktree stacks can run at the same time' \
    'agent guide documents parallel worktree stacks'
assert_file_contains "$script_dir/../../AGENTS.md" \
    'switch' 'agent guide documents non-destructive switching'
assert_file_contains "$script_dir/../../CHANGELOG.md" '[0.3.0]' \
    'changelog records the parallel stack release'
assert_eq '0.4.3' "$(<"$script_dir/../../VERSION")" \
    'VERSION records the worktree environment release'
assert_file_contains "$script_dir/../../docs/template-sync.md" '.template/template.lock' \
    'sync documentation defines the lock file'
assert_file_contains "$script_dir/../../docs/template-sync.md" \
    'source checkout must be clean' \
    'sync documentation requires a clean source checkout'
assert_file_contains "$script_dir/../../docs/template-sync.md" '--dry-run' \
    'sync documentation defines dry-run behavior'
assert_file_contains "$script_dir/../../docs/template-sync.md" 'major-version' \
    'sync documentation defines major-version migrations'
assert_file_contains "$script_dir/../../docs/template-sync.md" \
    'bin/template-release-check' \
    'sync documentation requires release consistency checks'
assert_file_order "$script_dir/../../docs/template-sync.md" \
    'finance migration bootstraps project configuration before sync' \
    'For `finance`:' \
    'template_checkout=/path/to/project-template' \
    'finance_checkout=/path/to/finance' \
    'cp "$template_checkout/.template/project.conf.example" "$finance_checkout/.template/project.conf"' \
    "printf 'PROJECT_NAME=finance\\n' > \"\$finance_checkout/.template/project.conf\"" \
    '"$template_checkout/bin/template-sync" --target "$finance_checkout" --dry-run'
assert_file_order "$script_dir/../../docs/template-sync.md" \
    'consumption migration bootstraps project configuration before sync' \
    'For `consumption`:' \
    'template_checkout=/path/to/project-template' \
    'consumption_checkout=/path/to/consumption' \
    'cp "$template_checkout/.template/project.conf.example" "$consumption_checkout/.template/project.conf"' \
    "printf 'PROJECT_NAME=consumption\\n' > \"\$consumption_checkout/.template/project.conf\"" \
    '"$template_checkout/bin/template-sync" --target "$consumption_checkout" --dry-run'
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
template="$root/template"
target="$root/target"
mkdir -p "$template/bin" "$template/.template" "$target/.template"

git_init() {
    local repository=$1
    git -C "$repository" init -q -b main
    git -C "$repository" config user.email test@example.com
    git -C "$repository" config user.name 'Template Sync Test'
}

git_init "$template"
git_init "$target"

real_target="$root/real-target"
real_template="$root/real-template"
mkdir -p "$real_template"
while IFS=$'\t' read -r strategy path || [ -n "${strategy:-}" ]; do
    [[ -z "${strategy:-}" || "$strategy" == \#* ]] && continue
    if [ "$strategy" = template-owned ]; then
        mkdir -p "$real_template/$(dirname -- "$path")"
        cp -p "$script_dir/../../$path" "$real_template/$path"
    fi
done < "$manifest"
git_init "$real_template"
git -C "$real_template" add .
git -C "$real_template" commit -q -m 'clean real manifest source'
mkdir -p "$real_target/.template"
git_init "$real_target"
printf 'PROJECT_NAME=real-target\n' > "$real_target/.template/project.conf"
git -C "$real_target" add .
git -C "$real_target" commit -q -m 'real-manifest target'
if real_manifest_output=$(
    "$real_template/bin/template-sync" --target "$real_target" --dry-run 2>&1
); then
    real_manifest_status=0
else
    real_manifest_status=$?
fi
assert_eq 0 "$real_manifest_status" 'real manifest accepts consumer configuration'
assert_contains 'project-config: .template/project.conf' "$real_manifest_output" \
    'real manifest reports consumer configuration'

assert_failure_contains 'Template-Checkout' "$real_template/bin/template-sync" \
    --target "$real_template"
mkdir -p "$real_template/nested-target"
assert_failure_contains 'Template-Checkout' "$real_template/bin/template-sync" \
    --target "$real_template/nested-target"
rmdir "$real_template/nested-target"

cp "$sync_script" "$template/bin/template-sync"
chmod +x "$template/bin/template-sync"
printf '1.2.3\n' > "$template/VERSION"
printf 'template-owned\tshared.txt\ntemplate-owned\tcopy.txt\nproject-config\t.template/project.conf\nproject-owned\tapp.txt\n' \
    > "$template/template-manifest.tsv"
printf 'shared version one\n' > "$template/shared.txt"
printf 'copy version one\n' > "$template/copy.txt"
printf 'PROJECT_NAME=template\n' > "$template/.template/project.conf"
printf 'template application\n' > "$template/app.txt"
git -C "$template" add .
git -C "$template" commit -q -m 'template version one'
first_commit=$(git -C "$template" rev-parse HEAD)
assert_eq 'shared version one' "$(git -C "$template" show "$first_commit:shared.txt")" \
    'previous template content is available through git show'

duplicate_target="$root/duplicate-target"
mkdir -p "$duplicate_target/.template"
git_init "$duplicate_target"
printf 'duplicate target sentinel\n' > "$duplicate_target/.template/sentinel"
git -C "$duplicate_target" add .
git -C "$duplicate_target" commit -q -m 'duplicate target baseline'
printf 'project-owned\tshared.txt\ntemplate-owned\tshared.txt\nproject-config\tshared.txt\n' \
    > "$template/template-manifest.tsv"
git -C "$template" add template-manifest.tsv
git -C "$template" commit -q -m 'duplicate manifest path'
if duplicate_output=$("$template/bin/template-sync" --target "$duplicate_target" 2>&1); then
    duplicate_status=0
else
    duplicate_status=$?
fi
assert_eq 1 "$duplicate_status" \
    'duplicate manifest paths fail independently of strategy'
assert_contains 'Doppelter Manifest-Pfad' "$duplicate_output" \
    'duplicate manifest paths report a clear diagnostic'
[ ! -e "$duplicate_target/shared.txt" ] \
    && printf 'ok - duplicate manifest paths do not copy a target file\n' \
    || { printf 'not ok - duplicate manifest paths copied a target file\n' >&2; failures=$((failures + 1)); }
[ ! -e "$duplicate_target/.template/template.lock" ] \
    && printf 'ok - duplicate manifest paths do not write a lock\n' \
    || { printf 'not ok - duplicate manifest paths wrote a lock\n' >&2; failures=$((failures + 1)); }

    > "$template/template-manifest.tsv"
git -C "$template" add template-manifest.tsv
git -C "$template" commit -q -m 'restore manifest after duplicate-path test'

printf 'ignored-source.txt\n' > "$template/.gitignore"
printf 'template-owned\tignored-source.txt\n' > "$template/template-manifest.tsv"
printf 'ignored source version\n' > "$template/ignored-source.txt"
git -C "$template" add .gitignore template-manifest.tsv
git -C "$template" commit -q -m 'ignored source manifest fixture'
ignored_source_target="$root/ignored-source-target"
mkdir -p "$ignored_source_target/.template"
git_init "$ignored_source_target"
if ignored_source_output=$("$template/bin/template-sync" --target "$ignored_source_target" 2>&1); then
    ignored_source_status=0
else
    ignored_source_status=$?
fi
assert_eq 1 "$ignored_source_status" \
    'ignored untracked template-owned source fails synchronization'
assert_contains 'nicht in HEAD versioniert' "$ignored_source_output" \
    'ignored untracked source reports missing HEAD version'
[ ! -e "$ignored_source_target/ignored-source.txt" ] \
    && printf 'ok - ignored untracked source is not copied\n' \
    || { printf 'not ok - ignored untracked source was copied\n' >&2; failures=$((failures + 1)); }
[ ! -e "$ignored_source_target/.template/template.lock" ] \
    && printf 'ok - ignored untracked source does not write a lock\n' \
    || { printf 'not ok - ignored untracked source wrote a lock\n' >&2; failures=$((failures + 1)); }

rm -f "$template/.gitignore" "$template/ignored-source.txt"
printf 'template-owned\tshared.txt\ntemplate-owned\tcopy.txt\nproject-config\t.template/project.conf\nproject-owned\tapp.txt\n' \
    > "$template/template-manifest.tsv"
git -C "$template" add -A
git -C "$template" commit -q -m 'restore manifest after ignored-source test'
first_commit=$(git -C "$template" rev-parse HEAD)
assert_eq 'shared version one' "$(git -C "$template" show "$first_commit:shared.txt")" \
    'restored template baseline content is available through git show'

printf 'bad-version\n' > "$template/VERSION"
assert_failure_contains 'major.minor.patch' "$template/bin/template-sync" --target "$target"
printf '1.2.3\n' > "$template/VERSION"

printf 'template-owned\n' > "$template/template-manifest.tsv"
assert_failure_contains 'Ungültige Manifest-Zeile' "$template/bin/template-sync" --target "$target"
printf 'template-owned\tshared.txt\ntemplate-owned\tcopy.txt\nproject-config\t.template/project.conf\nproject-owned\tapp.txt\n' \
    > "$template/template-manifest.tsv"
assert_failure_contains 'Verwendung:' "$template/bin/template-sync" --unknown-option

printf 'template-owned\t../outside.txt\n' > "$template/template-manifest.tsv"
assert_failure_contains 'Unsicherer Manifest-Pfad' "$template/bin/template-sync" --target "$target"
for noncanonical_path in ./shared.txt dir/./shared.txt dir//shared.txt shared.txt/; do
    printf 'template-owned\t%s\n' "$noncanonical_path" > "$template/template-manifest.tsv"
    assert_failure_contains 'Nicht-kanonischer Manifest-Pfad' \
        "$template/bin/template-sync" --target "$target"
done
printf 'template-owned\tshared.txt\ntemplate-owned\tcopy.txt\nproject-config\t.template/project.conf\nproject-owned\tapp.txt\n' \
    > "$template/template-manifest.tsv"

printf 'PROJECT_NAME=target\n' > "$target/.template/project.conf"
printf 'local application\n' > "$target/app.txt"
git -C "$target" add .
git -C "$target" commit -q -m 'target baseline'

printf 'dirty source version\n' > "$template/shared.txt"
printf 'staged source version\n' > "$template/copy.txt"
git -C "$template" add copy.txt
printf 'untracked source version\n' > "$template/untracked-source.txt"
if dirty_source_output=$("$template/bin/template-sync" --target "$target" 2>&1); then
    dirty_source_status=0
else
    dirty_source_status=$?
fi
assert_eq 1 "$dirty_source_status" \
    'dirty template source prevents synchronization'
assert_contains 'sauber' "$dirty_source_output" \
    'dirty template source reports a clear checkout diagnostic'
[ ! -e "$target/shared.txt" ] \
    && printf 'ok - dirty source does not copy template-owned files\n' \
    || { printf 'not ok - dirty source copied a template-owned file\n' >&2; failures=$((failures + 1)); }
[ ! -e "$target/.template/template.lock" ] \
    && printf 'ok - dirty source does not write a lock\n' \
    || { printf 'not ok - dirty source wrote a lock\n' >&2; failures=$((failures + 1)); }
rm -f "$template/untracked-source.txt"
git -C "$template" reset -q HEAD -- copy.txt
printf 'copy version one\n' > "$template/copy.txt"
printf 'shared version one\n' > "$template/shared.txt"
rm -f "$target/shared.txt" "$target/copy.txt" "$target/.template/template.lock"

for index_flag in assume-unchanged skip-worktree; do
    index_flag_target="$root/$index_flag-target"
    mkdir -p "$index_flag_target/.template"
    git_init "$index_flag_target"
    printf 'PROJECT_NAME=%s\n' "$index_flag" > "$index_flag_target/.template/project.conf"
    git -C "$index_flag_target" add .
    git -C "$index_flag_target" commit -q -m "$index_flag target baseline"
    printf 'hidden source version\n' > "$template/shared.txt"
    git -C "$template" update-index "--$index_flag" shared.txt
    assert_failure_contains 'HEAD' "$template/bin/template-sync" \
        --target "$index_flag_target"
    [ ! -e "$index_flag_target/shared.txt" ] \
        && printf 'ok - %s source change is not copied\n' "$index_flag" \
        || { printf 'not ok - %s source change was copied\n' "$index_flag" >&2; failures=$((failures + 1)); }
    [ ! -e "$index_flag_target/.template/template.lock" ] \
        && printf 'ok - %s source change does not write a lock\n' "$index_flag" \
        || { printf 'not ok - %s source change wrote a lock\n' "$index_flag" >&2; failures=$((failures + 1)); }
    git -C "$template" update-index "--no-$index_flag" shared.txt
    printf 'shared version one\n' > "$template/shared.txt"
done

initial_output=$("$template/bin/template-sync" --target "$target")
assert_contains 'template-owned: shared.txt' "$initial_output" \
    'initial sync reports the copied template-owned file'
assert_contains 'template-owned: copy.txt' "$initial_output" \
    'initial sync reports every copied template-owned file'
assert_contains 'project-config: .template/project.conf' "$initial_output" \
    'initial sync reports project configuration'
assert_contains 'project-owned: app.txt' "$initial_output" \
    'initial sync reports project-owned file'
assert_eq 'shared version one' "$(<"$target/shared.txt")" \
    'initial sync copies template-owned file'
assert_eq 'copy version one' "$(<"$target/copy.txt")" \
    'initial sync copies the second template-owned file'
assert_eq 'local application' "$(<"$target/app.txt")" \
    'initial sync preserves project-owned file'
assert_eq 'PROJECT_NAME=target' "$(<"$target/.template/project.conf")" \
    'initial sync preserves project configuration'
expected_lock=$(printf 'source=template\nversion=1.2.3\ncommit=%s' "$first_commit")
assert_eq "$expected_lock" \
    "$(<"$target/.template/template.lock")" 'initial sync writes the lock'

lock_before=$(<"$target/.template/template.lock")
printf 'shared version two\n' > "$template/shared.txt"
printf 'copy version two\n' > "$template/copy.txt"
git -C "$template" add shared.txt
git -C "$template" add copy.txt
git -C "$template" commit -q -m 'template version two'
second_commit=$(git -C "$template" rev-parse HEAD)

printf 'target modification before dry-run\n' > "$target/shared.txt"
if dry_run_output=$("$template/bin/template-sync" --target "$target" --dry-run 2>&1); then
    dry_run_status=0
else
    dry_run_status=$?
fi
assert_eq 1 "$dry_run_status" 'dry-run reports conflicts with failure status'
assert_contains 'would copy template-owned: copy.txt' "$dry_run_output" \
    'dry-run reports every planned copy despite a conflict'
assert_contains 'conflict: shared.txt' "$dry_run_output" \
    'dry-run reports every conflict'
assert_contains 'would write .template/template.lock' "$dry_run_output" \
    'dry-run reports the planned lock change despite a conflict'
assert_eq 'target modification before dry-run' "$(<"$target/shared.txt")" \
    'dry-run does not copy files'
assert_eq 'copy version one' "$(<"$target/copy.txt")" \
    'dry-run does not copy other planned files'
assert_eq "$lock_before" "$(<"$target/.template/template.lock")" \
    'dry-run does not write the lock'

printf 'shared version one\n' > "$target/shared.txt"
update_output=$("$template/bin/template-sync" --target "$target")
assert_contains 'template-owned: shared.txt' "$update_output" \
    'sync reports replacement from the previous locked content'
assert_contains 'template-owned: copy.txt' "$update_output" \
    'sync replaces every unchanged target file from the previous commit'
assert_eq 'shared version two' "$(<"$target/shared.txt")" \
    'sync replaces unchanged target content from the previous commit'
expected_lock=$(printf 'source=template\nversion=1.2.3\ncommit=%s' "$second_commit")
assert_eq "$expected_lock" \
    "$(<"$target/.template/template.lock")" 'sync updates the lock'

printf 'target modification\n' > "$target/shared.txt"
conflict_lock=$(<"$target/.template/template.lock")
if conflict_output=$("$template/bin/template-sync" --target "$target" 2>&1); then
    conflict_status=0
else
    conflict_status=$?
fi
assert_eq 1 "$conflict_status" 'changed target causes a conflict'
assert_contains 'conflict: shared.txt' "$conflict_output" \
    'conflict output identifies the changed file'
assert_eq 'target modification' "$(<"$target/shared.txt")" \
    'conflict leaves the target file unchanged'
assert_eq "$conflict_lock" "$(<"$target/.template/template.lock")" \
    'conflict leaves the lock unchanged'

force_output=$("$template/bin/template-sync" --target "$target" --force)
assert_contains 'template-owned: shared.txt' "$force_output" \
    'force reports the overwritten conflict'
assert_eq 'shared version two' "$(<"$target/shared.txt")" \
    'force overwrites the conflicting target file'
assert_eq 'copy version two' "$(<"$target/copy.txt")" \
    'force leaves the other template-owned file synchronized'
expected_lock=$(printf 'source=template\nversion=1.2.3\ncommit=%s' "$second_commit")
assert_eq "$expected_lock" \
    "$(<"$target/.template/template.lock")" 'force keeps the current source lock'

second_sync_output=$("$template/bin/template-sync" --target "$target")
assert_contains 'no changes' "$second_sync_output" 'second sync is a no-op'
assert_eq 'shared version two' "$(<"$target/shared.txt")" \
    'second sync leaves the template-owned file unchanged'
assert_eq 'local application' "$(<"$target/app.txt")" \
    'second sync leaves the project-owned file unchanged'

printf 'changed shared\n' > "$target/shared.txt"
printf 'changed copy\n' > "$target/copy.txt"
multi_conflict_lock=$(<"$target/.template/template.lock")
if multi_conflict_output=$("$template/bin/template-sync" --target "$target" 2>&1); then
    multi_conflict_status=0
else
    multi_conflict_status=$?
fi
assert_eq 1 "$multi_conflict_status" 'multiple conflicts fail without writing the lock'
assert_contains 'conflict: shared.txt' "$multi_conflict_output" \
    'multiple-conflict output identifies the first file'
assert_contains 'conflict: copy.txt' "$multi_conflict_output" \
    'multiple-conflict output identifies the second file'
assert_eq "$multi_conflict_lock" "$(<"$target/.template/template.lock")" \
    'multiple conflicts leave the lock unchanged'

target_without_lock="$root/target-without-lock"
mkdir -p "$target_without_lock/.template"
git_init "$target_without_lock"
printf 'pre-existing shared\n' > "$target_without_lock/shared.txt"
printf 'pre-existing copy\n' > "$target_without_lock/copy.txt"
git -C "$target_without_lock" add .
git -C "$target_without_lock" commit -q -m 'target without template lock'
if no_lock_output=$("$template/bin/template-sync" --target "$target_without_lock" 2>&1); then
    no_lock_status=0
else
    no_lock_status=$?
fi
assert_eq 1 "$no_lock_status" 'existing files without a lock cause conflicts'
assert_contains 'conflict: shared.txt' "$no_lock_output" \
    'missing-lock output identifies the first existing file'
assert_contains 'conflict: copy.txt' "$no_lock_output" \
    'missing-lock output identifies the second existing file'
[ ! -e "$target_without_lock/.template/template.lock" ] \
    && printf 'ok - missing-lock conflict does not write a lock\n' \
    || { printf 'not ok - missing-lock conflict wrote a lock\n' >&2; failures=$((failures + 1)); }

mkdir -p "$template/nested"
printf 'nested version one\n' > "$template/nested/file.txt"
printf 'template-owned\tshared.txt\ntemplate-owned\tcopy.txt\ntemplate-owned\tnested/file.txt\nproject-config\t.template/project.conf\nproject-owned\tapp.txt\n' \
    > "$template/template-manifest.tsv"
git -C "$template" add template-manifest.tsv nested/file.txt
git -C "$template" commit -q -m 'template nested file'

outside="$root/outside"
mkdir -p "$outside"
printf 'outside sentinel\n' > "$outside/sentinel"

printf 'hardlink target sentinel\n' > "$target/shared.txt"
hardlink_file="$outside/shared-hardlink"
ln "$target/shared.txt" "$hardlink_file"
hardlink_output=$($template/bin/template-sync --target "$target" --force)
assert_contains 'template-owned: shared.txt' "$hardlink_output" \
    'force reports the hardlinked template-owned replacement'
assert_eq 'shared version two' "$(<"$target/shared.txt")" \
    'force replaces the hardlinked target file'
assert_eq 'hardlink target sentinel' "$(<"$hardlink_file")" \
    'force preserves a hardlink outside the target project'

symlink_target="$root/symlink-target"
mkdir -p "$symlink_target/.template"
git_init "$symlink_target"
ln -s "$outside/sentinel" "$symlink_target/shared.txt"
git -C "$symlink_target" add .
git -C "$symlink_target" commit -q -m 'target final symlink'
assert_failure_contains 'Unsicherer Zielpfad' "$template/bin/template-sync" \
    --target "$symlink_target" --force
assert_eq 'outside sentinel' "$(<"$outside/sentinel")" \
    'force never writes through a final target symlink'
[ -L "$symlink_target/shared.txt" ] \
    && printf 'ok - final target symlink remains intact\n' \
    || { printf 'not ok - final target symlink was replaced\n' >&2; failures=$((failures + 1)); }

intermediate_target="$root/intermediate-target"
mkdir -p "$intermediate_target/.template"
git_init "$intermediate_target"
ln -s "$outside" "$intermediate_target/nested"
git -C "$intermediate_target" add .
git -C "$intermediate_target" commit -q -m 'target intermediate symlink'
assert_failure_contains 'Unsicherer Zielpfad' "$template/bin/template-sync" \
    --target "$intermediate_target" --force
[ ! -e "$intermediate_target/shared.txt" ] \
    && printf 'ok - intermediate target symlink prevents all copies\n' \
    || { printf 'not ok - intermediate target symlink allowed an earlier copy\n' >&2; failures=$((failures + 1)); }

lock_directory_target="$root/lock-directory-target"
mkdir -p "$lock_directory_target"
git_init "$lock_directory_target"
ln -s "$outside" "$lock_directory_target/.template"
git -C "$lock_directory_target" add .
git -C "$lock_directory_target" commit -q -m 'target lock directory symlink'
assert_failure_contains 'Unsicherer Zielpfad' "$template/bin/template-sync" \
    --target "$lock_directory_target" --force
[ ! -e "$outside/template.lock" ] \
    && printf 'ok - lock directory symlink prevents lock writes\n' \
    || { printf 'not ok - lock directory symlink allowed a lock write\n' >&2; failures=$((failures + 1)); }

lock_file_target="$root/lock-file-target"
mkdir -p "$lock_file_target/.template"
git_init "$lock_file_target"
ln -s "$outside/template.lock" "$lock_file_target/.template/template.lock"
git -C "$lock_file_target" add .
git -C "$lock_file_target" commit -q -m 'target lock file symlink'
assert_failure_contains 'Unsicherer Zielpfad' "$template/bin/template-sync" \
    --target "$lock_file_target" --force
[ ! -e "$outside/template.lock" ] \
    && printf 'ok - lock file symlink prevents lock writes\n' \
    || { printf 'not ok - lock file symlink allowed a lock write\n' >&2; failures=$((failures + 1)); }

directory_target="$root/directory-target"
mkdir -p "$directory_target/.template" "$directory_target/shared.txt"
printf 'directory target sentinel\n' > "$directory_target/.target"
git_init "$directory_target"
git -C "$directory_target" add .
git -C "$directory_target" commit -q -m 'target directory at template file path'
assert_failure_contains 'nicht überschreibbarer Konflikt' "$template/bin/template-sync" \
    --target "$directory_target" --force
[ -d "$directory_target/shared.txt" ] \
    && printf 'ok - force leaves directory target intact\n' \
    || { printf 'not ok - force replaced directory target\n' >&2; failures=$((failures + 1)); }
[ ! -e "$directory_target/.template/template.lock" ] \
    && printf 'ok - directory conflict does not write a lock\n' \
    || { printf 'not ok - directory conflict wrote a lock\n' >&2; failures=$((failures + 1)); }

printf 'source intermediate sentinel\n' > "$outside/file.txt"
rm -rf "$template/nested"
ln -s "$outside" "$template/nested"
source_intermediate_target="$root/source-intermediate-target"
mkdir -p "$source_intermediate_target/.template"
printf 'source intermediate target sentinel\n' > "$source_intermediate_target/.target"
git_init "$source_intermediate_target"
git -C "$source_intermediate_target" add .
git -C "$source_intermediate_target" commit -q -m 'source intermediate symlink target'
assert_failure_contains 'Unsicherer Quellpfad' "$template/bin/template-sync" \
    --target "$source_intermediate_target" --force
[ ! -e "$source_intermediate_target/shared.txt" ] \
    && printf 'ok - source intermediate symlink prevents all copies\n' \
    || { printf 'not ok - source intermediate symlink allowed a copy\n' >&2; failures=$((failures + 1)); }

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'all tests passed\n'
