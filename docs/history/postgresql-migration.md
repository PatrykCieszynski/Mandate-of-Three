# PostgreSQL migration — historical milestone

**Completed:** 2026-10-21. The live development path now uses PostgreSQL for accounts, profiles, Inventory, Wallet, Storage, NPC operations, Marketplace, Auction and Exchange. SQLite remains an explicit reference/fixture backend, not an automatic production fallback.

For the running system and operational guidance, use [full-state cutover](../development/postgres-full-state.md), [persistence policy](../architecture/persistence-policy.md), [testing](../development/testing.md), [recovery and startup](../development/postgres-process-startup.md). These override claims like "SQLite is still production" in old P1–P3 slice documents.

## Why old package reports are not current instructions
P1/P2 demonstrated backend parity and SQL transactions. P3a–v incrementally built asynchronous World reconciliation, durable operation/receipt recovery, session fencing, Inventory, Wallet, NPC, Storage, Marketplace, startup and operator recovery. P4 covered load and full cutover. These were sequential milestones, not separate live backends.

**Original detailed evidence is still available** under [evidence](../evidence/README.md), and historical implementation details remain in older `development/postgres-*.md` files while dependency/link pruning is audited. They must not be opened wholesale during ordinary feature work.

Future updates belong to current canonical documents and the PR description. Do not create new per-slice milestone files unless a new milestone is actually accepted.
