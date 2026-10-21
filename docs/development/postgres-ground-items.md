# PostgreSQL initialization and ground-item pickup — P3l

P3l adds optional nonblocking initialization/pickup using the existing PG item
store, native executor and delegated session fence. Normal startup remains
SQLite. There is no new schema, loot table, UI, protocol signature, per-kill
history or generic acquisition framework.

## Initialization before gameplay readiness

Construct the ground-item coordinator before attaching Inventory peers. It enables
Inventory's initial `initialize` stage, before pending recovery/snapshot/revision
ACK. A worker calls the existing `initialize_character` transaction: account lock,
character lock, grant check, `item_initializations`, the unchanged two-sword
prototype starter kit and marker commit together. Initialization accepts a valid
recovering grant; pickup requires a ready grant. Registered accounts cannot use
bare legacy init/claim calls to bypass that fence.

The marker is the stable identity for initialization. Lost COMMIT completion
pauses local readiness; explicit retry or a later session rechecks the marker,
without regranting an already committed kit. Failed/partial transactions leave
neither kit nor marker. Initial state is loaded and acknowledged before combat
stats or mutations become ready. No account/character provisioning or backend
selector is introduced: trusted identity binding and schema setup remain explicit.
An imported existing character must retain its initialization marker.

## Pickup ownership and transaction boundary

The existing RPC still accepts only a drop UID. World admission checks the current
map actor, alive state, transfer gate, loot protection, distance and line of sight
in the enqueue turn. The original protection/lifetime policy is unchanged. Only
a copied, already-rolled server drop and delegated context cross the worker
boundary. The browser cannot choose item contents, owner, position or bonuses.

The optional `ground_item_runtime_postgres.gd` admits one operation per account
and holds Inventory mutation/combat-stat readiness. Retained unknown accounts
and native queue capacity are bounded. A server-only drop reservation prevents
another peer from claiming that runtime UID or expiry from deleting it while SQL
is pending. Full native capacity refuses the mutation, releases the reservation
and leaves the drop; it is not queued again for later execution.

The existing store owns capacity/full-footprint validation, immutable UID and
rolls, item/custody creation, account revision and the global `ground_item_claims`
marker in one transaction. The native primary key remains the final double-claim
guard across independent DB sessions. A full bag/known rejection leaves the same
drop on the ground, subject to its normal remaining lifetime.

## Outcomes, publication and recovery

The UID is the stable pickup identity. A queued result is volatile scheduling,
not a durable admission or success. Known success/other-claim removes the drop;
Inventory then reloads and ACKs the current revision before final feedback and
known-new-commit publication. Receipt replay adds no item or commit fact.

An ambiguous COMMIT leaves the reservation/lane paused. At most three automatic
attempts read the durable claim; they never execute another mutation. Explicit
retry also discovers the outcome first. If no claim exists, the reservation is
released and the user may explicitly try pickup again with the same UID. A missing
runtime drop can initiate only read-only claim lookup, never item creation.

Claim lookup requires a current grant. Same-account outcome recovery may confirm
the original character's claim, including after RAM retirement or alt takeover;
it never moves that item into the replacement bag. A claim held by another
account yields `claimed` without its private data. A client reconnect loads the
authoritative saved inventory; there is no new pickup journal/import of another
character's intent. The existing pickup UX had no blocking pending purchase UI.

World polls acquisition alongside Inventory/wallet/NPC/Storage. Shutdown closes
admission and recovery scheduling, finishes accepted SQL and joins the owner.
Only then may unresolved delivery be deferred to UID receipt discovery, with
bounded diagnostics and summary warning, using the Storage pattern. Wallet/NPC
dirty-value rules remain separate. Ground entities themselves remain volatile:
this does not promise to persist unclaimed ground loot across a World crash.

The optional item-domain gate now allows the existing combat/loot simulation
without a SQLite item store. Combat still reads equipment-derived values from
World RAM, never a per-hit DB/network call. The same map-local endpoint callbacks
publish reconciled inventory and normal pickup feedback; CEF remains presentation.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite ground-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-concurrency
& ./tests/run-combat.ps1
```

See [P3l evidence](../evidence/postgres-p3l/README.md) for native faults, competing
pickups, capacity/full inventory, starter recovery and six actual client processes.
Gateway entry/map construction are controlled; the network economic fixture
omits mob simulation/rendering but executes production pickup RPC/feedback. Linux,
physical CEF, whole-World crash/failover, production provisioning/handoff, multi-
World invalidation and P4 load/soak/import/cutover are not verified by this slice.
