# P4c — sustained fixture and PostgreSQL backend-process loss

## Clean sustained repeat: PASS (2026-10-21)

`run-frkna2kb`, integrated baseline `b442adaa` (PR #109): unchanged command
`run_readiness.py --suite mixed-load --load-seconds 450 --load-repeats 1`
with `Y:/Software/PostgreSQL/bin`. Four 450-second arrival cohorts: 7.5 minutes
baseline and 22.5 minutes traffic, plus separately timed drain/setup/audits.
Only source/document editing and lightweight static/CLI checks ran alongside;
no other benchmark ran concurrently.
The running process used the baseline scripts loaded before the subsequent
Representative Economy implementation edits.

| Offered writes/s | Offered attempts | Successful including tail | Source busy | Terminal rejections | Max native pending | Physics gap p99 / max ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 | 0 | 0 | 16.8 / 47.508 |
| 10 | 4,500 | 4,493 | 7 | 0 | 5 | 16.7 / 33.342 |
| 30 | 13,500 | 11,246 | 832 | 1,422 | 9 | 16.7 / 33.349 |
| 100 | 45,000 | 15,508 | 22,940 | 6,552 | 10 | 16.7 / 62.003 |

Exact observed success IDs = **31,247 durable success IDs**, no missing/extra IDs.
UID/custody/full-footprint, money/material/reservation, receipt and drain audits
PASS. Zero PostgreSQL deadlocks. `native_workers_stopped=true`; runner exit 0,
`POSTGRES_MIXED_LOAD_PASS`, owned cluster `stopped=true`, data cleanup confirmed
by its owner. Per-cohort tails: 0.013 / 0.021 / 0.118 / 0.092 seconds.

At 100/s offered, successful arrival-window work was 15,506 operations in
450 seconds, approximately **34.46/s**, not 100/s achieved throughput. Busy,
participant changes and receipt-recovery outcomes remain explicitly counted.
World poll/projection p99 was 5.4 ms, max 54.830 ms in that cohort; the isolated
62.003 ms physics gap remains an observed tail, not hidden by stable p99.
No new faults were injected into this clean measurement; the separate backend
loss/COMMIT/response-loss evidence below remains the fault acceptance evidence.

This closes the previously missing clean sustained repeat, not all of P4.
Representative Economy's separate 30-minute profile, agreed responsiveness
assessment and remaining World/cluster/network acceptance remain open.
No SQLite import or production cutover is implied. Raw reports remain ignored
under `.godot/verification/postgres-readiness/run-frkna2kb/`.

Windows, Godot 4.7.2, SOCI 0.4.3, PostgreSQL 18.6, owned disposable clusters only.
Runtime defaults, production data/schema, worker budgets and economy rules are
unchanged; the paused-projection notification correction is described below. This extends the existing mixed fixture, not a new framework.

## Backend process loss: PASS

`run-1cy38d6q`: `run_readiness.py --suite mixed-load --load-seconds 15
--load-repeats 1 --load-faults --load-backend-loss`, with the installed PG bin path.

| Offered writes/s | Successful operations including tail | COMMIT errors recovered | Backend exits recovered | Lost successes recovered | Max native pending |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 | 0 | 0 |
| 10 | 148 | 1 | 1 | 1 | 5 |
| 30 | 363 | 1 | 1 | 1 | 9 |
| 100 | 466 | 1 | 1 | 1 | 10 |

977 successful operations. In each write cohort, a selected deferred receipt
trigger records its own PostgreSQL PID in a nontransactional sequence and calls
`pg_terminate_backend(pg_backend_pid())`. The audit verifies actual PID exit,
original-ID receipt recovery, zero receipts for rolled-back operations and one
receipt for each recovered lost success. Independent traffic continues; the
existing native worker reconnects. All UID/custody/full-footprint, money/material/
reservation, receipt cardinality, queue and drain audits PASS. Native workers and
owned PostgreSQL cluster are confirmed stopped.

This is server-side **connection backend** process loss in an uncommitted
transaction. PostgreSQL postmaster, World and host stay up. It does not certify
cluster/World crash recovery, commit-then-network-loss or automatic failover.

## Fixture corrections discovered by longer verification

- The first sustained attempt (`run-jfx9sdwh`) exhausted short-probe Exchange
  stock and emitted expected `funds` rejections not supported by that fixture.
  It is FAIL evidence, not a capacity/correctness PASS. Only its verified Godot
  child was stopped; the owning Python runner's finally confirmed cluster stop.
- Fixture accounts now start with 1,000,000,000 Yang each and the two material
  sellers with 1,000,000 units each. No mid-run replenishment. Exact conservation
  audits use those initial values, also recorded in the report.
- `run-90omzive` exposed pre-COMMIT domain rejections disarming the backend fault
  selector. It is FAIL evidence; owned cluster stopped. Known definitive
  rejection now rearms injection, while uncertainty still uses original-ID
  lookup only. A queued/rejected request alone never certifies an injected fault.

Detailed logs/reports stay ignored under `.godot/verification/postgres-readiness/`.
No credentials or raw runtime databases are committed.

## Sustained attempt: NOT ACCEPTED

`run-bnjcjdx5` completed all four 450-second arrival cohorts after fixture funding
was fixed, but the final successful-receipt cardinality audit failed. Runner
result is FAIL; the owned cluster stopped. A JSON report's provisional PASS
field or scene OK marker does not override assertions/runner failure.

Before the final assertion the cohorts recorded 4492 / 11130 / 14644 successful
operations at offered 10 / 30 / 100 writes/s; physics gap p99 was 16.7 ms and
aggregate pending stayed at 5 / 9 / 10. UID/custody/footprint, money/material and
reservation checks did not fail; deadlocks were zero. These observations are
not accepted soak evidence. The completed 30-minute arrival window includes
7.5 minutes baseline and 22.5 minutes economic traffic.

Investigation identified a deterministic ambiguous runtime notification:
after a committed mutation, queue pressure on the follow-up snapshot calls
`_failure(..., "busy")` while the operation remains paused and recoverable. The
mixed fixture counted this as a final rejection, although the runtime could
later deliver success. The normal network Seller adapter already treats `busy`
as nonterminal, so this is not evidence of a client dupe or lost persistent item.

The runtime now maps **paused projection** `busy` to the existing
`recovery_required` code. Genuine definitive no-execution busy results retain
their old behavior. No new protocol or receipt format is introduced.
`postgres_settlement_runtime` deterministically holds snapshot admission after a
real Yang collection COMMIT, requires recovery rather than a rejection, verifies
one durable receipt and original-ID recovery of the original amount.

The mixed audit now compares exact successful IDs with durable receipt IDs and
writes bounded missing/extra samples to `receipt-audit.json`, instead of losing
the diagnosis behind a count assertion. `--load-rates 100` supports targeted
reproduction; the default four-cohort schedule is unchanged. A clean 30-minute
repeat after the correction is still required before calling soak accepted.

Other development attempts: `run-cww6sh83` was an intentionally aborted targeted
diagnostic after the deterministic cause was found (owned child only; cluster
stopped). `run-tatya3w2`, 120 seconds at offered 100/s before the correction,
passed with exactly 3758 observed and durable success IDs; a short pass did not
reproduce or dismiss the longer failure. `run-v_arh1y7` was an insufficient
one-shot queue-pressure regression attempt; `run-pwmzikdf` held the admission
failure and correctly failed the old implementation's recovery assertion.
All those clusters were confirmed stopped.

## Correction verification

- Deterministic settlement runtime RED: `run-pwmzikdf` failed the new recovery
  assertion on the old implementation. GREEN: `run-ojtdvnyn`, real collection
  COMMIT followed by persistently refused snapshot admission, original-ID retry,
  exactly one receipt and original claimed amount; full existing suite PASS.
- `run-2lc5ctt2` failed a fixture assertion which required a lost success lookup
  to succeed before allowing an intermediate recovery notification. The check
  now permits uncertainty first, then requires success at the terminal result.
  It is not PASS evidence; owned cluster stopped.
- Fault regression after correction: `run-neljz2kn` PASS, all three backend exits,
  all three deferred COMMIT errors and all three dropped successes recovered;
  exact success IDs match durable IDs; native workers and owned cluster stopped.

- Targeted post-correction pressure: `run-tz0fnel0` PASS, 120 seconds of offered
  100/s, 3833 successful operations and 3833 exact durable success IDs, no missing
  or extra IDs. Intermediate `recovery_required` notifications are not terminal
  rejections; confirmed absent receipts remain failed operations. Aggregate
  native pending max 10; physics gap p99 16.7 ms/max 20.873 ms. Native workers and
  owned cluster stopped. This short diagnostic does not replace the long repeat.
- Post-correction fault regression completed 984 successful operations matching
  984 exact durable IDs; no database deadlocks.

- Default smoke/architecture guards, TypeScript build and 88 Web contracts: PASS
  (14 Godot cases). Python AST and diff checks PASS. Native workloads and smoke
  ran sequentially; no physical CEF or Linux validation was performed.
