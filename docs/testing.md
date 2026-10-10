# Prototype testing policy

Accepted 2026-10-09: keep a small set of stable regression contracts during rapid
prototyping. A tiny UI/style or balance change should not require repairing a
browser screenshot, a specific DOM tree or a combat animation timeline.

## Default

```powershell
git diff --check
& ./tests/run-smoke.ps1
```

Godot 4.7.2 and Node 20.19+ are required. Run `npm ci --ignore-scripts` in
`source/client/ui_web` once for the pinned compiler and test dependencies.
Smoke compiles TypeScript and tests the emitted static browser JS. `-NodeExecutable` can select a bundled Node.
No running server, browser, GUI, network port or production accounts are required.
The smoke suite does not install/download CEF. Installing CEF is optional; installed CEF loads in headless without
creating a browser. The suite has six small SQLite scenarios, one NPC content/context fixture and one bridge contract group:

- Item identity, ownership, revisions, atomic equip/move and rollback/reopen.
- Inventory footprints, page bounds, overlap and atomic legacy migration.
- Pickup identity, full bag, double pickup and partial-write rollback.
- XP/level RAM updates and dirty checkpoints, including forced save and crash window.
- Wallet deltas, immediate critical spend, rollback/checkpoint and relog.
- NPC Shop offer/stack invariants, exact/first-fit purchase, capacity-before-charge,
  pending Yang, rollback and durable item identity.
- Neutral NPC definitions, service references, map/range/context authority and teardown.
- Bridge framing, explicit command boundary, readiness, request correlation and
  full snapshot recovery; small Core UI lifecycle, skin and icon contracts.
  No browser rendering or network fixture is involved in default smoke.

Successful runs delete their disposable databases and overwrite a small fixed
set of logs under `.godot/verification`. Failed runs retain diagnostic state.
These tests intentionally protect persistence and authority, not prototype visuals.

## Optional integration

The existing headless gameplay/network runners remain available on demand:
`run-spike3d`, `run-pve`, `run-combat`, `run-progression`, `run-xp`, `run-yang`,
`run-web-inventory`, `run-npc`, `run-shop`. Choose the affected flow for movement/combat/XP/wallet/RPC
changes; do not run all of them after CSS edits. They share port 18098: run
sequentially. `run-items.ps1 -WithSession` requires normal gateway/master/world
roles and writes guest fixture accounts; use it for actual session/login changes.

`run-first-region.ps1` loads the production graybox scene headlessly and checks
connected navigation to NPC/mob/Metin sites, safe hub spawns, profile-preserving
respawn and the shore boundary. It opens no window and does not assert exact
layout or balance. See [region notes](first-region-graybox.md).

`run-cef-export.ps1` is an optional packaging-boundary check after addon/export
changes: client Web assets and CEF registration, CEF-free server packs and
client/server pack headless boot (including real client UID validation without
SQLite). It requires the local CEF installation and opens no windows.

`run-core-ui-browser.ps1` is an opt-in [Core UI milestone check](core-ui.md)
using the production page, controlled IPC and an installed headless browser.
It checks behavior and broad bounds, with no pixel/exact-tree assertions or downloads.
It does not replace native root-client CEF verification.

`run-shop-browser.ps1` is the analogous optional [NPC Shop view check](npc-shop.md).
Pass the installed `-PlaywrightModule` and `-BrowserExecutable`, and optionally
`-ScreenshotDirectory`. It verifies rendered skin/fallback, broad frame bounds
and Shop/Inventory placement, mouse purchase gestures, tooltip, catalog pages
and close/Escape with controlled IPC; no game accounts or running servers. It also
checks [Upgrade](npc-upgrade-ui.md): server-driven item selection/commit/rejection,
a +0 → +1 snapshot and an explicit execute command without optimistic mutation.
The separate developer page retains visual level controls.

Asset pipeline tests and visual fallback probes remain optional for pipeline
changes. The small default suite downloads no browser and does not install Pillow.

The old CEF spike, its mock/diagnostic adapter, its renderer/measurement runners
and the exact-layout browser matrix test were removed. The original adoption
results remain in [the historical decision record](cef-ui-spike.md). The inventory
resolution matrix is a manual milestone checklist in [UI Contract v1](ui-contract.md),
not a pixel-sensitive CI assertion. Use the root client for CEF/input/
resize/transparency/shutdown checks; no parallel standalone UI mock.

## CI and cleanup

Push/PR CI installs the pinned Web UI development dependencies, compiles TypeScript,
checks that committed runtime assets match their source, imports a clean checkout,
checks whitespace and runs smoke.
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

`run-upgrade.ps1` is an opt-in two-client production Upgrade RPC suite on port
18098; run sequentially with the other PvE-derived suites. Smoke includes one
material/item/wallet rollback fixture and small UI/bridge contracts.

`run-camera.ps1` is the optional headless Camera v1 collision/picking fixture.
See [Camera v1](camera-v1.md) for the native input/framing acceptance checklist.
