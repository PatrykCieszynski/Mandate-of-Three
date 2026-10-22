# Representative Economy profile — implementation verification

2026-10-21, Windows, Godot 4.7.2, SOCI 0.4.3, PostgreSQL 18.6.
Disposable owned clusters; runs sequential after the clean P4c stress soak.
No production data, schema, runtime limits or worker budgets changed.

## Focused native verification: PASS

`run-vtw155s4`, seed 1729:

```powershell
python tools/postgres/run_realm_workload.py --pg-bin Y:/Software/PostgreSQL/bin --profile representative --seconds 90 --peak-every 30 --peak-seconds 5
```

300 economic accounts = 260 offline sellers plus 40 admitted synthetic buyer/
browser sessions (28 buyers, 10 read-only browsers, 2 heavy buyers). **Zero
connected clients.** The catalogue starts at 5,200 items/offers. Inherited test
floor has 84 passive mobs and stationary buyer actors, not real combat/farming.

- 600 scheduled/started stories; no busy/readiness opportunity skips in this run.
- 395/395 successful searches, 297/297 visits and 64/64 purchases.
- 182 distinct shops visited; zero repeated offer selections or purchase
  conflicts. 5,136 offers remain: **98.769% unsold**.
- Successful domain read/write actions: 692 / 64 (91.5% reads).
- Normal/peak durations: 80 / 10 seconds; tail 0.080 seconds. Scheduled
  opportunities: 439 / 161, approximately 5.49/s / 16.1/s. They are offered
  stories, not achieved economic writes/s. Phase completion counts may cross
  boundaries; the 30-second time series retains that distinction.
- Exact 64 observed successful command IDs = 64 durable successful receipts.
  UID/custody/full-footprint and money/material/reservation audits PASS.
  Initial/final audited total money 4,390,000 Yang; 5,280 original UIDs retained.
- Max aggregate native pending 5; PostgreSQL connections 9 before/after traffic,
  1 fixture control after worker closure. Worker drain, runner exit 0 and owned
  PostgreSQL stop PASS. Raw data removed by its verified owner.

| Successful action | Samples | p50 ms | p95 ms | p99 ms | max ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Search, all | 395 | 33.5 | 66.3 | 83.2 | 115.285 |
| Shop visit | 297 | 83.7 | 84.6 | 87.6 | 99.976 |
| Purchase | 64 | 83.6 | 84.5 | 100.6 | 100.511 |
| Search, normal | 294 | 33.5 | 50.2 | 66.7 | 83.140 |
| Search, peak | 101 | 33.6 | 82.4 | 99.3 | 115.285 |

Search p95 rises **64.1%** between normal and intentionally tripled-demand peak
windows in this short run. No rejection/recovery was observed. This is a workload
phase observation, not a comparable historical regression or maximum capacity
measurement. Physics gap p99 16.7 ms / max 19.115 ms. Histogram quantiles round up
to 0.1 ms buckets and can slightly exceed the exact max.

## Verification boundaries

This proves the new path executes real native reads/purchases against dispersed
offline stock and preserves audited invariants through peaks/drain. It is **not
the mandatory 30-minute Representative Economy acceptance**. Default-length
peaks, sustained inventory/stock behaviour and agreed responsiveness assessment
remain pending. No Gateway/Master login, network clients, World/cluster crash,
CEF or production capacity claim follows.

The unchanged stress case separately passed its clean 30-minute repeat with
31,247 exact receipts: [P4c evidence](../postgres-p4c/README.md).
Old MMO-scenario regression `run-5q6i1qwk` PASS: original default story policy,
24 requested/admitted accounts, 45-second arrivals plus current-story tail,
100 successful searches, 32 purchases, 17 pickups, 16 cache rebinds, 2 Exchange
fills including 1 partial-then-cancelled order. Ten purchases applied 154 pending
Yang; original hot-offer conflicts remain counted rather than removed from that
scenario. Exact durable receipts, inventory/wallet/claims audits and worker/
owned-cluster closure PASS. This is a behavior regression, not a comparable
performance run against the 180-second historical baseline.

Python AST/CLI invalid-peak rejection and cross-case/configuration comparison
checks PASS. Default `run-smoke.ps1` PASS: architecture guards, 14 Godot behavior
cases, TypeScript build and 88 Web UI contracts. `git diff --check` PASS.
Raw artifacts remain ignored under `.godot/verification/postgres-readiness/`.

## PR #110 follow-up: coverage and start cohorts (metrics v4)

The arrival policy remains scenario v1; metrics v4 now classify requests by
original start and separately by terminal callback phase. Earlier v3 phase
numbers above are historical completion-observation cohorts and must not be
silently compared as if they measured the new start cohorts.

