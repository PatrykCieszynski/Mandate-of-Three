# E1a: canonical custody, escrow, account claims and receipts

Feature `codex/e1a-market-custody`, based on integrated account wallets in `shop`.
Backend only: no My Shop frontend or buying in this package.

## Canonical SQL location

Migration v19 preserves every ItemInstance field/UID and moves bag/equipment/
Storage locations into one physical `item_custody` table. UID is its primary key.
The old `item_placements` and `account_storage` names become compatibility views
with write triggers; existing inventory/Storage operations continue through them.
They are not additional location records. Escrow/claim views project the same
canonical table. Character containers use character ownership; Storage/escrow/
claims use verified Master account ownership. Provenance remains on ItemInstance.

Deferred reciprocal foreign keys require each item and custody row to exist
together at commit while permitting a transaction to change locations. Unique
UID prevents two simultaneous locations, including direct SQL bypass. SQL checks,
owner triggers, bag/equipment/storage/shop position indexes, one-offer-per-UID and
one-custody-per-offer constraints prevent aliasing or owner mismatches. Open offer
foreign keys bind its UID, offer ID, shop, owner and position to its escrow record.
Shop footprint cells have unique shop/position keys and custody references.

SQLite foreign_keys is explicitly enabled and retained on reopen. Migration rejects
unplaced/duplicated items or inconsistent character placements rather than guessing.
All table/view/trigger changes and schema version commit together; failure restores
the original schema/data. There is no general ORM or generic persistence framework.

## Commands and custody transitions

MarketStoreSqlite provides account-wide create/get shop, inventory-to-escrow,
offer-to-account-claim, and claim-to-receiving-alt inventory. Each mutation uses a
bounded command ID, server-derived account, stable request fingerprint, expected
revision where applicable, and a durable account-scoped receipt in the same commit.
Retries return the previous outcome; different data with the same ID returns
command_conflict. Validation failures are also stable receipts. SQL failures roll
back and create no success receipt, so retry remains possible.

Listing checks bag ownership, revision, tradeable content and real 1/2/3-height
footprints. The initial shop is 5x8 cells (40); slot geometry remains presentation.
Listing increments item revision and removes it from Inventory. Equipped/Storage/
escrow items cannot be listed as bag items. The developer trace sword is explicitly
nontradeable. Cancellation moves to account claims even when all alts' bags are full.
Any verified alt can claim if its real Inventory has space; ownership/revision are
changed atomically without changing rolls or sockets. Receiving character is part
of the claim fingerprint, preventing a retry from silently targeting another alt.

Live offers are removed on cancellation; the durable command receipt retains the
outcome. There is no separate per-kill or generic event log. Core UI integration,
rename/pause/move/reprice and public shop presentation belong to E1b; buying to E2.

## Evidence and verification

`run-market.ps1` covers populated migration failure/retry/reopen, preserved bag/
Storage snapshots, two accounts and alts, every listing/cancel/claim SQL write
stage, durable retries, changed-command conflicts, full Inventory, foreign owner,
direct duplicate-location bypass, offer alias rejection and unplaced commit failure.
These new custody/receipt risks were not covered by old inventory/economy tests.

Existing smoke and Yang/NPC Shop/Upgrade/Web Inventory network tests pass under
the canonical model. Test seeding now creates/destroys items transactionally through
the real receive path. SQL fault triggers target the physical custody write rather
than obsolete table internals. The historical v14 grid migration uses an actual
pre-custody fixture. No pixel/DOM/animation tests were added to default smoke.

The dev World stopped gracefully and was backed up before v19. It had 380 items;
after unchanged migration plus 12 documented new session-fixture items, it had
392 items and 392 custody rows, with zero foreign_key_check failures. Real four-alt
Gateway/Master/World and existing two-client item relog suites pass. Backup is
ignored `.godot/runtime/backups/e1a-pre-custody.db` with matching Master collection.
Rollback requires compatible code plus that stopped-World backup; v18 code expects
physical legacy tables and should not operate on a v19 database during rollback.
