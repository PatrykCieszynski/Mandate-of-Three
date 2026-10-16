# PostgreSQL P1d — character Inventory parity evidence

2026-10-16, Windows, Godot 4.7.2, official pinned SOCI v0.4.2, PostgreSQL 18.6
binaries from `Y:/Software/PostgreSQL/bin`. Fresh owned SCRAM loopback clusters
and disposable migrated SQLite fixtures only. Runtime remains SQLite.

- Native `--suite inventory`: PASS. Observable snapshots match SQLite for
  starter grant, move, equip/swap, activation, unequip and persistent ground pickup:
  UID custody, per-item/account revisions, derived stats and durable marker counts.
- Lost-response receipt recovery after later mutations, reopen and full bag: PASS.
  Original result/watermarks, no second mutation. No-op receipts preserve revisions.
- Full-bag pickup retry after freeing space, same prepared UID, double pickup after
  reopen, owner/stale/overlap/page bounds and 1/2/3-cell footprints: PASS.
- Starter marker, custody, item revision and receipt fault rollback: PASS, including
  swap and ground claim with partial writes already made. Rejected spam adds no rows.
- Native deferred COMMIT faults on command, ground claim and starter marker: PASS.
  API reports unknown, closes session; reconnect verifies unchanged committed state.
- Account/receiving-character/kind isolation, request conflict, caller-owned
  transaction preservation, repeat schema bootstrap and future version refusal: PASS.
- Existing native `--suite npc-shop`: PASS after extending the shared item store.
- Default smoke: 14 Godot cases, 85 Web tests and headless bridge: PASS.

Initial fixture attempts exposed a Node.owner field collision, direct assignment
through a constant resource reference and fault injection against the legacy
SQLite placement view; the fixture was corrected to use a distinct field, a local
resource reference and the canonical custody table. A later fixture cleanup used
the view's column name against custody; corrected to `uid`. No assertion was
removed. Passing fixture logs have no SCRIPT ERROR/Parse Error.

Refreshing the local editor cache after pulling P5 registered its new classes.
That headless editor import emitted unrelated Terrain3D editor/spike errors and
asset importer warnings; it is not reported as a clean editor validation. The
subsequent runtime fixtures and smoke passed. No Terrain3D change is included.

No credentials, binaries, native logs, runtime databases or player files are
committed. Linux, physical CEF, PostgreSQL-backed clients, independent writer
races, async World execution, automatic discovery/fencing and cutover are outside
this evidence. See [scope and commands](../../development/postgres-inventory-parity.md).
