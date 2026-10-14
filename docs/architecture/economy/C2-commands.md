# C2 — Economy commands and results

**Status: Draft — for next design review.** Nothing below defines a final wire protocol or an implementation task.

## Accepted constraints inherited from C1

- World processes must not block their simulation thread waiting for SQL or network.
- Economy is the realm-wide authority for durable economic changes; success follows commit.
- Authenticate/authorize a World sender and its realm/session context. Client-supplied account/realm identifiers do not confer authority.
- Requests and retried responses must not double-grant items or spend money twice. World/session handoff must not cause a lost response to turn into a second transaction.

## Accepted C2 decisions (2026-10-14) — partial acceptance only

- Every **state-changing economic operation** has a stable `operation_id`, distinct from the transport/client `request_id` used to correlate a particular attempt. Pure read-only searches need not create durable receipts.
- The same intended operation retains its `operation_id` across timeout, retry, reconnect, CH/dungeon transition and World Process transfer. Retrying cannot apply an already committed economic mutation twice; a known terminal result is retrievable by that identity.
- A reused `operation_id` with a different immutable command payload or inconsistent authenticated context must be rejected, never treated as a legitimate repeat. The exact scoping/keying and hashing remain open.
- An absent response is not evidence of failure or rollback. World must reconcile the original command's outcome rather than creating a *new operation* for a retry.
- This does not yet settle who allocates/persists `operation_id`, receipt retention, response schema, cancellation, or cross-World recovery. C2 remains **Draft** until those are agreed.

## Proposed command model — not yet approved

Implement the accepted distinction between transport `request_id` and stable `operation_id`. Scoping the latter by realm, authenticated actor/account and command type is a proposal pending review; its origin and recovery must be specified before implementation.

Candidate command groups: item claim/move/equip, Yang grant/spend, Shop list/buy/claim, Exchange order/place/cancel, and durable grant of a dungeon reward. World submits a bounded immutable payload and a trusted session/authority context; Economy validates its own invariants and returns the committed result plus relevant revision(s).

**Candidate outcome classes:**

- `committed`: durable outcome known, including a durable business rejection if the contract warrants one; no duplicate effects on retry.
- `rejected`: definitive validation/auth/capacity/conflict failure (define per-command retry semantics).
- `unknown`: World timed out or lost transport; it must query/retry with the **same economic command ID**, never create a fresh ID for the same intended mutation.
- `unavailable`: service refuses admission before durable handling; whether safe to retry depends on the acknowledgment/command status rule.

Do not treat network timeout as proof of rollback. Define explicit `GetCommandOutcome`/status reconciliation versus retry-by-ID semantics, receipt retention, replay authorization and payload hashes during C2 review.

## Failure contracts to make precise

1. Accepted command commits, but reply disappears; caller retries after reconnect or CH transfer.
2. Same user sends duplicate request IDs, or two operations race for the same account balance. A single active character per account/realm is the current gameplay preference, but does not remove concurrency requirements.
3. World process crashes with commands in flight; a different host resumes the session.
4. Session is revoked during an already accepted command. Which accepted actions can finish, and how does new World learn the outcome?
5. Economy restarts while a client sees a pending operation. How long are stable command results resolvable?
6. Backpressure, overload, cancellation and deadline: distinguish **cancelling response interest** from **cancelling a committed transaction**.

## Decisions to confirm

- Stable economic ID creation and recovery: server-generated vs client-intention-derived key; how a newly connected World recovers the **same ID** if the original World crashed before replying; collision/replay controls.
- Exact request/result envelope, authenticated identity proof, realm ID and session epoch, optional expected item/wallet revisions.
- Definitive versus ambiguous failure taxonomy and query-by-ID protocol.
- Bounds: per-account and per-host concurrency, queue deadline, receipt retention/replay window.
- Ordering: multiple independent commands per account vs one ordered per-account stream; commands depending on equipment/inventory revision.
- How a new World obtains outcome of a command initiated on an old World.

## Current code / migration

The present Shop/Exchange code already uses command IDs and durable receipts; auction search has separate per-session RPC correlation and native async scheduling. Those are useful existing behaviors, **not** proof that a new cross-process protocol is implemented. Do not swap the live RPC or database backend under this draft.
