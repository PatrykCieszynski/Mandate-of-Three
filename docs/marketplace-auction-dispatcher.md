# Auction dispatcher — D0 thread/SQLite boundary proof

Status: **Windows D0 PASS; Linux runtime gate remains NOT VERIFIED**. Stop for
review here. D1 production dispatcher and D2 acceptance are not implemented.
R6 remains paused. Branch starts from shop 712e9f4, including accepted R0–R4.

## Scope and ownership

Only repeatable test fixtures/runners and this evidence document were added.
WorldDatabase, MarketplaceService, MarketSearchSqlite, RPC/CEF, migrations,
matching, wallet/receipt code and the synchronous 5/s search gate are unchanged.
Production Trading Glass is still synchronous until a separately accepted D1.

`tests/fixtures/auction_read_probe.gd` is a one-slot diagnostic controller, not the
production queue/dispatcher. One real Godot Thread constructs, configures, queries,
closes and drops its own SQLite object. Main owns the writer and runs production
Shop/Yang operations. Mutex protects copied job/result/state containers; Semaphore
wakes the worker. Only strings, scalars, arrays/dictionaries of data cross the
boundary. No SceneTree, nodes, ItemDefinitions, ItemInstance, mutable Resources,
RPC, runtime wallets or writer SQLite object enter the worker. Row-to-item
projection occurs on main. Thread safety checks remain enabled.

The proof verifies distinct thread IDs and live SQLite object IDs, and matches
main physics ticks and COMMIT timestamps against each actual SQL start/end
interval. Worker lifetime owns open/close even during pause/resume and failure.
This demonstrates concurrency, not a deferred synchronous call.

## API/source audit and binary provenance

Pinned engine: Godot 4.7.2 stable, ed1daf0bf; plugin metadata godot-sqlite 4.7,
GDExtension minimum 4.5. Source audit used upstream tag v4.7, commit
162ffbae0b0c8a933ba63bbb50da6cc0402950f8, in an ignored reference checkout.
Source inspection is not treated as proof that a differently built binary is safe;
actual installed binaries were exercised and fingerprinted.

