# Development and verification

- [Testing policy](testing.md) — supported suites, fixture expectations, runtime acceptance.
- [PostgreSQL backend concurrency acceptance](postgres-concurrency-acceptance.md) — opt-in P2 matrix; production still uses SQLite.
- [PostgreSQL Inventory execution](postgres-inventory-executor.md) — P3a local bounded transaction owners; runtime integration remains pending.
- [World RPC admission](world-rpc-admission.md) — A2 authorization contract and network checks.
- [World session admission](world-session-admission.md) — single-use handoff tickets and account replacement.
- [Economy command boundary](economy-command-boundary.md) — Stage 2 validation, operation results and commit/replay effects.
- [CI](ci.md) — scope and limitations of automated validation.
- [Local visual asset staging](local-dev-visuals.md) and [Warrior compatibility workflow](warrior-compatibility.md).
- [CEF root addon](../ui/cef-addon-integration.md) — install/export.
- [Architecture hardening plan](../plans/architecture-hardening.md) — planned technical work, not implemented guarantees.
- [Third-party attribution](../third-party-credits.md) — retain licence obligations.

Use the repository's pinned Godot/runtime versions; don't treat a historical one-off test as a production acceptance gate.
