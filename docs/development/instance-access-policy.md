# Local MapInstance access policy

## Contract before implementation

The local manager currently treats every copy of a map resource as a public CH.
Creating a private copy with the same resource would let ordinary initial routing
select it. Current-session checks alone do not express permission to enter a run.

This slice adds explicit PUBLIC / RESERVED runtime policy. Public copies retain
normal initial routing; reserved copies require an explicit server-selected
target and a positive character ID in a server-owned allowlist. Shared map content
does not imply shared access. Private copies have channel zero and are never used
as fallback public capacity. Instance IDs are routing addresses, not credentials.

Reservation and final join both enforce access. Revoking a pending character's
access prevents publication/join and retires its reservation through the existing
cleanup. Existing actors are not evicted by allowlist changes. Capacity, deadline,
session replacement and draining behavior remain the same for both policies.
There is no active-character transfer, party/invite protocol, dungeon content,
lockout/rejoin persistence, protected reward or multi-host authority in this slice.

The API remains server-only. A network payload cannot select a policy or mutate
membership. Unknown policy, empty/invalid membership and private legacy 2D content
must fail closed without leaving a registered half-instance. Rollback uses the
previous matching build and needs no persistent migration.

Verification extends existing instance/network fixtures, not default CI: real
forged private-path join/input/combat/pickup, authorized pending entry checks,
public routing with private copies, revocation/replacement, capacity/draining and
the existing independent simulation/shared economy scenarios.

## Implemented boundary

`ServerInstance.AccessPolicy` has explicit PUBLIC = 0 and RESERVED = 1 values.
The policy and copied `PackedInt64Array` of allowed character IDs remain server
runtime data; they are not sent as client credentials. `charge_reserved_instance`
creates a 3D run with channel zero. `admit_peer(peer, resource, target)` publishes
only a validated initial assignment, using the same ready/session/deadline logic
as default admission. `reserve_entry` can be used without publication internally.
Explicit targets must belong to this manager and the requested content resource.
An already joined or pending peer cannot replace its context with another target.

Automatic selection considers only PUBLIC copies. A map with only reserved runs
can still lazily create public capacity; a full public set does not spill into a
reserved run. Legacy public loader callbacks also skip reserved pending copies.
Reserved runs do not consume public channel numbers. Their retirement uses the
same idle/draining gates but ignores the shared resource's public startup flag.

Legacy warper, recall and jail routing use `find_public_instance`, which selects
only loaded, owned, accepting PUBLIC copies rather than the resource array's
last entry. Deferred public-load callbacks skip draining/retiring copies too.
Legacy cross-instance transfer and staff teleport revalidate the destination and
current source/session before checkpoint or despawn. RESERVED, unsupported 3D,
draining, stale and foreign targets leave the source actor in place. A failed
checkpoint also leaves both memberships unchanged. This safety check does not
implement the future 3D transfer/handoff flow.

Pending access is checked again before publication and actual join. Maintenance
releases revoked reservations and uses the existing matching-session rejection /
disconnect path. Allowlist mutation is a trusted server action; changing it does
not transfer or forcibly remove an actor already in the run. Run membership
survival across reconnect/restart is not implemented by this runtime list.

Production entry still uses the two public First Region copies. No private run
is provisioned for real players until a future authorized gameplay service uses
the explicit server API. No new RPC, frontend control or database field was added.

## Verification — 2026-10-16

- Standard smoke: 10 Godot fixtures, 85 Web contracts and architecture guards.
- Existing two-client local MapInstance fixture passed in both modes: normal two
  public copies, and test-only reserved initial entry for one authenticated
  character alongside public entry for the other. Production manager publication,
  client loading and actual join run unchanged. Both modes retain foreign-path
  join/input/attack/item/currency rejection, physics/Metin/loot isolation and a
  real cross-copy Shop sale with UID custody, buyer wallet and seller revenue.
- Extended cases reject empty/invalid membership, unknown policy, a legacy 2D
  run and another manager's explicit target. They cover copied membership,
  private-only registry/public provisioning, pending target protection,
  access revoked before join, and private retirement for shared startup content.
  Existing deadline, replacement-session and draining checks also pass.
- Review regression: PUBLIC CH1 + CH2 followed by RESERVED CH0 never selects the
  private copy through the legacy public helper. Controlled legacy source and
  checkpoint fixtures verify no despawn/checkpoint for rejected targets and no
  despawn or destination reservation after checkpoint failure. That deliberate
  failure logs the named transfer-cancelled error.
- Existing World RPC ingress and native World session admission regressions pass.
- Normal Gateway/Master/World `run-items.ps1 -WithSession` passed in a disposable
  project, including both clients equip/relog and graceful World shutdown through
  Master. Original account/SQLite SHA-256 hashes remain unchanged.

No native CEF/input, Linux, release export or dense-load result is claimed.
Existing certificate-store and resource teardown warnings remain. These are
runtime access guarantees, not a shipped dungeon/party/rejoin feature. No new
test suite or default CI expansion was introduced.
