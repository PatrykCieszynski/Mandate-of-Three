# Bounded local MapInstance admission and draining

Follow-up: [explicit instance access](instance-access-policy.md) separates public
startup copies from reserved runs of the same map content. Reserved runs use idle
retirement even when that shared map resource has public startup copies.

## Contract before implementation

The previous slice counts pending entries for balancing, but never expires them,
has no capacity gate and keeps startup copies alive unconditionally. A client
that never finishes loading can reserve space indefinitely.

This slice bounds initial 3D entry inside the existing manager. Each map has a
configurable player limit and entry timeout. Connected plus pending players count
against capacity. Reservation, validation and consumption run on the World main
thread without an await between capacity selection and reservation. Retries reuse
the original deadline; a late join cannot revive an expired reservation.

A draining copy rejects new reservations but honors existing unexpired entries.
Its players keep playing. It closes only after both active and pending membership
are empty. Non-startup copies also retire after an idle delay and minimum lifetime;
startup copies remain unless explicitly drained. No live actor is moved or killed
to rebalance. Expired or rejected initial entry disconnects only the matching
current session, allowing the existing reconnect/login flow to recover.

No new queue, worker, database, autoscaling threshold, client CH selector or active
player transfer is introduced. Full/draining capacity is rejected, not queued.
Limits are configurable safety bounds, not measured hosting-capacity promises.
Legacy 2D transfer policy remains separate. Rollback deploys the preceding matching
client/World build; no persistent schema/data migration is involved.

Verification extends the existing local MapInstance fixture for capacity,
expiry/retry, session replacement, grandfathered reservations and safe retirement.
Existing World admission, live local-copy isolation and smoke suites remain gates.

## Implementation

`InstanceResource` owns four local 3D settings: `max_players` (default 64),
`entry_timeout_seconds` (30), `idle_timeout_seconds` (60) and
`minimum_lifetime_seconds` (60). These defaults are prototype safety bounds;
they are not a measured CCU recommendation. Initial routing stays within the
configured set. If every copy is full or draining, the initial connection closes
through normal World cleanup; the client uses its existing disconnect feedback.
There is no waiting queue or dedicated map-full popup in this slice.

`InstanceManagerServer.reserve_entry()` validates the current peer/character
owner, reuses an existing reservation without extending it, selects an accepting
copy, and reserves synchronously. `has_valid_entry()` checks the deadline again
before publication and the actual 3D join. A one-second lifecycle sweep reclaims
expired/obsolete entries, including instances still loading. A session denied or
expired stays rejected until disconnect or replacement; transport teardown cannot
be raced to obtain a fresh deadline. Disconnect releases its reservations.

`begin_draining()` is a server-only local API on an owned 3D copy, not an RPC.
Preexisting valid reservations can finish joining; no new ones are admitted.
An empty draining copy retires on maintenance, even if it was a startup copy.
An accepting startup copy stays loaded. Other empty copies wait for both minimum
lifetime and idle grace. Queued-for-deletion instances cannot receive entries;
the existing exit callback removes their loaded/loading registry entries. Once
all copies have actually retired, a subsequent initial entry may recreate one
using the existing on-demand loader. There is no automatic replenishment of the
startup set or occupancy-based provisioning in this change.

The manager scans local instance membership once a second; it adds no SQL to
admission checks or combat. Expiry is enforced at join regardless of sweep timing.

## Verification — 2026-10-16

- Standard smoke: 10 Godot fixtures, 85 Web contracts and architecture guards.
- Extended existing `local_map_instances` two-client fixture: pending capacity,
  duplicate deadline, full-set rejection without provisioning, drain preservation
  of members/reservations, timeout before sweep, no renewal during disconnect,
  stale callback against replacement session, registry cleanup and idle gates.
  Existing live physics/Metin/loot/RPC isolation and cross-copy sale still pass.
- Extended existing `world_session_admission`: real authenticated WebSockets,
  assignment received by a client that deliberately does not finish loading,
  full-map rejection through normal disconnect/Master retirement, timeout saving
  dirty progression and pending Yang, and successful relog into reclaimed space.
  The original ticket/replay/replacement/last-login-wins cases remain covered.
- Existing two-client World RPC admission regression passed.
- Normal Gateway/Master/World `run-items.ps1 -WithSession` passed in a disposable
  complete project: both clients equip/relog, then graceful World shutdown through
  Master. Original accounts and SQLite files have unchanged SHA-256 hashes.

All checks were headless. No native CEF/input, Linux, release export, automatic
scaling or dense-load capacity result is claimed. Existing certificate-store and
resource teardown warnings remain. No default CI suite was expanded and no new
test suite was introduced.
