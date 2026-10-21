# PostgreSQL implementation: consolidated milestone

**Historical milestone (2026-10-21).** Earlier P1/P2 parity and P3a–v runtime slices are completed. The current normal deployment uses PostgreSQL for accounts, profiles and Economy. Do not follow staged descriptions saying normal World uses SQLite.

## Canonical runtime references

- [Running full-state backend](../development/postgres-full-state.md)
- [Persistence guarantees and checkpoints](../architecture/persistence-policy.md)
- [Economy contracts C1–C5](../architecture/economy/README.md)
- [Testing](../development/testing.md), [maintenance](../development/postgres-maintenance.md), [backup/restore](../development/postgres-backup-restore.md)
- [Process startup](../development/postgres-process-startup.md), [World replacement](../development/postgres-world-replacement.md)

## Retired stage-level implementation reports

The following per-slice development notes are intentionally removed from the active tree to avoid stale claims and large duplicate summaries. They remain recoverable from [Git history at cleanup baseline](https://github.com/PatrykCieszynski/Mandate-of-Three/tree/d9c7ecb42c166106aab24e772c0afad1de6908a8/docs/development):

- `development/postgres-account-claims-parity.md`
- `development/postgres-auction-runtime.md`
- `development/postgres-auction-search-parity.md`
- `development/postgres-exchange-ledger-parity.md`
- `development/postgres-exchange-ledger-runtime.md`
- `development/postgres-exchange-matching-runtime.md`
- `development/postgres-exchange-orders-parity.md`
- `development/postgres-ground-items.md`
- `development/postgres-inventory-cache-fence.md`
- `development/postgres-inventory-concurrency.md`
- `development/postgres-inventory-endpoint.md`
- `development/postgres-inventory-executor.md`
- `development/postgres-inventory-intents.md`
- `development/postgres-inventory-parity.md`
- `development/postgres-inventory-runtime.md`
- `development/postgres-inventory-session-bridge.md`
- `development/postgres-inventory-sessions.md`
- `development/postgres-market-settlement-runtime.md`
- `development/postgres-npc-runtime.md`
- `development/postgres-npc-shop-parity.md`
- `development/postgres-pending-recovery.md`
- `development/postgres-seller-runtime.md`
- `development/postgres-shop-seller-parity.md`
- `development/postgres-shop-settlement-parity.md`
- `development/postgres-storage-parity.md`
- `development/postgres-storage-runtime.md`
- `development/postgres-upgrade-parity.md`
- `development/postgres-wallet-concurrency.md`
- `development/postgres-wallet-parity.md`
- `development/postgres-wallet-runtime.md`

The original per-slice tests and detailed results remain in [evidence](../evidence/README.md) for reproducibility. Their historical phase statements do not override the current implementation. PR descriptions should cover routine runs; create one consolidated milestone summary only after a milestone closes.
