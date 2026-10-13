# E3b: Trading Glass and public shop

T opens Trading Glass (B retains Storage; M opens My Shop). A compact table shows
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

Native CEF verification is OPEN: the first Vulkan Mobile attempt initialized CEF
accelerated OSR on RTX 4070 but did not reach UI_READY before the fixture timeout.
No native PASS or GPU/input correctness is claimed. run-combat.ps1 supports the
explicit optional -NativeClient1 milestone, not default headless checks. Test-only
CefTexture.eval is the documented plugin method; no eval was added to production
adapter or web command surface. API: https://godotcef.org/api/ and upstream
https://github.com/dsh0416/godot-cef. Two inline PowerShell/Node debugger diagnostics
were denied by antivirus; they are not retried and no protection was changed.
