# Plans — proposed work, not current guarantees

Plans are **not** evidence that functionality exists or a standing instruction to implement old TODOs. The owner maintains the roadmap independently. Confirm active scope before starting work.

- [World W0–W7 optimization](world-server-optimization.md) — stages are conditional and require measured justification; W0/W1 and admission have already been completed, later packages are not an automatic execution queue.
- [World capacity / configuration background](world-runtime-configuration.md), [W0 limit audit](world-w0-limit-audit.md).
- [World technical candidates](world-technical-candidates.md) — ideas to evaluate, not decisions.
- [Season-to-Classic transfer](season-close-transfer.md) — deferred feature.
- [Architecture hardening](architecture-hardening.md) and [PostgreSQL migration](postgresql-migration.md) — **historical execution plans** for largely completed work, not fresh tasks. Current behavior: [full-state cutover](../development/postgres-full-state.md).

The [2026-10-14 file audit](documentation-file-audit.md) concerns the old 97-file state, not the present document set. It is retained for provenance, not a cleanup checklist.

Do not add a new plan for every implementation slice. Prefer updating an existing accepted plan or the PR description.
