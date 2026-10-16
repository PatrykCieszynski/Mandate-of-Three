# P1b wallet parity — Windows evidence

2026-10-16, Godot 4.7.2, unchanged pinned godot-soci v0.4.1
(`b43e37e97b0c2321c678ab81809085f1863003ba`), installed PostgreSQL 18.6 binaries
from `Y:/Software/PostgreSQL/bin`. Fresh owned clusters only; no installed data
directory, player database or Windows service was used or modified.

| Check | Result |
| --- | --- |
| Native wallet operations vs migrated SQLite snapshots | PASS, repeated fresh runs |
| Multi-account checkpoint, pending-income spend/credit, reservations, rollback, cap, revisions, reconnect | PASS |
| Original SOCI/readiness fixture with installed PG binaries | PASS |
| Default smoke | PASS: 13 Godot cases / 85 Web tests |
| Python AST / git diff --check | PASS |
| Minimal deferred COMMIT error, native session only | **FAIL: native process exit 3765269347 / 0xE06D7363** |
| Owned cluster shutdown after passing and crashing probes | PASS |
| Linux, multi-connection economic races, response-loss recovery, World latency | NOT VERIFIED |

Commands, ownership rules and scope are in
[wallet parity](../../development/postgres-wallet-parity.md). The failure is a
real failed gate, not an expected-pass assertion or a green adoption result.

The native-only probe emits:

```text
POSTGRES_COMMIT_FAILURE_BEFORE_NATIVE_COMMIT
```

It does not reach `POSTGRES_COMMIT_FAILURE_NATIVE_RETURNED`. PostgreSQL logs the
fixture's deferred exception, and the Windows process exits inside the native
COMMIT call. The runner records `result: FAIL, stopped: true` and removes its
stopped cluster. A prior wallet-level deferred-error probe exited the same way;
the minimal fixture isolates the dependency path from all wallet/SQLite code.

The ordinary fixtures emit the existing intentional SQL-fault diagnostics and
project ObjectDB/resource teardown warnings. Successful runs have no SCRIPT ERROR.
Local user-owned combat resource UID warnings are unrelated to this database-only
failure; the minimal reproducer uses no combat or wallet operations. No raw logs,
connection strings, generated passwords, native payloads or fixture databases are
committed. No dependency pin/binary is patched to hide the failure.
