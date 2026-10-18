# PostgreSQL P3g — local Inventory cache fence evidence

Verified 2026-10-18 on Windows, Godot 4.7.2, PostgreSQL 18.6 and pinned official
SOCI v0.4.3. Branch `codex/postgres-inventory-cache-fence`, based on integrated
`main` `1eb927d2` (PR #86 squash). No player data or installed PostgreSQL service
is used. All native runs below use fresh owned SCRAM loopback clusters and
runner-confirmed shutdown.

## Native runtime contracts

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-runtime`

Final expanded run `run-wkgzein0`: PASS, stopped (also `run-h2_w03os`). Existing admission, replay, session
takeover, unknown mutation COMMIT and recovery contracts remain covered.

- A successful unequip commits, then a separate account-locked fixture transaction
  changes items after the command's refresh snapshot. No notice is delivered.
  Post-command ACK detects staleness; runtime repairs the view before delivering
  the original success. There is one original receipt, not a repeated mutation.
- Three external committed markers delivered before polling immediately close
  the affected account and deny its cached attack inputs, leaving the other
  account ready. They coalesce into one coherent hydration. Duplicate/reordered
  old notices preserve readiness; unrelated accounts cannot schedule its work.
- A native trigger/sequence plus idle worker observation proves an ACK has
  finished in PostgreSQL while its completion remains unpolled. A newer external
  commit/notice arrives in that window. The delayed successful ACK is rejected
  by the revision floor and cannot reopen the stale view. Missing receipt remains
  `unknown_command` with no admission/receipt row after current-state repair.
- A deferred freshness-ACK COMMIT `40001` occurs **after** equip and its receipt
  committed. Runtime pauses with `outcome_unknown`, removes dependent combat
  inputs, and publishes neither terminal success nor a new change fact. The
  sequence records one ACK attempt. Explicit recovery confirms the current view,
  returns the original result and publishes one fact; the original receipt stays
  unique. This fault is a known database abort reported conservatively as unknown,
  not a simulated lost network COMMIT acknowledgement.
- A mismatched authority pauses rather than replacing the accepted authority.
  Explicit recovery can rehydrate the legitimate owner. Continual snapshot-time
  commits exhaust the existing three-repair budget and leave combat unavailable;
  explicit retry succeeds after churn stops. No unbounded per-notice queue.

## Native endpoint and unchanged SQLite

The existing `inventory-endpoint` fixture exercises real client processes,
current Master tickets, native RPCs and the production Inventory UI adapter.
An additional controlled external transaction upgrades an equipped fixture sword
under the account lock. Its committed marker invalidates the runtime, denies
attack/speed inputs for that account, and leaves the other account available.
After acknowledgement the real client receives the upgraded item and recalculated
stats. This is a cache test, not a new equipped-item Upgrade gameplay feature.

The fixture also verifies that pending and hydrated-but-unacknowledged inputs
stay gated, including its forced initial-ACK window. Existing lost response,
terminal rejection, reload, real process/relogin journal, missing-ID explicit
retry and fact/UID/privacy contracts remain covered.

- `inventory-endpoint`: final `run-kpdpkecm` PASS, stopped (also expanded
  `run-m41b0kcb` and `run-rmxj2e14`). All three actual client logs have PASS
  markers and no SCRIPT/parse errors.
- `inventory-session-bridge`: `run-uu00onq2` PASS, stopped.
- `tests/run-web-inventory.ps1`: SQLite server + two clients PASS.
- Default smoke: architecture guards + 14 Godot checks + 85 Web contracts PASS.
- SOCI v0.4.3 pin/hash and `git diff --check`: PASS.

Raw logs remain ignored under `.godot/verification`. The expected COMMIT-fault
cleanup warning and existing small ObjectDB/resource teardown warnings remain;
successful native logs have no SCRIPT/parse or unjoined-worker errors.

## Limits

See [implementation contract](../../development/postgres-inventory-cache-fence.md).
The local API requires trusted application-side committed notices; no new client
RPC, domain publisher or durable/distributed notification transport is installed.
ACK proves freshness at its transaction boundary, not perpetual freshness after
an unreported future commit. Other economic domains stay disabled in this opt-in
mode. Missed idle notifications, complete in-flight attack policy, indexed pending
discovery, pending Yang/handoff, bootstrap/shutdown and P4 remain open.

Peer identity is seeded in the runtime fixture. The endpoint fixture uses actual
client processes and Master/World native sockets, with credentials/entry initiation
and map construction controlled. No complete production PG bootstrap, playable PG
combat, Linux, native CEF rendering, load/SLA, migration or cutover is claimed.
