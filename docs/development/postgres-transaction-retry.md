# PostgreSQL P2c–P2j — receipt-backed transaction retry

These opt-in slices use official SOCI v0.4.3 and enable bounded whole-use-case
retry for **Shop purchase/revenue collection, Exchange order placement/cancellation,
Exchange stack conversion, Upgrade, NPC purchases and receipted Inventory/Storage/
Shop seller commands**. Production World remains
SQLite; no executor, connection pool, RPC, schema or backend selection is added.

## Policy and ownership

The existing `economy_command_postgres.gd` owner captures native structured error
details **before** rollback clears them. It records an internal retry proof only
when the failure is storage-related, `error_backend` is PostgreSQL, SQLSTATE is
`40001` or `40P01`, an explicit transaction is active, and native rollback succeeds.
The owner separately records whether native COMMIT was attempted and vetoes retry
across that phase. Other error codes and message text cannot authorize retry. Failed rollback
closes the session and never produces that proof. Missing structured diagnostics
fail closed. No retry metadata is added to public results or receipts.

`run_with_retry()` invokes the complete operation at most three times. Each
invocation starts fresh identity/admission, receipt lookup, current offer/revenue
or order-book selection, capacity/headroom and economic validation, then mutation/receipt/COMMIT.
The initiating character and command ID remain identical. Purchase captures a copy
of its server-owned pending-income prefix once; collection retains the original
integer prefix. An aborted attempt rolls that prefix back with every other write.
This is not a statement retry or reuse of first-attempt selection decisions.

Success, receipt replay, a business rejection, exhausted attempts, a closed session
or any unproven cleanup terminates the loop. There is no yield/backoff/pool or
unbounded work queue. These synchronous stores remain outside the World simulation
path; P3 must provide bounded nonblocking execution before runtime adoption.

COMMIT failure keeps the existing conservative policy: close and return
`outcome_unknown`, then discover the original receipt after reconnect. Even a
COMMIT error carrying `40001`/`40P01` does not enter the statement-rollback loop.
Unreceipted Wallet checkpoints and other domain stores are not opted in.

PostgreSQL requires retry of the full transaction, including decisions about SQL
and values. SQLSTATE alone is insufficient for application retry safety. See
[official serialization failure guidance](https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html).

## Native lifecycle gate on the released payload

`postgres_commit_failure.gd` retains its existing native failure containment check
and verifies v0.4.3 naming/reset and transaction semantics. A failed deferred COMMIT
can leave local `in_transaction()` true after PostgreSQL has ended and rolled back
the transaction. An ordinary statement failure instead leaves subsequent statements
failing with `25P02`. COMMIT of that aborted transaction can return true while
PostgreSQL performs ROLLBACK. No boolean or local flag substitutes for the owner's
statement tracking, durable receipt or outcome discovery.

## Verification and remaining scope

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite commit-failure
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite shop-settlement
```

The existing settlement fixture now injects server SQLSTATE failures at custody
and receipt writes after prior wallet/revenue changes. Sequence counters survive
rollback and measure attempts without writing fake economic receipts. It verifies
two-attempt purchase/collect success, one application of pending income, original
result replay, a three-attempt cap, no retry for constraints/timeouts/cancellation/
generic errors, and no retry/discovery substitution after COMMIT or rollback failure.

An independent editor is queued ahead of the retried buyer while the first attempt
is held at a database barrier. After rollback, the editor changes price/revision;
the next complete purchase reads it and returns `stale` without debit. Only this
diagnostic uses larger session-local timeouts to coordinate its native threads;
normal fixture limits and the three-attempt budget remain unchanged.

This is fault/recovery correctness, not a contention-throughput or soak benchmark.
See [P2c evidence](../evidence/postgres-p2c/README.md). Other use cases need explicit
adoption/review, not a global retry toggle. P3 pending-prefix ownership, session
fencing and runtime reconciliation, P4 migration/load/cutover and Linux native
verification remain separate gates. An internally retried call does not make the
same pending prefix safe across multiple successful commands with different IDs.

## P2d — Exchange order lifecycle

`ExchangeOrdersPostgres.place_order()` and `cancel_order()` use the same existing
owner and three-attempt policy. No new retry engine or schema is introduced.
Placement captures the original order payload and server-owned pending map once;
cancellation captures its command/order ID, expected revision and pending map.
Each complete attempt reacquires the pair and sorted participant accounts, checks
the receipt, and rereads the current book or cancellation target. Failed attempts
discard generated order IDs, selected makers, fills, wallet changes and refunds.

Price/time priority, lot arithmetic, reservation rules, active-order limits and
receipt results are unchanged. A successful replay returns the original result
with `committed == false`; runtime reconciliation must distinguish it from a new
commit. A cancellation whose expected revision became stale returns `stale` and
does not refund the new remainder. COMMIT failure still closes the connection and
requires receipt discovery; its SQLSTATE never authorizes automatic retry.

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite exchange-orders
```

