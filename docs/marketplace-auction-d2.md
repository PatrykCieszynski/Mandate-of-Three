# Auction D2 — load, lifecycle and economy observations

Review topic: `codex/auction-d2-load`, based on integration `auction` at
`7f274ab`. Recorded 2026-10-14 with Godot 4.7.2 and verified, unmodified
godot-soci v0.4.1. R6 has not started.

**Windows functional contracts pass. Full D2 acceptance remains pending Linux
runtime evidence and review of write-related tick latency.** SQL-only/native
conversion timing is unavailable through the public addon API. Worker round-trip
is not SQL time; Linux export is not Linux runtime evidence.

## Reproduction and scope

```powershell
& .\tests\run-web-inventory.ps1 -Scene market_load
& .\tests\run-market-recovery.ps1
```

The same load runner works on Windows/Linux:

```sh
python3 tests/run-auction-load.py --godot /absolute/path/to/godot
```

Prerequisites: Godot 4.7.2, Python, the existing godot-sqlite addon for that OS,
and pinned SOCI (`python tools/soci/setup.py`, verify with `--check`). No browser,
CEF setup or live Gateway/Master is needed. The runner checks port 18098 is free,
creates three headless processes and isolates APPDATA/LOCALAPPDATA/XDG directories
under `.godot/verification/auction-d2`. Run network suites sequentially. Success
removes its DB and retains fixed-name logs/results; scoped backup/cache cleanup
uses `clean-dev-artifacts.ps1`.

The fixture matches WorldMain's 60 physics Hz / 60 max FPS, WAL/FULL and production
async service, with combat, AI and replication in the existing test arena. There
are **two physical WebSocket clients plus sixteen simulated enrolled account
query sources**. Simulated sources exercise service admission/native execution/
projection, not sixteen network/session paths. The real clients cover authenticated
async search, correlation, independent 8/s peer budgets and endpoint destruction/
reconnect. Fixture identities replace Master login; full Gateway/Master/CEF
acceptance remains R6 work.

10,000 offers are spread over 500 shops, 20 swords each. Canonical custody and
legacy character ownership both follow that distribution. The old SQL fixture
assigned all legacy owners to the combat hero, inflating inventory refresh cost.
D2 opts into distributed ownership; historical SQL parity cases keep their
original data. Earlier skewed-owner exploratory numbers are not the reference.

Each phase offers traffic for six seconds; drain is included in measured duration.
Sixteen sources submit broad/selective affix queries at up to 8/s each, quantized
by real ticks without catch-up bursts. Two real clients additionally search at
up to 4/s. The normal write phase yields between commands; the separate burst
phase intentionally groups list/edit/buy/replay into one physics callback.
Neither changes production scheduling or persistence. Fixture invulnerability
and target HP restoration sustain combat without minting unrelated kill income.

## Windows reference result

Host: Windows 10 build 19045, AMD Family 25 Model 33, 12 logical CPUs. These are
local debug-engine observations, not a clean release capacity certification.
Pre-existing user edits to combat/resource settings were preserved and used
consistently across phases. Sample counts, per-account progress, write operation
costs and RPC outcomes are in [results.json](evidence/auction-d2/windows/results.json).

| Phase | Successful reads | Rate-limited | E2E p50 / p95 / p99 (ms) | E2E max (ms) | Tick p99 / max (ms) |
| --- | ---: | ---: | --- | ---: | --- |
| Combat only | 0 | 0 | — | — | 16.691 / 16.698 |
| Combat + search | 223 | 545 | 101.312 / 233.346 / 451.303 | 500.957 | 16.960 / 47.707 |
| Combat + search + sequential writes | 215 | 569 | 101.251 / 210.705 / 451.760 | 534.815 | 24.219 / 25.017 |
| Combat + search + write burst | 196 | 572 | 101.893 / 267.416 / 434.421 | 467.366 | 36.829 / 57.587 |

Every simulated account completed searches in every loaded phase. Normal backlog
peaked at 19 including the native slot. A separate 65-account burst admitted 64,
rejected one and settled all 65 once. Shedding/coalescing is visible; this is not
a claim that all offered 128+ searches/s succeed. Existing `auction_queries` also
covers queued expiration, active timeout, late suppression and busy-drain refusal.

