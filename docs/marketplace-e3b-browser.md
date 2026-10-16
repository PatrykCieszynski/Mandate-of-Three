# E3b: Marketplace search and public shop

T opens Marketplace Search (B retains Storage; M opens My Shop). A compact table shows
icon, real item +N, amount, whole-stack Yang and shop. Catalog typeahead debounces
200 ms. Upgrade from/to are independent and inverted bounds produce an error.
Bonus rows use authoritative labels/units and AND; Reset removes them. Search uses
20-row keyset pages. Hover reuses exact ItemTooltip presentation. Selecting a result
opens the whole 5x8 shop and highlights its offer; only Buy selected item purchases.
Paused/stale/gone/funds outcomes come from World, followed by a fresh shop read.
Timeout offers Retry same purchase with original command ID and expected values,
even if a subsequent refresh no longer contains the sold offer.

MarketBrowserUiAdapter owns query correlation, bounded snapshots and per-action
response generations. Close/reopen advances an epoch so old responses cannot
replace a later session. UI_READY restores the last client presentation snapshot;
queries and mutations remain authenticated server operations, never JS authority.

Verified: 76 Web contracts, production modules in Chrome across 10 viewport/scale
cases, +7..+9 AND controls, result-to-shop highlight and explicit buy command.
market_race now performs catalog/search/visit through actual native bridge/RPC
before two buyers race. Server SQL rollback/retry tests remain separate.

Native CEF verification passed on Godot 4.7.2 / godot-cef v2.0.0 / Vulkan Mobile /
RTX 4070: production module/legacy skin, result/full-shop/highlight, actual CEF Buy,
resize, reload and focus/blur. The initial fixture timeout was a background native
control-focus precondition, not a UI_READY startup failure. The optional fixture
runs outside the visible desktop and primes native control focus before its DOM field
focus check. Human keyboard/IME/gameplay feel remains a separate check.
run-combat.ps1 -NativeClient1 is optional, not default smoke. Test-only eval uses the
[documented plugin API](https://godotcef.org/api/methods); no eval is exposed to
production web commands. Startup UI_READY has bounded retries until a valid full
snapshot acknowledges it, then stops; teardown cancels it. Search criteria and
catalog text survive reload together with results, preserving cursor context.
Two inline PowerShell/Node debugger diagnostics were denied by antivirus; those
are not retried and no protection was changed.
