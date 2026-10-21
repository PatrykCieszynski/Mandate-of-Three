# PostgreSQL bootstrap ownership — P3r

**Current adoption:** normal configs also use PostgreSQL profiles and Master
credentials. See [full-state setup](postgres-full-state.md). The hybrid/file
details below describe the retained compatibility fixture rather than defaults.

P3r supplies one explicit bootstrap API for the optional Master and World Economy
owners. The ten-client acceptance fixture now uses it instead of manually creating
seven pools and wiring individual domains. P3r itself did not select a process
backend. [P3s process startup](postgres-process-startup.md) now supplies that opt-in
configuration and trusted identity integration. SQLite remains the default;
neither milestone approves a production cutover.

## Complete startup guarantee

`economy_bootstrap_postgres.gd` owns preflight, native pools, composition and drain.
Call `start_master(master, settings)` before registering Worlds, or
`start_world(world, settings)` before admitting players/creating map endpoints.
The nodes must remain in the scene tree until startup or shutdown completes.
The caller retains the owner; it is also attached to the node as `economy_bootstrap`.

The descriptor is server-only:

```gdscript
var settings := {
    "backend": "postgresql",
    "connection_env": "MANDATE_ECONOMY_CONNECTION",
    "authority_id": "<32 lowercase hexadecimal characters from provisioning>",
    "queue_capacity": 2,
}
var owner := preload("res://source/server/world/database/postgres/economy_bootstrap_postgres.gd").new()
var started: bool = await owner.start_world(world, settings)
```

The settings resolver defaults to `sqlite` when no backend is selected. A PG
descriptor requires a named nonempty environment variable, expected authority ID
and per-worker capacity 1–4. It never retains or reports the connection string in
status or `world_info`. Connection timeout is set to three seconds; native DNS/OS
or running SQL are never force-joined by a frame timeout.

Startup first opens a bounded native pool and verifies the expected authority and
all twelve required feature versions in one read-only transaction. It does not
execute migrations or silently accept a different realm. Only after preflight
and every remaining pool is ready does World receive Inventory/initialization,
wallet, NPC, Storage, ground-item and complete Marketplace/Exchange/Auction owners.
An initialized, matching SQLite profile store must already be attached. Master
receives its delegated-session issuer only after the same realm preflight passes.

World uses eight native sessions: Inventory 2, wallet 1, NPC 1, Storage 1, ground 1,
Marketplace 2. Master uses one separate control session. Database connection
limits must also allow operator/fixture sessions and PostgreSQL reserved slots.
These are the existing executor/owner boundaries, not a new pool framework.

Startup refuses a populated/attached runtime, active players or dirty SQLite wallet
state. Once an empty runtime explicitly selects PG, failure is sticky: admissions
and SQLite economic fallback remain disabled. All partially opened native pools
finish/close before the failed start returns. `status()` reports only state, error,
pool/worker counts and stop completion. A dead executor after startup changes the
owner to `BLOCKED` and closes admissions; it does not reopen SQLite or hot-restart
an uncertain transaction.

## SQLite profile boundary

The profile store and soft progression remain SQLite. The facade and Mandate
adapter block legacy item/wallet/Marketplace operations after PG selection, even
before PG owners exist or after they stop. Legacy RAM wallet snapshots are cleared
only after the dirty-wallet precondition passes. New profile initialization no
longer creates legacy gold/potions or a SQLite Yang wallet in this mode. Profile
creation and the narrow progression checkpoint still work; this does not make
the new profile a provisioned PG character.

Existing SQLite economic rows are preserved, not copied or made authoritative.
The bootstrap does not migrate player data, generate realm-global character IDs,
bind the Master identity manifest or reconcile an existing SQLite economy with PG.
The ten-client fixture explicitly seeds its trusted identities and PG mappings.
Direct raw SQLite references remain server internals; this facade/adapter boundary
is not an OS-level read-only database connection or a database trigger policy.

## Offline provisioning

Create the target database/role separately. With the server stopped and the
connection stored in an environment variable, run:

```powershell
$env:MANDATE_PG_PROVISION = '1'
# Set MANDATE_ECONOMY_CONNECTION securely for this shell; do not commit it.
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=world-server --script res://tools/postgres/provision_economy.gd
Remove-Item Env:MANDATE_PG_PROVISION
```

The command invokes existing feature migrations, prints the nonsecret authority
ID and closes its session. It does not create a database/role, import data, start
servers or change the default backend. Provisioning is idempotent per feature;
it is not one transaction across all features. Inspect a failed partial run before
retrying. Runtime preflight still refuses an incomplete/incompatible schema.

## Shutdown and recovery

Stop World before Master. `await world_owner.shutdown_world()` closes new tickets,
authentication and Inventory submissions, and asks the existing domain owners to
drain. Current delivery contexts remain usable for read-only receipt recovery and
committed-state reconciliation. Only after captured pending income/outcomes settle
does it detach sessions and close the Inventory pool. A lost successful settlement
must be discovered, not discarded or executed again. No active native SQL is joined
or forcibly cancelled.

An unresolved barrier returns `false` / `BLOCKED`, retaining owners and diagnostics
for explicit recovery. It does not authorize killing the process or losing pending
money. The existing domain receipt/retry APIs remain the recovery boundary; this
package does not add automatic worker replacement or recovery after control-plane
loss. `await master_owner.shutdown_master()` revokes current ticket markers, drains
issuer revocations and only then closes the control pool. Failed revocation likewise
blocks completion. Profile save/backup/close remains the profile connection owner's
separate responsibility; this is not a PostgreSQL backup implementation.

## Verification and next integration

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite bootstrap
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-session-bridge
& ./tests/run-web-inventory.ps1 -Scene market_network
& ./tests/run-smoke.ps1
```

Owned disposable fixtures cover refusal, partial native connection exhaustion,
offline provisioning, profile/XP writes with no SQLite starter wallet, uncertain
settlement during shutdown and the ten actual-client economic flows. Run shared
18098/18099 network suites sequentially. See [evidence](../evidence/postgres-p3r/README.md).

The subsequent [P3s integration](postgres-process-startup.md) supplies normal
startup/configuration, trusted identity/creation-manifest integration and readiness
publication using this owner, including Gateway → Master → World → PG entry/equip/
relog/restart acceptance. Operator health/backup, handoff, broader gameplay/load/
soak/import/restore and explicit cutover approval remain open.
This does not enable multi-World hosting, remove profile SQLite, verify physical
CEF input or claim Linux acceptance.
