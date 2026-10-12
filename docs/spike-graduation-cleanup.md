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

The only registered InstanceResource is spike.tres, pointing at production
First Region. It will become first_region.tres/FirstRegion; the empty spike map
scene is used only by verification fixtures and will be moved under tests/fixtures.

The old native UI root is mounted only in InstanceManagerClient's inherited 2D
branch. That obsolete UI mount must be removed before deleting its root/HUD/menu
closure. The instance transport and inherited Map/Player/ability systems remain.
Settings/navigation/themes are active in gateway and GameWorld; UISound and
PixelIcon are used by autoloads, and FloatingDamageNumber by InstanceClient.
Removal will use a reference audit including resources, global script classes,
UIDs, dynamic resource paths, tests and tools; no blanket legacy-directory move.
