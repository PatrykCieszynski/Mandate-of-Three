# Session/control/cache capacity — verification

2026-10-21, Windows / Godot 4.7.2. Based on `main` **5a71efe5** (W0 squash merge,
PR #114). This package implements the first configuration/admission slice,
not all operational budgets from the W0 inventory.

## Guarantee

Normal startup validates immutable settings, injects session/cache/control caps
and reports numeric budgets without credentials. World 64, Inventory 64, retained
Wallet 64 and Master grants 64 remain shipped defaults. The old non-enforcing
200 World metadata is replaced by an actual 64-account reservation ceiling.
Worker counts, queue capacity, Economy operation caps, schema and physics stay
unchanged. See [supported settings](../../development/runtime-capacity.md).

Master prepares the existing native PG grant, then waits for a bounded,
token/World-qualified acceptance ACK. World atomically validates capacity and
stores the unused ticket, reserving room alongside live/native-pending sessions
and retained Wallet ownership. Only confirmed current acceptance can reach the
Gateway result. No usable ticket is published on refusal/loss/deadline/supersession.
The obsolete fixed 0.5-second post-ticket wait and disconnected token signal are
removed. No public client/economic command format changed; the trusted
Master/World RPC surface adds one matching acknowledgement method.

## Executed verification

| Check | Result / scope |
|---|---|
| `git diff --check`; both architecture guards | PASS |
| `tests/run-smoke.ps1` with pinned Node | PASS, including 88 Web UI contracts |
| `tests/run-account-identity.ps1` | PASS: account identity, Gateway lifecycle/menu, native World expiry/relogin, reordered Master entry replies, new capacity contracts |
| `runtime_capacity.tscn` final focused rerun | PASS, real loopback Master/World RPC and disposable SQLite identity/profile data; no native SQL assumed |
| Invalid World startup config | PASS: `wallet_accounts=1` vs sessions 64 refuses startup with exit 1, before World/PG startup |
| PG `--suite full-state` | PASS: normal Gateway/Master/World/PG, one-account configured limits, creation/equip/relog, clean shutdown, restart and all-state backup/restore |
| PG `--suite inventory-session-bridge` | PASS: real session grants/epochs, reconnect/Master-loss and admission fences |
| PG `--suite wallet-runtime` | PASS: native wallet batching, spend, checkpoint, failure/unknown ownership and drain behavior |

All PostgreSQL runners created and stopped their own disposable clusters; no
real local realm/account database was reset, imported or migrated. No game window
or live server restart was needed. Native worker/cluster closure markers passed.

The full-state fixture now uses `max_players=1`, Inventory/Wallet budgets 1 and
Master grant budget 1. Its World process checks via public capacity methods that
both actual PG runtime owners refuse a second distinct account. This proves the
configured values were injected rather than silently using class defaults of 64.
Its client then relogs/restarts successfully with the same account.

## Focused boundary cases

- Checked-in Master/World examples parse; invalid types, schema version, unknown
  runtime keys, ranges and owner/session contradictions reject configuration.
- A malformed World metadata shape does not reach field lookups. Oversized
  declared capacity or actual World TTL <= Master ACK window never becomes ready.
- Accepted unused ticket reserves the last place; max+1 is refused before a
  Gateway ticket result. Duplicate delivery preserves expiry, same-account
  replacement reuses its reservation, and expiration releases the unused place.
- Acknowledgement waits are bounded. A replacement retires its own old wait;
  older continuation cleanup cannot revoke the newer accepted marker.
- Lost/late ACK never becomes success. Deadline is checked **at RPC receipt**,
  including a deterministic clock-boundary fixture before coroutine resumption.
- Grant/revoke owner capacity includes unresolved control work, not only SQL
  execution. Same request reuses ownership; unconfirmed revoke retains its slot.
- Actual Inventory/Wallet attach/detach and income methods run against explicitly
  seeded ready caches. Dirty or paused/unknown detached Wallet ownership keeps
  income and refuses another account. Same-account replacement can reuse it;
  a clean acknowledged state can release it. Native persistence recovery is
  covered separately by the PG wallet/session suites, not inferred from this mock.
- Capacity error is readable and not classified as transport/bad credentials.

Updated the pre-existing Master entry fixture's `save_account_collection()` stub
to return bool, matching its post-PG parent. Its old timing-based drain case now
holds the actual ACK, so it continues protecting the observable admission fence.

## Evidence paths / limitations

Ignored local logs: `.godot/verification/runtime-budget-identity.log`,
`runtime-capacity.log`, `runtime-invalid-startup.log`, `runtime-budget-smoke.log`,
`runtime-budget-full-state.log`, `runtime-budget-session-bridge.log` and
`runtime-budget-wallet.log`.

Final full-state cluster evidence: `.godot/verification/postgres-readiness/run-u9lk58bv/`;
its `capacity-proof` records rejection by actual configured PG runtime owners.
Session bridge: `run-cjevq41g`; Wallet: `run-op4zwa4j`. All reported
`OWNED_POSTGRES_STOPPED` plus their suite PASS marker.

Expected refusal cases log errors; existing ObjectDB/resource teardown warnings
remain. No claim of a leak-free process or tested physical CEF interaction.
Linux, mixed-version Master/World deployment, real high-client capacity, new
performance benchmarks and 30-minute soaks were not run. Existing economic
transaction/receipt semantics and tables are unchanged.

The normal CI now runs the existing account/session runner sequentially before
the 3D host suites. Optional PG clusters/soaks remain outside default CI.
Review this package before merge. W1 profiling and worker/operation-budget
configuration remain separate scopes; no population increase is approved here.
