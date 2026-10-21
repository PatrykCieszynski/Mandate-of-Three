# W0 limit ownership audit — current runtime

Audited 2026-10-21 against `main` **8a934785** (PostgreSQL full-state cutover +
PR #88 neutral-host cleanup). This is an inventory and configuration proposal,
not implemented settings or permission to raise limits. See
[measurement contract](../development/world-baseline.md) and
[configuration plan](world-runtime-configuration.md).

## Findings that constrain the next configuration slice

1. `[world-server] max_players=200` is loaded into `WorldMain.world_info`, but
   no enforcing consumer of that key was found in the current production source.
   `WorldServer.start_world_server()` starts the transport without a player budget.
   It must not be presented as an enforced process-wide session ceiling.
2. Inventory **64 bindings**, Wallet **64 retained accounts**, and Master grant
   issuer **64 tracked accounts** are independent caps. First Region has two
   public copies, each defaulting to 64 places; that does not provide 128 usable
   Economy sessions. Master or World Economy admission can refuse first.
3. World attaches Inventory/Wallet **after** native authentication and local
   session-map installation. A capacity refusal disconnects the peer. The next
   slice should reserve capacity before issuing a usable handoff/admission;
   retain single-session and generation fencing throughout rollback/release.
4. Dirty/unknown offline Wallet accounts and unresolved control/economic work
   legitimately retain capacity. A max-online-player setting cannot alone size
   those resources. Never evict uncertain work to make room for a new login.
5. Current poll and peer-lookup paths have per-account iteration. Size/poll/cache
   costs need measurement; the value 64 has no demonstrated physics/hardware basis.

## Actual budgets and decisions

Paths below are relative to the repository root; values are observed defaults.
“Configure” means the **next implementation**, not a supported key today.

| Owner / source | Current value / unit | Exhaustion / lifetime | W0 decision |
|---|---|---|---|
| `WorldMain`, `data/config/world_config.cfg` | `max_players=200`, advertised metadata | No process-wide enforcing read found | Replace with validated enforced session/reservation budget; preserve 200 as metadata until explicitly reconciled, do not claim it is usable capacity |
| Gateway `http_server.gd` | 10,000 sessions including reservations; TTL 28,800 s; 1,024 pending Master requests | Reserve before side effects; replace own account slot; bounded deadlines/pruning and transport errors | Configure separately from World players; retain account replacement semantics |
| World `world_server.gd` | 1,024 handoff/pending-auth places; ticket TTL 30,000 ms | Refuse handoff before storing; prune, consume once, invalidate on Master loss | Configure control-plane burst budget/TTL; distinct from connected players |
| Master `inventory_session_issuer_postgres.gd` | `MAX_ACCOUNTS=64` tracked grants/revocations | New account `busy`; completed grants retained until revoke; paused/revoke jobs retained, erase on confirmed retire | Explicit control ownership capacity plus drain/recovery headroom; do not mistake for concurrent SQL |
| PG `inventory_runtime_postgres.gd` | `MAX_BINDINGS=64`; identity jobs 4 | attach false; idempotent same context; detach erases binding, bounded native jobs finish/discard; durable work recovered by replacement | Derive online binding budget from accepted session budget; identity queue separate |
| PG `wallet_runtime_postgres.gd` | `MAX_ACCOUNTS=64`; checkpoint 30 s | attach false; detach keeps dirty/captured income, peer=0; erase only after safe acknowledgement | Separate retained-account budget/headroom; reserve room at session admission, preserve soft-income checkpoint policy |
| PG NPC runtime | One active operation per account; no extra global MAX_ACTIVE | Wallet capture + Inventory hold; bounded native submit; failures retain receipt recovery as required | Inherits admitted-account/worker budgets; do not invent a second session cap |
| PG Storage / Ground / Seller runtimes | `MAX_ACTIVE=64` **each**, including detached/unknown operations | `busy` before new active entry; per-account lane; preserve recovery/drain ownership | Configure independent domain work caps; retain unresolved work |
| PG bootstrap `economy_bootstrap_postgres.gd` | Inventory 2, Wallet 1, NPC 1, Storage 1, Ground 1, Market 2 workers; Master control 1 | Fixed native owner per connection, bounded startup/drain; not per player | Configure with bounded validated pool sizes; preserve current 8 World + 1 Master workers by default |
| PG executor / settings | Queue capacity **2 per worker**; config 1..4; executor allows 1..16; max workers 4 per executor | load counts queued + executing + completed but unpolled; submit `busy`, no unbounded secondary native queue | Document actual meaning; keep executor hard ceiling as guard; validate startup config against it |
| PG Auction runtime | 64 queued+active requests per World; one active query; 8 requests/account/s; 2,000 ms deadline | Account replaces queued request; bounded rejection; timeout retains native slot until completion | Configure scheduling budget/deadline separately; preserve dedup and exactly one terminal response |
| `InstanceResource` | 64 places per map copy, including awaiting; public copies 2, startup 1 (First Region 2); entry 30 s, idle/min lifetime 60 s | Reservation/join checks; pending expiry; PUBLIC/RESERVED fences | Keep map capacity/content policy distinct from process budget; validate relationship at startup |
| `InstanceManagerServer` | 8 host instances; CH choice timeout 30 s | Includes loaded/loading provision budget; expire choices | Configure host budget; retain atomic pending-place accounting |
| `instance_provision_budget.gd` | 120 samples; 2 s settling; max sample age 250 ms; sum p95 frame+physics <75% tick | Fail-closed dynamic copy creation without recent headroom | Keep algorithm/measurement constants until W1 evidence; expose policy only with clear validation |
| World runtime / `GameWorld3D` | 60 physics Hz, headless max FPS 60; input + player snapshots 20 Hz; input expiry 250 ms | Current timing/authority behavior | Freeze in W0; no blanket tick-rate or wire cadence change |
| `BaseMultiplayerEndpoint` | 1 MiB inbound + outbound WebSocket buffers | Bounded engine transport buffering | Keep as protocol safety margin, not tune down after payload optimization |
| Inventory intent / command owners | 8 pending durable intents/account; discovery page 32, max page 100; recovery/transaction attempts 3 | Recovery/receipt correctness and bounded traversal | Keep correctness/page guards in code; do not make arbitrary deployment knobs |
| Item/Wallet/Exchange domain | 180 bag cells; Yang max 9e15; Exchange orders 20/account, 2,048/pair | Durable/gameplay invariants and economic admission | Keep domain/content limits separate; schema/receipt semantics require their own change |

## Runtime cost and lifecycle inspected

- `WorldServer._process()` polls six owners once per frame. Inventory `poll()`
  walks `_bindings.keys()` even when all accounts are ready. `_for_peer()` walks
  `_bindings.values()`; `snapshot_for_peer()` then deep-copies the snapshot.
- Wallet `poll()` iterates accounts and `_for_peer()` scans values. Clean detach
  can release on the next poll; dirty/paused/in-flight accounts persist until
  acknowledgement/recovery. This persistence is required, not a leak to “fix”.
- Seller includes active work plus refresh accounts and its shared Auction owner;
  operation caps and native slot counts must remain separate from session count.
- Master issuer retains done grants and only erases after confirmed revoke.
  Per-process World sizing must not silently ignore the realm/control owner.
- Serialized Inventory size and allocator-memory delta are measured separately.
  Never estimate RAM by multiplying the wire payload alone. Binding probe uses
  mocked ready states; real loading/recovery remains in existing PG suites.

## Next implementation contract (separate review)

One immutable, server-only validated startup settings value; explicit injection
to owners. No mutable settings singleton, hot reload, new worker model or schema.
Retain present pool/queue/operation defaults. Document public supported keys,
units, ranges and resource dimensions in one commented sample; secrets remain env.

Admission must account for connected + reserved sessions, Master grant ownership,
Inventory slots and Wallet retained ownership, with rollback of unused reservations.
Exercise rejection before a usable handoff, max+1, double reservation, logout,
replacement login and dirty/unknown detached accounts. Establish headroom policy
before raising **any** cap. Configuring 200/500 does not prove hosting capacity.

W1 then profiles actual hotpaths/poll/copy/recovery costs with nested timers and
same-commit controls. W2 movement remains unapproved until those measurements;
Terrain3D/combat parity and W6 true connected-client capacity remain open.
