# Current development and verification

Read [project direction](../decisions/project-direction.md), [runtime persistence](../architecture/persistence-policy.md) and [testing policy](testing.md) first. Normal development uses PostgreSQL for Economy, accounts and profiles; **SQLite is a reference/legacy fixture**, not a production fallback.

## Canonical current runbooks
- [Full PostgreSQL state](postgres-full-state.md), [backup/restore](postgres-backup-restore.md), [process startup](postgres-process-startup.md), [maintenance barrier](postgres-maintenance.md) and [World replacement](postgres-world-replacement.md).
- [World admission / capacity](runtime-capacity.md), [World session admission](world-session-admission.md), [RPC admission](world-rpc-admission.md), [channel transfer](local-channel-transfer.md).
- [Testing](testing.md), [CI](ci.md), [World baseline](world-baseline.md), [World profiling](world-profiling.md) (retained tools; profiling work is deferred).
- [CEF integration](../ui/cef-addon-integration.md), [local visuals](local-dev-visuals.md).

## Reference tools and historical fixture scope

[Native readiness](../history/postgres-readiness.md), [transaction retry](postgres-transaction-retry.md),
[backend concurrency](../history/postgres-concurrency-acceptance.md) and
[projection budget](../history/economy-projection-budget.md) retain useful commands and
failure analysis. Their original stage/default-backend statements are historical;
use the current runbooks above for deployment, not their old pending gates.

## Older implementation notes
The old `postgres-*-parity.md` and P3 `postgres-*-runtime.md` reports described incremental implementation stages. Thirty superseded stage-level documents have been removed from this directory and indexed in [completed PostgreSQL milestone history](../history/postgresql-migration.md), with exact source paths recoverable in Git history. The remaining operational runbooks and [evidence](../evidence/README.md) are authoritative for their respective purposes.

Do not write a new development report for every change: update a canonical runbook if behavior changes; put test commands and outcomes in the PR; write a dated [milestone summary](../evidence/README.md) only when a milestone closes.
