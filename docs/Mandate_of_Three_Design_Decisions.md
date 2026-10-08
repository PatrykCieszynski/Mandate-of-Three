# Mandate of Three - current design decisions

Design note. This records the direction following discussion of world structure,
bosses, dungeons, parties, classes and QoL. It is not final balance or a complete specification.

## 1. One logical world

Avoid traditional Metin servers that split the community and manually selectable
CH1/CH2/CH3 channels. Mandate should have one logical world and one community.
Initially, each open-world zone may exist as a single instance.

If population eventually becomes too high, the backend can create transparent
overflow layers. Players do not select layers manually; layering is not for hopping
between respawns, and parties/friends may have affinity to the same layer.

Automatic layering is not implemented at this stage, but architecture should not
assume a zone always has exactly one instance.

## 2. Open-world Metins and bosses

Avoid the loop: fixed point -> respawn every 30 minutes -> players follow a spawn
route -> repeat. Prefer spawn regions: Metins, elite packs and bosses can appear
at different points within a region rather than one fixed location.

Player activity can build regional pressure. Normal grinding can lead to elite
packs, then Metins/minibosses, a larger event and a regional boss. Players should
trigger content through normal play rather than waiting for a timer.

## 3. Bosses

Bosses should be substantially more meaningful encounters than in classic Metin.
A strong polymorphed player should not erase a boss in 5-15 seconds.

An open-world boss should survive long enough to make the encounter noticeable,
have a few simple mechanics and encourage spontaneous cooperation. Preferred
mechanics: cleave/frontal, AoE, adds, a simple phase change, repositioning,
a vulnerability window or an object to destroy. Avoid raid bosses requiring
memorization of a dozen mechanics.

## 4. Dungeons and tiers

Base dungeon versions should have no entry cost. Higher tiers may require a key,
sigil or similar item obtainable in the open world, among other sources.
Higher tiers should primarily offer more materials per hour, a greater chance of
good drops and potentially additional modifiers.

Higher tiers should not be the sole source of basic progression materials.
Casual players still progress through open world/free dungeons; hardcore players
improve efficiency through harder tiers. Keys may be tradable, allowing open-world
farmers and dungeon farmers to have different economic roles.

## 5. Party design

Mandate should be more party-friendly than Metin 2 without requiring parties.
Preferred model: solo is fully viable; 2-3 players form a highly efficient sweet
spot; 4-5 tackle harder dungeons/bosses; larger groups do open-world events/regional bosses.

Normal grinding, quests and basic progression should be possible solo. Parties
increase options, efficiency and class synergies and unlock harder content without
requiring a rigid tank + healer + DPS model.

## 6. Classes and self-buffs

Every class should be a viable main able to farm a spot independently. Avoid a
main plus second-client Shaman required for buffs.

Each class should have its own skill/aura/stance supporting its basic combat loop,
not identical +X% attack for everyone:

- Warrior: heavy attacks, cleave, poise, armor penetration/knockback.
- Ninja: attack speed, crit, multihit, bleed/mobility.
- Sura: enchanted weapon, magic on-hit, sustain, debuffs.
- Shaman: elemental/spirit imbue, splash, attack speed, support utility.

## 7. Self auras versus party buffs

Class-defining self-buffs should generally be toggles/stances rather than short
timed buffs. Players should not need to recast a basic class-function buff every
few minutes.

Party buffs can last approximately 30-60 minutes and be weaker than the skill
owner's version. Support should help the party without being penalized for solo play.

## 8. Potions and basic consumables

Avoid the traditional buy 500 red potions -> farm -> return to buy more loop.
Basic sustain should not be a logistical tax on playing.

Preferred basic HP potion: infinite uses -> strong regeneration for around eight
seconds -> approximately 20-second cooldown. Exact values are balance placeholders.
The potion should not have 100% uptime: autopotion still has a role, defense/sustain
builds matter and harder pulls can overcome sustain. Autopotion should be normal
game QoL, not premium functionality.

## 9. Lure / capes

If gathering mob groups is part of basic combat, lure should not be consumable.
Preferred model: Lure/Taunt tool -> infinite uses -> cooldown -> attracts/aggros
mobs within a radius. It can be a skill, tool or classic cape equivalent without
consumable stacks.

## 10. Meaningful consumables

Limited resources can remain where they create real decisions: strong emergency
heals, boss elixirs, resistance consumables, revive items, special dungeon utility,
food and temporary power buffs. Basic combat should work without continuous
consumable purchases.

## Overall direction

Keep grinding, farming spots, mob groups, +0...+9, Metins, bosses, trade, a shared
world and simple readable combat.

Remove channel hopping, exact spawn-timer farming, required buff alts, consumable
tax, premium QoL, dungeons as the only worthwhile activity and bosses dying before
they can act.

A Metin-like MMO retaining its simplicity and social grind while modernizing
encounter design, classes, progression and QoL.
