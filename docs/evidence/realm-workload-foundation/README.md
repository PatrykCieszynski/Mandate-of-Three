# MMO Integration & Load — first runtime story baseline

2026-10-20, Windows, 12 logical processors, Godot 4.7.2, SOCI 0.4.3,
PostgreSQL 18.6. Scenario version 3, metrics version 3, seed 1729.
No production stores/services, runtime/schema changes or visible game windows.
This is the small integration slice, not completed large-population acceptance.

## Verified baseline

`run-fs6nv86_`: `run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin`
PASS. 24 requested/admitted synthetic sessions, zero connected clients, 52 passive
mobs on the scalable test floor, 180 seconds of arrivals and 39.208 seconds of
current-story completion/drain. Setup, final synchronous audits and shutdown are
outside measurement; distributions and total counts include the tail. The report
separately retains window-only successful actions and per-account frequencies.

| Role | Admitted | Economic activity |
| --- | ---: | --- |
| Farmer | 14 | Scripted reward arrivals, a shop visit after first burst, real UID pickup and cache rebind |
| Passive | 5 | Present in simulation, no economy command loop |
| Browser | 2 | Auction/filter/page/visit, single or sequential five-item purchase, cache rebind |
| Trader | 2 | Listing/edit/proceeds and Exchange |
| Power trader | 1 | Shorter think times, bulk shopping and Exchange |

19 accounts performed economic actions; five stayed economically inactive.
5600 reward events added exactly 5600 Yang. There were 106 native wallet batch
jobs, not a SQL write per reward. Three successful purchases atomically applied
39 pending Yang, confirmed from authoritative returned wallet states. All money,
material, reservation, custody/full-footprint and UID audits PASS.

Counts including the tail: 334 successful market/visit/pickup actions; 216/216
successful searches; 124 purchases; 70 persistent pickups; 5 proceeds collections;
16 checkpoint/cache rebinds; 5 Exchange fills and 5 partially filled orders whose
remaining reservation was cancelled. 210 successful market command IDs match
exactly 210 durable receipts, with no missing or extra IDs. Ground claim owner/UID
mapping is audited independently and exactly.

155 of 164 stories completed their target. 151 definitive purchase refusals
comprised one stale result and 150 absent-receipt confirmations after unavailable
offers. The small scenario deliberately overlaps buyers on cheap/live listings;
these are catalogue races, not lost money, arbitrary SQL faults or proof of server
overload. Preserve this outcome rather than hiding it behind success-only latency.
This first shopping mix is a hypothesis, not measured player behavior.

## Observed timings, not performance gates

| Measurement | p50 | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Physics inter-tick gap | 16.7 ms | 16.7 ms | 16.8 ms | 33.339 ms |
| Physics callback span | 2.1 ms | 2.8 ms | 3.4 ms | 12.498 ms |
| World poll/projection | 0.4 ms | 1.0 ms | 1.5 ms | 2.559 ms |
| Auction search, 216 samples | 67.0 ms | 300.3 ms | 400.3 ms | 468.370 ms |
| Successful purchase, 124 samples | 84.0 ms | 99.3 ms | 100.1 ms | 100.468 ms |
| Conflicting purchase incl. receipt discovery, 151 samples | 500.5 ms | 650.8 ms | 667.4 ms | 668.004 ms |
| Pickup, 70 samples | 83.5 ms | 84.7 ms | 100.1 ms | 100.087 ms |

The search tail is worth retaining for subsequent comparable runs; no tuning or
fixed p95 limit was introduced. These are runtime request/callback timings, not
pure SQL, client RPC RTT or physical UI latency. Whole-story time also includes
think time and readiness waits. Farmer story p50/p95 was 31.064/45.665 seconds;
the histogram has no 10-second ceiling. Max aggregate native pending was 9 under
the unchanged existing pool/queue configuration.

Godot allocator accounting grew from 121,070,552 to 122,713,036 bytes during the
arrival window. This is not RSS or a native leak test. PostgreSQL connections
were 9 before/after traffic, then 1 control connection after native shutdown.
Native workers and the owned cluster are confirmed stopped.

## Admission probe, not a 100-client load result

`run-2zsdpo33`: requested 100, 15 seconds of arrivals. PASS integrity/closure;
64 actual runtime sessions, 36 refused by current Inventory binding admission,
53 economically active accounts and 132 passive mobs. Roles among admitted
accounts were 39 farmers, 11 passive, 7 browsers, 4 traders and 3 power traders.
No production limit was raised. The probe drains current farmer stories after
the short arrival window; total outcomes must not be divided by 15 seconds and
advertised as throughput. The configured 100 is not 100 connected clients.
300/500 and 5–10-minute load/30–60-minute soak profiles remain unverified.

## Other verification and development evidence

- Existing separate stress/fault case after shared-probe/audit extraction:
  `run-8f85uffp` PASS, including original-ID recovery, COMMIT failure and actual
  PostgreSQL backend termination; no stress scheduling policy was put into MMO.
- Default smoke PASS: architecture guards, 14 Godot, TypeScript build, 88 Web.
- Python AST, comparison arithmetic/config mismatch/read-only baseline checks,
  exact-receipt and histogram observations, and whitespace checks PASS.
- The first preflights (`run-7d_qnq17`, `run-peksaff9`) failed fixture initialization
  or handling an income event temporarily blocked by wallet checkpoint. Fixed by
  initializing movement intentions and retaining reward events until admission.
  They are not PASS evidence. Their owned clusters were stopped.
- `run-rgzz6n4e`, `run-qnq9e141`, `run-v8wpqfiw`, `run-3ppg6z0x` and admission
  probes `run-9i0riciz`, `run-06oywi3k`, `run-nfqxfhv5` are development observations,
  not this final comparable baseline. Refinements include shuffled roles before
  admission, small canonical mob packs (with an exact population guard), unclipped
  story histograms, callback timestamps, window accounting and pending-income
  purchase coverage. Scenario/metrics versions protect comparison boundaries.

Raw reports and scheduling traces stay ignored in `.godot/verification/`.
Runtime rebind is not network login, rewards are not produced by actual combat,
and the scene is not full First Region geometry. This does not close old stress
soak, World/cluster crash, broader domain, transport, import or cutover gates.
See [method and extension policy](../../development/realm-workload.md).
