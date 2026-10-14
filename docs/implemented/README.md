# Implemented and verified — branch-aware index

This is a **map to implementation reports**, not a statement that every manual/native test has passed. Read the report's date, branch and validation limits.

## On `main` (existing prototype)

| System | Evidence / contract |
| --- | --- |
| Item UID, inventory, equipment and pickup | [ItemInstance](../item-instances.md), [ground loot](../pve-ground-loot.md) |
| Yang checkpoints and critical spend | [Yang](../yang-wallet.md), [persistence](../persistence-policy.md) |
| Server-authoritative 3D combat and mob packs | [Combat trace](../warrior-combat-trace-v1.md), [mob packs](../mob-packs-v1.md) |
| First region, Metins and native visual passes | [First region](../first-region-graybox.md), [Metin encounter](../metin-encounter-v1.md), [Visual V4 terrain foundation](../visual-upgrade-v4-terrain3d.md) |
| CEF Core UI, Storage, NPC Shop/Upgrade | [Core UI](../core-ui.md), [NPC services](../npc-services.md), [Upgrade](../npc-upgrade-ui.md) |
| Build and regression policy | [Testing](../testing.md), [CI](../ci.md) |

## Implemented on `shop`, **not yet merged to `main`** (at time of writing)

[Marketplace PR #1](https://github.com/PatrykCieszynski/Mandate-of-Three/pull/1) adds verified account identity, account Yang, durable Shops, Auction search, Exchange and many regressions. Auction PR #2 was integrated into `shop`. Read its PR body and the branch-specific reports for scope, platform gaps and native/SQL limitations.

The [newer Marketplace policy](../decisions/marketplace-v2-gaps.md) intentionally differs from that implementation in several UX and payout rules. Do not mark these changes implemented until they pass tests and merge.

For upcoming hardening packages, use the [technical implementation plan](../plans/architecture-hardening.md).
