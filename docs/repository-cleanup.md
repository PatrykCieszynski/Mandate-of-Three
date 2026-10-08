# Mandate of Three fork cleanup

This is a Godot Tiny MMO/Ekonia fork with intended 3D gameplay.
Architecture plan: `Mandate-of-Three_TinyMMO_Spike_Plan.pdf` in this directory.

The project owner chose to start cleanup before the 3D spike. Keep a minimal
client -> gateway -> master -> world path to test login, character creation,
instance entry and replication.

## Stage 1: 2D maps and presentation

Removed:

- All Ekonia maps, tilesets and map template.
- Their instance definitions and the dungeon keeper NPC referencing a deleted dungeon.
- 2D weather and its client/map-model integration.
- World clock, day/night cycle, ambient light and `get.server_time` endpoint.
- Campfire/firefly effects.

Spike is the only instance definition. Every login/recall enters it. The initial
technical 2D scene was replaced by
`source/common/gameplay/maps/spike/spike_map_3d.tscn`: floor, walls, obstacles and
server-physics player capsules. Status: [spike3d.md](spike3d.md).

## Stages 2-3: disconnected Ekonia gameplay systems

These systems were removed with active calls, menus and endpoints:

| System | Removed connections |
| --- | --- |
| Basing / territory | Tick, map-flag registry/damage, menus, endpoints, flag persistence API and territory-only guild upgrades. |
| Sparring | Matchmaking/rating, death/disconnect hooks, damage rules, team tints, equipment/level normalization, countdown, menus/endpoints. |
| Mastery | Weapon XP, trees/loadouts/passives, spawn/equip refresh, replicated special-skill pseudo-slots, tabs/messages/endpoints. |
| Jobs | Professions, XP/perks, gathering gates/bonuses, Jobs tab/endpoints. |
| Ekonia crafting | Stations/map registry, recipes, menus and craft.item endpoint. |
| Leaderboard | Ranking service, statues, kill/dungeon-clear hooks, menus/endpoints. |

Character shows only Stats. Help/welcome describe the technical map rather than
the removed cell, Hall Keeper and territory acquisition. Gathering temporarily
retains item yield and fixed cooldown without profession XP/perks. Weapons keep
scene-defined skills; consumables keep their own use action.

Historical SQLite migrations and persisted skills/masteries/loadout, guild stats
and flags remain for existing-save compatibility. Removed systems have no active
runtime. Schema rebuilding/historical-field removal require a separate pre-alpha
stage. ItemInstance already uses separate SQLite tables independent of legacy payloads.

Demo assets/audio still used by login, remaining UI, 2D characters/items are removed
only after reference analysis or replacement of those layers by 3D.

## Stage 4: second cleanup after the PvE slice

2026-10-07, branch `codex/second-cleanup-readme`. The user manually confirmed PvE
before this stage. Removed **157 unused assets** plus .import metadata:
**314 files**, approximately **6.92 MiB** of original assets:

- 133 environment/building/terrain textures left after map deletion.
- Six map music tracks: fungus, lost_woods, market, shadow_temple, shop, village.
- 13 old skill/mastery icons without remaining references.
- Five unused 16px menu icon variants.

Manifest: [cleanup-2-removed-assets.txt](cleanup-2-removed-assets.txt).
Candidates needed no path/UID references in remaining scripts, scenes, resources,
configuration or addons. Cross-asset references were considered. Dynamically loaded
status/daily/menu 32px/emotes/guild-trophy folders were excluded. Editor icons,
fonts, 2D models/items and assets still connected to login/quarantined modules remain.

README now describes the actual project, controls, local start and tests. Upstream
is retained in credits/infrastructure references; LICENSE and remaining-asset
attributions are preserved. SQLite schema/quarantined modules were not rebuilt.

Verification: no removed-path/UID references in source, addons/tinymmo,
configuration, tests or remaining assets; editor import without parse/missing-
resource errors; all 872 source resources loaded. run-items, run-spike3d and
run-pve passed, including two clients fighting one mob and competing for pickup.
`git diff --check` passed.

Party, guilds, trade, shops, quests, dungeon and events remain for separate review
under the plan's QUARANTINE category. Their presence does not commit them to MVP.

## Verification

Check removed-resource res:// paths/UIDs, Godot import and two local clients entering
Spike. Import alone does not prove login or movement replication.

Verification after stages 1-3, before 3D rework (2026-10-07), using local Godot 4.7.2:

- `git diff --check`: passed.
- 187 removed tracked files: no path/UID references in source or addons/tinymmo.
- Editor import: no script errors after removing missing MCP addon configuration.
- All 861 remaining source scripts/scenes/resources loaded without compilation or
  missing-dependency errors.
- Scene smoke: exactly one Spike instance; map instantiates without NPCs/warpers;
  master/gateway/world scenes load.
- Four-role local startup: gateway/world connect to master, world opens SQLite,
  client starts the login scene.
- Manual two-client test (2026-10-07): user confirmed operation. Screenshot shows
  different peer IDs and Dralusa/Lynanel visible in both windows, confirming
  world entry and mutual visibility.
- Bidirectional movement: manually confirmed by the user on 2026-10-07.
- Reconnect: not yet checked at that stage.

Test processes stopped automatically after a bounded frame count. Logs include
Windows certificate-store access and exit-resource diagnostics; runtime is not
claimed entirely clean. Headless tests do not prove UI/map appearance.

Local startup needs master-server, gateway-server, world-server and two client
processes. Entry supports feature tags and `--mode=<role>` before Godot's `--`
separator; the parser uses `OS.get_cmdline_args()`.

## Stage 5: local converter removal and English documentation

2026-10-08, branch `codex/english-docs`. The owner authorized committing deletion
of the five tools/legacy_assets converter/index/catalog/config files. Their
obsolete Python fixture, CI step and local batch-conversion runner were removed
as dependent tooling. Selected-GLB staging in tools/dev_assets, visual resolvers,
tracked placeholders and the batch fallback scene remain.

Conversion history is retained in [legacy-asset-pipeline.md](legacy-asset-pipeline.md).
README, project Markdown and the two planning PDFs now use English. Historical
verification reports and decisions remain historical; translation does not
implement future milestones or alter gameplay/persistence policy.
