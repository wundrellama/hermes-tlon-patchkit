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

## Contents

| File | Purpose |
| --- | --- |
| `update-hermes-with-tlon.sh` | Recommended wrapper: update Hermes from a clean upstream branch, then safely reapply Tlon. |
| `apply-tlon.sh` | Safely applies `tlon-pr.patch` to a Hermes checkout. |
| `tlon-pr.patch` | Reusable patch containing the local Tlon gateway integration changes. |
| `VERSION` | Package version. |
| `CHANGELOG.md` | Release history. |
| `checksums.txt` | SHA-256 checksums for package files. |

`apply-tlon-portable.sh` is intentionally not included. It was a compatibility shim and is deprecated; `apply-tlon.sh` itself is now portable.

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

If `--dry-run` fails, do not apply the patch. The patch is probably stale against current upstream Hermes.

The normal recovery path is:

1. Apply the patch manually in a temporary worktree.
2. Resolve conflicts there.
3. Run focused tests.
4. Regenerate `tlon-pr.patch` from the resolved commit.
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

Never commit ship codes, API keys, auth cookies, or private channel identifiers.

## Branch Naming

This repository uses `master` as its default branch.
