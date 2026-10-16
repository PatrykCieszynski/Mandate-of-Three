# PostgreSQL P1b — account wallet parity

Status: opt-in backend port candidate; **not connected to World runtime**. The game
still uses SQLite. Core wallet parity passes, but a native COMMIT-error crash is a
blocking driver finding, so this package is not approved for runtime use. It is
not full P1 Item/Shop/Storage/Upgrade/Exchange parity or the later executor gates.

## Ownership and schema

`source/server/world/database/postgres/` contains a PostgreSQL-specific schema
bootstrap and wallet store. There is no generic database interface or SQLite SQL
translation. All statements use the pinned native godot-soci v0.4.1 API.

The isolated `economy` namespace starts with trusted Master account IDs, a stable
authority identity and account wallets. It does not copy passwords, create login
accounts, port legacy player profiles or automatically ingest World data. A trusted
server bootstrap may initialize an account once; creating another character must
reuse its Master account ID and cannot repeat the 1500-Yang starter grant. The
fixture derives IDs from the existing SQLite identity flow, including an alt.
Production identity hydration/mapping and actual data migration remain pending.

Wallet balances, reservations and revisions use BIGINT. Checks enforce the current
9,000,000,000,000,000 Yang cap and `0 <= reserved_yang <= yang`. A PostgreSQL BEFORE
UPDATE trigger advances the revision only when balance/reservations change. A zero
delta does not manufacture a revision. This replaces SQLite's recursive AFTER
UPDATE mechanism while preserving observed snapshot values. Bootstrap is an
explicit transaction, safe to repeat on the supported version, and rejects an
unknown future wallet version. Run migrations under one offline migration owner;
parallel schema bootstraps are not an accepted deployment procedure.

## Transaction contract

- Checkpoint writes account **deltas**, all in one transaction. A failure on any
  account restores every balance and revision in that batch.
- Critical spend applies pending income and debits unreserved funds atomically.
  Credit applies pending income and the separate critical credit atomically.
- The `_in_transaction` primitives require an already active transaction on the
  same supplied SOCI session. A future Shop/Upgrade caller must include its item
  and receipt writes in that same transaction. No COMMIT is hidden in a primitive.
- Standalone operations refuse to take over an existing caller transaction.
- If native COMMIT returns failure, the store returns `outcome_unknown` and closes
  the session. The pinned Windows binary currently crashes first in the isolated
  deferred-error reproducer below; this containment path is not runtime-validated.
  Never infer
  failure or blindly resubmit the spend/delta. This store does **not** implement
  durable command receipts or grinding-batch deduplication; outcome discovery and
  fencing must be added before remote/runtime use.

The store is synchronous. One caller/thread must create/open/use/close its native
session and own the entire read/validate/write/commit operation. This P1 fixture
does not authorize blocking World simulation on PostgreSQL, distributing a
transaction across async dispatchers, or claiming P2 race correctness/P3 pooling.
There is no cache reconciliation or client publication in this opt-in store.

## Running the contract fixture

Use installed binaries, with no dependency on an installed service or its data:

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite wallet
```

Alternatively omit `--pg-bin` after installing the pinned portable release with
`python tools/postgres/setup.py`. The runner always initializes its own fresh
cluster with SCRAM, generated credentials, a random loopback port, a non-superuser
probe role and timeouts. It never opens `Y:/Software/PostgreSQL/data`, stops an
installed service or accepts an external DSN. The stopped cluster is removed;
logs remain below `.godot/verification/postgres-readiness/`.

`tests/postgres_wallet.gd` runs the same store operations against a fresh migrated
SQLite fixture and the actual PostgreSQL driver. It compares durable snapshots
(excluding each backend's independent authority ID), including:

- account/alt scope and no repeated initialization grant;
- multi-account delta checkpoint and preservation of an independently added delta;
- 40,000 + pending 30,000 - spend 50,000 = 20,000 in one transaction;
- injected failure after income/before debit, and later caller failure after spend;
- credit rollback and commit, reserved-funds guard, zero-delta revisions;
- full checkpoint rollback on a later cap/unknown-account error;
- exact cap and balance/reservation/revision persistence after reconnect;
- repeated schema bootstrap and rejection of a future schema version.

## Blocking driver finding: failed native COMMIT

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite commit-failure
```

On Windows / PostgreSQL 18.6 / pinned SOCI v0.4.1, this **fails** with process exit
`3765269347` (`0xE06D7363`, native C++ exception). The runner still stops/removes
its owned cluster. The native-only fixture creates one table, one deferred
constraint trigger raising an exception, begins a transaction and updates one row.
The SQL update succeeds. Godot prints `BEFORE_NATIVE_COMMIT`, then exits inside
`db.commit()` without printing `NATIVE_RETURNED`. No wallet, SQLite or World code
participates in the reproducer.

The pinned [native transaction implementation](https://github.com/PatrykCieszynski/godot-soci/blob/b43e37e97b0c2321c678ab81809085f1863003ba/src/database.cpp)
catches only `std::exception` in `commit()` (and other lifecycle methods), while
`execute()` also has a catch-all. That is consistent with the observed exception
escaping the native boundary; the precise exception/ABI cause still needs native
debugging. A driver fix must contain errors at the Godot ABI and preserve honest
transaction/outcome state. Retest this reproducer, rollback/close and actual
connection-loss cases before adopting the backend.

No native binary, dependency pin or addon code is changed here. There is no raw
`execute("COMMIT")` workaround bypassing SOCI's transaction flag, and this failing
suite is not reported as an expected success. Core parity and this failure gate
are separate explicit commands so the successful scenarios remain inspectable.

The existing `yang_wallet` smoke remains responsible for authoritative RAM,
30-second dirty batching, disconnect/relog and shutdown behavior on the current
SQLite runtime. The new fixture is opt-in; default smoke/CI gains no PostgreSQL
dependency. Network response-loss/restart recovery, multi-connection races, real
load/soak and Linux behavior remain separate, unverified gates.
