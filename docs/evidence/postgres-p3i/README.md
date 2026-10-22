# PostgreSQL P3i — wallet runtime evidence

Verified 2026-10-18 on `codex/postgres-wallet-runtime`, based on integrated
`main` `26acb168` (approved PR #90 squash). Windows, Godot 4.7.2,
PostgreSQL 18.6, pinned official SOCI v0.4.3. All PG runs use fresh owned local
SCRAM clusters and isolated profiles, with runner-confirmed shutdown. No player
data, installed PostgreSQL service, public database or visible game window used.

## Acceptance

- `wallet-runtime`: **run-tikj7qn8 PASS**, stopped. Real production pickup/services
  accept 20 drops into RAM while PG balance and receipt count remain unchanged.
  A locked account checkpoint does not stop another wallet or physics. Income
  arriving after capture survives ACK as a separate pending prefix. The old
  `WorldDatabase` timer does not force/block the PG ordinary checkpoint.
- Native batches prove DB 40,000 + pending 30,000 - spend 50,000 = 20,000,
  receipt replay/conflict and reserved-funds rejection. A reservation raced after
  the RAM check rejects/rolls back cleanly and refreshes rather than wedging a debit.
- A test wrapper loses the **completion of a real successful native COMMIT**, for
  both income and test spend. Recovery reuses the original ID/body and does not
  add/subtract Yang twice. A native deferred COMMIT failure rolls back wallet and
  receipt; scheduled same-ID retry succeeds after removing the owned fixture fault.
- Duplicate attach, same-account alt replacement, delayed old detach, revoked
  offline dirty income, authorized relog, cap rejection and wallet-only Master
  loss are checked. Forced World shutdown checkpoint stops income, drains/joins
  workers, and recreated RAM starts at the acknowledged durable balance.
- `inventory-endpoint`: **run-04o680ue PASS**, stopped (also run-zrbiots9 before
  the final replacement-snapshot gate). Actual actor/observer/restored client processes
  and native Master–World sockets use production currency pickup/test-spend RPCs
  and receive wallet snapshots. Pickup is visible before SQL checkpoint, debit
  persists, account balances remain private and process relog restores Yang.
  SQLite wallet stays at its original 1,500; PG reaches 1,550. All existing
  Inventory loss/retry/reload/cache/fact/UID assertions remain intact. All three
  client PASS markers are required by the runner.

## Regressions

- `wallet-concurrency`: **run-a3lngx2a PASS**, stopped — independent native sessions,
  cross-operation funds/reservations, account receipt namespace and checkpoint locks.
- `inventory-runtime`: **run-sz82n8x6 PASS**, stopped — durable recovery and current
  combat cache behavior through the same bounded executor implementation.
- `inventory-session-bridge`: **run-wx2psqzi PASS**, stopped — real control transport,
  grant/auth/relogin/revocation/Master-loss admission.
- `tests/run-yang.ps1`: wallet, server and both clients PASS, headless, sequential
  with the other port-18098 network fixtures. Default SQLite currency remains intact.
- Default smoke: architecture guards, 14 Godot checks and 85 Web contracts PASS.
  SOCI pin/hash and `git diff --check` PASS.

The deferred-COMMIT fixture intentionally produces native failure/cleanup warnings.
Successful native runs have no SCRIPT/parse failures or unjoined-thread errors;
small pre-existing ObjectDB/resource teardown warnings remain. Raw owned logs stay
ignored under `.godot/verification/postgres-readiness/`.

## Boundaries

This is correctness acceptance, not P4 capacity, latency or a soak benchmark.
The wallet fixture supplies peer maps/control availability and geometry. The
multi-process fixture uses actual authentication/RPCs but controlled Gateway
credentials, map construction and line of sight. Physical CEF input/rendering,
Linux, full production PG startup and live migration are **NOT VERIFIED** here.

Normal gameplay still uses SQLite. This package does not wire Shop/Upgrade,
Storage, Player Shop, Exchange, cross-domain wallet invalidations or multi-World
handoff, and does not retire profile/progression SQLite. Synchronous local transfer
fails closed until its async wallet checkpoint settles; transparent transfer is
not claimed. Revoked dirty state remains in RAM until authorized recovery, and
unresolved state refuses graceful shutdown. A crash can still lose uncheckpointed
soft income. See [behavior and remaining adoption (historical)](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/d9c7ecb42c166106aab24e772c0afad1de6908a8/docs/development/postgres-wallet-runtime.md).
