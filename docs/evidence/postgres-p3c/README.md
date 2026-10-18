# PostgreSQL P3c — Inventory session fence evidence

Verified 2026-10-18 on Windows, Godot 4.7.2, PostgreSQL 18.6, pinned official
SOCI v0.4.3 and Node 24.19.0. Branch
`codex/postgres-inventory-session-fence`, based on integrated `main` `bfdf3223`.
Every PostgreSQL suite uses a fresh owned SCRAM loopback cluster, with confirmed
runner shutdown. No installed service or player data is used.

## New boundary

Final session fixture `run-8otw8_mr`: PASS.

- Fixtures model **already verified existing Master grants**. Grant install is
  privileged input and does not validate a ticket. No actual issuer bridge is
  exercised or implemented; the hashing helper is not an authenticator.
- Same-grant retry returns the existing epoch. Stale expected epoch conflicts,
  stale disconnect cannot revoke a replacement, revoked grant cannot reactivate,
  and compare-and-revoke replays safely. Native epochs beyond 2^53 remain exact.
- Real PostgreSQL account locks order old admission before takeover: the already
  accepted intent survives, and its result retains the old captured context.
  Reversing the order (revocation before queued admission) denies new work without
  creating a durable intent. Mutating the caller dictionary cannot alter the job.
- Old contexts cannot admit, discover or obtain session outcomes; cached terminal
  rejection cannot bypass the fence. Forged character context is rejected.
  Contextless Inventory admission/command fails after grant registration.
- Recovery blocks on pending Inventory work across the account. A newly active
  alt discovers and resumes the earlier character's intent without moving its
  item to the alt. New dependent commands remain blocked during recovery.
- Snapshot before a late item commit becomes stale. Wrong authority marker is
  rejected. Only a fresh account/character/authority/revision marker and zero
  pending intents enable ready, under one account lock. This checks a supplied
  marker, not actual application to a live World projection.
- A deferred grant COMMIT `40001` returns unknown and closes the native session.
  A nontransactional sequence proves exactly one attempted commit, without
  automatic retry. The fixture inspects the known aborted state before explicit
  retry; it does not establish the outcome of arbitrary lost COMMIT responses.
  Drain/reopen and repeated schema installation preserve the durable grant.

## Shared-owner regression matrix

The command-owner admission guard is shared with earlier PostgreSQL domain
ports. All eighteen native suites passed on separate fresh clusters:

| Suite | Run |
| --- | --- |
| inventory-sessions | `run-8otw8_mr` |
| inventory-intents | `run-ipzctelb` |
| inventory-executor | `run-bbrs8x_7` |
| readiness | `run-baid7vpq` |
| commit-failure | `run-i8jro3d6` |
| wallet | `run-oidwcjun` |
| npc-shop | `run-htlri3du` |
| inventory | `run-hcvkubu5` |
| storage | `run-0ictkesx` |
| upgrade | `run-_2kcs_fh` |
| shop-seller | `run-fotvmri3` |
| shop-settlement | `run-ehaa5ii1` |
| account-claims | `run-pa96yl2i` |
| auction-search | `run-3ltqhn3v` |
| exchange-ledger | `run-dpn0n112` |
| exchange-orders | `run-431vm1gw` |
| wallet-concurrency | `run-bfyv72gv` |
| inventory-concurrency | `run-1b19t5ym` |

Default smoke: architecture guards, 14 Godot checks and 85 Web contracts PASS.
Existing isolated native World session admission fixture PASS
(`WORLD_SESSION_ADMISSION_OK`); its authenticated WebSockets verify the unchanged
live SQLite ticket path, not integration with the new PostgreSQL grant API.
The World fixture emits existing resource-leak teardown warnings; it has a zero
exit status, its PASS marker and no script/parse errors. No native game window
or normal player-server session was opened.

Runner AST, official SOCI pin and `git diff --check`: PASS. An initial fixture
parse error from inferred Variant typing was fixed with an explicit Dictionary
type before the successful native runs. Logs remain ignored under
`.godot/verification`; they are not production data or committed artifacts.

## Limits

This is a delegated **Inventory backend** fence, not a full C5 implementation.
Actual trusted issuer authentication/delivery, live World reconciliation and
stale-result filtering, endpoint/client integration, handoff/pending Yang, other
economy domains, P4 load/soak/cutover, Linux and physical CEF remain unverified
or unimplemented. Raw recovery/control APIs remain trusted internal APIs. No
claim is made that every item-creation/pickup path is session-fenced. Production
continues using SQLite; no runtime backend selector or login code changed.
