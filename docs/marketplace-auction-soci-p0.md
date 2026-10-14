# Auction P0 — SQLite plan and godot-soci build diagnosis

Decision recorded 2026-10-14: select published **godot-soci v0.4.1** for the next
auction-reader stage. The 10,000-offer indexed fixture passes the fixed 2-second
gate. Stop for review; this branch does not implement D1 or migrate production.
The unchanged baseline still fails and is not an acceptable D1 configuration.

Source baseline: `codex/auction-soci-s0`, `a6a23f9`. Historical S0 and its v0.4.0
lock remain in [the dispatcher report](marketplace-auction-dispatcher.md).
The new release is separately locked in
`tests/fixtures/auction_soci_release_041.json`: tag commit
`b43e37e97b0c2321c678ab81809085f1863003ba`, ZIP SHA256
`a93c7b4b3a51c16cac336f50dea35fa81df57d106ea557565e9f6f2d460bf0aa`.
The GitHub asset digest and tag commit were checked live, and the loaded DLL
path/hash was checked for each run. Release metadata:
[v0.4.1](https://github.com/PatrykCieszynski/godot-soci/releases/tag/v0.4.1).

## What this protects

The existing search suite protects model behavior but does not separate a slow
query plan, dependency build flags and asynchronous delivery latency. P0 adds
one isolated integration fixture to protect exact item/result/cursor parity,
including descending order, tied-price continuation and empty results, while
keeping a hard query budget. It instruments only downloaded diagnostic sources.
No WorldDatabase, MarketplaceService, Exchange, RPC, wallets, PostgreSQL,
production API, pool or cancel framework is changed.

## Measurement conditions and preserved evidence

Windows x86_64, official Godot 4.7.2 `ed1daf0bf` Debug/editor engine so assertions
run. Windows template_release DLLs are loaded explicitly under that engine;
this does not establish acceptance under a release engine or Linux. No new Linux
CI/host was provisioned. Benchmarks run sequentially, without concurrent builds
or smoke suites. They are latency diagnostics, not sustained-load guarantees.

One synthetic schema-22 fixture contains 10,000 offers. Each state receives a
disposable copy and the same fixture-only tied-price edit. SQL and named bind
values come from the S0 SQL builder unchanged. Both Godot adapters compare full
projected items, results and next cursor with MarketSearchSqlite. Standalone
SOCI checks ordered offer IDs/prices against an export of those same SQL rows;
it copies all columns but does not independently compare complete item models.

States: existing indexes; additional UID-first lookup index; ANALYZE on existing
indexes; additional index plus ANALYZE. No case silently raises the 2,000 ms gate.
Fast cases have two warmups and at least 30 measured warmed samples. Multi-second
diagnostic cases have three warmed samples to bound runtime, and one Godot
warmup after a slow first-connection sample. Standalone uses two warmups. With
n=3 nearest-rank p95 equals max and is only diagnostic evidence.

"Cold" means the first query after opening/configuring a fresh reader, not an
OS-cache purge: fixture setup and prior adapters can warm filesystem pages.
Connection setup is outside the query interval. Each first-connection sample is
preserved separately from warmed samples, so this limitation is observable.
Projection parity checking has a separate timing and is outside query wall_us.

Evidence under [evidence/auction-soci-p0](evidence/auction-soci-p0/):

- `samples.csv`: 6,861 individual samples, including first-connection timings,
  counts, cursors and measured timing components; 27 valid runs.
- `distributions.csv`: p50/p95/max, split by build/state/case/adapter/phase and
  frame-versus-signal wait mode. Empty native timings mean unavailable.
- `plans.json`: actual EXPLAIN output and predicate match counts.
- `provenance.json`: source/build/library/release hashes, runtime compile options,
  gate failures and the controlled link-selection experiment.
- `quick-summary.json`, `wait-mode-comparison.json`, standalone CSVs and exact
  SQL/binding transfer files retain the focused comparisons reported to the user.

No databases, engine/native binaries, accounts, build trees or logs are committed.
Probe runs and invalid `/OD` samples are excluded. MSVC treats `/OD` as an unknown
flag; corrected `/Od` controls were rebuilt and measured. Future build/run scripts
reject D9002/unknown-option diagnostics rather than accepting mislabeled controls.

## Query plan, index and ANALYZE

The expensive broad case uses `monster_damage >= 0`, matches all 10,000 offers,
and returns 51 SQL rows (50 results plus continuation). Existing EXPLAIN:

```text
SEARCH i USING INDEX market_item_search (definition_id=? AND upgrade_level>? AND upgrade_level<?)
SEARCH a EXISTS USING COVERING INDEX affix_search (stat_id=? AND value>?)
SEARCH o USING INDEX sqlite_autoindex_shop_offers_2 (item_uid=?)
SEARCH s USING INTEGER PRIMARY KEY (rowid=?)
SEARCH c USING INDEX sqlite_autoindex_item_custody_1 (uid=?)
USE TEMP B-TREE FOR ORDER BY
```

The correlated EXISTS needs one item's UID. `affix_search(stat_id,value,uid)`
starts with a broad stat/value range and searches many entries repeatedly.
Adding the following index to the copied database makes UID an equality prefix:

```sql
CREATE INDEX affix_item_lookup ON item_affix_index(uid, stat_id, value);
```

Its measured plan changes the EXISTS line to:

```text
SEARCH a EXISTS USING COVERING INDEX affix_item_lookup (uid=? AND stat_id=? AND value>?)
```

ANALYZE alone also fixes this fixture's broad plan. It starts from ordered prices,
uses the existing UID-first affix primary key and avoids the temporary sort:

```text
SEARCH o USING INDEX market_price_search (price_yang>? AND price_yang<?)
SEARCH i USING INDEX sqlite_autoindex_item_instances_1 (uid=?)
SEARCH s USING INTEGER PRIMARY KEY (rowid=?)
SEARCH c USING INDEX sqlite_autoindex_item_custody_3 (uid=?)
SEARCH a EXISTS USING INDEX sqlite_autoindex_item_affix_index_1 (uid=?)
```

With lookup plus ANALYZE, the ordered-price plan uses affix_item_lookup as a
covering EXISTS lookup. Both analyzed states and index-only states preserve
results/cursors. ANALYZE is effective here, but a future migration should make
the UID-first covering index available and collect statistics during migration
or controlled maintenance; this fixture does not prove statistics alone remain
sufficient as the catalog distribution changes. Keep the existing stat-first
index until its other callers and write/storage cost have been reviewed.

Predicate selectivity is measured before LIMIT: default/broad/descending 10,000;
monster minimum 15: 3,334; selective upgrade/price plus two affixes: 80; rare:
3; empty: 0; pagination: 9,951; tied-price continuation: 1. These exercise both
broad and narrow cases, not just a favorable selective filter.

## Adapter comparison and published release improvement

Warmed broad-query wall times in milliseconds. n=3 without the extra index;
n=30 with it. These focused cohorts use the historical frame-wait harness.

| Adapter/build | Existing indexes p50 / p95 / max | Extra index p50 / p95 / max | Indexed native SQL p50 |
|---|---:|---:|---:|
| Installed godot-sqlite 3.51.0, v0.4.1 batch | 5247.780 / 5480.047 / 5480.047 | 23.990 / 40.542 / 47.420 | unavailable |
| Diagnostic godot-sqlite, common SQLite 3.53.4 O2/no DEBUG | 2962.027 / 3023.526 / 3023.526 | 24.415 / 28.844 / 31.674 | 23.9305 |
| Standalone SOCI, common SQLite 3.53.4 O2/no DEBUG | 2760.437 / 3056.176 / 3056.176 | 23.875 / 30.928 / 31.336 | 23.6125 |
| Diagnostic godot-soci, common SQLite 3.53.4 O2/no DEBUG | 2954.724 / 3083.177 / 3083.177 | 33.2315 / 40.272 / 40.567 | 24.1255 |
| Published godot-soci v0.4.0 | 17324.944 / 17365.675 / 17365.675 | 108.9695 / 123.127 / 129.928 | unavailable |
| Published godot-soci v0.4.1 | 2875.459 / 3009.580 / 3009.580 | 33.249 / 40.303 / 40.407 | unavailable |

The three diagnostic implementations share the same SQLite static library;
standalone uses SOCI session/statement/row without Godot or a dispatcher.
The SQL cost is similar across those implementations. Installed godot-sqlite
uses a different SQLite version/build; its baseline difference is not proof that
the SQLite version itself caused the difference. The 3.51 diagnostic variant
was compiled but not measured, and no such causal claim is made.

Published DLLs have no SQL timestamp instrumentation, so their SQL columns stay
unavailable. Diagnostic sql_us measures time inside sqlite3_step, excluding
prepare and row-copy work. native_total_us covers the full worker operation;
prepare, describe, copying, marshaling, queue, delivery wait and Godot conversion
are separately available. SQLite trace profiles are supplemental telemetry.

## Actual SQLite build and controlled flag experiment

Both v0.4.0 Windows DLLs reported SQLite 3.53.4 with DEBUG. Pinned vcpkg
`e456309491fd875487bf02b8a0dca76c1b1b00cc`, sqlite3 port 3.53.4#2, adds
SQLITE_DEBUG, SELECTTRACE and WHERETRACE for its Debug dependency build.
The old workflow used Visual Studio multi-config, omitted CMAKE_BUILD_TYPE,
and built both Godot ABI selectors using `--config Release`.

Pinned vcpkg toolchain lines 437–450 put debug prefixes first when
CMAKE_BUILD_TYPE is undefined or Debug. Generic FindSQLite3 can then select
debug/lib/sqlite3.lib at configure time; a later --config Release does not
reselect that imported library. The isolated prefix experiment reproduced:

| Configure setting | Selected imported library | Executed probe |
|---|---|---|
| CMAKE_BUILD_TYPE undefined, VS multi-config | prefix/debug/lib/sqlite3.lib | SQLite 3.53.4, DEBUG=1 |
| CMAKE_BUILD_TYPE=Release, fresh configure | prefix/lib/sqlite3.lib | SQLite 3.53.4, DEBUG=0 |

This uses actual controlled libraries, not dummy filenames. The archived link
probe was performed with an O2+DEBUG payload in the debug prefix before the
mistyped `/OD` control was corrected; it proves path selection and DEBUG, not
that probe's optimization level. Original historical linker logs were inaccessible
(GitHub Actions log API required additional repository access); the original
exact /Od link configuration cannot be independently recovered from this run.

To measure causality, all diagnostic C++/SOCI code stays Release /MD; only the
SQLite C compile control changes. Local MSVC is 19.51 versus published 19.44;
PostgreSQL is disabled only in the diagnostic target. These are controlled
comparisons, not bit-identical reproductions of the original release.

| SQLite 3.53.4 control | Broad native SQL p50 / p95=max, ms | Warm n |
|---|---:|---:|
| /O2, no DEBUG | 2940.553 / 3069.207 | 3 |
| /O2, DEBUG | 8885.382 / 8895.804 | 3 |
| /Od, no DEBUG | 4960.647 / 5326.096 | 3 |
| /Od, DEBUG | 14990.458 / 15064.328 | 3 |

Both optimization and debug definitions have substantial measured costs.
The v0.4.1 published Windows Release DLL reports SQLite 3.53.4, compiler
msvc-1944 and no DEBUG; its measured performance agrees with the O2/no DEBUG
diagnostic build. Its SHA256 is
`0c13fb5ec209ad16ae1f0038c23feb26ddb8fbb012468cebaf8caad7194ae20b`.
Release v0.4.1 already contains the CI build-selection fix; no further addon
release is required for the performance issue established here.

## The apparent 9 ms addon overhead

The initial harness awaited process_frame while polling in _process, adding
an extra coroutine observation frame. Diagnostic medians: queue 0.007 ms,
marshal 0.020 ms, conversion 0.230 ms, finished-to-poll wait 1.146 ms, and
unattributed script/call interval 7.5095 ms. Component medians are not additive.

Waiting on the existing completed signal with unchanged polling placement,
SQL and DLL produced the following 30-sample comparison:

| Build | Frame wait wall p50 / p95 / max, ms | Signal wait wall p50 / p95 / max, ms |
|---|---:|---:|
| Diagnostic O2/no DEBUG | 33.2315 / 40.272 / 40.567 | 26.401 / 33.255 / 33.418 |
| Published v0.4.1 | 33.249 / 40.303 / 40.407 | 26.4025 / 32.670 / 32.772 |

The residual drops to 0.777 ms; SQL stays near 24 ms. Poll cadence still adds
latency and depends on server frame scheduling. The published SociAsyncDatabase
wrapper already awaits completed. This is a harness correction using an existing
API, not an addon API change. Future P0 runs default to v0.4.1 and signal wait.

## Final v0.4.1 indexed acceptance matrix

Fresh final run, signal wait, 30 warmed samples per case/adapter. Exact model and
cursor parity passed, as did integrity_check and foreign_key_check. Every cold,
warmup and warmed query stayed within 2 seconds. No database path survives in
production. Times below are full request delivery, not inferred SQL durations.

| SOCI case | Matching offers | SQL rows | p50 ms | p95 ms | max ms |
|---|---:|---:|---:|---:|---:|
| Default | 10000 | 51 | 19.070 | 25.324 | 25.409 |
| Broad | 10000 | 51 | 32.780 | 39.317 | 47.406 |
| Medium | 3334 | 51 | 26.383 | 33.014 | 33.356 |
| Selective | 80 | 51 | 6.043 | 12.730 | 12.800 |
| Rare | 3 | 3 | 6.710 | 6.837 | 6.906 |
| Empty | 0 | 0 | 6.812 | 13.763 | 13.919 |
| Descending | 10000 | 51 | 19.401 | 24.659 | 26.117 |
| Pagination | 9951 | 51 | 12.607 | 18.833 | 19.178 |
| Tied-price pagination | 1 | 1 | 6.831 | 13.667 | 13.767 |

The installed godot-sqlite comparison in this same final batch also passed all
nine cases; its maximum was 166.630 ms. Native timing conclusions use diagnostic
cohorts, not this opaque published binary's request latency.

## Game changes versus addon changes and D1 recommendation

Game-side next step: make the UID-first index available through the existing
schema/migration policy, collect statistics, and retain named SQL semantics and
exact cursor parity. No SQL rewrite is required to pass this fixture. Recheck
the 2-second gate on the integrated production query shape before shipping D1.

Addon-side performance fix: explicit optimized Release dependency selection for
both Godot ABI selectors, plus a build regression that checks the actually
executed SQLite DEBUG option and imported link target for Windows Debug/Release.
This minimal change is already published in v0.4.1. Integration should use
completed signals, as the wrapper already does; no extra worker fixes slow SQL.
S0's generic native error-message issue is separate and is not claimed solved
by this performance release. Error classification/lifecycle coverage remains
part of the existing S0 evidence and future addon regression review.

**GO after review for a bounded readonly auction-reader D1 using v0.4.1 and the
indexed query configuration; NO-GO for the current unindexed broad query.**
The user selected godot-soci after reviewing the quick comparison. This branch
stops at P0 review; it does not automatically begin D1, install a production
reader or merge into the integrated baseline.

## Repeat and cleanup

Install the separately pinned release explicitly, seed only disposable storage,
then run the current acceptance cohort:

```powershell
python tests/prepare-auction-soci-041.py --install
& .\tests\run-auction-p0.ps1 -Seed
& .\tests\run-auction-p0.ps1 -State lookup
# Expected FAIL: the fixed gate must reject the baseline broad query.
& .\tests\run-auction-p0.ps1 -State baseline -Case broad
# Historical observation-delay comparison:
& .\tests\run-auction-p0.ps1 -State lookup -Case broad -WaitMode frame
git diff --check
& .\tests\run-smoke.ps1
```

For controlled C++ experiments, prepare pinned sources explicitly, build with
the installed Visual Studio/CMake toolchain, then select a diagnostic profile:

```powershell
python tests/prepare-auction-soci-s0.py --install
python tests/prepare-auction-p0.py --download
& .\tests\build-auction-p0-native.ps1 -CmakeExecutable C:\path\to\cmake.exe
& .\tests\run-auction-p0.ps1 -Profile diag-353-o2-nodebug -State lookup
cmake -S tests/fixtures/auction_p0_native/pure_build -B .godot/verification/auction-p0/native/pure-build -G "Visual Studio 18 2026" -A x64 "-DP0_NATIVE=$($PWD.Path.Replace('\','/'))/.godot/verification/auction-p0/native" -DP0_VARIANT=353-o2-nodebug
cmake --build .godot/verification/auction-p0/native/pure-build --config Release
& .godot/verification/auction-p0/native/pure-build/Release/pure_soci.exe "$($PWD.Path.Replace('\','/'))/.godot/verification/auction-p0/diag-353-o2-nodebug-lookup-signal/lookup.db" .godot/verification/auction-p0/diag-353-o2-nodebug-lookup-signal/lookup-broad-pure.txt 30
```

Standalone emits first-connection and warmed CSV timings, returns 1 for invalid
input/parity failures and 2 for a budget failure. Historical standalone baseline
measurements preceded the exit-code guard; their failures are explicitly
classified in the saved summary rather than treated as PASS.

After preserving evidence, use the existing cleanup tool's scoped selector:

```powershell
& .\tools\clean-dev-artifacts.ps1 -VerificationPaths auction-p0 -WhatIf
& .\tools\clean-dev-artifacts.ps1 -VerificationPaths auction-p0
```

Only named children of .godot/verification are removed. Path escapes are
rejected. The selected release cache, engine binaries, editor/import cache,
installed root addons, other tasks' diagnostics and runtime stores are preserved.
The cleanup deleted ephemeral DBs, builds, downloaded diagnostic source trees
and logs after export. Default smoke passed ten Godot cases and 78 Web contracts;
both architecture checks and git diff --check passed. No native client UI,
Linux runtime, PostgreSQL or production D1 acceptance is claimed.
