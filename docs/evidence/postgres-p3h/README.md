# PostgreSQL P3h — indexed pending recovery evidence

Verified 2026-10-18, branch `codex/postgres-pending-recovery`, based on integrated
`main` `28c04b2b` (PR #89 squash). Windows / Godot 4.7.2 / PostgreSQL 18.6 /
official pinned SOCI v0.4.3. Native runs use fresh owned SCRAM loopback clusters,
isolated profiles and runner-confirmed shutdown. No player data or installed
PostgreSQL service is used.

## Contracts

Existing `inventory-runtime` acceptance creates 33 validated terminal no-op
intents, then adds 10,000 matching historical intent/receipt copies in the owned
fixture. No item mutation is performed to manufacture that bulk history.

- A v1 layout with durable records is upgraded to intent feature v2. A conflicting
  relation makes partial-index creation fail; the transaction leaves version 1,
  original history and outcomes intact. Removing the fixture fault allows upgrade;
  repeated initialization succeeds and old receipt/outcome lookup is unchanged.
- Session-qualified pending pages exclude all terminal history. A pending no-op
  finishes between pages; later alt/main pending rows are still found once by
  sequence keyset. Another account receives no rows.
- Actual World recovery through the new native worker API finishes the alt's
  original command under its original character and the main character's equip.
  Items are not retargeted. Existing session/replay/unknown-COMMIT/cache repair
  and independent-account progress contracts remain exercised.
- Native EXPLAIN ANALYZE uses `inventory_intents_pending_account`, returning
  two pending rows despite 10,034 terminal history rows. The final recorded
  query reports **0.029 ms server execution**. This is one warm owned-fixture
  query plan, not coroutine/RPC/World latency, a throughput benchmark or an SLA.
- Session acceptance covers stale/forged contexts for the new pending query and
  exact native sequence cursors/request revisions above `2^53`. A completed row
  disappears from pending discovery but stays available as its original result.
- Existing historical discovery and real producer-process-loss tests remain
  unchanged; terminal records and economic receipts are never pruned here.

## Runs

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-intents
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-sessions
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
```

- Intents: `run-lsl23_e6` PASS, stopped.
- Sessions including int64 pending cursor: `run-5b0_lrhc` PASS, stopped.
- Runtime: `run-yc72ffn9` PASS, stopped (also `run-8rffyv5a` and `run-4yfto3tx`).
- Endpoint with actual client processes/native Master–World sockets:
  `run-pp450et8` PASS, stopped; all client markers present and no SCRIPT/parse
  errors. Existing lost reply, rejection, reload/process-relogin journal,
  cache invalidation/readiness and UID/fact/privacy assertions retained.

Default smoke PASS: architecture guards, 14 Godot checks and 85 Web contracts.
SOCI pin/hash and `git diff --check`: PASS. The expected
schema-conflict fault and COMMIT cleanup warnings are fixture diagnostics, not
successful gameplay writes. Small existing ObjectDB/resource teardown warnings
remain; successful native logs have no SCRIPT/parse or unjoined-worker errors.

## Limits and remaining migration

See [runtime adoption status](../../plans/postgresql-migration.md#runtime-adoption-status).
Normal startup still owns SQLite. This PR does not activate other economic
domains, wallet checkpoints, bootstrap/handoff/shutdown, distributed publishers,
load/soak or cutover. The native runtime's peer maps are seeded; the endpoint
fixture has real client processes and control sockets but controlled Gateway
entry/credentials and map construction. No full production PG bootstrap, native
CEF rendering, Linux or production migration acceptance is claimed.

Index installation is a transactional provisioning migration, not an online
concurrent-index rollout. Retained history/index storage and vacuum still need
P4 operational testing; the change removes terminal enumeration from recovery,
not all costs associated with retaining history. Raw logs remain ignored under
`.godot/verification/postgres-readiness/`.