The existing fixture injects real PostgreSQL statement errors before pair
admission, during reservation/material refund, on the second of two maker fills,
and at receipt persistence. It verifies rollback plus retry, pending income once,
exact replay, bounded exhaustion, nonretryable codes and deferred COMMIT errors.
Two independently queued-session cases verify current-state reselection: a maker
cancelled before buyer retry is no longer matched; an order filled before cancel
retry cannot be refunded using its old revision. Only those coordination probes
extend session-local lock/statement timeouts; runner defaults are unchanged.

See [P2d evidence](../evidence/postgres-p2d/README.md). P2d does not opt ledger
conversion (added separately in P2e), Inventory, Storage, Upgrade or seller lifecycle into retry, complete
the broad P2 gate, or provide P3 pending-prefix fencing/nonblocking execution.

## P2e — Exchange stack conversion

`ExchangeLedgerPostgres.deposit()` and `withdraw()` now use the same bounded owner.
Each attempt redoes account/character admission and receipt lookup, source
authorization/revision/fungibility or destination capacity, ledger credit/debit,
item consumption/creation, watermarks and success receipt. Original command
arguments stay fixed; no first-attempt stack, capacity decision or generated UID
is reused after rollback. Only the confirmed result exposes the new UID.

Storage remains the owner of shared-item authorization and consumption via
`item_in_transaction()` and `consume_in_transaction()`. Conversion does not write
Storage custody directly, weaken account-first locking or bypass full-footprint
validation. Withdrawal still targets character Inventory or account claims only;
it does not add a Storage fallback. Ordinary Storage/Inventory commands are not
automatically opted into retry by this change.

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite exchange-ledger
```

The expanded existing fixture covers partial/whole bag and shared-Storage stacks,
Inventory/claim receiving, one durable generated UID, ledger conservation,
revisions and original-result replay after native statement rollback. Persistent
retryable errors stop after three attempts; other codes and COMMIT failures do
not retry. A queued independent Storage withdrawal moves the source stack to an
alt after converter rollback; retry reauthorizes and rejects the obsolete Storage
source, without credit or a success receipt. The complete stack remains with its
new owner. Existing cross-operation capacity/custody regressions remain required.

See [P2e evidence](../evidence/postgres-p2e/README.md). Production remains SQLite.
P3 pending-prefix/session fencing and nonblocking execution, remaining domains'
explicit retry adoption and the broader P2/P4 gates remain separate work.

## P2f — Upgrade material, wallet and item mutation

`UpgradeStorePostgres.upgrade()` uses the same owner and at most three whole
attempts after proven statement rollback. The original operation ID, expected
target revision and pending Yang stay fixed. A deep copy captures the server-owned
recipe once per call, so an accepted operation cannot change cost or material
requirements between attempts. Receipt identity and result formats are unchanged.

Each attempt redoes account/character admission, receipt discovery, target
ownership/placement/revision, capacity, ordered material selection, whole/partial
stack consumption, pending-income spend, target upgrade and receipt persistence.
An aborted attempt publishes nothing; only confirmed commit may refresh runtime
stats/wallet. Replay returns the original result with `committed == false`.
COMMIT failures still close the connection and require receipt discovery without
automatic retry. Caller-owned NPC/service/range authorization is unchanged; this
store does not implement a World admission/session fence or async execution.

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite upgrade
```

