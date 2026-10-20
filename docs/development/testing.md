# Prototype testing policy

Accepted 2026-10-09: keep a small set of stable regression contracts during rapid
prototyping. A tiny UI/style or balance change should not require repairing a
browser screenshot, a specific DOM tree or a combat animation timeline.

## Contracts before implementation

Accepted 2026-10-12: test contracts and observable behavior. Inspect internals only
for a concrete bug or a critical invariant that cannot reasonably be checked
from outside.

Prefer, in order:

1. Existing behavior suites and their scenarios.
2. New integration coverage when the affected contract is not already covered.
3. Focused implementation unit tests when they are needed to isolate the risk.

Add or extend a test only when there is a new contract, a concrete bug, a critical
invariant, or a risk the current suites do not cover. Name that risk and explain
the coverage gap in the test/comment or change description. A new class or an
extraction alone does not justify new tests. Do not duplicate integration coverage
with assertions that mirror method calls, private maps or class layout.

For economy changes, prefer results: new item/stats and wallet balance after a
commit, the private Inventory received by the client, subsequent damage using the
equipped stats, and unchanged state after rollback. Do not encode the order of
refresh_authoritative_state versus a signal subscriber as the acceptance test.
A public change fact is a contract; its subscriber registration order is not.

For Package B, protect PlayerCombatRuntime and the service/actor extractions
primarily with existing ACTION, FEEL2, combat and network suites. Extend those
scenarios if a risk is uncovered. New focused unit cases may be justified for
buffered intent, cancel, hitch-safe impact, or cleanup after remove/death, but
should not repeat coverage merely because ownership moved to another class.

During extraction, use existing suites first. Add a test only when the extraction
exposes a concrete behavioral contract not actually covered today. Full line/path
coverage for PlayerCombatRuntime or each extracted class is not a goal.

Existing tests are regression evidence, not immutable API. During extraction,
preserve behavioral contracts, but freely rewrite or remove tests that assert
obsolete private state, implementation order, or ownership. Do not preserve old
internals solely to keep a test green. Controlled fixture setup may change with
the owner; a removed assertion still needs a reason grounded in the contract,
rather than removing a genuine behavior regression to make the suite pass.

Test setup may seed SQLite or configure a controlled actor. That does not make
private state or the setup mechanism the expected production behavior. Internal
probes need a specific justification; for example, the known Inventory publication
coupling regression checks that publication cannot refresh combat cache, and the
RAM-only swing invariant checks that an attack does not read SQLite Inventory.
Keep such exceptions narrow and separate from ordinary success/rejection checks.

## Default

```powershell
git diff --check
& ./tests/run-smoke.ps1
```

Godot 4.7.2 and Node 20.19+ are required. Run `npm ci --ignore-scripts` in
`source/client/ui_web` once for the pinned compiler and test dependencies.
Smoke compiles TypeScript and tests the emitted static browser JS. `-NodeExecutable` can select a bundled Node.
No running server, browser, GUI, network port or production accounts are required.
The smoke suite does not install/download CEF. Installing CEF is optional; installed CEF loads in headless without
creating a browser. The suite has six small SQLite scenarios, one NPC content/context fixture and one bridge contract group:

- Item identity, ownership, revisions, atomic equip/move and rollback/reopen.
- Inventory footprints, page bounds, overlap and atomic legacy migration.
- Pickup identity, full bag, double pickup and partial-write rollback.
- XP/level RAM updates and dirty checkpoints, including forced save and crash window.
- Wallet deltas, immediate critical spend, rollback/checkpoint and relog.
- NPC Shop offer/stack invariants, exact/first-fit purchase, capacity-before-charge,
  pending Yang, rollback and durable item identity.
- Neutral NPC definitions, service references, map/range/context authority and teardown.
- Bridge framing, explicit command boundary, readiness, request correlation and
  full snapshot recovery; small Core UI lifecycle, skin and icon contracts.
  No browser rendering or network fixture is involved in default smoke.

Successful runs delete their disposable databases and overwrite a small fixed
set of logs under `.godot/verification`. Failed runs retain diagnostic state.
These tests intentionally protect persistence and authority, not prototype visuals.

## Optional integration

PostgreSQL P1a is opt-in: `python tools/postgres/run_readiness.py` starts only a
fresh owned loopback cluster, checks native SOCI transaction/type/independent-session
contracts and stops/removes its data directory. Install binaries with
`python tools/postgres/setup.py` or pass `--pg-bin`; pinned SOCI must be installed.
It does not use port 18098 or player data, and is absent from default smoke/CI.
See [setup, safety and verification limits](postgres-readiness.md).

Wallet backend parity uses the same owned runner with `--suite wallet`; pass
`--pg-bin 'Y:/Software/PostgreSQL/bin'` to use an installed binary directory while
still creating a fresh disposable cluster. See [wallet parity](postgres-wallet-parity.md).

`--suite npc-shop` compares the existing SQLite NPC purchase with the PostgreSQL
port, including custody/receipts, full bag, exact target replay/reopen, SQL and
COMMIT failures, and integer watermarks above 2^53. This remains opt-in, with no
PostgreSQL dependency in default CI. See [NPC purchase parity](postgres-npc-shop-parity.md).

`--suite inventory` compares character-local move/equip/swap/unequip/activate,
starter initialization and ground pickup against SQLite, including durable
receipt replay/reopen, full bag, partial-write rollback and native COMMIT faults.
It is opt-in and does not switch World to PostgreSQL or cover account Storage.
See [Inventory parity](postgres-inventory-parity.md).

