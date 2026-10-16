# Horn Taunt V1

Three server-owned horn tiers, shared **12 m** horizontal detection range and **4 s** cooldown:
- Basic: 15 mobs
- Improved: 25 mobs
- Advanced: 40 mobs

Press **H** to request a horn use. Only the server determines the tier, selects live packs and advances cooldown. The client cannot request a tier or specific mobs. Basic is the default; assigning/upgrading an unlocked horn tier from equipment/progression is deferred. `HornTaunt.set_tier(peer_id, tier)` is exclusively for trusted server-side callers and current tier state resets on disconnect.

Selection rules:
- Only fully idle/wandering packs within the caller's pack leash are eligible.
- At least one pack member must be within 12 horizontal metres.
- Entire packs are recruited, nearest eligible pack first. A pack that would exceed the remaining cap is skipped; this intentionally yields fewer than the tier cap rather than recruiting part of a pack.
- Never steal a pack already engaged with a player; no extra pathfinding or physics queries.
- The cooldown is consumed even when no pack qualifies. Server clock uses monotonic milliseconds.

Deferred: proper horn item/unlock/equip UI, visual/audio feedback, upgrade progression, explicit error feedback on cooldown and fine balancing. Do not market improved/advanced horns as player-unlockable until equipment/progression hooks exist.
