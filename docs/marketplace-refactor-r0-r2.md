# Marketplace refactor: R0–R2

Scope: economic safety and search load control only. R3/R4 service/composition,
R6 claims UX and Gateway session expiry remain separate review packages. No
migration, trade-model change, PostgreSQL or generic persistence interface.

## R0 baseline — 2026-10-13, shop 440bc89

Marketplace custody/purchase/search, Exchange ledger/orders, two-client market
race/Exchange retry, Yang and Web Inventory passed before runtime edits. Existing
fault injection, offline settlement, successful durable replay and process-crash
WAL recovery remain regression gates. Recovery/backup passed with FK/integrity
checks. FULL receipt commit p50 0.569 ms / p95 0.767 ms (50 local samples).

1024 distinct unavailable cancel requests inserted **1024 durable rows** into
market_commands, taking 1973.888 ms. This is the uncovered R1 abuse contract.

`market_load` reuses the legal 10k-offer seed from `market_search`, runs production
World physics, AI, accepted Warrior impacts and replication with two real clients.
Test probes surround the whole physics traversal. Tick interval is monotonic wall
clock between traversals (includes scheduling/main-thread delays), not supplied
physics delta. Each phase is six **wall-clock** seconds. Sixteen emulated query
sources submit a synchronous burst at most once per 125 ms (<=8/s/source); no test
queue/catch-up. This isolates the expensive-query path at the aggregate permitted
client load; it is not a claim that 16 authenticated network clients were tested.

| Baseline phase | Accepted/rejected searches | Physics work p50 / p95 / p99 ms | Tick interval p95 / p99 / max ms |
| --- | --- | --- | --- |
| Combat only | 0 / 0 | 0.572 / 0.936 / 1.266 | 20.712 / 20.779 / 24.845 |
| Combat + search | 448 / 0 | 212.224 / 249.328 / 280.337 | 249.411 / 280.444 / 280.444 |

Loaded-search p50 12.975 ms / p95 16.096 ms (448 samples). Both phases accepted
six attacks and observed actual impacts. The unbounded aggregate burst caused
28 traversals versus 360 without search. These are local Windows/headless
measurements, not production capacity targets or hardcoded timing test assertions.

Repeat: `tests/run-market.ps1 -Scene market_search -Marker MARKET_SEARCH_OK`,
`tests/run-combat.ps1 -Scene market_load -MarkerPrefix MARKET_LOAD`, and
`tests/run-market-recovery.ps1`. Network-derived runners sharing port 18098 run
sequentially. Fixed logs live under ignored `.godot/verification`.
