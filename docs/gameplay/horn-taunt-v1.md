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
