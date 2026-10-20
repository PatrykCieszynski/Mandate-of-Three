# P3o — Exchange custody/ledger runtime evidence

2026-10-20, Windows. Branch `codex/postgres-exchange-ledger-runtime`, based on
main `5c33c5fe` (PR #96). Godot 4.7.2, PostgreSQL 18.6, pinned/hash-verified SOCI
v0.4.3 and Node 24.19.0. PostgreSQL tests used owned disposable loopback SCRAM
clusters and stopped them. No real player data or installed PostgreSQL service
was mutated. Raw logs remain ignored under
`.godot/verification/postgres-readiness/<run>`.

| Acceptance | Run / command | Result |
| --- | --- | --- |
| Final Exchange runtime / explicit capability guard | `run-w2r3z7mj` (also `run-w9s6r1l9`) | PASS / stopped |
| Initial complete runtime acceptance | `run-w00ed9su` | PASS / stopped |
| Final nine actual client processes | `run-x6ohjggx` | PASS / stopped; server and all nine markers |
| Earlier nine-client acceptance | `run-w_r138uj` | PASS / stopped |
| Existing Exchange ledger backend | `run-ey01xek9` | PASS / stopped |
| Existing Exchange orders backend/read model | `run-hnp1dc6o` | PASS / stopped |
| Seller runtime without Exchange capability | `run-q6gzt0de` | PASS / stopped; Exchange open explicitly unsupported |
| Existing SQLite Marketplace/Exchange RPC | `tests/run-web-inventory.ps1 -Scene market_network` | server + two clients PASS |
| Web UI contracts | `tests/run-web-ui.ps1` | 88 PASS, generated JavaScript rebuilt |
| Final default smoke | `tests/run-smoke.ps1` | Architecture guards, 14 Godot contracts, 88 Web contracts PASS |
| Configured formatting / runner syntax / whitespace | Prettier configured scope, Python AST, `git diff --check` | PASS |

The new native runtime test uses real worker-owned PostgreSQL sessions, World
Inventory cache and controlled peer maps. It covers:

- Current delegated-session bypass denial and foreign bag ownership rejection.
- Partial bag and account Storage deposits with UID/revision preservation and
  Inventory/Storage projection agreement before publication.
- Withdrawals to bag and account claims, insufficient free balance and successful
  receipt replay without additional units/commit facts.
- An account blocked in SQL while another account's conversion and physics
  progress independently.
- Native deferred receipt COMMIT failure: no partial consume/credit; read-only
  missing-receipt recovery before explicit original-ID execution.
- Lost successful withdrawal completion, alt takeover and fresh account-scoped
  receipt discovery after RAM retirement without retargeting the original bag.
- Foreign-account receipt isolation, unsupported order writes, unchanged Yang,
  conservation of all 12 original material units, and graceful worker drain.

The existing backend ledger suite retains SQLite parity, full-bag rollback,
Storage/claim authorization, overflow/reserved-unit bounds, independent-session
conversion/withdrawal conflicts and whole-transaction retry. The orders suite
checks the read-model composition change without enabling its runtime writes.

The endpoint suite runs nine headless clients: prior actor, observer, Inventory,
NPC, Storage, ground, seller and buyer restoration, plus Exchange restoration.
It uses production RPC/bridge/native journals and retains all prior economic
contracts. Exchange phases cover actual Storage transfer, deposit with lost reply,
`ui.ready` retry without the original browser body, claim withdrawal, bag withdrawal
with lost reply and actual client exit/relogin restoring the original new UID.
A saved but never submitted intent remains journaled after read-only reopen;
explicit Retry receives the definitive empty-ledger rejection and clears it.
Twenty-seven known item mutations yield twenty-seven facts, with no replay fact.
PG seller wallet remains 3880; SQLite economic items remain absent/Yang stays 1500.

One Web contract verifies Retry without a source stack, blocked replacement
mutations while unresolved, and the optional ledger-only order-control gate.
It does not assert pixels or menu node geometry. Existing SQLite browser retry
and domain-validation contracts remain covered.

The first fixture (`run-0hy0ubp7`) used `bag` instead of the Storage API's
`inventory` source. The next (`run-1dvju7tx`) exposed a real configuration omission:
Exchange could be enabled without combined Storage projections. Its constructor
now explicitly enables them before peer attachment. Final native runs have no
script/parse errors or unjoined-worker warning. Expected deferred-COMMIT cleanup
and small Godot fixture teardown warnings remain.

Normal gameplay remains SQLite. No schema/RPC-signature change, order/cancel/
matching runtime, distributed publication, public PostgreSQL Auction search,
complete R6 pagination or backend selector/cutover is delivered. Gateway/map/peer
construction is controlled. Physical CEF, Linux, whole-World crash/failover and
P4 load/soak/import/restore are NOT VERIFIED. See
[runtime contract](../../development/postgres-exchange-ledger-runtime.md).
