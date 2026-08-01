#!/bin/bash

set -euo pipefail

# =============================================================================
# guardrails-check.sh — Automated code quality & security guardrails checker
#
# Usage:
#   ./guardrails-check.sh              # default: color output, exit 1 on failures
#   ./guardrails-check.sh --ci         # machine-readable: FILE:LINE:CHECK:VIOLATION
#   ./guardrails-check.sh --warn       # always exit 0, show warnings only
#
# Each check scans relevant files only (skips vendor/, node_modules/, storage/, .git/).
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIG — Enable/disable individual checks
# -----------------------------------------------------------------------------
CHECK_SECURITY_FUNCTIONS=1
CHECK_MASS_ASSIGNMENT=1
CHECK_RAW_SQL=1
CHECK_RESPONSE_HELPERS=1
CHECK_TYPESCRIPT_ANY=1
CHECK_PHPSTAN_IGNORED=1

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------
MODE_DEFAULT=0
MODE_CI=1
MODE_WARN=2

mode=$MODE_DEFAULT
failures=0
warnings=0
checks_skipped=0
checks_ok=0

for arg in "$@"; do
    case "$arg" in
        --ci) mode=$MODE_CI ;;
        --warn) mode=$MODE_WARN ;;
    esac
done

script_dir=$(cd "$(dirname "$0")" && pwd)
cd "$script_dir"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

RED=''
GREEN=''
YELLOW=''
NC=''

