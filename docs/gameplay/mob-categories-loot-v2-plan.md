# Gameplay roadmap: five mob categories and Loot V2

Status: **agreed design direction; implementation not started**.
Scope: World-authoritative 3D PvE in Mandate of Three. The intent is
content-heavy, dense pack combat with straightforward server-side movement,
not a new behavior tree, generic spawning framework, or economy refactor.

## Product decisions

1. **Five categories for launch:** `beast` (Bestie), `humanoid`
   (Humanoidzi), `undead` (Nieumarli), `demon` (Demony), and
   `construct` (Konstrukty). **No Mystic category** in the initial design.
   A mob has exactly one category.
2. **Family** is independent (e.g. wolves, bandits, skeletons); it groups
   variants/content within a category. **Rank** is independent
   (`normal`, `strong`, `elite`, `boss`). A rare spawn can use a
   separately authored mob variant or an explicit encounter loot
   policy; rarity does not need to be a sixth category or a second
   hidden loot multiplier. A category is neither a zone nor an
   aggro/AI mode. Future vs-category damage bonuses may use these IDs;
   **do not implement damage bonuses in this roadmap**.
3. **Loot sources:** optional global, map/region, category, and exact mob.
   The four scopes form **one consolidated ordinary-item pool**,
   not four automatic attempts. **When a mob spawns**, server RNG
   selects its base attempt count uniformly from the authored inclusive
   `min_rolls..max_rolls` range (1..4). A normal mob with `1..3`
   therefore spawns with 1, 2 or 3 fixed, private attempts. A
   replacement/respawn rolls a new count. **At death** the rewarded
   player's Luck offers a percentage chance of exactly one additional
   attempt (max five). Specific items/amounts/affixes are generated
   on death, **not on spawn**. Mob rank is separate from the drop
   table's per-attempt item probability.
4. **Models from external reference games remain on the developer's
   machine only** as throwaway prototype assets. No such models, textures,
   animations, binary imports, exported packs or their derived data may be
   committed/distributed. Keep client asset lookup via the existing
   optional `VisualResolver` path, **exactly as the current mob model
   integration works**: `MobDefinition.visual_id` -> curated logical
   `VisualResolver.MOB_IDS` -> optional local
   `res://dev_assets/legacy/mobs/<visual_id>/<visual_id>.glb` ->
   repo-owned `mob_placeholder.tscn` when the local file is absent.
   The existing optional `res://assets/final/mobs/<visual_id>.tscn`
   path remains for eventual original/licensed replacements. Add IDs,
   not binary assets; never preload missing local scenes in content.
   Use original/licensed visuals for public builds. No borrowed
   game-specific UI, item or mob nomenclature.
5. **Refactoring prototype reward systems is authorized where needed.**
   The purpose is real non-weapon and stackable drop support, not a
   rewrite of World wallets, the inventory transaction service or
   market receipts.

## Existing baseline (as of 2026-10-16)

- `MobDefinition` .tres, canonical `MobDefinitions`, `MobSpawnEntry`,
  `MobSpawnPoint3D` and `MobSystem` already provide content-driven
  health, damage, visual ID, composition, shared pack aggro and respawn.
  Four registered 3D profiles are all dogs; first region has 104 actors
  across six authored packs. The older 2D `EnemyTypeResource` catalogue
  is not a drop-in replacement for the current 3D model.
- `KillRewardResolver.handle_mob_death` currently spawns one iron
  sword with an attack affix and one fixed Yang pile **for any mob**.
  `GroundLootSystem` persists just `definition_id` and weapon
  `bonus` in a live ground-drop record, and reconstructs a weapon
  `ItemInstance` on pickup. It cannot yet create normal materials,
  non-weapon gear or stack quantities.
- `ItemInstance` already has UID, definition ID, amount, affixes, owner,
  revision and custody. Its `amount` and the item's `stack_limit`
  should be used rather than introducing a parallel item model.
  Ground-item pickup currently commits via
  `claim_ground_item_operation` and refreshes Inventory only after
  commit. Preserve that authority and ordering.
- `MobDeathResult` is a frozen death fact carrying `mob_key`, position,
  contributor, owner and XP; it does not yet carry map/region identity.
  Region context must come from authoritative World content, never from
  client payload or untrusted coordinates.
- `VisualResolver` already separates visual IDs from gameplay profiles
  and has a local-only prototype asset convention. Prototype assets are
  not deliverables.

## Content contract

### Mob classification (M1)

Extend `MobDefinition` with stable category/family/rank identifiers,
validate the category against the five permitted IDs, and supply explicit
defaults for the four existing profiles. Migrate them without changing
behavior, combat math, XP or their stable `mob_key`.

