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
PREFLIGHT_WORKTREE=""
TLON_BUILD_CLI="${TLON_BUILD_CLI:-1}"
TLON_APPS_REPO="${TLON_APPS_REPO:-https://github.com/tloncorp/tlon-apps.git}"
TLON_APPS_REF="${TLON_APPS_REF:-77d6286aff52ca72ccc9003fce5dff46a844818d}"
TLON_APPS_DIR="${TLON_APPS_DIR:-}"
TLON_CLI_DEST="${TLON_CLI_DEST:-}"

usage() {
    cat <<EOF
Usage: bash $(basename "$0") [--dry-run] [--base-ref REF] [--no-tests] [--help]

Environment overrides:
  HERMES_HOME    Hermes home directory (default: \$HOME/.hermes)
  HERMES_AGENT   Hermes source checkout (default: \$HERMES_HOME/hermes-agent)
  PATCH          Tlon patch file (default: script directory/tlon-pr.patch)
  BRANCH         Patch branch name (default: tlon-apply)
  TLON_BUILD_CLI Build/pin monorepo tlon CLI after patch (1/0, default: 1)
  TLON_APPS_REPO tlon-apps Git URL (default: https://github.com/tloncorp/tlon-apps.git)
  TLON_APPS_REF  tlon-apps ref/commit to build (default: known-good public commit)
  TLON_APPS_DIR  Existing tlon-apps checkout to use instead of cloning (optional)
  TLON_CLI_DEST  Destination for built CLI (default: \$HERMES_HOME/bin/tlon-monorepo-<version>-<sha>)

Options:
  --dry-run       Preflight only; do not modify the live checkout.
  --base-ref REF  Dry-run/preflight against REF, e.g. origin/main.
  --no-tests      Skip focused pytest checks after applying.
  --no-cli-build  Skip monorepo tlon CLI build/pin step.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-tests) RUN_TESTS=0 ;;
        --no-cli-build) TLON_BUILD_CLI=0 ;;
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

cleanup_preflight_worktree() {
    if [ -n "${PREFLIGHT_WORKTREE:-}" ]; then
        git -C "$HERMES_AGENT" worktree remove --force "$PREFLIGHT_WORKTREE" >/dev/null 2>&1 || true
        rm -rf "$PREFLIGHT_WORKTREE" >/dev/null 2>&1 || true
        PREFLIGHT_WORKTREE=""
    fi
}

trap cleanup_preflight_worktree EXIT

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

apply_patch_checked() {
    local phase="$1"
    local apply_log
    apply_log="$(mktemp /tmp/apply-tlon-git-apply.XXXXXX)"

    if git apply --3way "$PATCH" >"$apply_log" 2>&1; then
        cat "$apply_log"
        rm -f "$apply_log"
        check_no_conflicts
        return 0
    fi

    cat "$apply_log"
    rm -f "$apply_log"
    echo ""
    echo "ERROR: tlon-pr.patch does not apply cleanly in $phase."
    if [ "$phase" = "preflight" ]; then
        echo "The live Hermes checkout was not modified."
        echo "Refresh tlon-pr.patch against the current upstream base before applying."
    else
        echo "The live checkout may be on $BRANCH with a failed patch application."
        echo "Inspect 'git status' before doing anything else."
    fi

    if git ls-files -u | grep -q .; then
        echo ""
        echo "Unmerged entries:"
        git ls-files -u
    fi

    if git grep -n -E '^(<<<<<<<|>>>>>>>)( |$)' -- '*.py' '*.toml' '*.md' > /tmp/apply-tlon-conflict-markers.txt 2>/dev/null; then
        echo ""
        echo "Conflict markers:"
        sed -n '1,120p' /tmp/apply-tlon-conflict-markers.txt
    fi

    exit 1
}

preflight_patch() {
    local base_branch="$1"
    PREFLIGHT_WORKTREE="$(mktemp -d /tmp/hermes-tlon-preflight.XXXXXX)"

    echo "==> Preflighting patch in disposable worktree from $base_branch..."
    git worktree add --detach "$PREFLIGHT_WORKTREE" "$base_branch" >/dev/null
    (
        cd "$PREFLIGHT_WORKTREE"
        apply_patch_checked preflight
        python - <<'PY'
import tomllib
with open('pyproject.toml', 'rb') as f:
    tomllib.load(f)
print('  pyproject.toml parses OK')
PY
    )
    cleanup_preflight_worktree
    echo "  patch preflight OK"
}


