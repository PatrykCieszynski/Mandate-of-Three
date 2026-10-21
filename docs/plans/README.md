# Plans — proposed work, not current guarantees

Plans are **not** evidence that functionality exists or a standing instruction to implement old TODOs. The owner maintains the roadmap independently. Confirm active scope before starting work.

- [World W0–W7 optimization](world-server-optimization.md) — stages are conditional and require measured justification; W0/W1 and admission have already been completed, later packages are not an automatic execution queue.
- [World capacity / configuration background](world-runtime-configuration.md), [W0 limit audit](world-w0-limit-audit.md).
- [World technical candidates](world-technical-candidates.md) — ideas to evaluate, not decisions.
- [Season-to-Classic transfer](season-close-transfer.md) — deferred feature.
- Historical architecture hardening and PostgreSQL cutover plans are retained in Git history; read [PostgreSQL milestone history](../history/postgresql-migration.md) and [current full-state runbook](../development/postgres-full-state.md), not an obsolete execution checklist.

The October 14 file audit covered the old 97-file state and is retained in Git history (prior to this cleanup), not as a current plan.

Do not add a new plan for every implementation slice. Prefer updating an existing accepted plan or the PR description.