The existing parity fixture now injects statement errors at material custody and
instance deletion, partial-stack reduction, wallet spend, target mutation and
receipt writes. Each case checks one upgrade/revision, one material cost, one
pending prefix and original-result replay. Exhaustion and deferred COMMIT errors
preserve target/material/custody/wallet/account revisions and receipts.

Independent native editors queue before retry. Moving a material into Storage
forces reselection of current eligible stacks; changing target position/revision
forces `stale` without costs. Editing the original recipe while the first attempt
is held does not alter the captured operation. Only these barrier diagnostics
extend session-local timeouts; the normal runner budgets remain unchanged.

See [P2f evidence](../evidence/postgres-p2f/README.md). NPC purchase, ordinary
Inventory/Storage, Shop seller/claim commands and unreceipted checkpoints are not
newly opted in. Runtime remains SQLite; broader P2 and P3/P4 gates remain open.

## P2g — NPC purchase and receiving capacity

`NpcShopStorePostgres.purchase()` uses the existing three-attempt whole-use-case
owner. A deep copy captures the server-owned Shop definition, including nested
offers, once per accepted call. Command ID, receiving character, offer, requested
position and pending-income prefix remain fixed across attempts. Each attempt
reacquires account/character admission, checks the original receipt, revalidates
current complete-footprint capacity and funds, then repeats item/custody creation,
wallet mutations, watermarks and receipt persistence. An aborted generated UID is
discarded; only the final committed UID is returned.

Exact requested placement rejects with `occupied` if another operation takes any
cell of the footprint between attempts. Automatic placement selects again from
current capacity. Receipt replay still resolves before occupancy/affordability
checks and returns the original result without applying new pending income.
COMMIT failure remains `outcome_unknown` with connection closure and receipt
discovery, without automatic retry. NPC/service/range admission remains with the
caller; this opt-in store does not introduce World session fencing or execution.

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite npc-shop
```

The existing parity fixture now injects statement failures at pending-income
application, spend, item instance/custody creation and receipt persistence for
single items and stacks. It checks one UID, one debit, one pending prefix, exact
replay, bounded exhaustion and no retry of other codes or deferred COMMIT errors.
Independent queued buyers occupy a nonstarting cell of the requested footprint;
explicit placement rejects without costs, while automatic placement succeeds
elsewhere. Editing original offer price/quantity during the barrier does not
change either accepted call's captured content. Only these diagnostic sessions
extend their own coordination timeouts; normal fixture budgets are unchanged.

See [P2g evidence](../evidence/postgres-p2g/README.md). Ordinary Inventory/Storage,
Shop seller/claim commands and unreceipted checkpoints are not newly opted in.
No schema, protocol, gameplay or runtime backend changes; broader P2 and P3/P4
remain separate gates.

## P2h — Character Inventory commands

`ItemStorePostgres.inventory_command()` uses one existing command owner for the
complete retry loop, including `move`, `equip`, `activate`, `unequip` and weapon
swap. Each attempt reacquires account-before-character admission and the original
receipt, then rechecks target ownership/revision, primary action, current equipment
and full-footprint receiving capacity. It repeats all custody/revision mutations
and receipt persistence. Original command ID and scalar arguments stay fixed.
Starter initialization, ground pickup and caller-owned receiving helpers retain
their existing policies; they are not implicitly wrapped by this change.

Public `committed` still means an actual item mutation. A successful newly
receipted no-op leaves it false and `receipt_replay` false. Replaying a durable
success leaves `committed` false and `receipt_replay` true, including no-ops.
Rollback, exhaustion and unknown COMMIT never report a committed mutation.
COMMIT failure closes the session and requires original receipt discovery; it
does not authorize automatic retry. These are backend flags, not a World runtime
or combat-cache integration.

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite inventory
```

The existing parity fixture injects `40001`/`40P01` statement faults at placement,
target revision and receipt writes for every command path. It verifies atomic
two-item swap, one revision per affected item, unchanged UID count, equipped stats,
original-result replay, no-op flags, bounded exhaustion and no COMMIT retry.
Independent editors queue before retry and change target revision, currently
equipped weapon or a nonstarting cell of unequip's destination footprint. Retry
respectively rejects stale input, selects current equipment without moving the
formerly equipped item twice, or rejects occupied placement with no partial
unequip. Only these coordination sessions extend diagnostic timeout budgets.

