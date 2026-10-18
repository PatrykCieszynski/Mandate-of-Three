# PostgreSQL P3d — World Inventory delivery evidence

Verified 2026-10-18 on Windows, Godot 4.7.2, PostgreSQL 18.6, official pinned
SOCI v0.4.3, Node 24.19.0. Branch `codex/postgres-inventory-runtime`, based on
integrated `main` `bb6c121c`. Every SQL fixture uses a fresh owned SCRAM loopback
cluster, not the installed service/player data. Runner confirms shutdown.

## World-thread boundary

Latest `inventory-runtime` fixture `run-f6co8t8q` (including review regressions): PASS.

- The fixture seeds World peer maps, then uses production native PG workers,
  Inventory transactions, durable intents/session grants and the actual
  `WorldServer.update_runtime_equipment()` combat projection. It does not fake
  asynchronous SQL results or compare hardcoded combat balance.
- An earlier admitted equip completes during account recovery. The actual
  equipment/stat watermark matches the authoritative PG snapshot before the
  runtime lane opens. Equip/unequip update RAM; combat's attack getter matches
  authoritative equipped stats without a per-hit DB request.
  Pending discovery scans past a full page of terminal history rather than
  incorrectly opening the lane after the first page.
- While one account is blocked by a real PG account lock, SceneTree physics
  progresses and the other account equips, hydrates and finishes. A second local
  command on the occupied lane is rejected without another durable receipt.
- Stale-revision rejection publishes after authoritative repair. Replaying its
  original ID returns the same rejection and one receipt.
- A command executes after durable ACK while the runtime owner stops polling.
  Replacement with a newer grant recovers the authoritative projection. The old
  buffered result neither updates/notifies the retired peer nor completes the
  old workflow on the new peer. A late old detach cannot erase the replacement.
- A deferred mutation COMMIT `40001` returns unknown, retains its durable pending
  intent, and pauses. A nontransactional sequence proves no automatic retry.
  Explicit caller recovery finishes the same identity once, rehydrates, then
  publishes its terminal result.
- Deferred admission COMMIT similarly pauses without a durable row or admission
  ACK. Explicit recovery discovers the missing outcome and resubmits the original
  captured ID/body, producing one mutation/receipt. These faults have known
  aborted database outcomes; arbitrary lost COMMIT responses remain uncertain.
- A separate item creation between snapshot application and readiness makes the
  marker stale. Recovery fetches/applies a newer snapshot before opening the lane.
- Retiring the peer during a queued read prevents subsequent snapshot delivery.
  Executor drain/restart and recreation of the runtime owner recover again from
  PostgreSQL and restore the same authoritative equipment/stat watermark.

## Regression checks

| Suite | Run/result |
| --- | --- |
| inventory-runtime, initial | `run-wye78tof` PASS |
| inventory-runtime, repair/lane coverage | `run-j96btwl4` PASS |
| inventory-runtime, including admission uncertainty | `run-sr0lgsk0` PASS |
| inventory-runtime, final including paged history | `run-7xzyvi3_` PASS |
| inventory-runtime, duplicate-attach review regression | `run-f6co8t8q` PASS |
| inventory-sessions | `run-68q7tqze` PASS |
| inventory-intents | `run-dc0aaa9o` PASS |
| inventory-executor | `run-ycx222a5` PASS |
| Native World session admission | `WORLD_SESSION_ADMISSION_OK` PASS |
| Default smoke | architecture guards, 14 Godot checks, 85 Web contracts PASS |
| Runner AST, official SOCI pin, diff checks | PASS |

The existing native World session fixture now checks the fingerprint helper
after real authentication, wrong-character lookup and last-login replacement.
The native authentication and runtime fixture logs include resource teardown
warnings, with exit zero/PASS and no script/parse errors. The deferred COMMIT
faults also emit transaction-cleanup warnings after the known abort. This
separate SQLite authentication test is not a complete
PostgreSQL Gateway/Master/World login test. No game/browser window was opened.

Prior P3c's full 18-suite matrix remains the shared-store baseline; this package
does not change those stores/executor. Only relevant P3a–P3c regressions are rerun.
Ignored `.godot/verification` retains diagnostic logs and owned fixture summaries.

## Limits and remaining migration

No live backend selection or dual writes. The new component is not installed in
normal login or Inventory endpoints. Trusted Master-to-Economy grant delivery,
automatic attach/detach, actual endpoint/client retry and private/public item
publication remain open. The component provides its local dependent-action gate;
callers must wire it before live use. Other domains, pending Yang/CH handoff,
multi-World, Linux, physical CEF and P4 mixed-load/soak/cutover are not established.
Production remains SQLite.

## PR #84 review follow-up

Repeated attach for the identical peer/context is now idempotent. Native run
`run-f6co8t8q` covers a ready session, admission actually blocked on an account
lock, and paused COMMIT uncertainty in both mutation and admission. The duplicate
does not reset the workflow: the blocked command delivers one terminal outcome,
explicit recovery after mutation uncertainty keeps the original intent, and
recovery after admission uncertainty reuses its captured ID/body even though the
failed admission left no durable row. Genuine replacement/disconnect recovery
continues to pass. Intentional fresh recovery in the fixture now detaches first.

Cross-domain post-command invalidation/reconciliation and indexed pending-only
recovery discovery remain explicit integration/load prerequisites, documented in
the development guide. Neither is implemented by this small review fix.
