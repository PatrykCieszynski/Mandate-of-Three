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
  `phase:normal:*`, `phase:peak:*`, `phase:tail:*`; phase is assigned when the
  coroutine observes completion (latency itself ends at the callback timestamp),
  so cross-boundary operations must be interpreted using the time series;
- read/write action counts, actual per-account activity, World physics/poll tails,
  native queue/worker/delivery timings, memory accounting, connections and drain.

No arbitrary latency/TPS cap is added. Profile diagnostics (observed purchases,
majority of offers unsold) are reported separately from integrity. Review demand,
read/write mix, conflicts and latency before accepting representativeness; a
near-idle or inventory-saturated run is not an acceptable normal-traffic baseline.
Only a successful runner exit, invariant audit and confirmed worker/owned cluster
shutdown certify a completed correctness run. Full-duration acceptance remains
explicitly pending until evidence is recorded and responsiveness is assessed.
