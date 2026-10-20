# PostgreSQL migration and concurrent Economy — implementation roadmap

**Status:** P1 PostgreSQL domain ports and P2 backend concurrency acceptance are
delivered. P3 has opt-in Inventory execution, durable recovery, delegated sessions,
Master/World wiring, client RPC delivery, cache reconciliation and indexed pending
discovery; P3i adds optional RAM Yang batching, receipted async checkpoints and
currency endpoint delivery. P3j adds optional NPC Shop/Upgrade execution and client
receipt/journal recovery. P3k adds optional shared Storage execution and combined
Inventory/Storage reconciliation. P3l adds optional starter initialization and
ground-item pickup/receipt recovery. P3m adds optional seller-local Marketplace
and item-claim execution with client journal recovery. P3n connects optional
purchase/proceeds settlement and authenticated shop visits. P3o connects optional
Exchange item/Storage deposits and withdrawals with journal recovery. P3p adds
optional order/cancel/matching, captured participant wallets and World-local
ledger projection freshness. P3q connects optional public Auction catalog/search
through bounded, session-qualified native reads. **Operational bootstrap and P4 are not completed. Normal
gameplay remains SQLite.** This roadmap implements the accepted
[Economy C1–C5](../architecture/economy/README.md) and
[World Process topology](../architecture/world-instance-architecture.md); every
package still requires its own review, tests and merge decision.

## Runtime adoption status

**Audited 2026-10-20. This is not the final cleanup of SQLite.** P1/P2 provide
PostgreSQL stores and backend acceptance; P3 has opt-in Inventory, wallet, NPC,
Storage, ground-item and seller/item-claim paths.
Normal server startup still creates the SQLite writer. A complete PostgreSQL
realm has not yet been enabled or rehearsed.

| Area | Current normal runtime | PostgreSQL adoption still needed |
| --- | --- | --- |
| Bootstrap / database ownership | `WorldDatabase.start_database/open_database` creates SQLite and its stores | Configure/provision the authoritative PG backend, pool lifecycle, graceful drain, health/readiness and fail-closed startup; never enable dual economic writers |
| Inventory / ground-item pickup | `WorldEconomyService` calls SQLite item transactions; PG move/activate/equip/unequip recovery is opt-in | P3l optionally connects marker-based initialization and asynchronous pickup with original UID, claims and current Inventory publication. Production provisioning/bootstrap and full PG gameplay acceptance remain |
| Yang wallet | Normal startup still loads/checkpoints `WalletStoreSqlite` | P3i optionally supplies RAM income, receipted async checkpoints, fixed test spend, currency RPC/HUD and local reconnect/drain. Production bootstrap, cross-domain freshness and multi-World handoff remain |
| NPC Shop / Upgrade | Normal startup uses `WorldEconomyService` and SQLite | P3j optionally connects authenticated RPCs, bounded PG transactions, captured pending Yang and current Inventory/wallet publication. Production bootstrap remains |
| Account Storage | `WorldEconomyService` still uses SQLite | P3k optionally connects shared custody, stable client journal recovery and combined account-revision projections; production bootstrap and distributed publication remain |
| Player Shop / claims / Exchange | `MarketplaceService` constructs `MarketStoreSqlite` / `ExchangeStoreSqlite` | P3m optionally connects seller/item claims; P3n adds purchases/proceeds with captured income, buyer Inventory/wallet reconciliation, seller private refresh and journals. P3o connects Exchange ledger conversions; P3p adds order/cancel/matching with participant wallet captures and local projection generations. Cross-process publication and production bootstrap remain |
| Auction reads | `AuctionQueryService` / `AuctionSociReader` uses SOCI's **sqlite3** read-only WAL reader | P3q optionally connects the catalog and indexed public search through a World-scoped bounded scheduler, session-qualified native worker reads and existing browser RPCs. Normal startup/operational PG ownership remain |
| Character/profile and other World data | `WorldStoreSqlite` still saves character/quest/guild data; `MailStore` uses SQLite; progression checkpoints stay here | These are not automatically covered by the realm Economy migration. Decide/retain their explicit boundary and identity mappings, or scope a separate port before claiming SQLite can be removed entirely |

Master credentials are a separate existing `AccountResourceCollection` persisted
as a Godot `.tres` resource by `AuthenticationManager`, not a migrated PostgreSQL
or SQLite auth store. The roadmap does not silently include moving that authority.

