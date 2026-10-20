# P3r — Shared PostgreSQL bootstrap evidence

2026-10-20, Windows. Branch `codex/postgres-economy-bootstrap`, based on main
`d664eb15` (PR #99). Godot 4.7.2, PostgreSQL 18.6, pinned/hash-verified SOCI
v0.4.3, Node 24.19.0. All native tests used owned disposable loopback SCRAM
clusters and stopped them. No installed service or real player data was changed.
Raw logs remain ignored under `.godot/verification/postgres-readiness/<run>`.

| Acceptance | Run / command | Result |
| --- | --- | --- |
| Final bootstrap / missing profiles / uncertain settlement drain | `run-zs_x3ljz` | PASS / stopped |
| Profile/XP and no starter currency / drain | `run-9j4_i9ff` | PASS / stopped |
| Initial uncertain settlement during drain | `run-0kr332px` | PASS / stopped |
| Offline provisioning CLI and startup refusal | `run-pjcodr3x` | PASS / stopped |
| Ten actual clients using shared Master/World bootstrap and shutdown | `run-_669xjkr` (also `run-19czgmwo`) | PASS / stopped; server and all ten client markers |
| Existing real Master/World session bridge | `run-iuvwr2rh` | PASS / stopped |
| Normal SQLite Marketplace/Exchange RPC | `tests/run-web-inventory.ps1 -Scene market_network` | server + two clients PASS |
| Default smoke | `tests/run-smoke.ps1` | Architecture guards, 14 Godot and 88 Web contracts PASS |
| Runner syntax / whitespace | Python AST, `git diff --check` | PASS |

The bootstrap suite exercises real native sessions and the existing World,
Inventory, wallet and Marketplace owners. It covers:

- SQLite default resolution and invalid/missing PG descriptor fields.
- Missing schema refusal without creating a schema, wrong authority ID and
  incompatible required feature version.
- The actual headless offline provisioning command, followed by idempotent
  provisioning using existing feature migrations.
- A missing profile connection/store failing before runtime publication.
- Two additional held database sessions exhausting the normal 12-connection
  fixture during partial World startup. Every opened pool closes before refusal;
  `pg_stat_activity` contains no executor session afterward.
- Master control composition and native stop, then complete eight-worker World
  composition; repeated startup cannot replace the existing owner.
- Failed/stopped PG selection withholding admissions and legacy SQLite facades.
- Profile creation and a three-column XP checkpoint still working while legacy
  potion/gold initialization is disabled and no SQLite account wallet is created.
- Pending 35 Yang plus 100 claimable proceeds committed atomically. A wrapper
  loses the successful native settlement result; shutdown retains current session
  delivery context, discovers the receipt read-only, reconciles 1635 Yang, and
  only then detaches and closes all pools. No blind mutation retry.

The ten-client suite now uses the same bootstrap for Master and World instead of
manual per-domain pool creation. It retains Inventory, NPC, Storage, ground item,
seller/buyer, Exchange order/cancel/matching and Auction browser/RPC recovery,
including all 27 known item facts and unchanged pre-existing SQLite wallet rows.
Trusted profile/PG identities and Gateway/map setup remain fixture-controlled.
The final ten-client run precedes only the additional missing-profile startup
guard, whose refusal and successful path are covered by the final bootstrap run.

This full-composition fixture uses 14 PostgreSQL connections: eight World sessions,
one Master control session, one test control session, three superuser-reserved
slots and one spare. Other suites retain 12, including deliberate exhaustion.
The first composed run (`run-p5_ruw89`) correctly refused the former fixture's
insufficient connection budget; it was not a gameplay failure or a reason to
remove a runtime worker. SQL/operation deadlines were not increased.

Development checks also caught an overly broad `available()` guard in the pure
NPC fixture with no World, and an assertion assuming an account-wallet table in
the profile-only schema (`run-rapoqiql`). The guard now applies specifically to
selected PG owners, preserving the legacy no-World test contract; the profile
assertion verifies that no SQLite wallet table was created. Final checks pass.
Expected native connection refusal/missing-table diagnostics belong to the
negative startup cases; final runs have no script/parse errors.

No normal Main/config backend switch, identity creation/import, schema change,
distributed owner, worker replacement or PG backup is delivered. The bootstrap
owns native resources, not the separately retained SQLite profile connection.
Physical CEF, Linux, full Gateway/process startup, multi-World, control-plane loss
recovery and P4 load/soak/import/restore/cutover are NOT VERIFIED. See
[bootstrap contract](../../development/postgres-bootstrap.md).
