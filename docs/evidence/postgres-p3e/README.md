# PostgreSQL P3e — Master/World Inventory session bridge evidence

Verified 2026-10-18 on Windows, Godot 4.7.2, PostgreSQL 18.6 and official pinned
SOCI v0.4.3. Branch `codex/postgres-inventory-session-bridge`, based on integrated
`main` `13b7c6a1`. PostgreSQL uses fresh owned SCRAM loopback clusters with
runner-confirmed shutdown. No installed service or player data is used.

## Native bridge

Latest `inventory-session-bridge` run `run-jrvgy1ct` (Master-loss review): PASS.

- The real Master login-result handler verifies the existing entry attempt and
  sender, then uses its own current ticket/account/character marker to request a
  delegated PG grant. Fabricated token, wrong World and missing account fail.
- A native advisory-lock fixture holds the old **grant installation** inside SQL
  while a newer authorized login supersedes it. Master rejects the old request
  without publishing a usable token. The old SQL may commit epoch 1, but the
  latest desired grant subsequently commits epoch 2; only that ticket is sent.
  SceneTree physics progresses during the SQL wait.
- The real authority-only Master/World RPC delivers context. A real client
  authenticates with the existing token; World automatically attaches the context,
  recovers/hydrates and acknowledges readiness. Equip through P3d updates the
  production World combat projection. No client maps or PG grants are manually
  installed for this flow. A PG World rejects a contextless legacy ticket.
- Native relogin installs epoch 3. Old-peer cleanup cannot revoke that replacement.
  Client disconnect retires the matching Master marker and revokes its PG grant.
- Deferred grant COMMIT `40001` produces a failed entry response, no usable World
  ticket and one sequence-recorded attempt, not an automatic grant retry. The
  known-aborted fixture row remains revoked. A fresh explicit login installs
  epoch 4 and recovers successfully. This does not prove arbitrary lost COMMIT
  response outcomes; withdrawal/inspection handle those conservatively.
- Losing the real Master socket detaches/disconnects active peers, discards unused
  tickets and aborts pending native authentication. The final review scenario
  freezes the issuer: grants remain valid in PostgreSQL, yet later admission
  fails both before delayed disconnect cleanup and after it. Owned pools drain;
  SQLite's Inventory remains empty.

Gateway credential/entry initiation, the roster handshake and post-auth UI are
controlled. The Master/World RPC and World/client authentication are real sockets
within one SceneTree, not three normal production processes. Default login and
legacy Inventory endpoints are not switched to PostgreSQL.

## Relevant regressions

| Check | Run/result |
| --- | --- |
| bridge, first functional run | `run-7jhjhhwu` PASS |
| bridge, SQL-in-flight takeover | `run-fr6woaxf` PASS |
| bridge, final including rejection checks | `run-innsuy6i` PASS |
| bridge, final including disconnected-Master cleanup guard | `run-9nothqjx` PASS |
| bridge, Master-loss review with valid unused grant/pending auth | `run-jrvgy1ct` PASS |
| inventory-runtime, Master-loss review regression | `run-6rv1ysom` PASS |
| inventory-runtime | `run-gek5yy_k` PASS |
| inventory-sessions | `run-w9kllge0` PASS |
| inventory-intents | `run-k902aow_` PASS |
| inventory-executor | `run-8lnuu52n` PASS |
| account identity, Gateway lifecycle/menu, native World admission, Master reordered entry replies | all five PASS |
| Default smoke | architecture guards, 14 Godot checks, 85 Web contracts PASS |

The internal token RPC fixture was updated for the optional context argument;
existing observable ticket/reply ordering assertions remain. The control read
adds no schema or domain transaction changes. Prior P3c's full domain matrix
remains the baseline; unrelated store packages are not rerun for a new control job.

## Normal three-process SQLite regression

`tests/run-items.ps1 -WithSession`: `items-unit`, `inventory-grid`,
`items-session-1`, `items-session-2` PASS. Three normal headless Gateway/Master/
World processes run current code from an owned project copy with empty account
and World data, isolated profiles, disabled Discord, dedicated Master/World ports
and the existing fixed loopback HTTP port 8088 checked free before startup.
Asset/addon/import directories are referenced from the checkout; runtime
accounts/DBs remain inside the owned copy. No server handler or login RPC is substituted.
Both clients exercise guest creation, native entry, Inventory and reconnect.
No script/parse/RPC signature errors appear in role logs. All launched processes
are stopped by their retained owned process handles; this is not a graceful
shutdown/checkpoint acceptance claim.

Role/client logs are retained under ignored
`.godot/verification/postgres-p3e-normal-logs`. The disposable project copy,
profiles and setup helpers are removed with the repository artifact cleaner.

Initial isolated fixture failures were an autoload class-name collision and
missing SQLite account-wallet setup; both were fixed in the fixture. The normal
copy initially lacked the main executable/generated translations and expected a
configurable HTTP port; setup was corrected without modifying production HTTP
code. Failed attempts remain separate from successful markers. Existing resource
teardown and known-abort transaction-cleanup warnings remain documented limits.
The Master-loss scenario also exposed an attempted disconnect notification on
an already closed control transport. World now checks native connection status
before sending that notification; the final run has no such RPC error.

## Remaining boundaries

No live backend selector, DSN, account import, dual economic writes or public PG
cutover. Normal endpoint/client publication and retries, other domains, full
three-process PG authentication, production bootstrap/shutdown and Master restart
recovery/failover remain open. Single-Master ownership is assumed. Cross-domain
invalidation, indexed pending discovery, pending Yang/CH handoff and P4
load/soak/migration are not closed by this package. Linux/physical CEF not verified.

## PR #85 Master-loss review regression

`run-jrvgy1ct` retains an unused beta ticket, a half-open gamma authentication and
an active alpha session. Issuer polling is deliberately frozen before closing the
real control socket, so it cannot revoke their grants. The disconnect callback is
also held temporarily: the unused ticket is still in World RAM, but token
validation, new ticket admission and a real late client's authentication already
fail because the control peer is disconnected. Releasing cleanup empties both
ticket/pending maps, closes native authentication peers and disconnects alpha.
Another late client is rejected after cleanup too. PostgreSQL still reports the
unused grant as recovering and alpha's grant as ready; denial does not depend on
revocation or ticket expiry. The relevant Inventory runtime regression and all
five existing account/Gateway/World/Master admission suites were rerun and pass.