Remaining deliverables before an Economy cutover are substantial:

1. Finish P3 runtime adoption for the remaining economic
   domains, preserving session-qualified recovery and committed-state publication.
2. Complete provisioning/bootstrap/shutdown and handoff behavior, plus actual
   end-to-end PG gameplay/network acceptance. Existing optional fixtures are not a
   playable realm selector.
3. Run P4 mixed runtime load/fault/soak, then rehearse a quiesced SQLite-to-PG import
   with account/character mapping, UIDs/custody, Yang/reservations/revenue,
   revisions and original receipts conserved. Test restore/operational procedures.
4. Obtain explicit maintainer approval for cutover. Only afterward retire unused
   SQLite economic runtime paths; parity fixtures/reference code and separately
   retained profile/progression storage are distinct cleanup decisions.

After P3q, the next integration priority is operational PostgreSQL bootstrap and
backend ownership/lifecycle, followed by full PG gameplay acceptance and P4.
The listed economic domains now have optional execution/read paths; that alone
does not create a playable PostgreSQL realm or authorize removing SQLite. No percentage or final PR count is asserted: unfinished runtime domains
and P4 are separate acceptance
gates, not documentation-only leftovers.

## Delivery history

The progress entries below record each package's scope and deferrals at delivery
time. The latest acceptance matrix and remaining gates are collected in
[P2 backend concurrency acceptance](../development/postgres-concurrency-acceptance.md).

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

