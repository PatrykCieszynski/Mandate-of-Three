# Active SOCI dependency

Mandate pins the official godot-soci **v0.4.4** prerelease, commit
`e1128e3ebcbe5a5662714d268b1f89b165ac8fc8`. The release archive and every payload
file are pinned in `tools/soci/release.json`. Native payloads remain ignored.

```powershell
python tools/soci/setup.py
python tools/soci/setup.py --check
```

Source: [official v0.4.4 release](https://github.com/PatrykCieszynski/godot-soci/releases/tag/v0.4.4).
ZIP SHA-256:
`802d66fdef048d0a82c480f5881f21d48d7c753047933362e4113ba0f037e2ea`.

v0.4.2 fixed the Windows MSVC exception-ABI mismatch exposed by deferred COMMIT
failure in v0.4.1. v0.4.3 adds synchronous structured errors (`error_backend`,
category, backend code, SQLSTATE), sharing async naming. The installed official
payload passes failure/rollback and conservative COMMIT-unknown/reconnect checks.
The expanded native probe distinguishes a local transaction flag from PostgreSQL
state and verifies that accepted COMMIT on an aborted transaction can mean rollback.
v0.4.4 fixes SQLite runtime result types in both synchronous and asynchronous queries,
including signed int64 and aggregates, without treating numeric TEXT as a number.
This is required by the retained embedded fixtures. No raw COMMIT SQL, locally
rebuilt addon or C++ patch is installed in Mandate.

Only PostgreSQL Shop purchase/collect opt into bounded whole-use-case retry after
confirmed statement-failure rollback. See [P2c policy and verification](postgres-transaction-retry.md).
Other stores, unreceipted checkpoint deltas, runtime execution and outcome recovery
are not automatically retried by this dependency update.

Adoption verification uses PostgreSQL 18.6 binaries from
`Y:/Software/PostgreSQL/bin` with fresh owned SCRAM loopback clusters only. The
installed service/data are not used. Normal development uses Gateway/Master/one World with PostgreSQL accounts,
profiles and Economy. Focused embedded SQLite fixtures use the same SOCI driver,
not a separate godot-sqlite addon. This does not add a pool or distributed Economy.

Verification commands:

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite commit-failure
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite wallet
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite shop-settlement
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin'
./tests/run-smoke.ps1
./tests/run-market.ps1 -Scene auction_queries -Marker AUCTION_QUERIES_OK
./tests/run-market-recovery.ps1
python tests/run-auction-load.py --godot '.godot/Godot_v4.7.2-stable_win64_console.exe'
```

Prepare `.godot/verification/auction-d1b` and isolated APPDATA/LOCALAPPDATA under
verification before the `auction_queries` case: its SQLite fixture and `user://`
backups must be writable. All network fixtures sharing port 18098 run sequentially.
The auction load report now reads the dependency pin instead of hardcoding 0.4.1.
It still reports worker round-trip, not native SQL timing; the new native metrics
API is not adopted by this dependency update.

Windows verification does not establish Linux runtime behavior or PostgreSQL
economic concurrency correctness. Earlier S0/P0/D1/D2 reports describe their
original payloads and are not relabeled as v0.4.3 measurements. The exact focused
adoption run set is recorded in [P2c evidence](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/37827015b8536a5b7862cb092d86a7da79dcf988/docs/evidence/postgres-p2c/README.md);
the optional Auction load command above does not imply a new capacity benchmark.
