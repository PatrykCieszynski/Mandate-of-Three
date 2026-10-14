# Auction D1b — production readonly SOCI search

Review topic: `codex/auction-d1b-service`, based on accepted D1a 0df221a.
Godot 4.7.2 and godot-soci v0.4.1 are pinned. Stop here before D2.

## Ownership and request flow

WorldDatabase owns the existing godot-sqlite writer, runtime wallets and dirty
checkpoints. Shop/Exchange/Yang/items/receipts continue to commit immediately
through that writer. There is no persistence/backend migration.

One World-scoped `AuctionQueryService` coordinates main-thread admission and
delivery. `AuctionSociReader` is the small native adapter: one
`SociQueryDispatcher`, one separate SQLite session with `readonly=true` and
`query_only=ON`. It receives only SQL, named scalar bindings and a row cap. No
GDScript worker, thread, shared writer, player, node or resource enters native SQL.

`MarketEndpoint3D.request_query("search")` authenticates the current peer/player/
account, captures endpoint/peer epoch, player and actor instance IDs, economy
identity and request ID, submits and returns. Completion is later delivered on
main through the unchanged `receive_query(peer, request_id, result)` RPC shape.
Main rechecks the captured session before delivery; disconnect, peer-ID reuse,
character replacement and instance teardown cannot redirect old results.
Endpoint teardown cancels its scope. Epoch entries disappear on disconnect.
Browser generation/epoch and reload handling remain unchanged.

`MarketSearchSqlite` now supplies named query bindings and main-thread item
projection. Filter/range/AND/order/cursor semantics are unchanged. The existing
diagnostic query remains an independent parity oracle. Invalid filters and
cursors are rejected before native scheduling. `catalog`, `visit` and `exchange`
remain synchronous. The old synchronous World-wide 5/s gate is removed; invoking
the old facade's search action returns request error instead of executing SQL
on the simulation thread. No fallback silently reintroduces synchronous search.

## Bounded admission and completion

- Existing endpoint protection: 8 query requests/sec per peer, independently
  of economic commands; retained for all query actions.
- Shared service protection: 8 valid search submissions/sec per verified account.
- 64 admitted jobs total, including the single active native read.
- At most one pending job per account; an account may also own the active job.
  Pending replacement settles the previous request with existing `rate_limited`.
  It retains the account's queue position; it cannot supersede active SQL.
- FIFO account turns and one native in-flight job. A newly queued turn from the
  currently executing account goes behind other waiting accounts.
- Duplicate request keys already pending/active do not create another job or
  settle the original twice. Request keys include endpoint, peer and epoch.
- One terminal result or explicit session cancellation per admitted job. Expired
  queued work never enters SQL. Queue overflow and admission spam are rejected.

The 2-second deadline starts at admission and includes queue delay, native work,
delivery and projection. The existing `timeout` reason is used within the same
`ok/error` envelope. Deadline checks run on main ticks; a main-loop hitch can
delay notification but cannot turn a late result into success. Native requests
are awaited with `request.completed`, guarded by `is_done()`. `poll(1)` delivers
on main. A timeout does not cancel a running statement or release its native
slot; the actual SQL continues to completion and its late result is suppressed.
The main thread continues ticking throughout. Unexpected native query failure
closes admissions, settles queued jobs with storage error and closes the idle
reader. Recovery uses an explicit start after safe drain, not hidden retries.

## Startup, backup and shutdown

The verified Master identity manifest completes migrations through v23 before
starting the reader. `start()` alone is not readiness: the adapter executes its
configuration and reads schema version/WAL on the real session before opening
admissions. Missing files are rejected without creating a DB. Unsupported quoted
paths are refused. Readiness failure logs an error and leaves search unavailable;
the authoritative economy remains operational.

`WorldDatabase.coordinated_backup()` serializes lifecycle requests, closes
admissions, drains accepted reads with a bounded deadline, closes/joins the idle
native session, then calls the existing TRUNCATE checkpoint + file copy. Routine
backup starts a new reader afterwards. Direct backup refuses an open reader.
Timeout refuses backup/shutdown, leaves the native session alive and continues
polling; no forced thread termination and no unsafe join on active SQL.

