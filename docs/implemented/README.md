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
