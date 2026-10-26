# Item progression

## Affix generation C1 — current foundation

The shared, pure `items/affixes/affix_generator.gd` accepts an ItemDefinition,
requested prefix/suffix counts, an authored pool and an explicit RNG. It returns
a complete decision or an error, never mutates an item, writes SQL or awards loot.
It is used by C2 ordinary equipment drops and C3 consumable crafting below. The independent +0…+9 upgrade state remains unchanged.

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
C3 crafting rejects these legacy items without altering their saved bonuses. UID, sockets, placement, revision and
upgrade level are independent of the new metadata. Existing CEF tooltips show
the real prefix/suffix kind for versioned rolls through the existing Alt labels.

Verification: smoke includes `affix_generation` (seeded selection, tier/family/
slot restrictions, exclusions, 3+3, bad definitions, legacy interpretation and
SOCI embedded reopen). PostgreSQL `--suite affix-generation` covers UID/effects/
sockets/+level preservation after reopen, both JSON formats and the existing
auction index. No schema migration, new currency or crafting UI is part of C1.

## Natural equipment drops C2

Ordinary Loot V2 in authored regions now decorates selected equipment through
the same C1 generator. Solo and party use `KillRewardResolver.resolve_ordinary()`;
table entries, per-spawn attempts, Luck, item identities/amounts and the item RNG
stream (also used for party recipient selection) are unchanged. Quality and
affix choices use a separate per-instance World RNG. Materials, stackable items,
KU, event-specific grants, starters, NPC purchases and the legacy arena/Metin
guaranteed reward keep their previous behavior.

`loot/tables/natural_affix_profile.tres` defines provisional alpha weights:
normal 60 (0+0 affixes), magic 30 (1+1), rare 9 (2+2), rare_full 1 (3+3).
These are tuning values, not finalized economy odds. Quality changes counts,
never eligibility or tier weights: a two-affix item can roll any tier its base
allows. Iron Sword remains eligibility level 1, so its currently legal tiers
remain level-1 tiers. Higher eligibility is exercised in fixtures, not silently
granted to live bases. Honed and Rhythmic extend the natural pool to three
definitions per kind; their shared `precision` group name is independent by kind.

The resolver produces a whole decorated batch or an error, without partial
awards or retries of a failed quality roll. Ground custody assigns one UID after
generation and freezes all six possible affixes. Pickup/retry validates stored
structure, never rerolls or resolves current profile values. Existing protection,
expiry, capacity, atomic PostgreSQL claims and receipts remain authoritative.
No SQL schema, new currency, mob rarity or crafting action is introduced.

Smoke adds `natural_affix_loot` for zero/two/four/six affix counts, eligible
top-tier access, frozen UID, material/KU exclusions and production Loot V2 RNG
parity. PostgreSQL `--suite ground-runtime` additionally covers a six-affix
pickup with lost completion, read-only recovery, replay and exactly one UID.

## Crafting currencies C3

Equipment has a durable `rarity` (`normal`, `magic`, `rare`), separate from
its affix count and +0…+9 upgrade. Magic permits at most one prefix and one
suffix; Rare at most three of each. There is no automatic Legendary label for
five/six bonuses. A Rare item stays Rare even with fewer bonuses.

Offline PostgreSQL provisioning migrates `npc_shop` from 1 to 2. Zero-affix old
items become Normal; versioned sets with at most one prefix and one suffix become
Magic; larger sets and opaque legacy bonuses become Rare. UID, resolved values,
revision, sockets and upgrade level are preserved. Legacy bonuses are not guessed
into prefix/suffix identities and cannot be crafted by these currencies. The
embedded SOCI fixture schema applies the same classification. Normal deployment
requires provisioning before build 0.38.0; runtime never migrates or falls back.

The original currencies are stackable USE items:

| Currency | Preconditions | Committed effect |
| --- | --- | --- |
| Iskra Przemiany (`change_spark`) | Normal eligible equipment in bag | Becomes Magic with one/two new affixes |
| Pył Odnowy (`renewal_dust`) | Magic eligible equipment in bag | Replaces all affixes; remains Magic |
| Odłamek Dopełnienia (`completion_shard`) | Magic equipment with exactly one affix | Preserves that roll and adds the opposite kind |
| Żar Wyniesienia (`ascension_ember`) | Normal eligible equipment in bag | Becomes Rare with four to six new affixes |
| Pryzmat Odnowy (`renewal_prism`) | Rare eligible equipment in bag | Replaces all affixes with four to six new rolls; remains Rare |
| Pieczęć Przebudzenia (`awakening_seal`) | Magic eligible equipment in bag | Preserves every existing roll and appends exactly one new affix; becomes Rare |
| Sól Oczyszczenia (`cleansing_salt`) | Magic/Rare eligible equipment in bag with at least one valid affix | Removes every affix and becomes Normal; preserves +level and sockets |
| Rdzeń Dopełnienia (`completion_core`) | Rare eligible equipment in bag with fewer than six affixes | Preserves all existing rolls and appends exactly one, respecting three of each kind |
| Dłuto Rozproszenia (`dispersal_chisel`) | Magic/Rare eligible equipment in bag with at least one valid affix | Removes one random affix; preserves rarity and every other roll |
| Pryzmat Dostrojenia (`attunement_prism`) | Magic/Rare eligible equipment in bag with at least one valid affix | Rerolls only numeric values within existing tiers; keeps rarity and all affix identities |

