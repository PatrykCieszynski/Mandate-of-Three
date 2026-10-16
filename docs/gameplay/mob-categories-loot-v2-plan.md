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
   (`normal`, `strong`, `elite`, `boss`). A category is neither a
   zone nor an aggro/AI mode. Future vs-category damage bonuses may use
   these IDs; **do not implement damage bonuses in this roadmap**.
3. **Loot sources:** optional global, map/region, category, and exact mob.
   Sources **add independent rolls**, not implicit overrides. An empty
   or missing source simply contributes nothing. Rank/level influence
   tables only through explicitly authored content; there is no hidden
   multiplier.
4. **Models from external reference games remain on the developer's
   machine only** as throwaway prototype assets. No such models, textures,
   animations, binary imports, exported packs or their derived data may be
   committed/distributed. Keep client asset lookup via the existing
   optional `VisualResolver` path; missing local assets fall back to
   repo-owned placeholders. Use original/licensed visuals for public
   builds. No borrowed game-specific UI, item or mob nomenclature.
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
`ItemDefinition`, **probability in [0,1]**, and a bounded integer
quantity range. Item quantities must obey the definition's
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

Each table performs **independent** item probability rolls. Several
sources may succeed on one death. There is no automatic replacement,
multiplication of chances or combinatorial cross-product. For the first
content pack keep entry counts and per-kill item spawn budget small and
explicitly validated; verify observed drops per kill rather than silently
discarding successful rolls. The RNG is supplied/injectable for
reproducible tests, but owned by World in production.

Yang is **one separate reward policy per kill**, not another Yang pile
from each item-loot layer. Configure its chance/range explicitly, with
zero supported and documented bounds. XP is still awarded by the existing
progression path, exactly once. Do not couple item probability to
wallet/grind delta semantics.

### Frozen reward and pickup (L2)

Capture/carry the authoritative region/category/mob context when the
mob dies, before the actor is removed or a new definition can replace
it. Resolve one immutable list of item outcomes plus one Yang outcome.
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
- Decide and document a small item-spawn budget before authoring
  content. Define explicit Yang ranges separate from item tables.
- Tests: absent and independent tables, 0/1 probabilities, quantity
  bounds, invalid resource rejection, exactly one reward resolution,
  deterministic sample output and finite worst-case spawn count.
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
  simultaneous claim, expiry/reservation, reconnect, amount/UID
  conservation, no duplicated XP/Yang/item on retries, existing
  Metin reward flow.
- **Exit:** real materials can be dropped and looted reliably, no
  mandatory weapon attack affix on every item.

### P4 — World content, local prototype visuals and pacing

- Introduce the first two families and map compositions using the
  canonical definitions; replace some dog packs instead of adding
  actor count blindly. Preserve the existing straight-line chase,
  pass-through obstacles, pack aggro and no mob-to-mob collision.
- Add a few **region/category/mob** drops on the first map. Keep
  starter rewards intentionally sparse; use local-only temporary
  visuals or repo-owned placeholders and verify no third-party models
  appear in git diff/export.
- Run bounded seeded loot simulations, 10-15 minute play sessions,
  headless packs/network/Metin tests and a frame-time/density check.
  Measure item entities per kill, rare material yield, progression,
  drop pickup feel and account-Yang injection.
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
