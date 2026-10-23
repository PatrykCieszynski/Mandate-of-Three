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
The view composes UiWindow, UiItemGrid, UiSlot/item icon renderer, ItemTooltip
and UiTab. NPC Shop uses a five-column slot grid with nine visible rows at
normal viewport size, matching the Inventory's 40 px logical cells. Offers pack
in server order into the first available footprint (1..3 vertical cells), with
empty slots retained. When an offer no longer fits, the next page starts; an
item never crosses the page boundary. Numbered tabs below the grid appear for
2+ pages and use the same skin as Inventory tabs. Small viewports scroll within
the selected page while keeping navigation/feedback clear. Catalog page and
positions are presentation only and never enter purchase commands.

Shop has no Yang balance footer; wallet presentation stays in Inventory.
Switching pages cancels carried items and hides tooltips. A same-shop snapshot
preserves the selected page (clamped if the catalog shrinks); reopening or
changing shop starts on page 1.

The shared game item tooltip recognizes typed `shop-offer` presentation and
renders its buy price in a separate footer beneath any authored description.
Ordinary owned items show no buy price. Icon quantity overlays show stacks;
name/description/price are tooltip content. Dragging preserves the actual grab
point within the item footprint, as in Inventory.
It opens Inventory alongside Shop and initially places Shop to its left using
the shared window placement rules. Content respects the common frame inset.
Inventory remains open after Shop closes in v1.

- Right-click offer: buy into the server's first fitting space.
- Drag/click-carry onto Inventory grid: exact footprint preview and exact buy.
- Drop on the Inventory content outside its grid (for example the Yang footer):
  automatic first-fit buy, with advisory capacity preview.
- Invalid/occupied exact preview or known-full receive preview: reject locally.
- Close/Escape: return to the service menu when 2+ services are enabled; otherwise
  close NPC interaction. Escape cancels carry before navigating back.

`NpcShopOfferDragSubject` is feature-owned. The shared gesture runtime sees opaque
subjects/presentation. Server errors have Shop status feedback; failed opening
exposes the NPC menu for retry instead of a blank window.

## Verification

`tests/run-smoke.ps1` includes isolated Shop purchase/rollback contracts, NPC service
checks, strict Web command validators and `shop.test.mts` for snapshot, order,
right-click, drag exact/receive, capacity, authority and menu behavior.

`tests/run-shop.ps1` is the optional two-client production RPC fixture on port 18098.
It checks pending income, private Shop/Inventory/wallet publication, foreign peer
rejection, exact/automatic purchase, occupied/funds/range rejection and menu return.
It runs sequentially with other network fixtures and uses disposable SQLite data.

`tests/run-shop-browser.ps1` is an optional real-browser milestone check, verified
2026-10-10 against production Web assets in installed headless Chrome with controlled
IPC. It covers legacy skin and CSS fallback, service menu, offer grid and carried
item icons, readable frame bounds, Shop beside Inventory at 1920x1080, 1280x720
and 960x540 with UI scales
0.9..1.5, right-click, exact/receive mouse drops, rejected previews, tooltip,
46-offer/three-page navigation, purchase from page 2, carry cancellation and
close/Escape navigation. Screenshots are optional;
there are no pixel comparisons or new default smoke requirements.

```powershell
& ./tests/run-shop-browser.ps1 `
  -PlaywrightModule 'N:/Mandate of Three/source/client/ui_web/node_modules/playwright-core' `
  -BrowserExecutable 'C:/Program Files/Google/Chrome/Application/chrome.exe'
```

Native root-client CEF appearance/input remains a manual milestone check. The
browser fixture does not establish native GPU rendering, transparency, input
routing through Godot, or real purchase persistence; the latter uses smoke/RPC.
Higher upgrades, finite stock, sell UI, stacking into existing items and Player Shop remain
later work; a purchased offer creates one new stack/footprint.

## Vendor Sell V1

