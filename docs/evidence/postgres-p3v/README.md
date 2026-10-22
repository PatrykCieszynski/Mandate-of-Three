# P3v — controlled sequential World replacement

Date: 2026-10-20. Windows, Godot 4.7.2, godot-soci 0.4.3, PostgreSQL 18.6,
Python 3.13 and Node 24.19. Disposable owned cluster, random loopback ports,
private stores and generated fixture credentials; no player data or installed
PostgreSQL service. No visible test/game windows.

| Check | Result | Ignored local evidence |
| --- | --- | --- |
| Two real process replacement cycles under live Master/Gateway | PASS | `.godot/verification/postgres-readiness/run-0zw6jmuo/` |
| Existing full realm maintenance, including native blocked SQL refusal | PASS | `.godot/verification/postgres-readiness/run-g137b9vf/` |
| Account/Gateway lifecycle, menu logout, World admission and Master entry ordering | PASS | `.godot/verification/{account_identity,gateway_lifecycle,gateway_menu_lifecycle,world_session_admission,master_entry_attempts}.log` |
| Added delayed grant and post-ticket handoff drain cases | PASS | `.godot/verification/master-entry-drain.log` and final `master_entry_attempts.log` |
| Smoke / architecture guards / 14 Godot suites / 88 Web contracts | PASS | `.godot/verification/*.smoke.log` and Web runner output |
| Python AST / diff checks | PASS | Local invocation |

## Observable guarantees

The existing ordinary process fixture creates an account/character, verifies
foreign identity refusal/recovery, equips and relogs. Before each replacement,
an actual held client receives fixture-only +37 dirty grinding Yang and +41 XP
through the production runtime APIs. The fixture holds an active wallet-table
lock, then calls the real authenticated dashboard World-shutdown route.

Master removes the World from public routing before SQL can finish. Status shows
the World draining/not ready while Master remains READY, and both old World and
Master processes are still alive. After lock release, World drains the money,
disconnects the client, writes the captured latest profile and exits. Exact Yang
and progression fields match the accepted RAM updates. Native inspection sees
only Master's one control worker; the account's previous grant becomes revoked.

Only after confirmed old-process exit does the fixture start a replacement on
the same World port/store configuration, with the same running Master/Gateway.
An actual WebSocket probe presents the prior **consumed** ticket and is rejected.
Normal Gateway login/enter obtains new authority and the client observes the same
two items/equipped UID. This is not claimed as a new unused-ticket acceptance
case; the independent session suite retains unused/replay coverage. The
replacement closes through the same real dashboard route. Two full cycles run,
including normal full-server restart between them. Copied replacement logs as
well as parent/normal client/server logs are checked for parse/script errors.

The real Master RPC ordering suite additionally holds grant completion, marks
the target World draining and verifies that a late grant success issues no
ticket. It separately closes readiness after World received a ticket but before
the existing delayed client handoff: the Gateway response must be an error.
Existing concrete closure-owner profile-failure/retry tests remain in the reused
maintenance fixture; native profile-write fault injection was not added here.
The new endpoint retains that same concrete owner across retries.

## Verification boundaries and failed attempts

The opt-in SQLite `run-account-identity.ps1 -WithSession` was attempted without
its separately configured local servers. It failed its first HTTP transport
assertion and is **not** counted as a passed SQLite production-session run. No
successful account-creation response was observed. The documented isolated five-suite
runner was then used successfully; normal three-process PG identity/login is
covered by the new native fixture. No real-data SQLite servers were started to
make an inappropriate test environment appear green.

An initial replacement fixture used a nonexistent probe close method; it failed
and its owned cluster/processes were stopped. The corrected native path closes
the actual peer/API. Existing Godot resource teardown warnings are not contract
success evidence; exit codes, explicit markers and absence of script/parse errors
are required. All owned clusters from these runs are stopped.

No capacity/latency benchmark, sustained soak, SQLite economy import, production
cutover, Linux/physical CEF or cross-host/concurrent-World handoff claim. SQLite
remains default. Supervisor-confirmed old-process exit is a precondition: no
distributed ownership lease or automatic failover was introduced. See the
[operator procedure](../../development/postgres-world-replacement.md) and current
[remaining migration gates (historical)](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/88b448a4fcf2476e43a7cce504df4987e5371d2b/docs/plans/postgresql-migration.md#remaining-gates).
