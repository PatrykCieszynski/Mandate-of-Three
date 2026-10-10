# Neutral NPC interaction and service foundation

Implemented 2026-10-10. Neutral NPCs expose declarative services. They do not own
Shop, Upgrade, Storage or Quest execution. This slice performs no purchase, item
mutation or currency write and adds no database schema.

## Static content

- `source/common/gameplay/npcs/domain/`: `NpcDefinition`, `NpcServiceDefinition`,
  the registry and `blacksmith.tres`.
- `source/common/gameplay/shops/domain/`: `ShopDefinition`, `ShopOfferDefinition`,
  the registry and `blacksmith_weapon_shop.tres`. These are separate from legacy
  upstream shop resources and use current ItemDefinitions.
- Service kinds are serialized explicitly: SHOP=0, UPGRADE=1, STORAGE=2, QUEST=3.
  Never derive kinds from UI text or reorder those values.

The Blacksmith exposes `upgrade` → `basic_upgrade` and `weapon_shop` →
`blacksmith_weapon_shop`. The shop contains one infinite-stock Iron Sword offer
(quantity 1, price 1000 Yang). Edit prices, offers and assignments in `.tres`.
There is currently only one registered production item definition.

Loaded definition resources are treated as immutable shared content. Validation
rejects malformed IDs, duplicate service/offer IDs, missing item/shop references,
invalid quantities/prices, unknown currencies/kinds and invalid interaction radii.
The non-shop references `basic_upgrade` and `account_storage` are explicit future
entry points, not implemented mechanics. No Quest content exists yet, so an
unresolved QUEST reference is rejected until that domain authors its content.

## World and authority

`NeutralNpc3D` separates `definition_id=blacksmith` from the map-scoped
`instance_id=spike-blacksmith-01`. A shared development scene is composed on client
and server at (-7, 0, 6), with a capsule placeholder visual and name label. The
`visual_id` is content metadata; a final model resolver is deferred. This fixture
is static content; dynamic NPC spawn/transform replication is not implemented.
NPCs use collision layer 8 for picking, outside the combat mob layer.

Approach the Blacksmith and click it, or press **N** within 3 m. Existing E item
pickup and B global account Storage remain unchanged. Interaction does not
implement auto-navigation to a distant NPC.

`NpcInteraction3D` lives under the authenticated map RPC path. It resolves the
stable instance ID against its own actor registry and validates the server's
player, map parent, interactable flag, content and current distance. It stores a
private runtime `NpcInteractionContext` per peer, with instance/definition IDs
and the currently selected service. Nothing is persisted for this context.

Future domains must call:

```gdscript
var authorization = world.npc_endpoint.resolve_npc_service(
    peer_id, npc_instance_id, service_id, NpcServiceDefinition.Kind.SHOP)
if not authorization.ok:
    return authorization
var shop = ShopDefinitions.get_definition(authorization.content_ref)
# Domain-owned transaction follows; service selection is not an authorization receipt.
```

The resolver checks the active interaction, current map/range, instance/definition,
service presence/kind and availability, and returns the authoritative Resource and
content_ref. Revalidate on every economically significant operation. Currency,
receiving capacity and mutations belong in the eventual atomic domain transaction.
There is no generic service executor or client-supplied content_ref.

Explicit close, peer removal, NPC teardown and world teardown clear context.
A 0.25-second runtime check invalidates out-of-range contexts and publishes changed
availability only; operations still check range immediately. `disabled_services`
on the actor provides a minimal runtime availability hook. It is not quest logic.

## CEF composition

`npc.interact`, `npc.select_service` and `npc.close` use explicit validators and
the existing per-request correlation. World → Godot controller → WebUiBridge →
DomainStore delivers the `npc` domain. `ui.ready` reloads its current snapshot.
No NodePath, domain Resource or content_ref is accepted from Web UI.

Snapshots contain active, NPC identity/name, ordered service ID/kind/label/iconId/
enabled fields and selectedServiceId. Priority then service ID determines stable
ordering. Icons are optional semantic metadata; this initial menu renders labels.
The browser validates the entire domain before replacing last known valid state.

`screens/npc/npc-service-menu.ts` composes UiWindow and UiButton and exposes a typed
selection callback. `npc-interaction.ts` owns routing based on enabled services:
0 → no window, 1 → select directly, 2+ → menu. Selection hides the menu and opens
an explicit service target placeholder. That placeholder performs no shop/upgrade
operation; corresponding feature screens replace it in their slices. Close/Escape
ends the interaction and releases its regions. Reload restores the selected target.

`openService(service, context?)` accepts an optional preselected item intent and
shares the same callback as the menu. It is presentation data, not permission to
mutate that item. Inventory-to-NPC drop wiring and actual Upgrade UI are deferred.
A later service screen can return to the menu by clearing selection while retaining
valid context; this slice closes the entire context instead.

## Verification

```powershell
& ./tests/run-smoke.ps1
# Optional production RPC check; uses isolated SQLite and port 18098:
& ./tests/run-npc.ps1
```

The smoke adds one headless content/context fixture and four focused browser
contract tests: IDs/references, validation, instance identity, map/range checks,
close/teardown, service authorization, enabled-service routing, order/callback,
optional intent and atomic snapshot replacement. The optional two-client fixture
checks real RPCs, private snapshots, selection, close and stale range. Neither
requires opening a game window or writes to actual player stores.
