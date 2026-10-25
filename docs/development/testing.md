# Prototype testing policy

Full-state PostgreSQL acceptance:
`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite full-state`.
This owns disposable data and real Gateway/Master/World/client processes,
backup/restore and restart. See [full-state setup](postgres-full-state.md).
The only native SQL addon is godot-soci. Embedded SQLite fixtures use
`SqliteSoci` for focused local correctness/network tests; they do not select the
normal deployment backend or prove PostgreSQL concurrency. Historical comparisons
against godot-sqlite and locally patched driver benchmarks are retired.
Run `python tools/soci/setup.py` before the first clean import or smoke.

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

For combat changes, protect PlayerCombatRuntime and the service/actor extractions
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

Runners clean their designated disposable databases and overwrite a small fixed
set of logs under `.godot/verification`. Failed runs retain diagnostic state.
These tests intentionally protect persistence and authority, not prototype visuals.

## Choose checks by affected boundary

Run existing behavior suites before adding a test. Select only the rows affected
by the change; this is not a checklist to run every extended suite for each PR.

| Boundary | Entry points | What must remain true |
| --- | --- | --- |
| Gateway, login, session, admission capacity | `tests/run-account-identity.ps1`; PostgreSQL `--suite full-state` / `process-startup` | Trusted identity, stale attempt/disconnect rejection, last-login ownership and capacity reserved through final attach |
| World RPC / local instances / CH | Current scenario commands in [RPC admission](world-rpc-admission.md), [local instances](local-map-instances.md), [channel transfer](local-channel-transfer.md) | Foreign RPC cannot spawn/move a character; destination admission precedes destructive departure; failed transfer preserves/recoverably ends the session |
| Movement and PvE | `tests/run-spike3d.ps1`, `tests/run-pve.ps1`, `tests/run-first-region.ps1` | Authoritative speed/collision/death, cleanup, ground pickup/rights and playable content |
| Combat / hit traces / BODY contacts | `tests/run-combat.ps1`; `-Scene combat_trace_network -MarkerPrefix TRACE`; `-Scene warrior_action_polish -MarkerPrefix ACTION` | Server damage once, hit geometry, locks, interruption, knockback and player overlap escape |
| Inventory / Wallet / Storage / NPC / Marketplace / Exchange | Relevant PostgreSQL suites below; retained `tests/run-items.ps1`, `tests/run-yang.ps1`, `tests/run-market.ps1` reference cases | Ownership/custody, revisions, capacity, atomic money/item mutations, replay and restart recovery |
| Profile/social persistence and complete deployment | PostgreSQL `--suite full-state` | No success before COMMIT, profile ownership, checkpoint failure, login/relog and full-state backup/restore |
| Web UI bridge / TypeScript | `tests/run-web-ui.ps1`; [UI build/test commands](../../source/client/ui_web/README.md) | Explicit command boundary, request correlation, UI_READY snapshot recovery, retained uncertain intentions |
| Native CEF / export / GPU integration | `tests/run-cef-export.ps1`, relevant `tests/run-visual-v0.ps1` scenario | Client addon resources, CEF-free server exports, renderer/input/lifecycle boundary; physical input/release packaging remain separate |

All network suites using **port 18098 run sequentially**. Do not run CPU load
baselines alongside those suites, builds or another load process. Normal-role
`-WithSession` tests require deliberately prepared disposable local roles; never
point them at real player data. Prefer the owned PostgreSQL full-state fixture
for complete login/restart acceptance on the normal backend.

## PostgreSQL runner

Affix C1: `--suite affix-generation` persists generated and legacy affixes through
the real PostgreSQL item store, reopens the connection, and checks UID, resolved
stats, sockets, upgrade level and the existing Auction stat/value index. The pure
generator/embedded compatibility coverage is in the standard smoke suite.

