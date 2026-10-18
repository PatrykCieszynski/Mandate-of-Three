# PostgreSQL P3e — existing Master ticket to Inventory grant

**Opt-in bridge only. Production still uses SQLite.** This connects the existing
Master ticket issuer and native World authentication to the
[P3c grant](postgres-inventory-sessions.md) and
[P3d runtime owner](postgres-inventory-runtime.md). It does not introduce a new
login/token issuer, expose PostgreSQL to clients, or select a live PG backend.

## Control ownership and trusted identity

`inventory_session_issuer_postgres.gd` is an optional single-Master control owner.
A trusted bootstrap injects it into `WorldManagerServer.inventory_session_issuer`
with its own already-ready bounded executor pool. It exclusively polls that pool
on the Master thread; SQL/connection work stays in the existing native workers.
World has a separate runtime executor/owner. No per-client connection or global
business transaction queue is added.

The issuer accepts a World ID, username and existing token, then derives account,
character and fingerprint from `verified_inventory_ticket()`. That helper checks
the current Master marker, registered World and account identity. Neither a
client nor a World request can supply a replacement account/character assertion.
The helper/issuer APIs are internal, not new RPC endpoints. They rely on the
existing trusted internal World connection and pre-authorized entry attempt;
this package does not add transport authentication for arbitrary World hosts.

Successful login and character-creation callbacks first consume their current
entry attempt. Before delivering a World ticket, the opt-in path waits for its
delegated grant COMMIT. `fetch_token` carries one additional optional Dictionary
over the existing authority-only Master-to-World RPC. It contains account,
character, native int64 epoch and token fingerprint, not a new credential. Master
and World must deploy matching code for this internal signature change.
The public Gateway/client credential envelope is unchanged.

## Supersession, revocation and uncertainty

The issuer retains at most 64 account entries. Each has one in-flight control job
and the latest desired grant/revocation, rather than an unbounded queue of login
attempts. Distinct accounts can use independent workers. Repeated matching
requests share the same pending/result record. Retired idle entries are removed.

Inspection holds the existing PostgreSQL account lock and returns the current
grant/epoch. The issuer installs with that expected epoch using P3c CAS. It checks
the current Master ticket before scheduling and before accepting a completion.
If a newer login arrives while old SQL executes, the old SQL may finish but its
ticket cannot be published. Only after it returns does this account inspect/apply
the latest desired grant. Its generation prevents a delayed completion from
fulfilling another request. No active worker is forcibly closed.

Existing Master compare-and-retire and explicit revoke notify the issuer. A
stale disconnect cannot enqueue revocation of the replacement token. Withdrawal
inspects first and revokes only its own matching persisted fingerprint. A later
grant can directly fence the old epoch without first exposing a new World owner.

Storage/COMMIT uncertainty pauses the affected request; there is no automatic
retry of the uncertain grant and no ticket success. `control_failed` reports the
failure. Master withdraws its current failed ticket; this cleanup may inspect and
revoke a grant that actually committed, but does not reinstall that same grant.
A fresh explicit login can inspect the authoritative row and request a new
token/epoch. Failed cleanup is not confirmed revocation. The existing Master
entry timeout bounds waiting/publication, not native SQL cancellation or drain.

## Native World lifecycle

A trusted isolated bootstrap injects `WorldServer.inventory_runtime` with P3d's
owner and a ready runtime executor. The default is null. Master ticket delivery
now retains its optional grant context in the existing expiring/single-use ticket.
A PG World refuses a contextless ticket; a SQLite World refuses a PG context,
rather than silently interpreting it as authorization to use another backend.

Only after native authentication completes and current player/peer/token maps
are installed does World automatically attach that context. P3d then discovers,
resumes and hydrates before its local Inventory lane becomes ready. Native
disconnect detaches its own peer; explicit account revocation detaches that
account's runtime bindings. Losing the actual Master socket in this opt-in mode
invalidates every unused ticket, clears pending admissions before closing their
native authentication sockets, and detaches/disconnects active game peers.
Connection failure uses the same cleanup. SQLite's existing reconnect behavior
is unchanged.

PG ticket acceptance, native authentication start/continuation/completion and
token validation also require the control peer to be currently connected. Runtime
fingerprint checks fail closed on the same condition. These boundary checks deny
admission even before the disconnect cleanup callback runs; a persisted PG grant
is not sufficient authority while Master is unavailable. Reconnecting does not
restore discarded tickets or pending auth: a fresh current Master handoff is
required. This does not cancel previously accepted SQL or depend on successful
database revocation after an issuer crash.

## Bootstrap limits and next integration

There is deliberately no player-facing setting, export switch, DSN in tracked
configuration, or normal startup enabling this bridge. It is exercised by an
isolated acceptance fixture. A playable PG realm still requires the real
Inventory endpoint/client/private/public publication integration and fail-closed
gates for other economy domains. **Do not inject this into the current normal
map endpoints and mix their SQLite item/wallet writes with PostgreSQL.**

Schemas/account/character mappings must be provisioned before grant installation.
The bridge does not migrate identity storage or provision a newly created World
character into PostgreSQL; such an unmapped opt-in creation fails closed.
Normal SQLite creation remains covered by full-process regression tests.

This is one logical Master issuer, not distributed issuer consensus/failover,
durable restoration of Master RAM markers, leases or multi-World deployment.
Bootstrap/controlled shutdown must stop new logins, withdraw/drain grants and
continue polling both executors to STOPPED before freeing them. No production
shutdown hook or database cutover is installed here. Cross-domain invalidation,
pending-only discovery, pending Yang/CH handoff and P4 remain open.

## Verification

Run `tools/postgres/run_readiness.py --suite inventory-session-bridge`. It uses
owned PostgreSQL, real Master-to-World RPCs and native player authentication on
ports 18099/18098. Run sequentially with other network fixtures. Gateway
credentials/entry initiation, roster setup and post-auth UI are controlled; this
is not a full three-process PG login or a CEF test. Separate normal-role
`run-items.ps1 -WithSession` checks unchanged SQLite behavior in a disposable copy.
See [P3e evidence](../evidence/postgres-p3e/README.md).
