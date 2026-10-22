# Seasonal-to-Classic transfer — retained design requirements

**Status: deferred design, not implemented.** Extracted on 2026-10-17 from section
13 (pages 12–13) of the [economy source PDF](../Mandate_of_Three_Economy_Marketplace_Spec_v1_1.pdf).
This preserves future requirements for review, without authorizing a migrator,
Classic deployment or backend switch.

Seasonal and Classic are separate realm economies. Season closure should move
characters and durable property without overwriting Classic's existing state.
This is a resumable offline administrative transfer, not a database-file copy.

## Required boundary and invariants

1. Quiesce economic admissions, drain transactions, settle pending checkpoints
   and create verified backups of both realms before import.
2. Stop Exchange matching, cancel unfilled remainders and release reservations.
   Archive season orders/fills; do not import live orders into Classic's book.
3. Close Seasonal listings into safe account claims, keeping Classic's Shop
   intact. This administrative closure differs from normal player withdrawal,
   which requires Inventory space; design it as an explicit domain operation.
4. Build per-account manifests for characters, UIDs/custody, Yang, Storage,
   claims, Exchange balances, progression, quests, skills and other durable data,
   with counts and checksums before changes.
5. Preserve trusted account identity; remap realm-local character IDs and every
   dependent reference. Preserve collision-free UIDs; investigate collisions
   rather than overwrite or silently destroy property.
6. Add balances/material quantities exactly once, with cap/overflow checks.
   Item overflow needs safe claims receiving. Yang-cap overflow policy remains
   open; funds must not be silently truncated.
7. Validate per-account/global conservation of Yang, material quantities, UID
   counts, custody and item details before marking a transfer complete.
8. Keep a read-only source snapshot and audit report. The source proposes
   `(season_id, account_id, transfer_version)` as identity; durable checkpoint/
   receipt mechanics still require implementation review.

## Decisions required before implementation

- Extra/archive character slots when combined characters exceed the normal limit;
  no deletion as an overflow policy.
- Explicit mapping of guilds, rankings, seasonal titles, quests and event currencies.
- Versioned conversion for content absent in Classic, without implicit destruction.
- Administrative authorization and restart/recovery/target-admission gates,
  verified on disposable copies. Ordinary economy parity does not prove this flow.
