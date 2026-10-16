# PostgreSQL P1c — NPC purchase parity evidence

2026-10-16, Windows, Godot 4.7.2, official pinned SOCI v0.4.2, PostgreSQL 18.6
binaries from `Y:/Software/PostgreSQL/bin`. New owned SCRAM loopback clusters and
disposable migrated SQLite fixtures only. Production runtime remains SQLite.

- Repeated native `--suite npc-shop` runs: PASS.
- Same SQLite/PostgreSQL snapshots after paid sword/material purchases and failures:
  balances, pending-applied result, item/custody state, account item/wallet
  revisions and receipt count. Random UID/authority identities alone are normalized.
- Lost-response replay/reopen with full bag and insufficient current funds: PASS;
  original UID/watermarks, no second income application or charge.
- Item/wallet/receipt faults, capacity-before-charge, overlap/bounds, stack amount,
  unknown owner, command conflicts and cross-account/character/kind receipt isolation:
  PASS. Rejected command spam creates no receipt rows.
- Revisions and a PG receiving character above 2^53 survive durable receipt recovery:
  PASS. Identity uses a BIGINT column, not a JSON-double comparison.
- Deferred COMMIT error closes the session/returns unknown; reconnect confirms this
  injected failure left no item, custody, debit, revision increment or receipt: PASS.
- Orphan item / mismatched custody owner rejected at COMMIT, rolled back together:
  PASS. Character-owned custody only, no escrow placeholder.
- Existing SQLite `market_purchase` and `exchange_orders`: PASS after sharing the
  unchanged durable receipt codec.
- Smoke: all 13 Godot cases PASS. Its Web step initially found missing local npm
  dependencies; restored from the unchanged lockfile with `npm ci --ignore-scripts`
  and ran that missing Web step separately: 85 Web tests + Godot bridge PASS.
  No package/lockfile or generated UI change. Python AST and whitespace PASS.

The first fixture attempt hit a test-variable collision with Node.owner; renaming
the local test field fixed compilation. Later runs passed without reducing a
behavioral assertion. Existing deliberate SQL-fault messages, certificate/resource
teardown warnings and local user combat-resource UID warnings remain distinguishable
from SCRIPT ERROR; passing runs contain no script error.

No binary, password, connection string, database, native log or installed PostgreSQL
data is committed. This is persistence parity, not multi-writer correctness, World
latency, PostgreSQL network client recovery, full P1 completion or a cutover gate.
See [scope and commands](../../development/postgres-npc-shop-parity.md).
