# Current implemented baseline

This is a *navigation index*, not a claim of public-production or Linux readiness.

- **Runtime:** Godot 4.7.2 Gateway, Master and one World; PostgreSQL for accounts, profiles and Economy. [Full state](../development/postgres-full-state.md).
- **Economy:** unique ItemInstances, Inventory/Equipment, Wallet/Yang, Storage, Ground pickup, NPC Shop/Upgrade, Marketplace/Auction/Exchange, transaction receipts and recovery. [Ownership contracts](../architecture/economy/README.md), [persistence](../architecture/persistence-policy.md).
- **Sessions:** validated startup budgets and Master-to-World ACK before publishing an accepted handoff. [Runtime capacity](../development/runtime-capacity.md).
- **Gameplay:** server-authoritative movement/combat, mob packs and Metins; First Region is still a graybox, not a finished authored map. [Combat](../gameplay/combat/README.md), [First Region](../world/first-region-graybox.md).
- **Client/UI:** TypeScript/CEF interfaces for core systems. [UI](../ui/README.md).
- **Terrain:** Terrain3D compatibility/authoring foundation exists; map authoring and visual polish are outstanding. [Guide](../world/terrain3d-authoring-guide.md).
- **Performance:** W0 and W1 produced *synthetic* controls; experiments do not prove real player capacity. [Evidence](../evidence/README.md).

Historical `shop` / PR #1 branch descriptions are superseded by the integrated Marketplace. Do not infer all experimental controller, AOI or multi-World features have shipped.

## Retired 2D gameplay

The TinyMMO 2D actor/synchronization runtime, abilities and effects, trade tables,
dungeon lobby/GroupService, quests and dailies are retired, including their generic
RPC handlers and editor registration hooks. Open-world Party, World3D combat,
NPC Shop/Sell/Vendor Recipes, Inventory and PostgreSQL Economy remain the current
implementations. This retirement also includes later Mandate additions built on
the old 2D runtime; provenance is not inferred from directory names.

For local inspiration, `.godot/references/tinymmo-2d/` contains separate upstream
and pre-retirement Mandate archives plus extracted sources and a SHA/hash manifest.
It is ignored, outside Godot resource scanning and absent from exports. On another
checkout, recover sources from upstream commit
`f4ed04f20963c3285117e58b1149fa1117658d3c` or Mandate commit
`de8774741d958f6ed4ec836801ea3c7b5129f96d` in Git history.

Legacy guilds and mailbox execution, related admin commands and persistent chat
history stores are also retired. Chat V1 remains ephemeral; its Guild option is
unavailable. Friends, blocks, profile customization and moderation notices remain.
The admin dashboard chat-history view currently receives an empty list from
`ChatService.recent()`: live chat monitoring is temporarily unavailable. Restoring
that view should consume public-channel messages from the current `WorldChat`,
without reviving the old messaging stores or exposing private whispers.
The old profile-JSON Inventory RPCs are retired; live Inventory/Wallet use their
existing UID/custody and account-wallet owners. Profile views no longer expose
legacy JSON gold or guild membership.

Retired profile columns are copied as opaque values through normal profile saves.
They are not normalized, migrated into gameplay, or published on login. Existing
SQL tables/data are retained with no schema migration. The static item registry
still provides legacy display metadata; its unused 2D UI helpers are removed.
Account moderation remains, but there is no authored 3D jail/lobby replacement.
