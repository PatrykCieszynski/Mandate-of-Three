# Stopped-writer realm backup and restore — P3u

The opt-in single-World PostgreSQL realm has three persistent parts: the
`economy` schema, the World SQLite profile/progression database (including its
`pg_profile_id`), and Master's account collection. Back up and restore them as
one set. SQLite remains the default backend; this is not a production cutover,
SQLite economy import, live backup or distributed maintenance lease.

## Stop and capture

1. Use the [maintenance barrier](postgres-maintenance.md). Require `QUIESCED`,
   not merely HTTP `ok`. `BLOCKED` is a refusal: resolve the retained operation
   before terminating anything. A historical status response is not proof that
   the current processes are stopped.
2. Disable supervisor/automatic restart and operator writes. Stop the supervised
   World, Gateway and Master (World before Master). Verify their exit. Keep all
   other writers and SQL clients out for the entire operation. The tool never
   kills another process, terminates SQL, revokes grants or forces a checkpoint.
3. Supply libpq environment or a private `PGPASSFILE`. Use a plain database name
   in `PGDATABASE`, not a DSN; no credentials go on argv or in the bundle manifest.
   The role must own/read the economy objects and see database sessions. Protect
   credentials, bundle directory and output using deployment ACLs.
4. Run the following with **new** destination paths whose parents already exist:

```powershell
$env:PGHOST = '127.0.0.1'
$env:PGPORT = '5432'
$env:PGUSER = 'mandate'
$env:PGDATABASE = 'mandate_realm'
$env:PGPASSFILE = 'N:/private/mandate.pgpass'
python tools/postgres/realm_backup.py backup --pg-bin Y:/Software/PostgreSQL/bin --profiles N:/private/realm/profiles.db --accounts N:/private/realm/accounts.tres --bundle N:/private/backups/realm-new --writers-stopped
```

`--writers-stopped` is an explicit operator precondition, not an inferred
certificate. There is no cross-host supervisor integration. The tool refuses
other database sessions before capture and checks again before completion;
SHARE locks on all existing economy tables prevent DML during capture. A bounded
lock failure refuses capture rather than disrupting a running worker. PostgreSQL
stays running. These locks do not stop a privileged administrator changing
sequences/schema or an independently restarted Master writing its account file.
Prevent those writers operationally; do not use this as a live backup API.

The SQLite connection holds an exclusive write transaction while serializing
the complete committed image, including committed WAL. It does not copy an
unchecked `.db` or discard its WAL. The source is not modified by gameplay SQL.
The account-file SHA-256 must stay unchanged throughout capture.

The bundle contains:

- `economy.dump`: custom-format `pg_dump`, economy schema only, no role ownership
  or grants. Other application schemas, PostgreSQL roles/passwords and deployment
  configuration are outside this bundle.
- `profiles.db` and `accounts.tres`: actual persistent data, **sensitive**, not
  anonymized fixtures or safe-to-publish evidence.
- `manifest.json`: written only after capture checks pass; SHA-256 of each file,
  authority/profile IDs, schema versions, per-table row counts/content digests,
  sequence values, source commit, SOCI tag and dump tool version. No DSN/password.

Validation checks SQLite integrity and absence of legacy economic rows, matching
realm/profile IDs, every profile account/character mapping against Master/PG,
revoked session grants, no pending Inventory intents, item custody and Exchange
reservation totals. Extra PG identities without a profile are permitted (the
existing convergence/identity contract); this is not orphan cleanup. Existing
domain suites remain responsible for complete placement/trading invariants.
Every economy table's rows are fingerprinted, including receipts, revisions,
offers, ledger, custody and reservations. Fingerprints are an offline consistency
audit, not a new runtime read path or an authenticity signature.

## Restore into a separate environment

Only restore a trusted immutable bundle: PostgreSQL archives and Godot resources
can contain executable input. Hashes detect accidental damage; they do not make
an attacker-controlled manifest trustworthy. Keep a private verified copy and
use the matching application/native versions first.

Create a **new empty database** with the deployment role outside this tool.
Never point this at the source or an active target. Provision target role/access
and supervisor configuration separately; this tool does not create roles,
rewrite server configs, start processes or enable admissions.

```powershell
$env:PGDATABASE = 'mandate_realm_restored'
python tools/postgres/realm_backup.py restore --pg-bin Y:/Software/PostgreSQL/bin --bundle N:/private/backups/realm-new --output N:/private/restored/realm-new --writers-stopped
```

Restore verifies file hashes **before SQL**, refuses a nonempty target or an
existing output directory, and uses `pg_restore --single-transaction
--exit-on-error --no-owner --no-privileges`. It never uses `--clean`, drops the
source, overwrites target data, replays economic mutations or creates new IDs.
It copies profiles/accounts and repeats the complete audit, requiring equality
with the captured table/sequence/identity evidence before writing
`RESTORE_VERIFIED.json`. Grants remain revoked; normal startup/login obtains new
authority rather than reusing old connection tickets.

After verification, configure a separate Master/World to use the restored PG DB,
the restored profile file and restored account collection, with the recorded
authority ID. Verify normal startup/manifest and a login, UID/equipment, balances
and progression before considering an operator-approved replacement. Keep the
original environment stopped; never operate both copies as authorities for one
realm. Subsequent accepted writes make reverting to the older set a separate
reconciliation decision, not a backend-toggle operation.

Failure produces no verified marker. A restore can leave a restored database
with incomplete filesystem output if copying/audit fails after SQL COMMIT.
Preserve it privately, do not admit players, diagnose the cause and retry into
another new empty DB/directory. An interrupted command is not proof of rollback;
the tool does not blindly rerun against populated state. Partial backups likewise
have no complete manifest and must not be used. No automatic recursive cleanup.

## Verification and limits

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite backup
```

The owned disposable fixture runs real Gateway/Master/World/client startup and
the HTTP maintenance barrier, stops the processes, captures committed SQLite WAL,
nonempty revenue/reservations/fills and receipt/UID state, restores into another
database and file set, then boots normal processes and logs in again. It rejects
active sessions/grants, mismatched profile/account files, corrupted dumps,
existing destinations and populated databases. A second dirty Yang/XP checkpoint
uses the restored stores. [Evidence](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/37827015b8536a5b7862cb092d86a7da79dcf988/docs/evidence/postgres-p3u/README.md).

Tested: Windows, Python 3.13, PostgreSQL 18.6, Godot 4.7.2, godot-soci 0.4.3.
Linux/physical CEF NOT VERIFIED. Python must provide SQLite `Connection.serialize`.
Serialization and sorted per-table audit aggregation use memory proportional to
data size; large production-scale restore timing/memory and off-host backup
retention/encryption remain an operational acceptance task. P4 load/soak, import,
cutover and multi-World/handoff are not implied by this successful rehearsal.
