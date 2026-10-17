# PostgreSQL P1i — account claims and Shop projections

This opt-in slice ports the existing account claim → receiving character Inventory
guarantee, plus complete private Shop and public visitor projections. Production
World/client still uses SQLite. Exchange ledger/order matching and Auction search
remain separate ports; this slice does not create a new claim producer or protocol.

## Claim custody and transaction contract

`account_claim_schema_postgres.gd` adds feature `account_claims` version 1 after
the populated seller/settlement schema. Custody adds `claim_account_id`; the
`account_claim` location requires that account, position -1, empty equipment slot
and no Storage/escrow/Shop/offer fields. Every other location requires a NULL claim
account. The original character remains `owner_id` provenance, matching
`item_instances.owner_character_id`. A deferred composite FK proves that character
belongs to the claim account. Existing mutual item/custody FKs continue guaranteeing
one custody row per UID; no second item or generic vault is introduced.

The existing character-to-account item revision trigger remains correct because
claim provenance is constrained to the same account. An alt claim changes item
provenance and custody together and bumps the account watermark using the same
observable row-mutation semantics as SQLite. Partial indexes support ordered
account claims and Shop offer projections. Schema bootstrap is additive, repeatable,
preserves populated Inventory/Storage/escrow/receipts, and refuses future versions.

`account_claim_postgres.gd` owns `claim_item(character, command, uid, revision,
requested_position=-1)`. It composes the existing command owner and Inventory
receiving logic, taking account admission before character, receipt and capacity.
The fingerprint is unchanged: `claim` and
`[character, uid, expected_revision, requested_position]`.

The store authorizes the claim account, checks revision/definition, resolves the
complete 1/2/3-cell receiving footprint and atomically updates item owner/revision,
custody location/provenance and receipt. It neither charges Yang nor consumes the
claim when Inventory is full. Exact placement and first-fit retain existing bounds,
page-edge and overlap behavior; there is no rotation or Storage fallback.

Two alts compete through the same account lock. One UID can be received once; the
same issuer/ID/payload returns its original receipt without another transfer.
Another issuer or altered payload with that ID conflicts. Read-only discovery is
account-scoped, matching existing Shop discovery, and returns the original receiver.
Receipt lookup precedes mutable claim/revision/capacity checks, so sold/received
state does not block recovery. A future Exchange claim producer must take the same
account admission and commit its item, provenance and claim custody atomically.

Statement failures roll back all writes without caching a transient failure.
Business rejections use the existing bounded RAM cache; successes have durable
receipts. Failed native COMMIT closes the session and returns `outcome_unknown`.
Reopen/discovery precedes an explicit same-ID retry; there is no automatic retry
with a new identity. Existing decimal-string watermark encoding is reused.

## Private and public projections

`shop_queries_postgres.gd` owns Shop presentation reads and shared item formatting:

- `mine(character)` resolves the trusted account, lazily creates its Shop under
  account admission, and returns metadata, ordered offers, real claimable Yang and
  ordered account claims. Alts see the same account projection. Item snapshots
  preserve UID, source character, revision, stack, upgrade, affixes and sockets.
- `visit(shop)` returns Shop metadata and ordered offers, with the existing empty
  public `claims` array. It never queries or exposes private claims/revenue, account
  identity, wallet, credentials or session state. Metadata and offers use one short
  `REPEATABLE READ READ ONLY` transaction; no transaction remains open for UI use.
- `seller_mine(character)` retains the prior seller-only projection on its original
  schema. `shop_seller_postgres.gd.mine()` is a compatibility delegation. The new
  complete projection does not silently change those prior parity fixtures.

Missing Shop, unknown character/definition, query failure and nested transaction
behavior remain explicit errors. A caller's open transaction is never committed
or rolled back by refused admission. Unknown content fails the projection instead
of publishing a partially formatted view.

The existing 200-claim UID-ordered projection window is deliberately preserved.
Receiving an entry exposes a later pending entry on refresh; claims are not deleted
by opening the view. Pagination/UX and a broader projection budget are separate
follow-ups, not an unannounced network or client change in this port.

## Verification and limits

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite account-claims
```

The disposable native fixture compares complete private/public projections,
Inventory ownership/metadata/revisions, Storage and receipt totals against SQLite.
It covers unauthorized/stale/wrong-custody requests, full bag, exact/first-fit
1/2/3-cell receiving, bounds/overlap, rollback at item/custody/receipt, response loss,
reopen/discovery, fingerprint conflict, public privacy, paused/offer-only display,
unknown definitions and existing Storage transfers on the extended schema.

Independent sessions overlap at an observed native lock barrier for double claim,
same-ID replay and intersecting receiving footprints. Deferred COMMIT failure proves
unknown/close, unchanged committed item/custody/receipt/watermark state, discovery
and explicit retry. Native constraints reject foreign provenance, bag/claim mixing
and orphan custody. BIGINT item revisions and receipt watermarks beyond 2^53 remain
exact. A native visitor probe commits independent metadata/price writes between
the real SELECTs and checks the returned view stays on its original snapshot.

See [P1i evidence](../evidence/postgres-p1i/README.md). These targeted cases do not
complete broad P2, P3 executor/fencing or P4 cutover. PostgreSQL-backed clients,
physical CEF, Linux, load/soak, Exchange creation/matching and Auction SQL/search
are not verified here. No real player stores or installed PostgreSQL service data
are used by the fixture.
