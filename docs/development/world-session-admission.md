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

This is an **internal Master–World RPC signature change**. Deploy/restart Master
and World together; mixed versions are unsupported. The token is never logged.
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

## Limits and rollback

This does not implement distributed fencing, durable session ownership, an
admission acknowledgement/retry protocol or recovery of Master session markers
after a Master restart. Initial connection/ticket delivery still uses the existing
Master handoff flow; admission failure requires another world-enter attempt.
It does not claim an exhaustive audit of every legacy direct RPC endpoint.
Full live Gateway → Master → World acceptance and native gameplay remain separate
milestone checks; the loopback fixture is not evidence for those complete flows.

Rollback is a coordinated code revert on Master and World. There is no schema
migration, persistent ticket ledger or data conversion to reverse.
