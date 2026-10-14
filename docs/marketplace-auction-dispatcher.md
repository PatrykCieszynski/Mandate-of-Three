# Auction dispatcher — D0 thread/SQLite boundary proof

Status: **Windows D0 PASS; S0 SOCI boundary verified on Windows, query-budget
gate FAIL / D1 NO-GO; Linux runtime remains NOT VERIFIED**. Stop for review here.
D1 production dispatcher and D2 acceptance are not implemented.
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

## S0 — released godot-soci proof (2026-10-14)

S0 starts from `codex/auction-d0` at `357f82d`, on
`codex/auction-soci-s0`. Only diagnostic tests, release pinning and this evidence
are changed. No World/Shop/Exchange/RPC, schema, production search, client export
preset, transaction owner or addon source change is part of S0. D1 and R6 do not
start here. Per the subsequent user instruction, Linux execution is deferred;
the existing game CI has only a Windows job, so no new Linux CI was introduced.

### Released dependency and server delivery boundary

The installed package is the published **prerelease**
[v0.4.0](https://github.com/PatrykCieszynski/godot-soci/releases/tag/v0.4.0),
not a source ZIP or a build of the latest main:

- Tag commit: `a9229e4af0a5420f681c19211de25bf181467fae`.
- Asset: `godot-soci-v0.4.0.zip`, 27,984,082 bytes.
- ZIP SHA-256: `6c1b906c3e12d86dfb1d69cf7061a1030ecb43fbf9cc25e76fe7d508d492da0f`.
- `tests/fixtures/auction_soci_release.json` pins every archived file hash.
  The preparation tool verifies the ZIP, exact payload inventory and every
  installed file before the runner launches Godot. An intentional README
  mutation was rejected; the original bytes were restored.

| Native payload | SHA-256 | Execution |
| --- | --- | --- |
| Windows Debug | `c5dfd597e2b462040dae6cf0c98fa1d764b1cddda23fbf8e66c201c0c95a5fc2` | Exercised on Godot 4.7.2 Debug |
| Windows Release | `397e67031639341f39e602ebc3c8e5562262ef6e3ae31e3ebd76c32eff52956a` | Diagnostic Release-library selector under Debug engine |
| Linux Debug | `c69ec979f1505437ecf857ba75cbd90b8e2feecdc375886bd7faaae781fc1d36` | NOT VERIFIED |
| Linux Release | `490e9315deac0982b5afd03072bd6a848b3684979304052da1bceee349856668` | NOT VERIFIED |

PE/ELF dependency inspection covers all four files. Windows requires the dynamic
MSVC runtime (`MSVCP140`, `VCRUNTIME140`, `VCRUNTIME140_1`, Universal CRT) and
Windows system DLLs; the exercised native payloads resolve on this host. Linux
DT_NEEDED lists only `libc.so.6`, `libm.so.6` and `ld-linux-x86-64.so.2`, with
GLIBC symbol requirements up to 2.34. Linux dependency resolution and execution
remain NOT VERIFIED. SQL libraries, libpq and their other dependencies are
linked into the native payload; absence of an external libpq DLL does not make
the extension suitable for shipping in the game client. License texts remain
with the ignored package.

S0 installs exclusively below `.godot/verification/soci-release/package` and
loads the extension explicitly from the diagnostic scene, via
`GDExtensionManager.load_extension`. It is not installed in the root `addons/`,
registered in the root extension list, or included in ordinary client/server
exports. Thus S0 adds no SQL library or PostgreSQL credentials to client packages.
Future server delivery must be an explicit server-only staging step: copy the
verified complete addon, descriptor and licenses into a dedicated server package,
load it from the server bootstrap, and check that the corresponding client
package contains no SOCI/native SQL payload. Production staging/bootstrap wiring
is a D1 review decision, not implemented in this diagnostic milestone.

### SQLite readonly and native worker boundary

The pinned [SOCI backend source](https://github.com/SOCI/soci/blob/a9e51707d565baa6e02634453d5e81b84062c94a/src/backends/sqlite3/session.cpp)
supports `dbname='physical/path' readonly=true timeout=1`. `readonly` selects
`SQLITE_OPEN_READONLY`, clearing READWRITE/CREATE; this uses SQLite's native VFS.
No `immutable`, shared-cache or Godot custom VFS shortcut is used. `timeout=1`
is the backend's busy/lock timeout in seconds, not a SQL execution deadline.

The reader's actual SQLite reports 3.53.4 / THREADSAFE=1 / WAL. The writer remains
the installed godot-sqlite with WAL, synchronous FULL and production schema 22.
The test reads committed WAL frames after a checkpoint, rejects dirty/uncommitted
changes and sees a new committed value in the next query. INSERT, UPDATE, DELETE,
CREATE TABLE and DROP TABLE all fail with query_only both ON and OFF. The same
statements succeed on the writer inside rolled-back savepoints, proving that
these are valid mutations rather than invalid SQL. Data and sqlite_master remain
unchanged by the reader. A missing physical DB is rejected without creating it.

[Native dispatcher source](https://github.com/PatrykCieszynski/godot-soci/blob/a9229e4af0a5420f681c19211de25bf181467fae/src/query_dispatcher.cpp)
shows one thread-owned SOCI session and copied C++ job/result data.
Godot Dictionary/Array conversion occurs in main-thread `poll()`. The fixture
checks data-only results and main-thread completion delivery, and calls the
resource-dependent item projector only on main. It reproduces current SQL in a
test-only builder with named `:parameters` and compares all projected results
and cursors with unmodified MarketSearchSqlite, for ascending/descending default
search, both pagination directions, broad affix and selective two-affix filters.

The released API does not expose native SQL start/end timestamps. Measurements
are **submission-to-result-delivery latency**, including queue and poll delay;
COMMIT overlap is measured against pending request intervals. Unlike D0's
instrumented GDScript worker, these measurements do not independently identify
the precise native execution interval or worker thread ID. No native timing
or production-capacity claim is inferred from them.

### Production economy, lifecycle and regression evidence

The three-second stress phase executes production listing, price edit, purchase
by another account, pending Yang income and subsequent critical spends while
native default reads are pending. The exact UID ends in buyer bag custody and
item ownership, the purchase has exactly one durable receipt, and SQL balances
match authoritative RAM. Assertions repeat on the independently opened backup
and after four worker restarts. Existing smoke protects economic rollback and
other writer contracts; no writing economic operation is delegated to SOCI.

Lifecycle stops diagnostic admissions, refuses new submissions, polls/yields
until pending()==0, and only then calls blocking stop(). A queued real search
finishes before the session is joined/closed. Only after closure does existing
WorldDatabase.backup_database() checkpoint/copy the main DB. Opening the backup
checks UID/custody, receipt, balances, FKs and integrity. The reader restarts four
times and reads 10,000 remaining offers. Final main-file rename/removal proves
handles were released. Every DB and user-data backup lives under the fixed,
guarded `.godot/verification/auction-soci-s0-*` diagnostic directories.

The two-second query budget is unchanged from D0. When exceeded, the test records
FAIL and continues polling only to obtain diagnostic samples and drain the real
read; it never calls stop() on an active SQL or claims successful overall
acceptance. The separate five-minute process watchdog is for the entire set of
benchmark samples, not a relaxed query timeout. Backup checks after completed
drain are lifecycle evidence; they do not override the failed query-budget gate.
The runner exits nonzero on recorded deadlines, wrong loaded native library,
script errors, unexpected locks or thread-safety errors. If the whole-run watchdog
expires, it leaves the diagnostic process alive for drain and reports its PID;
it never force-destroys an active native session or claims a backup-safe result.
The preparation tool checks resolved fixture paths before any DB cleanup,
including symlinks, in addition to the in-scene disposable-path guard.

Windows Debug completed all boundary/economy/search/lifecycle checks without
unexpected locks, script errors or thread warnings, but **failed the query budget**
for all five broad-affix and all five selective samples. Default stress had
41 queries, 182 main physics ticks and 30 committed writer operations; all 30
commits fell within pending default-read intervals. Across asynchronous phases
including slow-filter diagnostics, 6,446 physics ticks and 1,074 writer operations
progressed; maximum observed main process-frame gap was 15.075 ms and poll cost
0.406 ms. Synchronous reference searches run outside these measured phases.

### Benchmarks and D1 decision

The following initial Windows Debug sample is a local diagnostic measurement,
not a throughput guarantee. Five samples per query profile make p95 equal to
the maximum; this small sample is sufficient to show a multi-second budget
failure, not characterize a tail-latency distribution.

| Query | Samples | p50 ms | p95 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| Concurrent default | 41 | 67.479 | 94.343 | 96.302 |
| Default | 5 | 66.672 | 73.450 | 73.450 |
| Pagination ascending | 5 | 66.597 | 84.228 | 84.228 |
| Default descending | 5 | 74.170 | 87.207 | 87.207 |
| Pagination descending | 5 | 73.502 | 75.971 | 75.971 |
| Broad monster_damage >= 0 | 5 | 17212.690 | 17647.855 | 17647.855 |
| Selective upgrade/price + two affixes | 5 | 3116.374 | 3346.650 | 3346.650 |

The actual pinned Windows Release DLL was then exercised through a generated
diagnostic descriptor under the same Debug engine, retaining all assertions.
Its loaded module path and SHA-256 were recorded by the runner. It also completed
all behavioral/lifecycle checks and failed the same ten query deadlines:

| Release-library query | Samples | p50 ms | p95 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| Concurrent default | 42 | 67.538 | 81.313 | 98.828 |
| Default | 5 | 73.327 | 96.696 | 96.696 |
| Pagination ascending | 5 | 80.403 | 87.379 | 87.379 |
| Default descending | 5 | 73.445 | 87.214 | 87.214 |
| Pagination descending | 5 | 73.571 | 86.554 | 86.554 |
| Broad monster_damage >= 0 | 5 | 16978.235 | 17556.708 | 17556.708 |
| Selective upgrade/price + two affixes | 5 | 3047.287 | 3263.843 | 3263.843 |

Release-library stress likewise had 182 physics ticks / 30 commits while requests
were pending. Across all asynchronous phases, 6,355 ticks and 1,059 production
writer operations progressed; maximum main-frame gap was 15.822 ms and poll cost
0.486 ms. Writer reference broad/selective SQL measured 5,123.825 / 216.025 ms.
This is a native Release-library test, not a native Release engine executable test.

Both the writer and reader EXPLAIN plans retain an EXISTS lookup via
`affix_search(stat_id,value,uid)` under the item lookup. The current production
writer reference measured 5,246.037 ms for broad affix and 224.189 ms for the
selective request on the same fixture. Production SQL/indexes are unchanged;
threading does not repair this plan. The Windows native Release payload also
reports SQLite's `DEBUG` compile option; investigate its linked SQLite build
configuration before treating the filename as an optimized dependency build.

Issues for godot-soci review, with no addon changes made here:

1. Expected readonly failures and missing-file connection errors are collapsed
   to generic `non-standard native exception` messages in the Windows package.
   Preserve driver messages/error codes so callers can classify readonly,
   missing-file, busy and other failures. The underlying cause of this exception
   reporting is not established by S0.
2. Check the SQLite build configuration linked into the released Windows
   Release DLL, which reports `DEBUG` and remains substantially slower than
   the current writer on filtered reads. Configuration causality requires addon
   build investigation; this runtime observation alone does not prove it.
3. The dispatcher exposes neither native query duration nor active-statement
   cancellation. A future long-query shutdown contract needs an explicit
   decision. S0 adds no cancellation framework and makes no such guarantee.
4. Computed SQLite columns such as COUNT / EXPLAIN IDs / SELECT 1 can arrive as
   strings. The test normalizes known numeric fields on main and verifies actual
   auction projection parity. D1 must preserve that explicit conversion boundary.

**Decision: GO for technical feasibility of a separate native readonly WAL
reader on the tested Windows engine; NO-GO for D1 with the current released
payload/query-budget combination.** The slow plan and addon build/diagnostic
issues need review first. Linux remains NOT VERIFIED under the revised scope,
rather than an additional requirement to provision a host during this run.

### Repeat S0

Pinned Godot 4.7.2 stable `ed1daf0bf`, x86_64, Debug/editor engine is required so
assertions run. Install explicitly once; subsequent test runs never download:

```powershell
python tests/prepare-auction-soci-s0.py --install
& .\tests\run-auction-soci-s0.ps1
# Additional native Release-library diagnostic, still under the Debug engine:
& .\tests\run-auction-soci-s0.ps1 -NativeRelease
git diff --check
& .\tests\run-smoke.ps1
```

The broad/slow-filter budget gate currently makes the S0 runner exit nonzero.
Read the AUCTION_S0_REPORT / AUCTION_S0_FAILED markers and report.json rather
than calling that a PASS. Readonly refusal diagnostics are asserted negative
cases. Common engine certificate/resource teardown warnings do not override
project-specific evidence or hide a SCRIPT ERROR.

Logs are fixed `auction-soci-s0-windows-{debug,release}.{out,err}.log` files under
`.godot/verification`; reports are in the corresponding diagnostic directory.
Binary audit is `soci-release/provenance.json`. Installed native binaries,
release archive, fixture stores, backups and logs remain ignored.

On a separately provisioned Linux host (not executed during S0):

```bash
python3 tests/prepare-auction-soci-s0.py --install
bash tests/run-auction-soci-s0.sh /absolute/path/to/Godot_v4.7.2-stable_linux.x86_64
```

Default smoke and both architecture checks passed on Windows: ten Godot cases
and 78 Web contracts. No native client UI, PostgreSQL, Linux runtime or release
engine executable acceptance is claimed. Stop after S0 and wait for review.

## P0 follow-up and selected release

[The P0 diagnosis](marketplace-auction-soci-p0.md) separates correlated affix-plan
cost, SQLite build configuration and coroutine delivery latency. Published
godot-soci **v0.4.1** is the selected next-stage release; the original v0.4.0 S0
pin remains historical evidence. With the additional UID-first affix index,
v0.4.1 passes all nine 10,000-offer fixture cases at the unchanged 2-second gate.
P0 includes saved timing/EXPLAIN/build evidence and repeatable diagnostic sources,
then stops for review. No production index migration or D1 reader is implemented
by this follow-up.

## D1a — production index, pending review

After accepting the SOCI/P0 choice, [D1a](marketplace-auction-d1a.md) adds the
atomic startup v22->23 UID-first index migration. It leaves production search
synchronous and retains godot-sqlite as the economy writer. D1b reader/RPC
integration waits for this stage's review.
