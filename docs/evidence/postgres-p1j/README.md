# PostgreSQL P1j — Auction search evidence

Windows, PostgreSQL 18.6, Godot 4.7.2 and pinned godot-soci v0.4.2
(`222cfec77acbdb15fa7cd6f6c97d7064126a947a`). Fresh owned SCRAM loopback
cluster and SQLite fixtures only; no installed PostgreSQL service or player data.

Final native fixture `run-6qx3inj0` PASS with `POSTGRES_AUCTION_PARITY_OK` and
`POSTGRES_AUCTION_SEARCH_OK`. The owned cluster was stopped. Raw logs/EXPLAIN
remain ignored under `.godot/verification/postgres-readiness/`.

Verified:

- Identical complete rows, item metadata and cursors through all pages of shared
  valid three-Shop SQLite/PostgreSQL data. Both sorts, equal prices, upgrade and
  price boundaries (including maximum price), 1/7/50-entry pages, no-result and
  multiple definitions, rolled AND filters, duplicate rolls and negotiable tail.
- Paused Shops are absent; no-price listings are last in both price orders and
  appear only for an unbounded price range. Hex-ID tie/continuation ordering is
  explicitly binary/C, independent of default PostgreSQL locale.
- Invalid shape/definition/injection string, invalid cursor, duplicate stat filter,
  nonfinite minimum and over-limit payload refusal before SQL.
- Populated backfill, duplicate-roll ordinality, mutation/rollback, deletion cascade
  and injected projection-write failure preserving the old item and index.
- Malformed numeric-string rolls reject rather than silently become numeric
  projection values. Failed DDL/backfill/version transaction leaves existing
  items and no partial projection table. Repeated/future-version readiness checks.
- Refused nested transaction retains caller ownership; closed/read-failed session
  returns storage, reopen restores searches. A separately owned native read-only
  session searches, denies mutation and remains usable afterward.

Local synchronous read observations: 10,000 active fixed-price offers, 500 Shops,
valid 2-cell footprints and matching per-account character provenance. The 59
remaining earlier parity offers are in paused Shops. Thirty samples per cohort,
limit 50, warm initialized database with explicit ANALYZE; no concurrent writers.

| Rolled filters | Native call p50 | Native call p95 | Call + projection p50 | Call + projection p95 |
| --- | ---: | ---: | ---: | ---: |
| 0 | 34.179 ms | 42.201 ms | 35.362 ms | 44.159 ms |
| 1 | 38.912 ms | 39.744 ms | 40.205 ms | 41.186 ms |
| 2 | 42.413 ms | 54.907 ms | 43.989 ms | 57.191 ms |

Native call time includes preparation, libpq/SOCI, row conversion and fetch; it is
not isolated server execution time. No process_frame/signal scheduling delay is
included. These are host-specific observations, not PostgreSQL-versus-SQLite
speed claims, concurrent capacity, World tick latency or P4 acceptance. EXPLAIN
is recorded without forcing planner indexes. Bulk seeding uses bounded fixture
transactions without changing statement/deadline limits.

Existing SQLite `market_search` PASS (10k queries, mutations, migrations, restart).
`auction_queries` PASS for real async parity, request/budget dedup, session guards,
deadlines, backup drain/recovery and restart. The first non-isolated invocation
could not write its user:// backup under the restricted environment; the complete
suite passed with APPDATA/LOCALAPPDATA redirected into the workspace fixture.
No production lifecycle or sandbox policy was changed.

Default smoke PASS: 14 Godot cases, architecture checks, 85 Web/bridge tests.
Python AST, whitespace and hashes of all 45 unrelated local files verified.
Existing SQLite `run-auction-load.py` PASS: server, client1 and client2, 10k offers,
16 simulated sources plus two RPC clients, combat/AI, mutations, backup/restart/
reconnect and bounded overload. This verifies the retained SQLite production path,
not PostgreSQL World execution. Single-run observations:

| SQLite phase | Completed searches | Search e2e p95 | Tick interval p99 | Physics work p99 |
| --- | ---: | ---: | ---: | ---: |
| combat only | 0 | — | 16.780 ms | 1.418 ms |
| combat + search | 245 | 201.195 ms | 16.779 ms | 1.735 ms |
| combat + search + writes | 226 | 317.894 ms | 19.542 ms | 4.012 ms |
| write burst | 238 | 218.626 ms | 16.732 ms | 14.898 ms |

These include current queue/rate-limit behavior and are not paired baseline
comparisons or a capacity claim. Raw results remain ignored in
`.godot/verification/auction-d2/results.json`.

Not verified/completed: Linux, PostgreSQL runtime clients/CEF, concurrent PostgreSQL
mixed workload or load/soak, worker/pool/admission integration, broad P2, P3/C5 or
cutover. The game retains its existing SQLite reader and scheduler.
