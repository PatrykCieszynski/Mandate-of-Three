# P4a — mixed World/Economy load baseline

This is the first P4 measurement package, not completed load/fault/soak or
production cutover approval. It leaves pool sizes, admission budgets, gameplay,
schema and the default SQLite backend unchanged.

```powershell
python tools/postgres/run_mixed_load.py --pg-bin Y:/Software/PostgreSQL/bin --seconds 8 --runs 3
```

Each run owns a fresh PostgreSQL cluster and fixture stores. Runs are sequential
on the same host; do not concurrently run other benchmarks. Detailed artifacts
and the series summary stay under `.godot/verification/`. The existing readiness
runner bounds native work and confirms cluster shutdown. The series runner waits
for that owner rather than imposing an outer timeout that could kill it before
cluster cleanup.

## Workload and controls

- Normal shared World bootstrap and its eight native workers, capacity two per
  worker; one control SQL connection for setup/audits outside measurement.
- Six independent seller/buyer pairs circulate original swords through
  list → edit → cancel or purchase → revenue collection. Four additional actors
  place/cancel/match Exchange orders. Small grinding income enters the real RAM
  wallet and is reconciled/checkpointed without a DB write per addition.
- Four separate read accounts issue eight searches/second in the existing legal
  500-shop/10,000-offer fixture, rotating zero/one/two indexed affix filters.
- Production `WorldServer` runtime polling/reconciliation and `GameWorld3D`
  movement/physics/MobSystem tick run with four moving actors and 36 passive
  mobs (the four existing arena dogs plus a 32-member wandering pack).
- A no-economic-traffic baseline and open-loop **offered** 10/30/100 write attempts
  per second. There is no unbounded load-generator queue: busy sources and runtime
  admission/terminal rejections are counted. Accepted work finishes within a
  bounded tail; failure/uncertainty never authorizes discarding an accepted ID.

Sessions/arrivals are synthetic, using already-covered verified-grant APIs;
there are **zero connected clients**, no Gateway/Master login cost, transport,
snapshot serialization/fan-out, physical CEF or active combat damage workload.
Endpoint rate limiters are outside this measurement. Presentation RPCs are
suppressed, not sent to fake peers. This exercises real
movement/AI and economic runtimes, but cannot establish MMO capacity or a combat
capacity target. Normal startup/session and real network behavior have separate
acceptance fixtures.

## Metrics

The executor's `profiling_enabled` defaults to false. When explicitly enabled by
the fixture, worker-local timestamps separate queue/handoff, native worker wall
time, and output-copy/poll-delivery delay. Samples emitted on World contain only
intent, timings, pending depth and result booleans: no account/UID, SQL, command
body or credentials. Timing metadata is removed before normal runtime delivery;
it does not enter RPC payloads or durable receipts. Existing executor fault/replay
tests cover enabled/disabled profiling and unchanged result envelopes.

Worker wall time includes session authorization, domain logic, SQL/lock waiting,
transaction/retry and worker-side projection. It is **not pure SQL execution
time** or a direct lock-wait measurement. `world_poll_projection` measures World
runtime polling/reconciliation plus diagnostic collection. End-to-end time starts
at the scheduled arrival, includes frame scheduling and all native round trips,
and separately records successful outcomes. Do not blame SOCI for frame-delivery
time. PostgreSQL's final database deadlock count is reported as context; exact
per-operation lock wait/retry attribution is not implemented here.

Physics inter-tick gaps include scheduling stalls. `physics_callback_span` spans
the instrumented GDScript callback interval through movement/AI callbacks; it
excludes PhysicsServer work after callbacks, rendering and network serialization.
It is not total engine CPU time. The 60 FPS / 60 physics TPS configuration is
fixed for every cohort. Latencies use bounded 0.1 ms histogram buckets through
10 seconds, with exact maximum/mean; a saturated last bucket is a lower bound.

Offered, admitted, rejected and successful-in-window rates are distinct. Tail
completions do not inflate measured-window throughput. Timing/physics
distributions include that bounded tail. Every admitted write and
every independent search must resolve, and aggregate native queues/account lanes
must remain within their existing bounds. Some legitimate Exchange rejections
(`participant_busy`, `participants_changed`, `closed`) reflect concurrent matching,
not automatically a failed invariant. Failed/unknown outcomes are never counted
as successful writes.

