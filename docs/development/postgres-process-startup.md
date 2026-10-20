# Opt-in PostgreSQL process startup — P3s

Normal Master and World scenes can now select the shared P3r bootstrap. SQLite
remains the default. This is an explicit single-World development deployment,
not a production cutover, a SQLite economy import or multi-World admission.

## Configuration

Provision the empty target realm offline as described in
[bootstrap ownership](postgres-bootstrap.md). Keep connection credentials in an
environment variable inherited by **both** server processes, never in a checked-in
config or `world_info`. Append this section to private Master and World configs:

```ini
[economy]
backend="postgresql"
connection_env="MANDATE_ECONOMY_CONNECTION"
authority_id="<32 lowercase hex characters printed by provisioning>"
queue_capacity=2
```

Only the **World** also requires `profile_path` in that section:

```ini
profile_path="user://pg-development/profiles.db"
```

Use a separate profile file. An empty/missing path or a file containing SQLite
wallet/item rows is refused. Existing rows are never imported or erased. The
legacy profile schema still creates an empty item table; it is not an economic
write target. Player profiles and XP remain SQLite. Schema provisioning is still
an offline command; runtime preflight never upgrades an incompatible PG schema.

The profile file receives a persistent `pg_profile_id`. Normal World startup
idempotently binds that ID in the existing PG realm metadata before composing
runtime owners. Replacing the file with a freshly generated profile refuses
startup instead of reusing character IDs against an existing economy. Preserve
this file and its ID together with the realm; do not regenerate/delete the PG
binding to bypass a refusal. This is not a global character ID allocator.

Master account IDs remain owned by its account collection. Preserve that identity
source too. For an isolated deployment, a private Master config can explicitly
select its writable file:

```ini
[authentication]
account_collection_path="user://pg-development/accounts.tres"
```

Without that section, the existing editor/export account path is unchanged.
Start Master, Gateway and World with their usual role and private config:

```powershell
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=master-server --config=<master.cfg>
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=gateway-server --config=<gateway.cfg>
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=world-server --config=<world.cfg>
```

Each command runs its own process. Gateway now honours the existing
`[gateway-server] port/bind_address` fields, with unchanged loopback defaults.
Dashboard optionally accepts `--dashboard-config=<private-dashboard.cfg>` and
`[server] port` in that file; defaults remain unchanged. Neither path goes to
clients. These options allow independent disposable process fixtures.

## Readiness and trusted identity

Master completes PG preflight before listening for Worlds. It rejects a World
using another backend or authority and admits only one World/profile owner in
this milestone. The internal registration carries backend + authority, not DSNs
or profile paths. A PG World is absent from the public roster and entry handlers
until its trusted Master identity manifest has passed and it acknowledges readiness.

World audits existing profile account mappings against that manifest. Orphaned
or mismatched identities refuse readiness; unbound profile names can be bound
only to the corresponding verified Master ID. New accounts are bound by the
existing trusted Master character-creation request, not a client-supplied account.

Before a create/login result can issue a World ticket, the existing bounded
Inventory worker atomically inserts/verifies the PG account, starter wallet and
character mapping. Account admission is locked; an existing character is never
reassigned. Idempotent retries cannot reset a wallet or repeat starter Yang.
There is no new worker, per-action SQL on the main thread or schema migration.

Profile creation and PG identity binding are **not** a distributed transaction.
If the profile commit succeeds but PG fails or COMMIT is unknown, the server
returns no successful handoff. The profile stays visible in character selection.
Retry **entering that existing character** after recovery; the same immutable
mapping converges idempotently. Do not recreate/delete it or regard the error as
proof that its profile was rolled back. Foreign mapping conflicts need operator
investigation; the runtime never repairs ownership by overwriting it.

Master loss clears World wallet/readiness and admission state. Reconnection
requires a fresh manifest. Existing session-generation/epoch fences still decide
whether an asynchronous result may produce a current ticket. Backend failure,
unready manifest, shutdown or failed preflight never enables SQLite economics.

## Shutdown and boundaries

Stop World before Master. Normal World shutdown now calls the shared owner's
recovery/drain barrier, then saves/closes profile SQLite. An already stopped PG
owner does not enqueue a fresh wallet checkpoint from a later profile save.
Master's graceful window-close path drains grant revocations before exiting.
A blocked economic outcome still refuses completion. Headless signals are not a
guarantee of Godot notification delivery; use the existing authenticated World
shutdown RPC/dashboard path, and supervise Master separately after World stops.
P3s did not add an operator barrier. [P3t maintenance](postgres-maintenance.md)
now supplies authenticated, acknowledged realm quiescence; it still does not
implement PostgreSQL backup/restore or process supervision.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite process-startup
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite bootstrap
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-session-bridge
& ./tests/run-web-inventory.ps1 -Scene market_network
& ./tests/run-smoke.ps1
```

`process-startup` uses ordinary production role scenes in separate headless
processes, owned random loopback ports, private account/profile paths and a fresh
owned PG cluster. Its wrapper only requests orderly stop and records completion;
it does not replace identity RPCs, grant issuance, inventory or startup code.
The actual client creates an account/profile, is denied a deliberately foreign PG
mapping, then enters that same profile after disposable-fixture repair, equips,
relogs and reconnects after all three server processes restart. No fixture grant
or precreated client inventory is used. It checks wallet retry/mapping rollback,
profile-file binding and absence of SQLite economic rows. Child logs are checked
for script failures, and native pools drain before owned processes exit.

This is Windows/Godot 4.7.2/SOCI 0.4.3/PostgreSQL 18.6 acceptance. Linux, physical
CEF input, extended combat/load/soak, consistent PG/profile/account backup/restore,
controlled handoff, SQLite import rehearsal and P4 cutover approval remain open.
See [evidence](../evidence/postgres-p3s/README.md).
