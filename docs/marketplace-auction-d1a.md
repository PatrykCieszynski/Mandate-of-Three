# Auction D1a — UID-first index migration

Accepted SOCI choice: Godot 4.7.2 + godot-soci v0.4.1 + SQLite WAL. This topic
starts from `codex/soci-prototype` at e7ddaab (completed P0). Scope is the index
and its startup migration only. Stop for review before D1b.

## Production change

`MarketSearchSqlite.ensure_lookup_schema()` migrates v22 to v23 in one
`BEGIN IMMEDIATE` transaction: create `affix_item_lookup` on
`item_affix_index(uid, stat_id, value)`, write schema version, COMMIT. SQL failure,
including failure after CREATE INDEX, rolls both changes back. Repeated startup
at v23 succeeds without rebuilding the index. Existing v19–v22 migrations stay
in their original locations.

`WorldDatabase.prepare_account_wallets()` runs this after Exchange v22 and before
setting `wallet_ready`. A failure returns `market_lookup_migration` and leaves
that readiness flag false. Existing World character/session admission checks
require this flag. A future D1b reader must also start only after this sequence.
There is no production SOCI reader yet, no RPC change and no change to search
SQL, keyset ordering, cursors, item projection or economic writes.

## Verification and measured profile (2026-10-14)

Extended the existing `market_search` suite for the uncovered v22->23 risks:
fault injection after index creation, startup readiness refusal, version/data
rollback, repeat/reopen, exact item/result/cursor equality across ascending and
descending filtered pages, projection updates and item deletion cascade.
Baseline reads run before migration on the same disposable 10k-offer database.
No live runtime database or player account is used.

The existing P0 runner now accepts `migrated` and `migrated_analyzed` controls.
Each copy goes through the real v22->23 migration before either reader opens.
Both test all nine existing cases (default, broad, medium, selective, rare,
empty, descending, pagination, tied-price pagination), with exact production
result/cursor parity. Each has 30 warmed samples per case/adapter plus a fresh
connection sample and two warmups. All recorded samples and warmups pass the
unchanged 2-second budget. Native Release DLL loading and pinned hashes are
checked by the runner; the engine is the pinned Debug/editor executable so
assertions remain active.

| SOCI query | Index only p50 / p95 ms | Index + ANALYZE p50 / p95 ms |
| --- | ---: | ---: |
| Default | 12.790 / 19.214 | 5.633 / 5.994 |
| Broad affix | 26.353 / 39.898 | 5.522 / 6.452 |
| Medium affix | 26.369 / 32.982 | 5.719 / 6.707 |
| Selective two affixes | 5.857 / 6.631 | 6.015 / 31.668 |
| Rare | 6.743 / 6.790 | 6.707 / 6.821 |
| Empty | 6.863 / 6.925 | 13.730 / 20.597 |
| Descending | 19.060 / 19.683 | 5.377 / 5.997 |
| Pagination | 19.178 / 19.482 | 5.598 / 6.116 |
| Tied-price pagination | 6.800 / 13.659 | 6.774 / 6.842 |

SOCI times measure query submission to completed result, including queue/poll/
delivery, excluding main-thread projection. They are not native SQL measurements.
Use `await request.completed`, retaining the `is_done()` guard. The installed
godot-sqlite writer's highest warmed query p95 is 29.414 ms for index-only and
20.568 ms after ANALYZE. EXPLAIN confirms the covering UID/stat/value index is
used for the correlated affix lookup. These diagnostic profiles use the P0
frame configuration; server tick/load acceptance belongs to D2.

**Decision: ship the index without automatic ANALYZE.** Statistics improve broad
reads in this cohort, but empty/selective tail latency worsens. The index alone
already keeps every measured p95 below 40 ms, well inside the local 200-ms
target. No additional statistics maintenance/startup policy is needed for D1a.
Revisit with representative regional/server load at D2 rather than extrapolate
one fixture's statistics to all production distributions.

## Mutation cost

Thirty samples per operation before and after the index. Each measured operation
includes an immediate atomic COMMIT; update triggers rebuild affix rows, item
creation uses the existing ItemStore transaction and destruction verifies the
foreign-key cascade. Control updates restore original rolls before query parity
checks. Actual UID/placement/index contents are checked after each operation.

| Operation | Before p50 / p95 ms | After p50 / p95 ms |
| --- | ---: | ---: |
| Affix update | 2.124 / 3.394 | 2.404 / 4.617 |
| Item creation | 2.766 / 3.144 | 3.205 / 5.665 |
| Item destruction | 2.492 / 3.229 | 2.696 / 5.019 |

This is a local sequential observation with fsync/OS variance, not a causal
tail-latency guarantee or a load test. Writes remain immediate and transactional.

## Repeat and evidence

```powershell
& .\tests\run-market.ps1 -Scene market_search -Marker MARKET_SEARCH_OK
python tests/prepare-auction-soci-041.py --install
& .\tests\run-auction-p0.ps1 -Seed
& .\tests\run-auction-p0.ps1 -State migrated
& .\tests\run-auction-p0.ps1 -State migrated_analyzed
git diff --check
& .\tests\run-smoke.ps1
& .\tests\run-market.ps1 -Scene market_custody -Marker MARKET_CUSTODY_OK
& .\tests\run-market.ps1 -Scene market_purchase -Marker MARKET_PURCHASE_OK
& .\tests\run-market.ps1 -Scene exchange_ledger -Marker EXCHANGE_LEDGER_OK
& .\tests\run-market.ps1 -Scene exchange_orders -Marker EXCHANGE_ORDERS_OK
```

[Durable results](evidence/auction-d1a/results.json) include all distributions,
query plans, release hashes/compile options, raw-report hashes and mutation cost.
Historical S0 FAIL and v0.4.0/v0.4.1 P0 cohorts remain in their existing reports.
Validation passed: market_search migration/parity, both nine-case migrated
benchmark cohorts, ten Godot smoke cases, 78 Web contracts, architecture guards,
market custody/purchase, Exchange ledger/orders and D0 readonly concurrency/
backup/restart on v23. git diff --check passed. Historical D0/S0 test readers now
check the current lookup schema constant rather than an obsolete v22 literal.
Database files, binaries, backups and temporary logs remain ignored. Linux,
native CEF, real server load and production asynchronous RPC acceptance are not
claimed by D1a.

## Remaining roadmap

Every stage has its own branch, checks and review; advance only after acceptance.

- D1b: server-only pinned v0.4.1, one native readonly dispatcher, bounded/fair
  AuctionQueryService, authenticated asynchronous RPC, session/lifecycle safety.
- D2: real server configuration, 16 simulated query producers with combat/AI and
  economic writes, overload/reconnect/restart/backup, Windows and Linux runtime.
- R6: real CEF flow, claims, two real clients, final economic regression and
  review of `shop` before merging into `main`.
- Persistence V2/PostgreSQL: a separate project after R6. godot-sqlite stays the
  authoritative economy writer throughout these auction stages.
