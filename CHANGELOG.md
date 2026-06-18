# Changelog

## Unreleased

## 0.2.2 - 2026-06-18

### Fixed

- Refreshed `tlon-pr.patch` from Hermes `tlon-apply` commit `fe5304e3a` to include home-channel inbound fixes: channel-history catch-up polling, startup seeding to avoid replay spam, and `TLON_HOME_CHANNEL` monitoring/owner-listen defaults even when the channel is hosted by another ship.
- Preserved gateway slash-command dispatch in Tlon group channels by skipping recent-channel-context wrapping when the cleaned message starts with `/`; this fixes `/new` being treated as ordinary model input.
- Added regression coverage for `channel-action-2` timestamp payloads, home-channel catch-up dispatch, settings-preserved home owner-listen behavior, and raw slash-command dispatch in the home channel.

### Verified

- Live patched Hermes checkout passed: `./venv/bin/python -m pytest plugins/platforms/tlon -q` → `364 passed, 21 subtests passed`.
- The regenerated patch applies cleanly from Hermes `main` `426f321e8`.

## 0.2.1 - 2026-06-18

### Fixed

- Patched gateway DM delivery for current Tlon apps: `TlonCLI.send_message("~ship", text)` now sends direct messages via an Eyre `chat` poke using `chat-dm-action-2` and dotted decimal `@da` writ IDs instead of the stale `tlon posts send ~ship ...` CLI path, which current Tlon rejects.
- Added a regression test covering the v2 DM payload shape and timestamp-derived writ ID.

### Verified

- Focused Tlon plugin tests passed in the live Hermes checkout: `360 passed, 21 subtests passed`.
- Refreshed `tlon-pr.patch` applied cleanly in a disposable worktree from Hermes `main` `426f321e8`; the new DM regression passed there.
- Live patched `TlonCLI.send_message("~dinnyt-divsud", ...)` delivered a real DM, verified by Tlon message search.

## 0.2.0 - 2026-06-18

### Changed

- Rebased `tlon-pr.patch` onto Tlon's upstream Hermes plugin package at `tloncorp/tlon-apps/packages/hermes-tlon-adapter` (`develop` commit `77d6286`). The patch now adds `plugins/platforms/tlon/` as a native Hermes platform plugin instead of carrying the older in-tree gateway/tool integration.
- Kept the local `aiohttp==3.13.5` pin in Hermes extras while upstream Hermes currently pins `3.13.4`; this preserves the known Startram duplicate-`Server` header fix.
- Updated `apply-tlon.sh` verification to compile/import the plugin and run the upstream plugin test suite (`plugins/platforms/tlon/test_*.py`).

### Verified

- Upstream plugin import and dynamic `Platform("tlon")` registration work on Hermes `860cf51`.
- Upstream plugin tests passed in a disposable Hermes checkout: `359 passed, 21 subtests passed`.

## 0.1.3 - 2026-06-15

### Fixed

- Refreshed `tlon-pr.patch` against Hermes upstream `ed20f5ed0`, preserving upstream's latest `pyproject.toml` dev dependency pins while keeping the Tlon-required `aiohttp==3.13.5` pins across messaging-related extras.

## 0.1.2 - 2026-06-12

### Fixed

- Refreshed `tlon-pr.patch` against Hermes upstream `d810f2b26`, preserving upstream's new `WHATSAPP_CLOUD_HOME_CHANNEL` cron delivery mapping alongside the Tlon `TLON_HOME_CHANNEL` mapping.

## 0.1.1 - 2026-06-09

### Fixed

- Refreshed `tlon-pr.patch` against Hermes upstream `74239b494`, after upstream moved gateway slash-command handlers into `gateway/slash_commands.py`.
- Fixed the disposable preflight worktree cleanup trap in `apply-tlon.sh`; failed preflights no longer leave stale `/tmp/hermes-tlon-preflight.*` worktrees or trip `verify_dir: unbound variable`.
- `update-hermes-with-tlon.sh --dry-run --no-tests` now actually forwards `--no-tests` when preflighting against `origin/<base>`.
- `update-hermes-with-tlon.sh --dry-run` now continues against existing local refs if `git fetch origin` fails, instead of aborting before the preflight can run.

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
