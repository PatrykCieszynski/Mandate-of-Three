# Loot V2 P2 — validated ordinary item pool

This is the standalone **pure item-selection step** in [mob categories/loot roadmap #42](https://github.com/PatrykCieszynski/Mandate-of-Three/pull/42). It does not yet touch the prototype `KillRewardResolver`, `GroundLootSystem`, World3D inventory or currency persistence.

- `LootEntry`: canonical `ItemDefinition`, absolute `chance_bp` (0–10000), inclusive quantity min/max bounded by the item's `stack_limit`. Unregistered or duplicated item resources are rejected.
- `LootTable`: explicit list of such entries. The World caller chooses sources (global, region, category, mob). `null` sources are optional.
- `LootResolver.resolve(tables, base_attempts, luck_chance_bp, rng)`: validates **all** combined entries before consuming RNG. Each entry retains an absolute per-attempt chance (in basis points). The combined sum must be ≤ 10000; leftover probability is **no item**. No automatic fourfold roll, normalization, chance boost or hidden override.
- Base attempts are supplied by the spawn-frozen value from P1 (1–4). `luck_chance_bp` is server-computed at death (0–10000); it gets exactly **one** roll for +1 extra ordinary attempt, never a chance per base draw. Maximum is 5 attempts.
- Every successful attempt returns an ordinary outcome `{definition_id, amount, affixes: []}`. This layer does **not** roll item rarity/quality or create a persistent `ItemInstance`, UID or ownership. P3 will resolve optional equipment affixes and safely mint durable ground entries once at death. Never reroll a death outcome at pickup.
- Yang/XP, guaranteed boss rewards, quest-only items and time-gated event/season drops are **separate** reward sources and are unaffected by generic ordinary Luck by default.
- No borrowed models, map edits or economy SQL changes.

Test using `./tests/run-smoke.ps1` (new `tests/loot_resolver.tscn` scene). Test fixtures exercise seeded reproduction, 0/100% chance, no-drop, four source aggregation, stack limits, invalid canonical items, probability overflow, 1–4 attempt bounds and 0/20/100% Luck.