`--suite storage` compares account-shared deposit/move/withdrawal with SQLite and
checks independent native sessions competing for one UID, shared cell and command
ID. It covers provenance, account/character/kind isolation, partial-write/COMMIT
faults, full destinations and replay/reopen. The populated schema upgrade must
preserve existing Inventory. This remains opt-in; no PostgreSQL service is needed
by default CI. See [Storage parity and limits](postgres-storage-parity.md).

`--suite upgrade` compares the current atomic +0 to +1 Upgrade with SQLite:
whole/partial materials, pending/reserved Yang, target and receipt rollback,
replay/reopen, ineligible Storage/alt materials and exact issuer/revisions.
It remains opt-in, on fresh owned clusters. The current two-client Upgrade
runtime stays on SQLite. See [Upgrade parity](postgres-upgrade-parity.md).

`--suite shop-seller` checks PostgreSQL/SQLite seller lifecycle parity: listing,
offer/Shop edit, direct Inventory withdrawal, escrow/occupied-cell/receipt
atomicity, negative-cache bounds and reopen. Native overlapping sessions cover
footprint conflict and single-transfer/cross-alt replay. Purchases, claims,
revenue and Auction search are outside this fixture. See
[seller parity and limits](postgres-shop-seller-parity.md).

`--suite shop-settlement` compares fixed-price purchase, offline seller revenue
and partial wallet collection against SQLite, including pending income,
reservations, full bag, overflow, statement/COMMIT faults and receipt recovery.
Independent native sessions cover double-buy, buy/cancel/edit, additive sales,
same-ID buy/collect and reciprocal account locking. It is opt-in and does not
switch World or complete the broader concurrency/load gates. See
[settlement parity and limits](postgres-shop-settlement-parity.md).

`--suite account-claims` compares private/public Shop projections and account claim
receiving against SQLite: original UID/metadata/revisions, full footprint/capacity,
receipt/reopen, SQL/COMMIT rollback, provenance constraints and independent alt/
receiving conflicts. It also checks coherent public reads across native writer
commits and private account-data isolation. It preserves the 200-claim window and
does not switch runtime. See [claim parity and limits](postgres-account-claims-parity.md).

`--suite auction-search` compares complete SQLite/PG query rows and cursors across
filters, ties, negotiable listings and pagination, plus atomic affix backfill/
mutation/recovery and a read-only native session. Its 10k active-offer observations
are synchronous SQL/projection measurements, not World/concurrent-load evidence.
Production remains on the existing async SQLite reader. See
[Auction parity and limits](postgres-auction-search-parity.md).

The existing `--suite shop-settlement` also covers P2c bounded whole-operation
retry on the published SOCI v0.4.3 payload. Server-injected statement SQLSTATEs,
independent concurrent offer edit, pending-income/receipt invariants, attempt caps,
COMMIT phase and failed-cleanup recovery are checked. `--suite commit-failure`
additionally proves structured fields and local flag versus PostgreSQL state after
aborted/deferred COMMIT. No retry/pool is added to World or default CI. See
[settlement retry](postgres-transaction-retry.md).

`--suite inventory-concurrency` is the opt-in P2 cross-operation custody check:
cross-alt receipts, equip/list, move/deposit/conversion, full-footprint overlap,
last-space receiving, starter/pickup and global UID uniqueness. Independent native
sessions and original-store A/B cover the conflict boundary; no DOM, animation or
PostgreSQL runtime dependency is added to smoke. See
[Inventory concurrency](postgres-inventory-concurrency.md).

`--suite wallet-concurrency` is the opt-in P2 cross-operation shared-account check:
NPC/Upgrade spends, Exchange reservations, partial collection, receipt conflicts,
checkpoint lock ordering and known-rollback original-ID recovery. Native sessions
overlap at real database lock barriers; the checkpoint/matching regression also
fails against the pre-fix store. This is not a load or PostgreSQL World test.
See [shared wallet concurrency](postgres-wallet-concurrency.md).

The same fixture also covers Player Shop purchase versus Exchange reservation/
immediate fill, concurrent sale/partial collection, and independent Shop/Exchange
completion while another account's purchase remains blocked. The full opt-in
[P2 backend acceptance matrix](postgres-concurrency-acceptance.md) maps these and
the domain fixtures to the migration gate; it is not added to default CI.

`--suite inventory-executor` verifies the opt-in P3a full-transaction worker
boundary: blocked native SQL versus SceneTree progress, independent completion,
bounded buffered/unconsumed work, replay/discovery, COMMIT unknown/reopen,
timeout recovery and clean drain/restart. It is not World/session fencing or a
production PostgreSQL switch. See [Inventory execution](postgres-inventory-executor.md).

`--suite inventory-intents` verifies P3b durable Inventory admission/recovery:
an owned child process terminates after admission COMMIT; another owner discovers
and resumes its random ID. It also covers concurrent resume/admission, reserved-ID
conflicts, atomic terminal success/rejection, storage/COMMIT failure containment,
pending bounds and paged/int64 discovery. All SQL uses the owned fixture cluster.
See [Inventory identity/recovery](postgres-inventory-intents.md).

`--suite inventory-sessions` verifies P3c's opt-in delegated Inventory grants:
CAS epochs/revoke replay, queued admission versus takeover/revocation, stale
contexts, account-wide recovery without retargeting the original character,
fresh-snapshot readiness, failed COMMIT without automatic retry, reopen and
native int64 epochs. It models already verified Master grants; it does not test
an actual issuer bridge or enable live PostgreSQL sessions.
See [Inventory session fence](postgres-inventory-sessions.md).

