# Loot V2 P3a — generic ground item custody

**Integration boundary:** this is a standalone, backward-compatible step toward the normal Loot V2 resolver. It does **not** enable new loot tables for kills, which remain hardcoded prototype sword + Yang in `KillRewardResolver` until P3b.

`GroundLootSystem.spawn_resolved_item(position, owner_id, owner_name, now, definition_id, amount, affixes)` now accepts any **registered canonical** item definition and its amount (1..`stack_limit`) with an explicit validated array of stat rolls. It mints **one stable ground UID at spawn**, deep-copies and freezes rolls/quantity, reserves it for owner as before, and never rerolls a pickup. The old `spawn_item(..., sword_id, bonus)` remains a temporary compatibility wrapper; the existing player loop therefore continues to drop its original sword and Yang.

`prepare_claim_item(uid, picker_owner_id, ground_record)` reconstructs an `ItemInstance` with the **identical** definition, amount, UID and rolled affixes. Existing `claim_ground_item_operation` persists UID + item + placement/receipt transactionally. Failed claims leave ground content intact; successful and already claimed receipts remove the live entry as before. Inventory refresh/publication follows only a newly committed claim.

Ground snapshots retain `item_name` and `weapon_attack` for current client presentation, while adding an `amount` key to support stacks. Materials get attack 0, never a fake attack affix. Reserved-owner/expiry, distance, line of sight and protocol authority remain unchanged.

`tests/ground_items.gd` extends the **existing real SQLite headless regression** to prove stack amount 3, stable UID/replay, invalid canonical content rejection and frozen equipment affixes. `./tests/run-smoke.ps1` runs this automatically. No SQL schema changes, no parallel wallet, no new ground persistence.

Conditional quest-only, event-only and seasonal drops are deferred to P5. Their eventual owner-only policy must **not** reuse ordinary loot's 15-second public reservation semantics.
