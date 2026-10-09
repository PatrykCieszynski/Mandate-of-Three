# Project direction history through 2026-10-09

Historical decision sequence. Superseded limits/setup below are not current
instructions; use [current direction](../project-direction.md).

# Accepted project direction

Decisions following the user's review, 2026-10-07:

- Tiny MMO provides the fork's infrastructure. Keep gateway/master/world, auth and
  sessions, instance lifecycle, transport/replication and persistence.
- Movement, combat and pickup are server-authoritative; clients send intentions.
- ItemDefinition and persistent ItemInstance with UID, owner, placement, upgrade,
  affixes, sockets and revision remain the chosen direction. Atomic equip/swap
  and rollback are the foundation of the economy.
- Open-MT2 is a behavioral reference for Metin, not a runtime or dependency.
- The current item model is sufficient; do not expand the crafting/item framework.
- Priority: Player -> Mob -> Combat -> Death -> Ground Loot -> Pickup -> Persistent
  Item, tested with two clients attacking the same mob.
- Loot stays on the ground. Verify ownership, full inventory and double pickup.
- AOI comes later: first consider reusing Tiny MMO's grid on the XZ plane.
  Local prediction can also wait.
- The legacy schema is temporary. Before public alpha, introduce our own cleaner
  reset/migration; indefinite compatibility with Ekonia saves is not promised.
- After the vertical slice, perform a second dependency-based asset/upstream cleanup.
  Avoid aggressive removal while building the slice.
- Shorten the README around Mandate; retain Tiny MMO as upstream/credits and an
  infrastructure reference.
- New work belongs on topic branches and is integrated through local merges.

## Order after the PvE slice

The accepted order is **Combat Feel Pass** first, then **Item Progression Slice**.
Do not expand the crafting/item framework now.

Combat Feel Pass covers directional melee, multiple targets, a three-hit combo
with final knockback, several Wild Dogs, mob navigation, hit reactions and player
death/respawn. Target selection assists autoattack and future skills; basic attacks
do not require a selected target. Implementation and limits: [Combat Feel Pass](../combat-feel.md).

After manually confirming combat, the user accepted the first
[Item Progression Slice](../item-progression.md): compare a dropped weapon, equip it,
observe changed server damage and retain it after relog. Mob/combat balance comes
later. This stage does not include upgrades, crafting or a generic progression framework.

The next selected stage was [character XP and levels](../character-xp.md), reusing
PlayerResource fields/curve, authoritative kill rewards, HUD, level-up and relog
persistence. Reward ownership follows loot: highest damage contribution. Balance
remains deferred. Manual user verification of initial item progression and XP is
still pending.

Following review, combat uses minimal runtime equipment/stats; XP and levels run
in RAM with dirty checkpoints around 60 seconds. Permanent kill receipts are
removed. Items retain immediate transactional persistence. Yang income uses a
runtime wallet with pending delta and a separate checkpoint; critical spending
must be atomic with the economic change. See [persistence policy](../persistence-policy.md).

## World decisions and next milestones - 2026-10-08

[Design Decisions](../Mandate_of_Three_Design_Decisions.pdf) establishes one logical
world, transparent overflow layers later, spawn regions/regional pressure,
viable solo and party play, self-sufficient classes and basic QoL without a
consumable tax. Numerical values are balance proposals.

Accepted order:

1. [Yang wallet](../yang-wallet.md), GroundCurrency, short-range autoloot without a
   pet, HUD, delta checkpoints and one test critical-spend operation.
2. Upgrade +0 -> +1: Yang + one material, 100% success, atomic item/wallet commit
   and refreshed runtime stats. No failure, downgrade, destruction, pity or scrolls.
3. One affix reroll: consume material and mutate the item in one transaction.
4. Party vertical slice: invite/accept/leave, shared instance and explicit XP,
   loot/contribution rules. Highest damage remains a temporary solo rule.
5. First regional event: kills increase pressure; a threshold spawns a Metin-like
   object at one of several points; shared combat, reward and reset.

Bosses, free base dungeons, keyed tiers, classes/auras, potions/lure, AOI, local
prediction, layering and PostgreSQL come later. Do not start another large
refactor or a general crafting framework now.

The subsequent [CEF UI spike](../cef-ui-spike.md) is an isolated technical evaluation;
it does not authorize production UI migration or change gameplay priorities.

## CEF renderer decision - 2026-10-08

CEF Web UI officially targets **Vulkan Mobile**. Compatibility/OpenGL is
**unsupported / best-effort**; its drag findings are not a blocker for the
supported Vulkan path. See [Web UI foundation](../web-ui.md). This does not yet
migrate gameplay screens or introduce CEF into server/headless targets.

## First Web inventory integration - 2026-10-08

Following acceptance of the visual placeholder, the user authorized integrating
the equipment/backpack view into the 3D game. Keep the current item domain:
24 individual bag slots (6×4), one weapon equipment slot and immediate placement
transactions. Multi-cell item sizes remain a mock until separately implemented.
The optional Windows CEF client is staged under `.godot/cef-client`, targets Vulkan
Mobile and connects to the normal servers; root/headless/Compatibility retain
native UI. Click-to-carry is the accepted interaction. Right click equips or
unequips the exact instance. See [inventory UI](../inventory-ui-prototype.md).

## Inventory contract — 2026-10-09

UI Contract v1 supersedes the previous 24-slot integration limit for this slice.
Implement Inventory only: five columns, nine rows, four pages; 1×1/1×2/1×3
footprints; no rotation; logical 40px slots; fixed, draggable, clamped window.
Schema v15 atomically migrates anchors and repacks old collisions while preserving
unique items. Keep placement/economy writes immediate. Use individual extracted
legacy PNGs only as temporary local skin, isolated behind semantic asset names.
Equipment/Shop/full HUD/final art and generic frontend frameworks remain out of
scope. See [UI contract](../ui-contract.md) and [Inventory](../inventory-ui-prototype.md).

## Prototype cleanup — 2026-10-09

The standalone CEF spike is retired after production Inventory integration.
Use the root client for native UI checks. Default verification is the
small headless persistence/bridge smoke suite; exact DOM, pixel, animation and
balance assertions do not gate routine prototype edits. Extended gameplay/asset
suites remain opt-in. See [testing and scratch cleanup](../testing.md).

## Root CEF addon integration — 2026-10-09

Retire the copied CEF gameplay project. Install pinned CEF under `addons/godot_cef`
and run the actual root project using Vulkan Mobile. Server presets omit CEF;
local headless may load the extension but must not create a browser/subprocess.
Keep large upstream native payloads ignored and installation repeatable. This
supersedes the staged-client setup above. See [integration](../cef-addon-integration.md).
