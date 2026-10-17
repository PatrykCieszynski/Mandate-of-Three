# PostgreSQL migration and concurrent Economy — implementation roadmap

**Status:** P1 domain ports delivered; P2 concurrency hardening in progress (2026-10-17). P3–P4 **not implemented**. This plan adds a concrete delivery milestone for the accepted [Economy C1–C5](../architecture/economy/README.md) and [World Process topology](../architecture/world-instance-architecture.md); each implementation package still requires its own review, tests, and merge decision.

**P1 progress:** [P1a readiness](../development/postgres-readiness.md) adds a
disposable Godot/SOCI PostgreSQL probe and a sanitized SQLite schema/source audit.
Full domain backend/schema parity and runtime extraction remain incomplete; this
preparatory package does not complete P1 or change the game's SQLite backend.

**P1b progress:** [account wallet parity](../development/postgres-wallet-parity.md)
adds an opt-in PostgreSQL wallet schema/store and SQLite comparison fixture for
delta checkpoints, atomic pending-income spend/credit, reservations, revisions,
rollback and reconnect. Production identity hydration, other domain stores and
runtime execution remain unimplemented; no production backend switch is made.
The native-only `commit-failure` fixture exposed a deferred COMMIT crash on
v0.4.1. User-authorized adoption of official v0.4.2 fixes the MSVC exception ABI
configuration; installed-payload COMMIT/rollback, wallet parity and readiness
now pass. This closes that driver gate, not P1's remaining domain ports or P2–P4.

**P1c progress:** [NPC purchase parity](../development/postgres-npc-shop-parity.md)
adds an opt-in transaction spanning character Inventory capacity/custody, pending
Yang, item/wallet watermarks and a durable success receipt. Existing SQLite code
shares the unchanged receipt codec. Other Inventory mutations, Storage, Player
Shop, Upgrade and Exchange ports remain pending; World continues using SQLite.

**P1d progress:** [character Inventory parity](../development/postgres-inventory-parity.md)
adds opt-in starter initialization, durable ground pickup and receipt-backed
move/equip/swap/unequip/activate with SQLite behavior comparisons and native
COMMIT-failure recovery checks. This extends the same character custody model;
account Storage remains a separate risk/slice. World still uses SQLite and
independent-connection P2 races, P3 execution/fencing and cutover remain pending.

**P1e progress:** [account Storage parity](../development/postgres-storage-parity.md)
adds an explicit account custody extension, atomic deposit/move/withdrawal with
issuing-character receipts, replay/reopen and SQLite comparisons. Targeted native
two-session fixtures cover competing withdrawal, shared capacity, cross-alt
provenance and operation-ID conflict. This does not complete the broader P2 gate
or introduce PostgreSQL clients/World execution. Player Shop, Upgrade and Exchange
ports remain pending; production continues using SQLite.

**P1f progress:** [Upgrade parity](../development/postgres-upgrade-parity.md)
adds the opt-in existing +0 to +1 transaction: ordered material stack consumption,
pending Yang plus critical spend, unchanged target UID and durable receipt.
SQLite comparisons, partial-write/COMMIT faults and replay/reopen are covered;
no new schema, recipe/gameplay, client protocol or runtime switch is introduced.
Player Shop/Exchange ports, the broad P2 gate and P3–P4 remain pending.

**P1g progress:** [Player Shop seller lifecycle](../development/postgres-shop-seller-parity.md)
adds opt-in listing, offer/Shop edits, direct Inventory withdrawal, escrow/cell
constraints and account-scoped receipt/reopen parity. Targeted overlapping
listing/withdrawal/replay fixtures cover this custody boundary. The seller-only
projection omits unported claims/revenue; purchase/settlement, those projections,
Auction reads and Exchange still need separate ports. This is not full P1/P2 or
a live Marketplace backend switch.

**P1h progress:** [Player Shop settlement](../development/postgres-shop-settlement-parity.md)
adds opt-in purchase, offline seller claimable revenue and partial collection in
native transactions with success receipts. Sorted buyer/seller account admission,
additive proceeds, Inventory-only receiving, pending-income/reservation behavior,
replay/reopen and targeted independent-session conflicts are covered. Legacy
claims, complete Marketplace projections/public reads and Exchange remain pending;
this does not switch runtime or complete the broader P2/P3/P4 gates.

