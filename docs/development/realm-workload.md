# Two workload cases, one test infrastructure

Accepted 2026-10-20: keep two separate questions and scenario generators.

| Case | Question | Entry point |
| --- | --- | --- |
| Database/Economy Stress & Soak | What happens under deliberate queue saturation, conflicting writes and injected failures? | Existing `postgres_mixed_load` / `run_mixed_load.py` |
| MMO Integration & Load | What happens when a population follows player-paced stories? | `postgres_realm_workload` / `run_realm_workload.py` |

Both share the owned disposable PostgreSQL runner, normal World economy bootstrap,
test-only simulation/profiling probes and invariant audits in
`tests/support/postgres_workload_support.gd`. Neither case contains the other's
scheduler or arrival policy. This is test infrastructure, not a production service
framework. Existing adversarial P4a–P4c scenarios remain separate and useful.

## First slice: synthetic runtime integration

```powershell
python tools/postgres/run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin
```

Default: 24 requested accounts, 180 seconds of story arrivals, seed 1729. Current
stories finish in a separately reported tail, then checkpoint, audit and drain.
Setup/catalogue seeding, synchronous final audits and shutdown are outside the
measurement window. Total activity and timing distributions include drained
stories; successful actions and per-account attempt/reward frequencies in the
arrival window are also reported separately. No production DSN/service, player stores, CEF or visible game
windows are used. Run native workloads sequentially on the same host.

The 60/20/10/6.7/3.3 percent role mix is a test hypothesis, not player telemetry:

- Farmers: 80 scripted reward events over roughly 30 seconds, RAM Yang income,
  existing periodic wallet checkpoints, a real ground-item UID and authoritative
  pickup, followed by checkpoint/rebind validation. The first burst also visits
  a shop before the forced checkpoint; the report counts successful purchases whose authoritative wallet state confirms
  `pending_applied > 0`, exercising income plus critical spend in one transaction. An income event blocked by
  wallet refresh waits for admission; it is never silently discarded.
- Passive/exploration accounts: present in World; no economy command loop.
- Browsers: search, filter, next page, clear filter, visit the selected shop,
  purchase one item or five sequential items, and rebind Inventory/wallet once.
  Buyers prefer active simulated sellers when their listings appear in search;
  the seeded 10k-offer catalogue remains available for other visits.
- Traders: configure/list up to five owned swords, edit a listing, collect earned
  proceeds, and alternate with Exchange activity.
- Power traders: shorter think times, bulk purchases and Exchange placement/cancel.
  Quantities three versus two exercise partial fills when opposing orders overlap;
  actual fills and partial-then-cancelled outcomes are reported, not assumed.

Each account has its own seeded RNG and records randomized think times in
`schedule.jsonl`. Roles are deterministically interleaved before admission, so a
real runtime limit does not accidentally admit only the first role. Seed and
scenario version reproduce policy choices; concurrent SQL/physics completion
order and cryptographically generated item UIDs are not claimed deterministic.

### Measured versus deliberately absent

Measured: production character movement, passive mob AI, real bounded economic
runtimes/workers, RAM income aggregation, SQL transactions, snapshot reconciliation,
Auction reads, receipt lookup, custody and wallet checkpoint/rebind.

The scene is a scalable test floor with small passive dog packs, not full First
Region geometry. This first slice does **not** generate rewards through actual combat/death. Its
reward arrivals are scripted domain input. Rebind detaches and restores runtime
caches using an existing verified grant; it is **not** Gateway/Master login or a
new network session. There are zero connected clients and no RPC serialization,
fan-out, CEF, NPC navigation, or multi-World capacity claim. Normal three-process
session suites stay separate; headless client populations are a later extension.
No 100/300/500-player capacity conclusion follows from the small integration run.

## Scale and observation policy

The separate [Representative Economy profile](representative-economy.md) uses
offline sellers plus a smaller admitted buyer population. It is a mandatory P4
soak profile, not a replacement for either adversarial stress or broader MMO
integration. `--profile representative` defaults to 300 economic accounts,
40 active bindings and 1,800 seconds, with controlled peaks.

```powershell
python tools/postgres/run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin --profile load --players 300
python tools/postgres/run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin --profile soak --players 500
```

Profiles provide defaults only: integration 24/180 s, load 100/600 s, soak 100/1800 s.
`--players`, `--seconds` and `--seed` override them. There is no harness population
ceiling, target TPS gate or p95/p99 failure threshold. Large/long profiles are
manual and are not made verified by exposing these options.

**Production admission and queue limits remain intact.** Current Inventory and
wallet runtime permit 64 bindings/accounts. A request for 300 accounts therefore
does not establish 300 active sessions: the report separates requested, admitted,
refused and economically active populations, plus roles per admitted account.
The harness never raises production limits to manufacture a passing result.

Report per-action and whole-story distributions, completion/failure counts,
activity per account, income events versus native wallet jobs, queue/worker/delivery
latency (successful actions and conflicts also split), peak pending work, physics inter-tick gaps and callback span, World poll/
projection cost, memory samples, connections and final closure. Callback span is
not total engine CPU time. Action latency starts immediately before the runtime
request after readiness and ends at the actual completion callback, not the next
frame that resumes the fixture coroutine. Whole-story latency also includes
waiting for readiness and scripted think times. Worker wall time includes SQL/locks/domain work, not
pure SQL. `godot_static_bytes` is Godot allocator accounting, **not process RSS**
or proof of absence of native leaks. MMO histograms have no upper latency bucket
ceiling: 30-second stories are not clipped to the legacy stress histogram
limit. Bucket width remains 0.1 ms, with exact mean/max. Initial/final PG connection counts are not a
continuous connection-occupancy measurement.

Integrity failures still fail: money/material conservation, UID/custody and full
footprints, accepted-command outcome resolution, exact successful receipt IDs,
ground claim ownership, unchanged persisted state after rebind and clean drain.
Known offer/capacity conflicts are counted; queue pressure and uncertain outcomes
use original-ID receipt recovery, never a fresh mutation ID. A bounded liveness/
cleanup watchdog prevents a hung fixture from leaking processes; it is not an
economic latency target. A timeout is incomplete acceptance, not proof of rollback.

## Comparison and reporting regressions

```powershell
python tools/postgres/run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin --compare .godot/verification/postgres-readiness/<previous>/realm-workload.json
```

The previous report is read-only. The new report stores p95 deltas, both original
values and configuration mismatches (scenario version, seed, requested/admitted
players, duration, engine/environment and host). No baseline is silently replaced
and no arbitrary percent turns performance observations into FAIL. Inspect p99/max,
story success, refusal/recovery rates and population/activity as well as p95.
Call out material slowdowns with their magnitude and comparability limits in the
review summary; a changed scenario is context, not a reason to hide the delta.

This new case establishes its own baseline. Stress-case numbers answer a different
question and must not be presented as a directly comparable previous MMO run.

## Maintaining the case

When a World/Economy feature adds material simulation or persistence work, extend
the corresponding player story and the report's mechanism list, document which
parts are real/synthetic, and bump `scenario_version` for an arrival/behavior change.
Reuse the shared metrics/audits; add domain invariants for new custody/monetary
paths. Do not insert random unrelated commands merely to increase TPS. Keep the
small integration case opt-in initially; large profiles are manual/release checks,
not routine prototype CI. Full combat/drop generation, Storage and other current
domains, real reconnect, worker/World/cluster faults and many headless clients
remain explicit scenario additions rather than implied coverage.