Player Trade V1: `--suite player-trade` covers atomic two-account settlement,
UID/roll preservation, capacity/full-bag swaps, concurrent UID attempts, rollback,
COMMIT uncertainty, replay and stale sessions. `--suite player-trade-network`
uses two real headless WebSocket clients and production negotiation RPCs with
native PostgreSQL owners, including a lost completion and private Inventory
reconciliation. Master grant transport is fixture-controlled; this is not a full
Gateway login or a physical CEF input test. Run port-18098 suites sequentially.
The Trade network case also journals the first acceptance without submitting SQL,
drops the old adapter before cancellation publication, exits that client process,
and reconnects the same character with a new peer/session. A fresh adapter reads
the same on-disk pending ID, resolves PostgreSQL `not_committed`, and clears both
the journal and UI pending state. Original UIDs/balances are checked unchanged,
then another trade completes. It uses wall-clock timeouts rather than a startup
frame budget, since the scenario starts a replacement process.

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite full-state
python tools/postgres/run_readiness.py --help
```

The runner creates/stops its own disposable loopback cluster with SCRAM. Passing
an installed binary directory does not authorize use of an installed service or
player database. See [full-state setup](postgres-full-state.md),
[SOCI dependency](soci-dependency.md) and [bootstrap](postgres-bootstrap.md).
Choose a focused `--suite` according to the operation and failure boundary:

| Scope | Representative suite selectors |
| --- | --- |
| Native transaction/type lifecycle | `readiness`, `commit-failure` |
| Store parity and conflicting transactions | `wallet`, `inventory`, `storage`, `upgrade`, `npc-shop`, `shop-seller`, `shop-settlement`, `account-claims`, `exchange-ledger`, `exchange-orders`, `auction-search` |
| Locking / replay / retry | `wallet-concurrency`, `inventory-concurrency`; relevant operation suite |
| Inventory worker, durable admission and session recovery | `inventory-executor`, `inventory-intents`, `inventory-sessions`, `inventory-runtime`, `inventory-session-bridge`, `inventory-endpoint` |
| Active domain runtimes | `wallet-runtime`, `npc-runtime`, `storage-runtime`, `ground-runtime`, `seller-runtime`, `settlement-runtime`, `exchange-runtime`, `matching-runtime`, `auction-runtime` |
| Deployment and operational recovery | `bootstrap`, `process-startup`, `full-state`, `maintenance`, `backup`, `world-replacement` |

Unknown COMMIT outcomes require receipt discovery/reconciliation, not blind
mutation retry. SQLSTATE alone does not authorize replay: whole-use-case retry
must preserve the original operation identity, transaction ownership and safe
rollback proof. See [retry policy](postgres-transaction-retry.md).

Separate business correctness from setup. A PASS marker without a successful
process exit and clean script/assertion checks is not a passing run. Missing
source resources/imports are a setup failure to report, not a reason to ignore
parser errors or remove real assertions.

## Load and soak cases

These are opt-in tools, not default acceptance for a documentation/UI change.
Further World profiling/controller work is deferred by the maintainer as of
2026-10-22; do not resume W0–W7 or a long soak automatically.

- [Economy Stress & Recovery](postgres-mixed-load.md): `--suite mixed-load`.
  Deliberate contention, saturation, backend loss and outcome recovery.
- [Representative Economy](representative-economy.md): `--suite realm-workload
  --realm-case representative`. Broader economic population and offline sellers
  are not equivalent to the same number of connected players.
- [MMO Integration & Load](realm-workload.md): `--suite realm-workload
  --realm-case stories`. Distinct from the database stress case; reports actual
  admission, completion, rejection, recovery and profile coverage.
- [World baseline](world-baseline.md) and [profiling](world-profiling.md) retain
  synthetic controls. Their scenario counts are proposed test inputs, not
  measured map/population targets or connected-player capacity.

Record seed, scenario/configuration, source SHA, build/host, elapsed time,
operation attempts/admission/completion/recovery, conflicts and relevant latency/
tick distributions. Do not hide rejected work behind success throughput, mix
profiled and unprofiled cohorts, or introduce arbitrary TPS/p95 pass thresholds
for Representative/Integration. Performance regressions need explanation and
maintainer review, not silent changes to test population/limits.

## CI, artifacts and documentation

See [CI](ci.md) for checks actually enabled by the workflow. Do not claim that a
local PostgreSQL/native/browser test ran in CI unless the workflow executes it.
Keep runtime DBs, logs, screenshots and generated probes ignored under
`.godot/verification`. Use `tools/clean-dev-artifacts.ps1` for owned disposable
outputs; preserve engine binaries, imports/editor cache, references, installed
CEF and live runtime stores. Never recursively delete all of `.godot`.

Routine scope, commands, results and limitations belong in the PR body. Update
a canonical runbook when its contract changes; do not add a per-PR report or
copy old milestones into a new active plan. Completed migration provenance is
in [PostgreSQL history](../history/postgresql-migration.md); detailed dated
[evidence](../evidence/README.md) explains original failures and measurements,
not a queue of pending work. Native Windows results do not establish Linux,
physical input, release packaging or full MMO readiness.
