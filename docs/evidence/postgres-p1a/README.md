# PostgreSQL P1a — SQLite baseline evidence

Captured 2026-10-16 from integrated `main` **ee78c5e**, using production migrations
and a newly created `EconomyFixture` identity. No runtime/player database read.

- [sqlite-schema.json](sqlite-schema.json): 71 installed objects, comprising 26
  tables, 23 explicit indexes, 18 triggers and 4 views; migration 24, item/wallet
  revision feature 2. Internal `sqlite_*` objects/sequence values and per-fixture
  authority identity are excluded.
- [sqlite-source-inventory.json](sqlite-source-inventory.json): 19 persistence /
  orchestration source files, 341 candidate API call sites and 423 SQL-looking
  string literals. Includes expressions and dynamic SQL references; not a parsed
  executable SQL manifest. Some `.query()` calls are application delegation.
  Lexical dialect flags may include comments; use file/line references for review.

Regenerate source inventory:

```powershell
python tools/postgres/inventory_sql.py --output docs/evidence/postgres-p1a/sqlite-source-inventory.json
```

The schema is produced in the owned run folder by:

```powershell
python tools/postgres/run_readiness.py
```

Review and copy its sanitized `sqlite-schema.json` when intentionally refreshing
the baseline. These are historical port inputs, not exact-schema CI assertions.
Do not update them from a real World store or treat them as a data migration.

See [P1a contract, findings and setup](../../development/postgres-readiness.md).