Each action consumes exactly one selected currency, with no Yang surcharge.
Transform/renew currently choose prefix-only, suffix-only or both with equal
probability; these are explicit provisional content odds. Affix/tier weights and
base eligibility use the same natural-drop pool. Exhaustion/invalid existing
rolls reject the whole operation without consuming currency. Current currency
sources are listed below; market value and final drop balance remain provisional.

Rare creation/reforge use provisional equal chances of four, five or six total
affixes; each legal prefix/suffix split for that count is equally likely (4:
1+3/2+2/3+1; 5: 2+3/3+2; 6: 3+3). There is no downgrade, fallback or reroll
on an insufficient pool, and a legal random result may repeat existing rolls.
The same kind-local group/exclusion and tier eligibility rules apply. Normal
to Rare and complete Rare rerolls use this count distribution. Opaque legacy
Rare bonuses remain protected from crafting.
The Rare extension changes content only, not RPC signatures or the SQL schema;
client/server build 0.39.0 includes both currencies. No deployment migration
beyond the C3 rarity schema is needed. Current provisional sources are listed below.

Magic to Rare (build 0.40.0) is a separate preserving action: Pieczęć Przebudzenia
keeps the original ordered rolls, tiers and values, then appends exactly one new
affix. A one-affix Magic becomes two-affix Rare; a two-affix Magic becomes
three-affix Rare. Explicit empty Magic is also legal and becomes one-affix Rare.
Rarity is never inferred from the resulting count. The new kind is provisionally
chosen prefix/suffix with equal chance, using the shared weighted affix/tier pool
and conflict checks against retained rolls. Failure to supply the chosen kind
rejects without fallback, promotion or currency consumption. There is no reroll
of existing bonuses and no repeat on the same item once Rare. This action also
requires no RPC/schema change.

Cleansing (build 0.41.0) removes all recognized affixes and their stat contribution
from Magic/Rare, returning explicit Normal with an empty affix list. It does not
reset +level, sockets, UID or placement and consumes no random draws. Normal or
already empty Magic/Rare is rejected without spending currency. The existing
pool/eligibility validation still protects opaque legacy or invalid bonuses;
this action is not a legacy-data repair tool. It uses the same transaction and
recovery path, including replay after the last currency in a stack disappears.
The cleaned base can then be crafted again using Normal-target currencies.
Existing roll odds and currency sourcing remain unchanged.

Rare extension (build 0.42.0) adds exactly one roll without changing the ordered
existing affixes, tiers or values. Rare remains Rare, including an explicit empty
Rare base. If prefixes or suffixes already occupy three slots, the other kind
is selected; with both kinds open, prefix/suffix currently have equal chances.
The shared weighted pool and conflicts apply against all retained rolls. There
is no fallback or redraw for insufficient compatible content. Full 3+3 rejects
without spending currency, and Shift stops sending new uses for that full target
after its authoritative snapshot. UID, +level, sockets and placement survive.
This uses the existing receipts/recovery, without a schema or RPC change.

Single-affix removal (build 0.43.0) selects one stored affix uniformly, regardless
of kind, tier or value, and removes exactly that entry. Surviving entries retain
their order, tiers and values. Magic/Rare stays Magic/Rare even when the last
affix disappears; explicit rarity is independent of count. Empty items and Normal
are rejected without spending, as are opaque legacy/invalid rolls under existing
validation. UID, +level, sockets and placement remain unchanged. One currency
is consumed with no Yang surcharge. Frozen receipts recover the original choice
without removing another affix; another deliberate use needs a new command and
current revisions. Shift can continue until the authoritative target is empty.
No SQL schema, RPC or worker change is required; other crafting odds and currency
sources remain unchanged.

