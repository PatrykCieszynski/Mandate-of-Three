# PostgreSQL Inventory cache reconciliation — P3g

This opt-in slice strengthens P3d/P3f's local cache boundary. Production still
uses SQLite. No new economic domain, schema, backend selector, distributed event
transport or playable PG realm is enabled.

## Freshness at command completion

Previously, attach/recovery acknowledged its snapshot through PostgreSQL, but
post-command refresh reopened the local lane immediately after applying it. A
different transaction could commit after that read and before publication.

Both entry and command/receipt refresh now use the existing account-locked
`finish_recovery(context, item_state)` acknowledgement. It checks the current
delegated session, absence of pending account Inventory intents, and exact
authority/account/character/revision. World applies the snapshot first, then
waits asynchronously for ACK. Only then does it publish readiness, committed
change notification and the terminal operation response. No extra transaction
queue or worker ownership model is introduced.

Stale snapshot or newly pending work restarts bounded discovery/hydration without
losing the original command/body/terminal receipt. At most three freshness repairs
are attempted; continuing churn pauses closed. Unknown ACK COMMIT likewise pauses
and invalidates the combat projection, without treating an already committed
mutation as failed or automatically executing it again. Explicit recovery can
confirm the current view and deliver the original result. A missing receipt also
passes through reconciliation rather than reopening the lane directly.

## Trusted committed invalidations

`InventoryRuntimePostgres.invalidate_item_state(marker)` is an explicit server
application API, not an RPC and not a client-supplied proof. Future economic use
cases must call it **after confirmed commit**, using their authoritative marker;
an uncertain transaction needs outcome discovery first. It does not create a
new mutation, receipt or commit fact.

- Markers use the existing account item revision. An alt's committed marker can
  invalidate the current character of that account; the character's own snapshot
  is still identity-checked before application.
- A newer revision immediately closes the local lane and invalidates the World
  equipment projection while preserving its monotonic watermark. Multiple notices
  coalesce into one required revision floor, not a queue of per-fact refreshes.
- Duplicate/older notices cannot regress a newer applied/required revision. Invalid
  markers and unrelated/unbound accounts do not schedule work. A mismatched
  authority pauses closed; it cannot force a new authority into the current cache.
- An idle binding schedules asynchronous recovery. An active workflow retains its
  command and ticket; its next snapshot/ACK must satisfy the newer floor. Paused
  uncertain work requires explicit recovery. Active SQL is never forcibly closed.
- The floor is checked before applying snapshots and again on ACK delivery, so an
  old successful ACK cannot override a notice received after SQL finished.

`WorldServer.runtime_attack()` and `runtime_attack_speed_ratio()` use only RAM.
With the optional PG runtime installed, they deny inputs while its binding is
unready, invalidated, paused or detached. SQLite retains its existing behavior.
No combat hit performs SQL or a network request.

## Scope and remaining integration

ACK proves freshness at its account-lock/commit boundary, not perpetual freshness.
Every future item-mutating domain must deliver its committed marker into this
owner before dependent gameplay proceeds. This PR supplies the local consumer
and tests controlled external commits; it does not port Shop/Storage/Upgrade,
install their publishers or solve cross-process delivery loss. Durable transport,
missed-fact repair while idle, complete in-flight combat policy and multi-World
acceptance remain separate gates. No PostgreSQL combat gameplay is activated.

Snapshots may be prepared before ACK; P3f publishes them only on readiness.
Committed facts move behind ACK too. Reconciliation/coalescing is not an audit or
exactly-once event-delivery protocol. Pending-only discovery is still deferred:
recovery pages terminal history today, and must be indexed before load acceptance.
Pending Yang/handoff, bootstrap/shutdown, P4 soak/migration and cutover remain open.

## Verification

Use the existing `inventory-runtime`, `inventory-endpoint` and
`inventory-session-bridge` suites with `tools/postgres/run_readiness.py`, on owned
fixtures and ports 18098/18099 sequentially. No new default suite is introduced.
See [P3g evidence](../evidence/postgres-p3g/README.md).
