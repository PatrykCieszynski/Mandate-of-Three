# P5a — Event loot foundation

This slice adds only the server-side event drop execution seam. No concrete event, chest, schedule, event manager or persistent event state is implemented.

- `WorldEventDropService.set_active_rules(world_kind, rules)` atomically receives active rules from a future authoritative coordinator. World kinds: `classic` / `seasonal`; rule scopes: `classic` / `seasonal` / `all`.
- No active rules by default. The hot path exits immediately when the active list is empty; no SQL or time checks happen on mob death.
- Active events independently roll rewards (basis points), separately from ordinary `LootResolver`, Luck, Yang and XP. Outcomes use existing `GroundLootSystem` UID/transactional pickup.
- Rule admission validates canonical item definitions, stack quantity, unique event IDs, probability and scope. Failed updates do not replace the previous list.
- Bounded to 32 input rules and at most eight successful reward outcomes per kill. Policy for more simultaneous active events should be defined before production deployment.
- Deterministic tests in `tests/world_event_drops.tscn` are registered with the smoke suite.

Deferred: authoritative active-event coordinator, world identity source, schedules, admin controls, persistence/restarts, event-specific item/content, and full end-to-end multiplayer integration tests. This branch does not start any event.