## Correctness gates and limits

Outside measured windows, checkpoint dirty money and verify exact UID set/count,
one custody per item, full bag/shop footprints, orphan shop cells, conserved
wallet + revenue Yang including injected income, conserved fungible material,
order reservation totals and a durable successful receipt for each successful
stable operation ID. SQL audits/setup are synchronous **only in this fixture**
and excluded from timing. They are not new runtime per-tick queries.

For a short development probe:

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite mixed-load --load-seconds 2 --load-repeats 1
```

The repeated short baseline is tested; a sustained soak, workload fault injection,
connected-client/combat load, import and cutover remain open. Increasing
`--seconds` enables longer cohorts, but does not make an unrun soak verified.
The opt-in fixture is not added to default CI smoke. Windows is verified; Linux
and physical CEF are not. See [evidence](../evidence/postgres-p4a/README.md).

## P4b — recovery while mixed traffic continues

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite mixed-load --load-seconds 15 --load-repeats 1 --load-faults
```

This opt-in mode uses the same disposable fixture and existing pools. In every
nonzero-rate cohort it injects one deferred PostgreSQL COMMIT error (`40001`)
on a listing receipt and drops one successful purchase's application delivery.
The COMMIT trigger is scoped to selected fixture command IDs, installed only in
the owned database. The lost delivery occurs after normal runtime reconciliation;
it is not a disconnected socket or a worker/process crash.

Uncertainty resolves by the existing original-ID receipt lookup, never a new
mutation ID or blind mutation retry. The rolled-back listing must resolve as
`unknown_command`, with no durable receipt. The successful purchase must recover
success with exactly one receipt, although its item already occupies Inventory.
Both paths must actually execute in every write cohort; admission rejection does
not count as an injected COMMIT failure. Existing conservation/custody/footprint,
reservation, queue-bound and complete-drain audits remain enabled.

Fault runs are recovery evidence, not comparable performance baselines. This does
not cover PostgreSQL termination, World replacement during load, socket loss,
connected CEF or the planned 30-minute soak. The runner remains opt-in and does
not change normal CI/runtime/default backend.

## Sustained run and PostgreSQL backend termination

```powershell
# 30 minutes total arrivals: 7.5 minutes baseline + 22.5 minutes writes/reads.
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite mixed-load --load-seconds 450 --load-repeats 1
# Separate fault run, never concurrent with the sustained measurement.
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite mixed-load --load-seconds 15 --load-repeats 1 --load-faults --load-backend-loss
```

`--load-backend-loss` additionally terminates the selected PostgreSQL server-side
connection process inside a deferred receipt trigger, once per write cohort.
Only fixture-prefixed command IDs in the owned disposable database can trigger
this path. No operating-system process enumeration/kill, installed service or
external connection is targeted. The trigger records its own backend PID in a
nontransactional sequence before self-termination. The audit requires that PID
to be absent from `pg_stat_activity`, original-ID recovery to report no committed
receipt, and every invariant/queue/drain check to pass. Other accounts continue
using independent sessions, and the existing worker reconnects for recovery.

This is PostgreSQL **backend process** loss during an uncommitted transaction.
It is not PostgreSQL postmaster/cluster loss, an OS crash, or World process loss;
it does not certify overlapping World ownership or automatic failover. Those
scenarios retain separate acceptance requirements. Fault timings are not a
performance baseline, including the fixture-only synchronous PID audit.

Long runs retain the same synthetic-session and no-connected-client/combat limits
as P4a. Report active-traffic time separately from baseline/tail/setup, and report
successful throughput separately from offered attempts. An unrun command is not
acceptance evidence; consult the corresponding checked-in evidence record.

Soak fixture accounts now start with 1,000,000,000 Yang each and the two material
sellers with 1,000,000 units each. This prevents finite short-probe stock from
turning sustained Exchange traffic into `funds` rejections. The conservation
audit uses that exact initial total; no replenishment occurs during measurement.
These are fixture resources only, not gameplay balance or a production grant.

Use `--load-rates 100` for targeted high-pressure diagnosis (the default remains
`0 10 30 100`). On receipt mismatch, `receipt-audit.json` preserves counts and
bounded exact missing/extra ID samples. A paused follow-up projection reports
`recovery_required` when queue admission is busy, even if the transaction already
committed. Never interpret that notification as a failed economic mutation.
