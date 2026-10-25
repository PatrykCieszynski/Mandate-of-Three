# Equipment crafting and upgrades roadmap

Status: **approved direction / proposed implementation slices**, 2026-10-25.
This is a planning document, **not** a claim that these features are shipped.
The maintainer chooses when to start each slice; phases are not automatic tasks.

## Design goals

Three viable routes to powerful equipment must remain possible:
1. **Lucky natural drops:** a sufficiently fortunate drop can already be excellent, including top-tier affixes where its base/item-level eligibility allows.
2. **Incremental improvement:** preserve a promising item while adding/removing/rerolling selected portions through costly, probabilistic operations.
3. **Crafting from a selected base:** invest currency/materials in a chosen base and reroll or bias outcomes without deterministic best-in-slot creation.

Balance these routes against each other after playable testing. Do not create a permanent "hero weapon", item usage-history power, or mandatory use-to-improve mechanic. Replacing equipment when a better base drops is desirable; endgame equipment can be worked on longer without becoming permanent.

Core rules:
- Maximum **three prefixes and three suffixes** on an eligible item; individual affix families/groups have explicit duplicate/exclusion rules.
- Affixes have data-driven tiers, allowed item families, level eligibility, weights and stat effects. The exact affix list and numbers are provisional.
- Existing **+0 through +9 upgrade progression is separate** from prefix/suffix crafting. Changing one never implicitly rerolls the other.
- Client submits *intent*, not prices, odds, generated bonuses or random results. Server publishes exact costs, success odds and failure outcomes.
- Every economic mutation preserves item UID, increments revision, validates ownership/session/custody, and atomically settles item changes, consumed materials and Yang. A failed gameplay roll is a **committed economic outcome**, not a database failure. SQL failure rolls everything back.
- Persist a stable result/receipt and recover uncertain commits without re-rolling or blindly retrying mutations. Validate full/reordered bag and concurrent command races.
- Initially restrict active crafting to **bag items**; revisiting equipped-item support requires a separate decision.
- Design implementations to reuse existing ItemInstance, ItemDefinition, Inventory/Wallet/PostgreSQL economic owners, and CEF item presentation. Do not create parallel inventories, currencies or item identities.

## Existing implementation (as inspected before this plan)

- `ItemInstance` has `uid`, `upgrade_level`, `affixes`, `sockets`, `revision`, and `effective_stats()`; existing affix representation includes simple `{stat, value}` dictionaries.
- `ItemDefinition` has base and per-upgrade stats, slot and other immutable metadata; no finalized affix pool or item-level progression model yet.
- The Blacksmith Upgrade vertical slice supports **Iron Sword +0 -> +1**, **100% success**, **1,000 Yang + one Upgrade Ore**. It has server-authoritative selection, economic validation, CEF flow and atomic persistence.
- `UpgradeDefinition` currently contains `from_level`, `to_level`, `success_rate`, a single material requirement and Yang cost; validation explicitly restricts it to +0 -> +1 and 100%.
- `UpgradeStorePostgres` currently executes the deterministic successful upgrade; the presence of a success-rate field does **not** mean RNG/failure/downgrade is implemented.
- The upgrade preview can illustrate +0..+9, but that is not production upgrade support.

Implementation must begin by reconciling these details with HEAD; do not reimplement capabilities already landed.

## Delivery slices

Each phase is independently reviewable. A phase can be subdivided into smaller PRs; no big-bang crafting feature.

### C1 — Affix definitions and generation

Deliver:
- Data definitions for prefix/suffix identity, group, tier, stat effect, allowed equipment types, eligibility and weighted selection.
- Enforce at most 3 prefixes/3 suffixes, duplicate-group exclusions and level/slot eligibility.
- Small illustrative affix catalogue (e.g. 4–6 bonuses with at least two tiers); deterministic seeded test generation.
- One shared generation contract intended for both future loot and crafting, not separate rolling semantics.
- Safe interpretation of existing `{stat,value}` instances and existing gameplay stat projection; explicit compatibility tests before extending the persisted representation.