**P1i progress:** [account claims and Shop projections](../development/postgres-account-claims-parity.md)
adds explicit account claim custody, atomic claim-to-Inventory with original
receipts/reopen, complete private Shop revenue/claims and coherent public visitor
reads. Prior seller-only projections remain compatible. Targeted alt/capacity
conflicts, provenance constraints and read snapshot consistency are covered;
Exchange claim creation/ledger/matching and Auction search remain separate ports.
The existing 200-claim window is preserved; there is no client/runtime switch.

**P1j progress:** [Auction search parity](../development/postgres-auction-search-parity.md)
adds bounded opt-in native reads and a transactional rolled-affix projection,
sharing filter/cursor/result logic with the existing SQLite reader. Exact row and
pagination parity, migration/projection failure recovery and 10k active-offer
observations are covered. World still uses its current SQLite async scheduler;
Exchange ledger/matching and P2/P3/P4 remain separate unfinished gates.

**P1k progress:** [Exchange ledger conversion](../development/postgres-exchange-ledger-parity.md)
adds opt-in account fungible balances, Inventory/Storage deposits, Inventory or
explicit claim withdrawals and original operation recovery. Storage owns its
authorization/consumption; Claims owns new claim production. SQLite parity and
targeted native alt/withdrawal/Storage-transfer conflicts are covered. Order
reservations/release, matching and cross-party settlement remain the next separate
port; runtime and broad P2/P3/P4 are unchanged.

**P1l progress:** [Exchange order settlement](../development/postgres-exchange-orders-parity.md)
adds opt-in pair-coordinated reservation, price-time matching, partial fills,
cancel/refund and cross-party atomic settlement/receipts. SQLite snapshot parity,
native independent-session conflicts and placement/cancel COMMIT recovery are
covered. The planned P1 Exchange domain port is complete; broad P2 race/retry,
P3 execution/fencing and P4 operational gates remain. Production stays on SQLite.

**P2a progress:** [shared wallet concurrency](../development/postgres-wallet-concurrency.md)
adds account-first NPC/Upgrade and sorted multi-account checkpoint admission.
Native cross-operation spend/reservation/collect/receipt conflicts and a reproduced
checkpoint-versus-matching lock cycle are covered. Broader custody/conflict and
bounded retry policy remain P2 work; unstructured native failure text is not a
safe retry classifier. Runtime, P3/P4 and pending-income fencing are unchanged.

**P2b progress:** [Inventory custody/receiving conflicts](../development/postgres-inventory-concurrency.md)
adds account-first native Inventory command/starter/pickup admission and explicit
cross-alt receipt conflict recovery. Native tests cover one-UID equip/list/deposit/
conversion, cross-producer full-footprint/last-space receiving and global ground
UID uniqueness. Storage policy stays in its Store. Broad P2 verification and native
error classification/whole-transaction retry remain open; P3/P4 are unchanged.

**P2c progress:** [receipt-backed settlement retry](../development/postgres-transaction-retry.md)
adopts official pinned SOCI v0.4.3 structured native errors and enables at most three
complete attempts for Shop purchase/collection after confirmed `40001`/`40P01`
statement rollback. Re-selection, prefix/replay integrity, exhaustion and no
COMMIT/failed-cleanup retry are covered. Other use cases and unreceipted checkpoints
are not opted in; broad P2, P3/P4 and production PostgreSQL adoption remain open.

