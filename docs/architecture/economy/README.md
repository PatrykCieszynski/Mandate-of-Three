# Economy V2 — contract index

**Scope:** design contracts for a future realm-wide economy shared by World Processes on one or many hosts. These documents are **not** a request to implement a service, change the live SQLite schema, or start an infrastructure refactor.

**State of decisions (2026-10-14):** C1 and C5 are accepted at the architectural level; C2–C4 remain drafts with many accepted individual decisions. Acceptance defines future behavior, not a claim the present runtime already implements it. Open protocol and migration details are explicitly deferred.

| Contract | Status | Concern |
| --- | --- | --- |
| [C1 — ownership](C1-ownership.md) | **Accepted** | One authority for account money, durable items and economic mutations; World for simulation |
| [C2 — commands](C2-commands.md) | **Draft** | Asynchronous command/result envelope, authentication, correlation, retry |
| [C3 — transactions](C3-transactions.md) | **Draft** | Commit boundaries, loot, Yang accrual, receipts, recovery |
| [C4 — synchronization](C4-synchronization.md) | **Draft** | Versioned snapshots and combat cache, publication |
| [C5 — lifecycle](C5-lifecycle.md) | **Accepted (architecture)** | Server-controlled cancellable CH handoff, session fencing, lost hosts; implementation parameters deferred |

## Accepted cross-cutting direction

- A realm (e.g. Season or Classic) has one **logical economic authority** independent of its number of CH, layers, dungeons, World Processes or machines. Season and Classic economies are isolated, even if infrastructure is shared.
- Account Yang is shared by all characters of that account **within one realm**. Critical currency/item/equipment/trade operations commit durably and atomically before success is acknowledged. Shop/Auction seller revenue is **accepted** as separate account-level `claimable_yang` to be manually claimed in the shop panel; direct credit is not the target future design.
- The future Economy Service is a separate process, communicating asynchronously with World Processes. One logical authority need not mean a single SQL worker or one physical instance forever.
- The current development environment remains **single-process World + local SQLite**. PostgreSQL and process extraction come later; do not replace working economy code or add threads just to conform to this design.
- Simulated gameplay must not wait synchronously for database/network round trips. A particular economic operation may remain pending until its durable result is known.

## Existing implementation and compatibility

The current [persistence policy](../../persistence-policy.md) remains authoritative for the running prototype: RAM/dirty checkpoints for soft progression and some grinding Yang, immediate atomic item and critical Yang spending transactions. Current WorldDatabase, custody, Market, Exchange and auction integration are not changed by these design documents.

The separate [world instance architecture](../../world-instance-architecture.md) covers dynamically created public channels, optional invisible layers, public DT-style and private dungeons, multi-process placement and remote hosts. Economy contracts reference it without duplicating the instance scheduler.

## Contract review rules

Each file separates **Accepted**, **Proposed / open**, **Failure contracts**, and **Current code / migration implications**. Do not infer a wire protocol, deployment topology or implementation task from examples. Update contract status only after a concrete decision; mark replaced designs superseded rather than silently rewriting history.

**Suggested next review:** reconcile C2–C4 open implementation parameters with the accepted C5 architecture, check cross-contract consistency and prepare the documentation PR for merge. A future documentation reorganization should preserve these links and the historical test evidence.