Keep one **explicit, canonical registry** used by both World and client.
Do not scan arbitrary folders at runtime. Validate nonempty stable keys,
unique registrations, valid category/rank and identity of the registered
resource at content admission. The registry need not become a full
database or general-purpose plugin framework.

A character's damage vs category (if ever introduced) remains a
separate later feature. Keep category and family available to content,
quests and future systems without introducing new network fields merely
to render them.

### Loot sources (L1)

Use compact authored `LootTable` and `LootEntry` Resources (or equivalent
explicit structures). Each item entry identifies a canonical
`ItemDefinition`, an **absolute item probability budget in basis points
(0..10000; 10000 = 100%)**, and a bounded integer quantity range.
Do **not** normalize or dilute entries when additional scopes are
included: an entry with 100 basis points remains at 1% in every valid
combined pool. Item quantities must obey the definition's
`stack_limit`; nonstackable items have quantity one. Equipment affix
rolls are explicit, optional and defined separately from a material
quantity; no implicit +1..+9 attack affix on all drops.

One authoritative resolver combines the following in stable order:

| Scope | Example | Contract |
| --- | --- | --- |
| Global | Rare generic upgrade material | Optional shared World table |
| Region | Old Road timber/resin | Stable server region key, not a client-provided ID |
| Category | Beast hide | `beast` table reused in every region |
| Mob | Wolf fang | Exact stable `mob_key` table |

**One consolidated pool, configurable number of selections:**

1. Gather entries from the four scopes in the deterministic order above.
   Preserve source metadata for balancing/debugging; duplicates of the same
   item ID are allowed only as deliberately distinct authored entries.
2. Add each entry's absolute basis-point weight. The total across **all
   four scopes combined must not exceed 10000**. Validate authored
   World region/category/mob combinations before admitting content.
   Reject an invalid combination explicitly: do not normalize,
   silently clip, roll partially, or alter existing entry odds.
3. The unused budget `10000 - sum(weights)` represents **no item
   drop per draw**. For each draw sample a fresh integer `r` uniformly
   from `[0,9999]`, walk cumulative weights and choose at most one
   entry (or no item). **Four table sources are not four automatic draws.**
4. The base-count budget is an explicit, bounded **LootRollPolicy**.
   Author `min_rolls` and `max_rolls` on each mob definition
   or encounter variant, with **1 <= min_rolls <= max_rolls <= 4**.
   At **each server spawn**, choose a uniformly distributed
   integer from that inclusive range and store it as
   `spawn_base_loot_rolls` on the server-only live mob instance.
   `1..3` means 1/3 chance of each count; `2..2` is fixed.
   Suggested **authoring defaults**, never hardcoded rules:
   normal=`1..3`, strong=`2..3`, rare variant=`2..4`,
   elite=`3..4`, boss=`4..4`. Each mob may override these
   independently of rank. Never reroll the count on aggro,
   disengage, damage, death, player changes or client reconnects.
   A respawn is a new instance and samples a fresh count.
   No extra public mob snapshot field is needed. Bosses/encounters
   may separately author one bounded guaranteed reward.
5. Reward-owner **Luck** is an explicit chance of **one additional
   independent ordinary draw** (e.g. 2000 bp = 20% chance to make one
   extra draw). The server resolves the eligible reward owner's stats
   at death, freezes that context, validates/clamps the chance and
   never accepts luck from the client. This bonus draw can yield a
   different item or no item. It does not duplicate a selected stack
   and does not implicitly increase Yang/XP.
6. Initial ceiling: **1..4 spawn-frozen base attempts plus
   0..1 Luck extra attempt at death** (max five ordinary
   item selections) and optionally one explicit guaranteed
   encounter reward. Reject invalid `min_rolls`/`max_rolls`
   bounds before spawn; never silently truncate. Luck is
   checked **once per kill**, not once per base attempt.
   100% Luck adds exactly one. No recursive rerolls or
   generic loot-rule interpreter.
7. If selected entries have variable quantities/affixes, resolve these
   as separate *property rolls* before ground spawn. Each successful
   draw yields a stable item outcome with its own UID. Repeated picks
   of the same definition are allowed; respect `stack_limit` and
   item-count/quantity conservation. Pickup retries must never reroll
   identity, quantity or stats.

Example **per draw**: global ore 0.5% (50 bp), region resin 3%
(300 bp), category hide 8% (800 bp), mob fang 2% (200 bp), or
**86.5% no item**. Adding a valid fifth entry reduces only the
no-drop remainder *per draw*; all original absolute weights remain
unchanged. One normal draw yields an item in 13.5% of kills.
A normal mob with `min_rolls=1`, `max_rolls=3`
**spawns** with 1, 2 or 3 base item attempts, each count
with probability 1/3. At death these attempts use the
**same combined item pool** and may each fail. Expected base
attempts = **2 per kill**; with 20% Luck checked at death,
expected total = **2.2**. If the item chance per attempt
is 13.5%, expected item stacks = **0.297 per kill**
(2.2 * 0.135). A rare mob authored as `2..4` can spawn
with 2, 3 or 4 base attempts; 100% Luck makes 3, 4 or 5
total at death. Count-at-spawn, Luck-at-death and item
selection-at-death are distinct server RNG uses. Values are
illustrative, not final live balance.