**Acceptance:** a generated item can be validated, persisted/reloaded with unchanged UID and affix meaning, displayed and used for effective stat calculation. No new currency, UI or production drop balance.

**Design check:** decide how item level/base eligibility is represented without tying it to +0..+9; do not prematurely set final item-level ranges.

### C2 — Natural affix drops and item quality

Deliver:
- Integrate the shared affix generator into the **existing** loot/item-creation boundary, after auditing that boundary on HEAD.
- Data-driven rarity/quality influencing *number or distribution* of affixes, not an exclusive gate to the only best possible gear.
- Preserve existing loot source tables/odds and UID/custody behavior unless explicitly changed in this slice.
- Tests for clean zero-affix, ordinary, and lucky high-quality outcomes.

**Acceptance:** natural drops can produce genuinely excellent equipment, including eligible top-tier affixes. Final rarity odds, mob placements and economy tuning remain open.

### C3 — First safe crafting mutation (infrastructure plus one operation)

Deliver:
- Reuse PostgreSQL economic command/session, item/custody, Wallet and receipt paths.
- Server-owned operation definition; check item UID+revision, bag custody, restrictions, currency/material availability and current affix validity.
- One small real crafting action, with costs and results in one atomic transaction; end-to-end UI via the existing CEF inventory/NPC interaction pattern where possible.
- Read-only recovery of a committed/failed operation after lost acknowledgement; no second random draw.
- Concurrent UID mutation, missing funds/materials, rollback and lost-commit-response tests.

**Acceptance:** one actual consumable crafting operation can be executed and recovered without item/monetary duplication.

### C4 — Basic currencies, delivered one at a time

Candidate actions:
- Reroll the entire eligible affix set.
- Add one random eligible affix if space exists.
- Remove one random affix.

Each action needs clear preconditions and a visible preview of **possible consequences**, not a fake preview of RNG results. Do not automatically add all three in one PR. Retain UID, sockets and +level except where an explicitly separate rule says otherwise.

**Acceptance:** successive operations compose, respect the 3+3 and group constraints, and survive logout/trading/storage.

### C5 — Directed crafting / category essences

- Data-driven material effects that *bias the weights* of affix families; no arbitrary guaranteed perfect affix/tier.
- Potential sourcing from five existing mob categories: beast, humanoid, undead, demon and construct. Category-to-affix mapping is **not yet decided**; avoid rigid "all demon materials are offense" assumptions.
- Family/boss-specific essences are optional extensions, not required for V1.
- Test that eligible candidates remain legal and bias actually changes weights; avoid introducing new loot placements until balancing.

**Acceptance:** directed crafting meaningfully changes probabilities while preserving uncertain outcomes and viable ordinary drops.

### C6 — Advanced crafting and optional unstable actions

Candidates for separate decisions/slices:
- Protect prefixes or suffixes while rerolling the other group.
- More expensive targeted additions/removals that still respect restrictions.
- Optional unstable/high-risk operations with clearly disclosed, bounded consequences.

Do **not** commit now to specific unstable mechanics, permanent crafting locks, destruction, deterministic BiS or mandatory risk taxes. They require a design/playtest decision.

## U1 — Blacksmith Upgrade V2 (+0..+9), separate track

Upgrade V2 can be implemented independently of C1–C6 and should build on the existing Upgrade vertical slice, not replace it.

### Authoring model

- Per-attempt or per-target-level definitions specify **Yang cost and a list of material requirements**, quantities, `success_rate` and an explicit **failure effect**.
- A global default profile may provide chances/failure rules; a specific recipe can override them. Start with the simplest authoring solution that avoids duplicated config and keeps the **resolved authoritative result** in one server-provided snapshot. Avoid an elaborate inheritance system without a real use case.
- Server calculates and sends: source level, target level, odds, full material list, Yang, and exact level after failure; CEF uses these same values when displaying confirmation.
- Costs and odds can later vary by base/item category and upgrade tier. Final prices, materials, probabilities and mob sources are **not decided**.
- Failures **never destroy the item** in ordinary Blacksmith upgrading. Item UID, affixes, sockets and placement survive success and failure; upgrade level and revision reflect the committed outcome.
- Costs are consumed on **both** an unsuccessful gameplay roll and success. Insufficient resources or failed DB transaction are not a gameplay roll and must not consume costs.