Master save, periodic backup, restart countdown and graceful shutdown use this
coordination. Restart countdown leaves the reader closed while waiting for the
external stop. Shutdown performs a final dirty flush **after** reader drain,
backs up, closes the writer and only then quits. Window close has the same
World-only path with automatic quit disabled. Reopen/start refuses to reuse a
ready reader against a changed writer/path; drain and close precede reconfiguration.

SQLite busy timeout only bounds lock waiting, not SELECT execution. The addon
does not expose statement cancellation or guarantee bounded native SQL. A truly
stuck statement therefore prevents graceful shutdown; the application reports
failure rather than pretending a safe backup. External SIGTERM/SIGKILL is not
this graceful RPC/window path. Deployment must finish the coordinated shutdown/
restart protocol first. No addon patches or cancellation workarounds were added.

## Installation and export

```powershell
python tools/soci/setup.py
python tools/soci/setup.py --check
```

`tools/soci/release.json` pins the official ZIP, commit and every payload hash.
The installer copies the unmodified package to ignored `addons/godot_soci`.
Cached archives live under ignored `.godot/plugin-cache`. No binaries are committed.
Restart World after installing/updating code so its manifest startup starts the
reader. This topic did not restart live servers or touch runtime databases.
Historical S0/P0 pinned-library benchmarks require a separate diagnostic checkout
without this installed production addon. Their preflight refuses already
registered SOCI classes, preventing a loaded comparison DLL from accidentally
measuring the production class binding instead. Historical results are retained.

Client presets and the export plugin exclude the whole addon, including scripts
that Godot can force-export despite preset filters. Existing server-class stubs
cover the new classes. Windows client pack inspection found zero SOCI resources;
headless execution confirmed no native SOCI/SQLite classes and no common endpoint
parse error. Both ServerWindows/ServerUbuntu resource packs contain the addon
descriptor and production scripts. Native libraries remain export dependencies;
resource ZIP inspection is not a standalone/Linux runtime acceptance.

## Verification

Existing smoke/architecture guards passed: ten Godot cases and 78 Web contracts.
Existing market search/migration, purchase and Exchange order suites passed.
Extended the existing two-client bridge/RPC market flow to open Trading Glass,
perform a real asynchronous search and reject a malformed cursor, then exercise
the existing shop/reload/cancel/claim flow. Both market and Exchange headless
network scenarios passed on port 18098, sequentially. No native CEF window was
opened; manual visual/input acceptance remains R6.

`auction_queries` covers new contracts absent from synchronous suites, against
the actual installed native addon and disposable 10k-offer WAL database:
submission returns before completion; independent item/result/cursor parity;
readonly refusal/missing-file startup; changed-path rejection; pending replacement,
account limit, duplicate ID, stale session, scope cancellation and global overflow;
queue-inclusive timeout; deliberately degraded-plan active timeout while physics
ticks progress; bounded busy-drain refusal; coordinated backup/resume, repeated
session restarts, FULL, FK/integrity and final file rename/removal after closure.

```powershell
& .\tests\run-market.ps1 -Scene auction_queries -Marker AUCTION_QUERIES_OK
& .\tests\run-market.ps1 -Scene market_search -Marker MARKET_SEARCH_OK
& .\tests\run-web-inventory.ps1 -Scene market_network
& .\tests\run-web-inventory.ps1 -Scene exchange_network
& .\tests\run-smoke.ps1
git diff --check
```

The `auction_queries` fixture uses `.godot/verification/auction-d1b`; create the
directory before direct invocation. Scope APPDATA to that disposable directory
when running backup assertions. Default smoke still requires no addon download.

D2 remains separate: retarget the historical `market_load` harness to actual
async production requests; 16 simulated producers, real combat/AI/economy load,
queue latency/fairness/tick acceptance and Windows/Linux runtime. The retired
synchronous R0/R2 fixture is not evidence for this path. No new performance
guarantee, Linux runtime, full crash campaign, PostgreSQL or R6 acceptance is
claimed by D1b.
