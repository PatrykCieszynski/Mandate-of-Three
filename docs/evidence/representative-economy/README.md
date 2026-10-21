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
