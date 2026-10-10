# Accepted project direction

Current policy as of 2026-10-10. This file describes accepted scope and next work;
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

Production Inventory and the weapon Equipment window compose the small internal
[Core UI](core-ui.md). Shared shell/chrome, semantic skins and separate UI/item icon
resolvers reduce repeated window code. Domain state and actions remain in screens;
Account Storage (15×9×2) is integrated through the same CEF bridge; B opens it,
with server-authoritative atomic deposit/withdrawal and account access.
The neutral NPC foundation now exposes data-defined services through an
interactive development Blacksmith: Upgrade and Weapon Shop. Server contexts and
service authorization are map/range scoped. Shop offers are editable resources;
NPC Shop purchases now atomically receive items and spend persisted/pending Yang.
The CEF Shop supports right-click, exact Inventory drops and automatic receiving;
Upgrade now supports [atomic +0 → +1](npc-upgrade-ui.md), consuming Inventory
material and Yang, with server selection and an Inventory-to-Blacksmith drop entry. See [NPC services](npc-services.md) and
[NPC Shop](npc-shop.md). Global MVP Storage remains available through B.

A full HUD/character sheet and final art remain outside this slice. No frontend framework. Use small headless smoke checks by
default; extended gameplay/asset/export tests are opt-in. Native UI checks belong
at meaningful milestones. See [testing policy](testing.md).

Work on topic branches, inspect/check changes and merge locally with `--no-ff`.
Do not delete quarantined modules/assets without dependency analysis. Legacy save
compatibility is temporary; a deliberate schema reset/migration belongs before
public alpha. Keep existing user data paths during cosmetic project renames.

## Camera presentation slice

[Camera v1](camera-v1.md) adds an independent client orbit/zoom rig with
sphere collision, damped return and data-defined settings. Manual WASD follows the camera on the XZ plane while preserving the existing
bounded intention protocol and server authority. Auto-align is off by default. Native
feel/CEF interaction still require the documented manual acceptance pass.

## Next gameplay milestones

Yang wallet/autoloot/test spend, NPC Shop and the +0 → +1 Upgrade slice are
implemented. Upgrade supports Inventory items only, one material, pending Yang
and 100% success. Higher upgrades/failure/destruction remain deferred. Next:

1. [First region graybox](first-region-graybox.md): hub, three combat areas, routes,
   landmarks, camera obstacles, four Metin sites and a water test strip. Implemented;
   scale and travel/combat feel need a manual pass.
2. [Metin Encounter v1](metin-encounter-v1.md): implemented shared stone combat,
   threshold waves, ground rewards and timed respawn. Native loop playtest is next.
3. Spawn/pacing pass, then a visual pass after the playable loop is assessed.

One affix reroll and the party vertical slice remain planned after this focused
world loop. Regional pressure (kills, threshold, event spawn and reset) remains the
accepted direction for a later event cadence pass, not another framework now.

World direction: one logical world, later transparent overflow layers, spawn
regions/regional pressure, viable solo and party play, self-sufficient classes
and basic QoL without a consumable tax. Numerical values are balance proposals;
see [design decisions](Mandate_of_Three_Design_Decisions.md).

Bosses, free base dungeons, keyed tiers, classes/auras, potions/lure, AOI, local
prediction, layering and PostgreSQL remain later work. For AOI, consider reusing
Tiny MMO's grid on the XZ plane. Further technical cleanup must stay bounded and
must not replace the next gameplay milestone with another large refactor.
