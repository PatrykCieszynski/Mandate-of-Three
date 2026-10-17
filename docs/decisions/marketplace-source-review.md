# Marketplace and item-drag source review

Reviewed on 2026-10-17 against current Markdown contracts and implementation.
The original PDFs are design provenance, not a second active roadmap:

- [Account Economy & Marketplace v1.1](../Mandate_of_Three_Economy_Marketplace_Spec_v1_1.pdf),
  2026-10-13, 16 pages; implementation baseline `e362b9eb`.
- [Item Drag & Drop Interaction System](../item-drag-runtime-system.pdf), 6 pages.

## Covered by current documentation

| Source requirement | Current reference |
| --- | --- |
| Trusted account identity, realm wallet, exclusive UID custody, receipts and unknown outcomes | [Economy C1–C5](../architecture/economy/README.md), [runtime persistence](../architecture/persistence-policy.md) |
| Base-definition catalog, upgrade range, rolled-affix AND filters, opening the whole Shop | [Search](../marketplace-e3a-search.md), [browser](../marketplace-e3b-browser.md) |
| Fungible deposits, integer ratios, maker price, partial fills and conservation | [Ledger](../marketplace-e4-ledger.md), [Exchange](../marketplace-e5-exchange.md) |
| Gesture-only runtime, advisory preview, exact/automatic placement and atomic capacity | [Item drag runtime](../ui/item-drag-runtime.md) |
| WAL backup/restore and deliberate durability policy | [Testing](../development/testing.md), [PostgreSQL gates](../plans/postgresql-migration.md) |

## Superseded assumptions

- Direct seller-wallet credit in the PDF is superseded by account `claimable_yang`
  and manual partial collection. Cancelled listings returning to claims is
  superseded by atomic withdrawal to character Inventory with capacity checks.
  See [decision delta](marketplace-v2-gaps.md) and [Shop revenue](../development/shop-revenue.md).
- The source's durable "World" namespace is now called a **realm**. World Process
  and MapInstance are hosting/simulation identities, not economic ownership scopes.
- "No PostgreSQL now" and the E0–E5 branch checklist describe an older baseline.
  World still uses SQLite; the separately approved [P1–P4 plan](../plans/postgresql-migration.md)
  includes opt-in PostgreSQL work, without authorizing a runtime switch.
- The drag PDF's Inventory/Storage/Equipment-only initial migration is historical.
  NPC offer policies now exist; Trade examples remain future cases. The sample
  subject union does not require feature routing inside the generic runtime:
  its current opaque subject/typed policy boundary is intentional.

## Details retained for later work

The source's season-close requirements were missing from the newer indexes; see
[Seasonal-to-Classic transfer](../plans/season-close-transfer.md). This is deferred
administrative work, not part of current PostgreSQL retry implementation.
Optional rotating stalls remain views of existing Shop IDs, never independent
markets. Fees, numerical balancing limits, guild/event-currency conversion and
character-slot overflow need explicit decisions rather than defaults from the PDF.
