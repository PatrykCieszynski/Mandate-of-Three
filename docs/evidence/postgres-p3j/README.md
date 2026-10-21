# PostgreSQL P3j — NPC Shop/Upgrade runtime evidence

Verified 2026-10-18 on `codex/postgres-npc-runtime`, based on integrated `main`
`a2640ad7` (approved PR #91 squash). Windows / Godot 4.7.2 / PostgreSQL 18.6 /
official pinned SOCI v0.4.3. Native PG fixtures use fresh owned SCRAM loopback
clusters and isolated profiles, with runner-confirmed shutdown. No player data
or installed PostgreSQL service was used; clients are headless.

## New contracts

- `npc-runtime`: **run-wm6itzma PASS**, stopped. Four blocked native slots force a
  capacity rejection without retaining a mutation for later execution or consuming
  RAM income. A different account progresses while one account's SQL is locked,
  and physics continues. Accepted definition data is copied before mutation.
- Shop commits item creation, captured income, price and one receipt together.
  Exact occupied placement rejects without charge; its income stays in RAM.
  Upgrade consumes material, captured income and cost with the target UID/revision
  update atomically. No local Inventory write or grinding checkpoint races capture.
- A wrapper loses the completion of a real successful native purchase COMMIT.
  Same-ID receipt recovery removes that capture once. Replaying the same receipt
  after a later +37 income leaves +37 in RAM and does not emit a new-commit fact.
- A native deferred COMMIT failure rolls back target/material/Yang/receipt. Lookup
  remains read-only and returns unknown; only explicit execution retries the body.
  An Inventory recovery ACK COMMIT failure is repaired before terminal publication.
- Same-account alt takeover recovers the original issuer's receipt, preserves
  correct Yang and exposes no old-character items in the alt's snapshot. Late old
  detach cannot retire the replacement. Forced shutdown drains/joins workers.
- Extended `inventory-endpoint`: **run-h4p4ity7 PASS**, stopped (also
  `run-sngdpdpg` / `run-uzjpk_xv`). Actual actor, observer, restored and npc-restored client processes
  use native Master–World auth, production NPC/Shop/Upgrade RPCs, the Web UI bridge,
  existing adapters and local journals. Cases include foreign/no-context and range
  rejection, pending-funded purchase, lost Shop result/retry, Upgrade +1 and reload,
  and purchase recovery after process relog. All four client markers are required.
  Thirteen known Inventory/NPC commits emit thirteen facts; replay adds none.
  SQLite items stay empty and Yang stays 1,500 while PG reflects each atomic flow.

## Regressions

- `npc-shop`: **run-llm47r3u PASS**, stopped — existing SQLite/PG purchase parity,
  placement/capacity, receipt and rollback behavior.
- `upgrade`: **run-kxho6nc7 PASS**, stopped — existing parity, material consumption,
  failures/COMMIT handling and whole-transaction retry scenarios.
- `wallet-runtime`: **run-d5b5u648 PASS**, stopped — normal grinding checkpoints,
  lost completion, relog and worker drain remain intact.
- `wallet-concurrency`: **run-4z81vcxw PASS**, stopped — independent native sessions,
  reservations, receipt namespace and cross-operation account/wallet lock ordering.
- Existing `run-shop.ps1` and `run-upgrade.ps1`: server and both clients PASS.
  Port-18098 suites ran sequentially. No visible windows or watcher processes.
- Default smoke: architecture guards, 14 Godot checks and 85 Web contracts PASS.
  Pinned SOCI hash verification and `git diff --check` PASS.

Expected deferred-COMMIT cleanup diagnostics and small existing resource teardown
warnings remain. Successful native logs contain no SCRIPT/parse or unjoined-worker
errors. Raw logs remain ignored under `.godot/verification/postgres-readiness/`.

## Limits

This proves optional single-World behavior, not a production backend switch or
P4 performance acceptance. Runtime fixture peer maps/control availability/content
are controlled. Native network tests use real clients/control sockets but supplied
Gateway credentials, map/actor construction and line of sight. Physical CEF input,
Linux, server-process crash/restart and actual SQLite-to-PG import are **NOT VERIFIED**
by this package. Client process restart and native failed COMMIT are distinct tests.

There is no server durable NPC admission queue: only terminal receipts and the
existing durable client intent journal. Internal volatile scheduling is not a
durable acceptance ACK. RAM-only income can be lost on a World crash before
checkpoint/critical COMMIT. Distributed wallet/item publishers, shared Storage,
remaining Marketplace/Exchange/Auction flows, item pickup/initialization,
bootstrap/handoff and P4 remain open. See [the behavior contract](../../development/postgres-npc-runtime.md).
