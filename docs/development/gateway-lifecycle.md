# Gateway lifecycle — A1

Implemented on `codex/gateway-lifecycle` (2026-10-15), based on the `shop`
integration branch. This is the first Infrastructure Hardening slice. It does
not implement World ingress authorization, active-character admission or C5
cross-process session epochs.

## Request contract

Gateway retains at most 1024 pending Master requests (configurable through
`max_pending_requests`). Overflow returns the existing `ERR_RATE_LIMITED` code
without allocating/forwarding work. Master unavailable returns the existing
retryable timeout; connection loss immediately fails already-pending callers.

All RPC responses now use the same response signal and terminal path. Response,
timeout and disconnect erase pending identity/deadline entries **before** resuming
the caller. Late/duplicate replies are ignored; monotonically increasing request
IDs are not reset at reconnect. Response admission rechecks its monotonic deadline,
even before the next physics tick. There is no per-request timer retained after
completion; the bounded pending set owns deadline state.

A timeout or lost connection does not imply Master rolled back an operation.
These transport request IDs are not durable economy operation IDs. Existing
Marketplace receipts remain the source of economic retry/idempotency guarantees.

## Gateway credentials

- Tokens remain cryptographically random 256-bit values.
- Default fixed TTL: eight hours, configurable as `session_ttl_seconds` (1–86400).
  Uses monotonic process time; requests do not extend the lifetime.
- Periodic pruning runs approximately once a second; access/result delivery also
  checks expiration directly. Gateway restart loses all its in-memory tokens.
- At most 10000 sessions (`max_sessions`); a new verified login for an account
  replaces its earlier Gateway token. This is not active-World session fencing.
- Retain only verified account ID/name, independently of the mutable login HTTP
  response, never the guest password or generated response token.
- `POST /v1/logout` accepts the same `t-id`/`a-u` credentials, revokes the token
  and rejects pending authenticated callers. The menu Logout sends this using a
  separate bounded HTTPRequest and immediately clears local credentials. If that
  request cannot reach Gateway, server revocation is not guaranteed; TTL and new
  login replacement still apply.
- Master connection failure/disconnect clears cached world roster, fails pending
  work and invalidates Gateway credentials. Reconnect requires credential login.

An authenticated response is delivered only while its original token remains
valid. Revocation cannot cancel a command already accepted by Master/World, undo
a committed mutation, revoke an already-issued World handoff ticket, or kick an
active World player. Those trust boundaries belong to A2 and session admission.
The one-active-character-per-account-per-realm C1/C5 target remains future work.

## Verification and limits

`tests/run-account-identity.ps1` reuses the populated SQLite identity/ownership
fixture and adds `gateway_lifecycle`. The latter uses the production Gateway
request/session code and real GatewayManagerClient reply/disconnect signals with
a controlled transport, no sockets or production accounts. It protects:

- repeated completion cleanup and one terminal result;
- bounded pending admission and freed capacity;
- timeout, stale reply, disconnect and reconnect isolation;
- verified identity replacing a forged account ID without changing the caller;
- logout, replacement, capacity, fixed TTL, pruning and expiry during a request;
- independent stored credentials without retaining guest secrets.

Existing identity coverage seeded a private sessions dictionary; it now uses
`create_session` so it respects the public credential contract. The focused
lifecycle coverage addresses failure behavior not covered by existing SQLite or
Web UI suites. Default smoke remains unchanged.

Headless identity/lifecycle and standard smoke passed (10 Godot cases and 78 Web
contracts). The production Gateway menu also booted headlessly in an isolated
profile without script errors. The live
`run-account-identity.ps1 -WithSession` still needs Gateway/Master/World and creates
fixture accounts. Native menu click/HTTP logout and live process reconnect are
separate integration checks; controlled transport does not verify them.
