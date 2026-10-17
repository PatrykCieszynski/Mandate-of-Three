# PostgreSQL P1k — Exchange ledger conversion parity

This opt-in slice completes the existing stack ↔ fungible account balance flow:
deposit from the issuing character's Inventory or shared account Storage, then
withdraw into the issuing character's Inventory or explicit account claims.
Original operation identity, atomic custody/balance mutation and receipt recovery
remain part of that guarantee. Production World/client stays on SQLite.

## Schema and application contract

`exchange_ledger_schema_postgres.gd` adds feature `exchange_ledger` version 1 after
the populated Auction/claims schema. `exchange_assets` has an account FK, composite
account/asset primary key, BIGINT free/reserved values and the existing 9e15 total
cap. Bounds use `free <= MAX - reserved` rather than potentially overflowing an
addition. DDL and version marking are atomic, repeatable and future-version guarded.

`exchange_ledger_postgres.gd` composes the existing native command owner, Item,
Storage and Claims stores. Every mutation admits the trusted account before its
issuing character, receipt lookup, source read and receiving capacity. No user
payload chooses the account. Existing fingerprints remain:

- `exchange.deposit`: `[character, uid, revision, amount, source]`.
- `exchange.withdraw`: `[character, asset, amount, destination]`.

Deposit accepts only the canonical `MarketRequestRules.asset_definition` policy:
tradeable fungible stack definitions, no upgrades, affixes or sockets, legal stack
amount and expected revision. A bag belongs to the issuing character; Storage
belongs to the account even when another alt remains the source provenance.
The balance increment is additive and guarded by free plus reserved headroom.
Whole deposit destroys the old item/custody; partial deposit retains UID and
provenance and increments revision. Conversion failure rolls back the balance.

Withdrawal debits only free units with a conditional UPDATE, never reservations.
It creates one fresh plain stack UID through Item receiving or the explicit Claims
producer and commits it with the receipt. Inventory capacity uses the existing
full-footprint first-fit contract. A full bag rolls back the debit; it does not
silently become a claim. The explicit claim destination does not need bag space.
No output is placed in Storage by this operation.

## Storage and claim boundaries

`account_storage_postgres.gd.item_in_transaction` owns the shared-account source
lookup and reuses account admission. `consume_in_transaction` repeats that ownership
and revision check before decrement/removal. Exchange contains no Storage mutation
SQL. These trusted helpers require an existing transaction and account-first
command admission; caller owns rollback, receipt and COMMIT. Consumption allocates
no cells. All deposit/move/withdraw transfers into or out of Storage retain the
existing full-footprint transfer implementation; the unique starting-cell index
is still not a general exclusion constraint.

`account_claim_postgres.gd.receive_in_transaction` is now the concrete claim
producer used by Exchange. It validates the prepared stack/UID, resolves and locks
the trusted account, and inserts item plus claim custody within the caller's
transaction. Existing same-account provenance, unique custody and claim-shape
constraints apply. It never commits independently or publishes a provisional grant.
The normal claim-to-Inventory path remains unchanged.

## Receipts, read model and failures

Receipt lookup precedes balance/capacity/source validation. Retry/reopen returns
the original created UID and item watermark, without spending or granting again.
Different issuer, source, amount or destination with the same ID conflicts;
account-scoped discovery returns the original result. Native receipts add exact
decimal encoding/decoding for the amount scalar, with legacy numeric decoding.
Current withdrawal/deposit amounts are stack-bounded; ledger totals are native
BIGINT. Transient SQL errors do not create durable or cached business rejections.

A failed native COMMIT closes the session and returns `outcome_unknown`. Reopen
and original-ID discovery precede explicit retry. No fresh-ID compensation, blind
retry, worker, dispatcher, new global queue or runtime synchronization is added.

`ledger(character)` is a short repeatable-read read-only projection of committed
account assets and wallet/reservations. It includes every canonical fungible asset,
including zero balances, preserving display order/name/stack limits. Alts share
the view; another account sees its own state. It does not merge World pending Yang
or hold a transaction for UI use. Nested calls refuse without ending caller work.

## Verification and remaining scope

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite exchange-ledger
```

The fixture compares SQLite/PG ledgers, Inventory/Storage/claims, original metadata,
revisions/watermarks, affix projections and receipt counts. Only newly generated
withdrawal IDs are normalized between independent backends. It covers full/partial
consumption, all canonical materials, unauthorized/stale/nonfungible sources,
reserved units, full bag, explicit claim receiving, cap overflow and statement/
COMMIT rollback/reopen. Native independent sessions cover shared Storage deposits,
competing withdrawals, duplicate withdrawal identity and deposit-versus-Storage
transfer of one UID. See [P1k evidence](../evidence/postgres-p1k/README.md).

Reserved values exist in the schema and remain unspendable; fixture seeding them
is not a reservation API. Order reservation/release, price-time matching, partial
fills/cancellation and cross-party settlement are a separate P1/P2 port. This does
not complete broad P2, P3 execution/fencing or P4 load/cutover. PostgreSQL clients/
CEF, Linux and mixed PostgreSQL load/soak are not verified. No real player data or
installed PostgreSQL service is used by the owned fixture.
