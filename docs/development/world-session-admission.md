# World handoff ticket and session admission

This follow-up to [A2 RPC admission](world-rpc-admission.md) closes the previously
unbounded World ticket lifetime and overlapping account login window. It is a
single-World runtime boundary, not the future distributed C2/C5 session registry.
No database schema or public client message format changes.

## Invariants and behavior

- Trusted Master handoffs retain an account, character ID and monotonic expiry;
  they do not retain a character snapshot. Default lifetime is 30 seconds.
- At most 1,024 unused/pending tickets are retained, with one outstanding attempt
  per account. A new handoff replaces that account's unused or pending attempt,
  including at capacity. These limits are WorldServer export properties.
- Authentication accepts a serialized String up to 1 KiB. The ticket is consumed
  before the first yield. Unknown, expired, revoked and replayed tickets cannot
  acquire authority. An invalid/replayed ticket does not kick an active player.
- A valid replacement closes all previous game peers of that account through the
  WebSocket transport. It waits for their normal disconnect subscribers before
  completing authentication, for at most two seconds and never past ticket expiry.
  Failed cleanup denies the new admission rather than overlapping authority.
- Only the native `peer_connected` event, after **both** sides complete auth,
  installs the current character/peer binding. A half-open handshake cannot own a
  character. SceneMultiplayer's normal three-second authentication timeout remains.
- Character state is loaded at admission, after old-session checkpoints, using
  existing dirty progression recovery if a checkpoint failed. Existing immediate
  item transactions and wallet/progression checkpoint rules are unchanged.
- InstanceManager refuses a native connection without an admitted current-owner
  binding. It does not create an assignment for a cancelled/expired admission.
- Unused tickets are pruned once a second and before validation/issuance; expired
  pending auth is closed too. A new Gateway login revokes unclaimed tickets and
  pending auth through Master before the existing character kick.

The previous A2 last-login-wins disconnect guard remains: an old peer cannot clear
another peer's current character binding, runtime equipment or account state.

## Master notification identity

Master retains the latest issued `{world_id, token}` for each account. Ticket
issuance on both login and character creation registers this identity. World
reports `player_disconnected(username, session_token)` for current disconnect,
ticket expiry, capacity rejection and failed authentication of a consumed ticket.
Only the registered World and matching nonempty token may retire that marker.
Duplicate, wrong-World and delayed old-token notifications are ignored.

New Gateway login removes the old marker before kicking; World connection loss
retires that World's remaining markers. A delayed login response checks that its
ticket still owns the marker before returning credentials to Gateway.

Before asking World to validate a login or create a character, Master also stores
one current **entry attempt** per account. Its random `attempt_id` is echoed by
World and checked against the World peer, Gateway peer, request ID, operation and
requested character **before** any account update or token registration. New
login, newer enter or creation invalidates the previous attempt. Matching replies
consume the attempt once, including failures. Stale/duplicate replies issue no
ticket and no Gateway response that could preempt a newer successful reply.
Gateway's existing revocation/deadline handles the superseded HTTP request.

Attempt records have a 30-second deadline, are pruned on new work, and are capped
at 1,024 (one per account); World loss removes that World's outstanding attempts.
This identity is separate from a Gateway request ID, which may be reused after a
restart. A superseded creation may already have committed the character in World;
ignoring its reply denies automatic login but does not undo durable creation.

This is an **internal Master–World RPC signature change**. Deploy/restart Master
and World together; mixed versions are unsupported. Login/create requests and
results now also carry `attempt_id`. Neither identity is logged.
Client authentication and gameplay operation envelopes remain unchanged.

The authoritative native handshake APIs are documented in
[SceneMultiplayer](https://docs.godotengine.org/en/stable/classes/class_scenemultiplayer.html).
In the tested engine, its `disconnect_peer()` suppresses local disconnect signals;
the underlying WebSocket peer's normal close is necessary to run existing World
and instance cleanup. Do not replace it with the SceneMultiplayer shortcut.

## Verification

`tests/run-account-identity.ps1` now also runs `world_session_admission`:

- real loopback WebSockets and production World authentication/cleanup;
- unknown, expired, superseded, revoked and already-consumed ticket rejection;
- ticket capacity and same-account replacement at capacity;
- same-character and different-character account replacement;
- progression and pending Yang changed **after** ticket issuance survive replacement;
- delayed duplicate disconnect cannot clear the new current-owner binding;
- old/wrong-World/duplicate notifications cannot retire the current Master marker;
- unfinished native handshake times out without granting authority;
- replacing a pending handshake admits only the new attempt.

The fixture uses disposable SQLite plus in-memory Master accounts. Only the
Master transport and post-auth presentation pushes are substituted. It does not
load actual Master accounts, start production services or display game windows.
The existing account identity, Gateway lifecycle and menu transport cases remain.
Run the two-client A2 RPC fixture and PvE sequentially for regression coverage.

The same runner includes `master_entry_attempts`, protecting the review-discovered
race absent from the original World fixture. It uses real Master–World RPCs and
the production Gateway request methods and Master result callbacks, with a
controlled World worker and captured Gateway output. It covers login revocation,
both reply orders for competing enters, creation/enter supersession, duplicate
success/error replies and reused request IDs after another login. Assertions
observe emitted tickets, terminal responses and account status, not a fake call
to `register_world_session()`.

### Full process verification — 2026-10-15

Ran `tests/run-items.ps1 -WithSession` against **three normal headless processes**
(Gateway, Master, World) using a disposable project copy with current server code,
empty account collection, empty World DB and isolated client profiles. No server
handlers or RPCs were substituted. Discord configuration was empty in that copy.

- `items-unit`, `inventory-grid`, `items-session-1`, `items-session-2`: PASS.
- Both clients created guests/characters, authenticated, equipped items, checked
  revisions/public equipment and re-entered through Master after disconnect;
  exact UID, rolls and placement survived reconnect.
- Normal World shutdown through the Master dashboard drained/checkpointed: PASS.
- SHA-256 of original project account collection and World DB: unchanged.
- No script/parse/RPC signature errors in server logs. Existing ObjectDB/resource
  teardown warnings remained; this is not evidence for native rendering/input.

Additional regression: all account/Gateway/admission cases and standard smoke
(10 Godot cases, 78 Web contracts and architecture guards) passed. The disposable
copy was removed; diagnostic logs stay under
`.godot/verification/session-review-logs/` (ignored).

## Limits and rollback

This does not implement distributed fencing, durable session ownership, an
admission acknowledgement/retry protocol or recovery of Master session markers
after a Master restart. Initial connection/ticket delivery still uses the existing
Master handoff flow; admission failure requires another world-enter attempt.
It does not claim an exhaustive audit of every legacy direct RPC endpoint.
The full process check above covers login/item reconnect with isolated accounts;
native gameplay/rendering remains a separate milestone check.

Rollback is a coordinated code revert on Master and World. There is no schema
migration, persistent ticket ledger or data conversion to reverse.
