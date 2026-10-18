# PostgreSQL Inventory endpoint — P3f

This opt-in slice connects the existing Inventory RPCs and client journal to the
P3d/P3e runtime. Normal bootstrap still selects SQLite; no realm configuration,
DSN, export switch, schema migration or production cutover is added.

## Ownership and lifecycle

Configure the trusted Master issuer and World Inventory runtime before creating
the map. `InventoryEndpoint3D` then creates one small map-local PG adapter. It
correlates native request IDs, filters publication to actors on its map and
subscribes/unsubscribes to runtime signals on endpoint creation/destruction.
It does not run SQL, derive account identity from a client, or own transactions.
Runtime still owns its bounded account workflows and exclusive executor polling;
the native stores retain all ownership/revision/placement/receipt guarantees.

The existing move/activate/equip/unequip and receipt RPC signatures are unchanged.
The adapter captures one outstanding correlation per peer, without adding a work
queue. Busy/recovering requests retain client intent for explicit retry. Existing
per-peer action/receipt limits remain in place. Late results from a detached
native peer/session cannot publish to the replacement.

Runtime hydrates authoritative stats before notifying the endpoint. The endpoint
adds the existing delivery version and publishes private Inventory plus public
weapon state. The native item-state marker supplies the client journal scope
(`authority_id`, `account_id`, `character_id`); the Master token/epoch/fingerprint
are never sent to Web UI. Joining a map after runtime hydration uses a copied RAM
snapshot. Publication never reads SQLite or refreshes combat stats itself.
Initial private publication waits for the backend readiness acknowledgement;
otherwise client journal discovery could race the still-closed recovery lane.

`inventory_committed` reports only a confirmed worker mutation after hydration.
Receipt replay, no-op, missing receipt, rejection and private repair do not claim
a new commit. Several recovered mutations may coalesce into one final state fact;
it is an invalidation/change notification, not an audit/event-delivery guarantee.

## Lost replies and uncertain transactions

The existing `ItemUiAdapter` writes a stable ID/body to its scoped local journal
before sending. Timeout, reload and process loss do not create a new operation.

`request_outcome` performs session-qualified asynchronous discovery. A paused
binding first recovers admitted account work, hydrates and acknowledges its
current snapshot. A durable pending operation may finish with its original body;
a missing operation is returned as `unknown_command`, never automatically admitted.
Only the user's explicit retry resends the saved original ID/body after that
discovery. An unresolved different operation cannot replace the paused command.

A terminal success **or rejection** is published after current snapshot repair.
The additive `terminal: true` response field lets the client clear a confirmed
rejection even when its original reply was lost. Storage errors, uncertain COMMIT,
busy/session failures and missing receipts never carry that flag. The client
keeps their journal entries unresolved. Browser `ui.ready` continues to replay the
current domains independently of the native request session.

## Isolation and remaining work

There is no mixed writer mode. With the optional PG runtime installed,
`MandateWorldServices.item_store()` and `.economy()` do not expose the SQLite
economic authority, and the generic economics mutation gate stays closed.
Soft progression retains its separate existing SQLite service. The PG Inventory
adapter explicitly checks the local transfer gate; its native runtime separately
checks delegated session/readiness. Storage is presented as unsupported, and
Inventory publication does not call the SQLite Upgrade publisher.

This fixture is **not a playable PG realm**. Other economic domains, their reads,
wallet income/checkpoints, committed publishers for other domains, handoff/pending
Yang, bootstrap/provisioning and controlled shutdown remain migration work. [P3g](postgres-inventory-cache-fence.md) adds post-command
freshness ACK and a local versioned invalidation consumer. Do not enable concurrent
Shop/Storage/Upgrade writers without integrating their publication and recovery contract.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
```

The owned fixture runs real headless **client processes** and native Inventory
RPCs, `ItemUiAdapter`, bridge, journal and server transactions. Master and World
control/game sockets run in the fixture's server process; Gateway credentials,
roster initiation and map/actor construction are controlled. It is not a full
production Gateway/Master/World bootstrap or native CEF/browser-rendering test.
Ports 18098/18099 must run sequentially with other network suites. Client profiles,
journals and logs live under the owned verification directory. Watchdogs and the
runner's owned-process-tree timeout bound failures; normal success waits for all
client processes and both executors to stop.

See [P3f evidence](../evidence/postgres-p3f/README.md), and retain the existing
SQLite [Web Inventory network regression](testing.md).