### Approved default failure bands

Bands refer to the **target upgrade level**, not current level.

| Attempt | Failure outcome | Delta from current |
| --- | --- | --- |
| +0 -> +1 | remain +0 | 0 |
| +1 -> +2 | remain +1 | 0 |
| +2 -> +3 | remain +2 | 0 |
| +3 -> +4 | fall +3 -> +2 | -1 |
| +4 -> +5 | fall +4 -> +3 | -1 |
| +5 -> +6 | fall +5 -> +4 | -1 |
| +6 -> +7 | fall +6 -> +4 | -2 |
| +7 -> +8 | fall +7 -> +5 | -2 |
| +8 -> +9 | fall +8 -> +6 | -2 |

The failure rule should be explicitly defined or resolvable **per recipe** (e.g. `failure_levels` 0, 1 or 2), so new exceptions and UI descriptions require no hidden client logic. Clamp result at +0. No default break/destruction behavior.

### U1 delivery order

1. **U1a — Data/preview:** generalize `UpgradeDefinition` beyond +0 -> +1; add per-level prices, **multiple** material requirements and the resolved failure target to authoritative preview. Validate coverage +0..+9 and unsupported/ambiguous recipes. Tests only; existing +0 -> +1 must remain unchanged.
2. **U1b — Execute outcomes:** server-side RNG success/fail/downgrade; consume costs atomically, update item level/revision, retain UID/affixes/sockets, record recoverable outcome and reconcile runtime state. Test each failure band, replay, rollback and uncertain commit. Preserve selection/range/session guards and 3D NPC UI.
3. **U1c — Illustrative content:** provide complete +0..+9 recipe sets with *clearly provisional* odds, costs and materials; ensure UI communicates actual consequences before confirmation. Real sourcing/balancing later.
4. **Later, only if requested:** protection scrolls or alternative upgrading methods; no built-in item destruction.

## Economy, testing and UI invariants

- Single server-authoritative truth for operation requirements and outcomes; no client-authored RNG, affix values, item swaps or cost math.
- Existing persistent and volatile currency sources must reconcile before mutation; one SQL commit for item+materials+Yang+receipt.
- Repeat IDs should return the same recorded outcome even after disconnect, worker uncertainty or process reconnect; no repeated material consumption or extra roll.
- A trade, market sale, storage action, equip or another crafting attempt racing against the same UID must resolve with either one valid winner or a clean rejection.
- Preview shows **actual** server-provided costs, odds and possible failure result. Tooltip shows resulting real stats, and UI never claims a final random result before settlement.
- Prefer seeded/forced test RNG for exact success/fail branches, plus property/invariant tests for weighted selection.
- Test SQLite compatibility where that backend still carries profile/item data, but do not introduce parallel authoritative economy mutations outside PostgreSQL.

## Deliberately deferred balancing/content

Final affix stat values, distributions, rarity rates, tier bands, item levels, Yang prices, material quantities, currency drop rates, specific mob/category/boss loot sources, upgrade success odds, expected +9 resource cost and endgame availability. These must be tuned using actual item progression and seasonal playtests.

Before adopting any provisional percentage curve, estimate expected total attempts/material/Yang consumption with downgrade loops: raw individual probabilities alone misrepresent how expensive +9 becomes.

## Review gates / next action

First confirm baseline implementation and active branches; this roadmap is only a design proposal. **Recommended first delivery is C1**, with U1a as a separate candidate if Blacksmith upgrading is prioritized. No crafting runtime changes are authorized by this documentation PR.

Small PRs, explicit acceptance tests and maintainer-controlled scheduling; do not automatically execute C2–C6 or U1b/c merely because they appear here.
