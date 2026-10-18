# PostgreSQL P3f — Inventory endpoint/client evidence

Verified 2026-10-18 on Windows with Godot 4.7.2, PostgreSQL 18.6 and pinned
official SOCI v0.4.3. Branch `codex/postgres-inventory-endpoint`, based on
integrated `main` `802f57e6` (PR #85 squash). All PG runs use owned SCRAM
loopback clusters, isolated profiles/identity SQLite and runner-confirmed shutdown.

## Native RPC and real client processes

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite inventory-endpoint`

Final expanded run `run-ce10bd2f`: PASS, `stopped: true`. Server and all three
client process logs have their PASS markers and no SCRIPT/parse errors.

- Actual current Master ticket -> PG grant -> native World authentication and
  automatic runtime hydration, followed by real Inventory RPCs from separate
  client processes. Two accounts receive only their own item/state scope.
- One account row is held by the fixture while another client's equip commits
  and World physics continues. No simulation-thread PostgreSQL wait is introduced.
- Move, activate, equip, exact/automatic unequip, footprint rejection, stale
  revision and a no-op use the production endpoint/client adapter/bridge.
  Server combat stats and equipped actor state reflect committed equipment;
  the observer receives public weapon changes without the other Inventory.
- Lost mutation response retains original ID/body on disk. `ui.ready` after
  browser-transport reload exposes recovery, then receipt confirmation repairs
  current state without another mutation. A lost rejection reply resolves to
  the original durable rejection and clears its journal too.
- A deferred mutation-COMMIT `40001` leaves the client unresolved. After removing
  the fault, explicit receipt recovery finishes the originally admitted body and
  confirms that ID. This fixture simulates a known server rollback reported
  conservatively as unknown; arbitrary network-lost COMMIT acknowledgement is not
  directly injected here (native unknown-outcome suites remain separate).
- The first real client exits with a journal after a committed unequip loses its
  reply. A new process and native relogin restore that original entry and confirm
  it. A native advisory lock holds the readiness ACK after hydration: no initial
  client snapshot is sent until ACK succeeds, preventing premature auto-discovery.
- A journal entry written before any send remains missing after automatic
  discovery. Only explicit retry sends the original body/ID and moves the item.
- Exactly nine real mutations emit change facts. No-op, rejection, receipt replay
  and missing lookup emit none. Exactly the two seeded PG UIDs remain; identity
  SQLite has zero ItemInstances. The Mandate boundary exposes no SQLite economic
  store/service in PG mode. All clients exit and both owned pools drain to STOPPED.

The forced ACK barrier was added after a repeated run exposed early snapshot
publication racing the client's one-shot receipt discovery. The adapter now
prepares snapshots during hydration and publishes on readiness before terminal
command delivery; it does not retry by inventing IDs or poll forever in the UI.

## Regressions

- `--suite inventory-runtime`: PASS, `run-hqpum4ue` (also `run-1f6tr4uv`), stopped.
- `--suite inventory-session-bridge`: PASS, `run-lmq278za`, stopped. Its physics
  progress probe now explicitly waits for physics execution; a quick supersession
  response alone is not required to cross a physics tick.
- `tests/run-web-inventory.ps1`: server and two actual SQLite clients PASS,
  including existing move/equipment, loss/reload/journal/Storage contracts.
- `tests/run-upgrade.ps1`: server and two SQLite clients PASS; closed PG
  economics guards preserve the existing NPC authorization/Upgrade path.
- Default `run-smoke.ps1`: PASS — architecture guards, 14 Godot checks and
  85 Web contracts. SOCI pin/hash check and `git diff --check`: PASS.

## Limits

Master/World and their control sockets run inside the server fixture process;
Gateway credentials/entry initiation, roster and map/actor construction are
controlled. This is not a complete production bootstrap or native CEF-rendering
acceptance. No Linux run, load/soak/SLA, player database migration, schema change,
default PG selector, cross-World handoff or cutover is claimed.

Other economic domain ports, wallet checkpoints/pending Yang, cross-domain
versioned invalidation and indexed pending-only discovery remain open. Normal
gameplay still uses SQLite. The PG fixture remains Inventory-only and fail-closed
for legacy economics; no mixed economic writer mode is enabled.

The PG COMMIT fault logs the expected PostgreSQL aborted/no-active-transaction
warning during conservative cleanup. Existing small ObjectDB/resource teardown
warnings remain; final successful logs have no unjoined-worker warnings.
Ignored raw logs remain under `.godot/verification/postgres-readiness/`.
