# E1b: My Shop

Press M to open the account shop alongside Inventory. The existing Core UI window
manager controls placement, drag, clamping and user scale. The grid has 5 by 8
40-logical-pixel cells. Inventory drop/right-click selects a candidate; it remains
in Inventory until an explicit List item command commits. Enter a whole-stack Yang
price. An own offer can be repositioned, repriced or cancelled to account claims.
Collect receives the same persistent UID into the current character bag.

Name and active/paused status have their own expected shop revision. Offer edits
use expected offer revision. All mutations use durable account-scoped command IDs;
a timeout exposes Retry same command, preserving its ID and payload. Transport
request correlation remains separate. Reload UI_READY restores authoritative
snapshots. No buy path is introduced in this package.

Only marked text inputs take keyboard ownership. Blur, close and navigation release
it. Ordinary window clicks continue to allow gameplay keys. CEF remains presentation;
MarketEndpoint3D revalidates explicit payload shapes and authenticated ownership.
The view shows at most 20 claims at once; successful collection refreshes the next
batch. No item is deleted merely because a claim is outside the visible batch.

Verification: market_custody covers each edit SQL failure stage; market_network uses
two clients, real bridge/RPC/SQLite, list/edit/configure/reload/retry/cancel/claim and
text focus. Existing smoke and 75 Web contracts pass. Optional market_browser.mts
boots the production modules in headless Chrome and checks text focus, configure
and all 10 contract viewport/scale cases. This browser check is not a native CEF/GPU
playtest. The combined native marketplace milestone subsequently passed in E5.
