# PostgreSQL P1e — account Storage parity evidence

2026-10-17, Windows, Godot 4.7.2, official pinned SOCI v0.4.2, PostgreSQL 18.6
from `Y:/Software/PostgreSQL/bin`. New owned SCRAM loopback clusters and migrated
disposable SQLite fixtures only. Production runtime remains SQLite.

- `--suite storage`: PASS. Same prepared UIDs and observable snapshots across
  SQLite/PostgreSQL: account Storage, all three characters' Inventories, metadata,
  provenance, equipment stats, item/account revisions and receipt count.
- Deposit, move by another alt, receiving-character withdrawal, exact/first-fit,
  same-cell no-op, heights 1/2/3, both pages, full Inventory/Storage, stale/owner/
  overlap/bounds and rejected-request receipt growth: PASS.
- Original receipt replay/discovery after other account mutations, reopening and
  full destinations: PASS. Account/issuer/kind isolation and payload conflict PASS.
  Stored items remain absent from Inventory and cannot be equipped/activated.
- Partial deposit/withdrawal faults in item provenance/revision, custody and
  receipt insertion: PASS. All snapshots/revisions/receipts remain unchanged.
- Deferred withdrawal COMMIT error: PASS. API reports unknown and closes session;
  reconnect confirms unchanged custody/provenance and absent success receipt.
- Populated Inventory/equipment schema extension, repeated bootstrap, future
  version rejection and caller-owned transaction preservation: PASS.
- Database rejection of mismatched Storage/provenance account, null account and
  unsupported escrow placement: PASS. BIGINT issuer above 2^53 recovery PASS.
- Actual overlapping independent sessions: PASS for single-UID withdrawal,
  shared destination, cross-alt provenance move and same account command ID.
  Each worker owns its own native connection; a database barrier and observed
  lock waits establish overlap. Final custody and receipt results are checked.
- Existing PostgreSQL Inventory and NPC purchase parity: PASS after changing
  character lock mode and adding shared-account command admission.
- Default smoke: 14 Godot cases + 85 Web tests and bridge PASS.
- Existing SQLite two-client `storage_recovery`: server/client1/client2 PASS.
  This protects the unchanged production journal/retry/account fanout path.

Review identified two lock/admission hazards before publication: exclusive
character locks conflict unnecessarily with provenance FK checks; and receipt
lookup before shared admission can race into a duplicate-key failure. Account-
first shared admission plus `NO KEY UPDATE` locks and overlapping native fixtures
now cover those boundaries. No global queue/worker is added to production.

Native runs contain deliberate SQL fault diagnostics and known teardown/resource
warnings, but no SCRIPT ERROR/Parse Error. No credentials, DSNs, databases, native
logs or binaries are committed. Linux, physical CEF, PostgreSQL-backed clients,
broader P2/load evidence, distributed discovery/fencing and cutover remain outside
this result. See [scope and commands (historical)](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/d9c7ecb42c166106aab24e772c0afad1de6908a8/docs/development/postgres-storage-parity.md).