Value tuning (build 0.44.0) independently rerolls each affix's integer value in
the inclusive range of its existing tier. It never chooses a new affix or tier,
changes count/order, or resets rarity, UID, +level, sockets or placement. A result
may equal the old value; a fixed-value tier necessarily stays unchanged. Normal,
empty Magic/Rare and opaque legacy/invalid rolls are rejected without spending.
One Pryzmat Dostrojenia is consumed with no Yang fee. The existing frozen receipt
and client journal recover the original values after a lost response, rather than
rerolling again. Current item snapshots refresh derived stats and Auction values.
No schema/RPC change is required. Currency sourcing is described below.

### Crafting currency sources — alpha milestone

Build 0.45.0 connects all ten currencies to ordinary Loot V2 in authored regions
(currently First Region). The legacy empty-region arena fallback remains unchanged.
`global_crafting_currencies.tres` is appended once after the existing ordinary
tables. Entries use absolute basis-point chances, not normalized weights. Existing
item chances remain intact; the currency budget uses part of the no-item remainder.
There are no extra rolls: the same spawn-selected 1–4 attempts and optional single
Luck attempt apply. Each selected currency outcome contains one unit, not a bundle.

| Currency | Provisional chance per ordinary attempt |
| --- | --- |
| Iskra Przemiany | 1.00% |
| Pył Odnowy | 0.80% |
| Odłamek Dopełnienia | 0.50% |
| Żar Wyniesienia | 0.40% |
| Pryzmat Odnowy | 0.30% |
| Pieczęć Przebudzenia | 0.25% |
| Sól Oczyszczenia | 0.40% |
| Rdzeń Dopełnienia | 0.10% |
| Dłuto Rozproszenia | 0.15% |
| Pryzmat Dostrojenia | 0.10% |
| **Any crafting currency** | **4.00%** |

These are playtest starting values, not final economy balance or per-kill chances.
Edit the authored table to tune them; exceeding the combined probability budget
still rejects the whole ordinary roll. Metin stone reward pools, XP, Yang and event
drops are unchanged. Ordinary wave mobs use their existing ordinary-loot policy.
Currencies bypass equipment affix generation and use existing physical ground
reservation/party rights, UID ownership, PostgreSQL pickup receipts and recovery.
No free startup grants, NPC offers, new schema or RPC contract are introduced.

This closes the first crafting alpha loop: find a base and currencies, pick them
up through durable custody, craft with explicit targeting, and recover the same
committed outcome after reconnect. Smoke, native PostgreSQL claim/crafting tests
and browser preview cover those contracts. Physical CEF input, manual progression
pace, broader item bases and final affix/drop balance remain playtest work.

Right-click a currency in Inventory (or activate its USE hotbar binding) to arm
its original symbol and remaining stack at the cursor. Left-click a bag target
to use exactly one unit. Normal carrying/dragging only moves items and never
crafts. Without Shift, a successful use exits targeting; Shift retains the stack
for another deliberate click after authoritative reconciliation. Pending requests
block new uses; each repeat reads current item/currency revisions. Invalid targets
are dimmed and explain the restriction. Decorations survive Inventory/Storage
page changes; Storage targets explain that crafting requires moving to the bag.
A left click outside Inventory cancels targeting before normal UI handlers run,
so the same click can operate Shop, Trade or Storage (including Ctrl-transfer).
RMB/Escape/blur and closing Inventory also cancel. Cancellation never discards a
pending receipt or sends another crafting operation. There is no crafting panel or dropdown. Recovery is a
small Inventory notice/button, and never automatically executes an unsent intent.
The standalone preview has a non-economic Use crafting currency fixture.

The existing native NPC-operation coordinator is reused for worker scheduling,
Inventory/Wallet barriers, reconciliation and receipts; crafting itself needs
no NPC authorization or SQL on the simulation thread. Both item UIDs/revisions,
current session and bag custody are validated on the server. One transaction
settles the pending Yang prefix, consumes currency, updates target rarity/affixes
and revision, and writes a frozen receipt. UID, +level, sockets and placement are
unchanged. Server entropy is stable across proven-aborted SQL retries; uncertain
COMMIT goes to read-only receipt lookup, never an automatic second roll.

The client journals the original identity before sending. Reload/relogin looks
up the receipt; only explicit Retry can submit a previously unsent operation
when the receipt is absent. Character-scoped journals are not transferable to
another character. Pending results block another crafting intent. Existing
Inventory snapshots publish the committed outcome and refresh derived stats.

Verification: smoke `crafting_currencies`, PostgreSQL `--suite crafting` and
`--suite npc-runtime`; `--suite inventory-endpoint` includes real client-process
restart, lost Magic/Rare crafting responses and a saved-but-unsent journal. UI contracts
check explicit target clicks, normal-drag isolation, serialized Shift reuse with
current revisions, cancellation, pending retry and explicit-rarity tooltips. Headless
and browser fixtures do not establish physical native CEF input behavior.

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
