# Item progression

## Affix generation C1 — current foundation

The shared, pure `items/affixes/affix_generator.gd` accepts an ItemDefinition,
requested prefix/suffix counts, an authored pool and an explicit RNG. It returns
a complete decision or an error, never mutates an item, writes SQL or awards loot.
It is **not yet wired into production drops or crafting**; existing drop bonuses
and the independent +0…+9 upgrade state remain unchanged.

- Resource definitions specify identity, prefix/suffix kind, group,
  symmetric exclusion groups within the same kind, allowed base families/slots and integer-valued tiers.
  Each eligible definition/tier pair competes by its explicit positive weight.
  One chosen group excludes all its other definitions/tiers on that item.
  The cap is three prefixes and three suffixes, with no duplicate groups within
  each kind. Prefixes and suffixes have independent group namespaces: the same
  group name may appear once in each, and exclusions never cross the two kinds.
- C1 eligibility uses authored `ItemDefinition.affix_family` and `affix_level`,
  not character level or upgrade level. Empty family opts out. Iron Sword opts
  into the illustrative sword pool at base eligibility level 1. A future rolled,
  per-instance item level remains a separate design/content decision; no SQL
  column or implicit inference from old items has been introduced.
- Requested counts must be satisfiable along the selected path. A depleted or
  mutually excluded pool returns `insufficient_pool`, with no partial award,
  automatic retries or backtracking that would silently change probabilities.
  Candidate identities and tiers are sorted so authoring order does not affect
  seeded results. The caller owns RNG seeding/lifetime; tests use fixed seeds.
- The illustrative catalogue has four definitions: Keen/Tempered prefixes add
  attack; Swift/Balanced suffixes add attack speed. Each has a tier at level 1
  (weight 80) and a stronger eligible tier at level 5 (weight 20). Values are
  examples, not approved balance. C1 supports these two already projected stats;
  new stat effects need their own actual combat/projection implementation.

New stored rolls retain `stat` and the resolved `value` plus `affix_version=1`,
`affix_id`, `kind`, `group`, `tier` and the eligibility `level` used at creation.
They use the existing affixes JSON field and auction stat/value projection.
Loading validates structure, caps and duplicate groups per kind, normalizes JSON integer
metadata, and reads the **saved effect**, without looking up current tier values.
Changing/removing a catalogue entry therefore cannot reroll an existing item.
Live `validate()` additionally checks the current definition, tier, restrictions
and resolved value before a future mutation is allowed.

Legacy `{stat,value}` rolls remain unclassified and retain their old calculation
and tooltip behavior; no invented prefix, tier, item level or refund is applied.
Mixed legacy/versioned arrays are rejected: converting a legacy item for future
crafting needs an explicit policy in C3. UID, sockets, placement, revision and
upgrade level are independent of the new metadata. Existing CEF tooltips show
the real prefix/suffix kind for versioned rolls through the existing Alt labels.

Verification: smoke includes `affix_generation` (seeded selection, tier/family/
slot restrictions, exclusions, 3+3, bad definitions, legacy interpretation and
SOCI embedded reopen). PostgreSQL `--suite affix-generation` covers UID/effects/
sockets/+level preservation after reopen, both JSON formats and the existing
auction index. No schema migration, new currency or crafting UI is part of C1.

## Historical first progression slice

Status: 2026-10-07, branch `codex/item-progression-slice`. A small loop on the
existing instance model: kill a dog -> see its ground weapon -> pick up -> compare
-> equip -> deal new weapon damage -> retain it after relog.

## Gameplay behavior

Loot remains an iron sword with a server-rolled +1...+9 attack bonus. Ground labels
and pickup notices show that weapon's attack, 11...19. Pickup adds it to the bag
without automatically equipping it.

The I panel shows character attack and the current weapon. The equipped instance
comes first, then the latest pickup marked as new, then remaining items sorted by
attack. This is presentation order; bag placement, snapshot and SQLite state are
unchanged. The name tooltip contains the UID.

Each bag weapon shows **character attack after equipping** and the difference
from the current weapon. Green means higher attack, red lower, gray unchanged.
Preview subtracts the equipped instance's attack and adds the compared instance:

| Situation | Current character attack | Found weapon attack | After equipping |
| --- | --- | --- | --- |
| Starter with +3 bonus | 23 | 19 | 29 (+6) |
| Starter with +7 bonus | 27 | 19 | 29 (+2) |
| Starter with +7 bonus | 27 | 13 | 23 (-4) |
| No weapon | 10 | 13 | 23 (+13) |

The difference concerns attack, not overall item quality. Combo hit three still
uses a 1.5 multiplier; other rules are now described in [Warrior combat feel](combat/warrior-combat-feel-v2.md).

## Server and persistence

Preview uses server-calculated instance stats and is not sent as a command.
Equip still accepts action, UID and revision; the server checks ownership and
atomically persists the swap. After commit it also refreshes runtime equipment/
stats. Combat reads RAM attack at swing start. The same first hit can therefore
deal 23 damage with the starter and 29 with a picked-up +9 sword.

UID, bonus, placement and revision survive relog. New-item marking and pickup
notices are session presentation, not new durable data. Reservation, full bags,
double pickup and durable claims follow the [first PvE slice](pve-ground-loot.md).

This stage changed no combat parameters, bonus rolls, two-sword starter set or
schema v11. It introduces progression through choosing a better instance, without
XP, levels, upgrades, rarities, crafting or new weapon types. Further progression
requires a separate scope decision.

The user subsequently selected [character XP and levels](character-xp.md).
That stage added schema v12 reward receipts while retaining the item model.
The later schema v13 refactor removes those XP receipts; current behavior is in
[persistence policy](../architecture/persistence-policy.md).

## Verification

```powershell
# Isolated database, server and two clients; normal servers not required.
& .\tests\run-progression.ps1

# Full login, comparisons and relog; requires gateway/master/world.
& .\tests\run-items.ps1 -WithSession

# Run sequentially with progression; these share port 18098.
& .\tests\run-pve.ps1
& .\tests\run-combat.ps1
```

Progression tests use production combat/pickup/equip RPCs. The fixture sets the
killed dog's drop bonus to +9 to remove RNG; production rolls remain unchanged.
It checks no pre-pickup grant, ground weapon description, exact UID, 29 (+6)
preview, no UI snapshot mutation, other-player inventory privacy, actual 23 -> 29
damage and identical persistence after SQLite reopen/initialization.
Markers: `PROGRESSION_SERVER_OK` and two `PROGRESSION_CLIENT_OK`.

Full inventory sessions verify better/weaker/equal weapon previews and a preview
without an equipped weapon. `tests/pve_session.tscn` additionally runs normal
gateway/master/world: dog kill, random instance pickup, comparison, equip and
relog with an identical snapshot.

`item-progression-preview.png` in `.godot/verification` was generated and inspected;
the new-sword comparison and equip button are visible without scrolling. Full
sessions also generate `pve-item-comparison-preview.png` and
`pve-item-equipped-preview.png`. All 873 source scripts/scenes/resources loaded
without parse errors. Earlier certificate-store and exit-resource diagnostics remain.

The retired native inventory renderer and its screenshot checks are removed.
The progression runner is headless; item state, RPCs and persistence checks remain.
