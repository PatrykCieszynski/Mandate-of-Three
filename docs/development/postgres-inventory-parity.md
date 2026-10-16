# PostgreSQL P1d — character Inventory persistence parity

Contract before implementation: opt-in port of the existing character-local
Inventory behavior, using the P1c custody/receipt model and native SOCI session.
World/client/journal behavior remains on SQLite. No Storage, Player Shop, Upgrade,
Exchange, new item actions, transport change or generic persistence framework.

Scope: one-time starter initialization; stable prepared ground UID claim; durable
move/equip/swap/unequip/activate commands and read-only receipt recovery. Preserve
ownership/revision checks, exact/first-fit multi-cell capacity, equipment stats,
no-op semantics, atomic rollback and replay after response loss/reopen. A failed
COMMIT remains unknown and retires the connection; it is not a safe-new-ID retry.

Verification must compare observable snapshots with SQLite, including partial
swap/move/pickup and receipt/COMMIT faults, full-bag failure, double pickup, account
and receiving-character isolation, original receipt watermarks, and no repeated
initialization grant. The runtime's existing clients and CEF remain unmodified;
P2 independent-connection races and P3 async World execution/fencing are separate.

## Implementation

`inventory_schema_postgres.gd` adds version 1 of the `inventory` feature after
the existing wallet/NPC schemas. It owns only the one-time starter marker and
ground-claim marker. The claim marker deliberately outlives an item: later
destruction must not make an old drop UID claimable again. Item/custody foreign
keys, unique starts/equipment slots and account revision triggers remain in the
existing character-only schema.

`item_store_postgres.gd` owns the character use cases on a single native session.
Move checks placement with its own UID excluded; swap finds room for the previous
weapon before replacing either placement. Delete/reinsert custody and item
revision updates preserve SQLite's account watermark semantics. Stats are read
from the same authoritative definitions/affixes. Successful no-ops have receipts
but do not publish a new item mutation. Activation uses the item's existing
primary action; no consumable implementation or toggle behavior is added.

`economy_command_postgres.gd` now supplies the shared item-state query directly,
removing its dependency on ItemStore before that store uses command receipts.
The receipt format and NPC transaction flow are unchanged. Recovery filters
account, BIGINT receiving character, command kind and operation ID. Replay returns
the original result before evaluating current placement/revision/capacity.

Starter and pickup take the same character row lock as Inventory commands.
The caller supplies an already prepared ground item and stable UID; this store
does not generate a second item on retry. A committed claim rejects another
pickup as `claimed`, including after reopening. Failed/full-bag claims leave no
marker, so the same drop can be retried. These standalone APIs reject a caller's
active transaction without committing or rolling it back.

All COMMIT failures return `outcome_unknown`, retire the session, and leave
discovery to the caller. Tests reconnect to inspect the actual result of an
injected deferred failure. They do not turn arbitrary transport loss into a
definitive rejection or implement P3 automatic outcome discovery/fencing.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite inventory
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite npc-shop
./tests/run-smoke.ps1
```

The new fixture runs the same observable Inventory scenarios against migrated
SQLite and PostgreSQL, comparing items, equipment, derived stats, revisions and
receipt/claim/grant counts. Only independently generated starter UIDs and authority
IDs are normalized. It covers 1/2/3-cell footprints, stale/owner/overlap/page
rejections, no-op receipts, account/character/kind isolation, request conflicts,
replay after later mutations/reopen/full bag, and rejected-request table growth.

Faults target the starter marker, custody, item revision and receipt, including
after a swap has started relocating both items. Snapshots must remain unchanged.
Full-bag pickup is retried with the same UID after freeing space. PostgreSQL-only
deferred faults cover command, pickup and starter COMMIT; the connection closes
and reconnect observes no partial state. Schema repeat/future-version guards and
caller-transaction preservation are also checked. Existing NPC parity protects
the shared receiving/state/command foundation.

Windows, Godot 4.7.2, official SOCI v0.4.2 and PostgreSQL 18.6 are the verified
environment. Linux, physical CEF, PostgreSQL-backed game clients and concurrent
independent writers are not validated here. World's SQLite gameplay/client retry
path is unchanged. Account Storage, Player Shop, Upgrade and Exchange ports and
P2–P4 remain separate work; this does not complete P1 or authorize cutover.
