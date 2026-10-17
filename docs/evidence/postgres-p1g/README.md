# PostgreSQL P1g — Player Shop seller lifecycle evidence

2026-10-17, Windows, Godot 4.7.2, official pinned SOCI v0.4.2, PostgreSQL 18.6
from `Y:/Software/PostgreSQL/bin`. Only fresh owned SCRAM clusters and migrated
SQLite fixtures. Runtime remains SQLite; no installed service/player data used.

- Native `--suite shop-seller`: PASS. SQLite/PostgreSQL seller, Inventory/Storage,
  price/metadata/revision, complete occupancy and receipt-count snapshots match.
  Generated Shop/offer/authority identities alone are normalized.
- Inventory listing, account-alt offer/name/status edit, offer-only price,
  price-only revision semantics, 1/2/3-cell geometry, direct withdrawal and
  full-receiving-Inventory failure: PASS. No silent Storage/claim destination.
- Stored/equipped/non-tradeable/foreign/stale/bounds/overlap rejection: PASS.
  Negative cache remains bounded; reject spam adds no durable receipts.
- Cross-alt success replay retains the original receiving character, including
  after later custody changes and reopening: PASS. Altered payload conflict and
  cross-account receipt isolation PASS. RAM rejects disappear with a new owner.
- Custody, offers, partially inserted cells, item revision and receipt faults on
  listing/edit/configure/withdrawal: PASS. State restores after every provisional
  write; the same command can execute after a transient SQL failure is cleared.
- Deferred COMMIT faults on list/edit/cancel: PASS. API reports unknown and closes
  session; reconnect confirms no partial committed state before explicit retry.
- Native mutual escrow/offer/provenance constraints, existing populated Storage
  extension, repeat/future-version guard and nested caller transaction: PASS.
- Overlapping independent sessions: PASS for listings with distinct starts but
  intersecting footprints, competing withdrawals and same-ID cross-alt withdrawal.
  Shared ID gives one mutation plus identical replay, not two transfers.
- Native BIGINT Shop ID and scalar revision above 2^53: PASS for direct result,
  durable recovery and replay after decimal-string scalar encoding.
- Existing PG Storage, Upgrade and NPC purchase fixtures: PASS.
- Default smoke: 14 Godot cases + 85 Web tests and bridge PASS.
- Existing SQLite market_custody and two-client market_network: PASS.

Initial schema bootstrap found an extra closing parenthesis in the new CHECK;
the final index pass also found a composite-constraint/index name collision.
Both were corrected before the final native pass. A legacy SQLite read-only receipt returns JSON numeric
scalars as floats; the fixture compares integer meanings without weakening custody
or replay assertions. Native exact-BIGINT cases remain strict. Successful fixture
logs contain no SCRIPT ERROR/Parse Error. Deliberate SQL fault diagnostics and
known teardown/resource warnings are not reported as new functional failures.

No fake claims/revenue API, economic settlement, data import or production worker
is included. Negative cache is owner/thread-local, not durable distributed C2
admission. PostgreSQL clients, physical CEF, Linux, broad P2/load, P3 fencing and
cutover remain unverified/deferred. See [scope and commands](../../development/postgres-shop-seller-parity.md).
