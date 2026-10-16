# Bounded local public-channel provisioning

## Contract before implementation

The finite public set currently rejects initial entry when all copies are full.
This slice may create one additional public copy on demand, only within explicit
per-map and process-wide instance limits and with recent measured CPU headroom.
Loading copies count immediately, and an accepting copy with spare capacity is
always reused. Reserved runs do not count as public CH, but do consume host slots.

The budget uses a bounded recent sample of actual engine physics/frame CPU time,
not player count as a CPU estimate. Missing/stale/invalid samples or observed tick
stalls fail closed. New creation resets the observation window and adds settling
time, preventing a login burst from allocating a series of new maps. Full,
draining or rejected contexts do not bypass session/access/deadline checks.

Only initial admission is affected. No player is moved from a loaded instance.
Demand-created overflow copies retire through existing idle/minimum-lifetime
rules, even when the shared map content has pinned startup copies. Explicitly
draining copies do not trigger automatic replenishment. There is no background
allocator, work queue, thread, new database or predictive CCU threshold.

Failure closes the initial connection through existing cleanup. Failed content
load must release the claimed host slot. Rollback restores the preceding build
and finite configuration, without schema or saved-state migration.

These are conservative admission guards, not a hosting-capacity or frame-time
SLA. Synchronous scene construction can still cause a transient main-thread spike.
Verification reuses local MapInstance fixtures for cap/burst/settling/failure/
retirement behavior and records a same-host First Region headroom observation.

## Implementation and configuration

- `InstanceResource.max_public_copies` defaults to 2 and bounds all local public
  copies, including loading copies. Startup configuration above this cap is
  rejected before partial startup. Reserved copies consume host capacity only.
- `InstanceManagerServer.max_host_instances` defaults to 8. All local hosts,
  including private, loading and queued-for-deletion copies, count until removed.
  Manual loaders cannot bypass these count limits. Failed preparation releases
  its loading registration before another allocation can claim the slot.
- `instance_provision_budget.gd` samples engine physics and process CPU monitors
  from the existing manager's physics callback. It retains at most 120 samples.
  Creation requires a full recent window, at least one second of observations,
  and sum of physics/process p95 below 75% of the physics tick budget (12.5 ms at
  60 Hz). Samples older than 250 ms, invalid values or a gap above two ticks fail
  closed. New instances reset the window and require two seconds of settling.
- Full accepting public copies can grow by one within these gates. Spare places
  are reused even during settling; duplicate entry preserves its original place.
  Draining copies are not replenished while still registered. The first map on
  an empty host may bootstrap without samples. Lazy creation of a map with no
  public copy on an already busy host still needs headroom; private-only content
  cannot bypass that guard. Explicit configured startup/private loading remains
  a trusted server action, bounded by counts rather than this automatic CPU gate.
- Demand-created overflow copies use existing idle/minimum-lifetime retirement,
  independently of the shared resource's public startup flag. No live players
  are evicted after a load spike or moved to free resources.

**First Region remains at two startup copies and maximum two public copies.**
The mechanism is available for explicit per-map configuration, but the observations
below do not justify enabling a third production First Region copy on this host.
Raising that map's limit requires a separate measured decision; this PR does not
silently tune combat/navigation to make the measurement pass.

## Verification and observations — 2026-10-16

Existing local MapInstance integration passes in both public and reserved-entry
modes. Controlled monitor inputs verify missing/stale/invalid/combined CPU costs,
stall reset, host and map limits, loading-slot accounting, failed load/reuse,
settling, burst reuse/deduplication, no drain replenishment and idle overflow
retirement. Actual map creation/reservation/readiness and lifecycle use production
manager code; injected metrics make these failure cases deterministic. Existing
foreign-RPC isolation and cross-copy economic settlement remain covered.

Short native-engine headless observations used the current Windows working-copy
content and two real socket clients, after three seconds of observation. These
are samples from this test, not repeatable clean-content capacity benchmarks:

| Scenario | Physics p95 | Process p95 | Guard |
| --- | ---: | ---: | --- |
| Two public First Region copies, final run | 18.781 ms | 12.302 ms | Deny |
| Two public + one reserved First Region, final run | 22.813 ms | 0.181 ms | Deny |

An earlier exploratory run observed 11.745 / 0.179 ms and allowed a diagnostic
third public copy. Scene construction took 1.672 ms, but the subsequent window
rose to 22.700 / 178.996 ms (including startup/harness work). This demonstrates
why current headroom is not a reliable prediction of the next map's cost. The
fixture temporarily permits three for that diagnostic and restores the production
limit; it never requires a particular performance outcome. Future growth needs
measured per-map cost/headroom decisions and dense-combat evidence.

Standard smoke (10 Godot / 85 Web), World RPC admission and native session
admission passed. Normal Gateway/Master/World `run-items.ps1 -WithSession` also
passed in a disposable project, including equip/relog and graceful World shutdown;
original account/SQLite SHA-256 hashes stayed unchanged. No new suite/default CI
expansion, SQL/network protocol or frontend change. Existing named negative-test
errors, certificate-store and resource teardown warnings remain. No native CEF,
Linux, release, dense-load SLA or multi-World result is claimed.
