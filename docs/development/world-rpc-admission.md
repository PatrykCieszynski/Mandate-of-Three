# World RPC admission — A2

Implemented on `codex/world-rpc-admission`, based on main after A1 (#6).
This hardens the generic World `_data_request` ingress and legacy instance entry.
It preserves RPC signatures and existing handler domain validation.

## Admission contract

- Client operation names must be in the literal `DATA_REQUEST_TYPES` allowlist.
  Adding a script file alone does not expose an operation. The handler base class,
  unknown names and resource-path traversal are not public operations.
- The RPC sender must have a server-authenticated PlayerResource with a positive
  character ID and account name, matching `current_peer_id` and the reverse
  character-to-peer map. Client payload fields cannot select that identity.
- An explicit instance ID must name a direct ServerInstance child of the manager
  and contain that peer in its joined membership. IDs are not NodePaths.
- An omitted ID resolves the peer's own joined instance. Unknown IDs never fall
  back to the default map. Pending/awaiting membership alone does not admit
  generic data requests before entry completes.
- Legacy actor/resource identity must match the authenticated session. A 3D
  instance must also contain that peer in its GameWorld characters.
- Invalid context returns the existing numeric `ERR_UNAUTHORIZED` error in a
  correlated `{ok:false,error:...}` response. Unlisted operations return
  `ERR_INVALID_PARAMETER`; no arbitrary script is loaded first.
- Legacy `ready_to_enter_instance` requires authenticated current-peer identity
  and the server's awaiting assignment for that specific instance before spawn.

The allowlist retains the existing public handler names. It is not a new role or
service permission system; handler checks for ownership, staff permissions,
range, targets and economic invariants remain necessary. Authenticated requests
before actual instance entry now fail closed instead of using the default map.

## Existing production 3D boundary

The 3D map already admits entry through authenticated session data plus its
server-owned awaiting assignment. Its gameplay endpoints use map-local actor
membership and domain checks; this slice does not reroute those RPCs through the
legacy generic dispatcher or alter their network protocol. PvE regression covers
that existing flow. This is not a claim that every legacy endpoint has been
exhaustively security-audited.

Single-active-character admission, handoff token expiry/revocation, session epochs
and cross-process fencing remain separate work. No database schema, Economy
transaction or per-hit SQL access is introduced.

## Verification

```powershell
& ./tests/run-combat.ps1 -Scene world_rpc_admission -MarkerPrefix WORLD_RPC
& ./tests/run-pve.ps1
& ./tests/run-smoke.ps1 -NodeExecutable /absolute/path/to/node
```

Network checks use port 18098 sequentially. The new fixture uses two real
WebSocket clients, the production World dispatcher, instance lookup and handlers,
with controlled session/map admission and no database. It protects previously
uncovered cross-instance and script-path risks:

- unregistered, wrong-peer, wrong-owner, wrong-actor and awaiting contexts;
- valid explicit/inferred scope with distinct per-client progression;
- forged, other-instance, absolute/relative and unique-name-like IDs;
- unknown operations, base-class invocation and resource-path traversal;
- restored legitimate access after rejected context;
- missing/present 3D actor membership and a legitimate world-scoped handler;
- attempted legacy spawn through another instance RPC path.

The test constructs session bindings directly. It does not prove real Master
handoff/reconnect; A1 identity/session coverage and the existing authentication
path remain separate. The shallow 3D admission map does not test rendering or AI;
the existing production two-client PvE suite covers actual 3D gameplay.
