# P4b — mixed-load receipt recovery

Windows same-host disposable PostgreSQL 18.6, Godot 4.7.2, SOCI 0.4.3.
No live services/player data, production code, schema migrations or pool/budget
changes. This extends the existing opt-in mixed-load fixture, not default CI.

## Verified fault run

`run-d2rvlc1p`: `run_readiness.py --suite mixed-load --load-seconds 15
--load-repeats 1 --load-faults` (with the installed PG bin path). PASS.
Full ignored reports: `.godot/verification/postgres-readiness/run-d2rvlc1p/`.

| Offered writes/s | Successful operations including tail | Failed COMMIT recovered | Lost success recovered | Max aggregate native pending |
| --- | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 | 0 |
| 10 | 149 | 1 | 1 | 5 |
| 30 | 368 | 1 | 1 | 8 |
| 100 | 488 | 1 | 1 | 10 |

1005 successful operations, three deferred real PostgreSQL `40001` COMMIT
failures, three discarded successful application replies. All unknown outcomes
resolved using original-ID receipt lookup; the harness never resubmits an
uncertain mutation. Failed COMMIT IDs have zero durable receipts, dropped success
IDs exactly one each. An absent receipt is a resolved failed operation; the
ordinary actor loop can subsequently issue a distinct new operation.

Exact UID set/count, custody and complete bag/shop footprints, money/revenue plus
173 injected income, materials, reservations, receipt cardinality, queue bounds
and terminal completion audits PASS. Database deadlocks: zero. Native worker
shutdown and owned cluster stop are confirmed. Counts include bounded tail;
these fault runs are not comparative throughput benchmarks.

An initial development run (`run-jxq6kbiv`) failed because the fixture disarmed
COMMIT injection even when admission rejected the selected request at saturation.
The final fixture rearms on admission rejection and requires both faults to
execute/recover in every write cohort. That attempt is not PASS evidence; its
owned cluster was stopped.

## Scope limits

Lost delivery is simulated at the application callback after normal World
reconciliation, not socket loss. COMMIT failure is a deferred trigger restricted
to selected fixture IDs, not PostgreSQL process termination or a COMMIT that
succeeded remotely then lost its acknowledgement. This does not establish crash
recovery during mixed load, 30-minute soak, connected-client/combat capacity,
Linux/physical CEF, SQLite import or cutover. Those gates remain open.

## Regression verification

- Normal mode without faults: PASS, `run-cjry6s3z`, eight seconds/cohort,
  one repeat; native workers drained and owned PostgreSQL stopped.
- Architecture guards and default smoke: PASS (14 Godot cases, 88 Web contracts,
  TypeScript build). Run after the native workload, not concurrently with it.
- Python AST and `git diff --check`: PASS.
