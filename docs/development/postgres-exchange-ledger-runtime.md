# PostgreSQL Exchange custody runtime — P3o

P3o optionally connects the existing `deposit` and `withdraw` transactions to
World RPCs and the production Exchange client. It completes the item/Storage to
fungible-ledger conversion flow, not order placement, cancellation or matching.
Normal startup remains SQLite. No schema, RPC signature or frontend framework
is introduced.

## Authority and projection boundary

Enable the existing Marketplace coordinator's fourth constructor argument,
`exchange_ledger`, before attaching Inventory peers. Its bounded native executor
and account lane now route two additional commands through the existing Exchange
ledger store. The coordinator enables combined Inventory/Storage snapshots;
omitting Storage after an Exchange mutation is not an acceptable cache result.
Registered accounts require the current delegated session fence, including replay.

Deposit consumes a validated stack from the character bag or account Storage
and credits fungible units atomically. Storage authorization/consumption remains
inside the existing Storage boundary under the account lock. Partial stacks keep
their UID and increment revision; whole stacks are consumed. Withdrawal debits
free ledger units and creates one fresh item in the original character's bag or
account claims. Existing capacity, full-footprint, fungibility, reserve, cap and
receipt guarantees remain in the stores. Neither operation changes Yang.

The private shop/claims and Exchange projection are read under one current-account
lock. The existing bounded order/depth/fill read model is composed into that
transaction; it does not fabricate empty orders or adopt matching writes. The
item marker must agree with acknowledged Inventory/Storage before snapshots and
terminal feedback publish. Known new conversions publish one item fact; receipt
replay publishes no new mutation. Current optional RAM wallet balance may decorate
the Yang display, without checkpointing income as a side effect of conversion.

One active operation per account, the existing 64-retained-account bound and
bounded native pool apply. No SQL runs on the simulation thread. Existing
current-session, stale-delivery, independent-account and graceful-drain behavior
is reused. Ordinary seller/settlement fixtures can omit Exchange capability and
do not require its schema or incur its projection reads.

## Intent, failure and recovery

The native Exchange adapter stores a stable ID and original action/body in a
character-scoped local journal before sending. Browser IDs are not durable
operation identity. Timeouts/transient responses retain that intent. Read-only
account + ID + allowed-kind receipt discovery runs after UI recreation/relogin.
It works after the source stack disappears or the withdrawal has already created
its item. Same-account alt discovery confirms the original result without moving
the original character's withdrawal to the replacement bag.

Unknown COMMIT never triggers automatic mutation execution. Reopening a saved but
never submitted intent only discovers; explicit Retry may execute the original
ID/body under current authorization. Known success or terminal rejection clears
the journal. A new command cannot replace an unresolved intent. The existing
SQLite client retry path is retained separately.

The existing Exchange window remains the UI. Optional `ledgerOnly` presentation
disables order controls and explains that trading is not enabled; server routing
independently rejects those mutations. Retry does not require a selected stack.
Default SQLite order behavior remains unchanged.

## Verification and next boundary

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite exchange-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite exchange-ledger
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite exchange-orders
& ./tests/run-web-inventory.ps1 -Scene market_network
```

Run 18098/18099 network suites sequentially. Native tests use owned disposable
clusters. The endpoint suite adds a ninth real headless client with production
RPC/bridge/journals, controlled Gateway/map setup and no physical CEF. See
[evidence](../evidence/postgres-p3o/README.md).

Next: order/cancel/matching runtime, captured pending Yang, reservation and
multi-party wallet/ledger reconciliation. Item-marker fencing alone cannot
invalidate a maker's ledger after a fill with no item mutation; that future port
must supply explicit participant freshness/publication. This slice does not claim
distributed invalidation, PostgreSQL Auction search, production provisioning or
bootstrap, complete R6 claims pagination, Linux, whole-World crash/failover,
physical CEF or P4 load/soak/import/restore/cutover acceptance.
