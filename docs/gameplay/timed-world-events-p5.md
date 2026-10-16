# P5a — Timed event drop core (draft)

This slice only adds the **runtime event drop policy**. It does not enable an event by default. Quest drops and seasonal gameplay are out of scope.

## Runtime
- `WorldEventDropService.configure(world_kind, schedules, unix_now)` accepts an authoritative manifest, with world kinds `classic` and `seasonal`, and event scopes `classic`, `seasonal`, and `all`.
- Active event windows are refreshed once per second by the server World timer. The mob-death hot path uses only `active_drop_events`; an empty list exits immediately.
- Each active event gets its own 0..10000 basis-point roll, independently of ordinary LootResolver, Luck, Yang and XP. All outcomes pass into the existing GroundLootSystem UID/pickup flow.
- Timestamp values in the manifest are **Unix seconds**. Ground drop lifetime and ownership still use existing monotonic milliseconds from MobDeathResult.
- Snapshot replacement validates the complete manifest before publishing. A failed update retains the previous manifest.
- Up to 32 scheduled events are admitted and at most 8 successful event item outcomes are emitted per kill. Overflow beyond 8 is bounded, but event priority/budget policy must be decided before enabling stacked production events.

## Still required before production event activation
1. A server-side coordinator with canonical Classic/Seasonal world identification and fan-out to every instance/channel. **Do not infer this from map names.**
2. SQL storage of event schedules and restart-safe reload, with authorized admin operations to start/stop a two-hour event.
3. An original/licensed Moonlight Chest item definition and content policy; do not reuse material IDs as production chest rewards.
4. A kill-to-ground-to-SQL integration smoke and a multiplayer/server replay test, plus a manual test after restart and expiry.

No production event is turned on by this draft. Tests in `tests/world_event_drops.tscn` check the pure runtime policy; the default smoke runner includes the scene.
