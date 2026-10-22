# PostgreSQL P2 — backend concurrency acceptance

**Historical fixture scope:** stage-level backend/default statements below refer
to the original measured implementation, not today's deployment. Normal roles
now use PostgreSQL; migration/adoption is complete. Retained commands, failure
analysis and retry/concurrency contracts remain reference material. Start with
[current full-state setup](../development/postgres-full-state.md),
[persistence](../architecture/persistence-policy.md) and
[migration history](postgresql-migration.md) for current status.

This gate covers the opt-in PostgreSQL stores and current economic operations.
It does not enable PostgreSQL in World, implement a worker pool or authorize two
World Processes to own the same pending runtime income. Production stays SQLite.

## Acceptance matrix

The existing fixtures use independent native sessions for conflicting operations,
with observed lock barriers rather than merely calling operations sequentially.
Each suite runs in a fresh owned SCRAM loopback cluster via
`tools/postgres/run_readiness.py`. No installed service or player data is used.

| Guarantee | Existing fixture / observable contract |
| --- | --- |
| One buyer receives one offer; no duplicate custody or spend | `shop-settlement`: same-offer double buy, buy/cancel/edit, original receipt after offer deletion |
| Additive offline proceeds; partial collection preserves newer sales | `shop-settlement`: two sales, reciprocal purchases and duplicate collection; `wallet-concurrency`: simultaneous sale/partial collection |
| Shop and Exchange cannot spend the same account funds twice | `wallet-concurrency`: Shop purchase versus resting reservation or immediate maker fill, including alts, Yang/material conservation and one UID |
| Shared-wallet mutations respect reservations, headroom and command identity | `wallet-concurrency`: NPC/reservation, Upgrade/NPC, collection/spend, cross-alt/cross-kind receipt collisions, checkpoint/matching lock order |
| One owner/custody and complete receiving footprints | `inventory-concurrency`: equip/list, move/Storage/Exchange consumption, cross-producer last space, starter/pickup UID conflicts; `shop-seller`: competing footprint listings |
| Shared Storage retains its own account/footprint boundary | `storage`, `exchange-ledger`: competing alt transfers/deposits, complete footprints, provenance, rollback, issuing-character identity and replay |
| Claims retain the receiver and original item | `account-claims`: two-alt competing receive, capacity conflict, provenance constraints, replay/reopen; queued editors force current owner or capacity |
| Exchange reserves/releases and matches atomically | `exchange-orders`: same maker/two takers, fill/cancel, duplicate ID, cross-book participants, partial fills, refund and total Yang/material conservation |
| Retried operations reauthorize/reselect current state | Domain retry fixtures: queued editors change revision, owner, capacity, equipment, maker book or materials between attempts |
| Retry cannot duplicate receipt, income or partial writes | Domain retry fixtures: confirmed statement rollback for `40001`/`40P01`, three total attempts, original ID/arguments/pending prefix; other SQLSTATEs do not authorize retry |
| Uncertain COMMIT never automatically retries | `commit-failure` plus domain fixtures: native deferred errors close the connection, preserve `outcome_unknown`, reopen/discover the original ID; failed cleanup also fails closed |
| A blocked transaction does not serialize unrelated account pairs | `wallet-concurrency`: hold one purchase at account admission; a different Shop purchase and Exchange match both commit before releasing it |
| Read models remain coherent and bounded | `account-claims`: real visitor snapshot plus bounded claims; `auction-search`: indexed filters, stable pagination and SQLite parity |

Unique starting-cell indexes alone do not exclude overlapping tall footprints.
Every receiving/transfer store still relies on account-first admission plus its
full-footprint validation. These tests do not authorize direct custody SQL from
another producer outside that contract.

## Running the backend gate

Run the opt-in native suites sequentially, using the pinned SOCI payload:

```powershell
$suites = @(
    'readiness', 'commit-failure', 'wallet', 'npc-shop', 'inventory',
    'storage', 'upgrade', 'shop-seller', 'shop-settlement', 'account-claims',
    'auction-search', 'exchange-ledger', 'exchange-orders',
    'wallet-concurrency', 'inventory-concurrency'
)
foreach ($suite in $suites) {
    python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite $suite
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL gate failed: $suite" }
}
git diff --check
& ./tests/run-smoke.ps1
```

This is a milestone verification, not an addition to default CI. Keep routine
changes scoped to the affected behavior suites. Lock-barrier timeout budgets are
diagnostic bounds; successful independent completion is the contract, not a
transaction latency benchmark. No new test asserts UI geometry or game balance.

## Remaining gates

P2 backend acceptance is distinct from runtime adoption. P3 must provide bounded
nonblocking execution with one connection owner per transaction, backpressure,
stable IDs through timeout/reconnect, session/handoff fencing, versioned pending
income ownership and safe committed-fact reconciliation. No synchronous store may
be inserted into a combat tick because these tests pass.

P4 still requires actual PostgreSQL-backed World/network load, mixed writes and
reads, saturation/recovery, repeated comparable runs, soak, and a rehearsed
quiesced migration with conservation/receipt validation. Native COMMIT faults
demonstrate their known fixture outcomes; they do not determine whether an
arbitrary lost COMMIT reply committed. Discovery/fencing remains required.

Verification platform and run identities: [P2 acceptance evidence](https://github.com/PatrykCieszynski/Mandate-of-Three/blob/37827015b8536a5b7862cb092d86a7da79dcf988/docs/evidence/postgres-p2l/README.md).
