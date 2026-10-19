# P3l — initialization and ground-item runtime evidence

2026-10-19, Windows, Godot 4.7.2, PostgreSQL 18.6 and pinned/hash-verified SOCI
v0.4.3. All PG runs used owned disposable loopback clusters and stopped them.
No real account/player database or installed PostgreSQL service was mutated.
Raw local logs remain under ignored `.godot/verification/postgres-readiness/<run>`.

| Acceptance | Run / command | Result |
| --- | --- | --- |
| New ground-item runtime | `run-xjdsepun` (also `run-kg9cb629`, `run-jph44w9l`) | PASS |
| Six actual native clients | `run-qp8fhabf` | PASS, server and all six markers |
| PG/SQLite inventory parity | `run-p9jv6lrp` | PASS |
| Independent-session inventory/init/claim concurrency | `run-vuu3ryy0` | PASS |
| Existing optional Inventory runtime | `run-i7jmxvky` | PASS |
| Existing combat/SQLite pickup | `tests/run-combat.ps1` | server + two clients PASS |
| Default smoke | `tests/run-smoke.ps1` | Architecture guards, 14 Godot contracts, 85 Web contracts PASS |
| Whitespace / dependency payload | `git diff --check`; runner SOCI check | PASS |

The new runtime fixture uses real native PG sessions and World combat cache,
with controlled peer maps/control availability and a small ground map. It covers:

- Lost successful initialization completion, closed readiness, explicit marker
  recovery and exactly one original starter kit; normal/replacement hydration.
- Bare legacy init/pickup denied for an account with a registered grant.
- Loot protection, distance, line of sight and dead actor rejection.
- One account waiting on SQL while another pickup and physics progress.
- In-flight drop protected from expiry; public drop single-flight competition.
- Native full-pool refusal releases reservation, writes nothing later, and permits
  explicit retry after capacity returns.
- Full bag preserves UID/rolled contents and no claim marker; free capacity then
  explicitly claim that same drop.
- Native deferred claim COMMIT failure atomically rolls back, read-only lookup
  confirms missing outcome, then explicit same-UID retry succeeds.
- Lost successful claim completion, alt takeover and original bag/quantity;
  same-account replay and other-account denial create no duplicate or replay fact.
- Graceful drain/join using the existing bounded owner pattern.

The existing endpoint fixture now runs actor, observer, restored, NPC-restored,
Storage-restored and ground-restored headless client processes with native
Master/World authentication. It retains prior Inventory/Yang/NPC/Storage contracts.
The production Combat pickup RPC checks reserved loot, commits four ore units,
updates Inventory, and confirms the same UID through receipt retry. A fresh client
process relogs, restoring that UID/quantity and unchanged item counts, with no
starter regrant. Eighteen known mutations yield eighteen facts. SQLite item count
remains zero and Yang remains 1500. Map/entry setup is controlled; combat simulation,
navigation and rendering are omitted in this economic RPC fixture. One worker per
wallet/NPC/Storage/ground consumer keeps its fixed PG connection budget.

Development failures were fixture/setup errors and were corrected before final
acceptance: a Node3D `visible` name collision and duplicate cleanup callback
(`run-d8qsp0vz`); an omitted client input-loop override in the controlled pickup
fixture (`run-yjci9w_r`); and a supposed public-drop race that had not yet expired
its protection (`run-k3f9n7vf`). The combat regression also exposed an existing
handwritten drop still using the old `bonus` DTO: the test now supplies the current
`amount`/`affixes` data. Gameplay assertions were preserved. Final successful logs
contain no script/parse error or unjoined-worker warning. Expected native deferred
COMMIT cleanup and small Godot fixture resource teardown warnings remain.

Normal gameplay remains SQLite. No schema/protocol/UI change, durable pending
pickup queue, persistent unclaimed ground entity, per-kill record, new wallet
operation or production cutover is introduced. Physical CEF, Linux, complete
PG combat playthrough, whole-World crash/failover, multi-World publication and P4
load/soak/import/restore are NOT VERIFIED by P3l.
