# Persistence policy - explicit state categories

Accepted following the user's review. The database is the persistence layer;
an active character's authoritative state lives in World Server memory. Do not
build a generic stats/event framework or autosave the entire profile for each change.

| State / operation | Runtime | Persistence |
| --- | --- | --- |
| XP, level, unspent attribute points | PlayerResource + separate dirty set | Approximately 60-second checkpoint, dirty characters only, one transaction |
| Equipment and combat stats | Minimal server cache restored on entry | Immediate item transaction; refresh cache after commit |
| Account Storage deposit/withdrawal | Account placement; receiving character on withdrawal | Immediate atomic item/placement/ownership/revision transaction |
| ItemInstance: pickup, equip/unequip, ownership, placement | Server validates intent | Immediate atomic persistence |
| Yang grinding income | Balance + pending delta + wallet dirty | Delta checkpoint around 30 seconds |
| Economically significant Yang spending | Check affordability against RAM | Immediate transaction including pending income, spending and economic mutation |
| Trade, upgrade, socket, reroll, crafting | Server-side result | Immediate transaction for all changed durable data |
| Materials/currencies acting as inventory items or stacks | Item/stack | Immediate transaction, including split/merge and creation/destruction |

## Current runtime and checkpoints

`WorldServer.runtime_equipment` stores active characters' equipment UIDs and
resulting stats by persistent ID. Entry loads inventory from SQLite;
`SpikeInventory3D._send_state()` refreshes runtime from committed state.
Combat reads `attack` from runtime without querying on a swing. Failed equipment
changes affect neither placement nor attack; a missing valid snapshot invalidates
the cache so combat cannot use stale stats after a read error.

Mob death is a runtime event. DEAD state prevents repeated processing within the
current encounter. Contribution resolution and XP run in RAM; level-up and client
notification are immediate. There is no persistent KillEvent or kill ID for XP.
The ground item's UID still serves its economy-critical claim independently of progression.

`WorldDatabase.dirty_progression` is a separate set of character references.
Every 60 seconds, one transaction checkpoints only `level`, `experience` and
`available_attributes_points` for dirty characters. Success clears their dirty
flags; failure rolls back the batch and retains RAM/dirty state for retry.
No dirty characters means no transaction. Reentry reads the dirty resource to
avoid reverting unsaved progression.

Forced checkpoints run before session end, on disconnect and 3D map departure,
before existing instance transfer and during world save/shutdown/restart.
Graceful shutdown through the master is cancelled if a checkpoint fails.
Dirty references remain available for retry after disconnect. 3D process transfer
is not implemented; future handoff must wait for a successful checkpoint before
transferring ownership.

The older full-profile serializer still handles independent legacy data, normal
session saving and backups. XP ticks/kills do not invoke it. Its existing schedule
does not replace the progression checkpoint.

Schema v13 removes unused `kill_xp_rewards`, retaining XP fields and items.
A crash may lose soft progression since the last successful checkpoint: normally
about one minute, or back to the last successful save if the DB is unavailable.
Kills are not recovered from durable history. Item pickup/placement retain
immediate transactions and their own double-pickup protection.

## Yang: runtime wallet and ground currency

Spike 3D has a separate Yang wallet and runtime GroundCurrency. Dogs drop 30 Yang
with the same loot rights as their items. Auto-pickup works within 1.25 m; G picks
up within 2.5 m. There is no pet, persistent stack UID or per-drop DB record.
Legacy gold remains separate upstream state and is not migrated into the wallet.

Wallet fields are explicit: `wallet_balance`, `pending_currency_delta` and a
separate dirty set. Income changes RAM balance, accumulates a positive delta and
marks the wallet dirty. Every 30 seconds, checkpoints add the delta rather than
overwriting an older snapshot:

```sql
UPDATE wallets SET yang = yang + ? WHERE character_id = ?;
```

Successful commit clears pending delta; failure retains it for retry.
WorldDatabase's separate `dirty_wallet` checkpoint is not part of full
PlayerResource autosave or dirty progression.

The test button spends a fixed, server-defined 50 Yang. Critical spending checks
runtime affordability and commits pending income with the cost. The current test
only consumes currency. A future upgrade/purchase/trade must mutate durable
economic state in the same transaction; separate spend and item commits are not
acceptable. Example: DB 40000 + pending 30000 - cost 50000 = 20000 in one COMMIT.
After commit, runtime balance is 20000 and pending delta is zero. Rollback does
not consume pending income or publish item changes. Transactions must also prevent
negative balances. Old DB state must not reject a purchase affordable after pending income.

GroundCurrency is a runtime entity: amount, loot rights/owner, position, expiry.
Pickup adds to the wallet and removes the entity. It creates no persistent
ItemInstance, durable UID or DB row for each small Yang stack. A tradable inventory
currency remains an item/stack with immediate persistence.

Wallet and progression have separate dirty sets and independent checkpoints.
Position dirty state is future work. Wallet loads on entry; logout/disconnect/
handoff/save/shutdown force both checkpoints. Failed wallet saving retains RAM
and pending delta even offline. Schema v14 adds `wallets`; PlayerResource's
serializer does not overwrite it. A crash may lose unsaved income and ground
currency, normally from a roughly 30-second window. Committed critical spending is durable.

## Tests

`run-progression` verifies runtime attack after equip, rollback without cache
mutation, zero inventory reads in both tested swings and stat restoration from
persistent equipment on entry. `run-xp` verifies multiple kills in RAM, no receipt
table, checkpointing, real disconnect, batch rollback, UPDATE of only three columns,
no clean-character writes and the accepted crash window. Full gateway/master/world
still tests logout/relog, level-up and the exact weapon UID.

`run-yang.ps1` checks delta checkpoints, no XP/profile writes for Yang, spend/batch
rollback, private HUD, rights/autoloot/pickup races, expiry, obstacles, RPC replay
and real disconnect. Full `pve_session` verifies combat/autoloot income and exact
balance after logout/relog.
