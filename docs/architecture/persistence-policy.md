# Persistence policy — current runtime

Normal development uses PostgreSQL for Economy, Master accounts and World
profiles/social services. The owner approved a clean test-data start on
2026-10-21. [Full-state setup](../development/postgres-full-state.md) is the
canonical deployment runbook. Embedded SQLite through godot-soci is used only
for focused reference/local fixtures; the godot-sqlite addon is retired;
selecting PostgreSQL never permits fallback after startup or write failure.

An active character's simulation state and committed-state projections live in
World memory. Durable economic authority belongs to database transactions, not
the cache. Combat never performs SQL or network round trips per hit.

## State categories

| State / operation | Runtime behavior | Persistence |
| --- | --- | --- |
| XP, level, available attribute points | Immediate change and level-up; separate dirty set | About 60-second checkpoint, only dirty characters and narrow Stats V1 progression fields |
| Attribute allocation | One authenticated point; current RAM changes only after COMMIT | Immediate narrow progression + allocation transaction and durable command receipt |
| Grinding Yang income | Account wallet balance, pending delta, separate dirty category | About 30-second delta checkpoint; no record per currency stack |
| Item creation/destruction, pickup, ownership, placement, equipment | Validate authoritative item/session context; refresh projections after commit | Immediate atomic transaction with custody/revisions and applicable receipt |
| Storage transfer | Account-shared custody; withdrawal names its receiving character | Immediate item/placement/ownership/revision transaction |
| Critical Yang spend, NPC purchase, upgrade, trading | Include captured pending income with the durable mutation | Immediate atomic transaction; no independent payment/item commits |
| Direct player trade | Both accounts held through settlement; both projections reconcile before completion | One transaction for both pending prefixes, Yang, UID/custody/revisions and dual receipts; unknown outcome uses lookup, never blind retry |
| Marketplace sale | Transfer UID, debit buyer and credit seller's claimable revenue | One immediate transaction, including its durable result |
| Revenue collection / Exchange | Reconcile committed balances and reservations | Immediate transaction with replay/recovery guarantees |
| Party membership/invitations | World-process RAM, 120-second reconnect grace; independent of local MapInstance | No persistence; World restart clears party |
| Transient actors, GroundCurrency, encounter HP | Authoritative World simulation | No per-tick or per-mob-death durable history |

Materials/currencies represented as Inventory items or stacks follow item
transactions, including split/merge, rather than the wallet checkpoint policy.
Accepted future socket/reroll/crafting operations must preserve these
atomicity rules; this table does not assert that all those features exist.

## Soft progression and wallet checkpoints

`WorldDatabase.dirty_progression` retains dirty character references. A batch
updates only `level`, `experience`, `available_attributes_points`, `attributes_json`
and `progression_json` (milestones, skill points, allocation revision/version); successful
commit clears dirty state, while failure rolls back the batch and preserves it
for retry. Clean intervals cause no progression transaction. Normal full-profile
saves remain separate; an XP change does not serialize Inventory, quests or the
entire PlayerResource.

The PostgreSQL Wallet runtime owns account bindings, loaded wallet state and
pending income. Checkpoints persist captured deltas, not stale balance snapshots.
Critical operations include the captured pending prefix in their transaction.
Only a confirmed result may consume that prefix; income earned later remains
pending. Wallet revisions and reconciliation prevent older results or receipt
replay from overwriting newer RAM. See
[wallet/ground currency](yang-wallet.md) and
[committed-state reconciliation](../development/economy-command-boundary.md).

Logout/disconnect, map/session departure and graceful save/shutdown force the
relevant checkpoints. Local CH transfer waits for checkpoint success before
removing the source actor. Failed saving retains dirty/pending state; graceful
shutdown cannot report success while required work remains unresolved. See
[local transfer](../development/local-channel-transfer.md) and
[maintenance/drain](../development/postgres-maintenance.md).

A crash can lose soft progression and eligible grinding income since the last
successful checkpoint: normally about 60 and 30 seconds respectively, potentially
longer during backend failure. This accepted window does not apply to committed
item mutations or critical Yang transactions. Mob death grants XP in RAM without
a persistent KillEvent/kill receipt. Ground pickup has its own economic identity
and durable claim protection.

## Committed state, receipts and recovery

Inventory, Wallet, Storage, pickup, NPC and Marketplace/Exchange operations use
their existing application/runtime owners and PostgreSQL stores. World endpoints
own authorization/admission and publication; workers own transaction execution.
A result reconciles current Inventory/equipment/combat and wallet projections
before publication. A receipt replay is not a new commit or a second mutation
fact. Combat reads the prepared equipment-derived cache; invalid/missing state
must not silently leave usable stale stats.

Client intentions retain original operation identity and payload through lost
responses and reload/reconnect. Recovery queries existing outcomes; transport
failure is not proof of rollback and does not authorize a new operation identity.
Storage preserves the original issuing/receiving character within account-scoped
recovery. Current snapshots, not historical receipt contents, restore usable
runtime state. See [command/recovery boundary](../development/economy-command-boundary.md).

Shop/Auction sales credit separate account `account_shop_revenue`, not the seller's
spendable wallet or pending income. Manual collection takes only what fits,
counting pending income and reservations, and retains the remainder. Values cross
the browser boundary as decimal strings. See [revenue policy](../development/shop-revenue.md).

Profile/social writes check transaction start, each write and COMMIT;
client success and live-state publication follow confirmed commit. Unknown profile
COMMIT outcomes fail closed and require authoritative reload/operator recovery,
not automatic mutation retry. Retired guild/mail/chat tables are retained without active services; opaque profile
columns survive saves without granting gameplay state. Details: [full-state failure behavior](../development/postgres-full-state.md).

## Deployment, verification and limits

PostgreSQL backup/restore uses the documented maintenance barrier and database
tools, not copying a SQLite file or treating a checkpoint as a backup. See
[backup/restore](../development/postgres-backup-restore.md).

Use [testing policy](../development/testing.md) to select the relevant runtime,
race, rollback and recovery suites. SQLite/WAL tests remain reference coverage;
they do not prove PostgreSQL concurrency. The full-state fixture covers real
Gateway/Master/World login, persistence and restart with disposable PostgreSQL.

Current development still has one World Process. This policy does not establish
cross-host ownership, distributed cache coherence or an extracted Economy Service.
[Economy C1–C5](economy/README.md) defines accepted target contracts; completed
migration steps and old SQLite schema versions belong in
[migration history](../history/postgresql-migration.md), not the current setup.
