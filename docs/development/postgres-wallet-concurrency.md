# PostgreSQL P2a — shared wallet admission across use cases

This opt-in backend change closes shared-account admission and checkpoint lock
ordering across NPC purchases, Upgrade, Exchange settlement and Shop collection.
World continues using SQLite; the new fixture is not PostgreSQL gameplay/network
integration or a load benchmark.

## Failure found and fixed

The original checkpoint iterated its input dictionary and updated wallets directly.
An Exchange match locks both account domains in sorted order, but may update the
higher-ID taker wallet before the lower-ID maker wallet. A checkpoint can then
hold the lower wallet while waiting for the higher wallet; the match waits for
the lower wallet. Sorting only checkpoint wallet writes cannot remove this cycle.

Checkpoint now admits **all** affected accounts, sorted by numeric ID, before
updating any wallet. It then applies all deltas in that transaction. This shares
the account-before-character/wallet order used by multi-party settlement. Missing
account, failed UPDATE or COMMIT retains existing all-or-nothing/unknown behavior.
Result wallet states are ordered by account; consumers correlate by account ID.
No delta receipt or automatic replay is introduced for checkpoints.

NPC purchase and Upgrade now use existing account-first command admission too.
The account scope is resolved from trusted character binding, not payload identity.
This serializes shared wallet use and receipt lookup before character/capacity
checks. Two alts racing one account-scoped operation ID get one committed outcome
and an original replay or `command_conflict`, rather than racing the receipt PK.
Existing fingerprints, receiving character, prices, recipes and rollback rules
remain unchanged. Other accounts have independent admission rows.

Standalone one-account Wallet spend/credit helpers still serialize on their wallet
row; they acquire no later account/character locks. The multi-account checkpoint
must not be composed by invoking those standalone helpers in arbitrary order.
None of these synchronous stores may be called on the World simulation path yet.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite wallet-concurrency
```

The owned PostgreSQL fixture uses independent sessions/threads and observes real
database lock waits before releasing its barriers. It checks:

- NPC spend versus Exchange reservation: one success, one `funds`, no overspend
  and no receiving item for the losing purchase.
- Upgrade versus another alt's NPC purchase: only one spend, with material and
  upgrade mutation present together or rolled back together.
- Partial revenue collection versus spend near wallet capacity: both operations
  succeed, the wallet stays bounded and wallet plus remaining revenue conserves
  the original total minus the purchase.
- Same ID across alts and across NPC/Exchange kinds: one mutation, deterministic
  conflict for the other payload, original UID/result after reopen and replay.
- Checkpoint versus reverse-wallet-order matching, held after the taker's wallet
  update; then two checkpoints with opposite dictionary insertion orders. Every
  delta and settlement survives without lock timeout/deadlock.
- Missing-account checkpoint rollback; account lock timeout leaves items, wallet,
  revisions and receipts unchanged. Discovery finds no result; explicit retry with
  the same ID commits once and subsequently replays.

The checkpoint/matching regression fails against the unchanged P1l wallet store
and passes with account-first checkpoint admission. The fixture's bounded lock
observation is synchronization, not a throughput/latency acceptance target.
See [evidence](../evidence/postgres-p2a/README.md).

## Remaining P2/P3 gates

This is not complete P2 verification: cross-operation custody/placement, broader
transaction conflicts and a bounded whole-transaction retry owner remain separate.
The pinned synchronous SOCI database API reports failure text, not a structured
SQLSTATE classification. Do not infer retryability by matching localized error
messages, or reuse the async dispatcher just to obtain its error fields. Safe
automatic retries need a verified native error boundary first.

Known statement failure plus successful rollback permits explicit original-ID
retry. Ambiguous COMMIT still closes the connection and requires receipt discovery;
it must never cause a fresh-ID compensation or blind automatic retry. Unreceipted
checkpoint deltas especially require P3 ownership/fencing before distributed use.
This fixture does not submit the same pending-income prefix twice through different
successful commands; runtime prefix ownership is a P3 contract, not supplied by
account locks alone. No executor/pool, RPC, UI, schema migration, dependency update
or production switch is added. Linux, PostgreSQL World/CEF and mixed load/soak are
not verified.