See [P2h evidence](../evidence/postgres-p2h/README.md). Account Storage and Shop
seller/claim retry remain separate scopes. World still uses SQLite; broader P2,
P3 execution/fencing and P4 migration/cutover remain open.

## P2i — Shared-account Storage commands

`AccountStoragePostgres.transfer_command()` uses one existing command owner for
the entire bounded loop. Every attempt reacquires account-before-character
admission, checks the original issuing-character receipt, and reauthorizes current
source custody/revision and full destination footprint. Deposit, internal move
and alt withdrawal repeat custody removal, provenance/revision update, destination
insertion and receipt atomically. Character, UID, expected revision, route,
requested position and operation ID stay fixed; retry cannot retarget an alt.

Stored provenance remains the original character until withdrawal assigns the
receiving character. Same-account access does not turn another alt's command into
a replay: a different issuer conflicts, and read-only discovery is issuer-scoped.
Public mutation/no-op/replay flags keep the existing Inventory semantics. Failed
COMMIT closes the session and returns `outcome_unknown` for receipt discovery,
without automatic retry. Caller-owned `item_in_transaction()` and
`consume_in_transaction()` remain inside their calling command's transaction;
they do not start a nested retry loop or become independent custody writers.

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite storage
```

The existing fixture now injects statement errors at custody deletion, revision/
provenance update, placement insertion and receipt for all three routes. It checks
one UID/custody, preserved rolls, correct alt provenance, exact replay/issuer
conflict, no-op flags, bounded exhaustion and no COMMIT retry. Independently queued
alts withdraw the source, revise its position or occupy a nonstarting destination
cell before retry. Current owner/stale/occupied checks reject without partial
transfer. Only those diagnostic sessions extend their coordination timeouts.

See [P2i evidence](../evidence/postgres-p2i/README.md). Shop seller/claim retry,
starter/pickup and unreceipted checkpoints retain their existing policies.
Production remains SQLite; broader P2 and P3/P4 are not completed by this slice.

## P2j — Player Shop seller lifecycle

`ShopSellerPostgres.list_item()`, `configure()`, `edit_offer()` and `cancel_offer()`
use the existing bounded whole-command owner. Each attempt reacquires account-
first admission and the original receipt, then rereads current item/custody,
Shop/offer revision, Shop cells and receiving Inventory footprint as needed.
Original character, command ID and scalar arguments stay fixed. Aborted Shop/
offer creation and partial cell writes roll back with the entire transaction.

Listing preserves UID/rolls in exclusive escrow. Offer Only and fixed-price edits
keep their existing representation; a price-only edit changes offer revision
without changing item revision/watermark. Withdrawal returns the same UID to the
initiating character's Inventory, assigning owner and removing offer/cells
atomically. Automatic receiving reselects current capacity. Configuration rechecks
expected Shop revision before applying name/status.

Existing **account-scoped** seller fingerprints/discovery are unchanged: another
alt may replay the original result, including its original receiving character.
Replay is not a new commit and cannot retarget the item. Definitive business
rejections retain the bounded negative-cache policy; storage errors do not become
permanent rejection receipts. COMMIT failure still closes and returns
`outcome_unknown` for discovery, never automatic retry.

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite shop-seller
```

The expanded fixture injects statement faults after earlier Shop cells were
written and at configuration, withdrawal custody and receipt persistence. Full
list/configure/edit/price-only/withdraw cycles check one offer/cell footprint,
item/provenance/revisions, Offer Only, cross-alt replay, exhaustion and no COMMIT
retry. Independently queued editors change custody, offer/Shop revision or Shop/
Inventory occupancy before retry; current state is honored. Only these barrier
sessions extend their own diagnostic coordination timeouts.

See [P2j evidence](../evidence/postgres-p2j/README.md). Claims, starter/pickup and
unreceipted checkpoints retain their policies. Production remains SQLite;
broader P2, P3 execution/fencing and P4 remain separate gates.
