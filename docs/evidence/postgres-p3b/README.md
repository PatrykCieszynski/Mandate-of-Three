# PostgreSQL P3b — durable Inventory recovery evidence

Verified 2026-10-18 on Windows, Godot 4.7.2, PostgreSQL 18.6, pinned official
SOCI v0.4.3 and Node 24.19.0. Branch `codex/postgres-inventory-intents`, based on
integrated `main` `186cf6ca`. All SQL uses fresh owned SCRAM loopback clusters,
with runner-confirmed shutdown; no installed service or player data is used.

## New boundary

Final Inventory-intents fixture `run-v99lay2s`: PASS.

- A separate owned Godot child chooses a random operation ID, receives durable
  admission COMMIT, writes its fixture marker and terminates its own process.
  Another owner discovers the pending identity/body from PostgreSQL without an
  ID passed by the producer, then resumes it. Windows may report exit code zero
  for `OS.kill`; the test fails if post-kill code executes. No unrelated process
  is addressed by PID or executable name.
- Duplicate concurrent resumes produce one mutation and equal terminal results;
  concurrent admissions produce one identity. Other characters cannot discover/
  resume it. Legacy Inventory cannot bypass pending, and conflicting Inventory/
  Exchange payloads return `command_conflict`. Ordinary Exchange place/cancel
  continues working with the new schema installed.
- Terminal business rejection and its negative receipt replay after later item
  changes and connection recreation. No new item mutation is performed on replay.
- A finalization constraint fault rolls back item changes and the provisional
  success receipt, leaving the already admitted row pending. Statement `40001`
  retries the whole command and finalizes once. A fault while finalizing a
  rejection likewise leaves no negative receipt and keeps pending.
- Deferred COMMIT `40001` during admission or execution publishes unknown, not a
  durable ACK or automatic new execution. The fixture verifies its known aborted
  state before explicit same-ID recovery; this does not establish the outcome of
  arbitrary lost COMMIT responses.
- Eight pending intents exhaust account capacity; rejected admission reserves
  nothing, and finishing one restores capacity. Two-row pages expose all fourteen
  fixture identities without duplication. Expected revisions beyond 2^53 remain
  exact native int64 values. Recovery cursors are scans, not outcome changefeeds.

## Shared-owner regression matrix

The shared command owner now respects optional Inventory reservations. All
seventeen native packages passed on separate fresh clusters:

| Suite | Run |
| --- | --- |
| inventory-intents (matrix run) | `run-ev_ziyf7` |
| inventory-executor | `run-0izi_0p9` |
| readiness | `run-hxw2t55s` |
| commit-failure | `run-dsxzmc_i` |
| wallet | `run-rbp16et0` |
| npc-shop | `run-29p_7z5e` |
| inventory | `run-zj8fdjyf` |
| storage | `run-hmy5i44z` |
| upgrade | `run-hw7chnvi` |
| shop-seller | `run-6creepe4` |
| shop-settlement | `run-x2cdnf8z` |
| account-claims | `run-fyati7mx` |
| auction-search | `run-ax3qbvyl` |
| exchange-ledger | `run-3r54ysjv` |
| exchange-orders | `run-gt_5qtm2` |
| wallet-concurrency | `run-wd5c_ruz` |
| inventory-concurrency | `run-_uhbrwf7` |

Final focused run adds the owned-path guard and ordinary Exchange compatibility
case. Default smoke: architecture guards, 14 Godot checks and 85 Web contracts
PASS. Runner AST, pinned payload and `git diff --check`: PASS.

An initial crash-fixture assertion incorrectly required a nonzero self-kill exit
status on Windows. It was corrected to verify the pre-kill durable marker and
absence of post-kill execution; no production workaround was added. Failed and
successful logs remain distinct under ignored `.godot/verification`.

## Limits

This is opt-in durable Inventory identity/recovery, not active World/session
admission or a live PostgreSQL route. Authentication/epoch revocation, runtime
reconciliation, pending Yang, CH handoff, other domains, receipt retention/rate
policy and P4 runtime load/soak/cutover remain open. No claim for crash during
active SQL, lost transport COMMIT, real World/network/CEF, Linux or multi-World.
Production remains SQLite.