Sequential-write queue wait p50/p95/p99: 68.274/194.187/418.462 ms. Worker
round-trip: 31.884/48.560/49.242 ms. Main projection: 1.083/1.322/1.608 ms.
Polling including completion callbacks: 1.117/1.838/2.144 ms. Poll/projection
overlap and must not be added together. Successful service E2E includes queue,
worker completion, projection and the pre-delivery deadline check. Real-client
E2E additionally includes transport/frame delivery and records both success and
controlled errors: client 1 completed 31 searches, client 2 completed 32 and
successfully reconnected.

Native SQL p50/p95/p99 is **null/unavailable**. Public SOCI v0.4.1 has completion
without native execution timestamps. Worker round-trip includes worker scheduling,
native conversion/marshalling and main-frame polling. Projection on main is measured
separately; native conversion cannot be isolated. No addon patch or extra worker
was introduced to manufacture missing measurements.

Tick intervals measure monotonic physics-start spacing. Physics-work probes
measure callback traversal; coroutine resumption outside that traversal affects
tick intervals and operation wall time, not necessarily the traversal sample.
Successful queries stayed below the admission deadline of 2s, but write phases
show worse tail latency than baseline. The short run/sample count is not an SLA,
and the same-tick burst must not be called a stable 60 Hz profile.

Mutation timings include validation, immediate writer transactions, post-commit
account publication and inventory refresh, not isolated SQL/fsync. Review should
decide whether the sequential-write tail is acceptable for this prototype and
whether scheduling/publication needs a focused next pass. Do not weaken FULL,
batch economic writes, add a writer worker or migrate persistence from this
short benchmark. Asynchronous reads do not eliminate main-thread mutation work.

## Verified behavior

- Twelve list/edit/purchase cycles with pending income, SQL fault rollback and
  same-command replay. Yang: 974,000 + 60 declared income = 974,060; zero reserve.
  One sword UID remains in final purchaser bag custody; twelve durable buy
  receipts despite retries. The 10,000 catalogue offers remain unchanged.
- Exchange deposit, reserve, partial fill and cancel during reads: ten materials
  conserved, zero remaining reserve.
- Active-traffic backup: 365.738 ms including drain/readiness. The copy **from
  this run** is independently opened and checked for integrity, foreign keys
  and complete catalogue. Reader quiesce/recreation: 46.130 ms. Lifecycle traffic
  reports 64 controlled `storage` while admissions pause and 175 `rate_limited`
  across lifecycle/capacity/reconnect. There is no hidden accumulating queue.
- Real client 2 abandons a query, destroys its endpoint and reconnects with a new
  peer/session; new search succeeds with correct correlation. GameWorld removes
  old actor/query scope. Fixture cleanup uses production progression/wallet
  flush/release APIs without a live Master.
- The existing recovery runner now kills its owned disposable process during
  continuous SOCI traffic, restores a committed post-backup WAL change, checks
  escrow/reserves/receipts and
  restarts a native reader against restored data. Search succeeds after restart.
  This is distinct from reader recreation and does not claim seamless two-client
  reconnection across a full World process crash.

[Validation evidence](evidence/auction-d2/windows/validation.json) lists actual
suites/markers. The intentional rollback logs its named SQL error. Established
ObjectDB/resource teardown warnings remain, and the fixture can report snapshot
RPC attempts after peer close. Successful runs have no assertion/script error,
crash, hang or orphan owned subprocess. This is headless evidence, not CEF UX.

## Remaining acceptance gates

Linux runtime is **NOT VERIFIED**. Actual Ubuntu launch fails with
`Wsl/Service/CreateInstance/CreateVm/HCS/HCS_E_HYPERV_NOT_INSTALLED`; virtualization
is unavailable. `wsl --status` and previously exported Linux packs are insufficient.
The common runner is ready for a Linux host with pinned engine/addons. Host
virtualization settings were not changed.

SQL-only/native-conversion metrics require separate native timing evidence or an
explicit acceptance of the public API limitation. Write-related tick tail also
needs review. Do not mark the full cross-platform D2 gate passed or begin R6
automatically from these results.

## Implementation boundary

Production change: one optional local `AuctionQueryService.observation` signal
for reply/queue/worker/poll/projection samples. It retains no history, emits only
with a subscriber and adds no wire fields. Routing, schema, writers, queue
limits, deadlines and addon code remain unchanged. Load generation, enrollment,
invulnerability, target HP restoration, fault injection and buffers stay in
existing fixtures. The cross-platform runner kills only subprocesses it creates.
