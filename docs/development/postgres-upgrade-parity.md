# PostgreSQL P1f — Upgrade persistence parity

Contract before implementation: port the existing server-authored +0 to +1,
100% recipe to the opt-in PostgreSQL backend. One native session/transaction
validates Inventory ownership/revision/placement, consumes ordered material
stacks, applies pending Yang plus critical spend, increments the same target UID
and writes the durable receipt. Any failure rolls all changes back. COMMIT error
remains unknown and retires the session.

Preserve original operation identity, account/issuing-character/kind isolation,
read-only receipt discovery and replay before mutable item/material/funds checks,
including reopen and later item/wallet changes. Compare observable item/material,
wallet, revision, receipt and derived-stat snapshots against SQLite.

Storage is not an eligible source for target or materials, including same-account
alts. Do not mutate Storage or bypass its account lock/whole-footprint contract.
No new recipe, gameplay, RNG/failure system, runtime backend switch, client/network
change, worker, schema/data migration or generalized crafting framework. Player
Shop, Exchange, broader P2–P4 and PostgreSQL-backed World execution remain pending.

## Implementation

`upgrade_store_postgres.gd` composes the existing native command owner, character
Inventory receiver/geometry and wallet spend within one transaction. It needs no
new schema: item upgrade level, revision, custody and receipts already exist.
Recipe definition/price/material come from trusted server data, with current
NPC/service/range admission still required at the application boundary.

Candidate lookup admits character bag/equipment custody only, rejects equipment
placement and requires the recipe's definition and a single target item. The
command then checks the expected +0 level and existing footprint with its own
UID excluded. It consumes eligible +0 material stacks from this character's bag,
in stable UID order: remove custody and item for a complete stack, or decrement
amount and increment revision for a partial stack. Material in Storage, another
alt's bag or an upgraded stack does not satisfy the recipe.

The same native session applies pending income and the critical Yang spend,
preserving reservations, then conditionally updates exactly one target UID and
writes the receipt. Native affected-row checks reject a missing/stale target or
material mutation. Item, wallet and receipt revisions remain part of the same
transaction. No Inventory slot move or new target UID is introduced.

The durable fingerprint remains character, recipe ID, target UID and original
revision. Replay occurs before current placement, materials, funds and newer
pending income checks; it returns the original result without another spend or
material consumption. Read-only discovery filters account, a BIGINT issuing
character, command kind and ID. Failed COMMIT returns `outcome_unknown` and closes
the connection; arbitrary transport-loss discovery/fencing remains P3.

This store never mutates Storage. Its target/material location filters respect
the separately owned account Storage contract. Future Player Shop/Exchange ports
must preserve that same shared-account lock and complete footprint validation,
not infer safety from the unique starting-cell index.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite upgrade
./tests/run-smoke.ps1
./tests/run-upgrade.ps1
```

The opt-in fixture compares migrated SQLite and PostgreSQL item/custody, shared
Storage, derived stat, wallet/reservation/revision and receipt snapshots. Prepared
UIDs are identical; only independently created authority IDs are normalized.
Cases cover whole/partial stacks in one upgrade, final whole-stack deletion,
pending income plus spend, missing/ineligible materials, reservations/funds,
ownership/stale/placement/level/recipe rejection, unchanged UID/rolls/sockets,
equipment stats after upgrade, replay/discovery/reopen after later mutations and
consumed materials, account/issuer/kind isolation, conflicts and rejected spam.

Faults target custody deletion, material deletion, wallet update, late target
update and receipt insertion. Every provisional write must roll back. A second
late failure after complete-stack consumption also checks restoration of both
material and custody. Native deferred COMMIT failure retires the connection;
reopen verifies committed state before retry. Native checks include caller-owned
transaction preservation and exact issuer/item/wallet revisions above 2^53.

Godot 4.7.2, official pinned SOCI v0.4.2 and PostgreSQL 18.6 on Windows are tested
using fresh owned SCRAM clusters. Existing SQLite smoke and the two-client NPC
Upgrade suite protect the runtime/journal/receipt/reconciliation path, which is
not moved to PostgreSQL here. No default CI PostgreSQL dependency is added.
Physical CEF, PostgreSQL-backed clients, Linux, independent Upgrade races/load,
automatic unknown-outcome discovery and cutover remain outside this evidence.
