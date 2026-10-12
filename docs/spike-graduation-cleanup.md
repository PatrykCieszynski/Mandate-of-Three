# Graduation cleanup — 2026-10-12

Package C integrated locally into codex/spike-graduation at 63aa38b.
Work continues on codex/spike-graduation-cleanup before the final main integration.
Exactly three changesets: production naming, production layout, unused legacy UI.
No further architecture, gameplay, transport or persistence redesign.

## Production naming

GameWorld3D, Actor3D, PlayerActor3D, MobActor3D, CombatEndpoint3D,
InventoryEndpoint3D and CurrencyEndpoint3D replace production Spike* classes.
Files and references follow their names; script UIDs are retained.
The authenticated 3D instance adapters are named world_instance_3d.gd.
BasicAttackService, PlayerCombatRuntime, MobSystem and ClientCombatController keep
names and behavior. Historical branch names/test runner markers remain unchanged.

## Audit before removal

At the start, the only registered InstanceResource was spike.tres, pointing at production
First Region. It will become first_region.tres/FirstRegion; the empty spike map
scene is used only by verification fixtures and will be moved under tests/fixtures.

The old native UI root is mounted only in InstanceManagerClient's inherited 2D
branch. That obsolete UI mount must be removed before deleting its root/HUD/menu
closure. The instance transport and inherited Map/Player/ability systems remain.
Settings/navigation/themes are active in gateway and GameWorld; UISound and
PixelIcon are used by autoloads, and FloatingDamageNumber by InstanceClient.
Removal will use a reference audit including resources, global script classes,
UIDs, dynamic resource paths, tests and tools; no blanket legacy-directory move.

## Production layout

The graduated runtime lives under common/gameplay/world3d: game_world_3d,
actors/, combat/ and endpoints/. ClientCombatController moves to
source/client/gameplay/combat, with its architecture guard scope following it.
All resource/script/guard/test references follow the new paths; UIDs stay intact.

First Region is the sole registered startup/default resource, now
instance_collection/first_region.tres with instance_name FirstRegion. Login always
selects the configured default resource, so this is not a player-save migration.
The empty arena moves to tests/fixtures/world3d/test_arena.tscn. Both scene roots
are named GameWorld on server/client; existing endpoint child names/channels and
intention payloads stay unchanged. Network checks verify the matched paths.
Inherited common/gameplay/combat, characters and items remain in place for later
skills/content work. Their presence is not an endorsement of the old UI runtime.

## Legacy UI removal — audit and outcome

125 unused native UI files removed (scripts, scene resources and UID companions):
ui.gd/ui.tscn, old hud/, all old menus except settings, slot-picker component,
native ItemTooltip/RewardFormat, unused touch-stick/input-hint helpers. No assets
or old ability/character/item content were removed and no legacy directory was added.

Reference scan covered resource paths, global GDScript classes, script/scene UIDs,
retained UI dependencies and runtime/test/tool callers. Dynamic menu loading was
owned by the removed HUD closure. Before removal the only external references to
that closure were the inherited 2D UI mount and its UI-typed field in
InstanceManagerClient. The only registered production instance is 3D First Region;
we removed this obsolete native UI mount/ownership, retaining map/session logic.
After detaching it, the scan found zero external references to the removal set.

Retained native UI (49 files):

- settings/ (moved from menus/settings/, preserving UIDs): gateway and GameWorld.
- shared/navigator, nav_panel, drag_scroll and menu_blur_backdrop: settings dependencies.
- themes/ and styles: shared gateway/settings palette and theme tooling.
- UISound/PixelIcon: autoload feedback; FloatingDamageNumber: InstanceClient dependency.

Native UI removal does not remove CEF ItemTooltip or the current combat XP/wallet
presentation. Old shared gameplay/content is classified in
[inherited-runtime.md](inherited-runtime.md), not relocated or rewritten.

## Verification

PASS: Godot import/parse; git diff --check; default smoke (10 Godot + 74 Web UI),
architecture guard/contracts; Web Inventory before/after cleanup, ACTION, FEEL2,
movement/network, First Region (loaded through its production InstanceResource),
Metin network. Network suites ran sequentially on their shared test port.

The retained settings scenes and gateway loaded headless, and settings instantiated
with disposable APPDATA. Packaging boundaries passed for Windows, ServerWindows,
ServerUbuntu; Windows/ServerWindows packs passed the existing headless bridge boot.
CEF remained excluded from server packs. No production TypeScript/static JS,
payload fields, checkpoint policy, attack behavior or combat balance changed.

Native Godot/CEF/Vulkan graphics/input acceptance remains separate. This cleanup
is local on its topic branch; the complete graduation is not yet merged to main
or pushed. Package C alone is already locally integrated at 63aa38b.