The selected existing NPC SHOP service also accepts a sale basket through
`Shop3D.request_vendor(action, npc_instance_id, service_id, payload, request_id)`.
This backend is PostgreSQL-only; SQLite reference worlds return
`unsupported_backend` without attempting fallback. CEF now exposes **Sell items** from this Shop window; it opens one compact
reference-only sale basket beside Inventory. Buy and Sell use the same NPC service.
Client/server application version is 0.34.0 because the Shop RPC table changed.

- `quote`: payload `{items: [{uid, revision, amount}]}`. Items remain in Inventory.
  Result: `{ok, quote_id, yang: decimal_string, rewards, expires_at}`. Random-pool
  previews contain pool/quantity/mystery icon, never an actual reward UID or book.
- `sell`: payload `{quote_id, command_id}`. `command_id` is the stable economic
  identity; `request_id` correlates only the transport reply. Client prices,
  outputs and arbitrary quote bodies are not accepted.
- `receipt`: payload `{command_id}`. Current session authority is required;
  receipt lookup remains possible without a live NPC interaction, including after
  reconnect/restart or quote expiry. An unknown receipt allows an explicit new
  attempt only after recovery; loss of a response does not imply failure.
- Responses arrive through `receive_vendor` / `vendor_result`. Sell/replay returns
  decimal-string Yang and original `{uid, definition_id, amount: decimal_string}`
  rewards. Successful results are published after Inventory and Wallet reconciliation.

World holds one opaque quote per bound account for 30 seconds, qualified by
session generation, the map-local Shop endpoint, NPC/service, canonical sorted
basket and a hash of recipe/price/pool content. Quotes are read-only projections:
no custody, amount, revision or balance changes and no reward randomization.
Replacing the basket replaces the quote. A MapInstance/Shop endpoint change,
session change or expiry invalidates its use for a new sale; outside the current
NPC interaction/range it cannot be confirmed. An old result is recovered by ID.
Fresh quote/sell requests reauthorize NPC interaction, selected service, range and
transfer state. The transaction repeats session, UID/owner, bag custody, revision,
quantity, sellability, content/version and price checks under the account lock.

Basket bounds: 32 distinct UIDs, 1..200 units per line, at most 1000 units in total.
Repeated UIDs and malformed numeric fields are rejected. These are admission
bounds, not additional Inventory slots. Equipped, Storage, escrow/claimed or
otherwise non-bag custody is excluded; existing in-flight Inventory/Wallet
operations block new sales through the shared NPC runtime. There is no new manual
item-lock feature; current economic locks are expressed by custody and these holds.

### Recipes and initial content

`VendorRecipeDefinition` resources contain ID, priority, input requirements and
one random reward pool/count. Requirements support exact definition, recipe tag
or category. Priority descending, recipe ID ascending and canonical UID order
resolve overlaps independently of drag order. Each unit can feed only one recipe;
repeatable matches consume the maximum repetitions of that recipe in this order.
Leftovers receive the authored flat Yang price, independent of upgrades/affixes.
The pure resolver performs no SQL, RPC, mutation or random draw.

The single live recipe consumes **5 arbitrary skill books**, including duplicates,
for one uniformly random book from Aura, Charge, Whirlwind, Blessing and Strike.
Ten books yield two independent draws. A mixed basket additionally sells its
non-recipe leftovers for Yang. Books are real registered item definitions, with
`skill_book` recipe tags and `book` category; this does not introduce learning,
active skills, book drops or NPC stock. Mystery/skill-book icon IDs are presentation
seams for the later CEF pass.

Initial tuning in ItemDefinition resources: books 10 Yang each, iron sword 25,
existing tradeable materials 2 each. `vendor_price=-1` explicitly excludes sale
(and recipe input), including the debug trace sword. These values are initial
content tuning; recycling five books returns one book, not guaranteed profit.
No dynamic equipment valuation or recipe discovery list is sent to the client.

### Atomicity and recovery

