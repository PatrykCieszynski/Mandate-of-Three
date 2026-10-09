# Accepted project direction

Current policy as of 2026-10-09. This file describes accepted scope and next work;
[decision history](history/project-direction-2026-10-09.md) records prior stages.

## Keep the technical foundation small

Tiny MMO supplies gateway/master/world, auth/sessions, instance lifecycle,
transport/replication and persistence. Preserve these working systems. Open-MT2
is a behavioral reference, not a dependency or runtime.

Movement, combat and pickup are server-authoritative. Clients send intentions;
server validates input, ownership, revisions, placement and economic operations.
The existing ItemDefinition/ItemInstance model is sufficient: UID, owner,
placement, upgrade level, affixes, sockets and revision. Do not build speculative
stat, crafting or persistence frameworks.

## Working vertical slice

- Server-side 3D movement/physics and remote interpolation.
- Directional melee against multiple targets, three-hit combo, final knockback,
  dogs with navigation/AI, hit reactions, death and respawn. Targets only assist
  autoattack/future skills. Balance is deferred.
- Ground item loot, reservation, pickup, transactional inventory/equipment and
  runtime combat stats. Combat does not query SQLite per swing.
- XP/levels in RAM, dirty checkpoints around 60 seconds and forced session saves.
- Yang ground currency, short-range autoloot without a pet, runtime wallet,
  pending income deltas/checkpoints around 30 seconds and one atomic test spend.

[Persistence policy](persistence-policy.md) is authoritative: soft progression
uses checkpoints; unique items and critical economy changes commit atomically
and immediately. Do not batch item pickup/equip/trade/upgrade with XP.

## Current UI and development workflow

Windows CEF UI targets Vulkan Mobile. Compatibility/OpenGL is unsupported /
best-effort. Pinned CEF is installed under `addons/godot_cef`; the client runs
the root project, with no copied gameplay tree. Exported servers omit CEF;
local headless may load the extension but must not create a browser/subprocess.
See [CEF integration](cef-addon-integration.md) and [Web UI boundary](web-ui.md).

The production Web Inventory is five columns × nine rows × four pages, with
1×1/1×2/1×3 footprints, no rotation, logical 40px slots and a fixed draggable,
clamped window. Click-to-carry and drag/drop send authoritative move intentions.
Schema v15 migrates old anchors atomically while preserving unique items.
Individual extracted legacy PNGs are temporary local skin, isolated behind
semantic names. Follow [UI Contract v1](ui-contract.md).

Inventory only: Equipment, Shop, full HUD/character sheet and final art are not
part of this UI slice. No frontend framework. Use small headless smoke checks by
default; extended gameplay/asset/export tests are opt-in. Native UI checks belong
at meaningful milestones. See [testing policy](testing.md).

Work on topic branches, inspect/check changes and merge locally with `--no-ff`.
Do not delete quarantined modules/assets without dependency analysis. Legacy save
compatibility is temporary; a deliberate schema reset/migration belongs before
public alpha. Keep existing user data paths during cosmetic project renames.

## Next gameplay milestones

Yang wallet/autoloot/test spend is implemented. The accepted order after it:

1. Upgrade +0 → +1: Yang + one material, 100% success, one atomic item/wallet
   transaction and refreshed runtime stats. No failure, downgrade, destruction,
   pity or scrolls.
2. One affix reroll: consume material and mutate the item in one transaction.
3. Party vertical slice: invite/accept/leave, shared instance and explicit XP,
   loot/contribution rules. Highest damage is a temporary solo reward rule.
4. First regional event: kills increase pressure; a threshold spawns a Metin-like
   object at one of several points; shared combat, reward and pressure reset.

World direction: one logical world, later transparent overflow layers, spawn
regions/regional pressure, viable solo and party play, self-sufficient classes
and basic QoL without a consumable tax. Numerical values are balance proposals;
see [design decisions](Mandate_of_Three_Design_Decisions.md).

Bosses, free base dungeons, keyed tiers, classes/auras, potions/lure, AOI, local
prediction, layering and PostgreSQL remain later work. For AOI, consider reusing
Tiny MMO's grid on the XZ plane. Further technical cleanup must stay bounded and
must not replace the next gameplay milestone with another large refactor.
