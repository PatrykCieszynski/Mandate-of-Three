# PostgreSQL wallet runtime — P3i

P3i adds an **opt-in, single-World** wallet owner beside the existing Inventory
runtime. Normal startup still uses SQLite. There is no backend selector, live
conversion, extra frontend or new gameplay currency.

## Ownership and batching

`wallet_runtime_postgres.gd` owns one RAM projection per verified Master account:
durable balance/reservations/revision, positive pending grinding income, one
captured batch and its local worker ticket. It accepts a peer only through the
World's current session/ticket mapping and the existing delegated PG context.
Every worker operation revalidates that context under the account lock.

Ground currency retains existing rights, reach, liveness and double-pickup rules.
The normal `CurrencyEndpoint3D` uses the optional wallet owner for pickup and HUD
snapshots. Income changes RAM immediately, with no per-drop SQL or item UID.
The owner uses a 30-second checkpoint interval. Each account has at most one
in-flight job; at most 64 accounts are retained, including unresolved offline
accounts. A dedicated instance of the existing bounded executor owns native
connections; Inventory and wallet must not consume each other's result queue.
SQL never runs on the World thread. Accounts are checkpointed independently,
rather than holding every dirty account in one global transaction.

A checkpoint captures the current income prefix and a random stable operation
ID. Its transaction validates the current session and original issuing character,
checks the account-scoped shared receipt namespace, adds the prefix, writes a
`wallet_batch` receipt and commits. Reusing an ID with a different body conflicts.
This adds no schema feature or per-ground-stack durable history. Receipts remain
retained; their long-term retention policy belongs to P4.

While an ordinary checkpoint is in flight, later income may accumulate. Only the
captured prefix is removed after a confirmed/replayed result. The owner then
loads current wallet state before reopening spending or publishing completion;
an old receipt is never used as the current balance. Later income remains dirty
until another checkpoint. Forced checkpoints close new currency admission until
settled, so transfer/save barriers cannot race another local pickup.

## Spend, failure and session recovery

The existing fixed **50 Yang test spend** captures pending income and spends in
one receipted transaction. Store acceptance also proves DB 40,000 + pending
30,000 - spend 50,000 = 20,000, plus reserved-funds rejection. This is not an NPC
purchase/Upgrade port: those must retain their atomic item/material changes when
integrated, rather than committing a wallet debit separately.

- SQL rollback/storage errors retain the prefix and original ID.
- A definite funds rejection rolls back the entire prefix/debit and refreshes
  before publishing rejection; the original income remains dirty for checkpoint.
- COMMIT failure and a lost successful completion close local currency admission.
  The next 30-second checkpoint or explicit server `retry(peer)` resubmits the
  **same ID/body**; receipt replay prevents a second credit/debit. A failed COMMIT
  is never classified as a definite rollback or blindly retried by SQLSTATE.
- A repeated identical attach preserves unresolved work. A newer same-account
  session carries RAM income and the original issuing character across local
  reattachment; it cannot overwrite dirty RAM with an older SQL snapshot.
- Detach requests a checkpoint and retains dirty/uncertain offline state. If
  revocation wins first, the old context cannot write: recovery waits for a new
  authorized same-account attachment. It does not drop the income or authorize
  writes using a retired session. A graceful shutdown remains blocked meanwhile.
- Losing Master also blocks wallet-only admission and clears unused tickets and
  pending authentication. Old peer cleanup cannot detach a replacement binding.
- Unrelated/stale wallet authorities, regressing revisions and cap overflow pause
  reconciliation. Other economic endpoints still cannot fall back to SQLite.

World save/shutdown/restart paths use an asynchronous bounded checkpoint barrier.
On timeout/unresolved state, save/shutdown is refused with RAM retained. Shutdown
quiesces income and drains/joins the wallet's executor only after acknowledgement;
it never closes an active worker. An aborted shutdown leaves currency quiesced
until recovery or restart, rather than silently resuming unsafe admission.

Existing synchronous instance-transfer checkpoints fail closed while wallet work
is pending, keeping the source actor. A later attempt can proceed after the
checkpoint. A transparent async CH countdown/handoff and cross-World ownership
transfer are **not** claimed by this package.

## Verification and limits

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite wallet-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
```

The new opt-in acceptance covers production pickup/services, RAM-only batching,
later income during locked SQL, independent wallet/physics progress, pending-funded
spend, reservations, receipt conflict/replay, native deferred COMMIT failure,
lost completion after a real commit, scheduled retry, duplicate attach, alt/relog,
disconnect/revocation, cap rejection, forced drain/worker join and RAM recreation.
Its geometry/peer maps/control availability are supplied by the fixture.

The extended existing endpoint suite uses real client processes, native
Master–World authentication, production currency RPCs and client wallet snapshots.
It checks pickup before checkpoint, spend, account privacy, process relog and
unchanged SQLite Yang, while preserving Inventory recovery tests. It supplies
the entry/map/line-of-sight fixture; this is not full Gateway/CEF/region acceptance.

A World crash may lose income not yet checkpointed, normally about 30 seconds
(longer during storage failure). Restart loads the current DB balance and never
replays RAM that died with the process. Unique items/critical economic mutations
keep immediate transactions. No production data was migrated. Cross-domain wallet
publishers/freshness, multi-World handoff, production bootstrap and P4 operational
acceptance remain separate gates in the [migration roadmap](../plans/postgresql-migration.md).
