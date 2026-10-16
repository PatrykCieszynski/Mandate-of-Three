# Account projection reads under marketplace load

This pass measures the current single-World SQLite implementation. It preserves
command admission, custody, receipts, immediate critical writes, synchronous
wallet/equipment reconciliation and current response ordering. It introduces no
worker, deferred command queue, cache or wire fields.

## Finding and fix

The existing 10,000-offer load fixture showed private Shop snapshot construction
costing more than the native economic COMMIT. `MarketStoreSqlite.mine()` reads
offers by `shop_id` and claims by account owner. Their query plans scanned all
offers or the global custody UID index, even for an empty private shop. Limiting
claims to 200 rows did not bound the scan needed to find those rows.

Startup now installs two non-unique read indexes in one transaction:

- `shop_offers(shop_id, position)` for one shop's ordered offers;
- `item_custody(owner_id, uid) WHERE location='account_claim'` for ordered claims
  belonging to one account.

These reads select their shop/account instead of walking the realm-wide
catalogue. This does not change the existing 200-claim display limit or implement
pagination. Existing rows, constraints, receipts, revisions and the numbered
migration sequence remain unchanged. Installation is idempotent and a failed
second index rolls back the first; a later startup can retry. It runs before
World admits players/starts the auction reader, including on current databases.

Rollback: revert the index-install call and diagnostic hooks. The extra indexes
can safely remain in existing databases; removal is optional maintenance on a
stopped database, never a rollback of committed economic state.

## Measurement

Run the existing fixture sequentially, with no other test suite generating
competing load or using its port:

```powershell
python tests/run-auction-load.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe --without-projection-indexes
python tests/run-auction-load.py --godot .godot/Godot_v4.7.2-stable_win64_console.exe
```

The baseline flag removes only the new indexes from the fixture's disposable DB,
after migrations and before reader startup. It is not a production setting. Copy
`.godot/verification/auction-d2/results.json` between runs to retain both outputs.
Output records host, engine, 60 Hz/60 FPS, mob count, 10k offers, two physical RPC
clients and sixteen simulated search sources. Each phase offers six seconds of
work; draining can extend the measured interval. This is a small combat/network
fixture, not a dense 100-player acceptance test.

Opt-in callbacks retain no production history and expose no metrics over RPC:

- `store`: domain SQL, validation and receipt/COMMIT, including failures/replay;
  `commit` separately times the native COMMIT call for new commits;
- `reconcile`: wallet RAM reconciliation and local result capture;
- `account_fanout`: synchronous account listeners, containing snapshot and
  publication costs; do not add it to nested metrics as separate work;
- `market_snapshot` / `exchange_snapshot`: private projection construction;
- `inventory_snapshot`: item read, presentation and derived stat construction;
  `combat_cache` measures runtime view acceptance, not all stat work;
- `storage_snapshot`, `upgrade_projection`, private RPC enqueue and public weapon
  fanout cover their named boundaries.

RPC enqueue is local serialization/queueing wall time, not network delivery or
browser render latency. COMMIT is not the whole transaction. The Shop snapshot's
lazy-shop creation transaction belongs to `market_snapshot`, not the command
COMMIT sample. SOCI worker round-trip remains distinct from native search SQL
time, which the pinned addon does not expose.

See [recorded Windows comparison](../evidence/economy-projection-budget/windows.json)
for phase percentiles, sample counts, summed stage costs and query plans. Timings
are observations rather than CI thresholds or a cross-platform SLA.

Windows observation on 2026-10-16 (four mobs, two clients):

| Phase | Tick interval p99 before | After | Maximum before / after |
| --- | ---: | ---: | ---: |
| Combat only | 16.818 ms | 16.732 ms | 16.990 / 16.938 ms |
| Combat + search | 16.767 ms | 16.720 ms | 16.795 / 16.818 ms |
| Combat + search + staged writes | 24.238 ms | 19.918 ms | 26.795 / 20.446 ms |
| Combat + search + write burst | 28.734 ms | 16.815 ms | 45.538 / 18.555 ms |

Shop snapshot p50 fell from 3.549 to 0.618 ms in staged writes (35 samples)
and 2.994 to 0.578 ms in bursts (30 samples). Plans changed from `SCAN o` /
global custody UID scan to shop/account index searches; the offer sort no longer
needs a temporary B-tree. Both cohorts ran sequentially with the same local
editor/content overrides held constant and excluded from publication. One short
cohort per variant does not establish a stable speedup or eliminate remaining
main-thread tail risk, but the indexed plans remove the demonstrated global scan.

## Safety coverage and scope

Existing `market_custody` covers a populated pre-index database, injected install
failure, rollback, retry, idempotence and reopen while preserving snapshots and
the migration version. Standard smoke, marketplace purchase/search, two-client
Marketplace/Web Inventory and SQLite/WAL crash/backup recovery remain the
behavioral checks. The A/B fixture retains receipt replay, failed-buy rollback,
single UID custody, Yang/material conservation, backup, reader restart, queue
saturation and peer reconnect checks. No exact-ms or plan-string assertion is
added.

Combat cache adoption stays synchronous before dependent gameplay; command and
replay publication order stays unchanged. Coalescing, a writer worker,
distributed invalidation and a new persistence model are not justified by a
missing-index problem. Larger fanout/dense-combat tests may justify a scheduling
change later. This pass does not complete future tick-budget or distributed C4
gates. Native CEF, Linux runtime, full Gateway/Master login and release export
are not verified by this headless fixture.