**Terminology:** `Luck -> chance for a bonus draw` is the first
implementation of a player double-drop opportunity. A literal
`duplicate the same successful stack` effect is a **different
modifier** that would require an explicit separate design and
fresh UID for each duplicate; do not mix both behaviors under a
single ambiguous `double_drop` field. The World owns production
RNG; tests inject seeded RNG and verify roll caps/odds.

Yang is **one separate reward policy per kill**, not another Yang pile
from each item-loot layer or ordinary-item draw. Its chance/amount
roll is distinct from ordinary item selection and **not multiplied
by rank draw count or player Luck** unless a future, explicit
Yang-specific design says otherwise. Configure Yang chance/range
explicitly, with zero supported and documented bounds. XP is still
awarded by the existing progression path, exactly once. Do not couple
item probability to wallet/grind delta semantics.

### PoE-inspired design: quantity, type and rarity stay separate

The direction is toward Path of Exile's **conceptual separation**
of drop quantity and item rarity, not copying its formulas:

1. **Number of attempts:** authored mob/encounter policy
   chooses `min_rolls..max_rolls` **at spawn**; the eligible
   player's Luck may add one at death. Do not reveal the
   hidden count in public snapshots.
2. **What drops:** item selection from global, map,
   category and per-mob ordinary sources **at death**.
   The consolidated 10000-bp per-attempt pool is the
   **first version only**. Keep resolver boundaries
   ready for later specialized equipment, currency or
   boss pools without breaking pickup.
3. **How good it is:** equipment rarity/tier, affixes
   and quality are a **separate item-generation layer**.
   A monster classified as rare/elite is not a guarantee
   that its equipment rewards roll a rare tier;
   material/currency stacks need not have item rarity.
4. **Special encounters:** any scripted/boss guaranteed
   loot is explicit and separate from ordinary attempts.

Keep `MobActor3D.spawn_base_loot_rolls` private to World,
RAM-only like existing mob packs, and freeze its value
in the one-shot death fact. A respawn samples a new value.
Resolve actual item UIDs/amounts/affixes only once at death
and preserve receipt-safe pickup. Luck/loot sources must
never be accepted from untrusted client requests.

### Frozen reward and pickup (L2)

At death capture the authoritative region/category/mob context
**and the spawn-frozen `spawn_base_loot_rolls`** before the actor
is removed. Resolve **zero to five item outcomes** (1..4 base
attempts allocated on spawn, at most one additional Luck
attempt) plus separately authored encounter reward and
one Yang outcome. Item identities, quantities and affixes
are **rolled once at death** (not at spawn or pickup).
Create ground entries representing item type, quantity and optional
valid item rolls. The eventual `ItemInstance` receives the same stable
UID and amount on pickup; never reroll the item during a retry.

`KillRewardResolver` should orchestrate *death -> resolve -> spawn*,
not hardcode a sword. `GroundLootSystem` should own *live ground entry,
reserved owner, expiry, distance/LOS validation, pickup*; it should not
decide which loot table rolls or what mob was killed. Use typed
domain records if they reduce dictionary shape ambiguity, but avoid an
extra generic event bus or drop persistence table for this phase.

**Do not regress economy invariants:**

- The World owns RNG, ground UID, owner/reservation and pickup approval.
- A ground item can enter persistent custody **once** through the
  existing economy transaction/receipt operation. Replays and two-client
  races never create a second UID or second quantity grant.
- Failed/full-Inventory pickup leaves the ground drop available
  according to existing semantics; confirmed persistent claim removes
  it and only then updates client caches/notifications.
- Reserving, expiry, no-LOS, out-of-range, disconnect/reconnect,
  ownerless drops and duplicate pickup remain covered.
- Stack amounts must be conserved across ground -> Inventory and
  subsequent Inventory/Storage/Market operations; test those handoffs
  before enabling quantities >1 in public content.
- Existing Metin encounter reward and network fixtures must continue
  to work; any prototype sword behavior still required by fixture
  content should be **explicit test content**, not a global special case.

## Sequential delivery plan

### P1 — Classification and data validation

- Add the five category IDs, family/rank fields, canonical validation
  and migrate four existing 3D definitions.
- Add a small first batch of new definitions (e.g. Besties and
  Humanoids, three variants each) as data, without changing 3D spawn
  density until L2 is ready. Placeholder visuals are acceptable.
