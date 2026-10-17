# PostgreSQL P1e — account Storage parity

Contract before implementation: opt-in port of the existing deposit, Storage move
and withdrawal, with atomic custody/provenance/revision/receipt changes. Access
comes from the authenticated character's trusted account binding. Depositing
keeps character provenance; withdrawal assigns the receiving character. A stored
item is never visible in a character's Inventory.

Preserve first-fit/explicit multi-cell placement, page bounds, full destinations,
same-cell no-op, account/issuing-character/kind-scoped receipts and original
operation identity on replay after lost response/reopen/later account mutations.
Rejects and partial writes must not leave new custody, revisions or receipts.
COMMIT failure stays unknown and retires the native connection.

Verify snapshots against migrated SQLite and add targeted independent-session
checks for competing withdrawals and the same shared Storage destination. This
is not a complete P2 concurrency gate, new async World executor, CEF/network
change, automatic outcome discovery/fencing, data import or runtime cutover.
Production World remains on SQLite. Player Shop, Upgrade and Exchange ports are
separate work.

## Schema and ownership

`storage_schema_postgres.gd` adds a separately versioned `storage` feature after
the P1d schema. It upgrades populated Inventory/equipment without replacing
items, receipts or watermarks. Custody gains an explicit nullable
`storage_account_id`: required for `account_storage`, forbidden for bag/equipment.
For all three locations `owner_id` still matches the item's character provenance
through the existing deferred UID/owner foreign key. A second deferred composite
foreign key proves that Storage's account owns that provenance character. A
unique partial index protects each account's starting cell; the service checks
the complete footprint while holding the account lock.

This deliberately keeps account access separate from character provenance. It
does not overload `owner_id` with account IDs or create placeholder Shop escrow,
claims or other unported custody types. The existing revision trigger still
resolves provenance to its account and preserves SQLite's watermark increments.
Withdrawal replaces custody and changes provenance to the receiving character
in the same transaction. The UID, amount, upgrade, affixes and sockets survive.

Inventory reads and item lookup now explicitly restrict custody to bag/equipment.
This is necessary once the schema admits Storage: provenance alone is not an
Inventory placement or authorization to equip/activate a stored item.

## Command and locking behavior

`account_storage_postgres.gd` implements snapshot, transfer command and read-only
receipt discovery. It resolves account identity from trusted character bindings,
never a requested account. It reuses the native receipt owner and the unchanged
decimal-string codec. The account-scoped fingerprint includes the original
issuing/receiving character and requested position, including `-1` for first fit.
Replay returns the original receipt, without restoring historical placement after
another alt has moved/withdrawn the item. A successful no-op has a receipt but no
new mutation/revision. Rejected requests do not add durable receipts.

Storage uses explicit shared-account admission in `economy_command_postgres.gd`:
lock account first, then issuing character, then inspect the receipt and capacity.
This coordinates all alts, including simultaneous reuse of an operation ID:
another issuer must observe `command_conflict`, not reach a duplicate-key failure
after provisional mutation. Default character-only command behavior stays local
to the character; this is not a global writer or generic command queue.

Account and character locks use `FOR NO KEY UPDATE`. They serialize peer writers
but allow foreign-key `KEY SHARE` checks on provenance/account identity. An
exclusive character lock would unnecessarily conflict with those references and
can form a wait cycle when an alt waits for shared admission. Trusted character
bindings remain immutable through the existing bind API; a changed binding
between shared admission and the locked character read fails closed.

Both backends use the small shared `storage_grid.gd` geometry. SQLite's public
constants and `AccountStorageSqlite.cells()` remain compatibility delegations;
its SQL, commands, networking and client recovery behavior are unchanged. No
PostgreSQL store depends on a SQLite connection/transaction implementation.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite storage
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite inventory
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite npc-shop
./tests/run-smoke.ps1
./tests/run-web-inventory.ps1 -Scene storage_recovery
```

The new opt-in fixture compares migrated SQLite and PostgreSQL snapshots for
all three fixture characters, account Storage, derived stats, item/account
revisions and receipt count. UIDs are prepared identically; only independently
generated authority IDs are normalized. It covers deposit/move/withdrawal,
first-fit/exact placement, 1/2/3-cell footprints and both pages, equipped/stored
Inventory rejection, full Inventory and Storage, no-op, stale/owner/overlap/bounds,
account/character/kind isolation, request conflict, reject growth, and original
receipt replay after later operations, reopen and full destinations.

Faults target item revision/provenance, custody insertion and receipt insertion
on both deposit and withdrawal. All observed snapshots/revisions/receipts must
remain unchanged. A deferred native COMMIT failure closes the connection and
returns unknown; reopening verifies the actual committed state before retry.
Additional checks cover existing populated schema upgrade, repeat bootstrap,
future version refusal, nested caller transaction preservation, rejected direct
cross-account custody/unsupported locations and exact BIGINT issuer discovery.

Independent sessions are created/used/closed on fixture-only workers. A native
account-row barrier plus observed PostgreSQL lock waits ensures both commands
actually overlap before releasing them. Scenarios check one winner for one UID,
one shared destination, competing cross-alt provenance moves and one shared
operation ID. Receipts and final custody are checked, not a winning thread order
or expected millisecond duration. No worker model is added to production World.

Windows, Godot 4.7.2, official pinned SOCI v0.4.2 and PostgreSQL 18.6 are verified.
All clusters/databases are fresh owned fixtures; installed PostgreSQL data and
services are untouched. Existing SQLite Storage recovery still exercises the
two-client journal/retry/fanout path. This does not validate PostgreSQL-backed
clients, physical CEF, Linux, broad P2 race/load coverage, P3 distributed fencing
or cutover. Other P1 domain ports remain pending; the runtime stays on SQLite.
