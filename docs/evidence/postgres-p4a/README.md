# P4a — mixed runtime load baseline evidence

Date: 2026-10-20. Windows, AMD Ryzen 5 5600X (6 cores / 12 logical processors),
Godot 4.7.2, godot-soci 0.4.3, PostgreSQL 18.6, Python 3.13, Node 24.19.
Same host/build; three sequential fresh owned clusters. No installed service,
player data, visible game windows or competing fixture during measured runs.

Command:

```powershell
python tools/postgres/run_mixed_load.py --pg-bin Y:/Software/PostgreSQL/bin --seconds 8 --runs 3
```

Series: `.godot/verification/postgres-mixed-load/series-dq6zayb0/summary.json`.
Independent cluster reports: `run-ez4xl9v5`, `run-fkq3xeeo`, `run-7b0i1iwy`
under `.godot/verification/postgres-readiness/`. Every run reports invariant PASS,
stopped native workers and confirmed owned-cluster shutdown.

## Workload and outcome

Eight real World workers, capacity two per worker; 16 synthetic mutation accounts,
four independent read accounts, four moving actors and 36 passive mobs. Legal
10k-offer seed, rotating indexed searches at eight/second, list/edit/cancel,
buy/claim revenue, Exchange order/cancel/matching and small RAM grinding income.
Zero connected clients, no transport/fan-out or active combat damage. Each run
has an eight-second no-economic-traffic baseline and three eight-second load
cohorts. Audits/setup and bounded final drain are separate from offered windows.

Ranges below are the three independent observations, not pooled percentiles or
confidence intervals. Timing/physics distributions include the bounded tail;
throughput uses only the offered window. Rates count successful business operations in the offered
window, not raw SQL jobs or tail completions.

| Offered writes/s | Successful operations/s | Successful E2E p95, ms | Physics gap p99, ms | Physics gap max, ms | World poll/projection p95, ms | Max native pending |
| --- | --- | --- | --- | --- | --- | --- |
| 0 baseline | 0 | — | 16.8 | 17.28–24.07 | 0.3–0.4 | 0 |
| 10 | 9.99 | 155.5–173.0 | 16.7–16.8 | 16.78–18.92 | 2.4 | 4–5 |
| 30 | 23.87–24.49 | 155.3–169.8 | 16.7–16.8 | 16.89–17.45 | 3.2–3.3 | 8–9 |
| 100 | 32.74–35.49 | 137.3–167.3 | 16.8 | 16.78–20.55 | 3.5–3.8 | 10 |

At 10/s, all 80 offered operations per run succeeded. At 30/s, 214–226 of 240
were admitted and 194–198 eventually succeeded, with tail completions excluded
from window throughput. At 100/s, 329–384 of 799 were admitted, with 374–400
source-busy attempts, 41–70 admission rejections and 66–96 terminal rejections.
263–288 eventually succeeded. Known failures were busy/recovery-required and
Exchange participant-busy/participants-changed. Successful action mix changes
under saturation, so lower aggregate p95 at 100/s is **not** evidence of faster
transactions. The report retains action counts and per-action latency.

Across all measured runs: **1655 successful business operations**, 573 successful
searches and three terminal busy search results (576 offered). Every admitted
write and every search was accounted for. All three databases reported zero
deadlocks. Exact UID set/count, full footprints, custody, shop cells, material
totals, reservations and successful receipt counts matched. Yang/revenue totals
also conserved 88 / 88 / 87 units of accepted fixture grinding income.

No queue exceeded the existing aggregate capacity of 16; no account lane was
discarded to make drain pass. All accepted work settled before audit/shutdown.
The fixture is not an endpoint-rate-limiter or connected-player capacity test.

## Attribution and decision

At offered 100/s, seller-execute native worker p95 was 10.7–13.3 ms, queue p95
13.7–21.4 ms and copied-result/poll-delivery p95 11.8–12.9 ms. End-to-end business
operations include multiple native jobs and frame/reconciliation passes. Successful
max latency reached 1.12–1.21 s in that cohort; World poll/projection had one
17.815 ms maximum spike. Do not claim zero stalls or blame the whole delay on SQL.

Physics p99 remained near 16.7–16.8 ms in these short samples. Baseline itself had
a 24.066 ms maximum gap; this does not establish absence of rare load-induced
tails. Callback span excludes PhysicsServer work after callbacks; native worker
time includes authorization, transactions, lock waiting and worker projection,
not pure SQL. Quantile buckets are 0.1 ms; full artifacts retain exact means/maxima.

**Decision:** correctness/measurement baseline PASS; **100 successful writes/s
not established**, and this fixture visibly saturates below it. Keep current
pool/budget defaults for this PR. Profile the existing stages and participant/
reconciliation pressure before proposing a separate measured performance change.
No new worker/database/queue architecture is justified solely by this sample.

## Verification and limits

- Native `inventory-executor`: PASS, `run-yh0jphjt`; disabled diagnostics emit no
  samples, enabled diagnostics preserve result envelopes and existing real lock,
  deferred COMMIT unknown, receipt replay/reconnect and drain behavior.
- Mixed short preflight: PASS, `run-2zzx8des`; includes baseline and all accounting
  and footprint/receipt gates. It is not used as a capacity observation.
- Native matching-runtime: PASS, `run-0o9xl1eo`, including participant capture,
  reservations, COMMIT-unknown recovery and drain.
- Default smoke/architecture guards: PASS (14 Godot + 88 Web contracts).
- Python AST and diff checks: PASS. Regressions ran after the benchmark series;
  no timing comparison is made against concurrent regression tests.

Development attempts exposed fixture issues (Node.owner name collision, starter
inventory overlap and missing ShopGrid preload). All were corrected; failed
clusters were stopped and are not successful evidence. Standalone `--check-only`
lacks this project's autoload compilation context and was not a verification pass.
The actual SceneTree fixture is the acceptance boundary.

This completes **P4a baseline**, not P4. Sustained soak (initial target 30 minutes),
fault injection during mixed load, broader connected-client/combat/domain traffic,
exact lock-wait/retry attribution, SQLite→PG import, deployment cutover approval
and Linux/physical CEF remain open. SQLite stays default. See the
[method and commands](../../development/postgres-mixed-load.md).
