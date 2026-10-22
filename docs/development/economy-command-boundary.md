# Economy commands, client intentions and recovery

Normal development uses PostgreSQL domain runtimes/workers. SQLite application
services and stores remain reference fixtures. See [persistence](../architecture/persistence-policy.md),
[Economy C1–C5](../architecture/economy/README.md) and [full-state setup](postgres-full-state.md).
The contracts below describe ownership and client recovery, not a distributed
Economy Service or permission to write economic state from World caches.

## Ownership

- Endpoints authenticate the session, resolve server-owned identity, validate
  command shape/context and enforce admission limits. UI correlation IDs are
  separate from durable economic command identities.
- Application/runtime owners coordinate the operation, pending-income capture,
  committed-state reconciliation and response publication.
- Stores enforce ownership, custody, revisions, capacity, affordability and
  atomic mutations with durable receipts where implemented. Direct callers must
  not bypass those checks. Never compose one purchase from independent payment
  and item commits.
- World keeps simulation state and economic projections. Combat reads runtime
  stats without SQL per hit. CEF owns presentation and sends explicit commands;
  it cannot authorize a transaction or declare its result.

## Stable intentions and receipts

A retry preserves the original command ID and immutable payload. Changing the
UID, action, receiving character, expected revision, placement or other bound
parameters creates a different intention; reusing an ID with a different
fingerprint must conflict. Transport retries must not invent another economic
operation merely because the response was lost.

A successful receipt replay confirms the original result. It is not another
commit and must not reapply pending income, item mutations, account change facts
or runtime effects. A replay must not roll newer state back to the original
snapshot. Refresh or reconcile the current authoritative projection instead.

Client journals preserve unresolved intentions across UI reload and process
restart for the operations that implement durable recovery. Persist the intent
before sending it; a journal failure must not silently send an untracked mutation.
A receipt lookup discovers an earlier result and must never become a new mutation.
An intention saved before send is not proof the server accepted it; follow the
operation's explicit retry/recovery flow rather than automatically executing it.

## Lost responses and authoritative refresh

Timeout, disconnect and UI reload do not prove rollback. Keep an unresolved
intention until its authoritative result is known. An explicit retry uses the
remembered payload, including the original destination, even if a newer snapshot
now shows the purchased item occupying that destination. Browser placement checks
must not block receipt recovery.

Inventory, Upgrade, NPC purchases and account-shared Storage use their existing
operation-specific admission and recovery paths. Do not generalize character-local
Inventory ownership to Storage: the latter shares account custody and must retain
the original issuer/receiver context needed by the durable operation.

Session generations prevent results from an old attachment from applying to a
new owner. A stale callback is not evidence that its database operation failed;
recovery still follows the original durable identity.

## Reconciliation after commit

Publish effects only after a confirmed transaction outcome. New commits and
receipt replay are distinct. Reconcile equipment/combat stats, inventory and
account wallet projections through their existing owners, rather than allowing
each window or endpoint to write caches independently.

Critical operations include the captured pending-income prefix in the same
transaction. Only confirmed application can consume that prefix; income earned
later remains pending. Versioned item/wallet state must prevent stale snapshots,
replays or callbacks from overwriting newer state. Shared-account changes must
respect the account ownership/locking contract across all affected domains.

For SQLSTATE-based whole-use-case retry, rollback proof and uncertain COMMIT
handling, see [transaction retry](postgres-transaction-retry.md). Never blindly
retry a mutation after an uncertain COMMIT.

## Verification and history

Use [testing](testing.md) to select the existing operation, network, journal and
recovery suites. Preserve tests of lost responses, restart recovery, changed
fingerprints, receipt replay, races and rollback. Routine pass counts, commands
and limitations belong in the PR description.

The original slice-by-slice implementation narrative, SQLite-specific class
extractions and dated results remain in [Git history](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/37827015b8536a5b7862cb092d86a7da79dcf988/docs/development/economy-command-boundary.md).
The completed PostgreSQL adoption is summarized in the
[migration milestone](../history/postgresql-migration.md).
