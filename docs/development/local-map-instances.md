# Local MapInstance admission and isolation

First Stage 4 slice: one World, one economy and two independently simulated
First Region copies. Realm/map/instance/channel/host labels are distinct. Reuse
InstanceManager and ServerInstance; do not add a scheduler, service or database.

Follow-up implemented: [bounded admission and draining](instance-admission-lifecycle.md)
adds capacity, expiring initial reservations and idle/draining retirement to this
finite local topology. The original slice and its verification below describe
the baseline before that follow-up.

Guarantee: initial admission is server-owned and chooses the least populated
configured copy, counting pending entries. A peer can enter only its assigned
copy under the current authenticated session. Duplicate/foreign joins cannot
spawn another actor. Simulation, physics, mobs, Metins and transient loot are
instance-local; durable items, wallets and Marketplace remain World-wide.

Existing behavior changed deliberately: First Region starts two public copies,
and initial players are distributed between them. No player-facing channel
selector or active-player switch is added here. Entry waits for the chosen map to
be ready before publishing its path/identity. Disconnect removes its pending or
active membership. Unused unloading must not remove an instance with pending
entries. Failed/obsolete admission never silently redirects to another map.

Failure scope: map load failure must leave no registered half-instance. A stale
session must not receive an entry assignment after loading completes. Runtime
instance IDs are process-lifetime routing identities, never a replacement for the
persisted map key or durable economy identity. Local realm/host labels do not
implement multiple realm databases or cross-process placement/fencing.

Rollback: deploy matching client/World builds and restore startup copies to one.
No economic schema or saved-item migration is involved. Dynamic scaling,
capacity/reservations, public/private dungeon policy, draining and controlled
active-character transfer remain later slices.

Verification: existing RPC/session and PvE suites plus a focused two-client
multi-instance integration for the previously uncovered live-isolation boundary.
Use disposable data and real production manager/loading/join paths. Native UI,
multi-process hosting and automatic scaling are separate acceptance gates.

## Implemented boundary

`InstanceResource.map_id` is the stable content ID (legacy resources fall back to
`instance_name`). `instance_name` remains the saved map key. Each prepared runtime
has a random `map_…` instance ID, a per-map channel number, and configured local
realm/host labels. These are sent by the existing authority-only entry RPC and
stored on InstanceClient; they do not grant admission. The existing status label
shows the assigned CH. Client and World must be updated together.

First Region configures `startup_copies = 2`. Loading is indexed by runtime ID,
not by shared map resource, so two pending copies cannot collapse into one. Initial
routing chooses the least populated configured copy, counts pending entries and
breaks ties by channel. It publishes only after map readiness and rechecks the
captured session. A join additionally verifies current peer/character authority,
the session-qualified pending assignment and manager ownership. Removing a peer
from an unrelated instance is a no-op, avoiding redundant cross-map checkpoints.
Each 3D ServerInstance retains its own World3D and physics/navigation space.

This is initial admission to a finite configured set. There is no capacity limit,
reservation timeout, automatic CH creation/retirement, CH selector or transfer
countdown yet. Pending entries retire on disconnect/session invalidation; public
startup instances stay loaded. Local realm/host metadata does not partition the
existing SQLite economy into multiple realms or authorize another process.

## Verification — 2026-10-16

- Standard smoke: 10 Godot fixtures and 85 Web contracts, plus architecture guards.
- New opt-in `run-combat.ps1 -Scene local_map_instances -MarkerPrefix LOCAL_MAP`:
  real manager/client entry, identity and roster isolation, foreign/duplicate join,
  movement/combat/pickup RPC rejection, a collider present only in one physics
  space, local Metin damage/waves, private ground loot and a cross-copy Shop sale
  with shared UID custody, buyer wallet and seller revenue. It covers revoked
  admission while loading and rejects a non-GameWorld scene without registering a
  half-instance. That negative content test deliberately logs its named error.
- Existing World RPC admission, account/Gateway/native-session suites,
  combat-feel and two-client Marketplace regression passed.
- `run-items.ps1 -WithSession` passed against three normal headless roles in an
  isolated project with empty accounts/World DB, complete generated imports and
  isolated profiles: both clients equipped items and re-entered through Master.
  The old fixture now checks actual roster membership and durable inventory
  fields rather than waiting for two players in one copy or comparing a live
  delivery sequence across entries. Graceful World shutdown through the Master
  dashboard passed. Original account/DB SHA-256 hashes remained unchanged.

The isolated preparation initially missed generated assets/translations and was
corrected before the successful full-process run. Existing certificate-store and
ObjectDB/resource teardown warnings remain. No native rendering/input, Linux,
release export, dense-load benchmark or multi-World result is claimed.
