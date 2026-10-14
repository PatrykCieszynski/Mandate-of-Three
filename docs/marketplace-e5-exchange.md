# E5: Exact limit orders and Exchange UI

X opens Currency Exchange. Deposit plain Ore via Inventory/Storage drag into the
selection strip, enter amount, then confirm. Withdraw one stack to bag or account
claim. Have/Want selects Ore↔Yang; quantity is always base Ore units. Limit price is
positive integer Yang numerator / Ore denominator. Display free/reserved balances,
public depth, own active/closed orders and recent fills. Cancel returns only remaining
reservation. No fees, direct item-shop slots, generated unique item per fill or UI
calculation of balances. Unknown outcomes retain the command in the native adapter:
UI_READY/reload exposes Retry same command without generating a new order ID.

Schema 22: exchange_orders uses canonical base asset/quote Yang and buy/sell side;
exchange_fills records actual maker/taker and whole base/Yang amounts. Ratios normalize
by GCD. Numerator and denominator are 1..1e9, so all comparison cross-products fit
signed int64 (<=1e18). Initial quantity must be divisible by the normalized base lot;
buy reserve multiplication is bounded by MAX_YANG before mutation. A fill uses a common
multiple of both base denominators, preventing fractional units at either limit.
Unmatchable remainder stays reserved until cancellation. No float prices/settlement.

Matching is deterministic: best exact price, then monotonic SQLite sequence. Fills
use maker price. Buy reserve is released at the buyer limit while actual Yang spend
uses the maker rate; improvement immediately remains free. Partial 60+40 fills of a
100-unit order end at zero. Same-account orders never match. Price comparison reads
an indexed opposite side and sorts bounded candidates with integer comparisons.
Prototype limits: 20 active orders/account, 2048 active orders/base pair; reject rather
than silently truncate better-price candidates. Depth shows first 10 orders/side;
not an aggregate depth chart. History displays 50 own orders and 20 latest fills.

All reserve/fill/cancel/receipt writes share one BEGIN IMMEDIATE. Pending Yang on any
touched online account enters that transaction once; RAM total/reserved and dirty
state reconcile only after fresh COMMIT. A receipt replay cannot restore old RAM.
WorldDatabase emits an account fact after committed operations; every instance
subscribes, so global shops/Exchange do not depend on the requesting map. SQL fault
paths emit no success fact. Existing progression and grind checkpoints remain soft.

Verification: exchange_orders protects exact maker refund, price/time ordering,
60+40, offline maker, cancellation revision race, each write-stage rollback, pending
income, overflow bounds, conservation and reopen. exchange_network uses two real
clients for cancel/fill plus browser reload with discarded reply and retained command
retry. market_recovery terminates its own disposable writer after COMMIT, backs up
recovered WAL, restores active item escrow/order reservation/receipts and checks
integrity/FKs. It also covers the production checkpoint+copy backup and busy-reader
refusal. This is process-crash evidence, not a physical power-loss simulation.

Native Godot 4.7.2 / godot-cef v2.0.0 / Vulkan Mobile / RTX 4070: production CEF entry,
local legacy skin, query-to-full-shop/highlight, actual web Buy button, resize/reload,
focus/blur and actual Exchange Place/Cancel buttons passed. The optional fixture runs
outside the visible desktop and primes native control focus for its background focus
check; it does not replace a human check of keyboard/IME/gameplay feel. Shutdown left
no bootstrap/CEF subprocesses. Test-only eval remains outside production code.

FULL WAL sync is now the default; explicit development setting
mandate/persistence/sqlite_synchronous may choose NORMAL. Latest 50-sample actual
configure+receipt commit benchmark: NORMAL p50 0.143 ms / p95 0.215 ms; FULL p50
0.513 ms / p95 0.622 ms. One local development disk is not a production durability
or contention guarantee. Backup refuses a failed/busy WAL checkpoint before copying.
Rollback: stop World gracefully, restore a matching pre-migration DB and code version;
do not restore an old DB over later real player trades. E6 stalls and Seasonal transfer
remain deferred.

Exported client payload checks use common MarketRequestRules, not server-only
SQLite classes. Shared endpoint locals have explicit types where server stubs return
Variant. Client/server pack boot is part of the final packaging check.
