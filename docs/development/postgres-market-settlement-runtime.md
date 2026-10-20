# PostgreSQL Marketplace purchases and proceeds — P3n

P3n extends the existing optional P3m coordinator with `buy`, `claim_revenue`
and an authenticated public shop `visit`. Supply the existing wallet owner as
the coordinator's third constructor argument to enable monetary operations.
Normal production startup remains SQLite; there is no backend selector or schema
change. Exchange and PostgreSQL Auction catalog/search remain separate ports.

## Transaction and pending-income ownership

The native worker calls the existing `ShopSettlementPostgres` transaction owner.
Current delegated session checks now also cover purchase/proceeds kinds, including
receipt replay. Bare calls cannot bypass a registered account's session fence.
Existing sorted account locking, offer revision/price/status, self-trade denial,
full-footprint bag capacity, UID custody transfer, additive seller revenue and
receipts remain one transaction. No account Storage custody is written directly.

The coordinator reserves the current wallet's pending prefix using its existing
external-capture API, with matching Inventory/wallet delegated contexts. It holds
Inventory and spending readiness while SQL executes. A purchase applies that
prefix and the debit atomically with custody and seller proceeds. Collection
applies the prefix and the partial revenue credit atomically; only the amount
that fits below the wallet cap is collected, leaving the remainder claimable.

Success receipts carry the capture token. Only a receipt matching the live RAM
capture consumes its pending prefix. Replaying an older purchase or collection
with newer income does not discard that income. After every result, current
Inventory revision ACK, wallet refresh and private shop/claims reconciliation
precede terminal publication. SQL never runs on the simulation thread.

## Settlement visibility and recovery

The existing bounded seller worker lane handles the two monetary operations,
rather than introducing a global economy queue. One operation per account and
the existing 64-retained-account/native-capacity bounds remain. The seller's
online private view is scheduled for refresh after a successful purchase or
receipt discovery, across map-local adapters within this World. If that account
is already busy, refresh waits for its current lane. Offline revenue is durable
and loaded on the next open. There is no push to another World Process.

Only known new commits publish item facts, and only purchases among these two
operations change buyer Inventory. Collection, price/name edits and replay add
no item facts. Read-only discovery uses current account + original ID + allowed
kind, including after RAM lane retirement or alt takeover; it never moves the
original buyer's item to the replacement character.

Unknown COMMIT results retain wallet capture and trigger bounded read-only
receipt discovery, never automatic mutation execution. Missing receipts permit
an explicit same-ID/body retry after current authorization. During drain, an
unresolved monetary capture prevents stopping the worker owner or claiming safe
shutdown. Existing-lane read-only recovery remains available; new operations are
closed. After retry exhaustion the operator sees pending stage/attempt diagnostics
and may retry discovery once storage recovers. Wallet dirty-value barriers remain
independent. Pure seller/item delivery retains P3m's safe deferred-delivery policy.

## Client and public read behavior

Purchases join the native Marketplace intent journal introduced in P3m. The
original command survives UI reload and client-process restart after the offer
disappears. The browser's existing purchase Retry button uses native recovery for
PG intents, without requiring an old offer or browser body. SQLite retains its
existing browser-ID retry behavior. The separate proceeds journal is retained.

The public `visit` RPC runs on the same bounded native owner with current grant
validation and returns public offers plus empty claims, without private revenue.
It is independently rate limited; in-flight duplicate IDs are ignored before
limiting. Private reconciliation still uses the existing account item marker.
Other PostgreSQL query actions return explicit `unsupported`; this is not the
Auction search scheduling/performance milestone. CEF remains presentation only.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite settlement-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite shop-settlement
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite wallet-concurrency
& ./tests/run-web-inventory.ps1 -Scene market_network
```

Run native network suites on 18098/18099 sequentially. The dedicated fixture uses
real native workers, controlled World peer maps and disposable PostgreSQL. The
existing endpoint fixture now adds an eighth actual client, with production
RPC/bridge/journals but controlled Gateway/map setup. The Web contract covers
restored purchase Retry without an offer. See [evidence](../evidence/postgres-p3n/README.md).

No production bootstrap, full Gateway-to-PG gameplay, physical CEF, Linux,
whole-World crash/failover, distributed invalidation, complete R6 claims pagination
or P4 load/soak/import/restore/cutover acceptance is claimed.
