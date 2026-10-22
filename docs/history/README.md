# Historical documentation

Superseded plans, old review notes and spike decisions are available via Git history. The October 14 documentation audit is retained in Git history, not as a current checklist. See the [completed PostgreSQL milestone](postgresql-migration.md).

Detailed PostgreSQL P1–P3 implementation notes were consolidated into the [milestone index](postgresql-migration.md); original text remains in Git history. Measured [evidence](../evidence/README.md) is retained in the tree. Prefer current runbooks when answering what runs now.

Do not copy entire completed milestones into fresh active plans. Summarize at milestone boundaries only, and cite relevant commit/PR for details.

## Retained historical references

- [Native PostgreSQL readiness](postgres-readiness.md) and [backend concurrency acceptance](postgres-concurrency-acceptance.md): original migration gates and fixture findings, not pending adoption tasks.
- [SQLite account projection measurements](economy-projection-budget.md): performance findings for the former backend.
- [TinyMMO first-pass audit](tinymmo-remanent-2026-10.md) and [repository-wide legacy inventory](repository-wide-remanent-2026-10.md): dated cleanup provenance. Their candidate lists require a fresh reference check before removal.

Current deployment and verification instructions live in [development](../development/README.md). The [transaction retry contract](../development/postgres-transaction-retry.md) remains there because its failure and outcome-discovery rules still apply.