- Representative verification `run-5p0dbyhz`: 90 seconds, 40 admitted
  bindings, 300 economic accounts, peaks at 30/60 seconds lasting 5 seconds.
  All required sanity checks PASS: 395 searches, 297 visits across 182 shops,
  64 purchases, exact audited 64 durable successes. Each peak scheduled/started
  81 stories; 89/107 requests actually started in those respective peaks.
  Zero refusals/conflicts; money/UID/custody audits and worker/owned-cluster
  shutdown PASS. Maximum native pending 5.
- Start-cohort search p95: normal 51.1 ms (289 requests), peak 82.4 ms (106).
  Callback-completion cohorts contain 294 normal and 101 peak searches: **five
  peak-started searches completed after the peak** and remain in their original
  peak-start cohort. Three normal-start visits completed in peak; one normal-start
  visit completed in the drain tail. Callback durations are unchanged.
- Diagnostic `run-lrx1t_1b`: 2 seconds, one read-only browser, no stories/requests
  randomly scheduled. PASS as a diagnostic: purchase NOT_APPLICABLE; search,
  visit and dispersion DIAGNOSTIC_NOT_OBSERVED. No peak overlaps its window;
  no rare bulk purchase is required. It certifies no capacity or full coverage.
- MMO regression `run-tjecw4in`: 24 admitted accounts, 45-second arrivals plus
  tail; PASS with 100 successful/admitted searches, 32 purchases, 17 pickups,
  16 rebinds, two Exchange fills and one partial-then-cancelled order. Eleven
  purchases applied 170 pending Yang. All economic/receipt/drain audits PASS;
  owned cluster stopped.
- Original stress/fault compatibility `run-il4w3lec`: unchanged four 15-second
  cohorts with `--load-faults --load-backend-loss`, PASS. Successful operations
  148 / 370 / 468, exact **986 observed = 986 durable success IDs**, no extras/
  missing. In each write cohort one deferred COMMIT failure, one actual backend
  exit and one lost successful application response recovered. Work/cluster
  closure PASS. No scheduler or shared-audit change; **no new 30-minute stress
  repeat** was run.
- Non-SQL `representative_profile_contract`: PASS for missing required search/
  visit/purchase/dispersion/peak, legitimate short/role-restricted/partial/no-peak
  diagnostics and normal → peak, peak → normal, normal → tail request cohorts.
  It also checks that the synthetic callback-derived durations are unchanged.

Development probe `run-7zmc5t3k` also passed before completion-event classification
was tightened to use the exact callback timestamp; a small contract check ran
alongside that probe. It is not the final sequential performance observation.
The 90-second run, diagnostic, MMO and stress cases ran sequentially.

Final-code confirmation `run-4yyzskhy`: 60-second arrivals with 5-second peaks at
20/40 seconds, unchanged generator clock policy. All six required scenario/peak
checks PASS. **433 opportunities = 432 started stories + 1 account-busy skip**,
zero runtime-not-ready skips. 282 searches were offered/admitted/successful;
258 market requests = 210 visits + 48 purchases, all admitted/successful and zero
terminal admission refusals. Both new counters are present even when zero.
Exact 48 successful receipts, UID/custody/money audits and worker/cluster closure
PASS. Each accounting identity documented in the profile was verified. This
also observes a real skipped opportunity rather than inferring one from actions.

Default smoke PASS: architecture guards, 14 Godot behavior suites, TypeScript
build and 88 Web UI contracts. `git diff --check` PASS. Final contract scene PASS.

Clean import used a fresh copy of the current source tree with no `.godot`
cache, local assets or player stores, the installed pinned Terrain3D dependency,
isolated APPDATA/LOCALAPPDATA and the same two-pass protocol as CI. Final copy
`pr110-clean-import-0_tke11c`: both processes exit 0; the second import has zero
SCRIPT ERROR / Parse Error / Failed loading resource diagnostics. The first cold
pass has 12 such diagnostics from generated translations/theme and Terrain3D
DoubleSlider initialization. A separate fresh archive of the published pre-follow-up
HEAD `f9aba8c9` (`pr110-baseline-import-dbd26e2k`) reproduces the exact same 12
messages and then a zero-error second import. They are baseline cold-import
behaviour, not introduced by this follow-up; no production/UI/plugin fix is
included. Original development imports/cache remained intact.

Native fixtures/contract still emit the existing small ObjectDB/resource teardown
warnings. This does not substitute for closure evidence: every one of the six
owned PG fixture summaries reports PASS and stopped=true, and economic workers
drain before shutdown. No 30-minute stress rerun was needed or performed.

Coverage eligibility is based on configured/admitted-role expected opportunities,
not measured TPS, latency, completed-story counts or success percentages. Missing
required coverage fails separately from invariant evidence; tiny diagnostics
retain explicit non-coverage statuses. The full 30-minute Representative Economy
Soak and responsiveness assessment remain pending.
