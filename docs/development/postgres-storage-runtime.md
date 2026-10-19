# PostgreSQL account Storage runtime — P3k

P3k optionally connects the existing Storage RPC/UI flow to PostgreSQL. It does
not enable a playable PG realm or change the normal SQLite bootstrap. No schema,
RPC signature, UI layout or Storage access rule changes: the MVP still permits
authenticated Storage use anywhere, without an NPC/window-state authority check.

## Ownership and execution

`InventoryEndpoint3D` admits the current map peer, limits requests and validates
coordinates. Its PG adapter correlates responses separately from Inventory work.
`storage_runtime_postgres.gd` coordinates one operation per bound account through
a dedicated instance of the existing bounded native executor. The worker owns
the connection and the complete store transaction; no SQL runs on the World
simulation thread. Only copied UID/revision/source/destination/position data and
the server's delegated session context cross the boundary.

The existing account Storage store retains account-first locking, character
ownership, receipt identity, revision and **complete item footprint** validation.
Moving custody, withdrawal provenance/revision, account item revision and success
receipt commit atomically. A unique starting-cell index is not a substitute for
the application's account-locked footprint check. No store writes custody around
this contract. A registered account grant now also fences unqualified legacy
Storage mutations; historical fixtures without a grant retain their behavior.

Inventory's existing external-operation hold now has a domain-neutral name, used
by NPC and Storage. A Storage-qualified hold blocks local Inventory/NPC writes and
dependent combat inputs during the operation. It does not capture pending Yang
or checkpoint the wallet: Storage moves no money. Other accounts remain free to
progress. Binding and worker capacity limits bound work; a full pool does not
save a mutating request in a second RAM queue to execute later.

## Shared projection and publication

Construct the optional Storage coordinator **before** attaching Inventory peers,
and provision the existing Storage schema explicitly. It enables combined
Inventory/Storage snapshots in the Inventory owner. Both domains are read in one
native account-locked transaction with one account-wide item revision. Enabled
Storage failures close recovery; they never silently publish an empty/SQLite
Storage projection. Without the coordinator, the prior unsupported projection
remains explicit.

Post-command refresh and the existing backend revision ACK precede readiness,
the terminal response and any known-new-commit fact. Rejection/no-op/replay repair
state without inventing a new commit. A failed ACK gets bounded projection repair.
The active binding is checked again after publication callbacks.

There is currently one delegated active session per account. A replacement alt
loads the same Storage but its own bag/equipment. An in-flight old operation keeps
its original issuer for receipt discovery; it never withdraws into the alt's bag
by replaying an old body. Old peers receive no private state/result. Account-wide
revision floors and current binding reconciliation are reused; this is not a
cross-process invalidation transport or simultaneous multi-session feature.

## Lost outcomes and lifecycle

The existing Storage client journal keeps a stable operation ID and original body
before send. Runtime `queued` means volatile scheduling, not durable admission.
Lost completion/ambiguous COMMIT pauses the lane; bounded automatic recovery only
reads receipts after account admission. It never auto-executes a missing command.
The user can explicitly retry the original intent after `unknown_command`.
Window/browser recreation and client-process relog use the same receipt path,
without requiring that the original source/destination cell still be available.

Successful receipts retain the original request fingerprint and cannot be changed
by another alt/payload. Existing business rejection persistence policy is unchanged:
this does not add durable negative receipts or durable pending Storage commands.
Transient recovery errors remain nonterminal. Storage's journal also honors an
explicit terminal result during receipt recovery.

World polls Storage during normal simulation, disconnect and graceful lifecycle
barriers. Shutdown closes admissions, settles/reconciles active work and drains
and joins the Storage executor. It refuses the graceful barrier if unresolved
work cannot settle; active native SQL is never force-stopped. Client journals and
committed receipts survive recreation; unsent volatile work has no durability
promise. No whole-World crash/operational failover guarantee is added here.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite storage-runtime
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite storage
& ./tests/run-web-inventory.ps1 -Scene storage_recovery
```

Native runtime acceptance covers complete footprints, foreign accounts, bare-write
session fencing, SQL-lock independence, queue refusal, replay/conflict, uncertain
COMMIT, projection ACK repair, original-issuer takeover, actual alt withdrawal
and forced drain. The extended endpoint fixture uses native Master/World sockets,
five real headless client processes and production Web UI bridge/adapters/journals.
It covers lost reply, `ui.ready`, client restart/relog, private Storage, exactly
one publication per known commit and unchanged SQLite economic data.

Gateway entry/map construction are controlled. Physical CEF input/rendering,
Linux, server crash/restart, multi-World hosting and P4 load/soak/cutover are
**NOT VERIFIED by P3k**. See [evidence](../evidence/postgres-p3k/README.md) and
the [remaining adoption gates](../plans/postgresql-migration.md).
