# Prototype testing policy

Accepted 2026-10-09: keep a small set of stable regression contracts during rapid
prototyping. A tiny UI/style or balance change should not require repairing a
browser screenshot, a specific DOM tree or a combat animation timeline.

## Default

```powershell
git diff --check
& ./tests/run-smoke.ps1
```

Godot 4.7.2 and Node are required. `-NodeExecutable` can select a bundled Node.
No running server, browser, GUI, network port or production accounts are required.
The smoke suite does not install/download CEF. Installing CEF is optional; installed CEF loads in headless without
creating a browser. The suite has five small SQLite scenarios and one bridge contract group:

- Item identity, ownership, revisions, atomic equip/move and rollback/reopen.
- Inventory footprints, page bounds, overlap and atomic legacy migration.
- Pickup identity, full bag, double pickup and partial-write rollback.
- XP/level RAM updates and dirty checkpoints, including forced save and crash window.
- Wallet deltas, immediate critical spend, rollback/checkpoint and relog.
- Bridge framing, explicit command boundary, readiness, request correlation and
  full snapshot recovery. No mock inventory or browser rendering is involved.

Successful runs delete their disposable databases and overwrite a small fixed
set of logs under `.godot/verification`. Failed runs retain diagnostic state.
These tests intentionally protect persistence and authority, not prototype visuals.

## Optional integration

The existing headless gameplay/network runners remain available on demand:
`run-spike3d`, `run-pve`, `run-combat`, `run-progression`, `run-xp`, `run-yang`,
`run-web-inventory`. Choose the affected flow for movement/combat/XP/wallet/RPC
changes; do not run all of them after CSS edits. They share port 18098: run
sequentially. `run-items.ps1 -WithSession` requires normal gateway/master/world
roles and writes guest fixture accounts; use it for actual session/login changes.

`run-cef-export.ps1` is an optional packaging-boundary check after addon/export
changes: client Web assets and CEF registration, CEF-free server packs and
client/server pack headless boot (including real client UID validation without
SQLite). It requires the local CEF installation and opens no windows.

Asset pipeline tests and visual fallback probes remain optional for pipeline
changes. The small default suite does not install Pillow or Playwright.

The old CEF spike, its mock/diagnostic adapter, its renderer/measurement runners
and the exact-layout browser matrix test were removed. The original adoption
results remain in [the historical decision record](cef-ui-spike.md). The inventory
resolution matrix is a manual milestone checklist in [UI Contract v1](ui-contract.md),
not a pixel-sensitive CI assertion. Use the root client for CEF/input/
resize/transparency/shutdown checks; no parallel standalone UI mock.

## CI and cleanup

Push/PR CI imports a clean checkout, checks whitespace and runs smoke only.
Workflow dispatch can opt into extended gameplay/asset checks. Local execution
verifies the scripts; it does not prove the remote Actions run until published.

```powershell
& ./tools/clean-dev-artifacts.ps1 -WhatIf
& ./tools/clean-dev-artifacts.ps1
```

Cleanup removes `.godot/verification`, retired spike/copied-client caches and the named old
scratch files, within checked workspace paths. It preserves `.godot/imported`,
editor cache, engine binaries, the installed root CEF addon/plugin archive cache, reference
checkouts, local asset cache and normal player/account data. Temporary work should
live under `.godot/verification`, rather than accumulating at the .godot root.