- [Plugin source](https://github.com/2shady4u/godot-sqlite/tree/v4.7): gdsqlite.cpp
  open_db selects custom Godot VFS for read_only=true. Normal mode uses native VFS
  with SQLITE_OPEN_URI. The custom file IO table is version 1, without WAL shared
  memory callbacks. SConstruct does not override SQLite THREADSAFE in this tag.
- [SQLite threading modes](https://www.sqlite.org/threadsafe.html): independent
  handles are mandatory here; neither connection is concurrently shared.
- [SQLite URI mode](https://www.sqlite.org/uri.html): documented mode=ro selects a
  native read-only file connection. No immutable=1, nolock or shared-cache shortcut.
- [Godot thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html): no active SceneTree or shared mutable Resources in worker;
  container resizing/handoff is protected with Mutex.

Runtime on both tested Windows DLLs: SQLite 3.51.0, THREADSAFE=1, MUTEX_W32. The
runner checks the actually loaded module (including console-launcher child), then
records its SHA-256, rather than trusting a filename or version string alone.

| Installed native binary | SHA-256 | Runtime evidence |
| --- | --- | --- |
| windows.template_debug.x86_64.dll | F5E0951F88666C5C06B927C099D0A22BCB53C6590E5E34B21AB24D8C167FEBD6 | PASS |
| windows.template_release.x86_64.dll | 2C9BF5B7620355FA9A0EF590C6BE5FFCCB069CB4123701BAEAD42F6009AF42A8 | PASS |
| linux.template_debug.x86_64.so | 16CF443EB2EA2FEAA5D4D4146D009B01D2BF447FC5F6EB2B1BC2B8D839D35755 | NOT VERIFIED |
| linux.template_release.x86_64.so | D68B69E7AC2F5632E462B3A8F5D1C72DAF4A5042F991B70EA863884CF2FF765B | NOT VERIFIED |

## Read-only mode finding

**Do not use this plugin's read_only=true custom VFS for the live WAL reader.**
On both Windows binaries open_db succeeds, but the first schema SELECT fails with
`unable to open database file` while the live database uses WAL. The fixture
retains that failure as an explicit diagnostic result, not a silently successful
startup. A checkpointed standalone/PCK read is a different use case.

The validated alternative uses the plugin's existing native URI support:
read_only=false, default_extension="", path=file:///.../market.db?mode=ro, followed
by PRAGMA query_only=ON. URI is built from a resolved physical path with reserved
characters escaped, on main. The worker connects only after schema 22/WAL setup.
INSERT, UPDATE and CREATE TABLE are rejected. Turning query_only OFF still does
not permit INSERT, proving OS/SQLite read-only mode rather than just that PRAGMA.
A missing path is refused without creating a DB. No schema migration runs in worker.
The authoritative writer remains synchronous=FULL throughout.

Expected error diagnostics: custom-VFS WAL refusal, attempted read-only mutations
and the deliberately missing database. These are separately asserted negative
cases. Thread warnings, script/parse errors, unexpected locks, failure of the
positive marker or wrong loaded binary fail the runner.

## Concurrent execution and transactional visibility

Use the existing 10,000-offer indexed catalog fixture plus one real test offer.
That additional offer is purchased during the stress phase, leaving 10,000. The
three-second thread-boundary load batches four default Trading Glass SELECTs
without bonus filters; every SELECT's native execution interval is recorded.
The worker returns 51 raw rows (50-result limit plus cursor lookahead). It does
not build item snapshots. This is not a 16-client dispatcher throughput test or
combat/AI acceptance; those remain D2.

Main concurrently commits a production offer edit, shop/account configuration,
purchase with pending Yang and subsequent critical wallet spends. The exact
purchased UID, single receipt, balances, ownership and final account name are
verified in the current DB and/or restored backup. An uncommitted writer price
change is invisible; a later committed revision is visible to the next reader query.

| Profile | Worker SELECTs | Main ticks | Writer operations | Ticks during SQL | Commits during SQL | SQL p50 / p95 / max ms |
| --- | --- | --- | --- | --- | --- | --- |
| Windows debug DLL (final root fixture) | 240 | 181 | 30 | 179 | 27 | 8.722 / 11.127 / 18.669 |
| Windows release DLL (diagnostic server pack) | 240 | 182 | 30 | 181 | 29 | 8.627 / 11.606 / 16.327 |

No unexpected DB lock errors or thread warnings occurred. Both profiles pass
FK/integrity checks, copied-data handoff, clean stop/join, four repeated restarts,
missing-file refusal and final file rename/removal after all handles close.
These are local development observations, not throughput/latency guarantees.

## WAL checkpoint/backup pause contract demonstrated

The worker deliberately holds a read transaction at a controlled test barrier.
Main commits an account change afterwards. Existing production backup_database()
correctly refuses TRUNCATE while that old snapshot is active; no success/stale
copy is claimed. A 50-ms reader-drain deadline expires while the test barrier is
held; backup is still refused. The test then releases the read, finishes its
result, closes reader **on worker**, acknowledges paused state, and only then
runs the production checkpoint+copy. The restored file contains the latest
account change, transferred UID and exactly one purchase receipt, with clean
FK/integrity checks. Reader resumes against the current DB and sees new data.

D1 must stop admissions, drain/abort bounded jobs, acknowledge reader closure,
checkpoint/copy on the writer, and resume. Main should poll/yield during drain,
with a bounded deadline; failure must refuse backup/handoff/shutdown rather than
force-kill a live SQLite thread. The stock backup function was not changed in D0.
It still refuses active readers until that coordination is wired in D1.

## Separate query-plan risk found during the proof

The first stress SELECT included a broad monster_damage minimum=0 predicate.
EXPLAIN on the disposable 10k DB selected the stat/value affix_search index for
a UID-correlated EXISTS, repeatedly scanning many affix entries. One identical
SELECT measured 3.310 s in a standalone SQLite diagnostic; a four-query worker
batch exceeded the two-second result deadline. It was a slow plan, not evidence
of cross-thread handle sharing. The final boundary proof uses the exact default
no-bonus SELECT used by R0/R2 and records that scope explicitly.

This remains a real input/capacity risk for D1/D2. Preserve bonus semantics but
inspect/tune the UID-correlated lookup plan and measure broad filters. A threaded
queue alone does not bound the duration of one SQL statement. No production query
or index change, timeout relaxation, progress-handler patch or hidden retry was
made in D0. Do not interpret the successful default-read proof as proving all
bonus predicates fast or cancellable.

## Repeat and platform limits

Windows debug/root:

```powershell
& .\tests\run-auction-d0.ps1
```

Diagnostic packs and actual release DLL (installed addon/presets stay unchanged):

```powershell
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --export-pack ServerWindows .godot/verification/auction-d0-ServerWindows.zip
& .\.godot\Godot_v4.7.2-stable_win64_console.exe --headless --path . --export-pack ServerUbuntu .godot/verification/auction-d0-ServerUbuntu.zip
python tests/prepare-auction-d0-packs.py
& .\tests\run-auction-d0.ps1 -MainPack "$PWD/.godot/verification/auction-d0-ServerWindows-release-library.zip" -Label windows-release-library -ExpectedLibrary libgdsqlite.windows.template_release.x86_64.dll
```

The copied diagnostic pack maps the debug-engine selector to the release library
so that the pinned editor can test that actual DLL. This is **not** a native
release-executable test; local export templates are 4.5.1, not the pinned 4.7.2.
The fixture requires the 4.7.2 editor/debug engine because its assertions are
part of the proof. Native libraries remain external installed dependencies;
the resource ZIP alone is not a standalone server distribution.

ServerWindows and ServerUbuntu diagnostic resource packs were built successfully.
Both include the compiled proof/worker. Packaging does not prove Linux execution.
Ubuntu WSL launch failed with HCS_E_HYPERV_NOT_INSTALLED / virtualization disabled.
No Windows features, BIOS settings or distro were installed/changed. A provisioned
Linux host with pinned editor/debug Godot and the installed matching native addons
can run the same proof (the shell runner also needs `rg`):

```bash
bash tests/run-auction-d0.sh /absolute/path/to/Godot_v4.7.2-stable_linux.x86_64
# Optionally append label and the prepared diagnostic pack path.
```

Default smoke remains separate: ten Godot cases and 78 Web contracts. Runtime
accounts/DBs, source reference checkout, native binaries, diagnostic packs and
logs stay ignored. Logs have fixed names under .godot/verification and disposable
DBs are restricted to that directory. Runners pass an explicit project root so
the safety guard also works when `res://` resolves relative to a diagnostic pack.
Full Windows+Ubuntu D0 portability gate
remains conditional until the Linux runtime proof is supplied. Stop at D0 review.
