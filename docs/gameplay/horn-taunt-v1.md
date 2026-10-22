# Horn Taunt V1

Three server-owned horn tiers, shared **12 m** horizontal detection range and **4 s** cooldown:
- Basic: 15 mobs
- Improved: 25 mobs
- Advanced: 40 mobs

Press **H** to request a horn use. Only the server determines the tier, selects nearby individual mobs and advances cooldown. The client cannot request a tier or specific mobs. Basic is the default; assigning/upgrading an unlocked horn tier from equipment/progression is deferred. `HornTaunt.set_tier(peer_id, tier)` is exclusively for trusted server-side callers and current tier state resets on disconnect.

Selection rules:
- Choose the closest eligible individual idle/wandering mobs, regardless of pack composition; deterministic ID tie-break.
- Each selected mob must be within 12 horizontal metres, and its player must remain within that mob pack's leash boundary.
- Do not replace targets of mobs already fighting; ordinary attacks still use pack aggro.
- At most the horn's cap can be recruited in one activation; cooldown is consumed even when no mobs qualify.

Deferred: proper horn item/unlock/equip UI, visual/audio feedback, upgrade progression, explicit error feedback on cooldown and fine balancing. Do not market improved/advanced horns as player-unlockable until equipment/progression hooks exist.

Horn activation is a live simulation action, not an economic mutation. It checks
World availability, an existing living actor and the local transfer gate; it does
not use the legacy synchronous economic-write guard. Inventory/Wallet PostgreSQL
owners therefore do not disable taunting. Failed admission does not consume the
cooldown. Item custody, tier unlocks and persistent item USE remain deferred.

Verification: `tests/horn_taunt.gd` is part of default smoke and covers selection,
the production `try_use()` path with PG owner presence, cooldown, death/missing
actor, transfer refusal and preservation of another player's target. The PG owner
fixture exercises admission only; it does not start a PostgreSQL database.

The new GameWorld RPC ships with build version 0.30.0. Restart server roles and
clients together; the existing Gateway version gate rejects older builds.
