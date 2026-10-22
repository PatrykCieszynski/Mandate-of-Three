# P3m — seller runtime and item-claim evidence

2026-10-19, branch `codex/postgres-seller-runtime`, based on main `1aa1313d`.
Windows, Godot 4.7.2, PostgreSQL 18.6, pinned/hash-verified SOCI v0.4.3 and
Node 24.19.0. All PostgreSQL runs used owned disposable loopback SCRAM clusters and
stopped them. No real player database or installed PostgreSQL service was mutated.
Raw logs remain ignored under `.godot/verification/postgres-readiness/<run>`.

| Acceptance | Run / command | Result |
| --- | --- | --- |
| Native seller coordinator | `run-n0dw6y5w` | PASS / stopped |
| Seven actual native clients, final expanded recovery | `run-26m5_ky1` | PASS / stopped |
| Earlier seven-client acceptance | `run-97d1lykb`, `run-zzama1nq` | PASS / stopped |
| Existing PG seller transactions | `run-ryh8_qcj` | PASS / stopped |
| Existing PG account claims | `run-ur_lzl74` | PASS / stopped |
| Existing SQLite market network | `tests/run-web-inventory.ps1 -Scene market_network` | server + two clients PASS |
| Default smoke | `tests/run-smoke.ps1` | Architecture guards, 14 Godot contracts, 86 Web contracts PASS |

The new runtime fixture uses real native sessions/workers and World Inventory
cache, with controlled peer maps. It covers all five operations; raw-call grant
bypass rejection; full placement/foreign ownership checks; receipt replay without
new facts; account A blocked while account B and physics progress; native deferred
mutation COMMIT failure, read-only missing receipt and explicit same-ID retry;
Inventory ACK COMMIT repair; successful cancellation with lost completion and alt
takeover; original-account receipt after RAM retirement; concurrent claim after
snapshot read with projection repair; full worker refusal with no later write;
unchanged wallet; unsupported buyer execution; and graceful drain/join.

The endpoint suite runs actor, observer, Inventory-restored, NPC-restored,
Storage-restored, ground-restored and seller-restored headless client processes.
It retains prior Inventory/Yang/NPC/Storage/ground contracts. New cases exercise:

- Lost listing reply followed by `ui.ready` and same-intent retry after the item
  has already left the bag for escrow.
- Price edit and shop configuration without extra Inventory facts.
- Lost cancellation reply and journal recovery through UI recreation.
- Lost item-claim reply followed by actual client exit/relogin and the same UID.
- An intent saved but never sent: window reopen only discovers; explicit Web
  retry executes the original body/ID and updates the name.
- Twenty-one known item mutations produce twenty-one item facts; replay,
  configuration and price editing add none. PG wallet remains 1850 after prior
  wallet/NPC scenarios; SQLite has no economic items and Yang remains 1500.

One Web contract checks restored pending recovery without an original browser
payload/item, single in-flight retry, retained retry after transient failure and
clearance after success. Generated JavaScript is rebuilt with TypeScript.

An initial SQLite regression was accidentally started while the endpoint suite
owned port 18098; it failed socket setup. It was repeated sequentially and passed.
This failure is not evidence of a production reader defect. Native final runs
remain successful; expected fixture teardown warnings are not gameplay evidence.

Normal runtime remains SQLite. No schema/RPC-signature change, buyer settlement,
proceeds collection, Exchange/public PG Auction, complete claims pagination,
cross-process publication or backend selector is delivered. Physical CEF, Linux,
full Gateway-to-PG gameplay, whole-World crash/failover and P4 operational/load
acceptance are NOT VERIFIED. See [contract and limitations (historical)](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/d9c7ecb42c166106aab24e772c0afad1de6908a8/docs/development/postgres-seller-runtime.md).
