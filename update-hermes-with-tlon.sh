#!/usr/bin/env bash
# update-hermes-with-tlon.sh — portable safe Hermes update + Tlon patch reapply.
#
# Usage:
#   bash update-hermes-with-tlon.sh
#   bash update-hermes-with-tlon.sh --dry-run
#   bash update-hermes-with-tlon.sh --restart-gateway
#   HERMES_HOME=/path/to/.hermes bash update-hermes-with-tlon.sh
#   HERMES_AGENT=/path/to/hermes-agent PATCH=/path/to/tlon-pr.patch bash update-hermes-with-tlon.sh
#
# Design:
#   - Never lets `hermes update` restore local Tlon changes.
#   - Updates from a clean upstream branch, then reapplies Tlon deliberately.
#   - Preflights the Tlon patch in a disposable worktree before touching live files.
#   - Leaves gateway restart opt-in because it is a live service change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_AGENT="${HERMES_AGENT:-$HERMES_HOME/hermes-agent}"
PATCH="${PATCH:-$SCRIPT_DIR/tlon-pr.patch}"
APPLY_SCRIPT="${APPLY_SCRIPT:-$SCRIPT_DIR/apply-tlon.sh}"
BRANCH="${BRANCH:-tlon-apply}"
RESTART_GATEWAY=0
RUN_TESTS=1
DRY_RUN=0

usage() {
    cat <<EOF
Usage: bash $(basename "$0") [--dry-run] [--restart-gateway] [--no-tests] [--help]

Environment overrides:
  HERMES_HOME    Hermes home directory (default: \$HOME/.hermes)
  HERMES_AGENT   Hermes source checkout (default: \$HERMES_HOME/hermes-agent)
  PATCH          Tlon patch file (default: script directory/tlon-pr.patch)
  APPLY_SCRIPT   Tlon apply script (default: script directory/apply-tlon.sh)
  BRANCH         Patch branch name (default: tlon-apply)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --restart-gateway) RESTART_GATEWAY=1 ;;
        --no-tests) RUN_TESTS=0 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

find_hermes_cli() {
    if [ -x "$HERMES_AGENT/venv/bin/hermes" ]; then
        printf '%s\n' "$HERMES_AGENT/venv/bin/hermes"
    elif [ -x "$HERMES_AGENT/.venv/bin/hermes" ]; then
        printf '%s\n' "$HERMES_AGENT/.venv/bin/hermes"
    elif command -v hermes >/dev/null 2>&1; then
        command -v hermes
    else
        return 1
    fi
}

detect_base_branch() {
    if git show-ref --verify --quiet refs/heads/main; then
        printf 'main\n'
    elif git show-ref --verify --quiet refs/heads/master; then
        printf 'master\n'
    elif git symbolic-ref --quiet --short refs/remotes/origin/HEAD >/dev/null 2>&1; then
        git symbolic-ref --quiet --short refs/remotes/origin/HEAD | sed 's#^origin/##'
    else
        fail "no main/master branch found and origin/HEAD is unavailable"
    fi
}

check_clean() {
    if [ -n "$(git status --porcelain)" ]; then
        git status --short
        fail "working tree is not clean; commit/stash/restore before updating"
    fi
}

run_apply_script() {
    local args=()
    [ "$RUN_TESTS" -eq 0 ] && args+=(--no-tests)
    HERMES_HOME="$HERMES_HOME" \
    HERMES_AGENT="$HERMES_AGENT" \
    PATCH="$PATCH" \
    BRANCH="$BRANCH" \
        bash "$APPLY_SCRIPT" "${args[@]}"
}

run_apply_dry_run() {
    local args=(--dry-run)
    [ "$RUN_TESTS" -eq 0 ] && args+=(--no-tests)
    HERMES_HOME="$HERMES_HOME" \
    HERMES_AGENT="$HERMES_AGENT" \
    PATCH="$PATCH" \
    BRANCH="$BRANCH" \
        bash "$APPLY_SCRIPT" "${args[@]}"
}

echo "==> Checking prerequisites..."
[ -e "$HERMES_AGENT/.git" ] || fail "$HERMES_AGENT is not a git repo"
[ -f "$PATCH" ] || fail "$PATCH not found"
[ -f "$APPLY_SCRIPT" ] || fail "$APPLY_SCRIPT not found"
cd "$HERMES_AGENT"
check_clean

HERMES_CLI="$(find_hermes_cli)" || fail "no hermes CLI found in venv or PATH"
BASE_BRANCH="$(detect_base_branch)"
echo "==> Hermes agent: $HERMES_AGENT"
echo "==> Hermes CLI:   $HERMES_CLI"
echo "==> Patch:        $PATCH"
echo "==> Base branch:  $BASE_BRANCH"

ORIGINAL_BRANCH="$(git branch --show-current)"
CURRENT="$ORIGINAL_BRANCH"
restore_original_branch_for_dry_run() {
    if [ "$DRY_RUN" -eq 1 ] && [ -n "${ORIGINAL_BRANCH:-}" ] && [ "$(git branch --show-current)" != "$ORIGINAL_BRANCH" ]; then
        git switch "$ORIGINAL_BRANCH" >/dev/null
        echo "==> Restored original branch: $ORIGINAL_BRANCH"
    fi
}

if [ "$CURRENT" = "$BRANCH" ]; then
    echo "==> Switching from $BRANCH to $BASE_BRANCH before update..."
    git switch "$BASE_BRANCH"
elif [ "$CURRENT" != "$BASE_BRANCH" ]; then
    echo "==> Switching from $CURRENT to $BASE_BRANCH before update..."
    git switch "$BASE_BRANCH"
fi
check_clean

if [ "$DRY_RUN" -eq 1 ]; then
    trap restore_original_branch_for_dry_run EXIT
    echo "==> Dry run: fetching origin and preflighting Tlon patch only; no update/apply/restart."
    if ! git fetch origin; then
        echo "WARN: git fetch origin failed; continuing dry-run with existing local refs." >&2
    fi
    if git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
        echo "==> Dry run: preflighting against origin/$BASE_BRANCH as well..."
        dry_run_args=(--dry-run --base-ref "origin/$BASE_BRANCH")
        [ "$RUN_TESTS" -eq 0 ] && dry_run_args+=(--no-tests)
        HERMES_HOME="$HERMES_HOME" \
        HERMES_AGENT="$HERMES_AGENT" \
        PATCH="$PATCH" \
        BRANCH="$BRANCH" \
            bash "$APPLY_SCRIPT" "${dry_run_args[@]}"
    else
        run_apply_dry_run
    fi
    echo "==> Dry run complete."
    exit 0
fi

echo "==> Updating Hermes from clean $BASE_BRANCH..."
# Because we switched to a clean upstream branch first, hermes update should not
# ask to restore local Tlon changes. If it does, answer no: the patch is reapplied
# deliberately below.
printf 'n\n' | "$HERMES_CLI" update

echo "==> Verifying Hermes CLI after update..."
HERMES_CLI="$(find_hermes_cli)" || fail "no hermes CLI found after update"
"$HERMES_CLI" --help >/dev/null

cd "$HERMES_AGENT"
BASE_BRANCH="$(detect_base_branch)"
check_clean

echo "==> Reapplying Tlon patch safely..."
run_apply_script

if [ "$RESTART_GATEWAY" -eq 1 ]; then
    echo "==> Restarting Hermes gateway..."
    "$HERMES_CLI" gateway restart
    "$HERMES_CLI" status --all || true
else
    echo ""
    echo "==> Done. Gateway not restarted. Restart when ready:"
    echo "    $HERMES_CLI gateway restart"
fi
