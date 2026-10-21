# P4 Representative Economy Soak

This profile supplements the unchanged adversarial Stress & Recovery case.
The [focused native verification](../evidence/representative-economy/README.md)
passes; the full 30-minute representative soak remains pending.
Both 30-minute soak profiles are required P4 acceptance before import/cutover.
Adding this runner is not acceptance evidence. Responsiveness criteria still
need agreement; integrity PASS alone does not certify performance or production
readiness. Do not run it alongside another benchmark.

```powershell
# Acceptance candidate: 300 economic accounts, 40 active synthetic sessions.
python tools/postgres/run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin --profile representative
# Focused verification, with two short peaks (not 30-minute acceptance).
python tools/postgres/run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin --profile representative --seconds 90 --peak-every 30 --peak-seconds 5
```

`--accounts` controls total economic accounts (default 300). `--players` controls
requested active buyer/browser bindings (default 40), **not connected clients**.
The remaining 260 accounts own offline shops with 20 two-cell items each: 5,200
offers initially. There are zero network clients. All active accounts pass the
existing real runtime admission limits; there is no binding/worker/queue override.
A refused binding is reported, never silently replaced. Custom populations may
exercise admission without establishing the requested simultaneous capacity.

## Arrival policy

- Approximately 25% read-only browsers, 5% heavy buyers, remainder normal buyers.
- Normal/browsing accounts offer a story every eight seconds; heavy accounts
  every three seconds, with seeded initial offsets. This is explicit synthetic
  pacing, not a claim about measured player behaviour.
- Each opportunity has 65% probability of Auction search; searches vary upgrade,
  price range, ordering and optional affix filters. It also has 45% probability
  of a shop visit unless already visiting for a purchase.
- Normal buyers attempt purchases on 12% of opportunities; heavy buyers on 4%
  (more reads, without exhausting a single inventory). Browsers never buy.
  Purchase stories select five offers on 2% of occasions, otherwise one.
- Shop selection is uniform across offline sellers; offer selection is random
  within the visited authoritative snapshot. Search does not funnel everyone to
  the cheapest global listing. Expected visits/purchases remain distributed;
  concurrent stale selections are still possible and measured.
- Default peaks multiply opportunities by three for 45 seconds, starting at
  450, 900 and 1,350 seconds. Override with `--peak-every`, `--peak-seconds`,
  `--peak-multiplier`; windows must be positive, finite and non-overlapping.

At defaults, the configured normal purchase demand is roughly 0.45 items/s
before occasional bulk purchases, refusals and real latency; peak demand is
three times that. These are offered expectations, not achieved throughput.
Most catalogue stock should remain unsold. Demand/outcomes reveal depletion,
inventory capacity, conflicts and account saturation instead of replenishing
stock or deleting purchased items during measurement.

The arrival scheduler keeps no backlog. An occupied/not-ready account counts its
next opportunity as `account_busy` / `runtime_not_ready`. Already started work
uses stable intent IDs and the shared real runtime receipt recovery. Completion
includes a separately timed tail; unfinished accepted work is a failure, never
discarded. Per-action latency excludes pre-admission readiness as in the existing
fixture; story latency includes it. Offered opportunities must be read alongside
completed-action throughput.

## Ownership and audits

`postgres_economy_representative.gd` owns the catalogue, arrivals and stories.
It reuses the realm fixture's bootstrap, correlated commands, original-ID
recovery, metrics, drain and exact UID/custody/footprint/money/receipt audits.
Small hooks keep these policies out of the old stress case; no new test framework
or production runtime/configuration/schema changes are introduced.

Offline identities/items/escrow/cells are prepared in bounded transactions before
measurement. During traffic, visits, searches and purchases use normal native
PostgreSQL runtimes. Seller proceeds stay offline and participate in exact money
conservation. Purchased UIDs must remain in legal, non-overlapping custody.

There is constant background test-floor physics/passive mob AI inherited from
the integration fixture; buyer actors remain stationary. This is not real
combat, farming, connected clients, network login,
CEF or a full-world capacity result. Broader MMO stories remain a separate case.

## Reports

The existing owned runner writes `realm-workload.json`, receipt audit, schedule
and cleanup summary in ignored `.godot/verification/postgres-readiness/run-*`.
The case is explicitly `Representative Economy`; comparisons check case and
workload configuration in addition to seed, versions, population and environment.
Use `--compare <prior>/realm-workload.json` without modifying the prior report.

Inspect:

