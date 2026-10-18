# Development and verification

- [Testing policy](testing.md) — supported suites, fixture expectations, runtime acceptance.
- [PostgreSQL backend concurrency acceptance](postgres-concurrency-acceptance.md) — opt-in P2 matrix; production still uses SQLite.
- [PostgreSQL Inventory execution](postgres-inventory-executor.md) — P3a local bounded transaction owners; runtime integration remains pending.
- [PostgreSQL Inventory identity/recovery](postgres-inventory-intents.md) — P3b durable admission, terminal outcomes and discovery.
- [PostgreSQL Inventory session fence](postgres-inventory-sessions.md) — P3c delegated backend epochs and recovery barrier; actual issuer/World integration remains pending.
- [PostgreSQL Inventory runtime](postgres-inventory-runtime.md) — P3d opt-in World-thread recovery and combat projection reconciliation; live login/endpoint wiring remains pending.
- [PostgreSQL Inventory session bridge](postgres-inventory-session-bridge.md) — P3e opt-in current Master ticket to durable grant/native World recovery; playable endpoint/bootstrap integration remains pending.
- [PostgreSQL Inventory endpoint](postgres-inventory-endpoint.md) — P3f opt-in RPC/client journal, private state and public weapon delivery; other domains/bootstrap remain pending.
- [PostgreSQL Inventory cache reconciliation](postgres-inventory-cache-fence.md) — P3g freshness ACK, versioned local invalidations and RAM-only combat-input gates.
- [PostgreSQL pending recovery](postgres-pending-recovery.md) — P3h indexed unresolved-only recovery, preserved receipt history; see the [actual adoption/cutover status](../plans/postgresql-migration.md#runtime-adoption-status).
- [PostgreSQL wallet runtime](postgres-wallet-runtime.md) — P3i RAM income batches, receipted async checkpoints, currency RPCs and forced save/relog recovery.
- [World RPC admission](world-rpc-admission.md) — A2 authorization contract and network checks.
- [World session admission](world-session-admission.md) — single-use handoff tickets and account replacement.
- [Economy command boundary](economy-command-boundary.md) — Stage 2 validation, operation results and commit/replay effects.
- [CI](ci.md) — scope and limitations of automated validation.
- [Local visual asset staging](local-dev-visuals.md) and [Warrior compatibility workflow](warrior-compatibility.md).
- [CEF root addon](../ui/cef-addon-integration.md) — install/export.
- [Architecture hardening plan](../plans/architecture-hardening.md) — planned technical work, not implemented guarantees.
- [Third-party attribution](../third-party-credits.md) — retain licence obligations.

Use the repository's pinned Godot/runtime versions; don't treat a historical one-off test as a production acceptance gate.
