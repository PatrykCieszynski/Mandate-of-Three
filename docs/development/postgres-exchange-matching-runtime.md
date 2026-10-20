# PostgreSQL Exchange matching runtime — P3p

P3p optionally connects order placement, cancellation and matching to the existing
World executor, RPCs and production Exchange adapter. Enable the Marketplace
coordinator's fifth constructor argument, `exchange_matching`, together with the
fourth ledger capability and a wallet owner. Normal startup remains SQLite.
There is no schema or RPC signature change, new worker model or frontend framework.

## Transaction and participant ownership

The worker first discovers the issuer and opposite active-order accounts under
current delegated-session authorization. This is a bounded read, not a transaction
or pair lock retained across the World round trip. World then captures pending
Yang and fences each participant's wallet. The existing order transaction reselects
participants under its pair lock and deterministic account locks. A changed set
returns `participants_changed` without a mutation/receipt; only explicit retry may
execute again. The runtime admits at most 64 participant accounts. It currently
captures all opposite active accounts, including non-crossing orders, so this is
a conservative availability limit rather than an optimized matching frontier.

Online captures require a current ready wallet; dirty/in-flight detached wallets
return transient `participant_busy` until their checkpoint settles. Absent or
clean offline wallets can participate with zero captured income. An account fence
also applies if a wallet attaches while native SQL is pending: it cannot expose
a balance, accept grinding income or spend until settlement resolves. No gameplay
tick performs SQL. Other accounts and physics continue while a participant is locked.

The existing transaction retains price-time priority, partial fills, reserve/refund,
session validation, caps and whole-transaction retries for known rollback errors.
Touched Yang accounts record their individual capture tokens in the durable receipt.
Only matching tokens consume a RAM prefix; replaying an old receipt cannot consume
new income. Non-touched captures retain their pending income. The account wallet
is refreshed after release, including a wallet created during settlement.

## Publication and recovery

An Exchange fill changes ledger state without changing an item revision. World-local
per-account view generations therefore invalidate online participant projections.
Snapshots scheduled before a fill are reread with bounded repairs. Caller terminal
feedback waits for participant wallets and online private projections to reconcile.
Generation bookkeeping is retired when an account has no live binding or lane.
This is single-World coordination, not distributed invalidation or multi-World safety.

The native client journal now includes order and cancel. It retains original ID/body
across timeout, UI reload and client relog. Read-only receipt discovery works after
the order is filled/cancelled; it does not depend on an order row remaining visible.
Unknown execution never automatically resubmits a mutation. Captured monetary
uncertainty blocks worker shutdown until receipt discovery resolves it; existing
operator drain diagnostics and explicit lookup remain available after bounded retries.
Receipt replay refreshes views without publishing a new committed item fact.

## Verification and remaining boundaries

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite matching-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite exchange-orders
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite wallet-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite settlement-runtime
& ./tests/run-web-inventory.ps1 -Scene market_network
```

Native fixtures use owned disposable clusters. Run shared-port 18098/18099 suites
sequentially. The endpoint fixture now has ten actual headless clients, controlled
Gateway/map setup and production RPC/bridge/native journals. See
[evidence](../evidence/postgres-p3p/README.md).

Next: PostgreSQL public Auction catalog/search, then operational backend bootstrap,
handoff and full end-to-end gameplay acceptance. P4 mixed load/soak/import/restore
and explicit cutover approval remain required. This does not complete R6 claims
pagination, distributed publication or whole-World crash/failover. Physical CEF
input/rendering and Linux are NOT VERIFIED by these headless Windows fixtures.
