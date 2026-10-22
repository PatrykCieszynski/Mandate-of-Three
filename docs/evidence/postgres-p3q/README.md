# P3q — Public Auction runtime evidence

2026-10-20, Windows. Branch `codex/postgres-auction-query-runtime`, based on
main `c174748b` (PR #98). Godot 4.7.2, PostgreSQL 18.6, pinned/hash-verified SOCI
v0.4.3, Node 24.19.0. All PG runs used owned disposable loopback SCRAM clusters,
then stopped them. No installed service or real player data was changed. Raw logs
remain ignored under `.godot/verification/postgres-readiness/<run>`.

| Acceptance | Run / command | Result |
| --- | --- | --- |
| Final native Auction runtime / disposal / active drain | `run-3uozd9e9` | PASS / stopped |
| Earlier complete queue/deadline/session acceptance | `run-jcqql7p7`, `run-odbctfuq` | PASS / stopped |
| Ten actual headless clients, public RPC/browser | `run-fjj2kj46` | PASS / stopped; server and all ten client markers |
| Existing Auction SQLite/PG parity, schema, rolled affixes and 10k observations | `run-bu807dnt` | PASS / stopped |
| Existing Exchange matching runtime | `run-bqnh_pxk` | PASS / stopped |
| Normal SQLite Marketplace/Exchange RPC | `tests/run-web-inventory.ps1 -Scene market_network` | server + two clients PASS |
| Final default smoke | `tests/run-smoke.ps1` | Architecture guards, 14 Godot and 88 Web contracts PASS |
| Configured formatting / runner syntax / whitespace | Prettier configured scope, Python AST, `git diff --check` | PASS |

The native runtime fixture reuses the existing 500-shop/10,000 legal two-cell offer
seed and actual worker-owned PostgreSQL sessions. Inventory/session maps are
controlled, with the real World/Inventory runtime. Tests cover:

- Public rows matching the existing domain result and malformed cursor rejection.
- An active account-lock wait while another account's seller command and World
  physics progress on the existing two-worker pool.
- Duplicate pending IDs with different payloads consuming no extra native work.
- A held completion exceeding the two-second deadline: one timeout, native slot
  retained, next account waits until the original completion is delivered.
- PostgreSQL lock-timeout rollback followed by a successful search on the worker.
- Local session detachment suppressing a result, and backend grant revocation
  rejecting a locally still-known context.
- Disposed map adapter refusing admission even after its endpoint is freed.
- Drain rejecting queued reads and refusing completion while a native result is
  held at the delivery boundary, even after the underlying workers have stopped.

A separate synthetic admission subcase fills 64 accepted sources and rejects the
65th, confirms one native slot and drains queued/active deliveries. These source
identities are test doubles, not 65 connected clients or a realm capacity result.

Final 30-read observation, three rotating source accounts, 0/1/2 affix filters:

| Metric | Value |
| --- | ---: |
| Worker-to-caller end-to-end p50 | 58.288 ms |
| Worker-to-caller end-to-end p95 | 66.648 ms |
| Physics interval p95 | 16.677 ms |
| Physics interval max | 16.705 ms |
| Physics interval samples | 100 |

End-to-end includes worker selection, session fencing, SQL, polling, projection
and the fixture's coroutine/frame scheduling. It is not native SQL time. The
fixture runs at a 120 FPS render cap with 60 Hz physics; it exercises no combat
simulation and is not a P4 load/soak acceptance or an A/B regression threshold.

The ten-client endpoint suite retains Inventory, wallet, NPC, Storage, ground,
seller, buyer and Exchange recovery. Before purchase it now opens public catalog,
searches the real listed offer, restores that browser result with `ui.ready`, then
sends repeated identical IDs with malformed payloads and repeats a rate-limited
terminal ID. Each gets at most one response. Earlier purchase/relog and matching/
cancel flows still finish, with 27 item facts and unchanged SQLite economic state.
The final client run precedes only the defensive disposed-adapter/active-drain
guards; the final native runtime run covers those guards directly.

Development runs `run-foypvewy` and `run-q9gui8av` failed fixture assumptions:
reading an old pre-ready snapshot and proceeding immediately after deliberately
exhausting the query limiter. The assertion now checks the actual `ui.ready`
snapshot and the fixture waits for its limiter window before continuing. Budgets
were not increased. Both owned clusters stopped. A one-off headless editor import
also reported an existing navigation initialization error; it is not counted as a
passing runtime test. Its untracked generated UID sidecars were removed.

No public wire/schema change, production backend switch, distributed invalidation
or new pool model is delivered. Physical CEF, Linux, combat capacity, full Gateway
bootstrap, whole-World crash/failover and P4 import/restore/cutover are NOT VERIFIED.
See [runtime (historical)](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/d9c7ecb42c166106aab24e772c0afad1de6908a8/docs/development/postgres-auction-runtime.md).
