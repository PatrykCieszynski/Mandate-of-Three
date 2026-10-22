# P3p — Exchange order/cancel/matching runtime evidence

2026-10-20, Windows. Branch `codex/postgres-exchange-matching-runtime`, based on
main `028ab325` (PR #97). Godot 4.7.2, PostgreSQL 18.6, pinned/hash-verified SOCI
v0.4.3 and Node 24.19.0. All PostgreSQL runs used owned disposable loopback SCRAM
clusters and stopped them. No installed service or real player data was changed.
Raw logs remain ignored under `.godot/verification/postgres-readiness/<run>`.

| Acceptance | Run / command | Result |
| --- | --- | --- |
| Final matching runtime, conservation and late-login fence | `run-_3bma_tf` | PASS / stopped |
| Earlier matching/late-login acceptance | `run-a8ul4ivp` | PASS / stopped |
| Ten actual headless client processes | `run-9cc6azz0` | PASS / stopped; server and all ten client markers |
| Existing Exchange orders/concurrency | `run-nztqabix` | PASS / stopped |
| Existing wallet runtime | `run-vi95r7jv` | PASS / stopped |
| Existing Marketplace settlement runtime | `run-uirxdb7c` | PASS / stopped |
| Existing SQLite Marketplace/Exchange RPC | `tests/run-web-inventory.ps1 -Scene market_network` | server + two clients PASS |
| Web UI contracts | `tests/run-web-ui.ps1` | 88 PASS |
| Final default smoke | `tests/run-smoke.ps1` | Architecture guards, 14 Godot and 88 Web contracts PASS |
| Configured formatting / runner syntax | Prettier configured scope, Python AST | PASS |

The new native fixture uses actual PostgreSQL workers, World Inventory/wallet
owners and controlled peer maps. It covers pending-funded price-time/partial and
multi-maker fills; buy reserve and sell/buy cancellation; replay preserving newer
income; native deferred COMMIT failure with read-only recovery before explicit
same-ID execution; participant membership changed between discovery and execute;
offline settlement; and independent account/physics progress during a SQL lock.

A successful native completion is held while an offline maker logs in as an alt.
Inventory may hydrate, but the account wallet remains unavailable for balance,
income and spend until settlement resolves. It then loads the committed 1970 Yang.
The fixture also exhausts three receipt attempts during drain, verifies shutdown
remains blocked, then explicitly discovers the result. Material free+reserved totals
remain 18; total durable Yang is 5447, including the captured grinding income.

The ten-client fixture retains all earlier Inventory/NPC/Storage/ground/Marketplace/
ledger phases. It adds a lost successful matched buy, actual buyer process relog
and native journal lookup, online maker remaining-order/reserved-unit refresh,
lost cancellation response with UI recreation, and buy reservation/refund. Seller
Yang reaches 4297; buyer remains 700 after the reserve/refund cycle. Known item
mutations remain 27, with no extra item facts for order/matching or receipt replay.
Normal SQLite economic items remain absent and its wallet remains 1500.

The ten-client run preceded the final receipt-token decoder validation and
generation-map retirement cleanup. The final matching fixture and all three
backend/runtime regressions above include those final changes. No Web presentation
code changed; existing 88 Web contracts cover the shared order controls and retry.

Development runs exposed test sequencing and a fixture assumption: the next
command must wait for participant refresh lanes, and a wallet held for settlement
must not be awaited as ready during late login. Those fixtures were corrected.
The final native run has no script/parse errors; expected deliberate COMMIT-failure
diagnostics and small fixture teardown warnings do not change the contract result.

This is optional single-World coordination, with a conservative 64-participant
capture limit. No schema/protocol change, production backend selector, distributed
invalidation, public PG Auction search or complete R6 pagination is delivered.
Physical CEF, Linux, full Gateway/bootstrap, whole-World crash/failover and P4
load/soak/import/restore/cutover are NOT VERIFIED. See
[runtime contract (historical)](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/d9c7ecb42c166106aab24e772c0afad1de6908a8/docs/development/postgres-exchange-matching-runtime.md).
