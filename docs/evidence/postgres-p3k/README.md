# P3k — account Storage runtime evidence

Date: 2026-10-19. Windows, Godot 4.7.2, PostgreSQL 18.6,
godot-soci v0.4.3 (pinned payload/hash verified by the runner and `setup.py --check`).
All native runs used owned disposable loopback clusters and stopped them. No
real player database or installed PostgreSQL service was modified.

## Acceptance

| Check | Evidence | Result |
| --- | --- | --- |
| New Storage runtime | `run-f9jw23dv` (also `run-s6q4zcy7`, `run-0ngehzoj`) | PASS |
| Extended native endpoint / five actual clients | `run-q533bs2h` | PASS, all five client markers |
| Existing Storage parity/concurrency | `run-ts_2huxm` | PASS |
| Existing Inventory runtime / cache fence | `run-o27aq_qu` | PASS |
| Existing NPC runtime | `run-fczyl1g6` | PASS |
| Existing SQLite Storage recovery | `run-web-inventory.ps1 -Scene storage_recovery` | server + two clients PASS |
| Default smoke | `run-smoke.ps1` | Architecture guards, 14 Godot contracts, 85 Web UI contracts PASS |
| Whitespace / dependency pin | `git diff --check`; `tools/soci/setup.py --check` | PASS |

Native logs/summaries are retained locally below the ignored directory
`.godot/verification/postgres-readiness/<run>/`. Owned cluster data is removed
after shutdown; logs contain test-only evidence and are not committed wholesale.

The Storage runtime test verifies:

- Account-first ownership/session checks; unqualified write cannot bypass a grant.
- Full 1x2 overlap/page-boundary rejection, foreign account rejection and no partial
  mutation; existing store suite retains 1/2/3-height and native race coverage.
- Independent account and physics progress while another account waits in SQL.
- Full executor refusal restores projection and never executes that transfer later.
- Replay without another commit fact, body conflict and original UID conservation.
- Native deferred mutation COMMIT failure, missing receipt discovery and explicit
  same-ID retry; no blind mutation retry after COMMIT uncertainty.
- Native deferred projection ACK failure, bounded repair before terminal delivery.
- Lost successful completion, replacement alt, original issuer's bag preserved,
  shared Storage visibility and subsequent alt withdrawal with correct provenance.
- Late old detach and settled graceful worker drain/join.

The endpoint suite uses real Master/World RPC/auth sockets and real headless
actor, observer, restored, NPC-restored and Storage-restored client processes.
Production `InventoryEndpoint3D`, `WebUiBridge`, command dispatcher, session,
Storage/Inventory/NPC adapters and file journals are exercised. Storage deposit,
rearrange and withdrawal update authoritative snapshots; lost replies recover
without requiring the original source/cell. `ui.ready` preserves pending recovery.
Client exit/relogin reconstructs and resolves the original Storage intent. Four
Storage mutations add four facts; replay does not. Other accounts see no Storage
items, and SQLite item count/Yang remain unchanged. Earlier Inventory/Yang/NPC
scenarios remain in the same suite.

The first endpoint attempt `run-i4xkub4y` failed during worker startup: adding
another two-worker consumer exceeded the fixture's nine ordinary PG connection
slots. NPC and Storage each use one worker in this fixture, retaining the fixed
cluster cap. The corrected final run passed. This is fixture sizing evidence,
not a production connection-pool recommendation.

Expected injected COMMIT cleanup warnings (`no transaction in progress`) and
small Godot fixture ObjectDB/resource teardown warnings remain. Successful runs
contain no script/parse error; executor stop/join and owned PostgreSQL shutdown
are checked explicitly.

## Limits

The new owner is optional and normal server startup still uses SQLite. No SQL
schema or RPC signature change, default backend switch, durable Storage pending
queue, negative-receipt policy change or Yang mutation is introduced. Account
admission still permits one delegated current session. Shared snapshots are
reconciled locally using the account revision fence; cross-World notification
delivery is not implemented.

Gateway credentials/entry and map construction are controlled. Physical CEF
input/rendering, Linux, whole-server crash/restart, multi-World hosting, production
bootstrap and P4 load/soak/import/restore/cutover are NOT VERIFIED by this slice.
