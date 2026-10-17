# PostgreSQL P1i — account claims / Shop read evidence

Windows, PostgreSQL 18.6, Godot 4.7.2 and pinned godot-soci v0.4.2
(`222cfec77acbdb15fa7cd6f6c97d7064126a947a`). Fresh owned SCRAM loopback
clusters and disposable SQLite only; no installed service or player data changed.

`POSTGRES_ACCOUNT_CLAIMS_OK` and `POSTGRES_ACCOUNT_CLAIMS_NATIVE_OK` PASS:

- Complete private and public Shop views match SQLite, including item metadata,
  real revenue, alts/account isolation, claims, paused Shop and no-price offers.
- Claim into the selected character preserves UID/affixes/sockets and increments
  item/account revisions. Wrong account/custody/revision, bounds/page edges and
  occupied/full receiving Inventory reject without consuming or relocating a claim.
- 1/2/3-cell exact and first-fit receiving, no Storage fallback, existing Storage
  transfer behavior on the populated extended schema.
- Item/custody/receipt statement faults restore all projections, Inventory,
  Storage, revisions and receipts. Original-ID retry succeeds when the fault clears.
- Same-ID replay/discovery/reopen keeps the original receiver, changed issuer or
  placement conflicts, another account cannot discover the receipt.
- Independent native sessions observed at a SQL lock barrier: one UID/one receiver,
  one commit plus identical duplicate-intent replay, no intersecting footprint grant.
- Deferred COMMIT error closes the session and reports unknown; reopen proves
  unchanged item/custody/receipt/watermark state, discovery finds no success and
  explicit original-ID retry succeeds.
- Direct malformed SQL cannot cross claim/provenance accounts, leave claim fields
  on bag custody or orphan an item from its custody. Nested calls preserve caller
  transactions. Populated/repeat schema extension and future-version refusal pass.
- More than 200 pending entries retain the existing UID-ordered window; receiving
  an entry makes a subsequent entry visible on refresh. No pagination protocol added.
- BIGINT item revision and receipt watermarks beyond 2^53 survive reopen/replay.
- Public visitor metadata and price stay coherent when an independent native
  writer commits name/status and price changes between its real SELECTs. A later
  visit sees the committed changes. Public views do not expose private revenue or
  claims and do not leave an open transaction; unknown content fails cleanly.

Affected regressions:

- PostgreSQL seller lifecycle PASS (`run-_vj_2st2`), using its original seller schema.
- PostgreSQL settlement PASS (`run-snqay8s6`).
- Default smoke PASS: 14 Godot cases, architecture checks, 85 Web/bridge tests.
- SQLite `market_custody` PASS.
- Existing SQLite two-client `market_network`: server/client1/client2 PASS.
- Python AST, whitespace and preservation of 45 unrelated local files verified.

The final claims fixture PASS is `run-loat3mh1`. Raw logs are ignored under
`.godot/verification/postgres-readiness/`. Intentional SQLite fault errors and generic
resource teardown warnings are diagnostic output; runner PASS requires markers
and no script/parse/assertion failures.

Not verified/completed: Linux, physical CEF or PostgreSQL-backed clients, claim
producer/Exchange ledger and matching, Auction search, broad P2, executor/fencing,
load/soak and cutover. This branch never enables PostgreSQL in World.
