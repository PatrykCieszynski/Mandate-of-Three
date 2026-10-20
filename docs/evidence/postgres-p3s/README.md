# P3s — normal PostgreSQL process startup acceptance

Date: 2026-10-20. Windows, Godot 4.7.2, pinned godot-soci 0.4.3,
PostgreSQL 18.6 from the supplied local binaries, Node 24.19 for Web UI smoke.
All PG runs used owned disposable loopback clusters and private account/profile
paths. No installed service or real player data was used. Every recorded final
PG run below reports `stopped: true`.

| Check | Final result | Local ignored evidence |
| --- | --- | --- |
| Normal Gateway/Master/World startup, identity, client and full restart | PASS | `.godot/verification/postgres-readiness/run-t02bynsg/` |
| Shared bootstrap/refusal/partial failure/unknown settlement drain | PASS | `.godot/verification/postgres-readiness/run-36xpodwv/` |
| Master → World PG session bridge | PASS | `.godot/verification/postgres-readiness/run-7ja1v4xk/` |
| Existing SQLite Marketplace RPCs, server + two clients | PASS | `.godot/verification/market-network-test-*.out.log` |
| Default smoke, architecture guards, 14 Godot suites + 88 Web contracts | PASS | `.godot/verification/` |
| Python runner AST / `git diff --check` | PASS | Local invocation |

## Behavioral evidence

The startup runner instantiates ordinary production Master, Gateway and World
scenes in separate native headless processes. Configuration selects P3r's owner;
the wrapper does not inject runtime domains, account mappings, session markers,
grants or starter items. It only observes completion and asks owners to close
before exit. Ports are private/random; both Master identity collection and World
profiles live under the owned fixture directory.

The real client creates its account through HTTP. A deliberately preexisting
foreign PG mapping makes character creation and subsequent login fail without a
successful handoff. The SQLite profile remains discoverable; failed PG binding
rolls back the new account/wallet too. After explicit repair only in the disposable
fixture, login binds that same profile and obtains a real Master-issued grant.
The client receives its initial inventory, equips by UID/revision and relogs
without changing the durable item/equipment/stat/revision view. The test then
stops all three roles, restarts them with the same files/PG realm and enters again
with the same equipped UID and two items, rather than repeating initialization.

Separate assertions cover wallet initialization replay without a balance reset,
foreign-character mapping rejection/rollback, stable realm/profile binding and
refusal of another profile ID. A missing profile cannot claim the PG realm.
Startup rejects an explicitly selected profile file containing legacy currency
rows. The normal profile file contains no `account_wallets` table; the existing
legacy item table remains empty. Bootstrap regression also verifies orderly exit
after failed startup, worker exhaustion cleanup and uncertain settlement recovery
before detachment. All role/client logs are checked for script/parse failures.

During development, new fixture assertions were corrected: the public world list
is nested under `w`, `economic_context` is not a session-epoch structure, and the
legacy profile schema creates an empty item table. Those failed harness runs are
not acceptance evidence. The final named runs above use the corrected contracts.
Existing Godot resource-teardown warnings remain separate from PASS/exit status;
no script failures are accepted by the runner.

## Boundaries

Default configuration remains SQLite. PG economic startup is explicitly opt-in,
with one World/profile owner, no silent fallback and no SQLite economy import.
The profile file/ID and Master identity collection must be retained with the realm.
This is not a distributed profile/PG transaction: on partial creation failure,
retry entering the visible profile; never assume the profile was rolled back or
overwrite foreign ownership. No schema migrations or frontend protocol changes
were introduced. The internal Master/World RPC table gains readiness acknowledgment.

Not verified here: Linux, physical CEF input, a sustained combat/economy soak,
consistent PG/profile/account backup and restore, controlled ownership handoff,
SQLite data import rehearsal or production cutover. Those operational/P4 gates
remain explicit follow-up work.