- Unit/headless checks: missing/invalid category, duplicate or
  unregistered definition, canonical identity and unchanged old keys.
- **Exit:** existing mob pack, Metin, network and smoke fixtures pass;
  no changes to loot/pickup or combat balancing yet.

### P2 — Loot resolver and authored drop tables

- Implement `LootEntry`, `LootTable` and pure/configurable
  `LootResolver` with global/region/category/mob inputs and a
  reproducible RNG in tests.
- Assemble the **single** weighted pool from four optional scopes,
  with a fixed 10000 bp budget and implicit no-drop remainder **per
  draw**. Validate all authored region + category + mob combinations;
  reject overflow and never silently renormalize chances.
- Add a small data-driven **LootRollPolicy** with individually
  configurable inclusive `min_rolls`/`max_rolls` (1..4 per
  mob/encounter variant). Freeze the chosen base count **at
  server spawn/respawn** and consume it on death. Check
  server-authoritative Luck once at death for at most one
  additional draw. Cap ordinary attempts at five, keep
  encounter guarantees and Yang separate.
- Tests: absent tables, 0 and 10000 bp entries, 10000 bp total and
  >10000 rejection, unchanged **per-draw** odds as scopes are
  added, deterministic seeded multiple draws, zero/multiple item
  results, repeated item UID uniqueness, valid quantity ranges,
  deterministic **spawn-time** count selection over
  `1..1`, `1..3`, `2..4`, `4..4`, rejection of
  invalid `0..1`, `3..2`, `1..5`; same mob retains
  its count across aggro/return and death resolution;
  replacement mob resamples; no loot UIDs or item outcomes
  generated at spawn; table count does not affect count
  distribution; at most 4+1 attempts; Luck 0/20/100%
  cases (100% only +1); offline owner fallback,
  malicious client Luck irrelevance and no
  unrequested four-source multiplier.
- **Exit:** testable outcome objects; no production ground
  item behavior change.

### P3 — Generalize drop ground representation / pickup

- Refactor `KillRewardResolver` and `GroundLootSystem` around the
  resolved outcomes. Support non-weapon definition IDs, stack
  quantities and optional equipment rolls through existing item
  ownership/transaction APIs.
- Rework snapshots/UI presentation only if required for genuine
  non-weapon/quantity display; preserve protocol validation.
- Tests: full bag, commit failure, receipt replay, two-player
  simultaneous claim, expiry/reservation, reconnect, multi-drop
  spawn/claim, two drops of the same item definition with different
  UIDs, stack limits, amount/UID conservation, no duplicated XP/Yang
  or rerolled loot on retries, existing Metin reward flow.
- **Exit:** real materials can be dropped and looted reliably, no
  mandatory weapon attack affix on every item.

### P4 — World content, local prototype visuals and pacing

- Introduce the first two families and map compositions using the
  canonical definitions; replace some dog packs instead of adding
  actor count blindly. Preserve the existing straight-line chase,
  pass-through obstacles, pack aggro and no mob-to-mob collision.
- Add a few **region/category/mob** entries to the first region's
  consolidated pool. Keep starter rewards intentionally sparse;
  validate the sum of absolute drop probabilities for every authored
  mob+region combination, and verify the expected no-drop rate.
- Reuse `VisualResolver` IDs already supported (`wolf`,
  `wild_boar`, `barbarian_soldier`, etc.) for local prototype GLBs.
  If more families require new IDs, add only curated ID/path mappings
  and repo-owned fallbacks; do not commit externally sourced models,
  their imports or derived textures. Confirm no such binary appears
  in git diff or distributed exports.
- Run bounded seeded loot simulations for **spawn-frozen**
  `1..3`, `2..4`, `4..4` variants and Luck
  0/20/100% at death, plus 10-15 minute play sessions,
  headless packs/network/Metin tests and a frame-time/density check.
  Measure item entities per kill, probabilities of 0/1/2+ drops,
  rare material yield, progression, drop pickup feel and
  account-Yang injection.
- **Exit:** greater encounter variety with a reason to farm distinct
  mobs/areas, without a measurable performance or economy regression.

## Exclusions and dependencies

No Mystic category in P1–P4; no new combat category-damage modifiers,
complex mob AI, boss skills, party loot policy, persistence of
individual ground entities, new economy ledgers, or import of the old
2D enemy system. The prototype model source/rights remain outside
git and published client assets.

Implement **P1 -> P2 -> P3 -> P4** in separate small reviewable PRs,
based on fresh `main`. Avoid overlapping Codex's economy/Inventory
writer work in P1/P2; make P3's pickup contract a deliberate integration
checkpoint, with transactional and network regressions before merge.
