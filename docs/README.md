# Documentation — start here

This index classifies the documentation on the `cleanup` branch. **Folder names within Current describe domains, not additional documentation statuses.** Documentation is not a backlog inferred from file count.

## Current — source of truth
- [Current project direction](decisions/project-direction.md) — active baseline and short-term priorities.
- [Implemented systems](implemented/README.md) — what actually runs now.
- [Architecture](architecture/README.md) — accepted invariants, including [persistence](architecture/persistence-policy.md) and [World instances](architecture/world-instance-architecture.md).
- [Development](development/README.md) — current runbooks and verification.
- [Gameplay](gameplay/README.md), [World and maps](world/README.md), [UI](ui/README.md).

## Plans — proposals, not implemented behavior
- [Active/deferred plans](plans/README.md). Never interpret an old TODO as a new assignment; check code and the project direction.

## Evidence — measurements and test history
- [Evidence index](evidence/README.md). P1–P4 PostgreSQL per-package records are **historical evidence**, not a required reading set.
- Preserve receipts, raw reproducibility data and non-trivial failure findings. Historical results do not establish current production capacity.

## Historical — superseded decisions
- [History](history/README.md) and Git history. Do not use historical plans as the current architecture.

## Authority and upkeep
Current code plus current runbooks/invariants take precedence over older plans or evidence. If documentation contradicts running behavior, repair the canonical document rather than adding another summary. Do not create a Markdown report per commit or PR. Put routine results in the PR description; summarize **at milestone completion** and update the few canonical documents it changes.

This organization is intentionally link-preserving: the existing topical directories are classified as **Current** rather than physically relocated just to insert a `current/` prefix.
