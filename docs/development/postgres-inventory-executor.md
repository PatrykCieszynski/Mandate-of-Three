# PostgreSQL P3a — bounded Inventory transaction execution

**Opt-in local execution component, not production World integration.**
`inventory_executor_postgres.gd` runs existing Inventory commands and receipt
lookups on worker-owned native sessions. World still uses SQLite. Session/epoch
authorization, durable admission/discovery and runtime reconciliation remain
later P3 work and must precede live use.

## Ownership and limits

One main-thread caller owns configuration, submit, poll and drain. Each worker
creates/opens its own `GodotSociDatabase`, runs an entire existing store command
(including transaction decisions, receipt and bounded retry), then closes that
session on exit. A native session is never passed between threads or taken from
an async statement dispatcher. No connection is dedicated to a player.

The local API accepts scalar Inventory arguments or an original operation ID for
receipt lookup. It accepts no arbitrary SQL, Godot method, Callable or gameplay
object. Existing stores retain owner/custody/revision/capacity authority. Workers
do not touch SceneTree, endpoints, runtime equipment or player state.

Defaults are two workers with two outstanding tickets per worker. Configuration
is capped at four workers and sixteen tickets per worker. Each worker has a
bounded FIFO; main-thread routing selects the least occupied worker. Tickets
include running, buffered and **completed but not yet polled** work. This bounds
completion memory when the consumer stalls as well as queued SQL work. This is
parallel transaction execution, not a single realm-wide transaction writer.
It does not yet promise account fairness under pool saturation.

`busy` is returned only before copying a job to a worker. That ticket was never
buffered/executed. A successfully buffered job returns `{queued: true, ticket}`;
the ticket is local correlation, distinct from the unchanged business operation
ID. **Queued is not a C2 durable admission acknowledgment.** The buffer is RAM
only. No live endpoint may publish it as safely recoverable admission or treat
process loss as proof the operation failed.

## API and lifecycle

1. `start(connection, workers, capacity_per_worker)` starts threads; connect/SQL
   happen in those threads. Poll until `is_ready()` or startup fails and drains.
2. `submit_inventory(character, operation_id, action, uid, revision, position)` or
   `submit_receipt(character, operation_id)` buffer explicit work. The caller must
   be a trusted server boundary; these IDs do not perform session authorization.
3. `poll()` transfers copied completion dictionaries to the main-thread caller.
   They contain ticket, original character/ID, lookup flag, store result and
   actual-mutation/replay flags. A receipted no-op can succeed with
   `committed == false`; receipt lookup is not another commit or mutation replay.
   The caller's copy cannot rewrite a stored receipt or a later worker result.
4. `begin_drain()` immediately stops new submissions and lets all buffered jobs
   finish. Keep polling to `is_stopped()` before releasing the component. Poll
   joins only threads already finished; it never closes/joins active native SQL.
   Draining is not cancellation and has no forced-stop timeout.
5. After STOPPED, the same component may start fresh worker sessions. Tickets
   remain monotonic across restart. Original business IDs still discover/replay.

Workers apply server-side statement/lock/idle-transaction timeouts of 2000/1000/
5000 ms on every new connection. These are diagnostic initial limits, not tuned
production capacity values or a hard network deadline. The DSN must supply
appropriate connect/transport settings. A stalled network/native driver cannot
be cancelled by this component; polling remains independent, but graceful drain
can remain pending until the owner returns. Never destroy active threads to
simulate rollback.

COMMIT unknown closes the session and publishes the existing `outcome_unknown`
without automatic resubmission. The next explicit job reconnects in the worker;
original-ID discovery remains separate from any deliberate retry. Statement
rollback/retry remains the existing store's responsibility. Unexpected worker
exit stops submissions/drains other workers and marks missing local completions
unknown, never busy or confirmed rejection.

## Verification and remaining P3

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite inventory-executor
```

The disposable native fixture observes a blocked account transaction while an
unrelated Inventory command commits and SceneTree physics continues. It verifies
backpressure after an unpolled COMMIT, original replay/discovery across executor
restart, no-op flags, consumer copy isolation, native deferred COMMIT failure,
session reopen, real lock timeout, queued drain and failed-start cleanup. Native
session counts reach zero after shutdown. This does not claim real World
combat/network integration or benchmark FPS/latency.

Next integration must bind trusted session/epoch context, durable intent and
unresolved-operation discovery; gate dependent work/handoff; reconcile committed
item/wallet revisions on the World thread; and retain safe pending income
ownership. Transport interest loss must not discard the operation identity.
Other economy domains, fairness/limits under load, network/restart/fencing tests,
P4 soak and cutover remain separate. No runtime backend toggle is added here.

Evidence: [P3a native execution](../evidence/postgres-p3a/README.md).
