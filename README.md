# Hermes Tlon Patch Kit

Portable scripts for updating a source-installed [Hermes Agent](https://github.com/NousResearch/hermes-agent) checkout while preserving the local Tlon/Urbit gateway adapter patch.

This kit is intended for machines where Hermes is installed from a Git checkout, usually at:

```text
~/.hermes/hermes-agent
```

## Important: Do Not Run `hermes update` Directly

If your Hermes install uses this Tlon patch, **do not run `hermes update` directly**.

Use the wrapper instead:

```bash
bash ./update-hermes-with-tlon.sh
```

The wrapper runs `hermes update` as part of its controlled flow, then reapplies `tlon-pr.patch` safely with preflight checks. Running `hermes update` directly can leave the checkout in a half-updated state, restore stale local changes, or produce patch conflicts that break the Hermes CLI before the Tlon patch has been refreshed.

For routine updates, the correct command is:

```bash
bash ./update-hermes-with-tlon.sh --dry-run
bash ./update-hermes-with-tlon.sh
```

## Mental Model

Think of this kit as a small, repeatable rebase machine for a local Hermes customization.

Hermes upstream moves over time. The Tlon gateway integration lives outside upstream for now, so it has to be reapplied after upstream updates. The unsafe version of that workflow is:

```text
run hermes update directly
hope Git restores local changes cleanly
notice too late if pyproject.toml or Python files now contain conflict markers
```

This kit makes the flow explicit instead:

```text
clean upstream Hermes checkout
        ↓
run Hermes' normal updater
        ↓
start from the updated upstream branch
        ↓
apply tlon-pr.patch in a disposable worktree first
        ↓
if the patch applies and sanity checks pass, apply it to the real checkout
        ↓
verify imports, CLI startup, dependencies, and focused tests
        ↓
commit the result on the local tlon-apply branch
```

There are two scripts because they have different jobs:

- `update-hermes-with-tlon.sh` is the outer workflow. It owns the safe update order: get back to clean upstream, run `hermes update`, then call the patch applicator.
- `apply-tlon.sh` is the patch applicator. It owns Git hygiene, disposable-worktree preflight, conflict detection, dependency pinning, import checks, and focused tests.

The patch file itself, `tlon-pr.patch`, is just the source delta: "given upstream Hermes, add the Tlon gateway/platform/tooling changes." It is intentionally dumb. The scripts provide the guardrails.

The important invariant is:

```text
upstream first, Tlon second
```

Do not let `hermes update` try to carry the Tlon patch through the update automatically. That is how you get conflict markers in live files and a Hermes CLI that explodes before it can help you. Tiny tragedy, avoidable with Bash.

## Contents

| File | Purpose |
| --- | --- |
| `update-hermes-with-tlon.sh` | Recommended wrapper: update Hermes from a clean upstream branch, then safely reapply Tlon. |
| `apply-tlon.sh` | Safely applies `tlon-pr.patch` to a Hermes checkout. |
| `tlon-pr.patch` | Reusable patch containing the local Tlon gateway integration changes. |
| `VERSION` | Package version. |
| `CHANGELOG.md` | Release history. |
| `checksums.txt` | SHA-256 checksums for package files. |

## Requirements

- Bash
- Git
- Python 3
- Hermes installed from a Git/source checkout
- Hermes virtualenv present under either:
  - `$HERMES_AGENT/venv`
  - `$HERMES_AGENT/.venv`
- `uv` or `pip` available for installing/pinning `aiohttp==3.13.5`
- `pytest` available in the Hermes venv for full focused-test verification

## Recommended Usage

Always start with a dry run:

```bash
bash ./update-hermes-with-tlon.sh --dry-run
```

If that passes, run the update/reapply flow:

```bash
bash ./update-hermes-with-tlon.sh
```

Then restart the gateway when ready:

```bash
hermes gateway restart
```

Or update, reapply Tlon, and restart the gateway in one run:

```bash
bash ./update-hermes-with-tlon.sh --restart-gateway
```

## Portable Usage

The scripts derive paths from environment variables, so they can be copied to another machine.

Defaults:

```bash
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
HERMES_AGENT=${HERMES_AGENT:-$HERMES_HOME/hermes-agent}
PATCH=${PATCH:-<script-dir>/tlon-pr.patch}
BRANCH=${BRANCH:-tlon-apply}
```

Examples:

```bash
HERMES_HOME="$HOME/.hermes" bash ./update-hermes-with-tlon.sh
```

```bash
HERMES_AGENT="/path/to/hermes-agent" \
PATCH="/path/to/tlon-pr.patch" \
bash ./update-hermes-with-tlon.sh
```

## Direct Apply Usage

If you do not want to run `hermes update`, you can use the apply script directly:

```bash
bash ./apply-tlon.sh --dry-run
bash ./apply-tlon.sh --dry-run --base-ref origin/main
bash ./apply-tlon.sh
```

## Safety Model

The scripts are designed to fail before damaging the live Hermes checkout.

`update-hermes-with-tlon.sh`:

- refuses to run from a dirty checkout
- switches from `tlon-apply` back to the upstream branch before update
- prevents `hermes update` from restoring local Tlon changes automatically
- reapplies Tlon deliberately via `apply-tlon.sh`
- keeps gateway restart opt-in unless `--restart-gateway` is passed

`apply-tlon.sh`:

- refuses dirty checkouts
- preflights `tlon-pr.patch` in a disposable Git worktree before touching live files
- recreates `tlon-apply` from the detected upstream branch (`main` or `master`)
- aborts on unmerged Git entries
- aborts on conflict markers
- runs `git diff --check`
- parses `pyproject.toml`
- pins/verifies `aiohttp==3.13.5`
- syntax-checks Tlon files
- import-checks Tlon modules
- verifies the Hermes CLI starts
- runs focused pytest checks unless `--no-tests` is passed
- commits only after verification passes

## Failure Guidance

### Dirty checkout before update

If the wrapper stops with output like:

```text
 M package-lock.json
?? .hermes-bootstrap-complete
ERROR: working tree is not clean; commit/stash/restore before updating
```

clean those generated/local files before retrying:

```bash
cd ~/.hermes/hermes-agent
git restore package-lock.json
rm -f .hermes-bootstrap-complete
git status --short
```

`git status --short` should be empty before running the wrapper.

### Stale patch / upstream drift

If `--dry-run` or the wrapper fails during patch preflight with output like:

```text
Applied patch to 'pyproject.toml' with conflicts.
U pyproject.toml
ERROR: tlon-pr.patch does not apply cleanly in preflight.
The live Hermes checkout was not modified.
```

stop. Do not apply the patch to the live checkout. The patch is stale against current upstream Hermes.

The normal recovery path is:

1. Apply the patch manually in a temporary worktree.
2. Resolve conflicts there.
3. Run focused tests.
4. Regenerate `tlon-pr.patch` from the resolved tree.
5. Re-run `update-hermes-with-tlon.sh --dry-run`.

Do not let `hermes update` restore local Tlon changes automatically. Update clean upstream Hermes first, then reapply Tlon deliberately.

## Configuration Not Included

This repository does not include Tlon credentials or Hermes runtime config.

The target machine still needs its own Hermes `.env` values, for example:

```bash
TLON_SHIP_URL=...
TLON_SHIP_NAME=...
TLON_SHIP_CODE=...
TLON_OWNER_SHIP=...
```
