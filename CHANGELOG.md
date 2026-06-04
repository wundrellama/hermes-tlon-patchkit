# Changelog

## 0.1.0 - 2026-06-03

Initial public patch-kit packaging.

### Added

- `update-hermes-with-tlon.sh` portable update/reapply wrapper.
- `apply-tlon.sh` portable guarded patch application script.
- `tlon-pr.patch` reusable Tlon gateway patch.
- README with safety model, dry-run workflow, and portable environment overrides.
- SHA-256 checksum manifest.

### Fixed

- Script Git-repo detection now accepts linked worktrees where `.git` is a file, not only primary checkouts where `.git` is a directory.

### Notes

- `apply-tlon-portable.sh` is intentionally omitted. It was a compatibility shim and is deprecated because `apply-tlon.sh` is now portable.
