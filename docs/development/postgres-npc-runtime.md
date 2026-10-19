# PostgreSQL NPC Shop and Upgrade runtime — P3j

P3j optionally connects the existing NPC Shop and +0 → +1 Upgrade flows to the
native PostgreSQL ports. Normal startup remains SQLite. No new recipe, UI,
protocol signature, SQL schema, database selector or generic command framework
is introduced.

## Admission and transaction ownership

`Shop3D` / `Upgrade3D` still authorize the current map actor, NPC, selected service
and range. Transfer admission remains closed. Upgrade selection/quotes read the
authoritative RAM Inventory snapshot; selecting a UID never changes custody.
The browser still sends only existing IDs, revision and optional placement.

The new map-local `npc_postgres_adapter.gd` owns RPC correlation/publication.
`npc_runtime_postgres.gd` coordinates the two use cases. A dedicated instance of
the existing bounded executor owns native sessions and whole store transactions.
Only copied primitive server-authored definition data crosses the worker boundary.
Price, quantity, material and recipe data never come from a client.

NPC authorization is the World admission check in the same turn as enqueueing.
A full worker pool does not retain a mutating request for later execution after
its NPC context expires. An operation already enqueued may finish after the player
moves or closes the window; active SQL is never cancelled. A later explicit
mutation retry must pass current NPC/service/range authorization again.

Each store validates the delegated session under the account lock, then performs
its existing fresh ownership/revision/capacity/material/funds checks. Pending
income, Yang spend, item creation or material consumption/upgrade and the success
receipt still commit together. Registered PG sessions cannot use the unqualified
legacy NPC write APIs. The existing bounded whole-transaction retry remains;
COMMIT uncertainty never triggers blind SQLSTATE retry.

## Captured income and current projections

The coordinator admits one NPC economic operation per account. It reserves the
wallet's current RAM income prefix and holds local Inventory mutation/combat
readiness. Other accounts continue independently. Ordinary wallet checkpoints,
other NPC operations and Inventory writes cannot race this captured prefix.
The wallet/Inventory binding limits and native queue capacities remain bounded.

An opaque capture token is recorded in the existing success receipt JSON. Only a
receipt carrying that token can consume the locally reserved prefix. Reading an
old receipt with a newly created RAM capture must not remove later income. No
extra record is created for individual drops, and no schema change is needed.

After a known outcome, both wallet and Inventory are refreshed before terminal
publication. Inventory retains its backend revision ACK and committed marker
floor. An uncertain projection ACK/read can be repaired without resubmitting the
business mutation. Automatic receipt/projection repair is bounded to three
attempts; an explicit client retry can request another recovery attempt.
Callbacks cannot complete a replaced session or reopen a newer invalidated view.
Known new-commit facts publish once; receipt replay only repairs current projections.

## Lost response, reconnect and restart

The existing Shop and Upgrade client journals persist the operation ID/body
before sending. Timeout/storage/recovery errors retain uncertainty. Reload or
relogin first performs read-only receipt discovery, even if the original item is
already moved/upgraded or the NPC context has closed. A missing receipt permits
execution only through the explicit, reauthorized original mutation path.

`queued` is internal volatile scheduling, **not durable server admission** and
not an acknowledgement sent to the player. This package does not introduce a
durable NPC command queue. If World crashes before a mutation commits, a saved
client intent can be retried explicitly; RAM-only grinding income can be lost
within the accepted checkpoint window. After a committed mutation, the receipt
and economic result survive, and a new capture cannot apply its prefix twice.

On same-World account/alt replacement, an unresolved operation keeps its original
issuer and capture. The new authorized context may discover the old receipt;
it never executes the old mutation under a new character. Old peers get no
terminal response/private Inventory. Dirty/unknown state blocks graceful drain;
World keeps polling, then joins NPC and wallet workers after settlement.
Other economic endpoints still cannot fall back to SQLite in the opt-in mode.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite npc-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
```

The new native fixture covers full capacity, account independence under SQL locks,
copied content, Inventory/wallet gates, exact item/material/Yang atomicity,
rejection, lost successful completion, replay with new income, native failed
COMMIT, receipt-only recovery, uncertain projection ACK repair, alt fencing and
worker drain. It supplies peer maps/control availability and trusted content.

The extended existing endpoint fixture uses native Master–World authentication
and four actual client processes with production NPC/Shop/Upgrade RPCs and the
existing Web UI bridge/adapters/journals. It verifies no-context/range rejection,
Shop lost-response retry, Upgrade reload recovery and purchase recovery after
client process restart, while retaining prior Inventory/Yang contracts. SQLite
items/Yang remain unchanged. Map geometry and Gateway entry are controlled;
physical CEF input/rendering, Linux and production bootstrap are not claimed.

See [evidence](../evidence/postgres-p3j/README.md). The subsequent
[P3k Storage integration](postgres-storage-runtime.md) covers its separate
custody/recovery scope. Ground-item initialization/pickup, Player Shop,
Exchange, Auction reads, cross-process publishers, deployment/handoff and P4
cutover remain open in the [roadmap](../plans/postgresql-migration.md).
