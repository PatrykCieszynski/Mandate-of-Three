# P3t — operator maintenance barrier evidence

Date: 2026-10-20. Windows, Godot 4.7.2, pinned godot-soci 0.4.3,
PostgreSQL 18.6, Node 24.19. Owned disposable PG clusters, random loopback ports
and private profile/account files only; no installed service or player data used.

| Check | Result | Ignored local evidence |
| --- | --- | --- |
| Native maintenance / normal three-process startup, clients and restart | PASS | `.godot/verification/postgres-readiness/run-7xwk6kk2/` |
| Shared bootstrap and unknown-settlement recovery | PASS | `.godot/verification/postgres-readiness/run-fkbss70g/` |
| Account, Gateway lifecycle/menu, World admission, Master stale-attempt suites | PASS | `.godot/verification/{account_identity,gateway_lifecycle,gateway_menu_lifecycle,world_session_admission,master_entry_attempts}.log` |
| Default smoke / architecture guards / 14 Godot suites / 88 Web contracts | PASS | `.godot/verification/` |
| SQLite Marketplace server/two clients | PASS | `.godot/verification/market-network-test-*.out.log` |
| Python AST and diff checks | PASS | Local invocation |

## Native positive path

The existing process-startup acceptance is reused rather than replaced. Two
ordinary Master/Gateway/World lifecycles run on private ports; existing account
creation, foreign-mapping refusal, same-profile recovery, equip/relog and restart
checks remain. Each lifecycle additionally admits a real held client. Only the
fixture injects +37 dirty grinding Yang and +41 XP via the real runtime APIs;
SQL still shows the old balance before the operator request.

Actual HTTP routes reject missing credentials, close admissions, remove public
World availability and drive the reliable World-first RPC barrier. The client
is disconnected only after the real economic drain; profile XP/level/points and
Yang match the accepted RAM values afterward. All nine native workers are absent
from `pg_stat_activity` before success. Same-ID operator retries return the current
result, and another ID is refused. Account password mutation is blocked; the
frozen account-file hash is unchanged even through process tree exit. The next
normal-process startup reuses the preserved UID/equipment rather than resetting
items or wallet.

## Native blocked path

A third owned lifecycle retains a client and dirty income while an independent
controller holds an active `ACCESS EXCLUSIVE` wallet-table lock. Controller
keepalive prevents the fixture's idle-transaction guard from accidentally
releasing this lock. Worker lock/query budgets are unchanged.

World drain must return failure: `BLOCKED`, unsettled wallet RAM, actor/context
retained, no stopped-worker proof. Master grant workers remain READY; the account
barrier never runs ahead of World. After releasing the controller lock, SQL still
has the old balance. Retrying the operator ID reports BLOCKED; a new ID cannot
bypass it. There is no production force/discard/reopen API.

This deliberately failed disposable simulation alone is forcibly cleaned at the
end. The runner's `stopped: true` means its owned PG cluster was stopped and removed;
it does not mislabel the negative application run as a graceful shutdown. Positive
runs use normal owner drain and close before their wrappers exit. All relevant
role/client logs are checked for script/parse errors.

## Focused control faults

Injected control cases cover foreign/old/malformed/missing ACK, late ACK after
timeout, World loss and failed account save. They assert the observable phase,
closed admission and absence of premature Master drain. Empty-token dashboard
configuration cannot authorize new control routes. A failed latest-profile write
refuses closure and retains its resource after disconnect; a subsequent successful
recovery saves the final disconnected state. The existing SQL profile serializer
now returns its actual write result (and creation rolls back a failed insert).

Initial harness failures were corrected: JSON port numbers require integer URL
formatting, and an idle controller must not release a lock intended to remain
active. Those failed runs are not acceptance evidence.

## Boundaries

Status is RAM-only worker/domain observation with heartbeat age, not an idle
PG liveness query. No connection strings, paths, account inventories or raw jobs
are published. Maintenance correlation is process-local and explicitly cannot
serve as a durable backup certificate or distributed lease. SQLite remains the
default. Coherent stopped-writer PG/profile/Master-identity backup/restore, process
handoff, Linux, physical CEF, sustained load/soak/import and cutover remain open.
