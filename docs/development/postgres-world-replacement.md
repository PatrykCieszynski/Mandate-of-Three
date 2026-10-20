# Controlled sequential PostgreSQL World replacement — P3v

The normal PG shutdown route now uses the same concrete profile-retaining
closure operation as realm maintenance. Master and Gateway can remain running
while an operator replaces the **single** World on the same host, with the same
profile/PG stores. This is not overlapping ownership, live migration, distributed
failover or permission to start another World before the old process exits.
SQLite remains the default backend.

## Operator sequence

1. Disable World automatic restart and use a configured private dashboard token.
   Ensure the new binary/config points to the same realm authority, profile file
   and PostgreSQL database. Master/account configuration stays unchanged.
2. POST `/v1/worlds/shutdown` with `{token, world_id}` on the existing dashboard.
   `ok: true` means **request accepted**, not checkpoint/exit success. The PG
   Master immediately marks that World `draining`, removes it from public
   routing and cancels pending entry attempts before reliable shutdown RPC.
3. Inspect `/v1/economy/status` and process supervision. Master remains READY;
   the target World is `draining: true`, `ready: false`. Heartbeat counters can
   lag, so a stale READY heartbeat or zero SQL count does not certify closure.
   Do not infer process exit merely from disappearance of a socket/roster row.
4. World drains existing economic work/pending income with the existing owners.
   Existing grants remain usable for their captured reconciliation; they are
   not prematurely revoked by closing public routing. Only after economic drain
   does it disconnect players, verify the latest captured profiles and close
   profile storage. Native workers stop before a successful process quit.
5. Require **confirmed old-process exit** from its supervisor, then start one
   replacement World. It runs normal schema/authority/profile checks and trusted
   Master identity-manifest readiness before it appears in public routing.
   New login obtains new authority; old tickets are not copied into the process.
   Master retires old session markers/grants on disconnect using existing
   compare-and-retire fencing.
6. Check normal login, UID/equipment and balances/progression. Re-enable the
   intended single-owner supervision policy only after the replacement is ready.

No new operator queue/receipt/lease is introduced. Retrying shutdown for the same
still-connected World resumes its retained concrete closure owner. A concurrent
duplicate is ignored while that owner runs. A failed economic or profile save
refuses quit, retains unresolved resources, leaves routing closed and blocks
another World registration while the old one remains connected. Resolve the
failure and retry on that process; never force-kill and call it a clean handoff.
If control transport was lost, status is not an exit certificate: verify the old
process externally before starting its replacement.

The native window-close path delegates to this PG closure owner too. Other
dashboard mutations, a suspended save/restart continuation and late manifest
readiness cannot reopen or write closed stores. SQLite keeps its existing save
and shutdown behavior. The existing restart countdown remains advisory; headless
SIGTERM/`systemctl stop` is not assumed to run Godot close notifications. Use the
acknowledged shutdown/process-exit sequence rather than relying on signal saves.

For a coherent backup of **all** stores, use full
[realm maintenance](postgres-maintenance.md) and the
[stopped-writer bundle](postgres-backup-restore.md), including Master shutdown.
A World-only replacement is not a frozen Master-account backup window.

## Correctness changes

- Master fences pending grant completion and the existing delayed handoff
  continuation against the target World's readiness, not only Master's state.
- Late identity-ready/re-registration cannot clear `draining` on the same peer.
- Master shutdown uses reliable transport at both RPC declarations. Its payload
  and player-facing protocol are unchanged; deploy matching Master/World code.
- Ordinary PG shutdown retains captured `PlayerResource` references and checks
  their actual writes. Reading `connected_players` after drain is insufficient:
  disconnect may already have removed every player, even if a legacy save failed.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite world-replacement
& ./tests/run-account-identity.ps1
& ./tests/run-smoke.ps1
```

The native fixture runs normal Master/Gateway/World and actual clients twice.
A held client has dirty Yang/XP. The controller temporarily locks the wallet
table while the real HTTP shutdown closes routing; the old process must remain
alive. After release, money/profiles persist, only Master's native worker remains,
and old grants retire. A replacement starts under the same live Master/Gateway,
rejects the previous consumed ticket, then accepts a normal login with the same
UID/equipment. Independent session fixtures cover unused-ticket/replay admission;
this probe does not claim a new unused-ticket test. The actual Master RPC test
additionally covers delayed grant and post-ticket handoff completion during drain.

Windows native acceptance only. Linux, physical CEF, cross-host/concurrent owner
handoff and P4 load/soak/import/cutover are not verified by these checks. See
[evidence](../evidence/postgres-p3v/README.md).