`--suite inventory-runtime` verifies P3d's World-thread Inventory owner with real
PostgreSQL and the production World combat projection: recovery before readiness,
equip/unequip and rejection repair, physics/independent progress during blocked
SQL, takeover/disconnect stale delivery, fresh-marker repair and explicit same-ID
recovery after admission or mutation COMMIT uncertainty. Its peer maps are seeded;
the separate native World session fixture checks the ticket fingerprint helper.
See [Inventory runtime](postgres-inventory-runtime.md). Neither fixture enables a
live PostgreSQL backend or proves the complete three-process PG login path.

`--suite inventory-session-bridge` verifies P3e's optional Master control owner
and native World attachment over actual RPC/auth sockets: current issuer identity,
old grant SQL finishing after supersession, grant COMMIT before ticket delivery,
native relog/disconnect/revoke, COMMIT unknown without automatic grant retry and
Master socket loss. It shares ports 18098/18099; run sequentially with network
suites. Gateway credentials/entry initiation and roster/UI setup are controlled.
See [Inventory session bridge](postgres-inventory-session-bridge.md) and its
separate three-normal-process SQLite `run-items -WithSession` regression evidence.

`--suite exchange-orders` compares SQLite/PG reservation, maker-price matching,
partial fills, cancel/refund, snapshots, original receipts and conservation. Native
independent sessions cover two takers, cancel/fill, duplicate commands and shared
accounts across two books; statement/COMMIT faults, reopen, overflow and limits
are opt-in. World stays on SQLite; no default CI dependency or PostgreSQL network
claim. See [order settlement parity](postgres-exchange-orders-parity.md).

`--suite exchange-ledger` compares Inventory/Storage stack conversion into account
balances and Inventory/claim withdrawal against SQLite. It covers original UID
replay, free/reserved/cap bounds, statement/COMMIT rollback/reopen and independent
alt/Storage-transfer conflicts. It does not implement order reservation/matching
or switch runtime. See [ledger parity and limits](postgres-exchange-ledger-parity.md).

The existing headless gameplay/network runners remain available on demand:
`run-spike3d`, `run-pve`, `run-combat`, `run-progression`, `run-xp`, `run-yang`,
`run-web-inventory`, `run-npc`, `run-shop`. Choose the affected flow for movement/combat/XP/wallet/RPC
changes; do not run all of them after CSS edits. They share port 18098: run
sequentially. `run-items.ps1 -WithSession` requires normal gateway/master/world
roles and writes guest fixture accounts; use it for actual session/login changes.

`run-combat.ps1 -Scene local_map_instances -MarkerPrefix LOCAL_MAP` also covers
local CH transfer: reservation/cancel, combat/movement/drain and checkpoint abort,
new Inventory/currency mutation gates, real two-client map recreation with retained
HP/options/XP/Yang and lost-response Inventory journal/receipt recovery across CH.
The `MANDATE_TEST_RESERVED_ENTRY=1` variant checks that private source copies cannot
use public handoff. `world_session_admission` covers actual native relog during a
countdown and bounded post-fence loading failure/relogin. No new default suite or
timing/balance assertion is added.

`run-first-region.ps1` loads the production graybox scene headlessly and checks
connected navigation to NPC/pack/Metin sites, safe hub spawns, authored composition
and the shore boundary. It opens no window and does not assert exact
layout or balance. See [region notes](../world/first-region-graybox.md).

Default smoke also covers mixed mob packs, shared aggro, anchor leash, unique
replacement IDs, Metin pack expiry, a short 50-actor AI tick, compact mob wire
round trips and serialized payload measurements for 50/100 actors. See [mob packs](../gameplay/mob-packs-v1.md).

`run-metin.ps1` covers the small stone lifecycle contracts.
`run-metin-network.ps1` is the optional two-client production encounter/ground
reward/cleanup/respawn flow with disposable SQLite on port 18098; run sequentially
with other PvE network suites. Neither opens a native window.

`run-cef-export.ps1` is an optional packaging-boundary check after addon/export
changes: client Web assets and CEF registration, CEF-free server packs and
client/server pack headless boot (including real client UID validation without
SQLite). It requires the local CEF installation and opens no windows.

`run-core-ui-browser.ps1` is an opt-in [Core UI milestone check](../ui/core-ui.md)
using the production page, controlled IPC and an installed headless browser.
It checks behavior and broad bounds, with no pixel/exact-tree assertions or downloads.
It does not replace native root-client CEF verification.

`run-shop-browser.ps1` is the analogous optional [NPC Shop view check](../gameplay/npc/npc-shop.md).
Pass the installed `-PlaywrightModule` and `-BrowserExecutable`, and optionally
`-ScreenshotDirectory`. It verifies rendered skin/fallback, broad frame bounds
and Shop/Inventory placement, mouse purchase gestures, tooltip, catalog pages
and close/Escape with controlled IPC; no game accounts or running servers. It also
checks [Upgrade](../gameplay/npc/npc-upgrade-ui.md): server-driven item selection/commit/rejection,
a +0 → +1 snapshot and an explicit execute command without optimistic mutation.
The separate developer page retains visual level controls.

Asset pipeline tests and visual fallback probes remain optional for pipeline
changes. The small default suite downloads no browser and does not install Pillow.

The old CEF spike, its mock/diagnostic adapter, its renderer/measurement runners
and the exact-layout browser matrix test were removed. The original adoption
results belong to the retired CEF spike (recoverable from Git history). The inventory
resolution matrix is a manual milestone checklist in [UI Contract v1](../ui/ui-contract.md),
not a pixel-sensitive CI assertion. Use the root client for CEF/input/
resize/transparency/shutdown checks; no parallel standalone UI mock.