**P2e progress:** [Exchange stack conversion retry](../development/postgres-transaction-retry.md#p2e--exchange-stack-conversion)
adds bounded complete deposit/withdraw attempts to the existing owner. Native
failures verify whole/partial bag and shared-Storage consumption, Inventory/claim
receiving, one durable generated UID, receipt replay, exhaustion and no COMMIT
retry. Independent Storage transfer between attempts forces source reauthorization
without ledger credit. Storage owns its existing lock/authorization/consumption
contract; no schema, protocol or runtime backend changes. Remaining domain retry,
broader P2, P3 and P4 are still open.

**P2f progress:** [Upgrade retry](../development/postgres-transaction-retry.md#p2f--upgrade-material-wallet-and-item-mutation)
uses the existing bounded owner for complete material/pending-Yang/spend/target/
receipt transactions, with one captured server recipe. Native faults cover all
mutation stages, original-result replay, exhaustion and no COMMIT retry. Queued
editors force material reselection or stale-target rejection without partial cost.
No schema, protocol, gameplay or runtime backend change; other domains' explicit
retry adoption, broader P2 and P3/P4 remain open.

**P2g progress:** [NPC purchase retry](../development/postgres-transaction-retry.md#p2g--npc-purchase-and-receiving-capacity)
uses the same bounded owner for pending income, spend, Inventory receiving and
receipt, with captured server offers. Native faults prove one UID/debit/prefix,
original replay, exhaustion and no COMMIT retry. Queued receiving conflicts cover
nonstarting footprint cells: explicit placement rejects without costs, automatic
placement reselects. No schema, protocol, gameplay or runtime backend changes;
remaining Inventory/Storage/seller/claim retry, broader P2 and P3/P4 remain open.

**P2h progress:** [Inventory command retry](../development/postgres-transaction-retry.md#p2h--character-inventory-commands)
uses one existing command owner for whole move/equip/activate/unequip/swap attempts.
Native faults verify custody, revisions, stats, original replay, no-op/mutation
flags, exhaustion and no COMMIT retry. Queued editors force current revision,
equipment and full-footprint capacity decisions. Starter/pickup/receiving helpers
keep their existing policies; account Storage and seller/claim retry stay separate.
No schema/protocol/runtime change; broader P2 and P3/P4 remain open.

**P2i progress:** [Shared Storage retry](../development/postgres-transaction-retry.md#p2i--shared-account-storage-commands)
uses one existing owner for complete deposit/internal move/alt withdrawal attempts.
Native faults cover custody, provenance/revision, placement, original issuing-
character replay/conflict, no-op flags, exhaustion and no COMMIT retry. Queued alts
change source ownership/revision or shared destination footprint before retry.
In-transaction consumption helpers retain caller ownership, with no nested loop.
No schema/protocol/runtime change; seller/claim retry and broader P2/P3/P4 remain open.

**P2j progress:** [Player Shop seller retry](../development/postgres-transaction-retry.md#p2j--player-shop-seller-lifecycle)
adds bounded full list/configure/edit/withdraw attempts using the same owner.
Native faults cover partial cells, revisions/provenance, Offer Only, price-only
watermarks, account-scoped cross-alt replay, exhaustion and no COMMIT retry.
Queued editors force current custody, Shop/offer revision and both grids' capacity
decisions. No schema/protocol/runtime change; claims and broader P2/P3/P4 remain open.

**P2k progress:** [Account claim receiving retry](../development/postgres-transaction-retry.md#p2k--account-claim-receiving)
uses bounded full attempts for claim-to-Inventory receiving, preserving the
original receiver/ID and account discovery. Native faults cover item/custody/
receipt rollback, explicit/automatic capacity, replay/reconnect, exhaustion and
no COMMIT retry. Independent queued editors force current claim ownership and
destination footprint checks. Listed receipted-domain retry adoption is covered;
this does not close broader P2 acceptance, P3 execution/fencing or P4 cutover.
No schema, public contract or production backend change.

**P2l progress:** [Backend concurrency acceptance](../development/postgres-concurrency-acceptance.md)
maps the current domain/race/retry fixtures to P2 guarantees. The shared-wallet
fixture now covers Shop purchase versus Exchange reservation/immediate matching,
Yang/material conservation, simultaneous sale/partial collection and unrelated
Shop/Exchange progress while a different account transaction is blocked. The
full native matrix and default smoke are recorded in the evidence report. This
closes backend correctness acceptance for current operations, not runtime
execution, pending-income/session fencing, load/soak or production cutover.

**P3a progress:** [Bounded Inventory execution](../development/postgres-inventory-executor.md)
adds opt-in worker-owned native sessions for full existing Inventory transactions
and receipt lookup, bounded per-worker work/results, main-thread polling and
nonblocking drain. Native tests cover independent completion/SceneTree physics
during blocked SQL, unconsumed-result capacity, replay/restart, COMMIT unknown,
lock timeout and session cleanup. Volatile `queued` is NOT durable admission;
session/epoch fencing, unresolved discovery, pending-income ownership, actual
World integration, other domains and P4 remain separate. No live backend switch.

**P3b progress:** [Durable Inventory identity/recovery](../development/postgres-inventory-intents.md)
adds explicit admission COMMIT, immutable ID/body reservation, original-ID resume
and bounded discovery after process loss. Item mutation, success/rejection receipt
and terminal intent finalize atomically. Other command paths respect pending
reservations; transient storage errors leave admitted work pending. Tests cover
actual producer-process termination, duplicate admission/resume, conflicts,
finalization rollback/retry, COMMIT unknown and bounded/int64 recovery pages.
Session/epoch authorization, World reconciliation, handoff and other domains
remain later P3 work; no live PostgreSQL route is enabled.

**P3c progress:** [Inventory session fence](../development/postgres-inventory-sessions.md)
adds an optional delegated grant projection, account-locked CAS epochs/revocation,
session checks before Inventory receipt/admission and an account-wide pending
recovery plus fresh-snapshot readiness barrier. Previously admitted work may
finish for its original character; results retain their captured context.
Native lock-order tests cover takeover/revocation races, stale contexts, alt
recovery, failed COMMIT without retry, reopen and int64 epochs. The privileged
grant API does not authenticate a Master ticket: the actual trusted issuer
bridge, World result filtering/reconciliation, handoff/pending Yang and other
domains remain open. No live PostgreSQL route or full C5 completion is claimed.

**P3d progress:** [World Inventory delivery](../development/postgres-inventory-runtime.md)
adds a bounded World-thread owner for discovery/resume, hydration into the actual
World equipment/stat cache, fresh-marker acknowledgement, and command delivery
after authoritative repair. Captured native peer/ticket identity plus local
binding generation suppress stale completions after disconnect/replacement.
Native tests cover independent progress during blocked SQL, rejection replay,
lost-interest takeover, snapshot freshness, and explicit original-ID recovery
after admission/mutation COMMIT uncertainty. This component is not wired into
live login/endpoints: trusted issuer delivery, endpoint/client/publication wiring,
other domains, handoff/pending Yang and P4 remain open. No backend switch.

**P3e progress:** [Master Inventory session bridge](../development/postgres-inventory-session-bridge.md)
connects the existing current Master ticket marker to an optional bounded control
owner: inspect/CAS grant COMMIT precedes authority-only World ticket delivery.
Native World authentication automatically attaches its delegated context; matching
disconnect/revocation and Master socket loss close that runtime ownership.
Tests cover old grant SQL finishing after a new login, failed COMMIT without token
publication/retry, real auth/relogin/revoke and the actual World combat projection.
Normal three-process SQLite item/reconnect regression also passes in a disposable
copy. This is not a playable PG backend selector: normal endpoint/client/public
publication wiring, other domains, cross-domain invalidation, indexed pending
discovery, pending Yang/handoff, operational bootstrap/shutdown and P4 remain open.

**P3f progress:** [Inventory endpoint/client flow](../development/postgres-inventory-endpoint.md)
routes existing native move/activate/equip/unequip and receipt RPCs through the
optional runtime. Stable client journal IDs survive lost replies, browser reload
and process/relogin recovery; terminal rejection can close its journal after
receipt confirmation. Current stats precede private Inventory/public weapon
publication, and receipt/no-op/rejection are not new commit facts. Separate native
client processes exercise the path on owned PG, including one blocked account
while another progresses. SQLite economics are unavailable through the Mandate
adapter in this opt-in mode; soft progression stays separate. Normal bootstrap
still uses SQLite. Other domains, cross-domain invalidation, indexed pending-only
discovery, pending Yang/handoff, operational lifecycle and P4 remain open.

**P3g progress:** [Inventory cache reconciliation](../development/postgres-inventory-cache-fence.md)
acknowledges post-command/receipt snapshots against the backend before reopening
local operations and publishing terminal results/change facts. Trusted committed
account markers close/gate stale views, coalesce a revision floor, and trigger
bounded asynchronous refresh; stale ACK delivery cannot override a newer notice.
Native tests cover external commits, lost notices before ACK, delayed ACK,
uncertain ACK COMMIT, churn limits and actual client/stat projection repair.
Other domains must still integrate their committed publishers. Cross-process
transport/missed idle facts, indexed pending discovery, pending Yang/handoff,
operational lifecycle and P4 remain open; normal startup stays SQLite.

**P3h progress:** [Indexed pending Inventory recovery](../development/postgres-pending-recovery.md)
adds transactional intent schema v2 with an account/sequence partial pending
index and session-qualified pending-only worker discovery. Runtime no longer
enumerates terminal history during recovery. Historical discovery, original-ID
outcome lookup and durable receipts remain intact; no history pruning or SQLite
migration. Native acceptance covers 10,034 terminal history rows, partial-index
plan, data-preserving v1 upgrade/failure rollback, paging/alt/session isolation,
and existing actual client recovery. Other runtime domains/bootstrap and P4 remain
open as detailed in the adoption table above.

**P3i progress:** [Wallet runtime](../development/postgres-wallet-runtime.md)
adds an optional account RAM owner, 30-second income batches with stable receipt
identity, pending-funded atomic test spend and bounded native worker execution.
Existing currency pickup/RPC/HUD and World lifecycle use the optional owner without
SQLite monetary fallback. Prefix reconciliation, lost successful completion,
COMMIT failure, same-account alt/relog recovery, offline dirty retention and forced
worker drain are covered. The existing real-client endpoint suite now also checks
PG wallet pickup/spend/process-relog and unchanged SQLite Yang. Normal startup
remains SQLite; production provisioning, item-dependent economic use cases,
cross-domain wallet publishers/freshness, transparent async CH/multi-World handoff
and P4 remain open. A synchronous transfer fails closed until its checkpoint is
settled; this does not implement distributed wallet ownership.
**P3j progress:** [NPC Shop and Upgrade runtime](../development/postgres-npc-runtime.md)
connects the existing authenticated endpoints and Web UI journals to bounded PG
execution. Current session fencing, atomic pending Yang/item/material mutations,
capture-token-qualified replay and Inventory/wallet reconciliation precede terminal
publication. Native tests cover lost completion/COMMIT, projection ACK repair,
capacity/independent progress and alt recovery; actual client processes cover
NPC range, Shop retry, Upgrade reload and purchase process-relogin recovery.
No server durable-admission queue, schema or protocol signature change is added.
Normal startup, shared Storage, other economic domains, distributed publication,
operational bootstrap/handoff and P4 remain open.

**P3k progress:** [Account Storage runtime](../development/postgres-storage-runtime.md)
adds optional bounded transfer/receipt execution with delegated session fences,
account-locked full footprints and combined Inventory/Storage snapshots. Current
revision ACK/reconciliation precedes terminal publication. Native acceptance covers
queue refusal, COMMIT/ACK uncertainty, independent accounts and original-issuer/alt
recovery; actual client processes cover lost reply, UI reload and journal relog.
No schema/protocol change, durable Storage admission, wallet mutation or bootstrap
switch. Ground-item initialization/pickup, Marketplace/Exchange/Auction runtime,
cross-process publication, operational lifecycle and P4 remain open.

**P3l progress:** [Initialization and ground items](../development/postgres-ground-items.md)
adds optional marker-based starter hydration and bounded native pickup execution
through the existing UID-only RPC. Grant/rights/range/liveness, global claim marker,
full bag/capacity and original rolled UID are preserved. Unknown COMMIT initiates
only read-only discovery; drop reservations survive pending SQL and reconcile
before terminal feedback. Native fault/race and six-client pickup/relog acceptance
pass. Normal startup, remaining Marketplace/Exchange/Auction runtime, operational
bootstrap/handoff, full PG combat acceptance and P4 remain open.

**P3m progress:** [Seller runtime](../development/postgres-seller-runtime.md)
connects optional list/edit/cancel/configure/item-claim RPC execution, current
session fences, native seller journals and account-scoped receipt discovery.
Private snapshots are reconciled against acknowledged Inventory before terminal
publication. Native faults/capacity/alt recovery and seven actual client processes
cover lost replies, reload/relog and saved-but-unsent explicit retry. Existing
claims pagination limits remain R6; buyer/proceeds settlement, Exchange/public
Auction, distributed publication, bootstrap/handoff and P4 remain open.

**P3n progress:** [Marketplace settlement runtime](../development/postgres-market-settlement-runtime.md)
connects optional buy/partial proceeds collection with current session fences,
captured-income receipt tokens, buyer Inventory/wallet reconciliation and
online seller private refresh. Public shop visits use bounded native execution;
Auction catalog/search remain unsupported on this optional path. Client journals
cover lost replies, reload/relog and retry after an offer disappears. Monetary
uncertainty prevents safe shutdown until read-only discovery resolves the prefix.
Normal startup, Exchange, cross-process publication, bootstrap/handoff and P4
remain open.

**P3o progress:** [Exchange ledger runtime](../development/postgres-exchange-ledger-runtime.md)
connects optional session-qualified deposit/withdraw to the existing native owner,
combined Inventory/Storage and private Exchange projections, durable client IDs
and explicit receipt-first retry. Native conversion faults/alt recovery and nine
actual clients cover lost reply, reload/relog and saved-but-unsent intents.
Order/matching writes, multi-party reservation/freshness, public Auction, bootstrap
and P4 remain separate; normal gameplay stays SQLite.

**P3p progress:** [Exchange matching runtime](../development/postgres-exchange-matching-runtime.md)
connects optional order/cancel/matching through prepare/capture/revalidate, existing
atomic price-time transactions and per-account income tokens. Account wallet fences
cover late login, World-local generations refresh participant ledger projections,
and native journals recover lost reply/relog without automatic mutation replay.
Ten actual clients retain prior contracts and add fill/reserve/cancel recovery.
Public Auction, bootstrap, distributed publication and P4 remain open; normal
startup stays SQLite. No schema or public RPC signature changes.

**P3q progress:** [Auction runtime](../development/postgres-auction-runtime.md)
adds optional catalog/search RPC delivery through the existing bounded native
pool. One active search and bounded per-account queue/rates apply across maps.
Current delegated session authorizes the read, rows project on World, and RPC IDs
deduplicate before validation/limiting. Timeout retains its native slot, stale
sessions suppress delivery and drain joins no active SQL. The native 10k fixture
records worker latency/World physics gaps; actual client/browser coverage retains
prior economic guarantees. No schema/backend switch; operational bootstrap,
full PG gameplay, distributed publication and P4 remain open.

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
