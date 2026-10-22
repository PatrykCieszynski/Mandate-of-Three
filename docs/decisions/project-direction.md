# Project direction — current technical and gameplay focus

**Updated 2026-10-22.** This is the short, current orientation document referenced by `AGENTS.md`. It is **not** a ledger of completed spike branches, a balance specification or permission to build a distributed service immediately.

## Current running prototype

- Godot 4.7.2; Gateway/Master/one World Process; PostgreSQL Economy, accounts and profiles. SQLite remains a reference/legacy fixture backend. See [full-state cutover](../development/postgres-full-state.md). **One process today** is not the same as the future multi-process topology.
- Server-authoritative 3D movement, hit/target resolution, mobs and respawns. Warrior basic combos have authored timing and combat geometry; combat uses RAM equipment-derived values and does not query SQL on every hit.
- Unique ItemInstances, item ownership/revisions, transactional pickup/inventory/equip and critical spend. XP/soft progress checkpoints and farming Yang batches remain covered by the [runtime persistence policy](../architecture/persistence-policy.md).
- First Region graybox with Metins, mixed mob packs and the Blacksmith NPC. [Gameplay index](../gameplay/README.md), [combat details](../gameplay/combat/README.md), [NPC](../gameplay/npc/README.md).
- TypeScript/CEF Inventory, Storage, NPC Shop/Upgrade and Core UI presentation. Godot remains the authority; the browser sends intentions. [UI index](../ui/README.md).
- Terrain3D V4 compatibility/adoption foundation exists, but authored maps and final visual polish are **not** completed. [World and visuals](../world/README.md).

The **Marketplace/Auction/Exchange** vertical slice is integrated, with bounded PostgreSQL workers and receipt/recovery paths. Windows fixtures and local development acceptance do not imply Linux or public-production readiness. See [implementation index](../implemented/README.md) and [current persistence behavior](../architecture/persistence-policy.md).

## Accepted direction; not all implemented

- One logical realm with **dynamic player-visible public channels per busy map**, optional invisible overflow, public/private dungeon MapInstances, and eventual multi-World placement on different machines. [World architecture ADR](../architecture/world-instance-architecture.md). This **supersedes** the older “hidden layers only, no selectable CH” draft.
- Season and Classic are independent realm economies; characters/accounts/Yang are realm-scoped. One active character per account per realm is the preferred model. [Economy C1–C5](../architecture/economy/README.md) defines ownership, commands, transactions, snapshots and server-driven cancellable handoff. PostgreSQL + one World is the development runtime; distributed Economy and cross-host placement remain future work.
- Dense readable combat, viable solo classes, rewarding small parties, Metin-like upgrades and less repetitive consumable/lure friction. These are design directions, **not finalized numbers**. [Gameplay direction](gameplay-direction.md).
- Preserve physical ground loot and familiar trading. Selected valuable dungeon rewards may use manifest-backed protection and a limited 12-hour fallback stash; ordinary ground drops remain transient. C3 controls economic invariants; detailed contribution/loot balance is separate.
- Shop behavior includes price-free listings, Inventory-capacity-backed withdrawal and account-level claimable sale proceeds. Built-in bidder/negotiation escrow is deferred. Historical gaps are recorded in the [delta](marketplace-v2-gaps.md); current code and implementation docs determine completion.

## Current focus and ownership

The maintainer owns the roadmap. Avoid treating old P1–P4 and W0–W7 checklists as automatic new work. PostgreSQL full-state, W0/W1 profiling and validated session admission are integrated. Profiling/controller experiments are deferred until representative map scale and mob/player populations are defined. Current work is documentation/repository cleanup; the maintainer will provide AOI scope separately. Authored maps, actual game assets, real-client gameplay and visual polish remain important unfinished work. Do not extrapolate synthetic load tests to hosting capacity.

Use [documentation index](../README.md) to distinguish current contracts, plans, historical notes and evidence. Legacy TinyMMO systems must be audited for live RPC reachability before deletion.

## Gameplay and visuals next

Once core economic integration and immediate trust-boundary fixes are stable, return to manual combat-density feel, authored Terrain3D First Region, vegetation, atmosphere, water/shore refinements and the first public dungeon loop. Do not treat historical V0–V4 plans as new work tickets. [Visual V4 evidence](../world/visuals/visual-upgrade-v4-terrain3d.md) records current plugin compatibility and editor limitations.

**Canonical precedence:** current code + persistence/testing docs describe the running baseline; newer Economy and World contracts define intended architecture. Earlier spike plans and superseded docs exist only in Git history.
