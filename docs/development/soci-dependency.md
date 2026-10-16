# Active SOCI dependency

Mandate pins the official godot-soci **v0.4.2** prerelease, commit
`222cfec77acbdb15fa7cd6f6c97d7064126a947a`. The release archive and every payload
file are pinned in `tools/soci/release.json`. Native payloads remain ignored.

```powershell
python tools/soci/setup.py
python tools/soci/setup.py --check
```

Source: [official v0.4.2 release](https://github.com/PatrykCieszynski/godot-soci/releases/tag/v0.4.2).
ZIP SHA-256:
`f597edbb6aae906de676dc50d98a625d0f8c9ba209a5d178a4eab83debc291e4`.

The update fixes the Windows MSVC exception-ABI mismatch exposed by a deferred
PostgreSQL COMMIT failure in v0.4.1. The installed official payload passes the
native-only failure/rollback fixture and wallet-level conservative unknown-outcome
handling, session close and reconciliation after reconnect. No raw COMMIT SQL,
locally rebuilt addon or C++ patch is installed in Mandate.

Adoption verification uses PostgreSQL 18.6 binaries from
`Y:/Software/PostgreSQL/bin` with fresh owned SCRAM loopback clusters only. The
installed service/data are not used. The current runtime remains a single World
and SQLite; PostgreSQL wallet parity is opt-in. This does not add a pool, runtime
backend selector or distributed Economy.

Verification commands:

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite commit-failure
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite wallet
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
original payloads and are not relabeled as v0.4.2 measurements.
