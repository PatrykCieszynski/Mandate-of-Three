# Inherited TinyMMO — current compatibility boundary

First Region runs through `common/gameplay/world3d/`, the Mandate domain modules
and CEF. TinyMMO Gateway/Master/World transport, authentication, sessions and
persistence infrastructure remain the network foundation.

## Retired content

The unused 2D enemy types, weapon/armor variants, merchants, sprite sheets and
raster VFX resources have been removed together with their registry entries.
The remaining catalogs do not advertise those resources. Surviving IDs and
`next_id` allocation are preserved; removed IDs must not be reassigned casually.
The `enemy_types` registry is intentionally empty: production mobs use
`MobDefinitions` and their server-authoritative 3D runtime instead.

Character creation retains the existing default appearance ID through a data-only
Warrior resource. The inherited registry name `sprites` remains a profile/API
compatibility key; its entries no longer require TinyMMO SpriteFrames. Actual
Warrior rendering belongs to the 3D presenter. This is not a cosmetic roster or
a new character selection feature.

Gateway keeps normal account/guest authentication, World selection and character
creation. Its temporary presentation uses Godot flat styles, built-in fonts,
procedural palette backgrounds, text character cards and a native loading bar.
No authentication bypass or automatic creation of a guest account is introduced.

## Deliberately retained code and data

- `PlayerResource` and inherited social/quest/profile types still participate in
  persistence and data request handling. Removing the entire `characters` folder
  would remove supported state as well as obsolete presentation.
- The old Item/Inventory types, starter potion/gold and the small content graph
  referenced by retained quest/gathering data remain compatible with SQLite
  reference fixtures. Their optional deleted icons/textures have been detached.
  This does not add those inherited activities to First Region gameplay.
- Legacy 2D instance/character adapters and ability types still have typed users
  in shared code and RPC/security fixtures. Their raster effect callbacks/defaults
  have been retired. Replacing these types is a separate ownership change, not a
  reason to restore deleted art or extend the legacy path for new 3D features.
- `common/gameplay/combat/` also contains active Warrior combo/trace/hit-reaction
  definitions. Its directory must not be deleted as an undifferentiated legacy
  subsystem.
- The `mandate_tools` export plugin and CEF legacy skin adapter are active
  dependencies despite their inherited names.

Normal gameplay uses PostgreSQL. Preserving SQLite fixtures does not authorize
fallback or independent economic writes outside the current owners. See
[persistence](../architecture/persistence-policy.md).

## Verification and future removals

The default [smoke](testing.md) checks that all registered content exists and
loads, that IDs/slugs are unique in each catalog, and that the default character
appearance remains selectable. It does not couple tests to exact catalog sizes,
UI geometry, art or balance.

Before another removal, check explicit resource paths, UID references, registry
IDs, dynamic lookup and supported RPC/test reachability. Reimport can rebuild a
missing cache only while the source exists; it cannot repair a deleted PNG.
Preserve imports/editor cache during disposable artifact cleanup.
