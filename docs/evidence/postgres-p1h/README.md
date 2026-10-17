# PostgreSQL P1h — Shop settlement evidence

Verified on Windows, PostgreSQL 18.6, Godot 4.7.2 and pinned godot-soci v0.4.2
(`222cfec77acbdb15fa7cd6f6c97d7064126a947a`). Only freshly initialized owned
SCRAM loopback clusters and disposable SQLite fixtures were used. The installed
PostgreSQL service/data and personal player stores were not touched.

The final settlement run `run-7pq7czt8` emitted both
`POSTGRES_SHOP_SETTLEMENT_NATIVE_OK` and `POSTGRES_SHOP_SETTLEMENT_OK`; runner
reported PASS and stopped its owned cluster. Ignored raw diagnostics are under
`.godot/verification/postgres-readiness/` and are not committed.

Verified contracts:

- SQLite/PG matching Inventory UID/owner/revision, account item watermarks,
  wallet balance/reservations/revision, revenue, occupied-cell and receipt totals.
- Self-trade, paused Shop, negotiable offer, stale price/revision, reserved funds,
  insufficient funds and completely full Inventory rejection.
- Purchase applies buyer pending income once, debits available funds, credits
  claimable proceeds without loading/crediting the offline seller wallet, and
  preserves exactly one UID with receiving-character provenance.
- Faults at wallet, revenue, cells, item, custody, offer and success receipt roll
  back every provisional mutation; same-ID retry succeeds after a SQL fault clears.
- Receipt replay after sold-offer deletion and connection reopen, altered-payload
  conflict, original wallet watermark and pending application.
- Partial collect includes pending income in headroom, leaves remainder, preserves
  reservations, and rejects full wallet/empty revenue. Wallet/revenue/receipt faults
  leave final state unchanged. BIGINT revenue overflow reverses provisional spend.
- Observed overlapping independent SOCI sessions: one winner for double-buy,
  buy/cancel and buy/edit; both different sales add to the same proceeds; duplicate
  purchase/collect give one commit plus identical replay; reciprocal buys complete;
  two alts buying different offers cannot overspend their shared account wallet.
- Deferred COMMIT faults for buy and collect close the session and report unknown.
  Reconnect proves unchanged custody/items/offers/cells/revisions/receipts and
  funds, discovery finds no receipt, explicit original-ID retry then succeeds.
- BIGINT proceeds beyond 2^53 and seller/Shop IDs beyond 2^53 survive receipt
  discovery/replay/reopen. Populated seller extension, repeat bootstrap and future
  feature-version refusal are verified.

Affected PostgreSQL regressions PASS:

- Seller lifecycle: `run-oyis2u_z`.
- Account Storage: `run-ld9n0o9x`.
- NPC purchase: `run-xbanhvdt`.

Default smoke PASS: 14 Godot cases, architecture checks, 85 Web tests and bridge
contracts. SQLite `market_purchase` PASS; existing two-client `market_network`
PASS for server, client1 and client2. These runtime clients still use SQLite.

Expected injected SQLite SQL errors and existing generic resource teardown
warnings appear in diagnostic logs; the runner rejects any script/assertion/parse
failure, and none are present in the final passing fixture.

Not verified here: PostgreSQL client/runtime/CEF, Linux, load/soak, query latency,
Exchange, legacy account claims, full Marketplace reads, P3 executor/fencing or
cutover. This is a targeted domain port with conflict checks, not the broad P2 gate.
