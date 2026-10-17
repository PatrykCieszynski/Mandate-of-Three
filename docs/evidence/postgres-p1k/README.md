# PostgreSQL P1k — Exchange ledger evidence

Windows, PostgreSQL 18.6, Godot 4.7.2 and pinned godot-soci v0.4.2
(`222cfec77acbdb15fa7cd6f6c97d7064126a947a`). Fresh owned SCRAM loopback
PostgreSQL clusters and disposable SQLite only; no personal/runtime stores.

Final ledger fixture `run-gosq884z`: `POSTGRES_EXCHANGE_LEDGER_OK` and
`POSTGRES_EXCHANGE_LEDGER_NATIVE_OK` PASS; runner stopped the owned cluster.
Raw diagnostics stay ignored under `.godot/verification/postgres-readiness/`.

Verified:

- SQLite/PG matching committed account ledger, zero/all canonical asset projection,
  Inventory/Storage/claims, source owner/revisions, account item watermarks,
  remaining affix rows and receipt counts. Only generated withdrawal UIDs normalized.
- Whole bag deposit, partial/whole cross-alt Storage deposit, material whitelist,
  unauthorized bag/Storage, stale or metadata-bearing/nonfungible stack rejection.
- Conditional free-only withdrawal, reserved balance protection, explicit bag/claim
  output, normal claim receiving by an alt, no full-bag fallback, retained UID on
  retry and exact stack amounts. Total-cap overflow preserves source and balance.
- Faults at ledger increment/debit, source decrement/delete, new item/custody and
  receipt restore all snapshots. Full Storage-consumption faults use its owned
  mutation boundary. Original command succeeds after clearing transient SQL faults.
- Original issuer/payload replay, account discovery/isolation, receiver conflict and
  reopen retain original UID/outcome; no second created stack on retry.
- Independent native sessions observed at a lock barrier: competing shared Storage
  partial deposits, no overspend from two alts, one created UID/receipt for duplicate
  withdrawal, and full Storage consumption versus normal Inventory transfer.
  The same UID becomes a balance OR a receiving stack, never both.
- Deferred COMMIT faults for deposit and claim withdrawal report unknown and close
  the session. Reconnect proves unchanged ledger/items/custody/revisions/affix rows/
  receipts, discovery finds no result, original-ID explicit retry succeeds.
- Populated schema extension preserves source items, injected DDL/version failure
  removes the partial ledger table, repeat/future-version guards and nested caller
  transaction preservation. Storage/Claims helpers refuse outside transactions.

Regressions PASS:

- Native account Storage: `run-m50qb1w_`.
- Native account claims: `run-5cit6w9a`.
- Native Shop settlement/shared receipt: `run-vozcy7pw`.
- Default smoke: 14 Godot cases, architecture checks, 85 Web/bridge tests.
- Existing two-client SQLite `exchange_network`: server/client1/client2, normal
  bridge/RPC/session flow, cancellation/fill and retry/reload/reconnect scenarios.
- Python AST, whitespace and all 45 unrelated local file hashes verified.

Expected injected SQLite SQL/overflow errors and generic native teardown warnings
appear in logs. Runner PASS rejects script/parse/assertion failures. No PostgreSQL
client/World switch, CEF physical validation, Linux, reservation/matching port,
concurrent load/soak, broad P2, executor/fencing or cutover is claimed.