## CI and cleanup

Push/PR CI installs the pinned Web UI development dependencies, compiles TypeScript,
checks that committed runtime assets match their source, imports a clean checkout,
checks whitespace and runs smoke.
Workflow dispatch can opt into extended gameplay/asset checks. Local execution
verifies the scripts; it does not prove the remote Actions run until published.

```powershell
& ./tools/clean-dev-artifacts.ps1 -WhatIf
& ./tools/clean-dev-artifacts.ps1
```

Cleanup removes `.godot/verification`, retired spike/copied-client caches and the named old
scratch files, within checked workspace paths. It preserves `.godot/imported`,
editor cache, engine binaries, the installed root CEF addon/plugin archive cache, reference
checkouts, local asset cache and normal player/account data. Temporary work should
live under `.godot/verification`, rather than accumulating at the .godot root.

`run-upgrade.ps1` is an opt-in two-client production Upgrade RPC suite on port
18098; run sequentially with the other PvE-derived suites. Smoke includes one
material/item/wallet rollback fixture and small UI/bridge contracts.

`run-camera.ps1` is the optional headless Camera v1 collision/picking fixture.
See [Camera v1](../gameplay/camera-v1.md) for the native input/framing acceptance checklist.

Hit reaction smoke covers profiles, flinch without locks, bounded knockdown/get-up,
independent displacement resistance, damped impulses and real scenery collision,
interrupt independence and snapshot recovery. `run-combat` exercises the same
authority with two clients, including the player-target pending-hit path. See
[Hit Reactions v1](../gameplay/combat/hit-reactions-v1.md).

