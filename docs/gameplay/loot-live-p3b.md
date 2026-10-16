# Loot V2 P3b — first production item drops

**Dependent integration branch:** merges P1 (#45), P2 (#46) and P3a (#48) as prerequisites without changes to main. **Do not merge this before all three foundations** (and rerun CI after their final main merges). The wolf/bandit content PR (#47) can be integrated separately afterward.

## Active gameplay behavior

- World3D's **first region** passes a stable `first_region` content key into `KillRewardResolver`. Every individual live mob draws and freezes its ordinary attempt count at spawn (P1).
- On mob death, use the authoritative region/category/mob keys plus the captured attempt count to select four optional `.tres` data sources (`LootContent`), call the pure `LootResolver` (P2), and send successful outcomes to generic ground custody (P3a). Each item gets its own UID and freezes amount/affixes once on ground creation, before any pickup.
- One separate 30 Yang pile per mob and existing XP awarding remain unchanged. No loot is generated for an invalid combined authored table; the error is logged rather than silently normalizing the probability.
- Player Luck is **one bonus-attempt chance** read server-side from the already-authoritative `runtime_stats().get(&"loot_luck_bp",0)` at death. Existing gear has no Luck stat yet, so this is **0 by default**, with no new client command or untrusted stat. Future gear/affix content can expose the approved field.
- The **test arena** continues using the existing one-sword fixture for network combat/pickup tests until those scripted tests are migrated to explicit loot content. Metin **stone** guaranteed rewards still call the old explicit sword+configured Yang function; normal mob rewards are separate. No generic hardcoded weapon bonus on ordinary drop.
- The new materials are **original content**: Forest Resin (region), Worn Beast Hide (beast), Bandit Token (humanoid), Wolf Fang (specific forest wolf). Rare prototype Iron Sword is a mob-specific ordinary drop from Wild Dog or Road Bandit. Icons use the existing repo-owned `upgrade_ore` placeholder until original artwork is ready.

## Authored ordinary probabilities (per attempt, no hidden normalization)

| Source | Entry | Chance |
| --- | --- | ---: |
| Global | Upgrade Ore | 0.5% |
| First Region | Forest Resin | 3% |
| Beast | Worn Beast Hide | 8% |
| Humanoid | Bandit Token | 8% |
| Forest Wolf | Wolf Fang | 2% |
| Wild Dog | Iron Sword | 1% |
| Road Bandit | Iron Sword | 1.5% |

A Forest Wolf in the first region has **13.5%** chance of one stack per attempt; all other attempts may be empty. Four source tables still represent **one shared selection pool**. A different mob category changes source entries without changing the other probabilities. This is prototype balance subject to playtesting.

This PR intentionally **does not** implement quest/event/season item filters, equipment rarity tiers, new Lucky gear, player quantity multipliers, party loot, permanent personal quest rights or ground persistence across restart. P5 remains separate.

## Safety and checks

- P1 `mob_packs` covers per-spawn count and frozen death facts.
- P2 `loot_resolver` smoke covers independent rolls, odds, 0..100% Luck, item stack bounds, overflow and no item.
- P3a `ground_items` smoke covers UID/amount persistence, rollback, duplicate claim and replay.
- First-region headless test checks authored production table wiring, at most 4+1 ordinary attempts per mob, valid frozen ground records and **exactly one Yang pile per kill**.
- Run `./tests/run-smoke.ps1`, `./tests/run-first-region.ps1` and optional `./tests/run-metin-network.ps1`. Manually judge farm pacing, pickup density and balance before publishing live content.
