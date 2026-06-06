# Changelog

## 0.1.0 - 2026-06-03

Initial public patch-kit packaging.

### Added

- README mental model explaining the safe update/reapply flow: upstream first, Tlon second, with disposable-worktree preflight before touching the live checkout.
- Prominent README warning that Tlon-patched installs should not run `hermes update` directly; the wrapper runs it as part of the safe update/reapply flow.
- `update-hermes-with-tlon.sh` portable update/reapply wrapper.
- `apply-tlon.sh` portable guarded patch application script.
- `tlon-pr.patch` reusable Tlon gateway patch.
- README with safety model, dry-run workflow, and portable environment overrides.
- SHA-256 checksum manifest.

### Fixed

- Refreshed `tlon-pr.patch` against Hermes upstream `66a6b9c93`, preserving upstream's new update-stream reconnect test and Matrix `Markdown` dependency while keeping the Tlon-required `aiohttp==3.13.5` pins.
- `apply-tlon.sh` now reliably removes disposable preflight worktrees on both success and failure.
- `apply-tlon.sh` now reports stale-patch preflight conflicts clearly and states that the live checkout was not modified.
- README failure guidance now covers generated-file dirty checkouts and stale-patch/upstream-drift preflight failures.
- Script Git-repo detection now accepts linked worktrees where `.git` is a file, not only primary checkouts where `.git` is a directory.

### Notes

- `apply-tlon-portable.sh` is intentionally omitted. It was a compatibility shim and is deprecated because `apply-tlon.sh` is now portable.
