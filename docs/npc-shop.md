# NPC Shop

Implemented 2026-10-10. The Blacksmith Weapon Shop sells an infinite-stock Iron
Sword for 1000 Yang. Shop content remains in
`source/common/gameplay/shops/domain/blacksmith_weapon_shop.tres`; array order
controls offer order. Prices, quantities and the NPC's shop assignment are content.

## Authority and persistence

`ShopOfferDefinition` requires price >= 1 and quantity in 1..ItemDefinition.stack_limit.
`ItemStoreSqlite._insert_item` also rejects an invalid amount independently of Shop.
Offers contain static content IDs and presentation, never an owned item's UID/revision.

`Shop3D` lives under the authenticated map path alongside Inventory and NPC.
Opening and buying revalidate the selected SHOP service, live instance, map,
interaction context, range and service availability. Browser requests cannot
supply price, quantity, item definition, owner or content_ref. A purchase has its
own per-peer 100 ms rate limit. No new schema, stock table or transaction framework.

`ShopStoreSqlite.purchase` uses one SQLite connection and `BEGIN IMMEDIATE`:

1. Validate server-resolved shop/offer and item definition.
2. Resolve Inventory capacity (exact position, or -1 for first fit).
3. Apply pending Yang and spend the offer price with `spend_in_transaction`.
4. Create the item at the offer quantity and insert/receive at the resolved position.
5. COMMIT, then accept the committed wallet balance in World RAM and publish Inventory
   and wallet to the buyer.

Full Inventory is rejected before any wallet write. Exact occupied/invalid cells
never fall back. Any wallet/item/placement/commit failure rolls back; pending income,
RAM balance and dirty wallet state remain intact. A command acknowledgement alone
never adds an item in the browser. Infinite stock needs no post-purchase Shop update.

## CEF interaction

`shop.open` takes `{npc_instance_id, service_id}`. `shop.buy` takes those fields plus
`offer_id` and either no coordinates or all three bounded integers `x/y/page`.
The `shop` domain contains active, NPC/service/shop IDs, title/currency and ordered
name/icon/height/quantity/price offer presentations. Full snapshot validation is
atomic; malformed offers preserve the previous valid state. `ui.ready` restores Shop.

SHOP routes from the authoritative selected service to `screens/shop/ShopView`.
The view composes UiWindow, UiSlot/item icon renderer, ItemTooltip and UiCurrency.
It opens Inventory alongside Shop. Inventory remains open after Shop closes in v1.

- Right-click offer: buy into the server's first fitting space.
- Drag/click-carry onto Inventory grid: exact footprint preview and exact buy.
- Drop on the Inventory content outside its grid (for example the Yang footer):
  automatic first-fit buy, with advisory capacity preview.
- Invalid/occupied exact preview or known-full receive preview: reject locally.
- Close/Escape: return to the service menu when 2+ services are enabled; otherwise
  close NPC interaction. Escape cancels carry before navigating back.

`NpcShopOfferDragSubject` is feature-owned. The shared gesture runtime remains
unchanged and sees opaque subjects/presentation. Server errors have Shop status
feedback; failed opening exposes the NPC menu for retry instead of a blank window.

## Verification

`tests/run-smoke.ps1` includes isolated Shop purchase/rollback contracts, NPC service
checks, strict Web command validators and `shop.test.mts` for snapshot, order,
right-click, drag exact/receive, capacity, authority and menu behavior.

`tests/run-shop.ps1` is the optional two-client production RPC fixture on port 18098.
It checks pending income, private Shop/Inventory/wallet publication, foreign peer
rejection, exact/automatic purchase, occupied/funds/range rejection and menu return.
It runs sequentially with other network fixtures and uses disposable SQLite data.

Native root-client CEF appearance/input remains a manual milestone check. Headless
contracts and RPC tests do not establish GPU rendering or final visual appearance.
Upgrade, finite stock, sellback, stacking into existing items and Player Shop remain
later work; a purchased offer creates one new stack/footprint.
