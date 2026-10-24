# All-PostgreSQL development cutover

On 2026-10-21 the owner approved a **clean start**: no import of the old test
SQLite databases or Master resource. Import is no longer a gate for this local
cutover. This does not authorize discarding future real-player data.

Normal Master/World configs select `backend="postgresql"`, `realm_state=true`.
No automatic SQLite fallback exists. Configs without an Economy section retain
the explicit embedded fixture behavior through godot-soci; the retired
godot-sqlite addon is not a supported dependency.

| Owner | PostgreSQL state |
| --- | --- |
| Master | `realm.accounts`: sequence-assigned IDs, salted password hashes, last World/character |
| World | `realm.players`: sequence-assigned IDs, profile/social data, level/XP/attribute points |
| Retired tables (no active services) | Existing guild, mail and persistent chat tables remain on disk; no runtime stores or RPCs |
| Existing Economy owners | `economy.*`: UIDs, custody, equipment, wallets, Storage, shops, Exchange, grants, intents and receipts |

Profile upserts cannot change the account owning an existing character. The pure
profile decoder is shared with the SQLite reference store; SQL/access remain
separate. This introduces no generic database interface or ORM. Combat still
reads RAM. Stats V1 requires the additive `character_stats=1` schema feature; rerun the
existing offline provisioning command before deploying build 0.33.0. Old six-stat
allocations are refunded on decode and atomically persisted with the version;
see [character progression](../gameplay/character-xp.md).
XP checkpoints update only the narrow progression/attribute fields in one
transaction; failure rolls back the batch and retains dirty references. Existing
Yang checkpoint and immediate economic transaction policies are preserved.
The legacy admin resource-renaming action is rejected for PG accounts; changing
an authenticated handle needs its own session/profile migration flow.

Social profile mutations check BEGIN, each write and COMMIT. Failed writes restore
the affected live resources in place; block-cache changes follow confirmed commit.
A failed SQL statement taints the transaction, so COMMIT cannot report success
merely because PostgreSQL accepted it as rollback of an aborted transaction.

Guilds, mailbox grants and the old persistent chat services have been retired.
No SQL tables or saved data are dropped. The profile codec copies retired JSON and
guild-ID columns verbatim in `retired_profile_fields`; these values grant no live
inventory, currency or membership. Current ItemInstances/Wallet stay authoritative.

COMMIT failure returns `outcome_unknown`, marks the result non-retryable and
closes/blocks the profile writer. There is no automatic reconnect or replay.
Restored pre-command RAM is not proof of a database rollback: a replacement
owner must load committed state from PG before resuming this profile's writes.
There is no in-process recovery of an uncertain profile writer. Do not force a stale full-profile checkpoint during
operator recovery.

This port preserves the existing profile payload. It does **not** introduce
persistent 3D position/instance restoration or change the current map spawn flow.
Assets, configuration and local client preferences remain files.

## Local startup

```powershell
python tools/postgres/dev_realm.py --pg-bin Y:/Software/PostgreSQL/bin
.\tools\servers.ps1 -Action start -Target all
```

The server helper runs the first command automatically. It owns a durable
loopback-only cluster at `.godot/runtime/postgres-local/data`, port 55432,
without touching an installed PostgreSQL service. Repeated starts preserve it;
there is no reset/drop action or automatic import. Use `-PgBin` to override the
binary location in `servers.ps1`.

Generated credentials live in ignored `connection.json`. The launcher supplies
`MANDATE_ECONOMY_CONNECTION` and `MANDATE_ECONOMY_AUTHORITY_ID` to the servers;
credentials do not appear on process arguments or public World metadata.
TCP and local-socket authentication use SCRAM. Treat runtime files/logs/backups
as private. The archive contains password hashes.

For managed deployment, offline provisioning uses
`tools/postgres/provision_economy.gd`, `MANDATE_PG_PROVISION=1` and the connection
environment variable. Both processes receive the same provisioned authority.
Runtime verifies the schema, without provisioning or falling back after failure.

## Backup/restore

Drain and stop supervised Master/World processes and all DB sessions first.
World periodic saves are **checkpoints**, not PostgreSQL backups. Using libpq
environment settings (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSFILE`):

```powershell
python tools/postgres/realm_backup.py backup --full-state --writers-stopped --pg-bin Y:/Software/PostgreSQL/bin --bundle <new-private-directory>
python tools/postgres/realm_backup.py restore --full-state --writers-stopped --pg-bin Y:/Software/PostgreSQL/bin --bundle <verified-bundle> --output <new-verification-directory>
```

Restore requires an **empty, separately created database** selected by
`PGDATABASE`. It never drops/overwrites the source. Format 2 captures `economy`
and `realm`, including sequences, in one custom archive. Checksums, exact table
and sequence fingerprints, identity, custody, reservations and pending work are
audited. Other sessions, live grants, tampered/incomplete bundles and populated
targets are rejected. Format 1 remains for the old hybrid reference fixtures.

## Verification and limits

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite full-state
```

This uses an owned disposable cluster and real Gateway/Master/World/client
processes: creation, stale mapping denial, grant, equip, relog, XP checkpoint,
drain, all-state backup/restore into another DB, then normal login after restart.
It asserts no normal `profiles.db`/`accounts.tres` is created. Focused contracts
cover hashes/IDs/reopen, profile ownership, batch rollback, retired-payload preservation and social transaction failures.

The fixture permits 16 DB connections (previous composition: 14), for the two
new credential/profile sessions. Economic worker/queue/session limits are
unchanged. The local cluster permits 32 connections including operator/reserved
capacity; this is not a player limit.

Profile/account APIs remain synchronous outside the combat/economy worker path,
with 3-second statement and 1-second lock budgets. They remain a World-tick risk
under profile/login bursts; previous Economy soaks do not measure this new
boundary. Do not claim fully asynchronous persistence or complete MMO capacity.
Overlapping World owners, production backup sizing, Linux and physical CEF
testing remain separate scopes.

See [evidence](../evidence/postgres-full-cutover/README.md),
[migration history](../history/postgresql-migration.md) and
[persistence policy](../architecture/persistence-policy.md).