The existing bounded NPC executor owns the entire transaction on one native
connection, sharing account admission, Inventory holds and captured pending Yang
with purchases/upgrades. Consumed stacks increment revision; full inputs are
deleted. Reward placement sees the freed footprints. Any capacity/overflow/SQL
failure rolls back all consumption, income, outputs and receipt writes. Wallet
capacity rejects the whole sale instead of clipping proceeds.

Only confirmation draws rewards, using unbiased random selection. Their actual
UIDs/types are stored in the same durable `vendor.sell` receipt. Replay precedes
expiry/live item checks and returns the identical original draw without consuming
new pending income. Distinct baskets/quotes under the same command ID conflict.
An unconfirmed COMMIT closes the connection and enters receipt recovery; mutations
are never blindly resubmitted. Existing safe transaction retry is limited to a
proven rollback of the whole attempt.

Verification: `tests/vendor_recipes.tscn` runs in smoke. On disposable PostgreSQL,
`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite vendor-sell`
covers preview purity, partial/mixed/repeated baskets, receipt/reopen, concurrent
commands, statement faults, uncertain COMMIT, freed capacity, wallet overflow,
backend absence and session revocation. `--suite npc-runtime` also covers real
workers/projection barriers, lost vendor completion and same-character relog.
Existing Shop RPC regression remains `tests/run-shop.ps1`. The worker/transaction fixtures and browser/native transport acceptance have
separate boundaries, described below.

### CEF basket and client recovery

Shop's **Sell items** button opens a Sell window with the common frame,
UiItemGrid and ItemTooltip. The vendor's output grid sits above the player's
offered-item grid, with **Accept** and **Cancel** below. Closing the window keeps
an unresolved sale available for receipt recovery. Inventory opens alongside it.
Inventory-only drag adds a reference (default: the current stack, at most 200 units); clicking an
offered item exposes its quantity editor, and right-click removes that reference.
Storage/equipment subjects cannot enter this target. None of these gestures
changes custody, amount, position or revision in authoritative Inventory.

The native client owns the basket and fetches a server quote after a short
coalescing delay. **Refresh offer** retries/renews it. Every edit invalidates the
old quote, and late quote results cannot replace a newer basket. Item changes
invalidate its quote without silently substituting a different revision. The
window shows exact decimal Yang and mystery rewards with a `?` and explanatory
tooltip; it neither computes prices/recipes nor draws results.

**Confirm sale** writes an immutable `npc-sell-` intent to a per-authority/account/
character journal before RPC. Pending sales freeze basket edits/confirmation but
retain a **Check sale result** action independent of Inventory placement or NPC
range. CEF reload keeps native state. Recreated adapters after relog restore the
journal and query receipts only. A found receipt confirms the original rewards;
`unknown_command` releases the old identity and requires a fresh explicit quote
and confirmation. It never auto-replays an expired quote. Any unresolved transport,
reconciliation or storage result keeps the journal; clearing failures fail closed.
Revisions/amounts inside journal records are decimal strings, avoiding JSON float
rounding. Existing server session and account locks remain the authority.

The standalone browser preview has a **Sample vendor** control and five book
fixtures. Its local native stand-in illustrates ordinary/recipe offers; confirming
reports `preview_native_only` and cannot consume items or credit Yang. It is not
a production valuation path.

Verification: smoke includes `tests/vendor_ui.tscn` and Web vendor contracts.
`--suite vendor-ui` uses the actual client adapter/journal, World owners and native
PostgreSQL workers: committed Inventory arrives before a lost response, then a
recreated adapter reads exactly one receipt and retains the original reward UID.
Transport is controlled in that fixture. Existing `run-shop.ps1` remains the real
network purchase regression. `run-core-ui-browser.ps1` performs real pointer
book-to-basket drops, removal, mystery presentation and preview confirmation without
Inventory mutation. Browser/worker coverage does not certify physical native CEF
keyboard/IME/Alt-Tab behavior or a complete Gateway-to-CEF sale journey.