**P2d progress:** [Exchange order lifecycle retry](../development/postgres-transaction-retry.md#p2d--exchange-order-lifecycle)
opts placement/matching and cancellation/refund into the existing bounded owner.
Native faults cover second-maker rollback, reservations, material/Yang refunds,
pending-income replay, exhaustion and no COMMIT retry. Independent queued sessions
verify maker and cancellation-revision reselection after rollback. No schema,
protocol or live backend change; ledger conversion/custody retry, broader P2 and
P3/P4 remain separate gates.

**Storage cross-port invariant:** the database's unique starting-cell index is
not a full-footprint exclusion constraint. Any subsequent port, especially Player
Shop or Exchange, that receives/moves items into or out of account Storage must
reuse its account-lock, authorization and complete-footprint receiving/transfer
contract inside the transaction. Do not write Storage custody directly under
only an item/character lock or assume the starting-cell index prevents overlap.

**Placement:** After the current single-World Economy hardening/SoC and local **MapInstance / CH** lifecycle, and **before** admitting two independent World Processes to the same realm economy. Preparatory contract tests may start earlier, but the plan does not require PostgreSQL for local CH or interrupt [World performance work](world-server-optimization.md). Do not combine it with gameplay/visual changes.

## Target and non-goals

- Replace the **realm Economy persistence/transaction backend** (currently local SQLite) with PostgreSQL through the project-approved Godot/SOCI integration, retaining explicit domain transaction ownership. Gateway/Master authentication storage is **not automatically in scope**; inventory every database consumer in P1 and propose any other migration separately.
- Enable **bounded concurrent independent economic commands**, not a single realm-wide SQL writer/transaction queue. PostgreSQL row-level conflicts should affect the **same offer/UID, inventory capacity, account wallet, seller revenue row, Exchange maker/order or receipt identity**, not unrelated shops. A Shop UI left open holds no database transaction or dedicated connection.
- Preserve established behavior: one-owner UID custody, authoritative revisions, account-shared wallet, reserved Yang, 30-second dirty grinding-Yang batching, account Shop claimable revenue with partial collect, Exchange settlement, operation IDs and replayable receipts, recovery after uncertain responses, transaction atomicity and committed-fact publication.
- World/client never connect to PostgreSQL directly on behalf of a player; the authorized server-side Economy boundary executes SQL using a **bounded connection pool**. World simulation never blocks a combat tick on PostgreSQL I/O. Gameplay-visible changes are applied only after a committed and validated result.
- **No** ORM/general repository rewrite, Kafka/global event bus, one connection per client, per-shop transaction mutex, speculative cross-host deployment, dual-write SQLite+PostgreSQL or new gameplay features. One logical Economy authority can process unrelated DB operations concurrently.

## Implementation packages — separate reviewable PRs

| Package | Implementation | Required acceptance gate |
| --- | --- | --- |
| **P1 — PostgreSQL adapter + schema parity** | Inventory every SQLite-specific query/trigger/UPSERT, migration and DB consumer. Integrate the native PostgreSQL-capable SOCI driver, explicit connection/transaction lifecycle and a disposable PostgreSQL test environment. Port realm Economy tables, keys, check constraints, triggers/revision rules, indexes, receipts and int64 decimal serialization. Keep the current SQLite backend usable during parity tests; do not silently switch production. | PostgreSQL boot/schema upgrade, rollback/retry and **existing** Item/Wallet/Shop/Storage/Upgrade/Exchange contract fixtures against the new backend; verify representative account/item/receipt snapshots match SQLite. Document unsupported features and Linux/native setup. |
| **P2 — Concurrent transaction correctness** | Replace assumptions supplied by SQLite's single writer with safe PostgreSQL primitives: guarded `UPDATE ... WHERE ... RETURNING`, atomic revenue increments, unique constraints, optimistic expected revisions and targeted `SELECT ... FOR UPDATE` where needed. Lock/check all resources in each transaction; use consistent acquisition order, bounded retries for serialization/deadlock errors, and exactly-once operation/receipt semantics. Protect inventory placement and Shop cell capacity against concurrent insertion. | Race tests on **independent PostgreSQL connections** for same-offer double buy, buy-vs-cancel/edit, two different sales crediting one seller, shared-account concurrent spends/collects, duplicate operation IDs and receipt discovery, same-slot listings, reservations and simultaneous Exchange matches/cancels. Assert no lost Yang, overspend, duplicate UID/fill, orphan custody, inconsistent revision or partial commit. |
| **P3 — Nonblocking World ↔ Economy execution** | Route mutations through a bounded asynchronous server-side executor/connection pool; do not synchronously wait for DB in Godot simulation. Keep admission/auth/session epoch at the server boundary, preserve stable business IDs on retries, and distinguish `committed`, `rejected`, `pending`, `unknown` after transport failures. Reconcile wallet/item revisions and publish facts on a safe World boundary; invalidate relevant caches without blocking combat. Implement necessary in-flight discovery/fencing before cross-process handoff; service/process extraction may be a separate tightly scoped PR within this package. | Real network/World tests for concurrency, timeout/lost reply, restart/reconnect, old-session fencing, CH transfer with pending Yang/operations, out-of-order facts and stale combat views. World remains responsive during slow/unavailable DB; no global command queue or unbounded pending work. |
| **P4 — Load, recovery and cutover** | Extend the **real Godot World + PostgreSQL** Marketplace fixture with continuously mixed list/edit/cancel/buy/collect, Exchange and parallel indexed reads at 10/30/100 write operations per second (adjust from measured capacity). Run repeated A/B and longer soak tests; measure admission, transaction latency, lock waits, deadlocks/retries, pool saturation, snapshot/fan-out and World tick p50/p95/p99/max. Rehearse a one-way **quiesced SQLite → PostgreSQL** migration on disposable verified backups, including WAL, IDs, wallet/revenue totals, custody, reservations, receipts, revisions and replay. Publish deployment, backup/restore, monitoring and safe forward-fix/rollback procedures. | No invariant failures across sustained load, faults, crash/restart and recoveries; no main-thread DB stalls; no unsupported silent data loss. At least three comparable performance runs and a sustained soak (initial target 30 minutes) on test data; cutover only after verified counts/checksums/invariants, fresh PG backup and explicit maintainer approval. No production switch merely because tests are green. |

P1 and P2 are **backend correctness**, P3 is **execution/topology**, and P4 is **operational proof**. Split a package further only when it reduces independent risk; avoid one large backend+worker+World PR. In P1/P2, keep one running backend at a time: parity tests are not authorization for mixed writes.

## Concurrency model and concrete invariants

- **Different sellers, different items, independent wallets:** concurrent transactions should proceed without an application-level global shop lock. The database may still briefly lock shared index/FK rows; measure rather than promise zero contention.
- **Two buyers, same offer:** exactly one commits custody transfer; the other gets a definitive stale/unavailable outcome or retrieves its original receipt. Expected offer revision and ownership/custody are rechecked atomically.
- **Two purchases from one seller:** both can race, but account `claimable_yang` increments must be **atomic against the same row** (never `SELECT balance` + write a precomputed absolute total without a lock). One shared revenue-row lock is acceptable; it must not block unrelated sellers.
- **Shared buyer/alt wallet:** conditional spend and reserved-Yang updates must enforce funds/cap in the transaction, include pending income **once** with versioned reconciliation, and tolerate a conflicting concurrent command. No stale read-modify-write.
- **Shop placement and account capacity:** independent item rows do not protect the same empty cell. Keep DB constraints/locking or serializable/conditional writes that prevent two offers or bag items occupying the same slot. Changes to Shop configuration/revision and receipt identity must also be race-safe.
- **Exchange:** price-time priority, partial fills, cancel-vs-fill, reserve release, multi-party ledger mutations and maker selection require explicit concurrency tests. Matching may need a **narrow per-pair/per-order coordination point**, not a global Marketplace lock.
- **Multi-row locks and failures:** prefer deterministic lock ordering; retry a **whole transaction with the same operation ID** only when its outcome is known to be uncommitted. An ambiguous COMMIT/connection loss requires receipt/outcome discovery first, never a new business ID. No result publication before confirmed commit.

## Migration/rollout constraints

1. **Before coding:** baseline current SQLite semantics, list all SQL statements/migrations/triggers/consumers, and decide connection-pool/admission limits from measurements. The PostgreSQL backend must have its own regression fixtures; SQLite fixtures cannot prove multi-writer safety.
2. **Before cutover:** stop/deny new economic admissions, settle or explicitly reconcile already admitted work, checkpoint/back up SQLite including WAL, import from a consistent snapshot, and validate account/character/UID mappings, total Yang + claimable revenue, reserved funds/materials, receipts and high-water revisions. Never copy only an unchecked `.db` file.
3. **At cutover:** switch a realm's **one authoritative** Economy backend only after validation; do not run dual writers or let Worlds independently mutate separate databases. Resume commands after state hydration and fencing.
4. **After cutover:** monitor lock waits, retries, latency, error rate, receipt recovery and World tick tails. PostgreSQL rollback means restore a **verified coherent snapshot** with an explicit handling of writes accepted since that snapshot, or deploy a forward fix; do not silently flip back to stale SQLite.

## Dependencies and intentionally deferred scope

- **Prerequisites:** [Pre-alpha hardening](architecture-hardening.md) A3/A5/A6 contracts, local MapInstance/CH entry/exit, [Economy C2 admission](../architecture/economy/C2-commands.md), [C3 transactions](../architecture/economy/C3-transactions.md), [C4 synchronization](../architecture/economy/C4-synchronization.md), and [C5 fencing](../architecture/economy/C5-lifecycle.md) before shared-host admission.
- Local CHs within **one World Process** remain compatible with SQLite; P1–P4 are an explicit future implementation milestone, **not** an immediate prerequisite for local MapInstance work.
- Remote World hosts, auto-placement, failover and gameplay dungeons may build on the completed economy migration but are not implemented by it. Document an additional distributed acceptance gate before the second World Process serves live accounts.
- Keep CI smoke focused and deterministic; run heavy stress manually/opt-in with real PostgreSQL. Do not include credentials, native binaries, personal game DBs or benchmark runtime artifacts in Git.
