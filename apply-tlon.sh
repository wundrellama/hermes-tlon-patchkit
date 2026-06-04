#!/usr/bin/env bash
# apply-tlon.sh — safely reapply the Tlon gateway patch after a Hermes update.
#
# Portable defaults:
#   HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
#   HERMES_AGENT=${HERMES_AGENT:-$HERMES_HOME/hermes-agent}
#   PATCH=${PATCH:-<this-script-dir>/tlon-pr.patch}
#   BRANCH=${BRANCH:-tlon-apply}
#
# Usage:
#   bash apply-tlon.sh
#   HERMES_HOME=/path/to/.hermes bash apply-tlon.sh
#   HERMES_AGENT=/path/to/hermes-agent PATCH=/path/to/tlon-pr.patch bash apply-tlon.sh
#   bash apply-tlon.sh --dry-run
#   bash apply-tlon.sh --dry-run --base-ref origin/main
#   bash apply-tlon.sh --no-tests
#
# Safety model:
#   1. Refuses to start from a dirty live checkout.
#   2. Preflights the patch in a disposable worktree before touching live files.
#   3. Recreates BRANCH from the detected upstream branch (main/master).
#   4. Applies the patch, refuses conflict markers/unmerged entries/whitespace errors.
#   5. Verifies syntax/imports/CLI and optionally focused pytest tests.
#   6. Commits only after verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_AGENT="${HERMES_AGENT:-$HERMES_HOME/hermes-agent}"
PATCH="${PATCH:-$SCRIPT_DIR/tlon-pr.patch}"
BRANCH="${BRANCH:-tlon-apply}"
RUN_TESTS=1
DRY_RUN=0
BASE_REF=""

usage() {
    cat <<EOF
Usage: bash $(basename "$0") [--dry-run] [--base-ref REF] [--no-tests] [--help]

Environment overrides:
  HERMES_HOME    Hermes home directory (default: \$HOME/.hermes)
  HERMES_AGENT   Hermes source checkout (default: \$HERMES_HOME/hermes-agent)
  PATCH          Tlon patch file (default: script directory/tlon-pr.patch)
  BRANCH         Patch branch name (default: tlon-apply)

Options:
  --dry-run       Preflight only; do not modify the live checkout.
  --base-ref REF  Dry-run/preflight against REF, e.g. origin/main.
  --no-tests      Skip focused pytest checks after applying.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-tests) RUN_TESTS=0 ;;
        --base-ref)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --base-ref requires an argument" >&2
                exit 2
            fi
            BASE_REF="$2"
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

