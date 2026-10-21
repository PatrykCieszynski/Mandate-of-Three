# Full-state PostgreSQL development acceptance — 2026-10-21

The owner accepted a **clean local start**, allowing retirement of old test data;
no SQLite import was requested or performed. The new local cluster is separate
from the installed PostgreSQL service. No player database was used by tests.

## Existing sustained Economy evidence

- Stress/Recovery: `run-frkna2kb`, four 450-second cohorts (30 minutes),
  **31,247 observed successes = 31,247 durable receipt IDs**, no missing/extra
  IDs, invariants/drain and owned-cluster shutdown PASS. See
  [P4c](../postgres-p4c/README.md). Offered 100/s was not achieved throughput.
- Representative: `run-cju0vqry`, 1,800 seconds, seed 1729, completed on
  `2364eb541ebad3c7abf8ac10eba81767d899dd0f` (same source tree as squash
  `19d790645dfbd798269e889bf2bdae47fe2a1933`). Owner reviewed/accepted it.

Representative population: **300 economic accounts**, 260 offline sellers,
40 active synthetic runtime bindings, **zero connected clients**. The 5,200
initial offers remained 79.8846% unsold. All 260 shops were visited.

| Observation | Result |
| --- | ---: |
| Searches, admitted/completed | 7,328 |
| Shop visits | 5,563 |
| Purchases / exact durable successful receipts | 1,046 |
| Market requests admitted/completed | 6,609 |
| Scheduled opportunities | 11,217 |
| Started stories / account-busy skips | 11,206 / 11 |
| Runtime-not-ready skips / admission refusals | 0 / 0 |
| Conflicts / retry / recovery | 0 / 0 / 0 |
| Maximum native pending | 7 |

Three 45-second, 3× peaks at 450/900/1350 seconds executed: respectively
729/733/728 opportunities, 725/730/724 started stories and 900/906/912 started
requests. Every profile sanity check passed. Successful purchase accounting
matched durable receipt cardinality; 5,280 item instances and 4,390,000 Yang
passed final integrity/conservation audits. Workers/owned cluster stopped.

Request-start-cohort search p95: normal 50.4 ms, peak 67.6 ms; p99 66.5/99.0 ms.
The peak p95 increased ~34.1% under 3× demand; no admission cliff occurred.
Visit p95 84.8 ms, buy p95 85.3 ms. Physics-gap p99 16.8 ms, maximum 44.974 ms.
These include existing main-loop delivery/observation semantics; they are not
raw SQL execution time, maximum throughput or 300 concurrent-network-client proof.

## New full-state acceptance

Native Windows / Godot 4.7.2 / SOCI 0.4.3 / PostgreSQL 18.6:

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite full-state
```

`run-ef7bg2tb`: PASS, exit 0, owned cluster stopped. Required markers:

- `POSTGRES_FULL_BACKUP_OK`: `realm` + `economy` archive, exact table/sequence
  audit, empty-target restore, tamper/populated-target/live-session refusal.
- `POSTGRES_REALM_STATE_CONTRACT_OK`: account IDs/hashes/reopen, immutable
  character/account mapping, three-column checkpoint and whole-batch rollback,
  retained guild/member/log, persistent chat and mail state.
- `POSTGRES_PROCESS_STARTUP_OK`: real Gateway/Master/World/client creation,
  deliberately foreign identity denial, grant/equip/relog, 41 XP forced save,
  graceful drain, restore into another database, process restart and normal login
  using the restored credentials and equipped UID. No normal profile SQLite or
  Master account resource file was created.

Earlier focused full-state run `run-ui69octq` also passed without the later
archive/restarted-restored-database extension. Intermediate failures found a
fixture connection budget shortfall and incorrect use of native query versus
execute for non-returning statements; corrected before the successful run.

Final follow-ups `run-paoadke8` and `run-7u1jwfoj` passed, including the final
credential-checkpoint fail-closed regression. Existing hybrid backup/restore
regression `run-tq1srifn` passed with its original nonempty Economy/WAL scenarios.
Default smoke: 14 Godot cases and 88 Web UI contracts PASS; architecture guards
and `git diff --check` PASS. Clean source-copy import
`full-state-clean-import-ix9nd5ma`: cold import exit 0 with 12 pre-existing load
messages, second import exit 0 with no script/resource load errors (same cold
pattern previously reproduced on the unchanged baseline). Not a warning-free
first-import claim.

The real local helper initialized its own durable cluster and started normal
Master/Gateway/World. Read-only SQL confirmed **0 accounts, 0 profiles, 0 items**:
old test data was not imported. It uses the same binary installation without
modifying the installed PostgreSQL service. Connection secrets remain ignored.
One initial helper restart exceeded its 30-second wait, although World did exit
and SQL/profile drain reported no failure. A repeated measured graceful World
restart completed in **9.09 seconds**, with all three roles listening afterward.
No forced World termination or deadline increase was used.

Generic Godot ObjectDB/resource teardown warnings remained; the runner separately
checked SQL script errors, process exits, native drain and owned-cluster stop.

## Boundaries

### PR #112 P1 follow-up: acknowledged profile transactions

`run-07kw33yi`: full-state suite PASS, exit 0, owned cluster stopped. Production
guild-create, block and mail handlers run against PostgreSQL; no menu/scene-path
assertions. Added `POSTGRES_PROFILE_FAILURE_OK` verifies:

- Refused BEGIN performs no RAM change or COMMIT.
- A profile-update trigger fails after guild rows and player gold changed:
  every SQL write rolls back, original live inventory/membership is restored.
- An ignored failed SQL write still prevents commit success.
- Failed block persistence changes neither live blocked IDs nor BlockList cache.
- Failed mail claim-state write rolls back the already-written staged grant;
  read failure returns failure; successful claim survives and cannot be claimed twice.
- A real deferred constraint trigger fails the actual COMMIT: no guild persists,
  RAM is restored, and the result is conservatively unknown/non-retryable.
- A proxy loses delivery **after a real successful COMMIT**: the handler returns
  unknown, performs no second commit, and a fresh reader observes exactly one
  guild and one gold deduction. RAM restoration is not mistaken for DB rollback.

Default smoke also passes: 14 Godot cases / 88 Web UI contracts. No sustained
Economy soak was repeated for this legacy profile transaction correction.
Clean source-copy import `full-state-clean-import-fo03znrs`: cold exit 0 with
the same 12 baseline load messages, second import exit 0 / zero load errors.

This closes the clean **development persistence cutover**, not production or
multi-World acceptance. SQLite reference/legacy fixtures remain checked in.
Credentials/profile APIs retain synchronous, SQL-budgeted calls outside combat;
their load/tick behavior needs separate profiling. Prior Economy soaks ran before
this profile/account port and do not certify that boundary. Linux, physical CEF
input and large connected-client combat were not rerun for a persistence change.
See [operator guide](../../development/postgres-full-state.md).
