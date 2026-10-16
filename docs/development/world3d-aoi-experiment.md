# World3D spatial AOI — first experimental pass

Branch: `experiment/world3d-spatial-aoi`. **Draft; do not deploy before network regression.**

## Current behavior

- Authoritative World positions and MobSystem state remain global. Only outbound
  replication is filtered.
- A 16-meter XY-plane grid (world X/Z) is rebuilt at the 20-Hz player snapshot
  boundary. A viewer **enters** actor/mob interest within 48 m and **exits**
  beyond 56 m (hysteresis). The viewer always sees its own player actor.
- A change in visible **player** membership sends a *reliable full roster* to
  just that viewer. Existing `receive_roster` spawns/despawns the client
  actors. Public weapon projection is explicitly resent upon AOI re-entry.
- 20-Hz **unreliable player position** snapshots include only visible players.
- 10-Hz **reliable combat state** now sends only the viewer's visible mob
  snapshots. The client MobSystem uses full replacement for its local visible
  mobs, so out-of-range mobs are despawned. Mob records are captured only for
  visible mobs and reused among viewers for the same send.

## Not done in this pass

- No field-delta codec, sparse per-actor change notifications or priority
  scheduler. AOI is **not** a delta-compression implementation.
- Combat state remains reliable, including mob positions. Splitting movement
  into unreliable ordered channel and reliable events requires its own test.
- Damage/swing/hits and public equipment updates still use broad event
  notification; this work only filters high-volume positions and mob snapshots.
- No visibility-based entity authority, hidden object protection, or change to
  combat validation; distance/line-of-sight checks are still server-side.
- No cross-map replication, per-party visibility rules, or interest-metric
  benchmark yet.
- The AOI refresh is currently every player snapshot tick, not dynamically
  throttled. Update cadence / dead reckoning is a separate work item.

## Minimum acceptance checklist before merge

1. `godot --headless --path . res://tests/world_interest_grid.tscn`
   prints `WORLD_INTEREST_GRID_OK`; negative cells, enter/exit hysteresis,
   invalid viewers and local self are checked.
2. Existing network tests (especially `spike3d_network`, `pve_network`,
   `shop_network`, `market_network`) still pass across clients.
3. Run `tests/aoi_network.tscn` as a three-process integration case
   (`tests/run-combat.ps1 -Scene aoi_network -MarkerPrefix AOI` on Windows).
   It teleports one of two **real transport clients** across the AOI boundary
   and checks roster visibility exit/re-entry and self-visibility.
   Extend coverage for weapon state, mob entry/exit, and reconnect
   before merging. Existing 32x32 tests do not exercise AOI boundaries.
4. Instrument actual outgoing bytes and server tick CPU for comparison to
   the unfiltered baseline; do not confuse client count with entity count.
5. Evaluate reliable mob snapshot channel and global combat events before
   claiming production-ready AOI.

The goal is to cut `players * all_players` and `players * all_mobs`
broadcast work when populations are **spatially spread out**. The worst-case
dense fight still has quadratic replication fanout. Real player load tests
remain necessary.