find_venv_python() {
    if [ -x "$HERMES_AGENT/venv/bin/python" ]; then
        printf '%s\n' "$HERMES_AGENT/venv/bin/python"
    elif [ -x "$HERMES_AGENT/.venv/bin/python" ]; then
        printf '%s\n' "$HERMES_AGENT/.venv/bin/python"
    else
        return 1
    fi
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

check_no_conflicts() {
    if git ls-files -u | grep -q .; then
        echo ""
        echo "ERROR: git has unmerged entries:"
        git ls-files -u
        echo ""
        echo "Resolve conflicts manually, then regenerate $PATCH."
        exit 1
    fi

    if git grep -n -E '^(<<<<<<<|>>>>>>>)( |$)' -- '*.py' '*.toml' '*.md' > /tmp/apply-tlon-conflict-markers.txt; then
        echo ""
        echo "ERROR: conflict markers found:"
        sed -n '1,120p' /tmp/apply-tlon-conflict-markers.txt
        echo ""
        echo "Refusing to continue. Tiny landmine disarmed."
        exit 1
    fi

    git diff --check
}

preflight_patch() {
    local base_branch="$1"
    local verify_dir
    verify_dir="$(mktemp -d /tmp/hermes-tlon-preflight.XXXXXX)"
    cleanup_preflight() {
        git -C "$HERMES_AGENT" worktree remove --force "$verify_dir" >/dev/null 2>&1 || true
        rm -rf "$verify_dir" >/dev/null 2>&1 || true
    }
    trap cleanup_preflight RETURN

    echo "==> Preflighting patch in disposable worktree from $base_branch..."
    git worktree add --detach "$verify_dir" "$base_branch" >/dev/null
    (
        cd "$verify_dir"
        git apply --3way "$PATCH"
        check_no_conflicts
        python - <<'PY'
import tomllib
with open('pyproject.toml', 'rb') as f:
    tomllib.load(f)
print('  pyproject.toml parses OK')
PY
    )
    echo "  patch preflight OK"
}

run_verification() {
    local venv_python="$1"
    local hermes_cli="$2"

    echo "==> Pinning aiohttp==3.13.5..."
    if command -v uv >/dev/null 2>&1; then
        uv pip install "aiohttp==3.13.5" --python "$venv_python" 2>&1 | tail -3
    elif [ -x "$HERMES_HOME/bin/uv" ]; then
        "$HERMES_HOME/bin/uv" pip install "aiohttp==3.13.5" --python "$venv_python" 2>&1 | tail -3
    elif "$venv_python" -m pip --version >/dev/null 2>&1; then
        "$venv_python" -m pip install "aiohttp==3.13.5" 2>&1 | tail -3
    else
        fail "neither uv nor pip is available to pin aiohttp"
    fi

    echo "==> Verifying syntax/imports..."
    "$venv_python" -m py_compile gateway/run.py gateway/platforms/tlon.py tools/tlon_tool.py
    "$venv_python" - <<PY
import sys
sys.path.insert(0, "$HERMES_AGENT")
import toolsets
from gateway.platforms import tlon
from tools import tlon_tool
import aiohttp
print('  toolsets OK')
print('  tlon platform OK')
print('  tlon tool OK')
print('  aiohttp', aiohttp.__version__, 'OK')
PY
    "$hermes_cli" --help > /dev/null && echo "  CLI OK"

    if [ "$RUN_TESTS" -eq 1 ]; then
        echo "==> Running focused Tlon/update tests..."
        "$venv_python" -m pytest \
            tests/gateway/test_restart_notification.py \
            tests/gateway/test_update_command.py \
            tests/tools/test_tlon_tool.py \
            -q -o 'addopts='
    else
        echo "==> Skipping focused tests (--no-tests)"
    fi
}

echo "==> Checking prerequisites..."
[ -e "$HERMES_AGENT/.git" ] || fail "$HERMES_AGENT is not a git repo"
[ -f "$PATCH" ] || fail "$PATCH not found. Put tlon-pr.patch next to this script or set PATCH=/path/to/file."
if [ -n "$BASE_REF" ] && [ "$DRY_RUN" -ne 1 ]; then
    fail "--base-ref is only supported with --dry-run"
fi
cd "$HERMES_AGENT"

if [ -n "$(git status --porcelain)" ]; then
    git status --short
    fail "working tree is not clean"
fi

BASE_BRANCH="${BASE_REF:-$(detect_base_branch)}"
echo "==> Base ref: $BASE_BRANCH"
echo "==> Base HEAD: $(git log --oneline -1 "$BASE_BRANCH")"
preflight_patch "$BASE_BRANCH"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> Dry run complete; live checkout was not modified."
    exit 0
fi

VENV_PYTHON="$(find_venv_python)" || fail "no Hermes venv python found under $HERMES_AGENT/{venv,.venv}"
HERMES_CLI="$(find_hermes_cli)" || fail "no hermes CLI found in venv or PATH"

CURRENT="$(git branch --show-current)"
if [ "$CURRENT" = "$BRANCH" ]; then
    echo "==> Already on $BRANCH — switching to $BASE_BRANCH first"
    git switch "$BASE_BRANCH"
elif [ "$CURRENT" != "$BASE_BRANCH" ]; then
    echo "==> Switching from $CURRENT to $BASE_BRANCH"
    git switch "$BASE_BRANCH"
fi

if git show-ref --quiet "refs/heads/$BRANCH"; then
    git branch -D "$BRANCH"
    echo "==> Dropped old $BRANCH branch"
fi

git switch -c "$BRANCH" "$BASE_BRANCH"
echo "==> Created $BRANCH from $BASE_BRANCH"

echo "==> Applying patch: $PATCH"
git apply --3way "$PATCH"
check_no_conflicts
run_verification "$VENV_PYTHON" "$HERMES_CLI"

git add -A
git commit -m "chore: reapply Tlon gateway patch (PR #26300)"
echo "==> Committed: $(git log --oneline -1)"

echo ""
echo "==> All good. Restart the gateway when ready:"
echo "    $HERMES_CLI gateway restart"
