# C2 — Economy commands and results

**Status: Accepted — architectural contract (2026-10-14).** Wire protocol, concrete persistent structures and numeric limits remain implementation work; no extraction or RPC rewrite is approved here.

## Accepted constraints inherited from C1

- World processes must not block their simulation thread waiting for SQL or network.
- Economy is the realm-wide authority for durable economic changes; success follows commit.
- Authenticate/authorize a World sender and its realm/session context. Client-supplied account/realm identifiers do not confer authority.
- Requests and retried responses must not double-grant items or spend money twice. World/session handoff must not cause a lost response to turn into a second transaction.

## Accepted C2 architectural decisions (2026-10-14)

- Every **state-changing economic operation** has a stable `operation_id`, distinct from the transport/client `request_id` used to correlate a particular attempt. Pure read-only searches need not create durable receipts.
- The same intended operation retains its `operation_id` across timeout, retry, reconnect, CH/dungeon transition and World Process transfer. Retrying cannot apply an already committed economic mutation twice; a known terminal result is retrievable by that identity.
- A reused `operation_id` with a different immutable command payload or inconsistent authenticated context must be rejected, never treated as a legitimate repeat. The exact scoping/keying and hashing remain open.
- An absent response is not evidence of failure or rollback. World must reconcile the original command's outcome rather than creating a *new operation* for a retry.
- For player-initiated actions, the **client carries a stable intention identifier** through retries; an authenticated server binds it to the authorized realm/account, command type and immutable content. The client-provided identifier gives no authority to grant/spend anything. For server-originated rewards/loot, World derives the operation identity from the authoritative event/drop identity rather than creating a fresh ID on every retry. Exact ID allocation, durable retention, collision handling and recovery remain to be specified.
- Accepted business operations have four **caller-visible outcome classes**: `committed` (successful durable transaction), `rejected` (definitive failure), `pending` (still being processed), and `unknown` (World cannot determine the outcome after a transport failure/timeout). `unknown` is **World's local knowledge state**, never a claim by Economy that no transaction occurred. `unavailable` can be a pre-admission transport/service error and must not be confused with an executed business result.
- An admitted state-changing operation must have a durable, replayable terminal outcome/receipt for success **and definitive business rejection**, e.g. insufficient Yang. Clearly unadmitted unauthorized or malformed requests need not create durable business receipts; admission/commit atomicity and receipt retention remain open design points.
- **Independent economic commands may execute concurrently**; there must not be a mandatory single global transaction queue per realm. Conflicting operations (the same UID, offer, wallet funds, or relevant revision) must be serialized/resolved at the *data invariant* boundary through atomic commits, database constraints, suitable row locking or optimistic revision validation. Their result may be success or a definitive conflict/rejection, but never partial settlement, double ownership or a negative wallet.
- This does **not** require concurrent writers in the local SQLite implementation: its existing single writer is valid for development. The eventual PostgreSQL backend must preserve the business invariants under genuine concurrency; it cannot rely on SQLite's serialization to prove correctness.
- **Commands depending on a mutable item/equipment state must carry expected revisions** and fail cleanly on stale state or incompatible ownership/custody. The caller may deliberately wait for one related operation to settle before issuing the next; this is *local flow ordering*, not a global queue. Economy remains the source of truth under races.
- **Durable admission and recovery visibility:** if an operation is acknowledged as admitted, Economy must have enough durable identity/intent/status to finish or recover it after an Economy crash, whether through a durable admission record or an atomically recorded transaction/outcome. Volatile queue acceptance alone is not durable admission. The active authorized session must be able to discover its unresolved admitted operations after source-World loss (via an authenticated account/character-scoped query or equivalent recovery barrier), even if the client no longer remembers all IDs. This does **not** require Kafka or a globally serialized message queue.
- **In-flight command continuity:** a properly authenticated and admitted economic command may reach its terminal outcome after the player disconnects, reconnects or changes CH/World Process. Loss of the caller connection is not automatic rollback/cancellation. Its terminal result remains attached to the original `operation_id`; the new active World/session retrieves/reconciles the outcome and authoritative item/wallet revision(s) rather than resubmitting a different operation.
- **Session fencing at admission:** after the old World's session/authority epoch is revoked, it may not admit **new** economic actions for that character. Revocation does not retroactively undo an already admitted transaction. A new World must rehydrate and reconcile outstanding economic state before permitting actions that rely on it. Exact boundaries for durable admission versus transaction commit, and how to discover pending IDs after a host crash, remain open for C2/C5.
- **Outcome recovery API:** provide an authenticated, read-only `GetOperationOutcome(operation_id)` (or equivalent) scoped to the operation's realm/account/authority. It may report an existing terminal `committed`/`rejected` outcome or an in-progress `pending` state. A missing lookup or transport timeout is **not** evidence the original mutation can safely be recreated; World remains `unknown` until it reconciles against authoritative state/admission rules.
- **Bounded detailed receipt retention, unbounded safety:** detailed business receipts need not be stored indefinitely, but cleanup must never turn an old `operation_id` into a newly executable economic command. After detail expiry, retain sufficient durable deduplication/tombstone information **or** enforce a durable rejection/expiration rule for old IDs; an expired outcome can be returned as `expired`/`no_detail` without replaying it. Exact scheme, time bounds, data retention and recovery UX remain for implementation design.
- **Bounded admission and backpressure:** Economy limits in-flight work and queue depth rather than accepting an unbounded backlog; concrete limits and fair scheduling come from measurements. Reject an operation promptly with `busy` only when the service can **prove it was not admitted for execution**. A dropped response or transport timeout remains `unknown`, not `busy`, and requires reconciliation by `operation_id`.
- No durable message broker or global persistent task queue is required for the initial service. Once admitted, a command must reach an authoritative terminal outcome or remain safely recoverable after failures; load pressure or a lost player connection must not silently discard it. World simulation continues while economic operations are pending. Client retry needs backoff and limits so overload does not amplify itself.
- These architectural guarantees do **not** settle wire schema, cancellation codes, the admission-log implementation, receipt retention duration, concurrency limits, the concrete pending-operation discovery API or client UX on a revision conflict. These details do not block architectural acceptance.

