# Marketplace refactor: R3–R4

R0–R2 were accepted and merged locally into shop. This second batch is isolated
on codex/shop-r3-r4; R6 claims UX/native acceptance and Gateway session expiry
remain separate work. No schema or production wire/model changes.

## R3: application orchestration

WorldDatabase still owns SQLite, wallet/progression RAM, dirty checkpoints and
initial migrations. Its existing market_snapshot/market_command/market_query
methods delegate to one lazily-created MarketplaceService. The existing
market_account_changed signal forwards that service's account_changed fact, so
endpoints in all instances keep their existing subscription/publication contract.

MarketplaceService owns Shop/Exchange routing, the shared negative-response cache
and R2 global search budget, pending Yang collection and post-COMMIT reconciliation.
It uses the current WorldDatabase connection when constructing stores; it neither
owns/closes that connection nor creates another runtime wallet. Fresh COMMIT alone
accepts wallet totals and clears included deltas. Durable receipt replay returns
its existing result but never restores old wallet values or clears newer income.
Successful replay retains the prior authoritative snapshot refresh/publication
behavior; it does not represent a second economic mutation.

No new service-extraction unit suite: existing purchase/orders cases already test
SQL write faults, pending income, offline settlement, visible COMMIT before account
facts and newer RAM after replay. Existing search/load cases protect the shared
budget, and network cases cover actual bridge/RPC/subscription flows.

R3 passed purchase/orders/search SQLite contracts, market_network, market_race,
exchange_network, live combat+10k search load and WAL crash/backup/restore. The
shared budget still admitted 23 and rejected 697 searches; 360 physics traversals
and six accepted attacks/actual impacts were preserved in each six-second phase.
Loaded tick-interval p99 was 21.478 ms (local observation, no timing assertion).