if [ "$mode" -eq "$MODE_DEFAULT" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
fi

check_pass() {
    local check_name=$1
    if [ "$mode" -eq "$MODE_CI" ]; then
        : # no output on pass in CI mode
    else
        printf "${GREEN}✅ %s${NC}\n" "$check_name"
    fi
    checks_ok=$((checks_ok + 1))
}

check_fail() {
    local check_name=$1
    local file=$2
    local line=$3
    local message=$4
    local is_warning=${5:-0}

    if [ "$mode" -eq "$MODE_CI" ]; then
        printf '%s:%s:%s:%s\n' "$file" "$line" "$check_name" "$message"
    else
        if [ "$is_warning" -eq 1 ]; then
            printf "${YELLOW}⚠️  %s — %s:%s — %s${NC}\n" "$check_name" "$file" "$line" "$message"
        else
            printf "${RED}❌ %s — %s:%s — %s${NC}\n" "$check_name" "$file" "$line" "$message"
        fi
    fi

    if [ "$is_warning" -eq 1 ]; then
        warnings=$((warnings + 1))
    else
        failures=$((failures + 1))
    fi
}

check_skip() {
    local check_name=$1
    local reason=$2
    if [ "$mode" -eq "$MODE_CI" ]; then
        : # no output on skip in CI mode
    else
        printf "${YELLOW}⏭️  %s skipped — %s${NC}\n" "$check_name" "$reason"
    fi
    checks_skipped=$((checks_skipped + 1))
}

# Check if a directory exists and contains files matching a pattern
dir_has_files() {
    local dir=$1
    local pattern=$2
    [ -d "$dir" ] && [ -n "$(find "$dir" -maxdepth 10 -name "$pattern" -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/storage/*' -not -path '*/.git/*' 2>/dev/null | head -1)" ]
}

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------

check_security_functions() {
    local dir="app"
    if ! dir_has_files "$dir" "*.php"; then
        check_skip "security_functions" "app/ directory not found or empty"
        return
    fi

    local matches
    matches=$(rg --no-heading --line-number \
        -g '*.php' \
        -g '!vendor/*' \
        -g '!storage/*' \
        -g '!.git/*' \
        '\b(eval|exec|shell_exec|passthru|system)\s*\(' "$dir" 2>/dev/null || true)

    if [ -z "$matches" ]; then
        check_pass "security_functions"
    else
        while IFS= read -r line; do
            local file clean_line
            file=$(echo "$line" | cut -d: -f1)
            clean_line=$(echo "$line" | cut -d: -f2)
            check_fail "security_functions" "$file" "$clean_line" "Potentially dangerous function call"
        done <<< "$matches"
    fi
}

check_mass_assignment() {
    local dir="app/Models"
    if ! dir_has_files "$dir" "*.php"; then
        check_skip "mass_assignment" "app/Models/ directory not found or empty"
        return
    fi

    local matches
    matches=$(rg --no-heading --line-number \
        -g '*.php' \
        '\$guarded\s*=\s*\[\s*\]' "$dir" 2>/dev/null || true)

    if [ -z "$matches" ]; then
        check_pass "mass_assignment"
    else
        while IFS= read -r line; do
            local file clean_line
            file=$(echo "$line" | cut -d: -f1)
            clean_line=$(echo "$line" | cut -d: -f2)
            check_fail "mass_assignment" "$file" "$clean_line" "\$guarded = [] disables mass assignment protection"
        done <<< "$matches"
    fi
}

check_raw_sql() {
    local matches
    matches=$(rg --no-heading --line-number \
        -g '*.php' \
        -g '!vendor/*' \
        -g '!storage/*' \
        -g '!.git/*' \
        'DB::raw\s*\(' . 2>/dev/null || true)

    if [ -z "$matches" ]; then
        check_pass "raw_sql"
    else
        while IFS= read -r line; do
            local file clean_line
            file=$(echo "$line" | cut -d: -f1)
            clean_line=$(echo "$line" | cut -d: -f2)
            check_fail "raw_sql" "$file" "$clean_line" "DB::raw() may allow SQL injection — ensure input is validated" 1
        done <<< "$matches"
    fi
}

check_response_helpers() {
    local dir="app/Http/Controllers"
    if ! dir_has_files "$dir" "*.php"; then
        check_skip "response_helpers" "app/Http/Controllers/ directory not found or empty"
        return
    fi

    local matches
    matches=$(rg --no-heading --line-number \
        -g '*.php' \
        'response\(\)\s*->\s*json\s*\(' "$dir" 2>/dev/null || true)

    if [ -z "$matches" ]; then
        check_pass "response_helpers"
    else
        while IFS= read -r line; do
            local file clean_line
            file=$(echo "$line" | cut -d: -f1)
            clean_line=$(echo "$line" | cut -d: -f2)
            check_fail "response_helpers" "$file" "$clean_line" "Use API Resources instead of response()->json()"
        done <<< "$matches"
    fi
}

check_typescript_any() {
    local dir="resources/js"
    if ! dir_has_files "$dir" "*.ts" && ! dir_has_files "$dir" "*.tsx"; then
        check_skip "typescript_any" "resources/js/ directory not found or empty"
        return
    fi

    local matches
    matches=$(rg --no-heading --line-number \
        -g '*.ts' -g '*.tsx' \
        -g '!node_modules/*' \
        '(: any|as any)' "$dir" 2>/dev/null || true)

    if [ -z "$matches" ]; then
        check_pass "typescript_any"
    else
        while IFS= read -r line; do
            local file clean_line
            file=$(echo "$line" | cut -d: -f1)
            clean_line=$(echo "$line" | cut -d: -f2)
            check_fail "typescript_any" "$file" "$clean_line" "Use 'unknown' instead of 'any' and narrow the type"
        done <<< "$matches"
    fi
}

check_phpstan_not_ignored() {
    local matches
    matches=$(rg --no-heading --line-number \
        -g '*.php' \
        -g '!vendor/*' \
        -g '!storage/*' \
        -g '!.git/*' \
        '@phpstan-ignore' . 2>/dev/null || true)

    if [ -z "$matches" ]; then
        check_pass "phpstan_ignored"
    else
        while IFS= read -r line; do
            local file clean_line
            file=$(echo "$line" | cut -d: -f1)
            clean_line=$(echo "$line" | cut -d: -f2)
            check_fail "phpstan_ignored" "$file" "$clean_line" "@phpstan-ignore suppresses type checking — verify it's justified" 1
        done <<< "$matches"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    if [ "$mode" -ne "$MODE_CI" ]; then
        echo "🔍 guardrails-check — scanning codebase..."
        echo ""
    fi

    [ "$CHECK_SECURITY_FUNCTIONS" -eq 1 ] && check_security_functions
    [ "$CHECK_MASS_ASSIGNMENT" -eq 1 ] && check_mass_assignment
    [ "$CHECK_RAW_SQL" -eq 1 ] && check_raw_sql
    [ "$CHECK_RESPONSE_HELPERS" -eq 1 ] && check_response_helpers
    [ "$CHECK_TYPESCRIPT_ANY" -eq 1 ] && check_typescript_any
    [ "$CHECK_PHPSTAN_IGNORED" -eq 1 ] && check_phpstan_not_ignored

    if [ "$mode" -ne "$MODE_CI" ]; then
        echo ""
        local total_failures=$((failures + warnings))
        if [ "$total_failures" -eq 0 ]; then
            printf "${GREEN}All checks passed (%d ok, %d skipped)${NC}\n" "$checks_ok" "$checks_skipped"
        else
            printf "${RED}%d violation(s) found (%d errors, %d warnings, %d ok, %d skipped)${NC}\n" \
                "$total_failures" "$failures" "$warnings" "$checks_ok" "$checks_skipped"
        fi
    fi

    if [ "$mode" -eq "$MODE_WARN" ]; then
        return 0
    fi

    local total_failures=$((failures + warnings))
    if [ "$total_failures" -gt 0 ]; then
        return 1
    fi
    return 0
}

main
