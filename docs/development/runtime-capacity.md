# Startup capacity and acknowledged World admission

This slice implements **session/control/cache capacity**, following the W0
[audit](../plans/world-w0-limit-audit.md). It does not implement worker tuning,
AOI, physics optimization or multi-World placement. PostgreSQL remains the normal
backend; there is no fallback after failed startup/write.

## Configuration

The checked-in `data/config/world_config.cfg` and `master_config.cfg` are the
commented examples. Private deployment configs can still be selected with
`--config=...`. Startup parses one immutable server-only settings value and
passes the relevant limits to each owner. No hot reload or mutable singleton.
Credentials remain in the existing environment variables, not this object.
Startup logs report the effective role-specific numeric budgets, without tokens,
connection strings, account identities or a raw config dump.

| Key | Default | Accepted range | Owner / meaning |
|---|---:|---|---|
| `[world-server] max_players` | 64 | integer 1..65,536 | Accounts connected or holding an accepted World ticket/native authentication reservation in this process; same-account replacement shares a place |
| `[runtime] version` | 1 | 1 | Settings contract version |
| `inventory_bindings` | 64 | integer 1..65,536, >= max_players | World Inventory owners; reservations must fit before a usable ticket |
| `wallet_accounts` | 64 | integer 1..65,536, >= max_players | Retained Wallet owners, including detached dirty/paused/unknown accounts |
| `master_grants` | 64 | integer 1..65,536 | Master grant/revoke owners; distinct from concurrent SQL and Gateway sessions |
| `handoff_tickets` | 1,024 | integer 1..65,536 | World unused + native-pending tickets; Master separately bounds in-flight acceptance ACKs by this value |
| `handoff_ttl_ms` | 30,000 | integer 1,000..300,000 | World ticket lifetime; Master uses it to validate the ACK deadline configuration |
| `handoff_ack_timeout_ms` | 2,000 | integer 100..30,000, < ticket TTL | Master wait for trusted World acceptance before replying to Gateway |

No `[runtime]` section uses these explicit defaults, including disposable legacy
fixtures. Unknown runtime keys, floats/bools in integer fields, invalid ranges,
or contradictory budgets refuse startup with exit code 1 before serving gameplay. Master refuses
registration of a World advertising more sessions than its grant-owner budget.
This preserves the single-World setup; it does not distribute admission globally.
Master also checks the actual World ticket lifetime from private registration
metadata against its ACK deadline; independently edited configs cannot silently
promise a longer acknowledgement window than the World ticket allows.
Settings for an unused role do not create that role's runtime in a process.

The former World `max_players=200` was metadata without an enforcing consumer.
The shipped value is now **64**, aligned with existing effective PG owner limits,
not a benchmark-backed increase/decrease of measured hardware capacity. Runtime
owners still default to 64 in isolated fixtures without injected settings.
Configurable ranges are validation limits, **not approved population targets**.

Keep worker/queue budgets unchanged: World 8 native workers, Master 1; existing
`[economy] queue_capacity=2` counts queued + executing + completed-but-unpolled
work per worker. Seller/Storage/Ground/Auction caps and Gateway limits remain
owned by their existing components. They are not silently moved into this schema.
Worker/operation-budget configuration is a later review scope.

## Ticket guarantee

```text
current Master entry attempt
  -> prepare existing trusted PostgreSQL grant
  -> send ticket to World
  -> World validates identity/health and reserves session + Inventory/Wallet room
  -> World replies handoff_accepted(token, accepted)
  -> Master validates sender, current token and deadline
  -> only then publish the ticket through the existing Gateway result
```

The internal ACK RPC is required because fire-and-forget ticket delivery could
otherwise publish a usable-looking ticket before World rejected its capacity.
The public client/Gateway request format and economic command protocol are unchanged.
The default 2-second ACK budget leaves room within the existing 5-second HTTP
request budget for other work. Increasing it requires considering those unchanged
Gateway/client deadlines; a longer wait does not guarantee an HTTP result.
Both Master and World must run the new version; mixed-version control-plane
rolling deployment is not supported by this local single-World slice.

World counts unique accounts across active peers, unused tickets and native
pending auth. Pending PG account IDs are unioned with actual Inventory bindings
and retained Wallet owners. Existing owners count once; a replacement may reuse
its own slot. All checks and token insertion are synchronous in one World turn.
Duplicate ticket delivery is idempotent and does not extend expiry or cancel
an already pending native authentication. Expiry/revocation/failure releases
unused reservations; completed authentication transfers ownership to live caches.
Master validates only the first matching ACK from the expected World peer.
The old fixed 0.5-second post-ticket wait is removed: actual acceptance is now
the synchronization point, and the connected-account marker is set afterwards.

Capacity rejection returns `ERR_BUSY`, with a readable client message. It is
not classified as a transport failure or bad credentials. There is no automatic
login retry loop on capacity exhaustion.

## Failure and recovery

- Native grant refusal: no World ticket is published. Original grant/revoke
  sequencing remains owned by the existing issuer, with its new injected cap.
- World refuses room: Master retires the provisional token/grant; no ticket
  escapes via Gateway and another account is not evicted.
- ACK timeout/loss, World disconnect/drain, or newer login: no assumption of
  success. Retire only this attempt's still-current token. A stale result cannot
  revoke a newer session. Late/duplicate ACKs cannot publish another result.
- ACK scheduling itself is bounded. Recheck available slots after awaiting SQL;
  replacing the same account retires its old ACK wait without double allocation.
- Wallet logout with dirty income or unknown COMMIT: ownership remains retained.
  Refuse a different account if the retained budget is full; do not flush stale
  snapshots, evict uncertain work, or interpret lost economic responses as failure.
  Existing wallet checkpoint/recovery is responsible for eventual release.
- Master loss: existing World fail-closed ticket/native-auth cleanup still applies.

Default Wallet capacity equals the session budget: pending offline checkpoints
can temporarily reduce new-login availability. Operators may separately budget
retained-account headroom after review; this change does not increase it by default.

## Verification / rollback

`tests/run-account-identity.ps1` includes `runtime_capacity`: real Master/World
loopback RPC, trusted fixture profiles and ready-cache ownership tests. It checks
invalid config, max+1, duplicate/replacement/expiry, bounded ACKs, loss/late ACK,
old/new login races and dirty/unknown retained Wallet capacity. Its simulated
ready cache does not claim PostgreSQL recovery coverage.

```powershell
& ./tests/run-account-identity.ps1
& ./tests/run-smoke.ps1
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite full-state
```

The full-state suite runs normal Gateway/Master/World processes with **one-account
configured budgets**, actual PG grants, creation/equip/relog, clean shutdown,
restart and backup/restore. It verifies that both native runtime owners refuse
a second account even though their class defaults are 64. Existing native PG
wallet/session suites remain the correctness owners for uncertain writes.

Rollback is a coordinated Master/World version rollback after draining sessions,
not hot-editing settings or replacing a live owner. No schema migration is added.
Do not restore the misleading 200 metadata value while retaining 64-owner caps.