Warrior combo v2 reuses the durable `hit_reactions` smoke case for exact 4/5/6
sequence and runtime reset contracts. `run-combat.ps1` verifies four/six native
animation keys at both real clients, plus pending-toggle/interruption behavior.
The optional [combo review](../gameplay/combat/warrior-basic-combo-v2.md#verification-and-remaining-manual-review)
uses the existing Warrior compatibility scene; rendered images are disposable
verification artifacts, not snapshot assertions in smoke.

`run-combat-trace.ps1` is the optional geometry plus two-client 50/100-target
Warrior trace contract suite. It uses port 18098; run sequentially with PvE suites.
`run-combat.ps1 -LegacyMelee` covers the retained fallback. Bake/native comparison
commands and verification limits are in [Warrior Combat Trace v1](../gameplay/combat/warrior-combat-trace-v1.md).

`run-combat.ps1 -Scene combat_feel_v2 -MarkerPrefix FEEL2` is the opt-in two-client
Attack Speed/buffer/facing and pooled confirmed-feedback contract check. Native
AS 100/122/150 and four/five/six-hit preview commands and verification boundaries
are in [Warrior Combat Feel & Presentation v2](../gameplay/combat/warrior-combat-feel-v2.md).

`run-combat.ps1 -Scene warrior_action_polish -MarkerPrefix ACTION` covers late
scheduled impacts, full-motion movement locks, authoritative forward advance and
scenery collision, visual turn blending, local finisher impulses and reusable
trail resources. Preview controls and authoring sources are recorded in
[Warrior basic action polish](../gameplay/combat/warrior-action-polish.md).

The same ACTION suite also checks full-motion advance versus interrupted chaining,
asymmetric movement BODY blocking, existing-overlap escape and finisher knockback
freeing space. The actual-physics native volume preview and measurements are in
[Warrior BODY collision](../gameplay/combat/warrior-body-collision.md). These checks remain opt-in.

`run-visual-v0.ps1` is an optional native Windows/Vulkan/CEF feasibility pass for
Mobile and Forward+ on the production First Region scene. It reuses the isolated
PvE fixture (port 18098, run sequentially), real production Web UI and server RPCs.
It protects renderer migration against missing/black CEF output, broken native
synthetic input/drag/orbit, lifecycle recovery and NPC transactions; headless
bridge/Node suites cannot exercise the native accelerated texture or GPU path.
Logs, captures and a short timing sample remain ignored under `.godot/verification`.
No pixel snapshots or balance/timing assertions are added to smoke. Physical
mouse/keyboard, DPI/alt-tab, feel and release executable packaging remain separate.
See [Visual V0](../world/visuals/visual-upgrade-v0.md) for commands and current evidence.

The same runner's `-Scene visual_v1 -RenderingMethod forward_plus` reuses that
native pass and adds four before/after world views in a separate SubViewport.
It checks the new fixed-time contract across real rendered frames and confirms
that the actual server omits the Sky3D environment. There are no image assertions:
captures support manual review of the lighting milestone. See [Visual V1](../world/visuals/visual-upgrade-v1.md).

`run-combat.ps1 -Scene world_time_network -MarkerPrefix WORLD_TIME` reuses the
two-client fixture for shared authoritative calendar, late entry, epoch recovery,
extrapolation/resync, midnight and malformed/stale/delayed sample contracts.
Existing gameplay suites do not cover calendar synchronization. Run sequentially
with other port-18098 fixtures. `run-visual-v0.ps1 -Scene visual_v2
-RenderingMethod forward_plus` adds a full-day continuity review, nine hour views,
moon/stars and 91 native timelapse frames to the existing CEF/transaction pass.
There are no pixel baselines. See [Visual V2](../world/visuals/visual-upgrade-v2.md) for artifacts,
optional GIF encoding and verification boundaries.

`run-visual-v0.ps1 -Scene visual_v3 -RenderingMethod forward_plus` adds paired
water review views, day/sunset/night/moon lighting, close/distant/production-camera
motion captures and paired GPU samples to the existing CEF/transaction pass.
Shader compilation errors fail the native runner. No pixel baselines are added:
headless suites cannot establish screen/depth sampling or temporal appearance.
The existing `run-first-region.ps1` protects shore blocking/navigation. See
[Visual V3](../world/visuals/visual-upgrade-v3.md) for configuration, artifacts and limits.

Marketplace E0a adds `run-account-identity.ps1`: real populated SQLite migration,
rollback/reopen, unique account mapping and verified handoff/session ownership.
`-WithSession` uses the normal local Classic Gateway/Master/World and creates two
accounts/four characters, exercising registration/login, guest flow, spoof
rejection and real World token entry. Existing item-session regression remains
`run-items.ps1 -WithSession`. These opt-in checks protect a previously uncovered
authentication/ownership boundary; see [E0a identity](../marketplace-e0a-identity.md).

`run-market.ps1` starts the opt-in marketplace SQLite behavior suite: migration,
canonical custody/claims and durable command receipts, including direct SQL
constraint bypass attempts and fault injection. E1a coverage protects new
economy contracts; it is not line coverage of a store extraction. See
[E1a custody](../marketplace-e1a-custody.md). Existing smoke/network item suites remain
the regression baseline and seed complete transactions under custody constraints.

## Marketplace integration checks

Use run-market.ps1 -Scene market_custody / market_purchase / market_search /
exchange_ledger / exchange_orders with the corresponding *_OK marker. These isolate
real SQLite. run-market-recovery.ps1 exercises a disposable process crash and WAL
restore. Optional run-combat.ps1 -Scene market_race -MarkerPrefix MARKET_RACE and
-Scene exchange_network -MarkerPrefix EXCHANGE_NETWORK share port 18098: sequential.
-NativeClient1 opts into the offscreen Vulkan Mobile/CEF market milestone.
The production Chrome milestone is source/client/ui_web/test/market_browser.mts
(after build-web-ui.ps1 -Tests); it covers UI commands/reload and all 10 scales.
Run normal-role account/item session suites sequentially too: their avatars share
one live world. Full item relog validates its own public actor, so another fixture
finishing earlier cannot hang it. Do not run native milestones for routine styles.

The historical R0–R2 synchronous `market_load` path is replaced by D2's production
async reader fixture. Run `run-web-inventory.ps1 -Scene market_load`, or
`python tests/run-auction-load.py --godot /absolute/path/to/godot` on Windows/Linux.
It uses 60 Hz/60 FPS, two real RPC clients and sixteen explicitly simulated account
sources over 10k offers, concurrent combat/AI and atomic mutations, saturation,
active-traffic backup/reader restart and real reconnect. It reports queue-inclusive
latency, worker round-trip (not native SQL), poll/projection costs and tick intervals.
Numbers are review observations, not fragile exact-ms assertions. Existing
`auction_queries` covers expiration/late results/fairness; `market_recovery` now
covers an owned process crash during async traffic and reader restart against
recovered WAL. See [D2 observations and gates](../marketplace-auction-d2.md). Existing
custody/order suites protect rejection-spam row count, bounded negative cache,
conflict, rollback and durable replay.


Gateway A1 adds the socket-free `gateway_lifecycle` case to
`run-account-identity.ps1`: bounded pending work, stale reply/timeout cleanup,
Master disconnect, Gateway credential expiry/replacement/revocation. See
[Gateway lifecycle](gateway-lifecycle.md) for guarantees and live-test boundaries.


World A2 adds an opt-in two-client ingress regression to the existing network
runner: `run-combat.ps1 -Scene world_rpc_admission -MarkerPrefix WORLD_RPC`.
It checks authenticated identity, literal operation admission and own-instance
routing with real RPCs, no DB or windows. See [World RPC admission](world-rpc-admission.md).

`run-account-identity.ps1` also includes `world_session_admission`: real loopback
native authentication, bounded/expiring single-use tickets, account replacement,
half-open handshake and Master notification fencing against disposable SQLite.
It shares port 18098 with the network suites: run sequentially. This specifically
covers native auth ordering, which A2's prebound RPC fixture does not exercise.
See [World session admission](world-session-admission.md) for scope and deployment.

The same account runner includes `master_entry_attempts`: actual Master result
RPCs delivered out of order, superseded logins/enters/creation, duplicate replies
and reused request IDs. This protects token issuance ordering, which a fixture
calling only `register_world_session` cannot cover. For login/session changes,
also run `run-items.ps1 -WithSession` against normal Gateway/Master/World roles;
the 2026-10-15 isolated full-process result is recorded in the session admission doc.


`run-web-inventory.ps1 -Scene storage_recovery` is the opt-in shared-account
Storage regression. Two distinct fixture characters compete for one UID, while
lost responses, fresh controller/independent-process journal recovery and
crash-before-send discovery exercise receipt-only restart and explicit Retry.
It checks current account fanout, a single receiving character, no extra mutation
facts on replay, and DB reopen. It shares port 18098: run sequentially with other
PvE-derived fixtures. No change to production simultaneous-login policy or native
CEF/input coverage is implied. Existing item_instances adds atomic receipt/custody
rollback and issuing-character isolation; Web contracts cover Retry after the
original item left Storage, without placement-dependent UI gating.


Durable item revision coverage stays in existing suites. Smoke/item_instances
protects same-transaction watermark/receipt rollback, account scope, no-op/replay,
populated migration/retry and exact int64 receipt/reopen. Web Inventory network
rejects old durable item state even with a newer delivery sequence. run-progression
also checks stale/duplicate World combat cache updates, retained watermark after
failed refresh, current-state rehydration and no SQLite inventory reads per swing.
No native window, timing assertion or new default suite is required for this change.


Wallet revision/reconciliation coverage extends yang_wallet (part of smoke),
yang_network (run-yang), market_purchase and exchange_orders. It protects late
income preservation, duplicate/older results, both-account preparation before
facts, atomic revision rollback, reservation-only changes, migration/retry and
int64 receipts. The existing Yang network flow also rejects stale durable state
with newer delivery, stale same-revision display and wrong account scope. These
are contract tests; no new suite, pixel baseline or exact timing assertion is added.

The optional auction load runner also records economic COMMIT, projection and
RPC enqueue stage costs. `--without-projection-indexes` selects an A/B baseline
only in the disposable fixture; run it sequentially with the default indexed
cohort. Existing `market_custody` verifies additive read-index failure/retry and
reopen. See [projection budget evidence](economy-projection-budget.md); no timing
threshold or additional default test suite is introduced.

Shop revenue extends existing market_purchase (sale/partial collection, pending
income, int64 display, atomic SQL faults and replay/reopen), market_network (lost
response, fresh UI, independent-process journal and unknown-receipt explicit
retry), market_recovery (sale and partial collection recovered from WAL), and
market_load (explicit collection plus wallet/revenue conservation). The existing
headless Chrome market_browser milestone checks exact decimal display and Collect
/ Retry commands with the normal scale matrix. No new default suite or native CEF
coverage is implied. See [Shop revenue](shop-revenue.md).

`run-combat.ps1 -Scene local_map_instances -MarkerPrefix LOCAL_MAP` is the opt-in
live isolation check for two copies of First Region. It uses the production
InstanceManager, map loader, initial assignment and client entry RPC, real physics
spaces, foreign/duplicate joins and gameplay RPC attempts, local mobs/Metin waves/
loot and one cross-copy Marketplace sale against disposable SQLite. It also
covers session revocation during map loading. This contract was not covered by
the existing single-map PvE or admission-only fixture. Run sequentially with other
port-18098 suites. The full `run-items.ps1 -WithSession` compares durable item
fields across relog; public roster size depends on initial map assignment and
live delivery versions need not survive re-entry. See [local instances](local-map-instances.md).

The same local-instance fixture covers capacity including pending places,
non-renewing deadlines, stale-session callbacks, draining reservations/members and
idle retirement. `world_session_admission.tscn` additionally uses native authenticated
sockets to reject a full map, time out a loading client, checkpoint XP/Yang and
relogin into reclaimed capacity. This controls Master transport and client loading,
not the actual World authentication/disconnect path. See
[bounded map admission](instance-admission-lifecycle.md).

The existing `local_map_instances` fixture also covers PUBLIC/RESERVED access.
Run its normal two-public-copy case, then repeat with
`MANDATE_TEST_RESERVED_ENTRY=1` in the runner environment (restore/unset it after
the command). This test-only variant routes the first authenticated client into
a server-reserved copy and the other into public capacity. Both use real manager
publication, client loading and join RPCs; foreign join/movement/combat/pickup,
isolated simulation and cross-copy Marketplace settlement remain checked. Direct
admission cases additionally cover invalid membership, wrong manager, revocation,
pending-target replacement and private retirement for shared startup content.
No production map or party flow enables reserved entry by default. See
[instance access](instance-access-policy.md).

The same fixture covers bounded public provisioning with controlled monitor inputs
for headroom/staleness/stalls, count caps, loading/burst/settling and idle retirement.
It also records actual physics/process p95 on the live First Region copies. Only
the normal fixture temporarily permits a diagnostic third public copy; its creation
may be denied by real headroom and no timing value is an acceptance assertion.
Production First Region remains capped at two. See
[provisioning observations](bounded-channel-provisioning.md).

Initial CH selection reuses those fixtures: local_map_instances now selects CH1/
CH2 via real catalogue/choice RPCs and checks no transfer/disconnect from a joined
actor's selector request. Native world_session_admission covers an authenticated
client waiting at the picker, refresh without reservation/deadline renewal, and
expiry cleanup. `run-items.ps1 -WithSession` retains programmatic automatic mode.
Visual QA of the existing pre-world Transition picker is separate from these
network contracts; see [initial channel selection](initial-channel-selection.md).

PostgreSQL P3f `--suite inventory-endpoint` adds native Inventory RPC/client journal
acceptance with separate headless client processes, current Master tickets and
World runtime on owned fixtures. It uses ports 18098/18099 sequentially. See
[scope and failure/recovery behavior](postgres-inventory-endpoint.md). No CEF
rendering or production bootstrap/cutover is claimed.

P3g extends the existing PG runtime/endpoint suites with committed cache
invalidations, post-command and delayed-ACK freshness, ACK COMMIT uncertainty,
bounded repair and RAM-only combat input gating. No new default suite. See
[cache fence contract and limits](postgres-inventory-cache-fence.md).

P3h uses the same four PG intent/session/runtime/endpoint suites to verify
pending-only recovery, transactional v1-to-v2 index migration with data, retained
history/receipt lookup, int64 cursors and the partial-index plan against 10,033
terminal records. It adds no default suite; see [pending recovery](postgres-pending-recovery.md).

## PostgreSQL wallet runtime (P3i, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite wallet-runtime`
uses a fresh owned SCRAM cluster. It covers RAM-only ground currency, captured
income prefixes, independent-account progress under SQL locks, pending-funded
spend, reservations, successful COMMIT with lost completion, native failed COMMIT,
same-ID scheduled retry, alt/relogin, offline dirty retention after revocation,
forced worker drain and wallet recreation. The existing `inventory-endpoint`
suite additionally checks actual client currency RPCs/snapshots and process relog,
with unchanged SQLite wallet rows. These are optional suites, not added to smoke.
See [wallet runtime](postgres-wallet-runtime.md) for the supplied fixture boundaries
and remaining production/multi-World adoption work.

## PostgreSQL NPC runtime (P3j, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite npc-runtime`
uses owned disposable PG workers to check pending-income/item/material atomicity,
receipt replay with later income, full native capacity, independent accounts,
lost successful completion, native failed COMMIT, projection ACK repair, alt
takeover and graceful drain. The extended `inventory-endpoint` suite additionally
uses four actual client processes and the production Web UI bridge/adapters for
NPC range checks, Shop retry, Upgrade reload and purchase process-relogin recovery.
No default CI expansion or physical CEF validation is implied. See
[NPC runtime](postgres-npc-runtime.md) and its evidence for the precise boundaries.

## PostgreSQL account Storage runtime (P3k, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite storage-runtime`
checks session-qualified account Storage, full footprints, independent progress,
queue refusal, native COMMIT/ACK failures, replay and original-issuer/alt recovery.
It uses real native workers/World and fixture session maps. `--suite storage`
retains the existing independent-session transaction/custody concurrency checks.

`--suite inventory-endpoint` now includes Storage RPC/bridge/journal lost reply,
`ui.ready`, client-process relog and private account snapshots, alongside prior
Inventory, wallet and NPC contracts (five real headless client processes). Run
sequentially with other suites using ports 18098/18099. `run-web-inventory.ps1
-Scene storage_recovery` preserves the existing SQLite client recovery contract.
See [Storage runtime](postgres-storage-runtime.md) for verified/deferred boundaries.

## PostgreSQL starter / ground items (P3l, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite ground-runtime`
uses real native workers, current World cache and controlled actor maps to verify
starter marker recovery, pickup rights/reach/liveness, bounded queue/refusal,
full bag, competing UID, native failed COMMIT and original-issuer recovery.
`--suite inventory` and `--suite inventory-concurrency` retain existing backend
parity and independent-session initialization/claim races. `--suite inventory-endpoint`
now includes the UID-only pickup RPC and a sixth actual client restoring the
saved drop after process relog; run sequentially with other 18098/18099 suites.
The economic network map suppresses combat simulation/rendering; `run-combat.ps1`
remains the existing server/two-client combat/pickup regression on SQLite.
See [ground-item runtime](postgres-ground-items.md) for explicit scope limits.

## PostgreSQL seller / item claims (P3m, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite seller-runtime`
checks all five seller-local operations, session fences, capacity/independent
progress, native mutation/ACK COMMIT failures, account-scoped receipt replay,
alt recovery, cross-domain snapshot freshness and graceful drain. Existing
`--suite shop-seller` and `--suite account-claims` preserve transaction acceptance.

`--suite inventory-endpoint` now runs seven actual headless clients, adding seller
lost-reply retry, UI recreation, claim process-relog and saved-but-unsent explicit
retry through production RPC/bridge/adapters. Run sequentially with 18098/18099
suites. `run-web-inventory.ps1 -Scene market_network` checks the existing SQLite
path. No physical CEF, full Gateway/bootstrap or P4 cutover acceptance is implied.
See [seller runtime](postgres-seller-runtime.md) and its evidence.


## PostgreSQL Marketplace settlement (P3n, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite settlement-runtime`
checks pending-funded purchases, session fencing, current wallet reconciliation,
old receipt/new income, alt recovery, partial/full proceeds, native COMMIT failure,
independent account/physics progress and monetary uncertainty during drain.
`--suite shop-settlement` and `--suite wallet-concurrency` retain backend acceptance.

`--suite inventory-endpoint` now runs eight actual headless clients, adding public
visit, purchase lost reply/process relog, seller proceeds refresh and collection
lost reply/UI recreation through production bridge/journals. Run sequentially
with other 18098/18099 suites. Web contracts check restored purchase retry after
an offer disappears; `run-web-inventory.ps1 -Scene market_network` retains SQLite.
See [settlement runtime](postgres-market-settlement-runtime.md) for scope limits.


## PostgreSQL Exchange ledger runtime (P3o, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite exchange-runtime`
checks bag/Storage stack conversion, current shared projections, ownership/replay,
native COMMIT failure, independent progress, conservation and original-issuer/alt
receipt recovery. Existing `exchange-ledger` and `exchange-orders` suites retain
backend parity, rollback, capacity, races and the composed read-model regression.

`inventory-endpoint` now runs nine actual headless clients: Exchange Storage
transfer/deposit lost reply, `ui.ready` retry, withdrawal to claims, withdrawal
lost reply/process relog and saved-but-unsent explicit retry, retaining earlier
Inventory/wallet/NPC/Storage/ground/Marketplace contracts. Run sequentially with
other suites on 18098/18099. A Web contract checks Retry without a source stack
and the ledger-only trading gate. See [runtime](postgres-exchange-ledger-runtime.md)
for the deferred matching, platform and production boundaries.


## PostgreSQL Exchange matching runtime (P3p, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite matching-runtime`
checks participant capture/revalidation, price-time partial/multiple fills, cancel
refunds, pending Yang tokens/replay, native COMMIT failure, independent physics,
offline settlement/late login fencing, conservation and uncertain-outcome drain.
Existing `exchange-orders`, `wallet-runtime` and `settlement-runtime` cover shared
transaction and wallet regression boundaries.

`inventory-endpoint` now runs ten actual headless clients, retaining prior phases
and adding matched order lost reply/process relog, online maker refresh, cancel
lost reply/UI reload and reserve/refund. Run sequentially with other 18098/18099
suites. `run-web-inventory.ps1 -Scene market_network` retains the normal SQLite
path. See [runtime](postgres-exchange-matching-runtime.md) for explicit limits.


## PostgreSQL public Auction reads (P3q, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite auction-runtime`
checks the global/single-active queue, account limits, timeout slot retention,
backend error recovery, current-session authorization, independent native seller
mutation and World physics with 10,000 legal offers. Its synthetic 65-source bound
is not a connected-client capacity claim. `auction-search` retains full SQLite
filter/cursor parity; `matching-runtime` retains the shared executor regression.

`inventory-endpoint` retains ten real headless clients and adds public catalog,
search, `ui.ready` snapshot recovery and duplicate/malformed/rate-limited request
IDs before an actual purchase. Run shared 18098/18099 network suites sequentially.
`run-web-inventory.ps1 -Scene market_network` retains SQLite RPC behavior. See
[runtime](postgres-auction-runtime.md) and [evidence](../evidence/postgres-p3q/README.md).
No physical CEF, combat soak, production PG bootstrap or cutover is implied.


## PostgreSQL bootstrap ownership (P3r, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite bootstrap`
checks missing/invalid configuration, read-only refusal of missing/incompatible
schemas, expected authority, missing profile store, partial connection exhaustion,
offline provisioning CLI, complete Master/World composition, profile/XP persistence
without SQLite currency initialization, and lost-settlement shutdown recovery.

`inventory-endpoint` uses the same bootstrap and explicit native shutdown for all
ten real headless clients. Its owned cluster has 14 connections to accommodate
World 8 + Master 1 + fixture control 1 and reserved PostgreSQL slots; other suites
retain 12, including the deliberate exhaustion case. `inventory-session-bridge`
and normal SQLite `market_network` retain admission/default-path regressions.
Run shared 18098/18099 suites sequentially. See [bootstrap](postgres-bootstrap.md)
and its evidence for normal process/identity/production gates that remain open.


## PostgreSQL normal process startup (P3s, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite process-startup`
starts ordinary Gateway/Master/World role scenes on private random ports and
owned account/profile paths. A real client covers identity conflict refusal,
same-profile recovery, session grants, equip, relog and full server restart.
Wallet initialization is idempotent; foreign ownership and another profile ID
are refused. All native pools stop before process exit; SQLite wallet rows are
absent and its legacy item table remains empty. Child logs must be script-error
free. The temporary wrapper only controls shutdown/diagnostics, not application
startup, grant or economic behavior. See [startup](postgres-process-startup.md).
`bootstrap`, `inventory-session-bridge` and SQLite `market_network` retain focused
composition/session/default-path regressions. Shared 18098/18099 suites remain
sequential. This is not PG production cutover, combat soak, Linux or physical CEF
acceptance.


## PostgreSQL operator maintenance (P3t, opt-in)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite maintenance`
extends the ordinary three-process/client startup scenario with authenticated
operator status/quiesce, active-session dirty Yang/XP, frozen account checkpoint,
operator retry, full restart and closed native workers. A real PG lock forces
BLOCKED without premature Master drain or discarded RAM income; only this failed
disposable simulation is forcibly cleaned up. Injected control faults cover
missing/late/foreign/malformed ACK, timeout, World loss and account save failure.
The suite uses private random ports and owned stores. Shared 18098/18099 suites
must still run sequentially. See [maintenance](postgres-maintenance.md).

## PostgreSQL realm backup/restore (P3u)

Opt-in disposable fixture only: `python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite backup`. Runs normal processes, acknowledged maintenance/exit, capture, restore into a second DB/profile/account set and normal login again. Includes committed WAL, identity/checksum/refusal and nonempty reservation/revenue/fill checks. No real player data or installed service. See [operator procedure](postgres-backup-restore.md).

## PostgreSQL controlled World replacement (P3v)

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite world-replacement` starts only disposable normal processes/private stores. Exercises real dashboard shutdown with held wallet SQL, immediate routing closure, dirty profile/Yang persistence, old-worker exit/grant retirement and fresh login under the same live Master/Gateway. Includes old consumed-ticket refusal. Pair with isolated `run-account-identity.ps1` (delayed grant/handoff tests) and smoke. The unrelated opt-in SQLite `-WithSession` still requires separately configured normal local roles; do not point it at player data. See [procedure](postgres-world-replacement.md).

## PostgreSQL mixed World load baseline (P4a)

`python tools/postgres/run_mixed_load.py --pg-bin Y:/Software/PostgreSQL/bin --seconds 8 --runs 3` runs fresh disposable clusters sequentially, with real World movement/AI and native economic runtimes but synthetic sessions/no connected clients. Reports no-traffic baseline and offered 10/30/100 write attempts/s plus independent reads; assert accounting, UID/footprints, custody, money/reservation and receipt conservation. Keep other performance tests stopped during measurement. Not default CI, not MMO capacity or completed soak/cutover. See [method](postgres-mixed-load.md) and [evidence](../evidence/postgres-p4a/README.md).

P4b opt-in recovery under the same mixed traffic: append `--load-faults` to the
`run_readiness.py --suite mixed-load` invocation (15 seconds/cohort recommended).
Requires actual deferred COMMIT failure and original-ID recovery of a dropped
successful purchase reply in each write cohort; no process/socket-crash claim.
