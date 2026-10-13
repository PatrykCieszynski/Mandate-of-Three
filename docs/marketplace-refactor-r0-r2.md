# Marketplace refactor: R0–R2

Scope: economic safety and search load control only. R3/R4 service/composition,
R6 claims UX and Gateway session expiry remain separate review packages. No
migration, trade-model change, PostgreSQL or generic persistence interface.

## R0 baseline — 2026-10-13, shop 440bc89

Marketplace custody/purchase/search, Exchange ledger/orders, two-client market
race/Exchange retry, Yang and Web Inventory passed before runtime edits. Existing
fault injection, offline settlement, successful durable replay and process-crash
WAL recovery remain regression gates. Recovery/backup passed with FK/integrity
checks. FULL receipt commit p50 0.569 ms / p95 0.767 ms (50 local samples).

1024 distinct unavailable cancel requests inserted **1024 durable rows** into
market_commands, taking 1973.888 ms. This is the uncovered R1 abuse contract.

`market_load` reuses the legal 10k-offer seed from `market_search`, runs production
World physics, AI, accepted Warrior impacts and replication with two real clients.
Test probes surround the whole physics traversal. Tick interval is monotonic wall
clock between traversals (includes scheduling/main-thread delays), not supplied
physics delta. Each phase is six **wall-clock** seconds. Sixteen emulated query
sources submit a synchronous burst at most once per 125 ms (<=8/s/source); no test
queue/catch-up. This isolates the expensive-query path at the aggregate permitted
client load; it is not a claim that 16 authenticated network clients were tested.

| Baseline phase | Accepted/rejected searches | Physics work p50 / p95 / p99 ms | Tick interval p95 / p99 / max ms |
| --- | --- | --- | --- |
| Combat only | 0 / 0 | 0.572 / 0.936 / 1.266 | 20.712 / 20.779 / 24.845 |
| Combat + search | 448 / 0 | 212.224 / 249.328 / 280.337 | 249.411 / 280.444 / 280.444 |

Loaded-search p50 12.975 ms / p95 16.096 ms (448 samples). Both phases accepted
six attacks and observed actual impacts. The unbounded aggregate burst caused
28 traversals versus 360 without search. These are local Windows/headless
measurements, not production capacity targets or hardcoded timing test assertions.

Repeat: `tests/run-market.ps1 -Scene market_search -Marker MARKET_SEARCH_OK`,
`tests/run-combat.ps1 -Scene market_load -MarkerPrefix MARKET_LOAD`, and
`tests/run-market-recovery.ps1`. Network-derived runners sharing port 18098 run
sequentially. Fixed logs live under ignored `.godot/verification`.

## R1 — bounded rejected responses

Only successful economic commands append market_commands, atomically with their
mutation. Validation rejection rolls back all provisional writes before replying;
SQL faults also roll back and remain immediately retryable. Existing historic
receipts (including older negative rows) are not purged. No schema migration.

WorldDatabase shares one negative-response cache across Shop/Exchange facades:
64 accounts x 64 commands, maximum 4096 entries, 60-second TTL, FIFO eviction at
both bounds. A retained command returns its same error and rejects changed
fingerprints with command_conflict. After expiry/eviction/restart an unsuccessful
command may be revalidated: it never committed value. Receipt lookup can report a
retained rejection but it is not a durable acknowledgement. All successful receipt
lookups happen in SQLite first; cache eviction cannot permit executing them again.

1024 rejected requests now add **zero durable rows**, taking 86.844 ms locally.
Custody, purchase, ledger/orders and WAL recovery passed. Added coverage protects
negative-cache bounds/expiry/shared facades and durable success/conflict after
cache recreation; previous suites covered successful replay but not rejection spam.

## R2 — one World search budget, no queued SQL jobs

`WorldDatabase.market_query` validates search input before admitting at most one
expensive search every 200 ms (5/s maximum, burst one), and never two in the same
physics frame. All Market endpoints/instances already share that database owner;
there is no per-instance reset or client/account bypass. Existing independent
8-query/s peer limits remain. Excess searches immediately return the existing
rate_limited error; no job, timer, persistence write or application queue is created.
Catalog/visit/Exchange snapshots retain their existing bounded client budget and
do not consume this full-catalog search admission. Economic commands are separate.
No wire fields/error vocabulary/trade rules/migrations change.

| R2 phase | Accepted/rejected searches | Physics work p50 / p95 / p99 ms | Tick interval p95 / p99 / max ms |
| --- | --- | --- | --- |
| Combat only | 0 / 0 | 0.581 / 0.874 / 1.056 | 20.715 / 20.895 / 22.458 |
| Combat + search | 23 / 697 | 0.579 / 12.839 / 14.606 | 20.718 / 22.714 / 24.436 |

Both phases had 360 traversals, six accepted attacks and actual damage. Loaded
search p50 12.333 ms / p95 14.070 ms, maximum 15.445 ms (23 samples). The 125-ms
stress bursts admit fewer than the theoretical 5/s due to the 200-ms cooldown;
rejected requests are not held for later execution. Standalone 10k SQL+presentation
search p50 11.552 ms / p95 13.255 ms (100 samples).

Decision: **defer SQL worker** for this narrow prototype budget. Full-physics
p99 was 14.606 ms, maximum 16.255 ms, while tick-interval p99 stayed 22.714 ms
(compared with 20.895 ms idle combat on this Windows scheduler). Single reads
still run on the simulation thread; this gate bounds aggregate work, not an
individual SQL deadline. A requirement above 5 searches/s per World, sustained
single-query hitches, larger content or slower production disks should trigger
another capacity/latency measurement and then a worker decision. Admission is
first-arrival, not fair scheduling between clients, and no production throughput
or hardware guarantee follows from this local sample.

Coverage: the search suite verifies another authenticated account is denied by
the same World budget, cheap reads remain usable, and admission returns after the
cooldown. The live fixture separately verifies each real client's 8/s limit and
continues accepted combat/replication while aggregate search is shed. The existing
two-buyer fixture now retries a rate-limited **read** at most three times, because
simultaneous searches are intentionally not all admitted; purchase/replay tests
retain their original economic contracts. A fixture barrier lets both clients finish
browsing before the simultaneous purchase race. No automatic retry loop was added to UI.

## First-batch review boundary

R0/R1/R2 are separate commits on `codex/shop-r0-r2`, based on shop. They remain
unmerged/unpublished until review. R3–R4 architecture and R6 UX/native acceptance
are not implemented here. Successful receipts are intentionally retained forever;
legitimate successful activity still grows the economic audit/idempotency table.
Prior legacy negative rows are retained, not migrated/pruned. Gateway session
expiry needs a separate plan before public trading.

First-batch verification passed: custody (including provisional-write rejection),
purchase, search, Exchange ledger/orders, WAL process-crash/backup/restore;
market_network, market_race, exchange_network, Yang and Web Inventory two-client
flows; architecture boundaries; default 10 Godot smoke cases and 78 Web contracts.
Native CEF was not rerun for this server-only batch; the planned R6 acceptance
retains that milestone. Temporary databases/logs are disposable; documented
measurements are the retained baseline.
