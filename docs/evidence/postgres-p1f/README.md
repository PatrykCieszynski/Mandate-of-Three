# PostgreSQL P1f — Upgrade parity evidence

2026-10-17, Windows, Godot 4.7.2, official pinned SOCI v0.4.2, PostgreSQL 18.6
from `Y:/Software/PostgreSQL/bin`. Fresh owned SCRAM loopback clusters and migrated
disposable SQLite fixtures only. Production runtime remains SQLite.

- Native `--suite upgrade`: PASS. Prepared UIDs and item/material/custody,
  account Storage, wallet/reservation, derived stat, revision and receipt-count
  snapshots match SQLite after successful and rejected operations.
- One upgrade fully consumes one stack and partially consumes another. Subsequent
  upgrades exercise partial and final whole-stack consumption. UID, rolls,
  sockets and placement survive; equipping the upgraded item reflects its stats.
- Missing material, same-account alt/Storage/upgraded material exclusion,
  equipped/stored target, funds/reservations, invalid recipe, level, stale and
  owner rejection: PASS. Rejected requests do not add durable receipt rows.
- Custody/material deletion, wallet update, late target and receipt faults: PASS.
  Item/material/provenance, pending-income application, spend, revisions and
  receipt writes roll back together. Whole-stack restoration checked separately.
- Original receipt replay/discovery after equip, later wallet changes, all
  eligible materials consumed and reopen: PASS. No second charge or application
  of newer pending income. Account/issuer/kind isolation and conflicts PASS.
- Deferred native COMMIT fault: PASS. Connection closes/API returns unknown;
  reconnect confirms unchanged state and absent success receipt before retry.
- Native caller-transaction preservation and BIGINT issuer/item/wallet revisions
  above 2^53: PASS.
- Default smoke: 14 Godot scenarios + 85 Web tests and bridge PASS.
- Existing two-client SQLite `run-upgrade.ps1`: server/client1/client2 PASS.

Initial fixture compile found a helper colliding with Godot's `seed()` builtin;
renamed it. Metadata preservation now compares against the persisted pre-upgrade
snapshot, preserving the assertion without binding it to JSON int/float spelling.
High wallet revisions are seeded by controlled INSERT because the UPDATE trigger
correctly owns that revision. Passing native runs have no SCRIPT ERROR/Parse Error;
deliberate SQL faults and known teardown/resource warnings remain distinguishable.

No credentials, DSNs, native logs, databases or binaries are committed. Storage
has no mutation in this port; future Shop/Exchange ports must retain its account
lock and complete-footprint contract. PostgreSQL clients, physical CEF, Linux,
broad concurrency/load, automatic outcome discovery/fencing and cutover remain
unverified/deferred. See [scope and commands (historical)](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/d9c7ecb42c166106aab24e772c0afad1de6908a8/docs/development/postgres-upgrade-parity.md).