update_env_tlon_cli() {
    local env_file="$1"
    local cli_path="$2"

    mkdir -p "$(dirname "$env_file")"
    ENV_FILE="$env_file" TLON_CLI_PATH="$cli_path" python3 - <<'PY'
from pathlib import Path
import os
path = Path(os.environ['ENV_FILE'])
cli = os.environ['TLON_CLI_PATH']
text = path.read_text() if path.exists() else ''
lines = text.splitlines()
out = []
seen = False
for line in lines:
    if line.startswith('TLON_CLI='):
        if not seen:
            out.append(f'TLON_CLI={cli}')
            seen = True
        # Drop duplicate TLON_CLI entries.
    else:
        out.append(line)
if not seen:
    out.append(f'TLON_CLI={cli}')
path.write_text('\n'.join(out) + '\n')
PY
}

build_and_pin_monorepo_tlon_cli() {
    if [ "$TLON_BUILD_CLI" = "0" ]; then
        echo "==> Skipping monorepo tlon CLI build/pin (TLON_BUILD_CLI=0)."
        return 0
    fi

    echo "==> Building monorepo tlon CLI from tlon-apps..."
    command -v git >/dev/null 2>&1 || fail "git is required to fetch tlon-apps"
    command -v node >/dev/null 2>&1 || fail "node is required to build the monorepo tlon CLI"
    command -v npm >/dev/null 2>&1 || fail "npm is required to fetch pnpm/bun for the monorepo tlon CLI build"

    local workdir=""
    local apps_dir=""
    local cleanup_apps=0
    if [ -n "$TLON_APPS_DIR" ]; then
        apps_dir="$TLON_APPS_DIR"
        [ -e "$apps_dir/.git" ] || fail "TLON_APPS_DIR is not a git checkout: $apps_dir"
    else
        workdir="$(mktemp -d /tmp/hermes-tlon-apps.XXXXXX)"
        apps_dir="$workdir/tlon-apps"
        cleanup_apps=1
        echo "  cloning $TLON_APPS_REPO"
        git clone "$TLON_APPS_REPO" "$apps_dir" >/dev/null
    fi

    (
        cd "$apps_dir"
        git checkout "$TLON_APPS_REF" >/dev/null
        short_sha="$(git rev-parse --short HEAD)"
        version="$(node -p "require('./packages/tlon-skill/package.json').version")"
        echo "  tlon-apps ref: $(git rev-parse --short HEAD)"
        echo "  tlon-skill version: $version"

        # Use npm exec so the patchkit does not require global pnpm/bun installs.
        # --script-shell works around npm configs that contain shell expressions.
        npm --script-shell=/bin/bash exec --yes --package pnpm@9.0.5 -- pnpm install --frozen-lockfile

        cd packages/tlon-skill
        mkdir -p dist
        npm --script-shell=/bin/bash exec --yes --package bun -- bun build scripts/main.ts \
            --compile \
            --target=bun-linux-x64 \
            --outfile dist/tlon \
            --define "__VERSION__=\"${version}-monorepo-${short_sha}\""
        chmod +x dist/tlon
        ./dist/tlon --version
        ./dist/tlon posts --help | grep -q 'send <channel> \[message\]' || fail "built tlon CLI lacks posts send"

        if [ -n "$TLON_CLI_DEST" ]; then
            dest="$TLON_CLI_DEST"
        else
            dest="$HERMES_HOME/bin/tlon-monorepo-${version}-${short_sha}"
        fi
        mkdir -p "$(dirname "$dest")"
        install -m 0755 dist/tlon "$dest"
        update_env_tlon_cli "$HERMES_HOME/.env" "$dest"
        echo "  installed: $dest"
        echo "  updated:   $HERMES_HOME/.env (TLON_CLI only; credentials untouched)"
    )

    if [ "$cleanup_apps" -eq 1 ]; then
        rm -rf "$workdir"
    fi
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

    echo "==> Verifying Tlon plugin syntax/imports..."
    "$venv_python" -m py_compile plugins/platforms/tlon/*.py
    "$venv_python" - <<PY
import sys
sys.path.insert(0, "$HERMES_AGENT")
from gateway.config import Platform
import plugins.platforms.tlon.adapter as adapter
import plugins.platforms.tlon.tlon_tool as tlon_tool
import aiohttp
print('  dynamic platform OK:', Platform('tlon'))
print('  tlon plugin adapter OK')
print('  tlon tool OK')
print('  aiohttp', aiohttp.__version__, 'OK')
print('  plugin requirements OK:', adapter.check_requirements())
PY
    "$hermes_cli" --help > /dev/null && echo "  CLI OK"

    if [ "$RUN_TESTS" -eq 1 ]; then
        echo "==> Running focused upstream Tlon plugin tests..."
        "$venv_python" -m pytest plugins/platforms/tlon/test_*.py -q -o 'addopts='
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
apply_patch_checked live
run_verification "$VENV_PYTHON" "$HERMES_CLI"
build_and_pin_monorepo_tlon_cli

git add -A
git commit -m "chore: reapply Tlon platform plugin patch"
echo "==> Committed: $(git log --oneline -1)"

echo ""
echo "==> All good. Restart the gateway when ready:"
echo "    $HERMES_CLI gateway restart"
