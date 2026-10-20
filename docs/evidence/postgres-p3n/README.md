# P3n — Marketplace settlement runtime evidence

Recorded 2026-10-20; acceptance runs 2026-10-19–20 on Windows. Branch
`codex/postgres-market-settlement-runtime`, based on main `e435f37a` (PR #95).
Godot 4.7.2, PostgreSQL 18.6, pinned/hash-verified SOCI v0.4.3 and Node 24.19.0.
PostgreSQL tests used owned disposable loopback SCRAM clusters and stopped them;
no real player database or installed PostgreSQL service was mutated. Raw local
logs remain ignored under `.godot/verification/postgres-readiness/<run>`.

| Acceptance | Run | Result |
| --- | --- | --- |
| Settlement runtime, final monetary drain recovery | `run-83j7n890` | PASS / stopped |
| Earlier runtime settlement/partial proceeds | `run-jf2tcvnz` | PASS / stopped |
| Eight actual client processes, final | `run-ppg8yfg6` | PASS / stopped, server + eight client markers |
| Earlier eight-client acceptance | `run-zt4apsh5` | PASS / stopped |
| Existing seller runtime compatibility | `run-jgdqpjj9` | PASS / stopped |
| Existing purchase/proceeds backend concurrency | `run-gc5rd3j_` | PASS / stopped |
| Existing wallet concurrency | `run-ef_tu4ah` | PASS / stopped |
| SQLite market RPC regression | `tests/run-web-inventory.ps1 -Scene market_network` | server + two clients PASS |
| Final default smoke | `tests/run-smoke.ps1` | Architecture guards, 14 Godot contracts, 87 Web contracts PASS |
| Configured Core UI formatting / generated JS / whitespace | Prettier configured scope, Web build, `git diff --check` | PASS |

The native runtime fixture uses real worker-owned sessions and current World
Inventory/wallet caches, with controlled peer maps. It verifies:

- Registered-session bypass rejection, self-trade/funds denial and public visit
  without private revenue/claims.
- A purchase funded by DB 1500 + pending 800 - price 2000 = 300 in one transaction.
- Lost successful COMMIT completion, read-only receipt recovery, unchanged UID,
  seller escrow removal/private refresh and durable revenue 2000.
- Replay after new income +37 preserves that pending income; current balance is
  refreshed instead of applying an old receipt balance. No duplicate commit fact.
- Alt receipt discovery after lane retirement does not retarget the original
  buyer's item. The original character still owns it.
- Wallet at cap minus 100, pending income 30: collection credits only 70, leaves
  1930 claimable, and further collection reports full. Replay credits nothing twice.
- Native deferred mutation COMMIT failure rolls back item/debit/revenue; lookup
  finds no receipt, then explicit original-ID retry succeeds after fault removal.
- One account held by an SQL lock does not stop another account's command or
  physics progress.
- During monetary COMMIT uncertainty, three failed receipt reads do not permit
  safe shutdown or release the pending prefix. Existing-lane explicit read-only
  recovery resolves it, then graceful drain joins native owners.

The existing economic endpoint fixture now includes eight actual headless
client processes. It retains Inventory, wallet, NPC, Storage, ground and seller
contracts. New phases use the production market RPC/bridge/journals for public
visit, listing, pending-funded buy with lost reply, actual buyer process exit/relog,
original-UID receipt recovery, online seller private proceeds refresh and lost
collection response recovered after UI recreation. Twenty-three known item
mutations produce twenty-three item facts; collection/replay add none. Buyer PG
balance is 300 after purchase, seller balance is 3880 after collection including
new pending income 30. SQLite economic items remain absent and Yang stays 1500.

Web contracts include restored native purchase Retry with no browser command or
remaining offer; legacy browser-ID retry remains covered. Physical rendering and
input are not exercised. The initial new Web fixture inherited a stale JSDOM
`Option` constructor; binding it to the current fixture fixed that test setup.

Other development fixture failures were corrected: inherited-scene resolution,
a frame-count watchdog ending native work early, omitted `seller_visit` control
classification, and attempting a new seller command before its scheduled private
refresh completed. Final acceptance runs have no script/parse errors or unjoined
worker warning. Expected deferred-COMMIT cleanup and small Godot resource teardown
warnings remain. An auto-review refusal prompted a process check and sequential
native test execution; no refused action was bypassed.

Normal startup remains SQLite. No schema/RPC signature change, Exchange/Auction
search adoption, complete R6 claims pagination, cross-process publication,
production bootstrap or cutover is delivered. Full Gateway-to-PG gameplay,
physical CEF, Linux, whole-World crash/failover and P4 load/soak/import/restore are
NOT VERIFIED. See [implementation contract](../../development/postgres-market-settlement-runtime.md).
