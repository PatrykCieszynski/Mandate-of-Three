# PostgreSQL P1l — Exchange order evidence

Windows, PostgreSQL 18.6, Godot 4.7.2, pinned godot-soci v0.4.2
(`222cfec77acbdb15fa7cd6f6c97d7064126a947a`). Fresh owned SCRAM loopback
clusters and disposable SQLite only. Raw diagnostics remain ignored under
`.godot/verification/postgres-readiness/`.

Final fixture `run-_v87bgs0`: `POSTGRES_EXCHANGE_ORDERS_OK` and
`POSTGRES_EXCHANGE_ORDERS_NATIVE_OK` PASS; owned cluster stopped.

Verified contracts:

- SQLite/PG account ledger, reservations, order/fill/depth and receipt-count
  parity; exact price ordering/FIFO, maker price, partial fills, rational lots,
  self-account exclusion and offline maker pending-income settlement.
- Total Yang/material conservation; reservation refund, stale/foreign/closed
  cancellation, original result replay, conflicting payload and reopen discovery.
- Statement faults at wallet, asset UPDATE/INSERT, order INSERT/UPDATE, fill and
  receipt restore all captured views. Cancellation faults restore reservations.
- Native observed lock barriers with independent sessions: two takers consume one
  maker once, cancel/fill serialize, one commit for duplicate operation, and two
  different pairs sharing reversed counterparties both settle without deadlock.
- Deferred COMMIT failure for matching and cancellation closes native connection,
  reports unknown and leaves no committed state/receipt. Reopen, discovery and
  original-ID retry recover; replay never reapplies supplied pending income.
- Wallet/material receiving overflow rolls back the full match. Twenty active
  orders/account blocks the next new order but permits the original receipt replay.
  Native account IDs above 2^53 survive result/discovery/replay exactly.
- Populated ledger survives additive order-schema failure/retry; repeated/future
  schema guards and refusal to consume a caller's transaction pass.

Regression commands also passed:

- Native `exchange-ledger` (`run-qwer16fq`), `shop-settlement` (`run-scdl6ps8`)
  and `storage` (`run-6q54fxxh`) using the shared command admission component.
- Default smoke, existing SQLite `exchange_orders`, and real two-client
  `exchange_network` (server/client1/client2). These network clients use SQLite.

Pair admission is bounded in code at 2048 active orders; no 2048-order contention
benchmark or mixed-load capacity claim is made. No PostgreSQL World integration,
automatic retries, Linux, physical CEF, deployment or cutover verification.