- economic accounts, requested/admitted bindings, active accounts and role mix;
- initial/remaining stock and unsold share; distinct shops/visit distribution;
- normal/peak/tail scheduled, started, busy and not-ready opportunities;
- normal/peak/tail offered and terminal search/visit/buy outcomes, plus 30-second
  demand/outcome buckets showing peak onset and recovery;
- repeated offer selections and error reasons (offer conflicts are distinct from
  capacity, queue refusal and receipt recovery);
- per-action and successful/conflicting action p50/p95/p99/max, including
  `phase:normal:*`, `phase:peak:*`, `phase:tail:*` by request start, with separate
  `completion_phase:*` cohorts using the terminal callback timestamp;
- read/write action counts, actual per-account activity, World physics/poll tails,
  native queue/worker/delivery timings, memory accounting, connections and drain.

No arbitrary latency/TPS cap is added. Profile diagnostics (observed purchases,
majority of offers unsold) are reported separately from integrity. Review demand,
read/write mix, conflicts and latency before accepting representativeness; a
near-idle or inventory-saturated run is not an acceptable normal-traffic baseline.
Only a successful runner exit, invariant audit and confirmed worker/owned cluster
shutdown certify a completed correctness run. Full-duration acceptance remains
explicitly pending until evidence is recorded and responsiveness is assessed.

## Coverage sanity and request cohorts (metrics v4)

`profile_sanity` checks that search, successful shop visit, purchase and visits to
at least two different shops actually occurred. Eligibility uses configured
duration, peak overlap, admitted roles and their unchanged arrival probabilities.
A scenario is required only when its model predicts at least eight opportunities;
this is a conservative coverage heuristic, **not a throughput, latency, story
completion or success-rate threshold**. Below that expectation, a missed random
action is `DIAGNOSTIC_NOT_OBSERVED`; a role/configuration that cannot generate it
is `NOT_APPLICABLE`. A single-offline-shop setup cannot demonstrate dispersion.
Bulk purchase is never required. These diagnostic statuses are not full soak
acceptance. Required coverage missing makes the runner fail after retaining its
report and completing the normal drain/audits.

`planned_peaks` includes every positive overlap of a configured peak with the
arrival window (including partial final peaks). Each row records scheduled and
started stories and requests actually started in that peak. With enough modeled
opportunities, all three must be observed. Tiny partial peaks remain diagnostic;
peaks outside the configured duration are not required.

Action histogram `phase:normal:*` / `phase:peak:*` now means **request start**,
captured at the same point as the existing latency stopwatch after command
readiness. Retry/recovery retains that original cohort. `completion_phase:*`
uses the existing terminal callback timestamp. `outcomes_by_start_phase` includes
offered, admitted and terminal results per action; `request_phase_transitions`
retains start → completion transitions, including completion in the drain tail.
No extra frame wait or playback/scheduler change is introduced. Physics and
uncorrelated native-pool `phase:*` observations retain observation-time cohorts.
`outcomes_by_phase`/the time series retain event-time reporting (terminal requests
use their callback timestamp; recovery/error notifications use observation time).
`metrics_version=4` makes v3 completion-cohort reports non-comparable by default;
arrival policy remains scenario v1.

Accounting relationships after drain:

- Sum of `demand.scheduled` = `started + account_busy + runtime_not_ready`.
  Skips are opportunities, not queued operations or failed transactions.
- Sum of `demand.started` = `stats.stories_started` = completed + failed stories.
  One story may emit zero, one or several requests; stories are not SQL/TPS units.
- Market `stats.attempts` = `admitted + terminal_admission_refused`.
  `admission_rejected` counts rejected scheduling attempts including retries;
  `admission_retries` counts retries, not distinct rejected operations.
- Market `admitted` = successful `completed` + known terminal `conflicts`.
  The legacy name `conflicts` includes all accepted terminal non-success results;
  use `errors`/phase error reasons to separate offer conflicts, capacity and
  definitively absent receipts. `recoveries` counts intermediate uncertainty
  notifications, not failures or additional mutations.
  Admission means volatile runtime scheduling, not a durable economic COMMIT;
  exact successful intent IDs are audited against durable receipts separately.
- Auction `searches` counts offered requests, `searches_admitted` counts actual
  queue acceptance (`has_pending` immediately after submit), and `searches_ok`
  counts successes. Per-start-cohort `admission_refused` and `terminal_rejected`
  distinguish immediate refusal from failure after acceptance. These counters
  are separate from market attempts/admitted, so do not sum them twice.

The focused non-SQL contract scene covers missing required scenarios, short/
role-restricted diagnostics, absent/partial peaks and boundary-crossing requests:

```powershell
& ./.godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --mode=world-server res://tests/representative_profile_contract.tscn --quit-after 120
```
