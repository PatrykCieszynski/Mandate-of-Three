# E0a: verified account identity

Base: `e362b9e` on 2026-10-13. Integration branch: `shop`; feature branch:
`codex/e0a-account-identity`. Product scope follows the user-provided Economy &
Marketplace Specification v1.1 and Implementation Plan v1.1. No Yang migration,
shop/escrow/claim tables, frontend, channels or PostgreSQL changes in E0a.

## Actual trust boundary

1. Gateway sends credentials to Master. AuthenticationManager validates them
   against the persisted AccountResource collection (or creates a new guest).
2. Gateway creates a random session token associated with Master's returned
   account name/ID. Before character create/list/enter, Gateway now verifies that
   session and its name; it overwrites the numeric client account ID with session
   identity. Previously these actions forwarded an unchecked payload username.
3. Master resolves the account from its own collection. World verifies that the
   requested local character belongs to that account name. Failed ownership now
   returns an error through Master rather than silently waiting for a timeout.
4. Master issues the existing random one-time world token, with an additional
   account ID argument only on its internal authority-only `fetch_token` RPC.
   Both character creation and existing-character entry use this path.
5. World rechecks the character/name and atomically binds the name to Master's ID.
   Only after successful commit does it install the token's PlayerResource.
6. The game client still supplies only the original token string to authenticate.
   It cannot select an authoritative account ID on the World connection. The
   existing token consumption and dirty-progression reentry behavior remain.

Master `AccountResource.id` is global to that Master's persisted account collection.
World `PlayerResource.player_id` is local to a World database. Multiplayer peer
IDs and instance IDs are transient and cannot become economic ownership keys.
WorldServer exposes `resolve_account_id(character_id)` and
`resolve_peer_account_id(peer_id)`; zero means unknown/unbound, never an invented ID.
Account Storage continues to use account_name in E0a; Yang remains per character.

Internal Gateway/Master/World links remain trusted server roles under the existing
deployment/network policy. This change does not add server enrollment, session
expiry, mutual role authentication, account renaming or a new identity framework.
Credential/world-token values are no longer printed by client connect/server auth.

## Additive SQLite migration v17

`accounts.master_account_id` is nullable for legacy accounts, CHECK > 0 when bound,
with a unique index across non-null IDs. Existing account/character/item/wallet/
Storage rows are preserved. Column/index creation and version marker commit in
one transaction; failure rolls them back. Repeated ensure/restart does not create
accounts or overwrite mappings. Already present columns/indexes tolerate replay
from an earlier version marker, as exercised by the existing wallet fixture.

Only a verified handoff binds an existing account. A name already bound to a
different ID, an ID already used by another name, a missing account row or an
invalid ID rejects the handoff and installs no usable token. No name hashes,
client IDs, guesses or automatic remapping are used.

`unbound_accounts()` reports pending legacy names. The read-only
`audit_account_identities(master_ids)` takes an explicit trusted Master manifest
and reports unbound, orphaned and mismatched names, including player rows without
an account row. It changes nothing and has no client RPC. Before E0b, obtain a full
Master manifest and explicitly reconcile offline/unbound legacy accounts; E0a
does not silently claim that accounts which never logged in are already mapped.

## Tests and deployment

Existing item/economy suites did not exercise Gateway session spoofing or
Master-to-World account mapping. Focused coverage therefore protects that new
ownership boundary and the real additive migration, rather than implementation
line coverage:

```powershell
& ./tests/run-account-identity.ps1
# Requires the normal local Classic gateway/master/world. Creates local accounts.
& ./tests/run-account-identity.ps1 -WithSession
& ./tests/run-items.ps1 -WithSession
& ./tests/run-smoke.ps1 -NodeExecutable '<node executable>'
```

SQLite coverage: populated v16, failure after ALTER/index creation, complete
rollback, repeat/reopen, two accounts/two characters each, same-ID binding,
conflicting name/ID rejection, orphan/unbound audit, trusted handoff installation,
peer/character resolution and persistence. The production session check uses HTTP
Gateway, Master RPC, World token authentication and character reentry, with forged
numeric ID, cross-account username, fake session and foreign character rejection.
It includes normal registration/password login and guest creation, reads the dev
World DB with query_only enabled, and leaves fixture accounts local.

Passing checks: populated SQLite identity/migration suite, the real four-character
session path, the existing two-client item session/relog suite, default smoke and
whitespace checks. Editor import also reopened the user's Terrain3D scene and
reported an unrelated null `navigation_map` in `Terrain3DSpike._enter_tree`;
this pass does not claim that editor scene is fixed. Headless identity/session
checks had no GDScript parse/assertion failures. Expected injected SQLite failures
and known engine/extension teardown diagnostics remain visible in test logs.

Restart Master and World together because internal RPC signatures changed;
restart Gateway to activate session checks. Public session/world token formats
are unchanged. Mixed server versions are unsupported. Existing clients may need
to log in again after Gateway restart because sessions remain in-memory.

Local pre-migration SQLite backup (including WAL snapshot) and Master account
collection copy are retained under ignored `.godot/runtime/backups/e0a-*`.
Rollback application code with coordinated role restart; the extra nullable SQL
column/index may remain, but retain v17 or explicitly restore the matching backup
if reverting schema metadata. Never independently restore Master IDs from an
unrelated snapshot. Runtime DB/accounts/logs and the user PDFs are not committed.