## Implementation outline — non-binding wire/adapter shape

Implement the accepted distinction between transport `request_id` and stable `operation_id`. An operation identity must be checked within an authenticated realm/actor scope so reused IDs cannot gain cross-account authority. Exact key format, origin and recovery representation are deferred.

Candidate command groups: item claim/move/equip, Yang grant/spend, Shop list/buy/claim, Exchange order/place/cancel, and durable grant of a dungeon reward. World submits a bounded immutable payload and a trusted session/authority context; Economy validates its own invariants and returns the committed result plus relevant revision(s).

**Already accepted semantics:** see the accepted C2 decisions above. The concrete status fields and error codes remain a proposal. An admitted business rejection is terminal and idempotent; an unknown result must be reconciled using the original `operation_id`.

## Failure scenarios to validate

1. Accepted command commits, but reply disappears; caller retries after reconnect or CH transfer.
2. Same user sends duplicate request IDs, or two operations race for the same account balance. A single active character per account/realm is the current gameplay preference, but does not remove concurrency requirements.
3. World process crashes with commands in flight; a different host resumes the session.
4. Session is revoked during an already accepted command. Which accepted actions can finish, and how does new World learn the outcome?
5. Economy restarts while a client sees a pending operation. How long are stable command results resolvable?
6. Backpressure, overload, cancellation and deadline: distinguish **cancelling response interest** from **cancelling a committed transaction**.

## Implementation details still open

- Stable ID implementation and recovery: how a newly connected World recovers the **same ID** if the original World crashed before replying, secure realm/account scoping, collision/replay controls and deterministic server-event IDs.
- Exact request/result envelope, authenticated identity proof, realm ID and session epoch, optional expected item/wallet revisions.
- Exact wire representation of the accepted outcome classes, reliable admission boundary and how `GetOperationOutcome` reports a missing, pending or expired record without authorizing replay.
- Bounds: per-account and per-host concurrency, queue deadline, receipt retention/replay window.
- Ordering and conflict UX for **dependent** commands: expected inventory/equipment/offer revisions, stale responses, and whether a caller explicitly queues a second dependent command. Do not impose one global realm queue.
- Exact endpoint/query or durable index used by a new World to discover admitted-but-unresolved operations initiated on an old World; the ability to discover and fence their dependent effects is an accepted requirement, not an optional optimization.

## Current code / migration

The present Shop/Exchange code already uses command IDs and durable receipts; auction search has separate per-session RPC correlation and native async scheduling. Those are useful existing behaviors, **not** proof that a new cross-process protocol is implemented. Do not swap the live RPC or database backend under this draft.
