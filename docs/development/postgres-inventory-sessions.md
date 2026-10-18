# PostgreSQL P3c — Inventory session fence and recovery barrier

**Opt-in backend proof; production World remains SQLite.** This extends
[P3b durable Inventory recovery](postgres-inventory-intents.md). It does not wire
PostgreSQL into Gateway, Master, World, CEF or the live login path.

## Authority and trust boundary

Master already issues World tickets and tracks their current token. This package
does not introduce another login or token issuer. The optional Economy projection
stores one grant per account: character, native int64 epoch, SHA-256 fingerprint
of an existing verified Master ticket, and `recovering`, `ready` or `revoked` phase.
The explicit `inventory_sessions` schema feature is version 1.

`submit_verified_inventory_grant(identity, expected_epoch)` is a privileged
control-plane API. **It does not authenticate the supplied identity or ticket
fingerprint.** `identity_from_verified_ticket()` only hashes a token already
verified by the caller. A future trusted Master-to-Economy bridge must validate
current issuer authority and order grant delivery; client or ordinary World
payloads cannot serve as that proof. That bridge is not implemented here.

Under the existing account lock, grant installation compares the expected epoch
and increments it for a replacement. Retrying the same current grant returns the
same epoch; a revoked grant cannot reactivate itself. Delayed installs with an
old expected epoch conflict. Revocation compares the complete context, so an old
disconnect cannot revoke a newer grant. These checks fence delegated state after
grant/revoke COMMIT; they do not prove a grant was authorized by Master.

Control operations share the bounded executor. `busy` or `outcome_unknown` is
not confirmed revocation/installation. Future integration must stop local new
admissions during transition and explicitly recover the control result. Failed
COMMIT closes the native session and is never automatically resubmitted.

## Inventory admission and already accepted work

`submit_session_inventory(context, id, action, uid, revision, position)` captures
only scalar context and arguments. The shared command owner checks the current
grant under the account lock **before** receipt lookup or new durable admission.
Wrong/revoked context returns `stale_session`; a recovering grant returns
`recovery_required`. Contextless receipted Inventory commands return
`session_required` once the account has a registered grant. Accounts without a
grant retain the prior opt-in behavior.

An Inventory operation durably admitted before takeover may still complete.
Revocation is not rollback of accepted work. Explicit resume uses the immutable
P3b body and original issuing character; a newly active alt cannot retarget it.
Session-scoped discovery/outcome/resume can recover the account's older intents.
Raw backend recovery APIs remain trusted technical APIs, not authenticated RPCs.
This fence covers receipted Inventory commands, not other economy domains or all
server-generated item creation/pickup paths.

## Recovery before dependent admission

A newly installed grant starts in `recovering`. The trusted owner must:

1. Discover and finish unresolved account Inventory intents using original IDs.
2. Fetch `submit_session_snapshot(context)` and apply the authoritative snapshot.
3. Submit its item-state marker through `submit_inventory_recovery_ready()`.

The final transaction holds the account lock, requires no pending Inventory
intent anywhere on the account, and compares the marker's account, character,
authority identity and current account item revision before setting `ready`.
A completion between snapshot and acknowledgement makes the marker stale.
The backend verifies the marker, not that a World actually applied it to RAM;
runtime reconciliation and its delivery owner remain future integration work.

Executor results retain their captured session context. Before applying a delayed
result, the future main-thread owner must compare it with the active context
(`same_context`). This package supplies the tag/helper, not an automatic live
result filter or a World cache. Native epochs stay int64, including beyond 2^53;
they must not be round-tripped through floating-point JSON numbers.

## Verification and remaining work

Run the disposable runner with `--suite inventory-sessions`; see
[P3c evidence](../evidence/postgres-p3c/README.md). Native lock barriers cover both
admission-before-takeover and revocation-before-admission, stale result context,
alt recovery, snapshot freshness, failed COMMIT without retry, and reopen.

Actual issuer validation/delivery, World/runtime reconciliation, endpoint and
client retry integration, handoff with pending Yang, other domains, and P4 load,
soak and cutover remain open. No full C5, multi-World, Linux or physical CEF claim.

The follow-up [P3d runtime owner](postgres-inventory-runtime.md) adds opt-in
World-thread recovery and actual combat projection reconciliation; live issuer,
endpoint and publication wiring still remain separate integration work.
