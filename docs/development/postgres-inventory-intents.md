# PostgreSQL P3b — durable Inventory identity and recovery

**Opt-in backend boundary. Production World remains SQLite.** This extends the
[P3a executor](postgres-inventory-executor.md) with Inventory-only admission,
original-ID resume/outcome and bounded discovery. It does not yet bind an active
World/session epoch or reconcile runtime equipment; these remain prerequisites
for live integration.

The follow-up [P3c session fence](postgres-inventory-sessions.md) adds an opt-in
delegated backend grant and recovery barrier; its trusted issuer bridge and
actual World reconciliation remain unimplemented.

## Durable boundary

`inventory_intent_schema_postgres.gd` explicitly installs schema feature
`inventory_intents` after the existing Inventory schema. Version 1 added the
account-keyed intent table and character/sequence history index;
[P3h version 2](postgres-pending-recovery.md) adds the account/sequence partial
pending index used by runtime recovery. Existing
success receipts are not rewritten/backfilled. No SQLite migration or backend
selection is changed.

A matching pre-existing legacy success receipt can be returned as a terminal
replay, but discovery enumerates identities admitted through this new path;
it is not a backfill of historical legacy operations.

The trusted server API accepts character, stable operation ID and existing
Inventory scalar arguments. `admit()` uses account-first command admission and
reserves the immutable character/action/UID/revision/placement fingerprint. Only
a successful **native COMMIT** returns `state: pending`. Failed COMMIT closes the
session and returns `outcome_unknown`, not a durable admission acknowledgment.
The executor's immediate `{queued: true, ticket}` still means RAM transfer only.

At most eight pending intents are admitted per account, serialized under its
existing account lock. `busy` from this durable admission phase creates no new
intent or receipt. Existing matching IDs can still recover/replay at capacity;
reuse by another character, kind or payload conflicts. The limit does not replace
future authenticated endpoint rate limits or detailed receipt-retention policy.

The common PostgreSQL command owner checks optional Inventory reservations before
allowing a new receipt identity. An ordinary Inventory command with the matching
pending ID gets `operation_pending`; a conflicting payload or another domain gets
`command_conflict`. Only explicit Inventory resume may execute that matching
reservation. Schemas without the optional feature retain existing behavior. The
small catalog/reservation reads are included in backend work and need measuring
under the later P4 runtime load gate.

## Execution and terminal outcomes

`execute()` loads the body from the durable row. The resume caller supplies no
replacement arguments. The existing Item store reuses its domain mutation logic
inside a fresh account-first transaction, checking the exact reservation and
original receipt. It retains bounded full-transaction statement retry.

Success writes item/custody/revisions, durable receipt and terminal intent result
in **one transaction**. Business rejection rolls back the mutation savepoint,
then writes a durable negative receipt and matching terminal intent in that same
outer transaction. A storage error rolls back the whole attempt and leaves the
already admitted intent pending. No storage failure becomes terminal rejection.
The legacy path keeps its existing rejection policy; only explicitly admitted
Inventory operations get these durable negative outcomes.

Duplicate/concurrent resumes return the same terminal business result. Rejection
is not reevaluated after later item changes. Original success/rejection also
blocks reuse through older command paths. Mutation/replay flags remain distinct
from the admission COMMIT and read-only discovery. No-op terminal success need
not be an actual item mutation.

COMMIT uncertainty is never automatically resubmitted. Reopen and inspect the
original identity. A missing row/receipt is not permission to create a fresh ID;
the caller must reconcile the same intention. Native deferred-failure fixtures
have a known aborted outcome, not a model of all lost COMMIT responses.

## Recovery API through the executor

- `submit_inventory_admission(...)` queues the explicit durable-admission phase.
- `submit_inventory_resume(character, operation_id)` queues execution of the
  server-loaded body; it is also safe for terminal replay.
- `submit_inventory_outcome(character, operation_id)` reads the current outcome.
- `submit_inventory_discovery(character, after, limit)` enumerates stored intents
  for that character, including pending and terminal results. Default page size
  is 50, maximum 100; `more` and the sequence cursor expose all rows.

These are server-local APIs, not client RPC authorization. All their database
work stays in worker-owned sessions. The existing raw Inventory executor APIs
remain technical paths and cannot bypass a reserved ID.

Discovery needs no client-held operation IDs. Start a recovery scan at cursor 0;
retain and reconcile every discovered pending ID explicitly. The cursor paginates
identity records, **not changes to existing outcomes**: do not use it as a
terminal-result watermark/changefeed. Terminal records/receipts are retained;
there is no cleanup that could make an old ID executable again. A future bounded
detail policy must retain deduplication safety. int64 revisions remain native
columns, not JSON-parsed numeric arguments.

## Verification and remaining work

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite inventory-intents
```

The fixture ends its own separate Godot process immediately after durable
admission. A new owner discovers the randomly generated identity from PostgreSQL
and resumes without being handed its ID. It also checks concurrent admission/
resume, cross-character/domain conflicts, terminal rejection replay, atomic
finalization faults/retry, admission/execution COMMIT unknown, pending bounds,
paged recovery and exact int64 arguments. See [P3b evidence](../evidence/postgres-p3b/README.md).

Remaining P3: trusted realm/session epoch binding and revocation, active-authority
recovery barrier, committed-fact delivery/versioned reconciliation, CH handoff,
pending-income ownership and other domains. Crash during active SQL/ambiguous
transport COMMIT, real World/network/CEF, saturation/fairness, retention and P4
cutover remain separate acceptance gates. No live route is enabled by this slice.
