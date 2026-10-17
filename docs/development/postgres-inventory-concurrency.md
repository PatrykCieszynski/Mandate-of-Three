# PostgreSQL P2b — Inventory custody and receiving conflicts

This opt-in slice makes every native Inventory command admit its account before
its character, receipt and item mutation. Starter initialization and ground-item
claim also lock the trusted character's account before the character. The binding
is checked again under the character lock. World still uses SQLite.

## Correctness boundary

Before this change two alts could both pass account-scoped receipt discovery on
different character locks. One committed; the other then failed its receipt INSERT
with a storage error. Account-first admission now makes it discover the original
result and return `command_conflict` for another issuing character/payload. Original
fingerprints, character-scoped recovery, revisions and receiving rules are unchanged.

All these mutations also advance account item watermarks. Starter/pickup must
follow account-before-character ordering, rather than remain character-only entry
points beside account-admitted Shop, Claims, Storage and Exchange operations.
Unreceipted starter/ground markers remain their existing durable invariants; no
new receipt model, per-drop history or command framework is introduced.

The existing receiving boundary still locks the target character and validates
every footprint cell. Composing callers own account admission and the complete
transaction before invoking it. Storage continues to own its source authorization,
provenance and complete-footprint transfer. No Store bypass, raw Storage write,
schema change or new placement algorithm is added.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin 'Y:/Software/PostgreSQL/bin' --suite inventory-concurrency
```

Native sessions/threads overlap at observed database lock barriers. The fixture
checks complete committed item/custody and full-footprint invariants after:

- Two alts moving different items under one command ID: exactly one mutation, the
  other receives conflict, original outcome survives reopen/replay without moving
  again. The same fixture fails against the original Inventory store at that
  expected-conflict assertion and passes after the fix.
- Equip versus listing of one sword; move versus Storage deposit; move versus
  conversion of one material into the Exchange ledger. The UID has one legal
  destination, or is consumed exactly once into the fungible balance.
- Move versus Storage withdrawal into the same receiving bag: different starting
  cells still overlap a two-high footprint, so only one operation succeeds.
- Claim versus NPC purchase for the last two-cell vertical space. No overlap,
  charged-but-unreceived item or destroyed claim; accepted/rejected claim receipt
  remains replayable after receiving capacity changes.
- Two starter initializations and duplicate ground pickup: one grant/marker.
  Two accounts racing one global ground UID still produce one item/custody/marker
  through the existing unique constraint; the losing transaction either discovers
  `claimed` or rolls back the unique conflict as `storage`. Explicit retry then
  discovers `claimed`, without a second grant.

The fixture uses existing Store APIs for cross-boundary mutations. Its fixture
producer inserts are trusted, sequential and isolated. See
[evidence](../evidence/postgres-p2b/README.md). Existing Inventory parity/COMMIT
fault/reopen, shared Storage, Shop seller, Claims and Exchange ledger suites remain
the regression owners for their earlier guarantees.

## Remaining gates

This does not complete broad P2 load/conflict coverage or whole-transaction retries.
The synchronous native SQLSTATE/error classification prerequisite recorded in
[P2a](postgres-wallet-concurrency.md) remains. P3 execution, pending-prefix ownership,
session fencing and World integration, plus P4 migration/load/cutover, are separate.
No new RPC, CEF flow, executor or database dependency is added to default CI. Linux,
PostgreSQL World/client/CEF and throughput/soak behavior are not verified here.
